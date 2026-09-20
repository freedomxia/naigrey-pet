"use strict";
// Pure scheduling port of Source/main.swift. Times are milliseconds except the
// explicitly named idleSeconds and native senses.keyAge (seconds).
function dayKey(date) {
  const d = new Date(date.getTime() - 6 * 3600000);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}
function greeting(date) {
  const hour = date.getHours();
  return hour >= 5 && hour < 11
    ? "早上好～"
    : hour >= 23 || hour < 5
      ? "这么晚还在呀"
      : "你回来啦～";
}
class Companion {
  constructor({ now = Date.now, random = Math.random, onceState = {} } = {}) {
    const time = typeof now === "function" ? now() : now;
    Object.assign(this, {
      clock: typeof now === "function" ? now : Date.now,
      random,
      onceState,
      activeSince: time,
      lastBreakNudge: 0,
      nextAction: time + 5000,
      company: "none",
      typeRate: 1,
      sleeping: false,
      autoSlept: false,
      napUntil: null,
      yawnedWhileIdle: false,
      lastPrefs: {},
      lastDate: new Date(time),
      lastPhase: "idle",
    });
  }
  result(extra = {}) {
    return { company: this.company, typeRate: this.typeRate, ...extra };
  }
  once(rule, date) {
    const key = dayKey(date);
    if (this.onceState[rule] === key) return false;
    this.onceState[rule] = key;
    return true;
  }
  sleep(auto, now, nap = null) {
    this.sleeping = true;
    this.autoSlept = auto;
    this.napUntil = nap === null ? null : now + nap;
    this.company = "none";
    this.typeRate = 1;
    return this.result({ action: "sleep" });
  }
  wake(now, bubble) {
    this.sleeping = false;
    this.autoSlept = false;
    this.napUntil = null;
    this.nextAction = now + 6000;
    this.activeSince = now;
    return this.result({ action: "idle", ...(bubble ? { bubble } : {}) });
  }
  manual(action, now = this.clock()) {
    this.nextAction = now + 6000;
    if (action === "sleep") return this.sleep(false, now);
    if (
      [
        "idle",
        "wake",
        "stop",
        "drag",
        "drag-start",
        "wave",
        "walk",
        "stretch",
        "yawn",
        "play",
        "type",
        "music",
      ].includes(action)
    ) {
      this.sleeping = false;
      this.autoSlept = false;
      this.napUntil = null;
    }
    if (!["type", "music", "blink", "meow"].includes(action)) {
      this.company = "none";
      this.typeRate = 1;
    }
    return this.result();
  }
  locked(now = this.clock(), prefs = this.lastPrefs) {
    if (prefs.routine === false || this.sleeping) return this.result();
    return this.sleep(true, now);
  }
  unlocked(now = this.clock(), date = new Date(now)) {
    return this.autoSlept ? this.wake(now, greeting(date)) : this.result();
  }
  tick({
    now = this.clock(),
    date = new Date(now),
    idleSeconds = null,
    senses = {},
    prefs = {},
    phase = "idle",
    dragging = false,
    playing = false,
  } = {}) {
    this.lastPrefs = prefs;
    this.lastDate = date;
    const idle =
      Number.isFinite(idleSeconds) && idleSeconds >= 0 ? idleSeconds : null;
    // Recognize phase transitions, not a stale sleep frame after issuing wake.
    const previousPhase = this.lastPhase;
    this.lastPhase = phase;
    if (phase === "sleep" && previousPhase !== "sleep" && !this.sleeping) {
      this.sleeping = true;
      this.autoSlept = false;
    }
    if (
      phase === "idle" &&
      ["sleep", "lieDown", "wake"].includes(previousPhase)
    ) {
      this.sleeping = false;
      this.autoSlept = false;
      this.napUntil = null;
    }
    this.typeRate = Number.isFinite(senses.typingRate)
      ? Math.max(0.25, Math.min(3, senses.typingRate))
      : 1;
    if (dragging) {
      this.company = "none";
      return this.result();
    }
    if (this.sleeping && this.napUntil !== null && now >= this.napUntil)
      return this.wake(now);
    if (prefs.routine !== false) {
      if (idle !== null && idle > 300) this.activeSince = now;
      if (this.sleeping) {
        this.company = "none";
        if (this.autoSlept && idle !== null && idle < 1.5)
          return this.wake(now, greeting(date));
        return this.result();
      }
      if (phase === "idle" && !playing && idle !== null) {
        const hour = date.getHours(),
          minute = date.getMinutes(),
          late = hour >= 23 || hour < 5;
        if (idle < 5) this.yawnedWhileIdle = false;
        if (idle > (late ? 40 : 90) && !this.yawnedWhileIdle) {
          this.yawnedWhileIdle = true;
          return this.result({ action: "yawn" });
        }
        if (idle > (late ? 100 : 240)) return this.sleep(true, now);
        if (
          idle < 30 &&
          now - this.activeSince > 50 * 60000 &&
          now - this.lastBreakNudge > 25 * 60000
        ) {
          this.lastBreakNudge = now;
          return this.result({
            action: "stretch",
            bubble: "用电脑快一小时啦，起来伸个懒腰吧～",
          });
        }
        if (idle < 20) {
          if (hour >= 5 && hour < 11 && this.once("morning", date))
            return this.result({
              action: "stretch",
              bubble: "早上好～ 今天也加油！",
            });
          if (
            ((hour === 11 && minute >= 45) || hour === 12) &&
            this.once("lunch", date)
          )
            return this.result({ action: "wave", bubble: "该吃午饭啦～" });
          if (hour >= 18 && hour < 20 && this.once("evening", date))
            return this.result({
              action: "wave",
              bubble: "辛苦啦，今天也很棒～",
            });
          if (late && this.once("late", date))
            return this.result({
              action: "yawn",
              bubble: "很晚了，早点休息吧",
            });
        }
      }
    }
    if (
      prefs.company === false ||
      prefs.companyOn === false ||
      prefs.demo ||
      playing ||
      this.sleeping
    ) {
      this.company = "none";
      this.typeRate = 1;
    } else {
      const wanted =
        idle !== null && idle > 200
          ? "none"
          : senses.typing === true
            ? "typing"
            : senses.music === true
              ? "music"
              : "none";
      if (wanted !== this.company) {
        this.company = "none";
        if (wanted !== "none" && phase === "idle") {
          this.company = wanted;
          return this.result({
            action: wanted === "typing" ? "type" : "music",
          });
        }
      }
    }
    if (this.company !== "typing") this.typeRate = 1;
    if (
      this.sleeping ||
      playing ||
      phase !== "idle" ||
      this.company !== "none" ||
      prefs.autonomous === false ||
      prefs.demo ||
      now < this.nextAction
    )
      return this.result();
    this.nextAction = now + 8000 + 8000 * this.random();
    if (Number.isFinite(senses.keyAge) && senses.keyAge < 4)
      return this.result();
    const hour = date.getHours(),
      drowsy = (hour >= 14 && hour <= 15) || hour >= 22 || hour < 6,
      roll = this.random();
    if (roll < (drowsy ? 0.16 : 0.07)) return this.result({ action: "yawn" });
    if (roll < 0.2) return this.result({ action: "meow", bubble: "喵～" });
    if (roll < 0.25) return this.result({ action: "stretch" });
    if (roll < 0.37 && prefs.roaming !== false)
      return this.result({
        action: "walk",
        duration: 5000 + 5000 * this.random(),
      });
    if (roll < 0.4)
      return this.sleep(false, now, 15000 + 15000 * this.random());
    return this.result();
  }
}
module.exports = { Companion, dayKey, greeting };
