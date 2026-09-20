const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const zlib = require("node:zlib");
const {
  parseUsageCLI,
  parseCacheEntry,
  ClaudeSources,
  TokenRenewal,
} = require("../src/quota-claude.cjs");
const now = Date.parse("2026-12-31T12:00:00Z");
const windows = [
  {
    id: "session",
    label: "当前会话",
    usedPercent: 42,
    resetsAt: new Date(now + 3600000).toISOString(),
  },
];
async function fixture(t) {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "quota-parity-"));
  t.after(() => fs.rm(home, { recursive: true, force: true }));
  await fs.writeFile(
    path.join(home, ".claude.json"),
    JSON.stringify({ oauthAccount: { organizationUuid: "org-a" } }),
  );
  return home;
}
test("CLI dates choose nearest year and honor IANA timezone, missing dates remain null", () => {
  const result = parseUsageCLI(
    "Current session: 38% used · resets Jan 2 at 3pm (Asia/Taipei)\nCurrent week (all models): 4% used\nCurrent week (Opus): 7% used",
    now,
  );
  assert.equal(result[0].resetsAt, "2027-01-02T07:00:00.000Z");
  assert.equal(result[1].resetsAt, null);
  assert.equal(result[2].id, "weekly_opus");
  assert.throws(() => parseUsageCLI("Current session: 101% used", now));
  assert.throws(() => parseUsageCLI("Cost: $1", now));
});
function cache(org = "org-a", host = "claude.ai") {
  const key = Buffer.from(
    `1/0/https://${host}/api/organizations/${org}/usage?skip_spend=1`,
  );
  const header = Buffer.alloc(24);
  header.writeBigUInt64LE(0xfcfb6d1ba7725c30n);
  header.writeUInt32LE(key.length, 12);
  const body = zlib.zstdCompressSync(
    Buffer.from(
      JSON.stringify({
        five_hour: { utilization: 42, resets_at: windows[0].resetsAt },
      }),
    ),
  );
  return Buffer.concat([
    header,
    key,
    body,
    Buffer.from("\0date: Thu, 31 Dec 2026 12:00:00 GMT\0"),
  ]);
}
test("Simple Cache isolates exact host and organization, zstd and trailer date bounded", () => {
  const reading = parseCacheEntry(cache(), "org-a", now);
  assert.equal(reading.windows[0].usedPercent, 42);
  assert.equal(reading.capturedAt, now);
  assert.equal(parseCacheEntry(cache(), "org-b", now), null);
  assert.equal(
    parseCacheEntry(cache("org-a", "claude.ai.evil.test"), "org-a", now),
    null,
  );
  assert.equal(parseCacheEntry(Buffer.alloc(524289), "org-a", now), null);
  assert.equal(parseCacheEntry(cache().subarray(0, 50), "org-a", now), null);
});
test("Desktop priority, misses throttle, CLI cache expires and account switch invalidates cache", async (t) => {
  const home = await fixture(t);
  let clock = now,
    desktopCalls = 0,
    cliCalls = 0;
  const source = new ClaudeSources({
    home,
    env: {},
    now: () => clock,
    desktop: async () => {
      desktopCalls++;
      return null;
    },
    cli: async () => {
      cliCalls++;
      return windows;
    },
  });
  source.setRenewalEnabled(true);
  assert.equal((await source.local()).source, "Claude CLI /usage");
  await source.local();
  assert.equal(desktopCalls, 1);
  assert.equal(cliCalls, 1);
  clock += 300000;
  await source.local();
  assert.equal(cliCalls, 2);
  await fs.writeFile(
    path.join(home, ".claude.json"),
    JSON.stringify({ oauthAccount: { organizationUuid: "org-b" } }),
  );
  await source.local();
  assert.equal(cliCalls, 3);
});
test("without explicit renewal consent CLI never starts, even for usage", async (t) => {
  const home = await fixture(t);
  let calls = 0;
  const source = new ClaudeSources({
    home,
    env: {},
    now: () => now,
    desktop: async () => null,
    cli: async () => {
      calls++;
      return windows;
    },
  });
  assert.equal(await source.local(), null);
  assert.equal(calls, 0);
});
test("renewal at 4-minute margin, single attempt per expiry, cooldown and verifies outcome", async () => {
  let expiry = now + 239000,
    calls = 0;
  const renew = new TokenRenewal({
    now: () => now,
    readExpiry: async () => expiry,
    launch: async () => {
      calls++;
      expiry += 28800000;
    },
  });
  assert.equal(await renew.consider(false), null);
  assert.equal(calls, 0);
  assert.equal((await renew.consider(true)).status, "refreshed");
  assert.equal(calls, 1);
  await renew.consider(true);
  assert.equal(calls, 1);
  const fail = new TokenRenewal({
    now: () => now,
    readExpiry: async () => now - 1,
    launch: async () => {
      calls++;
    },
  });
  assert.equal((await fail.consider(true)).status, "failed");
  await fail.consider(true);
  assert.equal(calls, 2);
});
test("Desktop newest matching entry wins and foreign organization never decoded", async (t) => {
  const home = await fixture(t);
  const dir = path.join(home, "cache");
  await fs.mkdir(dir);
  await fs.writeFile(path.join(dir, "old_0"), cache());
  await fs.writeFile(path.join(dir, "new_0"), cache("org-b"));
  await fs.utimes(
    path.join(dir, "old_0"),
    new Date(now - 10000),
    new Date(now - 10000),
  );
  const { readDesktop } = require("../src/quota-claude.cjs");
  const r = await readDesktop(dir, "org-a");
  assert.equal(r.windows[0].usedPercent, 42);
});
test("zstd bomb and malformed frame do not escape parser", () => {
  const b = cache(),
    start = 24 + b.readUInt32LE(12);
  const bomb = zlib.zstdCompressSync(Buffer.from("x".repeat(300000)));
  assert.equal(
    parseCacheEntry(Buffer.concat([b.subarray(0, start), bomb]), "org-a", now),
    null,
  );
  const bad = Buffer.from(b);
  bad[start + 4] = 255;
  assert.equal(parseCacheEntry(bad, "org-a", now), null);
});
test("CLI native path takes priority; npm uses node entrypoint and never executes cmd shim", async (t) => {
  const home = await fixture(t),
    dir = path.join(home, "npm"),
    bin = path.join(home, ".local", "bin");
  await fs.mkdir(bin, { recursive: true });
  await fs.mkdir(
    path.join(dir, "node_modules", "@anthropic-ai", "claude-code"),
    { recursive: true },
  );
  await fs.writeFile(path.join(dir, "claude.cmd"), "untrusted");
  await fs.writeFile(path.join(dir, "node.exe"), "");
  await fs.writeFile(
    path.join(dir, "node_modules", "@anthropic-ai", "claude-code", "cli.js"),
    "",
  );
  const { locateCLI } = require("../src/quota-claude.cjs");
  const npm = await locateCLI(home, { PATH: dir });
  assert.equal(npm.file, path.join(dir, "node.exe"));
  assert(npm.args[0].endsWith("cli.js"));
  await fs.writeFile(path.join(bin, "claude.exe"), "");
  assert.equal(
    (await locateCLI(home, { PATH: dir })).file,
    path.join(bin, "claude.exe"),
  );
});
test("CLI output capped and abort stops subprocess with no stderr leakage", async (t) => {
  const home = await fixture(t),
    { EventEmitter } = require("node:events"),
    { runCLI } = require("../src/quota-claude.cjs");
  let child,
    killed = false;
  const spawnImpl = (_file, args, opts) => {
    assert.equal(opts.shell, false);
    assert.deepEqual(opts.stdio, ["ignore", "pipe", "ignore"]);
    child = new EventEmitter();
    child.stdout = new EventEmitter();
    child.pid = 123;
    child.kill = () => {
      killed = true;
      queueMicrotask(() => child.emit("close", 1));
    };
    queueMicrotask(() => child.stdout.emit("data", Buffer.alloc(524289)));
    return child;
  };
  await assert.rejects(
    runCLI({ file: "fixture.exe", args: [] }, [], {
      cwd: home,
      env: {},
      spawnImpl,
    }),
    /unavailable/,
  );
  assert(killed);
});
test("service keeps Claude identity across token rotation and rebaselines on organization change", async (t) => {
  const home = await fixture(t);
  await fs.mkdir(path.join(home, ".claude"));
  const auth = path.join(home, ".claude", ".credentials.json");
  const write = (token) =>
    fs.writeFile(
      auth,
      JSON.stringify({
        claudeAiOauth: { accessToken: token, expiresAt: now + 1e8 },
      }),
    );
  await write("token-a");
  let p = 79;
  const { QuotaService } = require("../src/quota.cjs");
  const service = new QuotaService({
    home,
    env: {},
    now: () => now,
    fetchImpl: async () =>
      new Response(
        JSON.stringify({
          five_hour: { utilization: p, resets_at: windows[0].resetsAt },
        }),
      ),
  });
  t.after(() => service.stop());
  const events = [];
  service.on("reminder", (e) => events.push(e.kind));
  await service.connect("claude");
  await write("token-b");
  p = 80;
  await service.refresh();
  assert.deepEqual(events, ["threshold-80"]);
  await fs.writeFile(
    path.join(home, ".claude.json"),
    JSON.stringify({ oauthAccount: { organizationUuid: "org-b" } }),
  );
  p = 0;
  await service.refresh();
  assert.deepEqual(events, ["threshold-80"]);
  assert(!JSON.stringify(service.snapshot()).includes("org-b"));
});
test("OAuth backoff persists restart while Desktop remains usable during backoff", async (t) => {
  const home = await fixture(t);
  await fs.mkdir(path.join(home, ".claude"));
  await fs.writeFile(
    path.join(home, ".claude", ".credentials.json"),
    JSON.stringify({
      claudeAiOauth: { accessToken: "secret", expiresAt: now + 1e8 },
    }),
  );
  let calls = 0,
    clock = now;
  const { QuotaService } = require("../src/quota.cjs");
  const opts = {
    home,
    env: {},
    now: () => clock,
    fetchImpl: async () => {
      calls++;
      return new Response("", {
        status: 429,
        headers: { "Retry-After": "120" },
      });
    },
  };
  const one = new QuotaService(opts);
  await one.connect("claude");
  one.stop();
  const two = new QuotaService(opts);
  t.after(() => two.stop());
  await two.connect("claude");
  assert.equal(calls, 1);
  const three = new QuotaService({
    ...opts,
    claudeAdapters: { desktop: async () => ({ windows, capturedAt: now }) },
  });
  t.after(() => three.stop());
  await three.connect("claude");
  assert.equal(three.snapshot()[1].source, "Claude Desktop 缓存");
  assert.equal(calls, 1);
  clock += 120001;
  await two.refresh();
  assert.equal(calls, 2);
});
test("transient failure retains same-account reading and marks it stale after 15 minutes", async (t) => {
  const home = await fixture(t);
  await fs.mkdir(path.join(home, ".codex"));
  const auth = path.join(home, ".codex", "auth.json");
  await fs.writeFile(
    auth,
    JSON.stringify({ tokens: { access_token: "token-a", account_id: "a" } }),
  );
  let clock = now,
    fail = false;
  const { QuotaService } = require("../src/quota.cjs");
  const service = new QuotaService({
    home,
    env: {},
    now: () => clock,
    fetchImpl: async () => {
      if (fail) throw Error("secret");
      return new Response(
        JSON.stringify({
          rate_limit: { primary_window: { used_percent: 42 } },
        }),
      );
    },
  });
  t.after(() => service.stop());
  await service.connect("codex");
  fail = true;
  await service.refresh();
  assert.equal(service.snapshot()[0].status, "ok");
  assert.equal(service.snapshot()[0].windows[0].usedPercent, 42);
  clock += 900001;
  await service.refresh();
  assert.equal(service.snapshot()[0].status, "stale");
  await fs.writeFile(
    auth,
    JSON.stringify({ tokens: { access_token: "token-b", account_id: "b" } }),
  );
  await service.refresh();
  assert.deepEqual(service.snapshot()[0].windows, []);
});
test("session-limit uses 95 percent hysteresis independently from threshold crossing", () => {
  const { ReminderTracker } = require("../src/quota.cjs"),
    tracker = new ReminderTracker();
  const snap = (p) => ({
    provider: "claude",
    status: "ok",
    windows: [{ id: "session", label: "会话", usedPercent: p, resetsAt: null }],
  });
  tracker.observe(snap(90), "a");
  assert.deepEqual(
    tracker.observe(snap(100), "a").map((e) => e.kind),
    ["threshold-100", "session-limit"],
  );
  tracker.observe(snap(99), "a");
  assert.deepEqual(
    tracker.observe(snap(100), "a").map((e) => e.kind),
    ["threshold-100"],
  );
  tracker.observe(snap(94), "a");
  assert.deepEqual(
    tracker.observe(snap(100), "a").map((e) => e.kind),
    ["threshold-100", "session-limit"],
  );
});
test("Claude 401 rereads rotated file and retries exactly once without leaking credentials", async (t) => {
  const home = await fixture(t);
  await fs.mkdir(path.join(home, ".claude"));
  const auth = path.join(home, ".claude", ".credentials.json"),
    write = (token) =>
      fs.writeFile(
        auth,
        JSON.stringify({
          claudeAiOauth: { accessToken: token, expiresAt: now + 1e8 },
        }),
      );
  await write("old-secret");
  let calls = 0;
  const { QuotaService } = require("../src/quota.cjs");
  const service = new QuotaService({
    home,
    env: {},
    now: () => now,
    fetchImpl: async (_, opts) => {
      if (++calls === 1) {
        await write("new-secret");
        return new Response("hidden", { status: 401 });
      }
      assert.equal(opts.headers.Authorization, "Bearer new-secret");
      return new Response(
        JSON.stringify({
          five_hour: { utilization: 42, resets_at: windows[0].resetsAt },
        }),
      );
    },
  });
  t.after(() => service.stop());
  await service.connect("claude");
  assert.equal(calls, 2);
  assert.equal(service.snapshot()[1].status, "ok");
  assert(!JSON.stringify(service.snapshot()).includes("secret"));
});
test("weekly exhaustion still alerts when provider omits headline during reset", () => {
  const { ReminderTracker } = require("../src/quota.cjs"),
    tracker = new ReminderTracker();
  const snap = (p) => ({
    provider: "claude",
    status: "ok",
    windows: [
      { id: "weekly_all", label: "每周", usedPercent: p, resetsAt: null },
    ],
  });
  assert.deepEqual(tracker.observe(snap(99), "a"), []);
  assert.deepEqual(
    tracker.observe(snap(100), "a").map((e) => e.kind),
    ["weekly-limit"],
  );
});
test("automatic polling is five minutes idle and one minute while busy", async (t) => {
  const home = await fixture(t);
  await fs.mkdir(path.join(home, ".codex"));
  await fs.writeFile(
    path.join(home, ".codex", "auth.json"),
    JSON.stringify({ tokens: { access_token: "fixture", account_id: "a" } }),
  );
  let clock = now,
    calls = 0;
  const { QuotaService } = require("../src/quota.cjs");
  const service = new QuotaService({
    home,
    env: {},
    now: () => clock,
    fetchImpl: async () => {
      calls++;
      return new Response(
        JSON.stringify({ rate_limit: { primary_window: { used_percent: 1 } } }),
      );
    },
  });
  t.after(() => service.stop());
  await service.connect("codex");
  t.mock.timers.enable({ apis: ["setInterval"] });
  service.start();
  clock += 60000;
  t.mock.timers.tick(60000);
  assert.equal(calls, 1);
  service.setActive(true);
  const changed = new Promise((resolve) => service.once("change", resolve));
  clock += 60000;
  t.mock.timers.tick(60000);
  await changed;
  assert.equal(calls, 2);
});
