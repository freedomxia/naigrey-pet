"use strict";
// Read-only port of Source/AICompanion/Sessions.swift; never cache transcript text.
const fs = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");
const stamp = (value) =>
  Number.isFinite(value) && value > 0 && value <= 8640000000000000
    ? new Date(value).toISOString()
    : null;

function parseClaude(json, processStartedAt) {
  if (
    !json ||
    !Number.isInteger(json.pid) ||
    json.pid <= 0 ||
    json.pid > 2147483647 ||
    typeof json.cwd !== "string"
  )
    return null;
  let started = typeof json.startedAt === "number" ? json.startedAt : NaN;
  if (!Number.isFinite(started) && typeof json.procStart === "string")
    started = Date.parse(json.procStart.trim().replace(/\s+/g, " ") + " UTC");
  if (
    !stamp(started) ||
    !stamp(processStartedAt) ||
    Math.abs(started - processStartedAt) > 5000
  )
    return null;
  const state =
    json.tempo === "blocked" || json.status === "waiting"
      ? "waiting"
      : json.tempo === "active" || json.status === "busy"
        ? "busy"
        : json.tempo === "idle" || json.status === "idle"
          ? "idle"
          : "unknown";
  const updatedAt =
    stamp(json.statusUpdatedAt) || stamp(json.updatedAt) || stamp(started);
  return {
    id: `claude-${json.pid}-${Math.floor(started / 1000)}`,
    provider: "claude",
    name:
      path.win32.basename(json.cwd.replace(/[/\\]+$/, "")).slice(0, 100) ||
      "本地任务",
    state,
    evidence: state === "unknown" ? "unknown" : "explicit",
    updatedAt,
  };
}
function parseCodexTail(data, { id, modifiedAt, now = Date.now() }) {
  if (!stamp(modifiedAt)) return null;
  let currentTurn, latestState, latestTime;
  for (const line of String(data).split("\n")) {
    let json;
    try {
      json = JSON.parse(line);
    } catch {
      continue;
    }
    const p = json?.payload;
    if (
      json?.type !== "event_msg" ||
      !p ||
      !["task_started", "task_complete", "turn_aborted"].includes(p.type)
    )
      continue;
    const time =
      typeof json.timestamp === "string" ? Date.parse(json.timestamp) : NaN;
    if (!stamp(time)) continue;
    const turn =
      typeof p.turn_id === "string"
        ? p.turn_id
        : typeof p.task_id === "string"
          ? p.task_id
          : undefined;
    if (p.type === "task_started") {
      currentTurn = turn;
      latestState = "busy";
      latestTime = time;
    } else {
      if (
        currentTurn !== undefined &&
        turn !== currentTurn &&
        !(p.type === "turn_aborted" && turn === undefined)
      )
        continue;
      latestState = p.type === "turn_aborted" ? "unknown" : "ended";
      latestTime = time;
    }
  }
  if (latestState) {
    const uncertain =
      latestState === "unknown" ||
      (latestState === "busy" && now - modifiedAt > 120000);
    return {
      id,
      provider: "codex",
      name: "本地任务",
      state: uncertain ? "unknown" : latestState,
      evidence: uncertain ? "unknown" : "explicit",
      updatedAt: stamp(latestTime),
    };
  }
  const active = now - modifiedAt <= 8000;
  return {
    id,
    provider: "codex",
    name: "本地任务",
    state: active ? "busy" : "unknown",
    evidence: active ? "derived" : "unknown",
    updatedAt: stamp(modifiedAt),
  };
}
class SessionRules {
  constructor() {
    this.previous = new Map();
  }
  observe(sessions, now = Date.now()) {
    const alerts = [];
    for (const s of sessions) {
      const key = s.provider + ":" + s.id,
        old = this.previous.get(key),
        time = Date.parse(s.updatedAt);
      if (
        !old ||
        old.state === s.state ||
        old.evidence !== "explicit" ||
        s.evidence !== "explicit" ||
        !(time > Date.parse(old.updatedAt)) ||
        Math.abs(now - time) > 60000
      )
        continue;
      const waiting = s.state === "waiting" && old.state === "busy";
      const ended =
        ["ended", "success", "failure"].includes(s.state) ||
        (old.state === "busy" && s.state === "idle");
      if (!waiting && !ended) continue;
      const active = sessions.filter(
        (other) =>
          other.provider === s.provider &&
          other.id !== s.id &&
          other.state === "busy",
      ).length;
      const text = waiting
        ? "有 1 个任务等待你的操作。"
        : s.state === "failure"
          ? "有 1 个任务报告失败。"
          : "有 1 个任务本轮已结束。";
      alerts.push({
        id: `session:${key}:${time / 1000}:${s.state}`,
        provider: s.provider,
        title: `${s.provider === "codex" ? "Codex" : "Claude"} · ${s.name}`,
        body: text + (active ? `另有 ${active} 个进行中。` : ""),
        priority: waiting ? 0 : s.state === "failure" ? 1 : 2,
        createdAt: stamp(now),
        expiresAt: stamp(now + (waiting ? 300000 : 60000)),
        sessionID: s.id,
        kind: waiting ? "waiting" : "ended",
      });
    }
    this.previous = new Map(
      sessions.map((s) => [s.provider + ":" + s.id, { ...s }]),
    );
    return alerts;
  }
}
class SessionReader {
  constructor({
    home = os.homedir(),
    env = process.env,
    processStart = async () => null,
    ignoredPids = () => new Set(),
    now = Date.now,
  } = {}) {
    this.home = home;
    this.env = {
      CODEX_HOME: env.CODEX_HOME,
      CLAUDE_CONFIG_DIR: env.CLAUDE_CONFIG_DIR,
    };
    this.processStart = processStart;
    this.ignoredPids = ignoredPids;
    this.now = now;
    this.cache = new Map();
    this.generation = 0;
  }
  clearCache() {
    this.generation++;
    this.cache.clear();
  }
  async files(dir, suffix, limit = 1024) {
    const result = [];
    let entries,
      visited = 0;
    try {
      entries = await fs.opendir(dir);
      for await (const e of entries) {
        if (++visited > Math.max(limit, 1024) || result.length >= limit) break;
        if (!e.name.startsWith(".") && e.isFile() && e.name.endsWith(suffix))
          result.push(path.join(dir, e.name));
      }
    } catch {}
    return result;
  }
  async signature(file) {
    try {
      const s = await fs.lstat(file);
      return s.isFile() ? { mtime: s.mtimeMs, size: s.size } : null;
    } catch {
      return null;
    }
  }
  async bytes(file, size, tail) {
    let h;
    try {
      h = await fs.open(file, "r");
      const stat = await h.stat();
      if (!stat.isFile() || (!tail && stat.size > size)) return null;
      const start = tail ? Math.max(0, stat.size - size) : 0,
        buffer = Buffer.alloc(size + 1),
        { bytesRead } = await h.read(buffer, 0, tail ? size : size + 1, start);
      if (!tail && bytesRead > size) return null;
      let data = buffer.subarray(0, bytesRead);
      if (start > 0) {
        const nl = data.indexOf(10);
        if (nl < 0) return Buffer.alloc(0);
        data = data.subarray(nl + 1);
      }
      return data;
    } catch {
      return null;
    } finally {
      await h?.close();
    }
  }
  async read(enabled) {
    const generation = this.generation,
      now = this.now(),
      allowed = new Set(enabled),
      result = [],
      keep = new Set();
    const ignore = () =>
      new Set(
        typeof this.ignoredPids === "function"
          ? this.ignoredPids()
          : this.ignoredPids,
      );
    const store = (file, value) => {
      if (generation !== this.generation) return;
      this.cache.set(file, value);
      while (this.cache.size > 128)
        this.cache.delete(this.cache.keys().next().value);
    };
    if (allowed.has("claude")) {
      const dir = path.join(
        this.env.CLAUDE_CONFIG_DIR || path.join(this.home, ".claude"),
        "sessions",
      );
      for (const file of await this.files(dir, ".json", 64)) {
        if (generation !== this.generation) return [];
        keep.add(file);
        const sig = await this.signature(file);
        if (!sig || sig.size > 65536) continue;
        let entry = this.cache.get(file);
        if (!entry || entry.mtime !== sig.mtime || entry.size !== sig.size) {
          const data = await this.bytes(file, 65536, false);
          let json;
          try {
            json = JSON.parse(String(data));
          } catch {}
          entry = { ...sig, session: null, pid: null, startedAt: null };
          if (
            Number.isInteger(json?.pid) &&
            json.pid > 0 &&
            !ignore().has(json.pid)
          ) {
            const start = await this.processStart(json.pid).catch(() => null);
            if (generation !== this.generation) return [];
            const session = parseClaude(json, start);
            if (session)
              Object.assign(entry, {
                session,
                pid: json.pid,
                startedAt: start,
              });
          }
          // Do not negative-cache process liveness or ignored CLI PIDs.
          if (entry.session) store(file, entry);
        }
        if (!entry.session || ignore().has(entry.pid)) continue;
        const actual = await this.processStart(entry.pid).catch(() => null);
        if (generation !== this.generation) return [];
        if (
          !ignore().has(entry.pid) &&
          Number.isFinite(actual) &&
          Math.abs(actual - entry.startedAt) <= 1000
        )
          result.push({ ...entry.session });
      }
    }
    if (allowed.has("codex")) {
      let candidates = [];
      const home = this.env.CODEX_HOME || path.join(this.home, ".codex");
      for (const offset of [0, -86400000]) {
        if (generation !== this.generation) return [];
        const date = new Date(now + offset)
          .toISOString()
          .slice(0, 10)
          .split("-");
        for (const file of await this.files(
          path.join(home, "sessions", ...date),
          ".jsonl",
        )) {
          const sig = await this.signature(file);
          if (sig && now - sig.mtime < 900000)
            candidates.push({ file, ...sig });
        }
      }
      candidates.sort((a, b) => b.mtime - a.mtime);
      for (const { file, mtime, size } of candidates.slice(0, 12)) {
        if (generation !== this.generation) return [];
        keep.add(file);
        let entry = this.cache.get(file);
        if (!entry || entry.mtime !== mtime || entry.size !== size) {
          const data = await this.bytes(file, 262144, true);
          const session = data
            ? parseCodexTail(data, {
                id: path.basename(file, ".jsonl"),
                modifiedAt: mtime,
                now: mtime,
              })
            : null;
          entry = { mtime, size, session };
          store(file, entry);
        }
        if (entry.session) {
          const s = { ...entry.session };
          if (
            s.state === "busy" &&
            now - mtime > (s.evidence === "derived" ? 8000 : 120000)
          ) {
            s.state = "unknown";
            s.evidence = "unknown";
          }
          result.push(s);
        }
      }
    }
    if (generation !== this.generation) return [];
    for (const file of this.cache.keys())
      if (!keep.has(file)) this.cache.delete(file);
    return result;
  }
}
module.exports = { SessionReader, SessionRules, parseClaude, parseCodexTail };
