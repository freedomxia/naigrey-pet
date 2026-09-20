const { test } = require("node:test");
const assert = require("node:assert/strict");
const { TypingWatch, AudioWatch, NativeSenses } = require("../src/senses.cjs");
test("typing requires eight observed beats over 2.5 seconds and ends after two seconds", () => {
  const w = new TypingWatch();
  assert.equal(w.update(0, 0).typing, false);
  for (let i = 1; i <= 8; i++) {
    w.update(i * 0.4 - 0.1, 0.3);
    w.update(i * 0.4, 0);
  }
  assert.equal(w.snapshot().typing, true);
  assert.ok(w.snapshot().typingRate >= 0.7);
  assert.equal(w.update(5.3, 2.1).typing, false);
  assert.equal(w.update(10, null).typing, false);
});
test("audio ignores short beeps and tolerates pauses shorter than four seconds", () => {
  const w = new AudioWatch();
  assert.equal(w.update(0, true), false);
  assert.equal(w.update(7, true), false);
  assert.equal(w.update(8, true), true);
  assert.equal(w.update(11, false), true);
  assert.equal(w.update(12, false), false);
  assert.equal(w.update(20, true), false);
  assert.equal(w.update(21, false), false);
  assert.equal(w.update(28, true), false);
});
test("unsupported native source is explicit and never fabricates typing or audio", async () => {
  const s = new NativeSenses({ platform: "darwin" });
  s.start();
  assert.equal(s.snapshot().status, "unsupported");
  assert.equal(s.snapshot().typing, false);
  assert.equal(await s.processStart(1), null);
  s.stop();
});
