"use strict";
// Adapted from Source/AICompanion ClaudeQuotaSources and CNClaude* (Codenotch MIT).
const fs = require("node:fs/promises");
const path = require("node:path");
const zlib = require("node:zlib");
const { spawn } = require("node:child_process");
const { createHash } = require("node:crypto");
const LIMIT = 512 * 1024;
const CLI_ARGS = Object.freeze([
  "--print",
  "--no-session-persistence",
  "--strict-mcp-config",
  "/usage",
]);
const RENEW_ARGS = Object.freeze([
  "-p",
  "--no-session-persistence",
  "--strict-mcp-config",
]);
function abort(signal) {
  if (signal?.aborted) throw new Error("cancelled");
}
async function jsonFile(filename) {
  let f;
  try {
    f = await fs.open(filename, "r");
    const s = await f.stat();
    if (!s.isFile() || s.size > 1000000) return null;
    const b = Buffer.alloc(1000001);
    const { bytesRead } = await f.read(b, 0, b.length, 0);
    if (bytesRead > 1000000) return null;
    return JSON.parse(b.subarray(0, bytesRead));
  } catch {
    return null;
  } finally {
    await f?.close();
  }
}
function resetDate(text, now) {
  const m =
    /^([A-Za-z]{3}) (\d{1,2}) at (\d{1,2})(?::(\d{2}))?(am|pm)(?: \(([^)]+)\))?$/i.exec(
      text || "",
    );
  if (!m) return null;
  const month = [
      "jan",
      "feb",
      "mar",
      "apr",
      "may",
      "jun",
      "jul",
      "aug",
      "sep",
      "oct",
      "nov",
      "dec",
    ].indexOf(m[1].toLowerCase()),
    day = +m[2],
    hour = +m[3],
    minute = +(m[4] || 0);
  if (month < 0 || day < 1 || day > 31 || hour < 1 || hour > 12 || minute > 59)
    return null;
  let format;
  try {
    format = new Intl.DateTimeFormat("en-US", {
      timeZone: m[6] || undefined,
      year: "numeric",
      month: "numeric",
      day: "numeric",
      hour: "numeric",
      minute: "numeric",
      second: "numeric",
      hourCycle: "h23",
    });
  } catch {
    return null;
  }
  const parts = (t) =>
    Object.fromEntries(
      format
        .formatToParts(t)
        .filter((x) => x.type !== "literal")
        .map((x) => [x.type, +x.value]),
    );
  const year = parts(now).year,
    h = (hour % 12) + (m[5].toLowerCase() === "pm" ? 12 : 0),
    candidates = [];
  for (const y of [year - 1, year, year + 1]) {
    let t = Date.UTC(y, month, day, h, minute);
    const target = t;
    for (let i = 0; i < 3; i++) {
      const p = parts(t);
      t +=
        target -
        Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second);
    }
    const p = parts(t);
    if (
      p.year === y &&
      p.month === month + 1 &&
      p.day === day &&
      p.hour === h &&
      p.minute === minute
    )
      candidates.push(t);
  }
  candidates.sort((a, b) => Math.abs(a - now) - Math.abs(b - now));
  return candidates.length ? new Date(candidates[0]).toISOString() : null;
}
function parseUsageCLI(text, now = Date.now()) {
  if (typeof text !== "string" || Buffer.byteLength(text) > LIMIT)
    throw new Error("invalid usage");
  const windows = [];
  for (const m of text.matchAll(
    /^Current (?:(session)|week \(([^)\r\n]{1,100})\)):\s*(\d+)%[ \t]*used(?:[ \t]*·[ \t]*resets[ \t]*(.*))?[ \t]*$/gm,
  )) {
    const p = +m[3];
    if (p > 100) continue;
    const name = m[2]?.toLowerCase(),
      id = m[1]
        ? "session"
        : `weekly_${name === "all models" ? "all" : name.replaceAll(" ", "_")}`;
    if (windows.some((w) => w.id === id)) continue;
    windows.push({
      id,
      label:
        id === "session"
          ? "当前会话"
          : id === "weekly_all"
            ? "所有模型 · 每周"
            : `${m[2]} · 每周`,
      usedPercent: p,
      resetsAt: resetDate(m[4]?.trim(), now),
    });
  }
  if (!windows.some((w) => w.id === "session"))
    throw new Error("invalid usage");
  return windows.sort(
    (a, b) =>
      (a.id === "session" ? 0 : a.id === "weekly_all" ? 1 : 2) -
        (b.id === "session" ? 0 : b.id === "weekly_all" ? 1 : 2) ||
      a.id.localeCompare(b.id),
  );
}
function cacheKey(b) {
  if (b.length < 24 || b.readBigUInt64LE(0) !== 0xfcfb6d1ba7725c30n)
    return null;
  const n = b.readUInt32LE(12);
  return n > 0 && n <= 8192 && b.length >= 24 + n
    ? b.subarray(24, 24 + n).toString("utf8")
    : null;
}
function usageOrganization(key) {
  try {
    const start = key.indexOf("https://");
    if (start < 0) return null;
    const u = new URL(key.slice(start));
    if (
      !["claude.ai", "api.anthropic.com", "anthropic.com"].includes(
        u.hostname,
      ) ||
      u.port ||
      u.username ||
      u.password
    )
      return null;
    return (
      /^\/api\/organizations\/([^/]+)\/usage$/.exec(u.pathname)?.[1] || null
    );
  } catch {
    return null;
  }
}
// Walk zstd frame headers/blocks only; decompression itself has a hard allocation cap.
function frameLength(b) {
  if (b.length < 6 || b.readUInt32LE(0) !== 0xfd2fb528)
    throw new Error("frame");
  const d = b[4];
  if (d & 0x18) throw new Error("frame");
  const single = !!(d & 32),
    fcs = d >> 6;
  let p =
    5 +
    (single ? 0 : 1) +
    [0, 1, 2, 4][d & 3] +
    (fcs === 0 ? (single ? 1 : 0) : [0, 2, 4, 8][fcs]);
  for (let n = 0; n < 10000; n++) {
    if (p + 3 > b.length) throw new Error("frame");
    const h = b.readUIntLE(p, 3),
      type = (h >> 1) & 3,
      size = h >>> 3;
    p += 3;
    if (type === 3) throw new Error("frame");
    p += type === 1 ? 1 : size;
    if (p > b.length) throw new Error("frame");
    if (h & 1) {
      p += d & 4 ? 4 : 0;
      if (p > b.length) throw new Error("frame");
      return p;
    }
  }
  throw new Error("frame");
}
function parseCacheEntry(bytes, organization, modifiedAt) {
  try {
    if (bytes.length > LIMIT) return null;
    const key = cacheKey(bytes);
    if (!key || usageOrganization(key) !== organization) return null;
    const offset = 24 + bytes.readUInt32LE(12),
      frame = bytes.subarray(offset),
      n = frameLength(frame);
    if (typeof zlib.zstdDecompressSync !== "function") return null;
    const body = zlib.zstdDecompressSync(frame.subarray(0, n), {
      maxOutputLength: 256 * 1024,
    });
    const windows = require("./quota.cjs").parseClaude(body);
    const stamp = /\0date:[ \t]*([^\0]+)\0/i.exec(
        frame.subarray(n).toString("latin1"),
      )?.[1],
      date = Date.parse(stamp);
    return { windows, capturedAt: Number.isFinite(date) ? date : modifiedAt };
  } catch {
    return null;
  }
}
async function readDesktop(directory, organization, signal) {
  if (!directory || !organization) return null;
  let dir;
  const entries = [];
  try {
    dir = await fs.opendir(directory);
    let examined = 0;
    for await (const e of dir) {
      abort(signal);
      if (++examined > 20000) break;
      if (!e.isFile() || !e.name.endsWith("_0")) continue;
      const filename = path.join(directory, e.name);
      const s = await fs.stat(filename).catch(() => null);
      if (s?.isFile() && s.size > 24 && s.size <= LIMIT)
        entries.push({ filename, mtime: s.mtimeMs });
    }
    entries.sort((a, b) => b.mtime - a.mtime);
    for (const e of entries.slice(0, 400)) {
      abort(signal);
      let f;
      try {
        f = await fs.open(e.filename, "r");
        const stat = await f.stat();
        if (!stat.isFile() || stat.size > LIMIT) continue;
        // Read only the header and declared key, never unrelated response bodies.
        const head = Buffer.alloc(24);
        if (
          (await f.read(head, 0, 24, 0)).bytesRead !== 24 ||
          head.readBigUInt64LE(0) !== 0xfcfb6d1ba7725c30n
        )
          continue;
        const n = head.readUInt32LE(12);
        if (n < 1 || n > 8192) continue;
        const prefix = Buffer.alloc(24 + n);
        head.copy(prefix);
        if (
          (await f.read(prefix, 24, n, 24)).bytesRead !== n ||
          usageOrganization(cacheKey(prefix)) !== organization
        )
          continue;
        const b = Buffer.alloc(LIMIT + 1),
          r = await f.read(b, 0, b.length, 0);
        const result = parseCacheEntry(
          b.subarray(0, r.bytesRead),
          organization,
          stat.mtimeMs,
        );
        if (result) return result;
      } catch {
      } finally {
        await f?.close();
      }
    }
  } catch {}
  abort(signal);
  return null;
}
async function locateCLI(home, env) {
  // Native installer first. Never run cmd.exe or expand a shell command.
  const dirs = [
    path.join(home, ".local", "bin"),
    path.join(home, ".claude", "local"),
    path.join(home, ".bun", "bin"),
    ...(env.PATH || env.Path || "").split(path.delimiter),
  ]
    .filter((d) => path.isAbsolute(d))
    .slice(0, 100);
  for (const dir of [...new Set(dirs)].slice(0, 100)) {
    const exe = path.join(dir, "claude.exe");
    if ((await fs.stat(exe).catch(() => null))?.isFile())
      return { file: exe, args: [] };
  }
  // Standard npm global layout only: resolve the package entrypoint, not arbitrary shim text.
  const npmDirs = [
    env.APPDATA && path.join(env.APPDATA, "npm"),
    ...dirs,
  ].filter(Boolean);
  for (const dir of [...new Set(npmDirs)].slice(0, 100)) {
    const entry = path.join(
      dir,
      "node_modules",
      "@anthropic-ai",
      "claude-code",
      "cli.js",
    );
    if (!(await fs.stat(entry).catch(() => null))?.isFile()) continue;
    for (const nd of [dir, ...dirs]) {
      const node = path.join(nd, "node.exe");
      if ((await fs.stat(node).catch(() => null))?.isFile())
        return { file: node, args: [entry] };
    }
  }
  return null;
}
async function runCLI(
  command,
  args,
  {
    env,
    cwd,
    signal,
    timeout = 20000,
    onPID = () => {},
    acceptNonzero = false,
    spawnImpl = spawn,
  } = {},
) {
  abort(signal);
  await fs.mkdir(cwd, { recursive: true });
  abort(signal);
  return new Promise((resolve, reject) => {
    let child,
      ended = false,
      bytes = 0,
      chunks = [],
      timer,
      killTimer,
      cancelled = false;
    const finish = (err, value) => {
      if (ended) return;
      ended = true;
      clearTimeout(timer);
      clearTimeout(killTimer);
      signal?.removeEventListener("abort", cancel);
      onPID(null);
      err ? reject(new Error("Claude CLI unavailable")) : resolve(value);
    };
    const cancel = () => {
      if (cancelled || ended) return;
      cancelled = true;
      if (process.platform === "win32" && Number.isInteger(child?.pid)) {
        const root = env.SystemRoot || env.SYSTEMROOT || "C:\\Windows";
        try {
          const killer = spawnImpl(
            path.join(root, "System32", "taskkill.exe"),
            ["/PID", String(child.pid), "/T", "/F"],
            { windowsHide: true, shell: false, stdio: "ignore" },
          );
          killer.on("error", () => child?.kill("SIGKILL"));
          killer.on("close", () => {
            if (!ended) child?.kill("SIGKILL");
          });
        } catch {
          child?.kill("SIGKILL");
        }
      } else child?.kill("SIGKILL");
      killTimer = setTimeout(() => {
        child?.kill("SIGKILL");
        finish(new Error("cancelled"));
      }, 2000);
      killTimer.unref?.();
    };
    try {
      child = spawnImpl(command.file, [...command.args, ...args], {
        cwd,
        env,
        windowsHide: true,
        shell: false,
        stdio: ["ignore", acceptNonzero ? "ignore" : "pipe", "ignore"],
      });
      onPID(child.pid);
      child.stdout?.on("data", (chunk) => {
        bytes += chunk.length;
        if (bytes > LIMIT) cancel();
        else chunks.push(chunk);
      });
      child.once("error", () => finish(new Error("spawn")));
      child.once("close", (code) =>
        finish(
          cancelled || (code !== 0 && !acceptNonzero)
            ? new Error("exit")
            : null,
          Buffer.concat(chunks).toString("utf8"),
        ),
      );
      signal?.addEventListener("abort", cancel, { once: true });
      if (signal?.aborted) cancel();
      timer = setTimeout(cancel, timeout);
      timer.unref?.();
    } catch {
      finish(new Error("spawn"));
    }
  });
}
class TokenRenewal {
  constructor({ now = Date.now, readExpiry, launch }) {
    Object.assign(this, { now, readExpiry, launch });
    this.busy = false;
    this.attempted = null;
    this.last = null;
  }
  async consider(enabled, signal) {
    if (!enabled || this.busy) return null;
    this.busy = true;
    try {
      abort(signal);
      const expiry = await this.readExpiry();
      abort(signal);
      const now = this.now();
      if (
        !Number.isFinite(expiry) ||
        expiry - now >= 240000 ||
        expiry === this.attempted ||
        (this.last !== null && now - this.last < 600000)
      )
        return null;
      this.last = now;
      this.attempted = expiry;
      try {
        await this.launch(signal);
      } catch {}
      abort(signal);
      const after = await this.readExpiry();
      abort(signal);
      return after > expiry
        ? { status: "refreshed", until: new Date(after).toISOString() }
        : {
            status: "failed",
            message: "Claude 登录未能续期，请打开 Claude Code 重新登录。",
          };
    } finally {
      this.busy = false;
    }
  }
}
class ClaudeSources {
  constructor({
    home,
    env = {},
    now = Date.now,
    desktop,
    cli,
    onPID = () => {},
  }) {
    Object.assign(this, { home, env, now, onPID });
    this.config = env.CLAUDE_CONFIG_DIR || path.join(home, ".claude");
    this.accountFile = env.CLAUDE_CONFIG_DIR
      ? path.join(this.config, ".claude.json")
      : path.join(home, ".claude.json");
    this.desktop =
      desktop ||
      ((org, signal) =>
        readDesktop(
          env.APPDATA
            ? path.join(env.APPDATA, "Claude", "Cache", "Cache_Data")
            : null,
          org,
          signal,
        ));
    this.cli =
      cli ||
      (async (signal) =>
        parseUsageCLI(await this.launch(CLI_ARGS, signal), this.now()));
    this.enabled = false;
    this.forget();
    this.renewal = new TokenRenewal({
      now,
      readExpiry: async () => {
        const root = await jsonFile(
          path.join(this.config, ".credentials.json"),
        );
        return root?.claudeAiOauth?.expiresAt;
      },
      launch: (signal) => this.launch(RENEW_ARGS, signal, true),
    });
  }
  setRenewalEnabled(value) {
    this.enabled = value === true;
    if (!this.enabled) {
      this.cliAt = null;
      this.cliWindows = null;
    }
  }
  forget() {
    this.org = undefined;
    this.desktopMiss = null;
    this.cliAt = null;
    this.cliWindows = null;
    this.generation = (this.generation || 0) + 1;
  }
  async identity() {
    const root = await jsonFile(this.accountFile);
    const value = root?.oauthAccount?.organizationUuid;
    const org =
      typeof value === "string" &&
      value.trim() &&
      value.length < 256 &&
      !/[\r\n]/.test(value)
        ? value
        : null;
    if (org !== this.org) {
      this.desktopMiss = null;
      this.cliAt = null;
      this.cliWindows = null;
      this.org = org;
    }
    return createHash("sha256")
      .update(`claude:${org || this.config}`)
      .digest("hex");
  }
  async launch(args, signal, renew = false) {
    const command = await locateCLI(this.home, this.env);
    abort(signal);
    if (!command) throw new Error("CLI missing");
    return runCLI(command, args, {
      env: this.env,
      cwd: path.join(
        this.env.LOCALAPPDATA || this.home,
        "Naihui",
        "usage-scratch",
      ),
      signal,
      timeout: renew ? 30000 : 20000,
      onPID: this.onPID,
      acceptNonzero: renew,
    });
  }
  async local(signal) {
    const generation = this.generation;
    const fingerprint = await this.identity();
    const valid = () => {
      abort(signal);
      if (generation !== this.generation) throw new Error("cancelled");
    };
    valid();
    const now = this.now(),
      fresh = (w) =>
        w.length && !w.some((x) => x.resetsAt && Date.parse(x.resetsAt) <= now);
    if (this.desktopMiss === null || now - this.desktopMiss >= 300000) {
      const r = this.org ? await this.desktop(this.org, signal) : null;
      valid();
      if (r && Math.abs(now - r.capturedAt) < 1800000 && fresh(r.windows)) {
        this.desktopMiss = null;
        return { ...r, fingerprint, source: "Claude Desktop 缓存" };
      }
      this.desktopMiss = now;
    }
    if (
      this.enabled &&
      this.cliWindows &&
      now - this.cliWindows.capturedAt < 300000 &&
      fresh(this.cliWindows.windows)
    )
      return { ...this.cliWindows, fingerprint, source: "Claude CLI /usage" };
    if (this.enabled && (this.cliAt === null || now - this.cliAt >= 300000)) {
      this.cliAt = now;
      try {
        const windows = await this.cli(signal);
        valid();
        if (fresh(windows)) {
          this.cliWindows = { windows, capturedAt: now };
          return {
            ...this.cliWindows,
            fingerprint,
            source: "Claude CLI /usage",
          };
        }
      } catch {
        valid();
      }
    }
    return null;
  }
}
module.exports = {
  ClaudeSources,
  TokenRenewal,
  parseUsageCLI,
  resetDate,
  parseCacheEntry,
  readDesktop,
  locateCLI,
  runCLI,
  CLI_ARGS,
  RENEW_ARGS,
};
