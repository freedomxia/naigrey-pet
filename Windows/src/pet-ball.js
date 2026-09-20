"use strict";
const api = window.naigrey,
  canvas = document.querySelector("#yarn"),
  ctx = canvas.getContext("2d");
let radius = 13;
function render(s) {
  const b = s.ball;
  if (!b) return;
  radius = b.radius;
  const size = Math.ceil(radius * 2 + 6),
    ratio = window.devicePixelRatio || 1;
  canvas.width = Math.ceil(size * ratio);
  canvas.height = Math.ceil(size * ratio);
  canvas.style.width = size + "px";
  canvas.style.height = size + "px";
  ctx.scale(ratio, ratio);
  ctx.translate(3, 3);
  window.PetBall.drawYarn(ctx, radius, b.spin);
}
api.on("state", render);
api.bootstrap().then(render);
let held = false;
canvas.addEventListener("pointerdown", (e) => {
  if (e.button !== 0) return;
  held = true;
  canvas.setPointerCapture(e.pointerId);
  api.command("ball-grab", { x: e.screenX, y: e.screenY });
});
canvas.addEventListener("pointermove", (e) => {
  if (held) api.command("ball-move", { x: e.screenX, y: e.screenY });
});
function release(e) {
  if (!held) return;
  held = false;
  api.command("ball-release", { x: e.screenX, y: e.screenY });
}
canvas.addEventListener("pointerup", release);
canvas.addEventListener("pointercancel", release);
