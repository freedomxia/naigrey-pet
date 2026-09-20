"use strict";
const fs = require("node:fs"),
  path = require("node:path"),
  { randomUUID } = require("node:crypto");
function readStore(filename) {
  if (!filename) return null;
  let fd;
  try {
    fd = fs.openSync(filename, "r");
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.size > 2000000) return null;
    const data = Buffer.alloc(2000001),
      n = fs.readSync(fd, data, 0, data.length, 0);
    if (n > 2000000) return null;
    return JSON.parse(data.subarray(0, n).toString("utf8"));
  } catch {
    return null;
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}
function writeStore(filename, value) {
  if (!filename) return;
  const temp = filename + "." + randomUUID() + ".tmp";
  try {
    const data = JSON.stringify(value);
    if (Buffer.byteLength(data) > 2000000) return;
    fs.mkdirSync(path.dirname(filename), { recursive: true, mode: 0o700 });
    fs.writeFileSync(temp, data, { mode: 0o600, flag: "wx" });
    fs.renameSync(temp, filename);
  } catch {
    try {
      fs.unlinkSync(temp);
    } catch {}
  }
}
function validIdentity(value) {
  return typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
}
function cachedUsage(value, provider, now) {
  if (
    !value ||
    value.provider !== provider ||
    !Array.isArray(value.windows) ||
    !Number.isFinite(Date.parse(value.sourceAt)) ||
    Math.abs(now - Date.parse(value.sourceAt)) >= 86400000
  )
    return null;
  const windows = value.windows
    .slice(0, 64)
    .filter(
      (w) =>
        w &&
        typeof w.id === "string" &&
        w.id.length <= 100 &&
        Number.isFinite(w.usedPercent) &&
        w.usedPercent >= 0 &&
        w.usedPercent <= 100,
    )
    .map((w) => ({
      id: w.id,
      label: typeof w.label === "string" ? w.label.slice(0, 100) : w.id,
      usedPercent: w.usedPercent,
      resetsAt: Number.isFinite(Date.parse(w.resetsAt))
        ? new Date(w.resetsAt).toISOString()
        : null,
    }));
  if (!windows.length) return null;
  return {
    provider,
    status: "stale",
    source:
      typeof value.source === "string"
        ? value.source.slice(0, 160)
        : "本机历史记录",
    windows,
    message: "上次记录，等待更新。",
    sourceAt: new Date(value.sourceAt).toISOString(),
    observedAt: null,
  };
}
module.exports = { readStore, writeStore, validIdentity, cachedUsage };
