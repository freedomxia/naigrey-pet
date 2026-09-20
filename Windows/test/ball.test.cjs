const { test } = require("node:test");
const assert = require("node:assert/strict");
const { YarnBall } = require("../src/pet-ball.cjs");
test("ball uses Swift gravity, restitution and rolling friction in downward screen coordinates", () => {
  const b = new YarnBall({ radius: 10, x: 100, y: 50 });
  b.kick(100, 0);
  b.step(0.1, 100, [0, 300]);
  assert.equal(b.y, 65);
  assert.equal(b.vy, 150);
  b.step(0.1, 100, [0, 300]);
  assert.equal(b.y, 90);
  assert.equal(b.vy, -126);
});
test("held ball does not simulate, wall bounce loses forty percent speed", () => {
  const b = new YarnBall({ radius: 10, x: 280, y: 50 });
  b.kick(200, 0);
  b.step(0.1, 100, [0, 300]);
  assert.equal(b.x, 290);
  assert.equal(b.vx, -120);
  b.held = true;
  const y = b.y;
  b.step(0.2, 100, [0, 300]);
  assert.equal(b.y, y);
});
test("drag fling samples only last tenth of second and limits speed to 1400", () => {
  const b = new YarnBall({ radius: 10, x: 20, y: 30 });
  b.grab(20, 30, 0);
  b.drag(120, 30, 0.05);
  b.release(220, 30, 0.1);
  assert.equal(b.held, false);
  assert.equal(b.speed, 1400);
});
