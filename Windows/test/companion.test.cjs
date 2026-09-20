const { test } = require("node:test");
const assert = require("node:assert/strict");
const { Companion, dayKey } = require("../src/companion.cjs");
const noon = new Date(2026, 8, 20, 13),
  night = new Date(2026, 8, 20, 23);
function tick(c, patch = {}) {
  return c.tick({
    now: 1000,
    date: noon,
    idleSeconds: 0,
    senses: {},
    prefs: { autonomous: false },
    phase: "idle",
    ...patch,
  });
}
test("routine strict idle yawn and sleep thresholds day and night", () => {
  for (const [date, yawn, sleep] of [
    [noon, 90, 240],
    [night, 40, 100],
  ]) {
    const c = new Companion({ now: 0 });
    assert.equal(tick(c, { date, idleSeconds: yawn }).action, undefined);
    assert.equal(tick(c, { date, idleSeconds: yawn + 0.01 }).action, "yawn");
    assert.equal(tick(c, { date, idleSeconds: sleep }).action, undefined);
    assert.equal(tick(c, { date, idleSeconds: sleep + 0.01 }).action, "sleep");
    assert.equal(c.autoSlept, true);
  }
});
test("automatic sleep wakes below 1.5 seconds; manual sleep never wakes for activity", () => {
  const c = new Companion({ now: 0 });
  tick(c, { idleSeconds: 241 });
  tick(c, { idleSeconds: 242, now: 2000 });
  assert.equal(tick(c, { idleSeconds: 1.5, phase: "sleep" }).action, undefined);
  assert.equal(tick(c, { idleSeconds: 1.49, phase: "sleep" }).action, "idle");
  c.manual("sleep", 3000);
  assert.equal(
    tick(c, { idleSeconds: 0, phase: "sleep", now: 4000 }).action,
    undefined,
  );
});
test("lock respects routine and manual sleep, unlock wakes only auto sleep", () => {
  const c = new Companion({ now: 0 });
  assert.equal(c.locked(100, { routine: false }).action, undefined);
  assert.equal(c.locked(100, { routine: true }).action, "sleep");
  assert.equal(c.unlocked(200, noon).action, "idle");
  c.manual("sleep", 300);
  assert.equal(c.locked(400, { routine: true }).action, undefined);
  assert.equal(c.unlocked(500, noon).action, undefined);
});
test("break reminder requires over 50 active minutes and over 25 minutes cooldown", () => {
  const c = new Companion({ now: 0 });
  assert.equal(tick(c, { now: 3000000 }).action, undefined);
  assert.equal(tick(c, { now: 3000001 }).action, "stretch");
  assert.equal(tick(c, { now: 4500001 }).action, undefined);
  assert.equal(tick(c, { now: 4500002 }).action, "stretch");
  tick(c, { now: 4600000, idleSeconds: 301 });
  assert.equal(tick(c, { now: 6000000 }).action, undefined);
});
test("day once state rolls at 6am and persists greetings across restart", () => {
  const date = new Date(2026, 8, 20, 5, 59);
  assert.equal(dayKey(date), "2026-09-19");
  assert.equal(dayKey(new Date(2026, 8, 20, 6)), "2026-09-20");
  const onceState = {};
  const c = new Companion({ now: 0, onceState });
  assert.equal(tick(c, { date: new Date(2026, 8, 20, 8) }).action, "stretch");
  const second = new Companion({ now: 0, onceState });
  assert.equal(
    tick(second, { date: new Date(2026, 8, 20, 9) }).action,
    undefined,
  );
  assert.equal(
    tick(second, { date: new Date(2026, 8, 21, 8) }).action,
    "stretch",
  );
});
test("company typing wins over music, rate follows senses, transitions wait for idle", () => {
  const c = new Companion({ now: 0 });
  let s = tick(c, { senses: { typing: true, music: true, typingRate: 1.3 } });
  assert.equal(s.company, "typing");
  assert.equal(s.action, "type");
  assert.equal(s.typeRate, 1.3);
  s = tick(c, { phase: "type", senses: { music: true } });
  assert.equal(s.company, "none");
  assert.equal(s.action, undefined);
  s = tick(c, { phase: "idle", senses: { music: true } });
  assert.equal(s.company, "music");
  assert.equal(s.action, "music");
  assert.equal(
    tick(c, { phase: "music", playing: true, senses: { music: true } }).company,
    "none",
  );
});
test("company and routine never interrupt active clips or dragging", () => {
  const c = new Companion({ now: 0 });
  assert.equal(
    tick(c, { phase: "wave", idleSeconds: 400, senses: { typing: true } })
      .action,
    undefined,
  );
  assert.equal(
    tick(c, { dragging: true, idleSeconds: 400, senses: { music: true } })
      .action,
    undefined,
  );
  assert.equal(
    tick(c, { idleSeconds: 201, senses: { typing: true } }).company,
    "none",
  );
});
test("unknown system idle facts never synthesize absence or automatic sleep", () => {
  const c = new Companion({ now: 0 });
  assert.equal(tick(c, { idleSeconds: null }).action, undefined);
  assert.equal(tick(c, { idleSeconds: NaN }).action, undefined);
});
test("autonomous Mac probabilities use meow and key age suppresses large choices", () => {
  const c = new Companion({ now: 0, random: () => 0.12 });
  assert.equal(
    tick(c, { now: 6000, prefs: { routine: false }, senses: { keyAge: 3.99 } })
      .action,
    undefined,
  );
  assert.equal(
    tick(c, { now: 30000, prefs: { routine: false }, senses: { keyAge: 4 } })
      .action,
    "meow",
  );
  assert.equal(
    tick(c, { now: 60000, date: night, prefs: { routine: false } }).action,
    "yawn",
  );
});
test("autonomous nap has a deadline but manual sleep clears it", () => {
  const c = new Companion({ now: 0, random: () => 0.38 });
  assert.equal(
    tick(c, { now: 6000, prefs: { routine: false } }).action,
    "sleep",
  );
  assert.ok(c.napUntil > 6000);
  assert.equal(
    tick(c, { now: c.napUntil, phase: "sleep", prefs: { routine: false } })
      .action,
    "idle",
  );
  c.manual("sleep", 50000);
  assert.equal(c.napUntil, null);
});
test("stale renderer sleep acknowledgement after wake does not turn into manual sleep", () => {
  const c = new Companion({ now: 0 });
  c.locked(0, { routine: true });
  assert.equal(tick(c, { phase: "sleep", idleSeconds: 1 }).action, "idle");
  assert.equal(
    tick(c, { phase: "sleep", idleSeconds: 1, now: 1100 }).action,
    undefined,
  );
  assert.equal(c.sleeping, false);
  tick(c, { phase: "wake", now: 1200 });
  tick(c, { phase: "idle", now: 1300 });
  assert.equal(c.autoSlept, false);
});
test("roaming disabled suppresses walking and keeps the Mac nap fallthrough", () => {
  const c = new Companion({ now: 0, random: () => 0.3 });
  assert.equal(
    tick(c, { now: 6000, prefs: { routine: false, roaming: false } }).action,
    "sleep",
  );
});
test("greetings honor exact clock ranges and 20 second idle guard", () => {
  for (const [h, m, action] of [
    [11, 44, undefined],
    [11, 45, "wave"],
    [12, 59, "wave"],
    [18, 0, "wave"],
    [20, 0, undefined],
    [23, 0, "yawn"],
  ]) {
    const c = new Companion({ now: 0 });
    assert.equal(
      tick(c, { date: new Date(2026, 8, 20, h, m) }).action,
      action,
      `${h}:${m}`,
    );
  }
  const c = new Companion({ now: 0 });
  assert.equal(
    tick(c, { date: new Date(2026, 8, 20, 8), idleSeconds: 20 }).action,
    undefined,
  );
  assert.equal(
    tick(c, { date: new Date(2026, 8, 20, 8), idleSeconds: 19.99 }).action,
    "stretch",
  );
});
test("a failed/cancelled lie-down returning to idle clears scheduled sleep", () => {
  const c = new Companion({ now: 0 });
  c.locked(0, { routine: true });
  tick(c, { phase: "lieDown", idleSeconds: 300 });
  tick(c, { phase: "idle", idleSeconds: 0 });
  assert.equal(c.sleeping, false);
});
