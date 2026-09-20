const test = require("node:test"),
  assert = require("node:assert/strict");
const {
  ReminderCenter,
  bindReminderIdentity,
} = require("../src/reminder-center.cjs");
const now = Date.parse("2026-09-20T04:00:00Z"),
  iso = (n) => new Date(n).toISOString();
function usage(p = 100, epoch = {}) {
  return [
    bindReminderIdentity(
      {
        provider: "codex",
        status: "ok",
        sourceAt: iso(now),
        windows: [
          { id: "primary", usedPercent: p, resetsAt: iso(now + 18000000) },
        ],
      },
      epoch,
    ),
  ];
}
function event(id, epoch, extras = {}) {
  return bindReminderIdentity(
    {
      id,
      provider: "codex",
      kind: "threshold-100",
      title: "Quota",
      body: "Used",
      createdAt: iso(now),
      expiresAt: iso(now + 300000),
      ...extras,
    },
    epoch,
  );
}
test("priority and 8-second P0/15-second ordinary throttle; unavailable presentation retains queue", () => {
  let clock = now;
  const center = new ReminderCenter({ now: () => clock }),
    epoch = {},
    u = usage(100, epoch);
  center.accept(
    [
      event("low", epoch, { priority: 2 }),
      event("high", epoch, { priority: 0 }),
      event("high2", epoch, { priority: 0 }),
    ],
    u,
    [],
    {},
  );
  assert.equal(
    center.drain({ usage: u, sessions: [], prefs: {}, canPresent: false }),
    null,
  );
  assert.equal(center.drain({ usage: u, canPresent: true }).id, "high");
  clock += 7999;
  assert.equal(center.drain({ usage: u, canPresent: true }), null);
  clock++;
  assert.equal(center.drain({ usage: u, canPresent: true }).id, "high2");
  clock += 14999;
  assert.equal(center.drain({ usage: u, canPresent: true }), null);
  clock++;
  assert.equal(center.drain({ usage: u, canPresent: true }).id, "low");
});
test("bounded deduplicated history and queue; read markers expire with 24-hour retention", () => {
  let clock = now;
  const center = new ReminderCenter({ now: () => clock }),
    epoch = {},
    u = usage(100, epoch);
  const events = Array.from({ length: 120 }, (_, i) => event("e" + i, epoch));
  center.accept(events, u, [], {});
  center.accept([events[119]], u, [], {});
  assert.equal(center.snapshot().history.length, 100);
  assert.equal(center.snapshot().unreadCount, 100);
  center.markRead();
  assert.equal(center.snapshot().unreadCount, 0);
  clock += 86400001;
  assert.equal(center.snapshot().history.length, 0);
});
test("mute and per-kind settings preserve history but never replay suppressed notifications", () => {
  const epoch = {},
    u = usage(100, epoch),
    center = new ReminderCenter({ now: () => now });
  center.accept([event("a", epoch)], u, [], { mutedUntil: now + 1000 });
  assert.equal(center.snapshot().unreadCount, 1);
  assert.equal(center.drain({ usage: u, prefs: {}, canPresent: true }), null);
  center.accept([event("b", epoch, { kind: "reset" })], u, [], {
    notifyReset: false,
  });
  assert.equal(center.drain({ usage: u, prefs: {}, canPresent: true }), null);
  center.accept([event("c", epoch)], u, [], {});
  assert.equal(
    center.drain({
      usage: u,
      prefs: { mutedProviders: ["codex"] },
      canPresent: true,
    }),
    null,
  );
});
test("relevance rejects stale, changed account, lower usage and expired events; metadata never serializes", () => {
  const epoch = {},
    u = usage(100, epoch),
    center = new ReminderCenter({ now: () => now });
  const e = event("a", epoch);
  center.accept([e], u, [], {});
  assert.equal(
    center.drain({ usage: usage(50, epoch), canPresent: true }),
    null,
  );
  center.accept([event("b", epoch)], u, [], {});
  assert.equal(center.drain({ usage: usage(100, {}), canPresent: true }), null);
  assert.equal(center.snapshot().history.length, 0);
  center.accept([event("c", epoch)], u, [], {});
  u[0].sourceAt = iso(now - 900001);
  assert.equal(center.drain({ usage: u, canPresent: true }), null);
  assert(!JSON.stringify([e, u, center.snapshot()]).includes("account"));
  assert.deepEqual(Object.keys(e).sort(), [
    "body",
    "createdAt",
    "expiresAt",
    "id",
    "kind",
    "provider",
    "title",
  ]);
});
test("explicit session waiting/ended relevance and provider disable", () => {
  const center = new ReminderCenter({ now: () => now });
  let sessions = [
    { id: "s", provider: "codex", state: "waiting", evidence: "explicit" },
  ];
  center.accept(
    [
      {
        id: "wait",
        provider: "codex",
        sessionID: "s",
        kind: "waiting",
        title: "Wait",
        body: "Ready",
      },
    ],
    [],
    sessions,
    {},
  );
  assert.equal(
    center.drain({
      usage: [],
      sessions: [{ ...sessions[0], evidence: "derived" }],
      canPresent: true,
    }),
    null,
  );
  center.accept(
    [{ id: "wait2", provider: "codex", sessionID: "s", kind: "waiting" }],
    [],
    sessions,
    {},
  );
  assert.equal(
    center.drain({ sessions, prefs: { enabled: [] }, canPresent: true }),
    null,
  );
  center.accept(
    [{ id: "end", provider: "codex", sessionID: "s", kind: "ended" }],
    [],
    sessions,
    {},
  );
  assert.equal(
    center.drain({
      sessions: [{ ...sessions[0], state: "idle" }],
      canPresent: true,
    }).id,
    "end",
  );
});
test("overnight quiet hours and temporary override respect explicit mute precedence", () => {
  const clock = new Date(2026, 8, 20, 23, 30).getTime(),
    epoch = {},
    u = usage(100, epoch),
    center = new ReminderCenter({ now: () => clock });
  u[0].sourceAt = iso(clock);
  const ev = (id) =>
    event(id, epoch, { createdAt: iso(clock), expiresAt: iso(clock + 300000) });
  const prefs = { quietStart: 22 * 60, quietEnd: 7 * 60 };
  center.accept([ev("quiet")], u, [], prefs);
  assert.equal(center.drain({ usage: u, prefs, canPresent: true }), null);
  center.accept([ev("override")], u, [], {
    ...prefs,
    quietOverrideUntil: clock + 1000,
  });
  assert.equal(
    center.drain({
      usage: u,
      prefs: { ...prefs, quietOverrideUntil: clock + 1000 },
      canPresent: true,
    }).id,
    "override",
  );
  center.accept([ev("mute")], u, [], {
    ...prefs,
    quietOverrideUntil: clock + 1000,
    mutedUntil: clock + 1000,
  });
  assert.equal(center.snapshot().history.length, 3);
});
test("quota service privately binds emitted reminders and snapshots across account switches", async (t) => {
  const fs = require("node:fs/promises"),
    os = require("node:os"),
    path = require("node:path"),
    { QuotaService } = require("../src/quota.cjs");
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "reminder-quota-"));
  t.after(() => fs.rm(home, { recursive: true, force: true }));
  await fs.mkdir(path.join(home, ".codex"));
  const auth = path.join(home, ".codex", "auth.json"),
    write = (account) =>
      fs.writeFile(
        auth,
        JSON.stringify({
          tokens: { account_id: account, access_token: "fixture-secret" },
        }),
      );
  await write("a");
  let percent = 90;
  const service = new QuotaService({
    home,
    env: {},
    now: () => now,
    fetchImpl: async () =>
      new Response(
        JSON.stringify({
          rate_limit: { primary_window: { used_percent: percent } },
        }),
      ),
  });
  t.after(() => service.stop());
  const center = new ReminderCenter({ now: () => now });
  service.on("reminder", (e) => center.accept([e], service.snapshot(), [], {}));
  await service.connect("codex");
  assert.equal(
    center.drain({ usage: service.snapshot(), canPresent: true })?.kind,
    "threshold-80",
  );
  assert(!JSON.stringify(center.snapshot()).includes("secret"));
  await write("b");
  percent = 10;
  await service.refresh();
  center.drain({ usage: service.snapshot(), canPresent: true });
  assert.equal(center.snapshot().history.length, 0);
});
test("queue is capped at ten and expired events never present", () => {
  let clock = now;
  const center = new ReminderCenter({ now: () => clock }),
    epoch = {},
    u = usage(100, epoch);
  center.accept(
    Array.from({ length: 15 }, (_, i) => event(String(i), epoch)),
    u,
    [],
    {},
  );
  const delivered = [];
  for (let i = 0; i < 15; i++) {
    const e = center.drain({ usage: u, canPresent: true });
    if (e) delivered.push(e.id);
    clock += 8000;
  }
  assert.equal(delivered.length, 10);
  center.accept(
    [event("expired", epoch, { expiresAt: iso(now - 1) })],
    u,
    [],
    {},
  );
  assert.equal(center.drain({ usage: u, canPresent: true }), null);
});
test("serialization removes private identity and cloned quota events fail closed", () => {
  const epoch = {},
    u = usage(100, epoch),
    center = new ReminderCenter({ now: () => now }),
    e = event("a", epoch);
  center.accept([structuredClone(e)], u, [], {});
  assert.equal(center.drain({ usage: u, canPresent: true }), null);
  assert.equal(JSON.stringify(e).includes("identity"), false);
});
test("clearPending drops pre-suspend presentation but retains history and unread", () => {
  const epoch = {},
    u = usage(100, epoch),
    center = new ReminderCenter({ now: () => now });
  center.accept([event("before-sleep", epoch)], u, [], {});
  center.clearPending();
  assert.equal(center.drain({ usage: u, canPresent: true }), null);
  assert.equal(center.snapshot().history.length, 1);
  assert.equal(center.snapshot().unreadCount, 1);
});
test("known account switch clears private reminder history even when new usage request fails", async (t) => {
  const fs = require("node:fs/promises"),
    os = require("node:os"),
    path = require("node:path"),
    { QuotaService } = require("../src/quota.cjs");
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "reminder-switch-"));
  t.after(() => fs.rm(home, { recursive: true, force: true }));
  await fs.mkdir(path.join(home, ".codex"));
  const auth = path.join(home, ".codex", "auth.json"),
    write = (account) =>
      fs.writeFile(
        auth,
        JSON.stringify({
          tokens: { account_id: account, access_token: "fixture" },
        }),
      );
  await write("a");
  let fail = false;
  const service = new QuotaService({
    home,
    env: {},
    now: () => now,
    fetchImpl: async () => {
      if (fail) throw Error("network");
      return new Response(
        JSON.stringify({
          rate_limit: { primary_window: { used_percent: 90 } },
        }),
      );
    },
  });
  t.after(() => service.stop());
  const center = new ReminderCenter({ now: () => now });
  service.on("reminder", (e) => center.accept([e], service.snapshot(), [], {}));
  await service.connect("codex");
  assert.equal(center.snapshot().history.length, 1);
  await write("b");
  fail = true;
  await service.refresh();
  center.drain({ usage: service.snapshot(), canPresent: true });
  assert.equal(center.snapshot().history.length, 0);
});
