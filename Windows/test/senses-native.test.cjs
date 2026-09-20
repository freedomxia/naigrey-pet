const { test } = require("node:test");
const assert = require("node:assert/strict");
const { EventEmitter } = require("node:events");
const { PassThrough } = require("node:stream");
const { NativeSenses } = require("../src/senses.cjs");
function transport(t) {
  const child = new EventEmitter();
  child.stdout = new PassThrough();
  child.stdin = new PassThrough();
  child.kill = () => {};
  let clock = 0;
  const s = new NativeSenses({
    platform: "win32",
    spawnImpl: () => child,
    now: () => clock,
  });
  s.start();
  t.after(() => s.stop());
  return {
    s,
    child,
    setTime: (time) => (clock = time),
    send: (value) => child.stdout.write(JSON.stringify(value) + "\n"),
  };
}
test("helper messages are normalized and unknown private fields never escape", async (t) => {
  const { s, send, setTime } = transport(t);
  send({
    type: "senses",
    keyboardAvailable: true,
    keyAge: null,
    audioActive: true,
    keys: "PRIVATE",
  });
  setTime(8000);
  send({
    type: "senses",
    keyboardAvailable: true,
    keyAge: 0.1,
    audioActive: true,
    keys: "PRIVATE",
  });
  assert.equal(s.snapshot().music, true);
  assert(!JSON.stringify(s.snapshot()).includes("PRIVATE"));
  send({
    type: "senses",
    keyboardAvailable: false,
    keyAge: 0.1,
    audioActive: null,
  });
  assert.equal(s.snapshot().status, "partial");
  assert.equal(s.snapshot().music, false);
});
test("process identity RPC is bounded, validated and pending requests resolve on stop", async (t) => {
  const { s, child, send } = transport(t);
  let request;
  child.stdin.on("data", (data) => (request = JSON.parse(data)));
  const p = s.processStart(23);
  send({ id: request.id, startedAt: 1700000000000 });
  assert.equal(await p, 1700000000000);
  assert.equal(await s.processStart(-1), null);
  const pending = s.processStart(99);
  s.stop();
  assert.equal(await pending, null);
});
test("native helper exit clears active sensed state", (t) => {
  const { s, child, send, setTime } = transport(t);
  send({
    type: "senses",
    keyboardAvailable: true,
    keyAge: 1,
    audioActive: true,
  });
  setTime(8000);
  send({
    type: "senses",
    keyboardAvailable: true,
    keyAge: 1,
    audioActive: true,
  });
  assert.equal(s.snapshot().music, true);
  child.emit("exit", 1);
  assert.equal(s.snapshot().status, "unavailable");
  assert.equal(s.snapshot().music, false);
});
