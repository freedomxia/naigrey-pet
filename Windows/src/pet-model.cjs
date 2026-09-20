/* Shared, dependency-free geometry and animation transitions. */
(function (root) {
  const WINDOW_WIDTH = 520,
    WINDOW_HEIGHT = 320,
    CENTER_X = 260,
    GROUND = 307;
  const paths = {
    idle: ["idle"],
    wave: ["wave", "idle"],
    yawn: ["yawn", "idle"],
    stretch: ["stretch", "idle"],
    sleep: ["lieDown", "sleep"],
    play: ["play", "idle"],
    walk: ["standUp", "walk", "sitDown", "idle"],
    type: ["typeIn", "type", "typeOut", "idle"],
    music: ["musicIn", "music", "musicOut", "idle"],
  };
  function actionPath(current, requested) {
    if (
      !Object.hasOwn(paths, requested) ||
      (current === requested && ["idle", "sleep"].includes(current))
    )
      return [];
    return [...(current === "sleep" ? ["wake"] : []), ...paths[requested]];
  }
  function clampPosition(p, size, area) {
    return {
      x: Math.round(
        Math.max(
          area.x,
          Math.min(p.x, area.x + Math.max(0, area.width - size.width)),
        ),
      ),
      y: Math.round(
        Math.max(
          area.y,
          Math.min(p.y, area.y + Math.max(0, area.height - size.height)),
        ),
      ),
    };
  }
  function panelPosition(pet, area) {
    const y = pet.y + pet.height + 6;
    return clampPosition(
      {
        x: pet.x + pet.width / 2 - 180,
        y: y + 230 <= area.y + area.height ? y : pet.y - 236,
      },
      { width: 360, height: 230 },
      area,
    );
  }
  function clipRect(clip, t, sitHeight, catHeight, cx, ground) {
    const s = catHeight / sitHeight,
      a = clip.start,
      b = clip.end || a;
    const p = Math.max(0, Math.min(1, t));
    return {
      x: cx - (a[0] + (b[0] - a[0]) * p) * s,
      y: ground - (a[1] + (b[1] - a[1]) * p) * s,
      width: clip.size[0] * s,
      height: clip.size[1] * s,
    };
  }
  function repeatClip({
    name,
    completed,
    loops,
    pending,
    continuous,
    company,
  }) {
    if (pending) return false;
    return continuous ? company === name : completed < loops;
  }
  function clipBallHandOff(
    clip,
    sitHeight,
    catHeight,
    cx,
    ground,
    mirrored = false,
  ) {
    if (!clip.ballEnd || !clip.ballVelocity) return null;
    const rect = clipRect(clip, 1, sitHeight, catHeight, cx, ground),
      scale = catHeight / sitHeight;
    const x = rect.x + clip.ballEnd[0] * scale;
    return {
      point: {
        x: mirrored ? cx * 2 - x : x,
        y: rect.y + clip.ballEnd[1] * scale,
      },
      velocity: {
        x: (mirrored ? -1 : 1) * clip.ballVelocity[0] * scale,
        y: clip.ballVelocity[1] * scale,
      },
    };
  }
  function clipMoving(clip, seconds) {
    return (
      clip.speed > 0 &&
      seconds >= (clip.moveFrom || 0) &&
      (clip.moveTo == null || seconds <= clip.moveTo)
    );
  }
  function walkDistance(elapsed, speed, scale) {
    return (Math.max(0, Math.min(50, elapsed)) * speed * scale) / 1000;
  }
  function sleepContinuation(requested) {
    return requested === "sleep" ? null : requested;
  }
  function advanceWalk(x, delta, width, area) {
    return Math.max(
      area.x,
      Math.min(x + delta, area.x + Math.max(0, area.width - width)),
    );
  }
  class IdleCompanion {
    constructor(random = Math.random) {
      this.random = random;
      this.nextAt = 5000;
      this.greeted = false;
      this.wakeAt = null;
    }
    interact(now) {
      this.nextAt = now + 6000;
      this.wakeAt = null;
    }
    tick({
      now,
      pose,
      busy = false,
      dragging = false,
      enabled = true,
      typing = false,
      roaming = true,
      hour = 12,
    }) {
      if (!enabled || dragging) return null;
      if (pose === "sleep" && this.wakeAt !== null && now >= this.wakeAt) {
        this.wakeAt = null;
        this.nextAt = now + 8000;
        return "idle";
      }
      if (busy || typing || pose !== "idle" || now < this.nextAt) return null;
      this.nextAt = now + 8000 + this.random() * 8000;
      if (!this.greeted) {
        this.greeted = true;
        return "wave";
      }
      const roll = this.random();
      const drowsy = (hour >= 14 && hour <= 15) || hour >= 22 || hour < 6;
      if (roll < (drowsy ? 0.16 : 0.07)) return "yawn";
      if (roll < 0.2) return "meow";
      if (roll < 0.25) return "stretch";
      if (roll < 0.37 && roaming) return "walk";
      if (roll < 0.4) {
        this.wakeAt = now + 15000 + this.random() * 15000;
        return "sleep";
      }
      return null;
    }
  }
  const api = {
    WINDOW_WIDTH,
    WINDOW_HEIGHT,
    CENTER_X,
    GROUND,
    IdleCompanion,
    advanceWalk,
    sleepContinuation,
    actionPath,
    clampPosition,
    panelPosition,
    clipRect,
    walkDistance,
    clipMoving,
    repeatClip,
    clipBallHandOff,
  };
  if (typeof module !== "undefined") module.exports = api;
  else root.PetModel = api;
})(globalThis);
