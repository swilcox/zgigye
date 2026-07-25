// HTTP transport: one request per game turn, served by `zig build serve`.
//
// The server is stateless — each turn's reply carries the machine-state blob
// and the next request hands it straight back — so there is nothing to set
// up and `init` resolves immediately.
//
// See transport_wasm.js for the same interface backed by a WebAssembly
// module, and turn_json.zig for the JSON both of them return.
"use strict";

const Transport = (() => {
  async function post(url, body) {
    const res = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: body ? JSON.stringify(body) : null,
    });
    // Reported like any other failure, so the page has one error path.
    if (!res.ok) return { error: await res.text() };
    return res.json();
  }

  return {
    async init() {},
    async start() {
      return post("/new", null);
    },
    async advance(state, command) {
      return post("/turn", { state, input: command });
    },
  };
})();
