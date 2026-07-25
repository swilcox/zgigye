// WebAssembly transport: the interpreter runs in the browser, so a turn is
// a function call rather than a round trip and nothing leaves the client.
//
// The call boundary only carries numbers, so strings cross as (pointer,
// length) pairs into the module's linear memory. Always re-read
// `memory.buffer` after a call: growing the heap detaches the old
// ArrayBuffer, and a view taken before the call would then be empty.
//
// See transport_http.js for the same interface backed by a server, and
// wasm.zig for the exports used here.
"use strict";

const Transport = (() => {
  // Served alongside this page and the .wasm module.
  const STORY_URL = "zork1.z3";

  let wasm = null;
  const enc = new TextEncoder();
  const dec = new TextDecoder();
  const mem = () => new Uint8Array(wasm.memory.buffer);

  function copyIn(bytes) {              // -> { ptr, len }; caller frees
    const ptr = wasm.alloc(bytes.length);
    if (!ptr) throw new Error("wasm alloc failed");
    mem().set(bytes, ptr);
    return { ptr, len: bytes.length };
  }

  function readResult(ptr) {            // the JSON the last call returned
    const len = wasm.resultLen();
    return JSON.parse(dec.decode(mem().subarray(ptr, ptr + len)));
  }

  return {
    async init() {
      // Plain instantiate (not Streaming) so it works regardless of whether
      // the static server labels .wasm as application/wasm.
      const bytes = await (await fetch("zgigye.wasm")).arrayBuffer();
      const { instance } = await WebAssembly.instantiate(bytes, {});
      wasm = instance.exports;

      const story = new Uint8Array(await (await fetch(STORY_URL)).arrayBuffer());
      const s = copyIn(story);
      const ok = wasm.setStory(s.ptr, s.len);
      wasm.dealloc(s.ptr, s.len);
      if (!ok) throw new Error("setStory failed");
    },

    async start() {
      return readResult(wasm.start());
    },

    async advance(state, command) {
      const s = copyIn(enc.encode(state));
      const i = copyIn(enc.encode(command));
      const turn = readResult(wasm.advance(s.ptr, s.len, i.ptr, i.len));
      wasm.dealloc(s.ptr, s.len);
      wasm.dealloc(i.ptr, i.len);
      return turn;
    },
  };
})();
