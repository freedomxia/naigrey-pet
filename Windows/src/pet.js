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
  metadata,
  pose = "idle",
  active = null,
  busy = false,
  pending = null,
  fade = null,
  fadeAt = 0,
  pointer = null,
  clickTimer,
  bubbleTimer,
  ready = false;
let prefs = { motion: true },
  lastHit = true;
const { GROUND, WINDOW_HEIGHT, WINDOW_WIDTH, CENTER_X } = window.PetModel;
function bubble(text) {
  const el = document.querySelector("#bubble");
  el.textContent = text;
  el.classList.add("visible");
  clearTimeout(bubbleTimer);
  bubbleTimer = setTimeout(() => el.classList.remove("visible"), 4500);
}
let motion,
  renderer,
  rigData,
  externalSenses = {},
  facingRight = false;
let flipFrom = 1,
  flipTo = 1,
  flipAt = -1000,
  localPointer = null,
  lastPointerSample = null,
  pointerSpeed = 0,
  releaseAt = -1000,
  liftAt = -1000;
let company = null,
  typeRate = 1;
let cancelPlayback = null,
  actionGeneration = 0;
function catHeight() {
  return [72, 100, 130, 140, 170].includes(prefs.catHeight)
    ? prefs.catHeight
    : 140;
}
function currentFlip(now) {
  return (
    flipFrom + (flipTo - flipFrom) * window.PetMotion.ease((now - flipAt) / 180)
  );
}
function acceptState(s) {
  prefs = s.prefs || prefs;
  if (Object.hasOwn(s, "company")) {
    const previous = company;
    company =
      s.company === "typing"
        ? "type"
        : ["type", "music"].includes(s.company)
          ? s.company
          : null;
    if (
      previous !== company &&
      busy &&
      /^(type|music)/.test(active?.name || "")
    )
      pending = company || "idle";
    if (company && !busy && ready && !pointer) requestAction(company, true);
  }
  if (Number.isFinite(s.typeRate))
    typeRate = Math.max(0.25, Math.min(3, s.typeRate));
  if (active?.name === "type") active.video.playbackRate = typeRate;
  externalSenses = s.senses || externalSenses;
  const right = s.facingRight ?? s.direction > 0;
  if (right !== facingRight) {
    flipFrom = currentFlip(performance.now());
    flipTo = right ? -1 : 1;
    flipAt = performance.now();
    facingRight = right;
  }
  document.querySelector("#ai").textContent = s.sessions?.some(
    (x) => x.state === "busy",
  )
    ? "AI⋯"
    : "AI";
}
function cancelAction() {
  actionGeneration++;
  pending = null;
  if (cancelPlayback) cancelPlayback();
  active?.video.pause();
  active = null;
  pose = "idle";
  busy = false;
  api.command("phase", "idle");
}

function freeze() {
  const c = document.createElement("canvas");
  c.width = WINDOW_WIDTH * 2;
  c.height = WINDOW_HEIGHT * 2;
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
  const generation = actionGeneration;
  const video = getVideo(name);
  await videoReady(video);
  if (generation !== actionGeneration) return;
  video.currentTime = 0;
  freeze();
  active = { name, video, clip: clips.get(name) };
  const continuous = company === name && ["type", "music"].includes(name);
  video.playbackRate = name === "type" ? typeRate : 1;
  api.command("phase", name);
  let n = 0;
  await new Promise((resolve, reject) => {
    const onEnd = () => {
      n++;
      if (
        window.PetModel.repeatClip({
          name,
          completed: n,
          loops,
          pending,
          continuous,
          company,
        })
      ) {
        video.currentTime = 0;
        video.play().catch(fail);
      } else {
        if (name === "play") {
          const hand = window.PetModel.clipBallHandOff(
            clips.get(name),
            metadata.sitHeight,
            catHeight(),
            CENTER_X,
            GROUND,
            !facingRight,
          );
          if (hand) api.command("ball-hand-off", hand);
        }
        done();
      }
    };
    function cleanup() {
      video.removeEventListener("ended", onEnd);
      video.removeEventListener("error", fail);
    }
    function done() {
      cleanup();
      cancelPlayback = null;
      resolve();
    }
    function fail() {
      cleanup();
      reject(new Error("播放失败"));
    }
    cancelPlayback = () => {
      video.pause();
      done();
    };
    video.addEventListener("ended", onEnd);
    video.addEventListener("error", fail, { once: true });
    video.play().catch(fail);
  });
}
async function requestAction(action, autonomous = false) {
  if (!autonomous) companion.interact(performance.now());
  if (!ready) return;
  if (action === "meow") {
    if (prefs.motion) motion.meow();
    return;
  }
  if (action === "blink") {
    if (prefs.motion) motion.blink();
    return;
  }
  if (action === "stop") {
    cancelAction();
    return;
  }

  if (action === "sleep" && pose === "sleep") return;
  if (busy) {
    pending = action;
    return;
  }
  const path = actionPath(pose, action);
  if (!path.length) return;
  busy = true;
  const generation = ++actionGeneration;
  const companyAction = company === action;
  pending = null;
  try {
    for (let i = 0; i < path.length; i++) {
      if (generation !== actionGeneration) return;
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
          if (generation !== actionGeneration) return;
          pending = sleepContinuation(pending);
        } while (!pending);
        break;
      }
      if (["type", "music"].includes(name) && companyAction && company !== name)
        continue;
      await playClip(name, ["type", "music", "walk"].includes(name) ? 4 : 1);
    }
    if (action !== "sleep") pose = "idle";
  } catch {
    if (generation !== actionGeneration) return;
    active = null;
    pose = "idle";
    api.command("phase", "idle");
    bubble("这个动作暂时无法播放，请检查素材是否完整。");
  } finally {
    if (generation !== actionGeneration) return;
    busy = false;
    const next = pending;
    pending = null;
    if (next) requestAction(next);
  }
}
function draw(now) {
  renderedFrames++;
  ctx.setTransform(2, 0, 0, 2, 0, 0);
  ctx.clearRect(0, 0, WINDOW_WIDTH, WINDOW_HEIGHT);
  if (active && active.video.readyState >= 2) {
    const c = active.clip;
    const rect = clipRect(
      c,
      active.video.currentTime / c.duration,
      metadata.sitHeight,
      catHeight(),
      CENTER_X,
      GROUND,
    );
    const flip = ["walk", "standUp", "sitDown"].includes(active.name)
      ? currentFlip(now)
      : active.name === "play" && !facingRight
        ? -1
        : 1;
    ctx.save();
    ctx.translate(CENTER_X, 0);
    ctx.scale(flip, 1);
    ctx.translate(-CENTER_X, 0);
    ctx.drawImage(active.video, rect.x, rect.y, rect.width, rect.height);
    ctx.restore();
  } else if (renderer) {
    const h = catHeight(),
      scale = h / rigData.sizes.idle[1],
      r = rigData.rigs.idle;
    const pt = externalSenses.pointer || localPointer;
    let sensed = null;
    if (pt) {
      sensed = {
        x: (pt.x - (CENTER_X - (r.width * scale) / 2)) / scale,
        y: (pt.y - (GROUND - (r.height - 40) * scale)) / scale,
      };
      if (lastPointerSample) {
        const instant =
          Math.hypot(
            sensed.x - lastPointerSample.x,
            sensed.y - lastPointerSample.y,
          ) / Math.max(0.001, (now - lastPointerSample.at) / 1000);
        pointerSpeed += (instant - pointerSpeed) * 0.35;
      }
      lastPointerSample = { ...sensed, at: now };
    }
    if (prefs.motion !== false)
      motion.update(
        Math.max(0.001, Math.min(0.05, (now - (lastDraw || now - 16)) / 1000)),
        "idle",
        false,
        {
          pointer: sensed,
          pointerSpeed,
          pointerOverHead:
            sensed &&
            sensed.x > 135 &&
            sensed.x < 520 &&
            sensed.y > 10 &&
            sensed.y < 300,
          held: !!pointer?.moved,
          fixated: !!externalSenses.fixated,
        },
      );
    ctx.save();
    // Mac carried pose and soft landing, applied around the paw line.
    if (pointer?.moved) {
      const u = (now - liftAt) / 1000;
      ctx.translate(
        CENTER_X,
        GROUND - h * 0.06 * window.PetMotion.ease(u / 0.18),
      );
      ctx.rotate(
        -window.PetMotion.keys(u % 1.1, [
          [0, 0],
          [0.275, 0.06],
          [0.55, 0],
          [0.825, -0.06],
          [1.1, 0],
        ]),
      );
      ctx.scale(
        1 - 0.03 * window.PetMotion.ease(u / 0.2),
        1 + 0.04 * window.PetMotion.ease(u / 0.2),
      );
      ctx.translate(-CENTER_X, -GROUND);
    } else if (now - releaseAt < 500) {
      const t = (now - releaseAt) / 1000,
        K = window.PetMotion.keys,
        bounce = K(t, [
          [0, 0.06],
          [0.2, 0],
          [0.3, 0.018],
          [0.4, 0],
        ]);
      ctx.translate(CENTER_X, GROUND - h * bounce);
      ctx.scale(
        K(t, [
          [0, 0.97],
          [0.225, 0.97],
          [0.31, 1.07],
          [0.5, 1],
        ]),
        K(t, [
          [0, 1.04],
          [0.225, 1.04],
          [0.31, 0.92],
          [0.5, 1],
        ]),
      );
      ctx.translate(-CENTER_X, -GROUND);
    }
    ctx.drawImage(
      renderer.render(motion, "idle", { height: h }),
      0,
      0,
      WINDOW_WIDTH,
      WINDOW_HEIGHT,
    );
    ctx.restore();
  }
  if (fade) {
    const a = 1 - (now - fadeAt) / 120;
    if (a > 0) {
      ctx.globalAlpha = a;
      ctx.drawImage(fade, 0, 0, WINDOW_WIDTH, WINDOW_HEIGHT);
      ctx.globalAlpha = 1;
    } else fade = null;
  }
  if (
    active &&
    !active.video.paused &&
    lastDraw &&
    window.PetModel.clipMoving(active.clip, active.video.currentTime)
  )
    api.command(
      "walk-step",
      (facingRight ? 1 : -1) *
        walkDistance(
          now - lastDraw,
          active.clip.speed,
          catHeight() / metadata.sitHeight,
        ),
    );
  if (!smokeMode && !prefs.systemCompanion) {
    const chosen = companion.tick({
      now,
      pose,
      busy,
      dragging: !!pointer,
      enabled: prefs.autonomous !== false,
      typing: externalSenses.typing === true,
      roaming: prefs.roaming !== false,
      hour: new Date().getHours(),
    });
    if (chosen && !(chosen === "walk" && prefs.roaming === false))
      requestAction(chosen, true);
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
    x < WINDOW_WIDTH * 2 &&
    y < WINDOW_HEIGHT * 2 &&
    ctx.getImageData(x, y, 1, 1).data[3] > 35
  );
}
canvas.addEventListener("pointerdown", (e) => {
  if (e.button !== 0 || !hit(e)) return;
  pointer = { x: e.screenX, y: e.screenY, moved: false };
  canvas.setPointerCapture(e.pointerId);
});
canvas.addEventListener("pointermove", (e) => {
  localPointer = { x: e.clientX, y: e.clientY };
  if (pointer) {
    if (
      !pointer.moved &&
      Math.hypot(e.screenX - pointer.x, e.screenY - pointer.y) > 5
    ) {
      pointer.moved = true;
      liftAt = performance.now();
      cancelAction();
      api.command("drag-start");
    }
    if (pointer.moved) api.command("drag-move");
  } else {
    const h = hit(e);
    if (h !== lastHit) {
      lastHit = h;
      api.command("pointer", h);
    }
  }
});
function endPointer(e) {
  if (!pointer) return;
  const p = pointer;
  pointer = null;
  releaseAt = performance.now();
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
  acceptState(s);
});
async function boot() {
  const state = await api.bootstrap();
  acceptState(state);
  smokeMode = state.smoke;
  metadata = await (await fetch("../assets/clips/clips.json")).json();
  for (const c of metadata.clips) clips.set(c.name, c);
  rigData = await (await fetch("../assets/rig/rig.json")).json();
  motion = new window.PetMotion.CatMotion(rigData);
  renderer = new window.PetRenderer.RigRenderer(rigData);
  await renderer.load();
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
    throw new Error(
      `桌宠待机画布未持续更新: frames=${renderedFrames - startFrames}, pixelsChanged=${canvas.toDataURL() !== startPixels}, visibility=${document.visibilityState}`,
    );
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
