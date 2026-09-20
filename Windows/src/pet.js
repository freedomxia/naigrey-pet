"use strict";
const api = window.naigrey,
  canvas = document.querySelector("#cat"),
  ctx = canvas.getContext("2d", { willReadFrequently: true });
const { actionPath, clipRect, walkDistance, sleepContinuation, IdleCompanion } =
  window.PetModel;
const companion = new IdleCompanion();
let renderedFrames = 0,
  smokeMode = false;
const clips = new Map(),
  videos = new Map();
let lastDraw = 0,
  atlas,
  metadata,
  pose = "idle",
  active = null,
  busy = false,
  pending = null,
  fade = null,
  fadeAt = 0,
  blinkAt = performance.now() + 4500,
  pointer = null,
  clickTimer,
  bubbleTimer,
  ready = false;
let prefs = { motion: true },
  lastHit = true;
const CAT_HEIGHT = 140,
  GROUND = 247;
function bubble(text) {
  const el = document.querySelector("#bubble");
  el.textContent = text;
  el.classList.add("visible");
  clearTimeout(bubbleTimer);
  bubbleTimer = setTimeout(() => el.classList.remove("visible"), 4500);
}
function trim(source, x, y, w, h) {
  const c = document.createElement("canvas");
  c.width = w;
  c.height = h;
  const g = c.getContext("2d", { willReadFrequently: true });
  g.drawImage(source, x, y, w, h, 0, 0, w, h);
  const d = g.getImageData(0, 0, w, h).data;
  let l = w,
    t = h,
    r = 0,
    b = 0;
  for (let j = 0; j < h; j++)
    for (let i = 0; i < w; i++)
      if (d[(j * w + i) * 4 + 3] > 24) {
        l = Math.min(l, i);
        r = Math.max(r, i);
        t = Math.min(t, j);
        b = Math.max(b, j);
      }
  const out = document.createElement("canvas");
  out.width = r - l + 1;
  out.height = b - t + 1;
  out
    .getContext("2d")
    .drawImage(c, l, t, out.width, out.height, 0, 0, out.width, out.height);
  return out;
}
let idleSprite, blinkSprite;
function freeze() {
  const c = document.createElement("canvas");
  c.width = 840;
  c.height = 520;
  c.getContext("2d").drawImage(canvas, 0, 0);
  fade = c;
  fadeAt = performance.now();
}
function videoReady(v) {
  return new Promise((resolve, reject) => {
    if (v.readyState >= 2) return resolve();
    const timeout = setTimeout(() => finish(new Error("视频加载超时")), 15000);
    const ok = () => finish(),
      bad = () => finish(new Error("视频无法解码"));
    function finish(err) {
      clearTimeout(timeout);
      v.removeEventListener("loadeddata", ok);
      v.removeEventListener("error", bad);
      err ? reject(err) : resolve();
    }
    v.addEventListener("loadeddata", ok, { once: true });
    v.addEventListener("error", bad, { once: true });
    v.load();
  });
}
function getVideo(name) {
  if (videos.has(name)) return videos.get(name);
  const clip = clips.get(name);
  if (!clip) throw new Error("缺少动作 " + name);
  const v = document.createElement("video");
  v.muted = true;
  v.playsInline = true;
  v.preload = "auto";
  v.src = "../assets/clips/" + clip.file;
  videos.set(name, v);
  return v;
}
async function playClip(name, loops = 1) {
  const video = getVideo(name);
  await videoReady(video);
  video.currentTime = 0;
  freeze();
  active = { name, video, clip: clips.get(name) };
  api.command("phase", name);
  let n = 0;
  await new Promise((resolve, reject) => {
    const onEnd = () => {
      n++;
      if (n < loops && !pending) {
        video.currentTime = 0;
        video.play().catch(fail);
      } else done();
    };
    function cleanup() {
      video.removeEventListener("ended", onEnd);
      video.removeEventListener("error", fail);
    }
    function done() {
      cleanup();
      resolve();
    }
    function fail() {
      cleanup();
      reject(new Error("播放失败"));
    }
    video.addEventListener("ended", onEnd);
    video.addEventListener("error", fail, { once: true });
    video.play().catch(fail);
  });
}
async function requestAction(action, autonomous = false) {
  if (!autonomous) companion.interact(performance.now());
  if (!ready) return;
  if (action === "sleep" && pose === "sleep") return;
  if (busy) {
    pending = action;
    return;
  }
  const path = actionPath(pose, action);
  if (!path.length) return;
  busy = true;
  pending = null;
  try {
    for (let i = 0; i < path.length; i++) {
      const name = path[i],
        next = path[i + 1];
      if (next && next !== "idle") videoReady(getVideo(next)).catch(() => {});
      if (name === "idle") {
        freeze();
        active = null;
        api.command("phase", "idle");
        pose = "idle";
        continue;
      }
      if (name === "sleep") {
        pose = "sleep";
        do {
          await playClip(name);
          pending = sleepContinuation(pending);
        } while (!pending);
        break;
      }
      await playClip(name, ["type", "music", "walk"].includes(name) ? 4 : 1);
    }
    if (action !== "sleep") pose = "idle";
  } catch {
    active = null;
    pose = "idle";
    bubble("这个动作暂时无法播放，请检查素材是否完整。");
  } finally {
    busy = false;
    const next = pending;
    pending = null;
    if (next) requestAction(next);
  }
}
function draw(now) {
  renderedFrames++;
  ctx.setTransform(2, 0, 0, 2, 0, 0);
  ctx.clearRect(0, 0, 420, 260);
  if (active && active.video.readyState >= 2) {
    const c = active.clip;
    const rect = clipRect(
      c,
      active.video.currentTime / c.duration,
      metadata.sitHeight,
      CAT_HEIGHT,
      210,
      GROUND,
    );
    ctx.drawImage(active.video, rect.x, rect.y, rect.width, rect.height);
  } else if (idleSprite) {
    const breath = prefs.motion ? 1 + Math.sin(now / 1100) * 0.007 : 1;
    const h = CAT_HEIGHT * breath,
      w = (idleSprite.width / idleSprite.height) * CAT_HEIGHT;
    ctx.drawImage(idleSprite, 210 - w / 2, GROUND - h, w, h);
    if (now > blinkAt && now < blinkAt + 240) {
      const opacity = Math.sin(((now - blinkAt) / 240) * Math.PI);
      ctx.globalAlpha = opacity;
      const bw = (blinkSprite.width / blinkSprite.height) * h;
      ctx.drawImage(blinkSprite, 210 - bw / 2 + 1, GROUND - h, bw, h);
      ctx.globalAlpha = 1;
    } else if (now >= blinkAt + 240)
      blinkAt = now + 3500 + Math.random() * 3000;
  }
  if (fade) {
    const a = 1 - (now - fadeAt) / 120;
    if (a > 0) {
      ctx.globalAlpha = a;
      ctx.drawImage(fade, 0, 0, 420, 260);
      ctx.globalAlpha = 1;
    } else fade = null;
  }
  if (active?.name === "walk" && !active.video.paused && lastDraw)
    api.command(
      "walk-step",
      -walkDistance(
        now - lastDraw,
        active.clip.speed || 307.2,
        CAT_HEIGHT / metadata.sitHeight,
      ),
    );
  if (!smokeMode) {
    const chosen = companion.tick({
      now,
      pose,
      busy,
      dragging: !!pointer,
      enabled: prefs.autonomous !== false,
    });
    if (chosen) requestAction(chosen, true);
  }
  lastDraw = now;
  requestAnimationFrame(draw);
}
function hit(e) {
  const x = Math.floor(e.clientX * 2),
    y = Math.floor(e.clientY * 2);
  return (
    x >= 0 &&
    y >= 0 &&
    x < 840 &&
    y < 520 &&
    ctx.getImageData(x, y, 1, 1).data[3] > 35
  );
}
canvas.addEventListener("pointerdown", (e) => {
  if (e.button !== 0 || !hit(e)) return;
  pointer = { x: e.screenX, y: e.screenY, moved: false };
  canvas.setPointerCapture(e.pointerId);
});
canvas.addEventListener("pointermove", (e) => {
  if (pointer) {
    if (
      !pointer.moved &&
      Math.hypot(e.screenX - pointer.x, e.screenY - pointer.y) > 5
    ) {
      pointer.moved = true;
      api.command("drag-start");
    }
    if (pointer.moved) api.command("drag-move");
  } else {
    const h = hit(e);
    if (h !== lastHit) {
      lastHit = h;
      api.command("pointer", h);
    }
    if (
      h &&
      e.clientY < 165 &&
      e.clientY > 90 &&
      Math.abs(e.movementX) > 2 &&
      !active
    )
      blinkAt = performance.now() - 80;
  }
});
function endPointer(e) {
  if (!pointer) return;
  const p = pointer;
  pointer = null;
  api.command("drag-end");
  if (!p.moved) {
    clearTimeout(clickTimer);
    clickTimer = setTimeout(() => requestAction("wave"), 260);
  }
}
canvas.addEventListener("pointerup", endPointer);
canvas.addEventListener("pointercancel", () => {
  pointer = null;
  api.command("drag-end");
});
canvas.addEventListener("dblclick", () => {
  clearTimeout(clickTimer);
  requestAction(pose === "sleep" ? "idle" : "sleep");
});
canvas.addEventListener("contextmenu", (e) => {
  e.preventDefault();
  api.command("menu");
});
document.querySelector("#ai").addEventListener("pointerenter", () => {
  lastHit = true;
  api.command("pointer", true);
});
document
  .querySelector("#ai")
  .addEventListener("click", () => api.command("panel"));
api.on("action", requestAction);
api.on("bubble", bubble);
api.on("state", (s) => {
  prefs = s.prefs;
});
async function boot() {
  const state = await api.bootstrap();
  prefs = state.prefs;
  smokeMode = state.smoke;
  metadata = await (await fetch("../assets/clips/clips.json")).json();
  for (const c of metadata.clips) clips.set(c.name, c);
  atlas = new Image();
  atlas.src = "../assets/cats.png";
  await atlas.decode();
  const sx = atlas.width / 1672,
    sy = atlas.height / 940;
  idleSprite = trim(atlas, 0, 0, Math.round(570 * sx), Math.round(470 * sy));
  blinkSprite = trim(
    atlas,
    Math.round(570 * sx),
    0,
    Math.round(550 * sx),
    Math.round(470 * sy),
  );
  await videoReady(getVideo("wave"));
  ready = true;
  requestAnimationFrame(draw);
  await api.command("ready");
  // End-to-end smoke validates Chromium's real decoder and transparent pixels,
  // including all shipped clips. Main process only acts on result in --smoke-test.
  if (!state.smoke) return;
  const startFrames = renderedFrames;
  const startPixels = canvas.toDataURL();
  await new Promise((resolve) => setTimeout(resolve, 1500));
  if (renderedFrames - startFrames < 10 || canvas.toDataURL() === startPixels)
    throw new Error("桌宠待机画布未持续更新");
  const probes = [];
  for (const c of metadata.clips) {
    const v = getVideo(c.name);
    await videoReady(v);
    const test = document.createElement("canvas");
    test.width = c.size[0];
    test.height = c.size[1];
    const g = test.getContext("2d", { willReadFrequently: true });
    g.drawImage(v, 0, 0);
    const data = g.getImageData(0, 0, test.width, test.height).data;
    let min = 255,
      max = 0;
    for (let i = 3; i < data.length; i += 4) {
      min = Math.min(min, data[i]);
      max = Math.max(max, data[i]);
    }
    if (min !== 0 || max < 200) throw new Error(c.name + " alpha missing");
    probes.push(c.name);
  }
  await playClip("wave");
  active = null;
  await api.command("smoke-result", {
    ok: true,
    clips: probes.length,
    transparent: true,
    idleFrames: renderedFrames - startFrames,
    playbackCompleted: true,
  });
}
boot().catch((e) => {
  bubble("素材加载失败，请重新安装。");
  api.command("smoke-result", { ok: false, error: e.message });
});
