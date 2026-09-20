const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises"),
  os = require("node:os"),
  path = require("node:path");
const {
  SessionReader,
  SessionRules,
  parseClaude,
  parseCodexTail,
} = require("../src/sessions.cjs");
const now = Date.parse("2026-09-20T12:00:00Z");
const event = (type, turn, time = now) =>
  JSON.stringify({
    type: "event_msg",
    timestamp: new Date(time).toISOString(),
    payload: { type, turn_id: turn, text: "PRIVATE TRANSCRIPT" },
  });
test("Codex matches the newest turn and does not retain transcript text", () => {
  const data = [
    event("task_started", "a"),
    event("task_started", "b"),
    event("task_complete", "a"),
  ].join("\n");
  const s = parseCodexTail(data, { id: "test", modifiedAt: now, now });
  assert.equal(s.state, "busy");
  assert.equal(s.evidence, "explicit");
  assert(!JSON.stringify(s).includes("PRIVATE"));
  assert.equal(
    parseCodexTail(data + "\n" + event("task_complete", "b"), {
      id: "test",
      modifiedAt: now,
      now,
    }).state,
    "ended",
  );
  assert.equal(
    parseCodexTail(data, { id: "test", modifiedAt: now, now: now + 121000 })
      .evidence,
    "unknown",
  );
});
test("Claude requires live matching process identity and normalizes only state", () => {
  const json = {
    pid: 23,
    cwd: "C:\\projects\\demo",
    startedAt: now,
    status: "busy",
    updatedAt: now,
    secret: "PRIVATE",
  };
  assert.equal(parseClaude(json, now + 6000), null);
  assert.equal(parseClaude({ ...json, startedAt: undefined }, now), null);
  const s = parseClaude(json, now);
  assert.equal(s.name, "demo");
  assert.equal(s.state, "busy");
  assert(!JSON.stringify(s).includes("PRIVATE"));
});
test("session alerts require fresh explicit transitions and deduplicate", () => {
  const rules = new SessionRules();
  const s = {
    id: "a",
    provider: "codex",
    name: "本地任务",
    state: "busy",
    evidence: "explicit",
    updatedAt: new Date(now - 1000).toISOString(),
  };
  assert.deepEqual(rules.observe([s], now), []);
  const ended = {
    ...s,
    state: "ended",
    updatedAt: new Date(now).toISOString(),
  };
  assert.equal(rules.observe([ended], now)[0].kind, "ended");
  assert.deepEqual(rules.observe([ended], now), []);
  rules.observe([{ ...s, evidence: "derived" }], now);
  assert.deepEqual(rules.observe([ended], now), []);
});
test("reader gates consent, ignores quota PID, rechecks cached PID reuse and ages Codex cache", async (t) => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "naigrey-session-"));
  t.after(() => fs.rm(home, { recursive: true, force: true }));
  await fs.mkdir(path.join(home, ".claude", "sessions"), { recursive: true });
  await fs.writeFile(
    path.join(home, ".claude", "sessions", "one.json"),
    JSON.stringify({
      pid: 23,
      cwd: "C:\\demo",
      startedAt: now,
      status: "busy",
      updatedAt: now,
    }),
  );
  let start = now,
    calls = 0,
    clock = now;
  const ignored = new Set();
  const r = new SessionReader({
    home,
    env: {},
    now: () => clock,
    ignoredPids: () => ignored,
    processStart: async () => {
      calls++;
      return start;
    },
  });
  assert.deepEqual(await r.read([]), []);
  assert.equal(calls, 0);
  assert.equal((await r.read(["claude"])).length, 1);
  ignored.add(23);
  assert.deepEqual(await r.read(["claude"]), []);
  ignored.clear();
  start += 10000;
  assert.deepEqual(await r.read(["claude"]), []);
  const dir = path.join(home, ".codex", "sessions", "2026", "09", "20");
  await fs.mkdir(dir, { recursive: true });
  const file = path.join(dir, "one.jsonl");
  await fs.writeFile(file, "{}\n");
  await fs.utimes(file, new Date(now), new Date(now));
  assert.equal((await r.read(["codex"]))[0].evidence, "derived");
  clock += 9000;
  assert.equal((await r.read(["codex"]))[0].state, "unknown");
  r.clearCache();
});
test("revoking consent while process identity is pending invalidates the scan", async (t) => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "naigrey-session-"));
  t.after(() => fs.rm(home, { recursive: true, force: true }));
  const dir = path.join(home, ".claude", "sessions");
  await fs.mkdir(dir, { recursive: true });
  await fs.writeFile(
    path.join(dir, "one.json"),
    JSON.stringify({
      pid: 23,
      cwd: "C:\\demo",
      startedAt: now,
      status: "busy",
    }),
  );
  let release, entered;
  const ready = new Promise((r) => (entered = r));
  let calls = 0;
  const r = new SessionReader({
    home,
    env: {},
    now: () => now,
    processStart: async () => {
      calls++;
      entered();
      return calls === 1 ? new Promise((resolve) => (release = resolve)) : now;
    },
  });
  const reading = r.read(["claude"]);
  await ready;
  r.clearCache();
  release(now);
  assert.deepEqual(await reading, []);
  assert.equal(calls, 1);
});
test("tail cap drops partial leading JSON and scanner ignores old history and oversized Claude files", async (t) => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "naigrey-session-"));
  t.after(() => fs.rm(home, { recursive: true, force: true }));
  const today = path.join(home, ".codex", "sessions", "2026", "09", "20"),
    old = path.join(home, ".codex", "sessions", "2026", "09", "18");
  await fs.mkdir(today, { recursive: true });
  await fs.mkdir(old, { recursive: true });
  const f = path.join(today, "tail.jsonl");
  await fs.writeFile(
    f,
    "x".repeat(300000) + "\n" + event("task_complete", "b"),
  );
  await fs.utimes(f, new Date(now), new Date(now));
  await fs.writeFile(
    path.join(old, "ignored.jsonl"),
    event("task_started", "old"),
  );
  const claude = path.join(home, ".claude", "sessions");
  await fs.mkdir(claude, { recursive: true });
  await fs.writeFile(
    path.join(claude, "oversized.json"),
    JSON.stringify({
      pid: 23,
      cwd: "C:\\demo",
      startedAt: now,
      status: "busy",
      padding: "x".repeat(65536),
    }),
  );
  let processReads = 0;
  const r = new SessionReader({
    home,
    env: {},
    now: () => now,
    processStart: async () => {
      processReads++;
      return now;
    },
  });
  const sessions = await r.read(["codex", "claude"]);
  assert.equal(sessions.length, 1);
  assert.equal(sessions[0].state, "ended");
  assert.equal(processReads, 0);
});
