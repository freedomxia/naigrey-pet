const test = require("node:test"),
  assert = require("node:assert/strict");
const { text, daysApart } = require("../src/reset-copy.cjs");
const now = Date.parse("2026-09-20T04:00:00Z");
test("automatic rounds nearest minute, never shows 60 min, expired is resetting", () => {
  assert.equal(text(now, { now }), "正在重置…");
  assert.equal(text(now + 3040000, { now }), "51 分钟后重置");
  assert.equal(text(now + 1000, { now }), "1 分钟后重置");
  assert(!text(now + 3570000, { now, timeZone: "UTC" }).includes("60 分钟"));
  assert.equal(text(null, { now }), "暂未提供重置时间");
});
test("remaining uses days+hours or hours+minutes with rounding like Swift", () => {
  assert.equal(
    text(now + 27 * 3600000, { now, format: "remaining" }),
    "1 天 3小时后重置",
  );
  assert.equal(
    text(now + 3 * 86400000 + 3 * 3600000, { now, format: "remaining" }),
    "3 天 3小时后重置",
  );
  assert.equal(
    text(now + 3 * 3600000 + 20 * 60000, { now, format: "remaining" }),
    "3小时 20分后重置",
  );
  assert.equal(text(now + 59500, { now, format: "remaining" }), "1 分钟后重置");
});
test("absolute formatter chooses calendar days, respects IANA DST and locale hour cycle", () => {
  const before = Date.parse("2026-03-07T17:00:00Z"),
    after = Date.parse("2026-03-14T16:00:00Z");
  assert.equal(daysApart(before, after, "America/New_York"), 7);
  assert(
    !text(after, {
      now: before,
      timeZone: "America/New_York",
      locale: "en-US",
    }).includes(":"),
  );
  const en = text(now + 3600000, { now, locale: "en-US", timeZone: "UTC" }),
    zh = text(now + 3600000, { now, locale: "zh-CN", timeZone: "UTC" });
  assert.match(en, /AM/);
  assert(!/AM|PM/.test(zh));
  assert.match(zh, /05:00/);
});
