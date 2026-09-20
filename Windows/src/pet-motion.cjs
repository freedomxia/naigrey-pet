/* Direct numeric port of Source/Motion.swift. Coordinates are padded source pixels,
 * y down. Random event timing uses injected RNG; all movement equations are Swift's. */
(function (root) {
  const { sin, cos, exp, abs, min, max, hypot, tanh, PI, asin, floor, pow } =
    Math;
  const ease = (x) => 0.5 - 0.5 * cos(PI * min(1, max(0, x)));
  const envelope = (t, start, rise, end, fall) =>
    ease((t - start) / rise) * (1 - ease((t - end) / fall));
  function keys(t, frames) {
    if (t <= frames[0][0]) return frames[0][1];
    for (let i = 1; i < frames.length; i++) {
      const a = frames[i - 1],
        b = frames[i];
      if (t <= b[0])
        return a[1] + (b[1] - a[1]) * ease((t - a[0]) / (b[0] - a[0]));
    }
    return frames.at(-1)[1];
  }
  function flick(t, at, amp, freq = 6.5, decay = 0.13) {
    if (t < at) return 0;
    const s = t - at;
    return amp * exp(-s / decay) * sin(2 * PI * freq * s) * min(1, s / 0.02);
  }
  class Follow {
    constructor(omega, value = 0) {
      this.omega = omega;
      this.value = value;
      this.velocity = 0;
    }
    step(target, dt) {
      const h = dt / 4;
      for (let i = 0; i < 4; i++) {
        this.velocity +=
          (this.omega ** 2 * (target - this.value) -
            2 * this.omega * this.velocity) *
          h;
        this.value += this.velocity * h;
      }
      return this.value;
    }
  }
  class CatMotion {
    constructor(data, random = Math.random) {
      this.data = data;
      this.random = random;
      this.time = 0;
      this.pose = "idle";
      this.poseSince = 0;
      for (const [k, v] of Object.entries({
        eyeX: 38,
        eyeY: 38,
        headTilt: 7,
        headX: 7,
        headY: 7,
        interest: 3,
        petting: 4,
        squint: 9,
        heldness: 6,
        speed: 4.5,
        hurry: 3,
      }))
        this[k] = new Follow(v);
      for (const k of [
        "lastPointerMove",
        "lastPet",
        "blinkAt",
        "meowAt",
        "yawnAt",
        "sniffAt",
        "sighAt",
        "slowBlinkAt",
        "swishAt",
        "dreamAt",
        "pauseStart",
        "pauseEnd",
        "batAt",
      ])
        this[k] = -100;
      Object.assign(this, {
        glance: [0, 0],
        jitter: [0, 0],
        nextGlance: 1.5,
        nextJitter: 0,
        wasInterested: false,
        blinkShut: 0.06,
        nextBlink: 1.8,
        doubleBlinkAt: null,
        nextSlowBlink: 20,
        nextIdleSniff: 14,
        earFlicks: [],
        tipFlicks: [],
        nextEarFlick: 3,
        nextTip: 0,
        nextSwish: 9,
        nextDream: 9,
        breathPhase: 0,
        sleepPhase: 0,
        exertion: 0,
        gait: 0,
        chasing: false,
        nextPause: 5,
        walkRise: 0,
        walkPitch: 0,
        walkBreath: 0,
        walkLook: 0,
      });
    }
    randomRange(a, b) {
      return a + (b - a) * this.random();
    }
    chance(p) {
      return this.random() < p;
    }
    get cycle() {
      return 0.9 - 0.42 * this.hurry.value;
    }
    get stepLength() {
      return 40 + 16 * this.hurry.value;
    }
    get walkSpeed() {
      return (this.stepLength / (0.6 * this.cycle)) * this.speed.value;
    }
    get isBusy() {
      return this.time - this.yawnAt < 2.8 || this.time - this.meowAt < 0.8;
    }
    meow() {
      if (this.pose !== "idle" || this.isBusy) return false;
      this.meowAt = this.time;
      return true;
    }
    yawn() {
      if (this.pose !== "idle" || this.isBusy || this.interest.value >= 0.3)
        return false;
      this.yawnAt = this.time;
      return true;
    }
    sniff() {
      if (this.time - this.sniffAt > 1.5) this.sniffAt = this.time;
    }
    sigh() {
      if (this.pose === "idle" && this.time - this.sighAt > 4)
        this.sighAt = this.time;
    }
    bat() {
      this.batAt = this.time;
    }
    blink(t = this.time) {
      this.blinkAt = t;
      this.blinkShut = this.randomRange(0.04, 0.08);
      this.nextBlink = t + this.randomRange(2.2, 6.5);
      if (this.chance(0.2))
        this.doubleBlinkAt = t + this.randomRange(0.28, 0.4);
    }
    blinkAmount(t) {
      const s = t - this.blinkAt;
      if (s < 0 || s > 0.04 + this.blinkShut + 0.08) return 0;
      if (s < 0.04) return ease(s / 0.04);
      if (s < 0.04 + this.blinkShut) return 1;
      return 1 - ease((s - 0.04 - this.blinkShut) / 0.08);
    }
    update(dt, pose, walking, senses = {}) {
      // Subdivide stalls rather than destabilize the spring integrator.
      if (dt > 0.05) {
        let remaining = min(dt, 0.25);
        while (remaining > 1e-8) {
          const h = min(0.05, remaining);
          this.update(h, pose, walking, senses);
          remaining -= h;
        }
        return;
      }
      this.time += dt;
      const t = this.time,
        R = (a, b) => this.randomRange(a, b),
        C = (p) => this.chance(p);
      if (pose !== this.pose) {
        if (pose === "walk") {
          this.nextPause = t + R(3.5, 6.5);
          this.gait = 0;
        }
        if (this.pose === "walk") this.exertion = 1;
        this.pose = pose;
        this.poseSince = t;
      }
      const head = pose === "walk" ? [180, 190] : [325, 230],
        p = senses.pointer;
      if (
        p &&
        senses.pointerSpeed > 25 &&
        hypot(p.x - head[0], p.y - head[1]) < 1100 &&
        !senses.held
      )
        this.lastPointerMove = t;
      this.interest.step(
        t - this.lastPointerMove < 2.6 || senses.fixated ? 1 : 0,
        dt,
      );
      if (this.wasInterested && this.interest.value < 0.2) {
        this.wasInterested = false;
        if (C(0.5) && t - this.sighAt > 15 && pose === "idle") this.sighAt = t;
      }
      if (this.interest.value > 0.7) this.wasInterested = true;
      if (
        senses.pointerOverHead &&
        senses.pointerSpeed > 12 &&
        pose === "idle" &&
        !senses.held
      )
        this.lastPet = t;
      this.petting.step(t - this.lastPet < 0.45 ? 1 : 0, dt);
      this.heldness.step(senses.held ? 1 : 0, dt);
      this.exertion = max(0, this.exertion - dt / 20);
      if (t >= this.nextGlance) {
        this.glance = C(0.45) ? [0, 0] : [R(-3.6, 3.6), R(-1.6, 1.4)];
        this.nextGlance = t + R(1.2, 4.5);
        if (t - this.blinkAt > 1.2 && C(0.4)) this.blink(t);
      }
      if (t >= this.nextJitter) {
        this.jitter = [R(-0.35, 0.35), R(-0.25, 0.25)];
        this.nextJitter = t + R(0.25, 0.7);
      }
      let [ex, ey] = this.glance,
        tilt = ex * 0.6,
        hx = 0,
        hy = 0;
      if (p && this.interest.value > 0.02) {
        const dx = p.x - head[0],
          dy = p.y - head[1],
          k = this.interest.value;
        ex += (4.6 * tanh(dx / 140) - ex) * k;
        ey += (3.2 * tanh(dy / 140) - ey) * k;
        tilt += (5.5 * tanh(dx / 220) - tilt) * k;
        hx = 5 * tanh(dx / 220) * k;
        hy = 4 * tanh(dy / 220) * k;
      }
      const pet = this.petting.value;
      tilt += 4 * pet * sin((2 * PI * t) / 1.6);
      this.eyeX.step(ex, dt);
      this.eyeY.step(ey, dt);
      this.headTilt.step(tilt, dt);
      this.headX.step(hx, dt);
      this.headY.step(hy, dt);
      if (t >= this.nextBlink) this.blink(t);
      if (this.doubleBlinkAt !== null && t >= this.doubleBlinkAt) {
        this.doubleBlinkAt = null;
        this.blinkAt = t;
        this.blinkShut = 0.05;
      }
      if (t >= this.nextSlowBlink) {
        if (this.interest.value < 0.2 && pose === "idle") this.slowBlinkAt = t;
        this.nextSlowBlink = t + R(14, 32);
      }
      this.squint.step(0.55 * pet, dt);
      if (t >= this.nextEarFlick) {
        this.earFlicks.push({
          at: t,
          ear: floor(R(0, 2)),
          amp: R(8, 14) * (C(0.5) ? 1 : -1),
        });
        if (C(0.25))
          this.earFlicks.push({
            at: t + R(0.18, 0.3),
            ear: floor(R(0, 2)),
            amp: R(6, 10),
          });
        this.nextEarFlick = t + (pose === "sleep" ? R(5, 14) : R(2.5, 8));
      }
      this.earFlicks = this.earFlicks.filter((f) => t - f.at <= 1.5);
      if (this.interest.value > 0.5 && t >= this.nextTip) {
        this.tipFlicks.push(t);
        this.nextTip = t + R(0.6, 1.6);
      }
      this.tipFlicks = this.tipFlicks.filter((at) => t - at <= 1.5);
      if (t >= this.nextSwish) {
        this.swishAt = t;
        this.nextSwish = t + R(8, 20);
      }
      if (
        p &&
        pose === "idle" &&
        this.interest.value > 0.4 &&
        senses.pointerSpeed < 40 &&
        hypot(p.x - 318, p.y - 265) < 150 &&
        t - this.sniffAt > 3.5
      )
        this.sniffAt = t;
      if (t >= this.nextIdleSniff) {
        if (this.interest.value < 0.2 && pose === "idle" && !this.isBusy)
          this.sniffAt = t;
        this.nextIdleSniff = t + R(15, 40);
      }
      if (pose === "sleep" && t >= this.nextDream) {
        this.dreamAt = t;
        this.nextDream = t + R(9, 24);
      }
      this.breathPhase +=
        dt / (3.1 - 0.8 * this.interest.value - 0.9 * this.exertion);
      this.sleepPhase += dt / 3.8;
      let want = walking && pose === "walk" ? 1 : 0;
      this.hurry.step(this.chasing ? 1 : 0, dt);
      if (walking && pose === "walk" && !this.chasing) {
        if (t >= this.nextPause && t > this.pauseEnd) {
          this.pauseStart = t;
          this.pauseEnd = t + R(1.9, 3.4);
          this.nextPause = this.pauseEnd + R(3.5, 8);
        }
        if (t < this.pauseEnd) want = 0;
      }
      this.speed.step(want, dt);
      this.gait += (dt * this.speed.value) / this.cycle;
      const v = this.speed.value,
        g = this.gait;
      this.walkLook =
        envelope(t, this.pauseStart + 0.55, 0.3, this.pauseEnd - 0.75, 0.35) *
        (this.pauseEnd - this.pauseStart > 1.5 ? 1 : 0);
      this.walkRise = 1.8 * v * (0.5 - 0.5 * cos(4 * PI * (g - 0.1)));
      this.walkPitch =
        0.6 * v * sin(2 * PI * (g - 0.3)) +
        1.4 *
          envelope(
            t,
            this.pauseStart + 0.35,
            0.15,
            this.pauseStart + 0.5,
            0.35,
          ) -
        1.2 * envelope(t, this.pauseEnd - 0.4, 0.25, this.pauseEnd - 0.15, 0.2);
      this.walkBreath = 0.012 * (1 - v) * this.breath(this.breathPhase);
    }
    bend(p, r, name, fn, lag = 0) {
      const b = r.bends[name];
      if (!b) return;
      const o = 32 + b.slot * 13;
      for (let k = 0; k < (b.along ? 9 : 1); k++)
        p[o + 4 + k] = (fn(this.time - (lag * k) / 8) * PI) / 180;
    }
    move(p, r, name, dx, dy) {
      const slot = r.shifts[name];
      if (slot === undefined) return;
      const o = 110 + slot * 3;
      p[o + 1] = -dx;
      p[o + 2] = -dy;
    }
    scale(p, r, name, x, y, kx, ky) {
      const slot = r.scales[name];
      if (slot === undefined) return;
      const o = 134 + slot * 5;
      p[o + 1] = x;
      p[o + 2] = y;
      p[o + 3] = kx;
      p[o + 4] = ky;
    }
    body(p, x, y, degrees, gx, gy, sx, sy, lift = 0) {
      p[5] = x;
      p[6] = y;
      p[7] = (degrees * PI) / 180;
      p[28] = gx;
      p[29] = gy;
      p[8] = sx;
      p[9] = sy;
      p[11] = -lift;
    }
    lids(p, c, strength = 0.45, swap = true) {
      if (c <= 0.001) return;
      p[13] = 1 / (1 - strength * min(1, c / 0.6)) - 1;
      if (swap) p[17] = ease((c - 0.6) / 0.35);
    }
    breath(phase) {
      const q = phase % 1;
      return q < 0.38 ? ease(q / 0.38) : 1 - ease((q - 0.38) / 0.5);
    }
    params(layer, opacity = 1) {
      const r = this.data.rigs[layer];
      if (!r) return [];
      const p = [...r.rest];
      p[12] = opacity;
      if (layer === "walk") this.walking(p, r);
      else if (layer.startsWith("walk.")) {
        const l = this.leg(layer.slice(5));
        this.bend(p, r, "leg", () => l.degrees);
        this.move(p, r, "lift", 0, -l.lift);
        this.walkBody(p);
      } else if (layer === "sleep") this.sleeping(p, r);
      else if (layer === "wave") this.waving(p, r);
      else this.sitting(p, r);
      return p;
    }
    sitting(p, r) {
      const t = this.time,
        pad = 40,
        k = this.interest.value,
        pet = this.petting.value,
        held = this.heldness.value;
      const meow = envelope(t, this.meowAt, 0.08, this.meowAt + 0.4, 0.14),
        y = t - this.yawnAt,
        yawning = y >= 0 && y < 2.8;
      const yo = yawning
        ? keys(y, [
            [0, 0],
            [0.55, 0.3],
            [1.35, 1],
            [1.85, 0.95],
            [2.35, 0],
            [2.8, 0],
          ])
        : 0;
      const yh = yawning
        ? keys(y, [
            [0, 0],
            [0.7, 1],
            [1.9, 1],
            [2.5, 0],
            [2.8, 0],
          ])
        : 0;
      const ye = yawning
        ? keys(y, [
            [0, 0],
            [0.5, 0.45],
            [1.3, 0.62],
            [1.95, 0.62],
            [2.3, 0.2],
            [2.45, 1],
            [2.6, 0],
            [2.8, 0],
          ])
        : 0;
      const sigh = envelope(t, this.sighAt, 0.7, this.sighAt + 0.3, 0.9),
        slow = envelope(t, this.slowBlinkAt, 0.4, this.slowBlinkAt + 0.9, 0.45),
        b = this.breath(this.breathPhase),
        lift = 0.014 * b + 0.035 * sigh + 0.02 * yh;
      this.body(
        p,
        280 + pad,
        463 + pad,
        0.5 * sin((2 * PI * t) / 7.3),
        280 + pad,
        463 + pad,
        1 + 0.36 * lift,
        1 + lift,
      );
      this.bend(
        p,
        r,
        "tail",
        (u) =>
          (4 - 2.5 * k + 4 * pet + 3 * held) * sin((2 * PI * u) / 3.7) +
          1.5 * sin((2 * PI * u) / 1.7 + 1) +
          14 * sin(PI * min(1, max(0, (u - this.swishAt) / 0.7))),
        0.32,
      );
      this.bend(
        p,
        r,
        "tip",
        (u) =>
          this.tipFlicks.reduce((s, at) => s + flick(u, at, 16, 5, 0.12), 0),
        0.08,
      );
      this.bend(p, r, "head", () => this.headTilt.value - 2.5 * yh);
      this.move(
        p,
        r,
        "head",
        this.headX.value,
        this.headY.value -
          5 * meow -
          7 * yh -
          3 * sigh +
          0.6 * yh * sin(2 * PI * 9 * t),
      );
      const back = 5 * meow + 10 * yh + 6 * pet + 8 * held;
      this.bend(
        p,
        r,
        "earRight",
        (u) =>
          -7 * k +
          back +
          this.earFlicks
            .filter((e) => e.ear === 0)
            .reduce((s, e) => s + flick(u, e.at, -abs(e.amp)), 0),
      );
      this.bend(
        p,
        r,
        "earLeft",
        (u) =>
          7 * k -
          back +
          this.earFlicks
            .filter((e) => e.ear === 1)
            .reduce((s, e) => s + flick(u, e.at, abs(e.amp)), 0),
      );
      const ex = this.eyeX.value + this.jitter[0],
        ey = this.eyeY.value + this.jitter[1];
      this.move(p, r, "irises", ex, ey);
      const sniff =
        1.7 *
        envelope(t, this.sniffAt, 0.1, this.sniffAt + 0.65, 0.15) *
        pow(max(0, sin(2 * PI * 6.5 * (t - this.sniffAt))), 2);
      this.move(p, r, "muzzle", 0, -sniff);
      this.move(p, r, "chin", 0, 3 * meow + 7 * yo);
      const dilate = 1 + 0.24 * k + 0.12 * held - 0.06 * pet;
      this.scale(
        p,
        r,
        "pupilLeft",
        236 + pad + ex,
        171 + pad + ey,
        dilate,
        dilate,
      );
      this.scale(
        p,
        r,
        "pupilRight",
        344 + pad + ex,
        193 + pad + ey,
        dilate,
        dilate,
      );
      this.lids(p, max(this.blinkAmount(t), this.squint.value, 0.6 * slow, ye));
      [p[24], p[25]] = this.data.sizes.blink;
      if (yo > 0.001) {
        p[18] = yo;
        p[19] = 11;
        p[27] = 1;
        p[20] = 120;
        p[21] = 25;
        [p[22], p[23]] = this.data.sizes.yawn;
      } else if (meow > 0.001) {
        p[18] = meow;
        p[19] = 14;
        p[27] = 0;
        p[20] = 7;
        p[21] = 13;
        [p[22], p[23]] = this.data.sizes.wave;
      }
    }
    leg(name) {
      const leg = this.data.legs.find((l) => l.name === name),
        phase = { backNear: 0, frontNear: 0.25, backFar: 0.5, frontFar: 0.75 }[
          name
        ];
      if (!leg || phase === undefined) return { degrees: 0, lift: 0 };
      const reach = asin(min(0.9, this.stepLength / (2 * leg.length))),
        u = this.gait - phase - floor(this.gait - phase);
      let angle, lift;
      if (u < 0.6) {
        angle = reach * (1 - (2 * u) / 0.6);
        lift = 0;
      } else {
        const k = (u - 0.6) / 0.4;
        angle = -reach + 2 * reach * ease(k);
        lift = (11 * pow(sin(PI * k), 1.2) * leg.length) / 110;
      }
      return {
        degrees: ((angle * 180) / PI) * this.speed.value,
        lift: lift * this.speed.value,
      };
    }
    walkBody(p) {
      this.body(
        p,
        330,
        300,
        this.walkPitch,
        330,
        440,
        1,
        1 + this.walkBreath,
        this.walkRise,
      );
    }
    walking(p, r) {
      const t = this.time,
        v = this.speed.value,
        g = this.gait,
        look = this.walkLook,
        nod = 0.8 * v * sin(4 * PI * (g - 0.2)) - 3 * look;
      this.bend(p, r, "head", () => nod - 0.6 * this.walkPitch);
      this.move(p, r, "head", 2.5 * look, 0.5 * this.walkRise - 3 * look);
      this.bend(
        p,
        r,
        "tail",
        (u) =>
          (6 * v + 3) * sin((PI * u) / 0.9 + 0.4) * (0.6 + 0.4 * v) +
          2 * v * sin(4 * PI * (u / this.cycle - 0.1) - 1.3),
        0.28,
      );
      const tips = [
        ...this.tipFlicks,
        ...(1 - v > 0.5 ? [this.pauseStart + 1.2] : []),
      ];
      this.bend(
        p,
        r,
        "tip",
        (u) => tips.reduce((s, at) => s + flick(u, at, 16, 5), 0),
        0.06,
      );
      this.bend(p, r, "ear", (u) =>
        this.earFlicks.reduce((s, e) => s + flick(u, e.at, e.amp), 0),
      );
      let gx = 5.5 * look + 1.2 * sin((2 * PI * t) / 2.9) * v;
      gx += (this.eyeX.value - gx) * this.interest.value * 0.8;
      this.move(p, r, "irises", gx, -0.3 * look);
      this.walkBody(p);
      this.lids(p, this.blinkAmount(t) * 0.8, 0.5, false);
    }
    sleeping(p, r) {
      const t = this.time,
        b = this.breath(this.sleepPhase),
        dream = this.dreamAt;
      this.scale(p, r, "breath", 440, 365, 1 + 0.006 * b, 1 + 0.032 * b);
      this.bend(
        p,
        r,
        "head",
        () => 1.2 * sin((2 * PI * t) / 9) + flick(t, dream + 0.1, 2, 4, 0.2),
      );
      this.move(p, r, "head", 0, -1.3 * b);
      this.bend(p, r, "earUp", (u) =>
        this.earFlicks
          .filter((e) => e.ear === 0)
          .reduce((s, e) => s + flick(u, e.at, e.amp), 0),
      );
      this.bend(p, r, "earSide", (u) =>
        this.earFlicks
          .filter((e) => e.ear === 1)
          .reduce((s, e) => s + flick(u, e.at, e.amp * 0.8), 0),
      );
      const twitch = envelope(t, dream, 0.05, dream + 0.5, 0.2);
      this.move(
        p,
        r,
        "muzzle",
        0,
        -1.4 * twitch * pow(max(0, sin(2 * PI * 7 * (t - dream))), 2),
      );
      this.move(p, r, "paws", 2 * twitch * sin(2 * PI * 5 * (t - dream)), 0);
      this.body(p, 316, 365, 0, 316, 365, 1, 1);
    }
    waving(p, r) {
      const t = this.time,
        s = t - this.poseSince,
        raise = ease(s / 0.18),
        swat = t - this.batAt;
      if (swat >= 0 && swat < 0.8) {
        this.bend(p, r, "paw", () =>
          keys(swat, [
            [0, 0],
            [0.12, 12],
            [0.24, -34],
            [0.4, -18],
            [0.8, 0],
          ]),
        );
        this.bend(p, r, "head", () =>
          keys(swat, [
            [0, 0],
            [0.2, -3],
            [0.5, -2],
            [0.8, 0],
          ]),
        );
      } else {
        this.bend(p, r, "paw", () => raise * (13 * sin(2 * PI * 2.1 * s) - 3));
        this.bend(p, r, "head", () => 3.5 * sin(2 * PI * 1.05 * s + 0.5));
      }
      this.move(p, r, "head", 0, -1.4 * abs(sin(2 * PI * 1.05 * s)));
      this.bend(p, r, "tail", (u) => 7 * sin((2 * PI * u) / 1.5), 0.3);
      this.bend(p, r, "earLeft", () => 4 * sin(2 * PI * 2.1 * s + 1));
      this.bend(p, r, "earRight", () => -4 * sin(2 * PI * 2.1 * s + 1.4));
      const b = this.breath(this.breathPhase);
      this.body(
        p,
        320,
        505,
        0.8 * sin(2 * PI * 1.05 * s),
        320,
        505,
        1 + 0.005 * b,
        1 + 0.014 * b,
      );
    }
  }
  const api = { CatMotion, Follow, ease, keys, envelope, flick };
  if (typeof module !== "undefined") module.exports = api;
  else root.PetMotion = api;
})(globalThis);
