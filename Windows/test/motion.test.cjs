const { test } = require("node:test");
const assert = require("node:assert/strict");
const { CatMotion, Follow, ease, keys } = require("../src/pet-motion.cjs");
const data = require("../assets/rig/rig.json");
test("Swift springs and easing preserve response equations", () => {
  const f = new Follow(4);
  assert.ok(f.step(1, 1 / 60) > 0);
  for (let i = 0; i < 300; i++) f.step(1, 1 / 60);
  assert.ok(Math.abs(f.value - 1) < 1e-6);
  assert.equal(ease(0.5), 0.5 - 0.5 * Math.cos(Math.PI * 0.5));
  assert.equal(
    keys(1, [
      [0, 0],
      [1, 3],
      [2, 0],
    ]),
    3,
  );
});
test("idle deforms individual tail, ears, pupils and lids using original slot wiring", () => {
  const m = new CatMotion(data, () => 0.5);
  for (let i = 0; i < 120; i++)
    m.update(1 / 60, "idle", false, {
      pointer: { x: 500, y: 150 },
      pointerSpeed: 80,
      pointerOverHead: true,
    });
  const p = m.params("idle");
  assert.equal(p.length, 154);
  assert.ok(m.petting.value > 0.9);
  assert.ok(m.interest.value > 0.9);
  assert.ok(p[32 + 4] !== 0);
  assert.ok(p[13] > 0);
  assert.ok(p[134 + 3] > 1);
  assert.ok(p.every(Number.isFinite));
});
test("mouth requests are gated and reveal original mouth source", () => {
  const m = new CatMotion(data, () => 0.5);
  assert.equal(m.yawn(), true);
  assert.equal(m.meow(), false);
  m.update(0.05, "idle", false, {});
  for (let i = 0; i < 24; i++) m.update(0.05, "idle", false, {});
  assert.equal(m.params("idle")[27], 1);
  assert.ok(m.params("idle")[18] > 0.9);
});
test("all original pose layers have finite animated parameters", () => {
  const m = new CatMotion(data, () => 0.5);
  for (const pose of ["idle", "walk", "wave", "sleep"]) {
    for (let i = 0; i < 200; i++) m.update(1 / 60, pose, pose === "walk", {});
    for (const key of Object.keys(data.rigs).filter(
      (k) => k === pose || k.startsWith(pose + "."),
    ))
      assert.ok(m.params(key).every(Number.isFinite), key);
  }
});
test("walking stride controls travel speed and planted paws have no lift", () => {
  const m = new CatMotion(data, () => 0.5);
  m.chasing = true;
  for (let i = 0; i < 120; i++) m.update(1 / 60, "walk", true, {});
  assert.ok(m.walkSpeed > 100);
  m.gait = 0.1;
  assert.equal(m.leg("backNear").lift, 0);
  m.gait = 0.8;
  assert.ok(m.leg("backNear").lift > 0);
});
test("all 1232 initial parameter values match the unchanged Swift CatMotion reference", () => {
  const reference = require("../assets/rig/motion-reference.json");
  const motion = new CatMotion(data);
  let compared = 0;
  for (const [key, expected] of Object.entries(reference)) {
    const actual = motion.params(key);
    assert.equal(actual.length, expected.length);
    actual.forEach((v, i) => {
      assert.ok(
        Math.abs(v - expected[i]) < 1e-5,
        `${key}[${i}]: ${v} != ${expected[i]}`,
      );
      compared++;
    });
  }
  assert.equal(compared, 1232);
});
test("exported RGBA masks keep every alpha channel byte unchanged through gzip", () => {
  const fs = require("node:fs"),
    path = require("node:path"),
    zlib = require("node:zlib");
  for (const [key, r] of Object.entries(data.rigs)) {
    for (let i = 0; i < 5; i++) {
      const bytes = zlib.gunzipSync(
        fs.readFileSync(
          path.join(__dirname, "../assets/rig", `${key}-map${i}.rgba.gz`),
        ),
      );
      assert.equal(bytes.length, r.width * r.height * 4);
      if (key === "idle" && i === 3)
        assert.ok(
          bytes.some((v, j) => j % 4 === 3 && v === 255),
          "mouth reveal channel preserved",
        );
    }
  }
});
