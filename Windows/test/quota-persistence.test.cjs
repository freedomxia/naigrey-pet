const test = require("node:test"),
  assert = require("node:assert/strict"),
  fs = require("node:fs/promises"),
  os = require("node:os"),
  path = require("node:path");
const { QuotaService } = require("../src/quota.cjs"),
  { ReminderCenter } = require("../src/reminder-center.cjs");
const now = Date.parse("2026-09-20T04:00:00Z");
async function fixture(t) {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "quota-store-"));
  t.after(() => fs.rm(home, { recursive: true, force: true }));
  await fs.mkdir(path.join(home, ".codex"));
  const auth = path.join(home, ".codex", "auth.json");
  const write = (account) =>
    fs.writeFile(
      auth,
      JSON.stringify({
        tokens: { account_id: account, access_token: "never-store-secret" },
      }),
    );
  await write("a");
  return { home, write, stateDirectory: path.join(home, "state") };
}
const response = () =>
  new Response(
    JSON.stringify({ rate_limit: { primary_window: { used_percent: 90 } } }),
  );
test("cached usage restores stale only after same-account validation and never stores token", async (t) => {
  const opts = await fixture(t);
  const first = new QuotaService({
    ...opts,
    env: {},
    now: () => now,
    fetchImpl: async () => response(),
  });
  await first.connect("codex");
  first.stop();
  const next = new QuotaService({
    ...opts,
    env: {},
    now: () => now + 3600000,
    fetchImpl: async () => {
      throw Error("offline");
    },
  });
  t.after(() => next.stop());
  assert.equal(next.snapshot()[0].status, "disconnected");
  await next.connect("codex");
  assert.equal(next.snapshot()[0].status, "stale");
  assert.equal(next.snapshot()[0].windows[0].usedPercent, 90);
  const contents = await fs.readFile(
    path.join(opts.stateDirectory, "quota-cache.json"),
    "utf8",
  );
  assert(!contents.includes("never-store-secret"));
  assert(!JSON.stringify(next.snapshot()).includes("identity"));
  await opts.write("b");
  const other = new QuotaService({
    ...opts,
    env: {},
    now: () => now + 3600000,
    fetchImpl: async () => {
      throw Error("offline");
    },
  });
  t.after(() => other.stop());
  await other.connect("codex");
  assert.deepEqual(other.snapshot()[0].windows, []);
});
test("history restart stays hidden until matching account, never restores queued alerts", async (t) => {
  const opts = await fixture(t),
    center = new ReminderCenter({ ...opts, now: () => now });
  const service = new QuotaService({
    ...opts,
    env: {},
    now: () => now,
    fetchImpl: async () => response(),
  });
  t.after(() => service.stop());
  service.on("reminder", (e) => center.accept([e], service.snapshot(), [], {}));
  await service.connect("codex");
  assert.equal(center.snapshot().history.length, 1);
  const restored = new ReminderCenter({ ...opts, now: () => now + 1000 });
  assert.equal(restored.snapshot().history.length, 0);
  restored.accept([], [{ provider: "codex", status: "disconnected" }], [], {});
  restored.accept([], service.snapshot(), [], {});
  assert.equal(restored.snapshot().history.length, 1);
  assert.equal(restored.snapshot().unreadCount, 0);
  assert.equal(
    restored.drain({ usage: service.snapshot(), canPresent: true }),
    null,
  );
  service.removeAllListeners("reminder");
  await opts.write("b");
  await service.refresh();
  const isolated = new ReminderCenter({ ...opts, now: () => now + 1000 });
  isolated.accept([], service.snapshot(), [], {});
  assert.equal(
    isolated
      .snapshot()
      .history.some((e) => e.createdAt === new Date(now).toISOString()),
    false,
  );
});
test("fresh-looking disk cache remains stale offline and expired records are rejected", async (t) => {
  const opts = await fixture(t),
    first = new QuotaService({
      ...opts,
      env: {},
      now: () => now,
      fetchImpl: async () => response(),
    });
  await first.connect("codex");
  first.stop();
  const offline = new QuotaService({
    ...opts,
    env: {},
    now: () => now + 1000,
    fetchImpl: async () => {
      throw Error("offline");
    },
  });
  t.after(() => offline.stop());
  await offline.connect("codex");
  assert.equal(offline.snapshot()[0].status, "stale");
  await offline.refresh();
  assert.equal(offline.snapshot()[0].status, "stale");
  const expired = new QuotaService({
    ...opts,
    env: {},
    now: () => now + 86400001,
    fetchImpl: async () => {
      throw Error("offline");
    },
  });
  t.after(() => expired.stop());
  await expired.connect("codex");
  assert.deepEqual(expired.snapshot()[0].windows, []);
});
test("private stores bound file size and use restrictive permissions on POSIX", async (t) => {
  const { readStore, writeStore } = require("../src/quota-store.cjs"),
    opts = await fixture(t),
    file = path.join(opts.stateDirectory, "private.json");
  writeStore(file, { safe: true });
  assert.deepEqual(readStore(file), { safe: true });
  if (process.platform !== "win32")
    assert.equal((await fs.stat(file)).mode & 0o777, 0o600);
  await fs.writeFile(file, "x".repeat(2000001));
  assert.equal(readStore(file), null);
  await fs.writeFile(file, "{broken");
  assert.equal(readStore(file), null);
});
