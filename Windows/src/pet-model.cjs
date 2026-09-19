/* Shared, dependency-free geometry and animation transitions. */
(function (root) {
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
  const api = {
    advanceWalk,
    sleepContinuation,
    actionPath,
    clampPosition,
    panelPosition,
    clipRect,
    walkDistance,
  };
  if (typeof module !== "undefined") module.exports = api;
  else root.PetModel = api;
})(globalThis);
