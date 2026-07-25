//! Demo web frontend: one HTTP request per game turn.
//!
//! Deliberately stateless: each response carries the machine-state blob
//! (see state.zig) base64-encoded, and the client sends it back with the
//! next command, so the server keeps no session table. A real deployment
//! could equally store the blob server-side under a session id — the
//! session layer doesn't care.
//!
//!   GET  /     the embedded play page
//!   POST /new  -> {"output", "status", "state"}
//!   POST /turn {"state", "input"} -> same shape; "state" is null once
//!              the game has ended

const std = @import("std");
const Io = std.Io;
const zgigye = @import("zgigye");
const session = zgigye.session;

const turn_json = zgigye.turn_json;

const index_html = @embedFile("web/page.html");
const transport_js = @embedFile("web/transport_http.js");
const font_regular = @embedFile("web/fonts/et-book-roman.woff");
const font_italic = @embedFile("web/fonts/et-book-italic.woff");
const font_bold = @embedFile("web/fonts/et-book-bold.woff");

const max_steps_per_turn = 10_000_000;
const max_body_len = 1024 * 1024;

const TurnRequest = struct {
    state: []const u8,
    input: []const u8,
};

/// Static files the page pulls in. The wasm build stages the same set as
/// real files (see build.zig); here they ride along in the binary.
const Asset = struct {
    path: []const u8,
    content_type: []const u8,
    bytes: []const u8,
};

const assets = [_]Asset{
    .{ .path = "/transport.js", .content_type = "text/javascript", .bytes = transport_js },
    .{ .path = "/fonts/et-book-roman.woff", .content_type = "font/woff", .bytes = font_regular },
    .{ .path = "/fonts/et-book-italic.woff", .content_type = "font/woff", .bytes = font_italic },
    .{ .path = "/fonts/et-book-bold.woff", .content_type = "font/woff", .bytes = font_bold },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var story_path: ?[]const u8 = null;
    var port: u16 = 8080;
    const args = try init.minimal.args.toSlice(arena);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port")) {
            i += 1;
            const value = if (i < args.len) args[i] else usage(args[0]);
            port = std.fmt.parseInt(u16, value, 10) catch usage(args[0]);
        } else if (story_path == null) {
            story_path = args[i];
        } else {
            usage(args[0]);
        }
    }
    const path = story_path orelse usage(args[0]);

    const story = Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |err| {
        std.debug.print("error: cannot read '{s}': {t}\n", .{ path, err });
        std.process.exit(1);
    };

    const address: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var server = try address.listen(io, .{ .reuse_address = true });
    std.debug.print("serving {s} on http://127.0.0.1:{d}/\n", .{ path, port });

    var request_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer request_arena.deinit();

    while (true) {
        const stream = server.accept(io) catch |err| {
            std.debug.print("accept failed: {t}\n", .{err});
            continue;
        };
        // One connection at a time: plenty for a demo, and the machine
        // itself only ever runs between receiving a request and replying.
        serveConnection(io, &request_arena, story, stream);
        stream.close(io);
    }
}

fn usage(prog: []const u8) noreturn {
    std.debug.print("usage: {s} [--port N] <story-file.z3>\n", .{prog});
    std.process.exit(1);
}

fn serveConnection(
    io: Io,
    request_arena: *std.heap.ArenaAllocator,
    story: []const u8,
    stream: Io.net.Stream,
) void {
    var recv_buffer: [16 * 1024]u8 = undefined;
    var send_buffer: [16 * 1024]u8 = undefined;
    var conn_reader: Io.net.Stream.Reader = .init(stream, io, &recv_buffer);
    var conn_writer: Io.net.Stream.Writer = .init(stream, io, &send_buffer);
    var http_server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);

    while (true) {
        var request = http_server.receiveHead() catch return; // closed or malformed
        defer _ = request_arena.reset(.retain_capacity);
        handleRequest(request_arena.allocator(), story, &request) catch return;
    }
}

fn handleRequest(
    arena: std.mem.Allocator,
    story: []const u8,
    request: *std.http.Server.Request,
) !void {
    const method = request.head.method;
    const target = request.head.target;

    if (method == .GET and std.mem.eql(u8, target, "/")) {
        return request.respond(index_html, .{
            .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
        });
    }

    if (method == .GET) {
        for (assets) |asset| {
            if (std.mem.eql(u8, target, asset.path)) {
                return request.respond(asset.bytes, .{
                    .extra_headers = &.{.{ .name = "content-type", .value = asset.content_type }},
                });
            }
        }
    }

    if (method == .POST and std.mem.eql(u8, target, "/new")) {
        try drainBody(request);
        const turn = session.start(arena, story, max_steps_per_turn) catch
            return respondError(request, .internal_server_error, "the story crashed");
        return respondTurn(arena, request, turn);
    }

    if (method == .POST and std.mem.eql(u8, target, "/turn")) {
        var body_buffer: [4096]u8 = undefined;
        const body_reader = try request.readerExpectContinue(&body_buffer);
        if (!hasBody(request))
            return respondError(request, .bad_request, "missing request body");
        const body = body_reader.allocRemaining(arena, .limited(max_body_len)) catch |err| switch (err) {
            error.StreamTooLong => return respondError(request, .payload_too_large, "request body too large"),
            else => |e| return e,
        };

        const parsed = std.json.parseFromSliceLeaky(TurnRequest, arena, body, .{}) catch
            return respondError(request, .bad_request, "expected JSON with \"state\" and \"input\"");

        const state = turn_json.decodeState(arena, parsed.state) catch
            return respondError(request, .bad_request, "state is not valid base64");

        const turn = session.advance(arena, story, state, parsed.input, max_steps_per_turn) catch |err|
            switch (err) {
                error.InvalidState => return respondError(request, .bad_request, "state does not match this story"),
                else => return respondError(request, .internal_server_error, "the story crashed"),
            };
        return respondTurn(arena, request, turn);
    }

    return respondError(request, .not_found, "not found");
}

fn respondTurn(
    arena: std.mem.Allocator,
    request: *std.http.Server.Request,
    turn: session.Turn,
) !void {
    // Same bytes the wasm build hands the page directly; see turn_json.zig.
    const json = try turn_json.allocTurn(arena, turn);
    try request.respond(json, .{
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

fn respondError(
    request: *std.http.Server.Request,
    status: std.http.Status,
    message: []const u8,
) !void {
    try request.respond(message, .{ .status = status });
}

fn hasBody(request: *const std.http.Server.Request) bool {
    return request.head.transfer_encoding != .none or
        (request.head.content_length orelse 0) != 0;
}

/// Settle the connection's body state before responding. A POST without
/// body headers (e.g. bare `curl -X POST`) otherwise trips an assert in
/// std.http's discardBody; one with a body must be drained for keep-alive.
fn drainBody(request: *std.http.Server.Request) !void {
    var buffer: [256]u8 = undefined;
    const reader = try request.readerExpectContinue(&buffer);
    // With no body headers the reader is the raw connection: don't read it.
    if (hasBody(request)) _ = reader.discardRemaining() catch return error.ReadFailed;
}
