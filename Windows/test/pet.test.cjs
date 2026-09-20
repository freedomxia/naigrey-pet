const { test } = require("node:test");
const assert = require("node:assert/strict");
const {
  actionPath,
  clampPosition,
  panelPosition,
  clipRect,
} = require("../src/pet-model.cjs");
test("sleep exits through wake before wave, typing uses its entrance and exit", () => {
  assert.deepEqual(actionPath("sleep", "wave"), ["wake", "wave", "idle"]);
  assert.deepEqual(actionPath("idle", "type"), [
    "typeIn",
    "type",
    "typeOut",
    "idle",
  ]);
  assert.deepEqual(actionPath("sleep", "sleep"), []);
  assert.deepEqual(actionPath("idle", "sleep"), ["lieDown", "sleep"]);
});
test("unknown requests cannot address arbitrary files", () => {
  assert.deepEqual(actionPath("idle", "../../secret"), []);
});
test("saved offscreen cat returns to available desktop even with negative monitor coordinates", () => {
  assert.deepEqual(
    clampPosition(
      { x: 3000, y: 900 },
      { width: 300, height: 260 },
      { x: -1920, y: 0, width: 1920, height: 1040 },
    ),
    { x: -300, y: 780 },
  );
});
test("panel normally below cat and moves above when bottom has no space", () => {
  assert.deepEqual(
    panelPosition(
      { x: 100, y: 100, width: 300, height: 260 },
      { x: 0, y: 0, width: 1920, height: 1080 },
    ),
    { x: 70, y: 366 },
  );
  assert.deepEqual(
    panelPosition(
      { x: 1800, y: 800, width: 300, height: 260 },
      { x: 0, y: 0, width: 1920, height: 1080 },
    ),
    { x: 1560, y: 564 },
  );
});
test("different video frame sizes align by paw anchor on same ground", () => {
  const r = clipRect(
    { size: [516, 496], start: [260.8, 485], end: [260.8, 483] },
    0,
    441,
    160,
    150,
    245,
  );
  assert.ok(Math.abs(r.x + (260.8 * 160) / 441 - 150) < 0.001);
  assert.ok(Math.abs(r.y + (485 * 160) / 441 - 245) < 0.001);
});
test("walking distance uses elapsed time and caps stalls to prevent teleporting", () => {
  const { walkDistance } = require("../src/pet-model.cjs");
  assert.equal(walkDistance(16, 300, 0.5), 2.4);
  assert.equal(walkDistance(3000, 300, 0.5), 7.5);
  assert.equal(walkDistance(-1, 300, 0.5), 0);
});
test("sleep re-request during lie-down does not terminate the sleeping loop", () => {
  const { sleepContinuation } = require("../src/pet-model.cjs");
  assert.equal(sleepContinuation("sleep"), null);
  assert.equal(sleepContinuation(null), null);
  assert.equal(sleepContinuation("wave"), "wave");
});
test("high-refresh walking preserves subpixel distance until window positioning", () => {
  const { advanceWalk } = require("../src/pet-model.cjs");
  let x = 500;
  for (let i = 0; i < 240; i++)
    x = advanceWalk(x, -0.4, 360, { x: 0, width: 1920 });
  assert.ok(Math.abs(x - 404) < 0.001);
  assert.equal(advanceWalk(1, -4, 360, { x: 0, width: 1920 }), 0);
});
test("all shipped action frames fit the transparent window at both transition anchors", () => {
  const { clips, sitHeight } = require("../assets/clips/clips.json");
  for (const c of clips)
    for (const t of [0, 1]) {
      const r = clipRect(c, t, sitHeight, 140, 210, 247);
      assert.ok(
        r.x >= 0 && r.x + r.width <= 420,
        `${c.name} horizontal clipping`,
      );
      assert.ok(
        r.y >= 0 && r.y + r.height <= 260,
        `${c.name} vertical clipping`,
      );
    }
});
test("idle companion greets without clicks then autonomously chooses a full action", () => {
  const { IdleCompanion } = require("../src/pet-model.cjs");
  const idle = new IdleCompanion(() => 0.22);
  assert.equal(idle.tick({ now: 0, pose: "idle" }), null);
  assert.equal(idle.tick({ now: 5000, pose: "idle" }), "wave");
  assert.equal(idle.tick({ now: 18000, pose: "idle" }), "stretch");
});
test("autonomous actions never interrupt dragging, manual sleep or an active clip", () => {
  const { IdleCompanion } = require("../src/pet-model.cjs");
  const idle = new IdleCompanion(() => 0.3);
  for (const state of [
    { busy: true },
    { dragging: true },
    { pose: "sleep" },
    { enabled: false },
  ])
    assert.equal(idle.tick({ now: 6000, pose: "idle", ...state }), null);
});
test("an autonomous nap wakes up but a manually chosen sleep stays asleep", () => {
  const { IdleCompanion } = require("../src/pet-model.cjs");
  const idle = new IdleCompanion(() => 0.38);
  idle.tick({ now: 5000, pose: "idle" });
  assert.equal(idle.tick({ now: 20000, pose: "idle" }), "sleep");
  assert.equal(idle.tick({ now: 51000, pose: "sleep", busy: true }), "idle");
  idle.interact(52000);
  assert.equal(idle.tick({ now: 90000, pose: "sleep", busy: true }), null);
});
test("clip travel respects the exact stand-up and sit-down movement windows", () => {
  const { clipMoving } = require("../src/pet-model.cjs");
  const { clips } = require("../assets/clips/clips.json");
  for (const c of clips.filter((c) => c.moveFrom > 0)) {
    assert.equal(clipMoving(c, c.moveFrom - 0.001), false, c.name);
    assert.equal(clipMoving(c, c.moveFrom + 0.001), true, c.name);
  }
  for (const c of clips.filter((c) => c.moveTo != null))
    assert.equal(clipMoving(c, c.moveTo + 0.001), false, c.name);
});
test("Mac autonomous roll meows, becomes drowsy at night, and stays still during typing", () => {
  const { IdleCompanion } = require("../src/pet-model.cjs");
  const m = new IdleCompanion(() => 0.12);
  m.greeted = true;
  assert.equal(m.tick({ now: 5000, pose: "idle", hour: 12 }), "meow");
  assert.equal(m.tick({ now: 20000, pose: "idle", hour: 23 }), "yawn");
  assert.equal(m.tick({ now: 40000, pose: "idle", typing: true }), null);
});
test("company repeats without four-loop cutoff and exits cleanly on changed state", () => {
  const { repeatClip } = require("../src/pet-model.cjs");
  assert.equal(
    repeatClip({
      name: "type",
      completed: 100,
      loops: 4,
      continuous: true,
      company: "type",
    }),
    true,
  );
  assert.equal(
    repeatClip({
      name: "type",
      completed: 1,
      loops: 4,
      continuous: true,
      company: "music",
    }),
    false,
  );
  assert.equal(
    repeatClip({
      name: "type",
      completed: 1,
      loops: 4,
      continuous: true,
      company: "type",
      pending: "sleep",
    }),
    false,
  );
});
test("play hands the yarn ball to the native window at the last video position and signed velocity", () => {
  const { clipBallHandOff } = require("../src/pet-model.cjs");
  const { clips, sitHeight } = require("../assets/clips/clips.json");
  const clip = clips.find((c) => c.name === "play");
  const a = clipBallHandOff(clip, sitHeight, 140, 210, 247, false),
    b = clipBallHandOff(clip, sitHeight, 140, 210, 247, true);
  assert.ok(a);
  assert.equal(a.point.x + b.point.x, 420);
  assert.equal(a.velocity.x, -b.velocity.x);
  assert.equal(a.point.y, b.point.y);
});
test("logical viewport includes headroom for largest 170px action", () => {
  const { WINDOW_HEIGHT, GROUND } = require("../src/pet-model.cjs");
  assert.equal(WINDOW_HEIGHT, 320);
  assert.equal(GROUND, 307);
});
test("all decoded visible action pixels fit both orientations at every supported size", () => {
  const {
    WINDOW_WIDTH,
    WINDOW_HEIGHT,
    CENTER_X,
    GROUND,
  } = require("../src/pet-model.cjs");
  const { clips, sitHeight } = require("../assets/clips/clips.json");
  const alpha = require("./fixtures/clip-alpha-bounds.json").clips;
  for (const height of [72, 100, 130, 140, 170])
    for (const c of clips)
      for (const t of [0, 1]) {
        const r = clipRect(c, t, sitHeight, height, CENTER_X, GROUND),
          s = height / sitHeight,
          b = alpha[c.name].bounds;
        assert.ok(r.y + b[1] * s >= 0, `${c.name} ${height} top`);
        assert.ok(
          r.y + b[3] * s <= WINDOW_HEIGHT,
          `${c.name} ${height} bottom`,
        );
        const left = r.x + b[0] * s,
          right = r.x + b[2] * s;
        for (const mirrored of [false, true]) {
          assert.ok(
            (mirrored ? WINDOW_WIDTH - right : left) >= 0,
            `${c.name} ${height} left`,
          );
          assert.ok(
            (mirrored ? WINDOW_WIDTH - left : right) <= WINDOW_WIDTH,
            `${c.name} ${height} right`,
          );
        }
      }
});
test('decoded alpha-bound fixture belongs to the exact shipped video bytes',()=>{const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');for(const [name,evidence]of Object.entries(require('./fixtures/clip-alpha-bounds.json').clips)){const bytes=fs.readFileSync(path.join(__dirname,'../assets/clips',name+'.webm'));assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'),evidence.sha256,`${name}: regenerate alpha bounds after replacing media`);assert.ok(evidence.frames>1);}});
