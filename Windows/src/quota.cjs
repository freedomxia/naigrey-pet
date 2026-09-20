"use strict";
// Protocols and reminder rules adapted from Codenotch v1.14.0 (MIT),
// Copyright (c) 2026 Vinz. See ../../THIRD_PARTY_NOTICES.md.
const { EventEmitter } = require("node:events");
const fs = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");
const { createHash } = require("node:crypto");
const { ClaudeSources } = require("./quota-claude.cjs");
const { bindReminderIdentity } = require("./reminder-center.cjs");
const PROVIDERS = ["codex", "claude"];
const ENDPOINTS = Object.freeze({
  codex: "https://chatgpt.com/backend-api/wham/usage",
  claude: "https://api.anthropic.com/api/oauth/usage",
});
const SOURCES = {
  codex: "Codex 本机登录 · 在线额度",
  claude: "Claude Code OAuth · 在线额度",
};
class QuotaError extends Error {
  constructor(status, message, retryAfter = 0) {
    super(message);
    this.status = status;
    this.retryAfter = retryAfter;
  }
}
const invalid = () => new QuotaError("unsupported", "额度来源格式暂不支持。");
const number = (v) => typeof v === "number" && Number.isFinite(v);
const percent = (v) => number(v) && v >= 0 && v <= 100;
const nonempty = (v) => typeof v === "string" && v.trim() && !/[\r\n]/.test(v);
const iso = (n) =>
  number(n) && n > 0 && n <= 8640000000000000
    ? new Date(n).toISOString()
    : null;
function isoDate(v) {
  if (typeof v !== "string") return null;
  const calendar = v.slice(0, 10);
  if (
    new Date(`${calendar}T00:00:00Z`).toString() === "Invalid Date" ||
    new Date(`${calendar}T00:00:00Z`).toISOString().slice(0, 10) !== calendar
  )
    return null;
  return /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)$/.test(v)
    ? iso(Date.parse(v))
    : null;
}
function object(value) {
  try {
    const v =
      typeof value === "string" || Buffer.isBuffer(value)
        ? JSON.parse(String(value))
        : value;
    if (v && typeof v === "object" && !Array.isArray(v)) return v;
  } catch {}
  throw invalid();
}
function parseCodex(value, now = Date.now()) {
  const data = object(value),
    windows = [];
  function add(id, w, group = "") {
    if (
      !w ||
      !percent(w.used_percent) ||
      windows.some((item) => item.id === id)
    )
      return;
    const resetsAt =
      (number(w.reset_at) ? iso(w.reset_at * 1000) : null) ||
      (number(w.reset_after_seconds) && w.reset_after_seconds >= 0
        ? iso(Number(now) + w.reset_after_seconds * 1000)
        : null);
    const seconds = w.limit_window_seconds;
    const label =
      seconds === 18000
        ? "5 小时"
        : seconds === 604800
          ? "每周"
          : seconds > 0
            ? `${Math.round(seconds / 3600)} 小时`
            : id.includes("secondary")
              ? "每周"
              : "当前窗口";
    windows.push({
      id,
      label: group ? `${group} · ${label}` : label,
      usedPercent: w.used_percent,
      resetsAt,
    });
  }
  add("primary", data.rate_limit?.primary_window);
  add("secondary", data.rate_limit?.secondary_window);
  for (const extra of Array.isArray(data.additional_rate_limits)
    ? data.additional_rate_limits
    : []) {
    if (
      extra &&
      /spark/i.test(`${extra.limit_name || ""} ${extra.metered_feature || ""}`)
    ) {
      add("spark", extra.rate_limit?.primary_window, "Spark");
      add("spark-secondary", extra.rate_limit?.secondary_window, "Spark");
    }
  }
  add("code-review", data.code_review_rate_limit?.primary_window, "代码审查");
  add(
    "code-review-secondary",
    data.code_review_rate_limit?.secondary_window,
    "代码审查",
  );
  if (!windows.length) throw invalid();
  return windows;
}
function parseClaude(value) {
  const data = object(value),
    windows = [];
  const labels = {
    session: "当前会话",
    weekly_all: "所有模型 · 每周",
    weekly_opus: "Opus · 每周",
    weekly_sonnet: "Sonnet · 每周",
    weekly_scoped: "指定模型 · 每周",
  };
  function add(id, p, reset, label) {
    if (
      typeof id !== "string" ||
      !id ||
      id.length > 100 ||
      !percent(p) ||
      !isoDate(reset) ||
      windows.some((w) => w.id === id)
    )
      return;
    windows.push({
      id,
      label:
        typeof label === "string" && label.trim()
          ? label.slice(0, 100)
          : labels[id] || id,
      usedPercent: p,
      resetsAt: isoDate(reset),
    });
  }
  for (const limit of Array.isArray(data.limits) ? data.limits : [])
    if (limit)
      add(
        limit.kind,
        limit.percent,
        limit.resets_at,
        limit.scope?.model?.display_name,
      );
  add("session", data.five_hour?.utilization, data.five_hour?.resets_at);
  add("weekly_all", data.seven_day?.utilization, data.seven_day?.resets_at);
  const rank = (id) => (id === "session" ? 0 : id === "weekly_all" ? 1 : 2);
  windows.sort((a, b) => rank(a.id) - rank(b.id) || a.id.localeCompare(b.id));
  if (!windows.length) throw invalid();
  return windows;
}
class ReminderTracker {
  #states = new Map();
  #weekly = new Map();
  forget(provider) {
    this.#states.delete(provider);
    this.#weekly.delete(provider);
  }
  observe(snapshot, fingerprint) {
    if (snapshot.status !== "ok") return [];
    const headline = snapshot.windows.find(
      (w) => w.id === "primary" || w.id === "session",
    );
    const weekly = snapshot.windows.find(
      (w) => w.id === "secondary" || w.id === "weekly_all",
    );
    const weeklyEvents = [];
    if (weekly) {
      const previous = this.#weekly.get(snapshot.provider);
      const old = previous?.fingerprint === fingerprint ? previous : null;
      const exhausted = weekly.usedPercent >= 100;
      let latched = old?.exhausted || false;
      if (
        weekly.usedPercent < 95 ||
        (weekly.resetsAt &&
          old?.reset &&
          Date.parse(weekly.resetsAt) > Date.parse(old.reset))
      )
        latched = false;
      if (old && exhausted && !latched)
        weeklyEvents.push({
          provider: snapshot.provider,
          title:
            (snapshot.provider === "codex" ? "Codex" : "Claude") + " 额度提醒",
          body: weekly.label + "额度已用完。",
          kind: "weekly-limit",
        });
      this.#weekly.set(snapshot.provider, {
        fingerprint,
        exhausted: latched || exhausted,
        reset: weekly.resetsAt,
      });
    }
    if (!headline) return weeklyEvents;
    const p = headline.usedPercent,
      level = p >= 100 ? 100 : p >= 80 ? 80 : 0;
    const old = this.#states.get(snapshot.provider),
      changed = old && old.fingerprint !== fingerprint;
    const state =
      !old || changed
        ? {
            fingerprint,
            level: 0,
            p,
            peak: p,
            reset: headline.resetsAt,
            lastReset: headline.resetsAt,
            sessionExhausted: p >= 100,
          }
        : old;
    const events = [],
      name = snapshot.provider === "codex" ? "Codex" : "Claude";
    const emit = (kind, body) =>
      events.push({
        provider: snapshot.provider,
        title: `${name} 额度提醒`,
        body,
        kind,
      });
    for (const threshold of [80, 100])
      if (threshold > state.level && threshold <= level)
        emit(
          `threshold-${threshold}`,
          `${headline.label}已用 ${Math.round(p)}%。`,
        );
    if (old && !changed) {
      const rolled =
        headline.resetsAt &&
        state.reset &&
        headline.resetsAt !== state.reset &&
        (!state.lastReset ||
          Date.parse(headline.resetsAt) > Date.parse(state.lastReset));
      const dropped =
        p < state.p && (state.p - p >= 20 || (state.peak >= 30 && p <= 10));
      if ((rolled || dropped) && state.peak >= 15) {
        emit("reset", `${headline.label}额度已恢复。`);
        state.peak = p;
        state.lastReset = headline.resetsAt;
      }
      if (
        (headline.resetsAt &&
          state.reset &&
          Date.parse(headline.resetsAt) > Date.parse(state.reset)) ||
        p < 95
      )
        state.sessionExhausted = false;
      if (p >= 100 && !state.sessionExhausted) {
        emit("session-limit", headline.label + "额度已用完。");
        state.sessionExhausted = true;
      }
    }
    Object.assign(state, {
      level,
      p,
      peak: Math.max(state.peak, p),
      reset: headline.resetsAt,
    });
    this.#states.set(snapshot.provider, state);
    return [...events, ...weeklyEvents];
  }
}
async function boundedFile(filename) {
  let file;
  try {
    file = await fs.open(filename, "r");
    const stat = await file.stat();
    if (!stat.isFile() || stat.size > 1000000) throw invalid();
    const buffer = Buffer.alloc(1000001);
    const { bytesRead } = await file.read(buffer, 0, buffer.length, 0);
    if (bytesRead > 1000000) throw invalid();
    return object(buffer.subarray(0, bytesRead));
  } catch (error) {
    if (error instanceof QuotaError) throw error;
    throw new QuotaError(
      error.code === "EACCES" ? "accessDenied" : "needsAuth",
      "无法读取本机登录文件，请在原应用完成登录。",
    );
  } finally {
    await file?.close();
  }
}
function credentials(provider, root, now) {
  let token, account, identity;
  if (provider === "codex") {
    token = root.tokens?.access_token;
    account = root.tokens?.account_id;
    if (!nonempty(token) || !nonempty(account))
      throw new QuotaError(
        root.OPENAI_API_KEY ? "unsupported" : "needsAuth",
        "请使用 Codex 账号登录；API Key 不提供订阅额度。",
      );
    let claims;
    try {
      claims = JSON.parse(
        Buffer.from(token.split(".")[1] || "", "base64url").toString(),
      );
    } catch {}
    if (number(claims?.exp) && claims.exp * 1000 <= now)
      throw new QuotaError(
        "needsAuth",
        "Codex 登录已过期，请在原应用更新登录。",
      );
    identity = `codex:${account}`;
  } else {
    token = root.claudeAiOauth?.accessToken;
    const expiry = root.claudeAiOauth?.expiresAt;
    if (!nonempty(token) || !number(expiry) || expiry <= now)
      throw new QuotaError(
        "needsAuth",
        "Claude Code 登录已过期或不可用，请在原应用更新登录。",
      );
    identity = `claude:${token}`;
  }
  return {
    token,
    account,
    fingerprint: createHash("sha256").update(identity).digest("hex"),
  };
}
async function readBody(response) {
  if (Number(response.headers.get("content-length")) > 2000000) throw invalid();
  if (!response.body) throw invalid();
  const chunks = [];
  let length = 0;
  const reader = response.body.getReader();
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > 2000000) throw invalid();
      chunks.push(Buffer.from(value));
    }
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
  return object(Buffer.concat(chunks));
}
class QuotaService extends EventEmitter {
  #home;
  #env;
  #fetch;
  #now;
  #states = new Map();
  #tracker = new ReminderTracker();
  #timer;
  #claude;
  #renewalEnabled = false;
  #rateLimits = 0;
  #backoffFile;
  #loadedBackoff = false;
  #active = false;
  #renewalPending = null;
  #renewalController = null;
  constructor({
    home = os.homedir(),
    env = process.env,
    fetchImpl = globalThis.fetch,
    now = Date.now,
    claudeAdapters = {},
    stateDirectory,
  } = {}) {
    super();
    this.#home = home;
    this.#env = { ...env };
    this.#backoffFile = path.join(
      stateDirectory || path.join(env.LOCALAPPDATA || home, "Naihui"),
      "quota-backoff.json",
    );
    this.#fetch = fetchImpl;
    this.#now = () => Number(now());
    this.#claude = new ClaudeSources({
      home,
      env: this.#env,
      now: this.#now,
      ...claudeAdapters,
      onPID: (pid) => this.emit("cli-pid", pid),
      onProcess: (event) => this.emit("cli-process", event),
    });
    for (const provider of PROVIDERS)
      this.#states.set(provider, {
        connected: false,
        lastAttempt: null,
        fingerprint: null,
        reminderIdentity: {},
        generation: 0,
        retryAt: 0,
        pending: null,
        controller: null,
        value: this.#empty(provider),
      });
  }
  #empty(provider) {
    return {
      provider,
      status: "disconnected",
      source: SOURCES[provider],
      windows: [],
      message: "尚未连接",
      observedAt: null,
    };
  }
  #state(provider) {
    if (!PROVIDERS.includes(provider))
      throw new TypeError("Unknown quota provider");
    return this.#states.get(provider);
  }
  snapshot() {
    return PROVIDERS.map((p) => {
      const state = this.#states.get(p);
      return bindReminderIdentity(
        structuredClone(state.value),
        state.reminderIdentity,
      );
    });
  }
  #rememberIdentity(state, fingerprint) {
    if (state.fingerprint !== fingerprint) state.reminderIdentity = {};
    state.fingerprint = fingerprint;
  }
  #remind(reminder, state) {
    this.emit(
      "reminder",
      bindReminderIdentity(reminder, state.reminderIdentity),
    );
  }
  #change() {
    this.emit("change", this.snapshot());
  }
  setClaudeRenewalEnabled(enabled) {
    this.#renewalEnabled = enabled === true;
    this.#claude.setRenewalEnabled(this.#renewalEnabled);
    if (!this.#renewalEnabled) {
      this.#cancelRenewal();
      const state = this.#state("claude");
      state.generation++;
      state.controller?.abort();
      state.pending = null;
    }
  }
  async connect(provider) {
    const state = this.#state(provider);
    state.connected = true;
    if (state.retryAt > this.#now()) {
      state.value = {
        ...this.#empty(provider),
        status: "error",
        message: "额度接口限流，稍后重试。",
      };
      this.#change();
    }
    return this.refresh(provider);
  }
  disconnect(provider) {
    const state = this.#state(provider);
    state.connected = false;
    state.generation++;
    state.controller?.abort();
    state.pending = null;
    state.value = this.#empty(provider);
    this.#tracker.forget(provider);
    if (provider === "claude") {
      this.#cancelRenewal();
      this.#claude.forget();
    }
    this.#change();
  }
  setActive(active) {
    this.#active = active === true;
  }
  start() {
    if (!this.#timer) {
      this.#timer = setInterval(() => {
        void this.#considerRenewal();
        let aged = false;
        for (const [provider, state] of this.#states) {
          if (
            state.value.status === "ok" &&
            this.#now() -
              Date.parse(state.value.sourceAt || state.value.observedAt) >
              900000
          ) {
            state.value.status = "stale";
            aged = true;
          }
          const resetDue = state.value.windows.some(
            (w) => w.resetsAt && Date.parse(w.resetsAt) <= this.#now(),
          );
          const interval = this.#active || resetDue ? 60000 : 300000;
          if (
            state.lastAttempt === null ||
            this.#now() - state.lastAttempt >= interval
          )
            void this.refresh(provider);
        }
        if (aged) this.#change();
      }, 60000);
      this.#timer.unref?.();
    }
    return this;
  }
  stop() {
    clearInterval(this.#timer);
    this.#timer = null;
    this.#cancelRenewal();
    this.#claude.forget();
    for (const state of this.#states.values()) {
      state.generation++;
      state.controller?.abort();
      state.pending = null;
    }
  }
  async refresh(provider) {
    const providers = provider === undefined ? PROVIDERS : [provider];
    await Promise.all(
      providers.map((p) => {
        const state = this.#state(p);
        if (!state.connected || (p !== "claude" && state.retryAt > this.#now()))
          return;
        if (state.pending) return state.pending;
        state.lastAttempt = this.#now();
        const generation = state.generation;
        const pending = this.#read(p, state, generation).finally(() => {
          if (state.pending === pending) state.pending = null;
        });
        state.pending = pending;
        return pending;
      }),
    );
    return this.snapshot();
  }
  #cancelRenewal() {
    this.#renewalController?.abort();
    this.#renewalController = null;
    this.#renewalPending = null;
  }
  #considerRenewal(fromRead = false) {
    const state = this.#state("claude");
    if (
      !state.connected ||
      !this.#renewalEnabled ||
      (state.pending && !fromRead)
    )
      return Promise.resolve();
    if (this.#renewalPending) return this.#renewalPending;
    const controller = new AbortController(),
      generation = state.generation;
    this.#renewalController = controller;
    const pending = this.#claude.renewal
      .consider(true, controller.signal)
      .then((outcome) => {
        if (
          outcome &&
          !controller.signal.aborted &&
          state.connected &&
          generation === state.generation &&
          this.#renewalEnabled
        )
          this.emit("renewal", outcome);
      })
      .catch(() => {})
      .finally(() => {
        if (this.#renewalPending === pending) {
          this.#renewalPending = null;
          this.#renewalController = null;
        }
      });
    this.#renewalPending = pending;
    return pending;
  }
  async #saveBackoff(until) {
    const temp = this.#backoffFile + ".tmp";
    try {
      await fs.mkdir(path.dirname(this.#backoffFile), { recursive: true });
      await fs.writeFile(temp, JSON.stringify({ until }), { mode: 0o600 });
      await fs.rename(temp, this.#backoffFile);
    } catch {
      await fs.rm(temp, { force: true }).catch(() => {});
    }
  }
  async #read(provider, state, generation) {
    const valid = () => state.connected && generation === state.generation;
    let timer, currentFingerprint;
    const controller = new AbortController();
    state.controller = controller;
    try {
      if (provider === "claude") {
        if (!this.#loadedBackoff) {
          this.#loadedBackoff = true;
          try {
            const saved = await boundedFile(this.#backoffFile);
            if (number(saved.until))
              state.retryAt = Math.max(
                state.retryAt,
                Math.min(saved.until, this.#now() + 900000),
              );
          } catch {}
        }
        await this.#considerRenewal(true);
        if (!valid()) return;
        const local = await this.#claude.local(controller.signal);
        if (!valid()) return;
        if (local) {
          this.#rememberIdentity(state, local.fingerprint);
          state.value = {
            provider,
            status: "ok",
            source: local.source,
            windows: local.windows,
            message: null,
            sourceAt: new Date(local.capturedAt).toISOString(),
            observedAt: new Date(this.#now()).toISOString(),
          };
          const reminders = this.#tracker.observe(
            state.value,
            local.fingerprint,
          );
          this.#change();
          if (this.#now() - local.capturedAt <= 900000)
            for (const reminder of reminders) this.#remind(reminder, state);
          return;
        }
        if (state.retryAt > this.#now())
          throw new QuotaError("error", "Claude 额度接口限流，稍后重试。");
      }
      const filename =
        provider === "codex"
          ? path.join(
              this.#env.CODEX_HOME || path.join(this.#home, ".codex"),
              "auth.json",
            )
          : path.join(
              this.#env.CLAUDE_CONFIG_DIR || path.join(this.#home, ".claude"),
              ".credentials.json",
            );
      let credential = credentials(
        provider,
        await boundedFile(filename),
        this.#now(),
      );
      if (!valid()) return;
      const headers = {
        Authorization: `Bearer ${credential.token}`,
        Accept: "application/json",
        "Cache-Control": "no-cache, no-store",
      };
      if (provider === "codex")
        headers["ChatGPT-Account-Id"] = credential.account;
      else headers["anthropic-beta"] = "oauth-2025-04-20";
      if (provider === "claude")
        credential.fingerprint = await this.#claude.identity();
      currentFingerprint = credential.fingerprint;
      if (!valid()) return;
      const timeout = new Promise((_, reject) => {
        timer = setTimeout(() => {
          controller.abort();
          reject(new QuotaError("error", "额度请求超时，请稍后重试。"));
        }, 15000);
        timer.unref?.();
      });
      const request = (async () => {
        let response;
        for (let attempt = 0; attempt < 2; attempt++) {
          response = await this.#fetch(ENDPOINTS[provider], {
            method: "GET",
            headers,
            redirect: "error",
            signal: controller.signal,
            cache: "no-store",
            credentials: "omit",
          });
          if (
            provider !== "claude" ||
            ![401, 403].includes(response.status) ||
            attempt > 0
          )
            break;
          await response.body?.cancel().catch(() => {});
          credential = credentials(
            provider,
            await boundedFile(filename),
            this.#now(),
          );
          credential.fingerprint = await this.#claude.identity();
          currentFingerprint = credential.fingerprint;
          if (controller.signal.aborted || !valid())
            throw new Error("cancelled");
          headers.Authorization = "Bearer " + credential.token;
        }
        if (response.status < 200 || response.status >= 300)
          await response.body?.cancel().catch(() => {});
        if ([401, 403].includes(response.status))
          throw new QuotaError(
            "needsAuth",
            "登录失效或未授权，请在原应用重新登录。",
          );
        if (response.status === 429) {
          const hint = response.headers.get("retry-after");
          const seconds =
            hint && /^\d+(?:\.\d+)?$/.test(hint)
              ? Number(hint)
              : (Date.parse(hint) - this.#now()) / 1000;
          throw new QuotaError(
            "error",
            "额度接口限流，稍后重试。",
            Number.isFinite(seconds) ? Math.max(60, seconds) : 60,
          );
        }
        if (response.status < 200 || response.status >= 300)
          throw new QuotaError(
            "error",
            `额度接口暂不可用（HTTP ${response.status}）。`,
          );
        const data = await readBody(response);
        return provider === "codex"
          ? parseCodex(data, this.#now())
          : parseClaude(data);
      })();
      const windows = await Promise.race([request, timeout]);
      if (!valid()) return;
      state.retryAt = 0;
      if (provider === "claude") {
        this.#rateLimits = 0;
        await this.#saveBackoff(0);
      }
      if (!valid()) return;
      this.#rememberIdentity(state, credential.fingerprint);
      state.value = {
        provider,
        status: "ok",
        source: SOURCES[provider],
        windows,
        message: null,
        sourceAt: new Date(this.#now()).toISOString(),
        observedAt: new Date(this.#now()).toISOString(),
      };
      const reminders = this.#tracker.observe(
        state.value,
        credential.fingerprint,
      );
      this.#change();
      for (const reminder of reminders) this.#remind(reminder, state);
    } catch (error) {
      if (!valid()) return;
      const known =
        error instanceof QuotaError
          ? error
          : new QuotaError("error", "额度请求未完成，请检查网络后重试。");
      if (known.retryAfter) {
        const delay =
          provider === "claude"
            ? Math.min(
                900,
                Math.max(
                  60 * 2 ** Math.min(this.#rateLimits++, 4),
                  known.retryAfter,
                ),
              )
            : known.retryAfter;
        state.retryAt = this.#now() + delay * 1000;
        if (provider === "claude") await this.#saveBackoff(state.retryAt);
      }
      if (!valid()) return;
      const previous = state.value;
      const preserve =
        ["error", "accessDenied"].includes(known.status) &&
        currentFingerprint &&
        currentFingerprint === state.fingerprint &&
        previous.windows.length;
      state.value = preserve
        ? {
            ...previous,
            status:
              this.#now() -
                Date.parse(previous.sourceAt || previous.observedAt) >
              900000
                ? "stale"
                : "ok",
            message: known.message,
            observedAt: new Date(this.#now()).toISOString(),
          }
        : {
            provider,
            status: known.status,
            source: SOURCES[provider],
            windows: [],
            message: known.message,
            observedAt: null,
          };
      this.#change();
    } finally {
      clearTimeout(timer);
      if (valid()) state.controller = null;
    }
  }
}
module.exports = { QuotaService, parseCodex, parseClaude, ReminderTracker };
