"use strict";
// CompanionService.accept/drain and AIReminderPolicy, adapted from the Mac source.
// Account epochs are capability objects in a WeakMap: never fields in renderer data.
const { randomUUID } = require("node:crypto");
const identities = new WeakMap();
function bindReminderIdentity(value, identity) {
  if (value && typeof value === "object" && identity)
    identities.set(value, identity);
  return value;
}
const stamp = (v) =>
  typeof v === "number" && Number.isFinite(v)
    ? v
    : typeof v === "string"
      ? Date.parse(v)
      : NaN;
const text = (v, limit) => (typeof v === "string" ? v.slice(0, limit) : "");
const kinds = new Set([
  "threshold-80",
  "threshold-100",
  "weekly-limit",
  "session-limit",
  "reset",
  "waiting",
  "ended",
]);
function muted(prefs, now) {
  if (stamp(prefs.mutedUntil) > now) return true;
  if (stamp(prefs.quietOverrideUntil) > now) return false;
  const start = prefs.quietStart,
    end = prefs.quietEnd;
  if (
    !Number.isInteger(start) ||
    !Number.isInteger(end) ||
    start < 0 ||
    end < 0 ||
    start >= 1440 ||
    end >= 1440 ||
    start === end
  )
    return false;
  const date = new Date(now),
    minute = date.getHours() * 60 + date.getMinutes();
  return start < end
    ? minute >= start && minute < end
    : minute >= start || minute < end;
}
function allowed(event, prefs) {
  return (
    !(prefs.mutedProviders || []).includes(event.provider) &&
    !(event.kind === "waiting" && prefs.notifyWaiting === false) &&
    !(event.kind === "ended" && prefs.notifyEnded === false) &&
    !(event.kind === "reset" && prefs.notifyReset === false)
  );
}
function normalize(event, now) {
  if (
    !event ||
    !["codex", "claude"].includes(event.provider) ||
    !kinds.has(event.kind)
  )
    return null;
  const created = Number.isFinite(stamp(event.createdAt))
    ? stamp(event.createdAt)
    : now;
  const expires = Number.isFinite(stamp(event.expiresAt))
    ? stamp(event.expiresAt)
    : created + 300000;
  if (
    Math.abs(created) > 8640000000000000 ||
    Math.abs(expires) > 8640000000000000
  )
    return null;
  const priority =
    Number.isInteger(event.priority) &&
    event.priority >= 0 &&
    event.priority <= 2
      ? event.priority
      : event.kind === "reset" || event.kind === "ended"
        ? 2
        : event.kind === "threshold-80"
          ? 1
          : 0;
  const result = {
    id: text(event.id, 300) || randomUUID(),
    provider: event.provider,
    kind: event.kind,
    title: text(event.title, 160),
    body: text(event.body, 1000),
    priority,
    createdAt: new Date(created).toISOString(),
    expiresAt: new Date(expires).toISOString(),
  };
  if (typeof event.sessionID === "string" && event.sessionID)
    result.sessionID = text(event.sessionID, 300);
  else
    result.windowID =
      text(event.windowID, 100) ||
      (event.kind === "weekly-limit"
        ? event.provider === "codex"
          ? "secondary"
          : "weekly_all"
        : event.provider === "codex"
          ? "primary"
          : "session");
  return bindReminderIdentity(result, identities.get(event));
}
function list(usage) {
  return Array.isArray(usage)
    ? usage
    : usage && typeof usage === "object"
      ? Object.values(usage)
      : [];
}
function relevant(event, usage, sessions, now) {
  if (!(stamp(event.expiresAt) > now)) return false;
  if (event.sessionID) {
    const session = sessions.find(
      (s) => s.provider === event.provider && s.id === event.sessionID,
    );
    return (
      session?.evidence === "explicit" &&
      (event.kind === "waiting"
        ? session.state === "waiting"
        : ["ended", "idle", "success"].includes(session.state))
    );
  }
  const reading = list(usage).find((u) => u.provider === event.provider),
    identity = identities.get(event);
  if (
    !reading ||
    reading.status !== "ok" ||
    !identity ||
    identity !== identities.get(reading) ||
    !(now - stamp(reading.sourceAt || reading.observedAt) <= 900000)
  )
    return false;
  const window = reading.windows?.find((w) => w.id === event.windowID);
  if (!window || window.unlimited || !Number.isFinite(window.usedPercent))
    return false;
  if (event.kind === "reset") return true;
  if (["weekly-limit", "session-limit"].includes(event.kind))
    return window.usedPercent >= 100;
  return event.kind === "threshold-80"
    ? window.usedPercent >= 80
    : event.kind === "threshold-100" && window.usedPercent >= 100;
}
class ReminderCenter {
  #history = [];
  #queue = [];
  #unread = new Set();
  #epochs = new Map();
  #lastPresented = -Infinity;
  #now;
  constructor({ now = Date.now } = {}) {
    this.#now = () => Number(now());
  }
  #prune() {
    const now = this.#now();
    this.#history = this.#history
      .filter((e) => now - stamp(e.createdAt) < 86400000)
      .slice(-100);
    const ids = new Set(this.#history.map((e) => e.id));
    this.#unread = new Set([...this.#unread].filter((id) => ids.has(id)));
  }
  #sync(usage) {
    for (const reading of list(usage)) {
      const provider = reading?.provider;
      if (!["claude", "codex"].includes(provider)) continue;
      const epoch = identities.get(reading);
      if (reading.status === "disconnected") {
        this.clearProvider(provider);
        continue;
      }
      if (!epoch) continue;
      const old = this.#epochs.get(provider);
      if (old && old !== epoch) this.clearProvider(provider);
      this.#epochs.set(provider, epoch);
    }
  }
  accept(events, usage = [], sessions = [], prefs = {}) {
    this.#sync(usage);
    const now = this.#now();
    this.#prune();
    for (const input of (Array.isArray(events) ? events : []).slice(0, 1000)) {
      const e = normalize(input, now);
      if (!e || this.#history.some((h) => h.id === e.id)) continue;
      this.#history.push(e);
      this.#unread.add(e.id);
      if (!muted(prefs, now) && allowed(e, prefs)) this.#queue.push(e);
    }
    this.#prune();
    this.#queue.sort(
      (a, b) =>
        a.priority - b.priority || stamp(a.createdAt) - stamp(b.createdAt),
    );
    this.#queue = this.#queue.slice(0, 10);
    return this.snapshot();
  }
  drain({ usage = [], sessions = [], prefs = {}, canPresent = false } = {}) {
    this.#sync(usage);
    this.#prune();
    const now = this.#now();
    if (muted(prefs, now)) {
      this.#queue = [];
      return null;
    }
    const enabled = prefs.enabled || prefs.providers;
    this.#queue = this.#queue.filter(
      (e) =>
        (!Array.isArray(enabled) || enabled.includes(e.provider)) &&
        allowed(e, prefs) &&
        relevant(e, usage, sessions, now),
    );
    const e = this.#queue[0];
    if (
      !e ||
      now - this.#lastPresented < (e.priority === 0 ? 8000 : 15000) ||
      !canPresent
    )
      return null;
    this.#queue.shift();
    this.#lastPresented = now;
    return structuredClone(e);
  }
  snapshot() {
    this.#prune();
    return {
      history: structuredClone(this.#history),
      unreadCount: this.#unread.size,
      unreadIDs: [...this.#unread],
    };
  }
  clearPending() {
    this.#queue = [];
  }
  markRead() {
    this.#unread.clear();
    return this.snapshot();
  }
  clearProvider(provider) {
    this.#history = this.#history.filter((e) => e.provider !== provider);
    this.#queue = this.#queue.filter((e) => e.provider !== provider);
    this.#epochs.delete(provider);
    this.#prune();
  }
}
module.exports = { ReminderCenter, bindReminderIdentity };
