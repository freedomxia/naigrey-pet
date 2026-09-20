/* Source/Ball.swift translated to desktop coordinates with y downward.
 * Owns physics only; the main process owns the separate transparent ball window. */
(function (root) {
  class YarnBall {
    constructor({ radius = 13, x = 0, y = 0, random = Math.random } = {}) {
      Object.assign(this, {
        radius,
        x,
        y,
        vx: 0,
        vy: 0,
        spin: 0,
        held: false,
        random,
        trail: [],
        moved: false,
      });
    }
    get speed() {
      return Math.hypot(this.vx, this.vy);
    }
    get isResting() {
      return this.speed < 1 && !this.held;
    }
    kick(vx, vy) {
      this.vx = vx;
      this.vy = vy;
      this.held = false;
    }
    step(dt, floor, walls) {
      if (this.held) return;
      const ground = floor - this.radius;
      const airborne = this.y < ground - 0.5 || this.vy < 0;
      if (!airborne && this.speed < 1 && Math.abs(this.y - ground) < 0.5)
        return;
      if (airborne) this.vy += 1500 * dt;
      this.x += this.vx * dt;
      this.y += this.vy * dt;
      if (this.y >= ground) {
        this.y = ground;
        this.vy = this.vy > 90 ? -this.vy * 0.42 : 0;
        this.vx *= 0.96;
      }
      if (this.y >= ground - 0.5 && this.vy === 0) {
        const slow = Math.min(Math.abs(this.vx), 240 * dt);
        this.vx -= this.vx > 0 ? slow : -slow;
      }
      if (this.x - this.radius < walls[0]) {
        this.x = walls[0] + this.radius;
        this.vx = Math.abs(this.vx) * 0.6;
      }
      if (this.x + this.radius > walls[1]) {
        this.x = walls[1] - this.radius;
        this.vx = -Math.abs(this.vx) * 0.6;
      }
      this.spin += (this.vx * dt) / this.radius;
    }
    contains(x, y) {
      return Math.hypot(x - this.x, y - this.y) <= this.radius + 2;
    }
    grab(x, y, time) {
      this.offset = [this.x - x, this.y - y];
      this.trail = [{ x, y, time }];
      this.moved = false;
      this.held = true;
      this.vx = this.vy = 0;
    }
    drag(x, y, time) {
      this.trail.push({ x, y, time });
      this.trail = this.trail.filter((p) => time - p.time <= 0.1);
      if (Math.hypot(x - this.trail[0].x, y - this.trail[0].y) > 2)
        this.moved = true;
      this.x = x + this.offset[0];
      this.y = y + this.offset[1];
    }
    release(x, y, time) {
      this.held = false;
      const first = this.trail[0];
      if (this.moved && first && time - first.time > 0.001) {
        const dt = time - first.time,
          vx = (x - first.x) / dt,
          vy = (y - first.y) / dt,
          s = Math.hypot(vx, vy),
          k = s > 1400 ? 1400 / s : 1;
        this.kick(vx * k, vy * k);
      } else
        this.kick(
          (x < this.x ? 1 : -1) * (140 + 80 * this.random()),
          -(180 + 100 * this.random()),
        );
      this.trail = [];
    }
    snapshot() {
      return {
        x: this.x,
        y: this.y,
        radius: this.radius,
        spin: this.spin,
        held: this.held,
        speed: this.speed,
        isResting: this.isResting,
      };
    }
  }
  function drawYarn(ctx, r, spin = 0) {
    ctx.save();
    ctx.translate(r, r);
    ctx.rotate(spin);
    ctx.translate(-r, -r);
    ctx.save();
    ctx.beginPath();
    ctx.ellipse(r, r, r - 0.6, r - 0.6, 0, 0, Math.PI * 2);
    ctx.clip();
    const grad = ctx.createRadialGradient(r * 0.7, r * 0.65, 0, r, r, r * 1.05);
    grad.addColorStop(0, "#ffccd6");
    grad.addColorStop(0.6, "#ed8ca3");
    grad.addColorStop(1, "#c76680");
    ctx.fillStyle = grad;
    ctx.fillRect(0, 0, r * 2, r * 2);
    ctx.lineCap = "round";
    [0.15, 0.95, 1.75, 2.45].forEach((angle, i) => {
      ctx.save();
      ctx.translate(r, r);
      ctx.rotate(-angle);
      for (let k = 0; k < 4; k++) {
        const inset = k * r * 0.16 - r * 0.2;
        ctx.strokeStyle = `rgba(255,${Math.round((0.88 - 0.05 * i) * 255)},230,${0.55 - 0.08 * k})`;
        ctx.lineWidth = Math.max(0.6, r * 0.07);
        ctx.beginPath();
        ctx.ellipse(0, -inset, r * 1.02, r * 0.42, 0, 0, Math.PI * 2);
        ctx.stroke();
      }
      ctx.restore();
    });
    ctx.restore();
    ctx.strokeStyle = "rgba(158,77,102,.35)";
    ctx.lineWidth = Math.max(0.6, r * 0.05);
    ctx.beginPath();
    ctx.ellipse(r, r, r - 0.6, r - 0.6, 0, 0, Math.PI * 2);
    ctx.stroke();
    ctx.restore();
  }
  const api = { YarnBall, drawYarn };
  if (typeof module !== "undefined") module.exports = api;
  else root.PetBall = api;
})(globalThis);
