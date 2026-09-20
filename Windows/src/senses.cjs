"use strict";
// Timing thresholds mirror Source/Senses.swift. No key codes or audio enter JS.
const { EventEmitter } = require("node:events");
const { spawn } = require("node:child_process");
const path = require("node:path");

class TypingWatch {
  constructor() {
    this.lastAge = Infinity;
    this.beats = [];
    this.typing = false;
  }
  update(now, age) {
    if (!Number.isFinite(age) || age < 0) {
      this.lastAge = Infinity;
      this.beats = [];
      this.typing = false;
      return this.snapshot();
    }
    if (age < this.lastAge && this.lastAge !== Infinity)
      this.beats.push(now - age);
    this.lastAge = age;
    this.beats = this.beats.filter((t) => now - t <= 6).slice(-64);
    if (age < 1.2 && this.beats.length >= 8 && now - this.beats[0] >= 2.5)
      this.typing = true;
    if (age > 2) this.typing = false;
    return this.snapshot();
  }
  snapshot() {
    const duration = this.beats.at(-1) - this.beats[0];
    const pace = duration > 0 ? (this.beats.length - 1) / duration : 0;
    return {
      typing: this.typing,
      pace,
      typingRate: this.typing
        ? Math.min(1.4, Math.max(0.7, 0.55 + pace * 0.13))
        : 1,
    };
  }
}
class AudioWatch {
  constructor() {
    this.playingSince = null;
    this.quietSince = 0;
    this.music = false;
  }
  update(now, active) {
    if (active === null) {
      this.playingSince = null;
      this.music = false;
      return false;
    }
    if (active) {
      this.quietSince = now;
      this.playingSince ??= now;
      if (now - this.playingSince >= 8) this.music = true;
    } else {
      this.playingSince = null;
      if (this.music && now - this.quietSince >= 4) this.music = false;
    }
    return this.music;
  }
}

class NativeSenses extends EventEmitter {
  constructor({
    helperPath = path.join(__dirname, "../native/Naigrey.Senses.exe"),
    platform = process.platform,
    spawnImpl = spawn,
    now = Date.now,
    excludedPids = [process.pid],
  } = {}) {
    super();
    Object.assign(this, { helperPath, platform, spawnImpl, now, excludedPids });
    this.child = null;
    this.pending = new Map();
    this.nextID = 0;
    this.buffer = "";
    this.typingWatch = new TypingWatch();
    this.audioWatch = new AudioWatch();
    this.value = this.empty("stopped");
  }
  empty(status) {
    return {
      status,
      typing: false,
      music: false,
      typingRate: 1,
      pace: 0,
      keyAge: null,
      doubleClickInterval: 500,
      keyboardAvailable: false,
      audioAvailable: false,
    };
  }
  snapshot() {
    return { ...this.value };
  }
  publish(value) {
    this.value = value;
    this.emit("change", this.snapshot());
  }
  start() {
    if (this.child) return this;
    if (this.platform !== "win32") {
      this.publish(this.empty("unsupported"));
      return this;
    }
    this.typingWatch = new TypingWatch();
    this.audioWatch = new AudioWatch();
    this.buffer = "";
    this.publish(this.empty("starting"));
    let child;
    try {
      child = this.spawnImpl(
        this.helperPath,
        this.excludedPids
          .filter((p) => Number.isInteger(p) && p > 0)
          .map((p) => String(p)),
        {
          windowsHide: true,
          stdio: ["pipe", "pipe", "ignore"],
          shell: false,
        },
      );
    } catch {
      this.publish(this.empty("unavailable"));
      return this;
    }
    this.child = child;
    let lastSample = this.now();
    const fail = () => {
      if (this.child !== child) return;
      this.stop();
      this.publish(this.empty("unavailable"));
    };
    child.on("error", fail);
    child.on("exit", fail);
    child.stdin.on("error", fail);
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      if (this.child !== child) return;
      this.buffer += chunk;
      if (this.buffer.length > 65536) {
        fail();
        return;
      }
      let newline;
      while ((newline = this.buffer.indexOf("\n")) >= 0) {
        const line = this.buffer.slice(0, newline);
        this.buffer = this.buffer.slice(newline + 1);
        let data;
        try {
          data = JSON.parse(line);
        } catch {
          continue;
        }
        if (!data || typeof data !== "object") continue;
        if (Number.isInteger(data.id)) {
          const waiter = this.pending.get(data.id);
          if (waiter) {
            clearTimeout(waiter.timer);
            this.pending.delete(data.id);
            waiter.resolve(
              Number.isFinite(data.startedAt) && data.startedAt > 0
                ? data.startedAt
                : null,
            );
          }
          continue;
        }
        if (data.type !== "senses") continue;
        lastSample = this.now();
        const keyboardAvailable = data.keyboardAvailable === true;
        const keyAge =
          keyboardAvailable && Number.isFinite(data.keyAge) && data.keyAge >= 0
            ? data.keyAge
            : null;
        const audioAvailable = typeof data.audioActive === "boolean";
        const typing = this.typingWatch.update(lastSample / 1000, keyAge);
        const music = this.audioWatch.update(
          lastSample / 1000,
          audioAvailable ? data.audioActive : null,
        );
        this.publish({
          status: keyboardAvailable && audioAvailable ? "ok" : "partial",
          ...typing,
          music,
          keyAge,
          keyboardAvailable,
          audioAvailable,
          doubleClickInterval:
            Number.isInteger(data.doubleClickInterval) &&
            data.doubleClickInterval >= 100 &&
            data.doubleClickInterval <= 5000
              ? data.doubleClickInterval
              : 500,
        });
      }
    });
    this.watchdog = setInterval(() => {
      if (this.now() - lastSample > 5000) fail();
    }, 1000);
    this.watchdog.unref?.();
    return this;
  }
  processStart(pid) {
    if (
      !this.child ||
      !Number.isInteger(pid) ||
      pid <= 0 ||
      pid > 2147483647 ||
      this.pending.size >= 64
    )
      return Promise.resolve(null);
    const id = ++this.nextID;
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        resolve(null);
      }, 2000);
      this.pending.set(id, { resolve, timer });
      try {
        this.child.stdin.write(JSON.stringify({ id, pid }) + "\n");
      } catch {
        clearTimeout(timer);
        this.pending.delete(id);
        resolve(null);
      }
    });
  }
  stop() {
    const child = this.child;
    this.child = null;
    clearInterval(this.watchdog);
    this.watchdog = null;
    for (const { resolve, timer } of this.pending.values()) {
      clearTimeout(timer);
      resolve(null);
    }
    this.pending.clear();
    this.buffer = "";
    if (child) {
      child.stdin.end();
      child.kill();
    }
    this.publish(this.empty("stopped"));
  }
}
module.exports = { TypingWatch, AudioWatch, NativeSenses };
