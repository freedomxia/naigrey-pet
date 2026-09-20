const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const {
  QuotaService,
  parseCodex,
  parseClaude,
  ReminderTracker,
} = require("../src/quota.cjs");
const now = Date.parse("2026-09-19T00:00:00Z");
const iso = (ms) => new Date(ms).toISOString();
const payload = (p) => ({
  rate_limit: {
    primary_window: {
      used_percent: p,
      limit_window_seconds: 18000,
      reset_at: now / 1000 + 18000,
    },
  },
});
const snapshot = (p, w = 0, reset = now + 18000000) => ({
  provider: "codex",
  status: "ok",
  windows: [
    { id: "primary", label: "5 小时", usedPercent: p, resetsAt: iso(reset) },
    {
      id: "secondary",
      label: "每周",
      usedPercent: w,
      resetsAt: iso(now + 604800000),
    },
  ],
});
async function fixture(t, fetchImpl) {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "naihui-quota-"));
  t.after(() => fs.rm(home, { recursive: true, force: true }));
  await fs.mkdir(path.join(home, ".codex"));
  await fs.writeFile(
    path.join(home, ".codex", "auth.json"),
    JSON.stringify({
      tokens: { access_token: "secret-token", account_id: "account-a" },
    }),
  );
  const service = new QuotaService({
    home,
    env: {},
    fetchImpl,
    now: () => now,
  });
  t.after(() => service.stop());
  return { service, home };
}
test("Codex validates numbers independently and keeps extras unique", () => {
  const data = payload(true);
  data.rate_limit.secondary_window = {
    used_percent: 25,
    reset_after_seconds: 60,
  };
  data.additional_rate_limits = [
    { limit_name: "Spark", rate_limit: payload(40).rate_limit },
    { limit_name: "Spark", rate_limit: payload(50).rate_limit },
  ];
  const windows = parseCodex(data, now);
  assert.deepEqual(
    windows.map((w) => w.id),
    ["secondary", "spark"],
  );
  assert.equal(windows[0].resetsAt, iso(now + 60000));
  assert.throws(() => parseCodex(payload(-1), now));
  assert.throws(() => parseCodex(payload(101), now));
});
test("Claude merges modern and legacy windows and validates reset dates", () => {
  const windows = parseClaude({
    limits: [
      {
        kind: "weekly_scoped",
        percent: 32,
        resets_at: iso(now + 10000),
        scope: { model: { display_name: "Opus" } },
      },
    ],
    five_hour: { utilization: 0, resets_at: iso(now + 5000) },
    seven_day: { utilization: 10, resets_at: iso(now + 10000) },
  });
  assert.deepEqual(
    windows.map((w) => w.id),
    ["session", "weekly_all", "weekly_scoped"],
  );
  assert.equal(windows[2].label, "Opus");
  assert.throws(() =>
    parseClaude({ five_hour: { utilization: 10, resets_at: "tomorrow" } }),
  );
});
test("thresholds, weekly hysteresis, reset and account switch baselines", () => {
  const tracker = new ReminderTracker();
  assert.deepEqual(tracker.observe(snapshot(79, 99), "a"), []);
  assert.deepEqual(
    tracker.observe(snapshot(80, 100), "a").map((x) => x.kind),
    ["threshold-80", "weekly-limit"],
  );
  assert.deepEqual(tracker.observe(snapshot(80, 100), "a"), []);
  assert.deepEqual(
    tracker.observe(snapshot(100, 99), "a").map((x) => x.kind),
    ["threshold-100", "session-limit"],
  );
  assert.deepEqual(tracker.observe(snapshot(100, 100), "a"), []);
  assert.deepEqual(
    tracker.observe(snapshot(5, 20, now + 36000000), "a").map((x) => x.kind),
    ["reset"],
  );
  assert.deepEqual(
    tracker.observe(snapshot(90, 20), "b").map((x) => x.kind),
    ["threshold-80"],
  );
  assert.deepEqual(
    tracker.observe(snapshot(100, 20), "b").map((x) => x.kind),
    ["threshold-100", "session-limit"],
  );
});
test("no reads/network before explicit connection; snapshots contain no credential data", async (t) => {
  let calls = 0;
  const { service } = await fixture(t, async (url, options) => {
    calls++;
    assert.equal(url, "https://chatgpt.com/backend-api/wham/usage");
    assert.equal(options.redirect, "error");
    assert.equal(options.headers.Authorization, "Bearer secret-token");
    return new Response(JSON.stringify(payload(42)));
  });
  await service.refresh();
  assert.equal(calls, 0);
  assert.equal(service.snapshot()[0].status, "disconnected");
  await service.connect("codex");
  assert.equal(calls, 1);
  assert.equal(service.snapshot()[0].windows[0].usedPercent, 42);
  assert(!JSON.stringify(service.snapshot()).includes("secret-token"));
  assert(!JSON.stringify(service.snapshot()).includes("account-a"));
  service.disconnect("codex");
  await service.refresh();
  assert.equal(calls, 1);
  assert.deepEqual(service.snapshot()[0].windows, []);
});
test("Retry-After blocks manual refresh too, HTTP body secrets never escape", async (t) => {
  let calls = 0;
  const { service } = await fixture(t, async () => {
    calls++;
    return new Response("secret-token", {
      status: 429,
      headers: { "Retry-After": "120" },
    });
  });
  await service.connect("codex");
  await service.refresh("codex");
  assert.equal(calls, 1);
  assert.equal(service.snapshot()[0].status, "error");
  assert(!JSON.stringify(service.snapshot()).includes("secret-token"));
});
test("disconnect invalidates in-flight success", async (t) => {
  let release;
  const response = new Promise((r) => (release = r));
  const { service } = await fixture(t, () => response);
  const connecting = service.connect("codex");
  await new Promise((r) => setTimeout(r, 20));
  service.disconnect("codex");
  release(new Response(JSON.stringify(payload(42))));
  await connecting;
  assert.equal(service.snapshot()[0].status, "disconnected");
});
test("expired Claude auth never makes request; configured directory is respected", async (t) => {
  let calls = 0;
  const { home } = await fixture(t, () => {});
  const dir = path.join(home, "custom");
  await fs.mkdir(dir);
  await fs.writeFile(
    path.join(dir, ".credentials.json"),
    JSON.stringify({
      claudeAiOauth: { accessToken: "secret-token", expiresAt: now - 1 },
    }),
  );
  const service = new QuotaService({
    home,
    env: { CLAUDE_CONFIG_DIR: dir },
    now: () => now,
    fetchImpl: async () => {
      calls++;
    },
  });
  t.after(() => service.stop());
  await service.connect("claude");
  assert.equal(calls, 0);
  assert.equal(service.snapshot()[1].status, "needsAuth");
});
test("oversized response rejected; stale cached values are cleared on auth error", async (t) => {
  let calls = 0;
  const { service } = await fixture(t, async () =>
    ++calls === 1
      ? new Response(JSON.stringify(payload(42)))
      : new Response("secret", { status: 401 }),
  );
  await service.connect("codex");
  await service.refresh();
  assert.equal(service.snapshot()[0].status, "needsAuth");
  assert.deepEqual(service.snapshot()[0].windows, []);
  const oversized = await fixture(
    t,
    async () => new Response("x".repeat(2000001)),
  );
  await oversized.service.connect("codex");
  assert.equal(oversized.service.snapshot()[0].status, "unsupported");
});
test("invalid calendar resets and nonnumeric Codex reset stamps are not accepted", () => {
  assert.throws(() =>
    parseClaude({
      five_hour: { utilization: 10, resets_at: "2026-02-30T00:00:00Z" },
    }),
  );
  assert.equal(
    parseCodex(
      { rate_limit: { primary_window: { used_percent: 0, reset_at: "1000" } } },
      now,
    )[0].resetsAt,
    null,
  );
});
test("rate limit expires with clock and cannot be bypassed by reconnect", async (t) => {
  let clock = now,
    calls = 0;
  const { home } = await fixture(t, () => {});
  const service = new QuotaService({
    home,
    env: {},
    now: () => clock,
    fetchImpl: async () =>
      ++calls === 1
        ? new Response("", {
            status: 429,
            headers: { "Retry-After": new Date(now + 120000).toUTCString() },
          })
        : new Response(JSON.stringify(payload(10))),
  });
  t.after(() => service.stop());
  await service.connect("codex");
  service.disconnect("codex");
  await service.connect("codex");
  assert.equal(calls, 1);
  clock += 120000;
  await service.refresh();
  assert.equal(calls, 2);
  assert.equal(service.snapshot()[0].status, "ok");
});
test("API key is unsupported and errors/redirects cannot leak response text", async (t) => {
  let calls = 0;
  const { service, home } = await fixture(t, async () => {
    calls++;
    throw new Error("secret-token redirect failed");
  });
  await service.connect("codex");
  assert(!JSON.stringify(service.snapshot()).includes("secret-token"));
  await fs.writeFile(
    path.join(home, ".codex", "auth.json"),
    JSON.stringify({ OPENAI_API_KEY: "secret-key" }),
  );
  await service.refresh();
  assert.equal(calls, 1);
  assert.equal(service.snapshot()[0].status, "unsupported");
});
test("Claude opaque token rotation rebaselines while Codex account changes cannot synthesize reset", () => {
  const tracker = new ReminderTracker();
  tracker.observe(snapshot(90), "account-a");
  assert.deepEqual(tracker.observe(snapshot(0), "account-b"), []);
  assert.deepEqual(
    tracker.observe(snapshot(100), "account-b").map((x) => x.kind),
    ["threshold-80", "threshold-100", "session-limit"],
  );
});
test("timeout bounds a fetch implementation that never resolves", async (t) => {
  let entered;
  const ready = new Promise((r) => (entered = r));
  let signal;
  const { service } = await fixture(t, async (_url, options) => {
    signal = options.signal;
    entered();
    return new Promise(() => {});
  });
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const pending = service.connect("codex");
  await ready;
  t.mock.timers.tick(15000);
  await pending;
  assert.equal(signal.aborted, true);
  assert.equal(service.snapshot()[0].status, "error");
  assert.match(service.snapshot()[0].message, /超时/);
});
test("stop invalidates pending response without emitting a successful change", async (t) => {
  let entered, release;
  const ready = new Promise((r) => (entered = r));
  const response = new Promise((r) => (release = r));
  const { service } = await fixture(t, async () => {
    entered();
    return response;
  });
  const statuses = [];
  service.on("change", (values) => statuses.push(values[0].status));
  const pending = service.connect("codex");
  await ready;
  service.stop();
  release(new Response(JSON.stringify(payload(42))));
  await pending;
  assert(!statuses.includes("ok"));
});
test("Claude follows upstream by omitting null/missing resets without losing valid sibling windows", () => {
  const data = {
    limits: [
      { kind: "session", percent: 75, resets_at: null },
      { kind: "weekly_scoped", percent: 30 },
    ],
    five_hour: { utilization: 75, resets_at: null },
    seven_day: { utilization: 25, resets_at: iso(now + 604800000) },
  };
  assert.deepEqual(parseClaude(data), [
    {
      id: "weekly_all",
      label: "所有模型 · 每周",
      usedPercent: 25,
      resetsAt: iso(now + 604800000),
    },
  ]);
  assert.throws(() =>
    parseClaude({
      limits: [{ kind: "session", percent: 75 }],
      five_hour: { utilization: 75, resets_at: null },
    }),
  );
});
test("Claude legacy window fills a modern entry missing reset, while valid modern reading takes precedence", () => {
  const data = {
    limits: [
      { kind: "session", percent: 75, resets_at: null },
      { kind: "weekly_all", percent: 42, resets_at: iso(now + 604800000) },
    ],
    five_hour: { utilization: 0, resets_at: iso(now + 18000000) },
    seven_day: { utilization: 99, resets_at: iso(now + 604800000) },
  };
  assert.deepEqual(
    parseClaude(data).map((w) => [w.id, w.usedPercent]),
    [
      ["session", 0],
      ["weekly_all", 42],
    ],
  );
});
