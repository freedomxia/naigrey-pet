"use strict";
const api = window.naigrey;
const fields = {
  countdown: "显示重置倒计时",
  notifications: "系统通知",
  sound: "提醒声音",
  motion: "提醒时轻轻眨眼",
  notifyWaiting: "任务等待操作",
  notifyEnded: "任务本轮结束",
  notifyReset: "额度恢复",
  autonomous: "自主活动",
  roaming: "自由走动",
  routine: "跟随我的作息",
  company: "陪我打字和听音乐",
  startup: "开机启动",
  claudeRenewal: "允许调用 Claude CLI 查询并续期登录",
};
let state,
  signature = "";
function el(tag, text) {
  const n = document.createElement(tag);
  if (text !== undefined) n.textContent = text;
  return n;
}
async function command(name, value) {
  try {
    const result = await api.command(name, value);
    if (result) render(result);
  } catch {
    document.querySelector("#notice").textContent = "操作未完成，请重试。";
  }
}
function preference(key, value) {
  return command("preference", { key, value });
}
function button(text, fn) {
  const b = el("button", text);
  b.onclick = fn;
  return b;
}
function render(s) {
  state = s;
  const next = JSON.stringify([
    s.prefs,
    s.usage,
    s.sessions,
    s.reminders,
    s.senses?.status,
    s.update,
  ]);
  if (next === signature) return;
  signature = next;
  for (const [key] of Object.entries(fields)) {
    const input = document.querySelector(`[data-key="${key}"]`);
    input.checked = !!s.prefs[key];
  }
  document.querySelector("#size").value = s.prefs.catHeight;
  document.querySelector("#quiet").checked = s.prefs.quiet;
  for (const k of ["quietStart", "quietEnd"]) {
    const input = document.querySelector("#" + k);
    if (document.activeElement !== input) {
      const m = s.prefs[k] ?? 0;
      input.value =
        String(Math.floor(m / 60)).padStart(2, "0") +
        ":" +
        String(m % 60).padStart(2, "0");
    }
  }
  const root = document.querySelector("#details");
  root.replaceChildren();
  for (const p of ["codex", "claude"]) {
    const u = s.usage.find((u) => u.provider === p),
      heading = el("h2", p === "codex" ? "Codex" : "Claude");
    const connected = s.prefs.providers.includes(p);
    heading.append(
      button(connected ? "断开" : "连接本机账号", () =>
        command(connected ? "disconnect" : "connect", p),
      ),
      button(s.prefs.mutedProviders.includes(p) ? "取消静音" : "静音", () =>
        preference(
          "mutedProviders",
          s.prefs.mutedProviders.includes(p)
            ? s.prefs.mutedProviders.filter((x) => x !== p)
            : [...s.prefs.mutedProviders, p],
        ),
      ),
    );
    root.append(heading);
    if (u) {
      const age = Date.parse(u.sourceAt || u.observedAt);
      root.append(
        el(
          "p",
          `${u.source || "未连接"}${Number.isFinite(age) ? " · " + Math.max(0, Math.floor((Date.now() - age) / 60000)) + " 分钟前确认" : ""}`,
        ),
      );
      if (u.message) root.append(el("p", u.message));
      for (const w of u.windows || []) {
        const row = el(
          "p",
          `${w.label} · ${w.unlimited ? "不限额" : Number.isFinite(w.usedPercent) ? "剩余 " + (100 - w.usedPercent > 0 && 100 - w.usedPercent < 1 ? "<1" : Math.round(Math.max(0, 100 - w.usedPercent))) + "%" : "未知"}${w.resetsAt ? "\n" + window.ResetCopy.text(w.resetsAt, { format: s.prefs.countdown ? "remaining" : "automatic" }) : ""}`,
        );
        root.append(row);
      }
    }
  }
  root.append(el("h2", "任务"));
  const names = {
    busy: "工作中",
    waiting: "等待操作",
    ended: "本轮结束",
    idle: "空闲",
    unknown: "状态未知",
    failure: "失败",
    success: "已完成",
  };
  for (const x of s.sessions || [])
    root.append(
      el(
        "p",
        `${x.provider} · ${x.name} · ${names[x.state] || "状态未知"}${x.evidence === "explicit" ? "" : "（检测到活动）"}`,
      ),
    );
  if (!s.sessions?.length)
    root.append(el("p", "未检测到可确认的活动。没有更新不代表任务完成。"));
  root.append(
    el(
      "h2",
      `最近提醒${s.reminders?.unreadCount ? " · " + s.reminders.unreadCount + " 条未读" : ""}`,
    ),
  );
  for (const r of (s.reminders?.history || []).slice(-5).reverse())
    root.append(el("p", r.title + "\n" + r.body));
  if (!s.reminders?.history?.length) root.append(el("p", "暂无提醒。"));
  document.querySelector("#notice").textContent = s.demo
    ? "演示数据 · 未连接真实账号"
    : s.senses?.status === "ok"
      ? "按你的节奏陪伴"
      : "系统感知：" + (s.senses?.status || "正在启动");
}
for (const [key, title] of Object.entries(fields)) {
  const label = el("label", title),
    input = el("input");
  input.type = "checkbox";
  input.dataset.key = key;
  input.onchange = () => preference(key, input.checked);
  label.append(input);
  document.querySelector("#options").append(label);
}
document.querySelector("#size").onchange = (e) =>
  preference("catHeight", Number(e.target.value));
document.querySelector("#quiet").onchange = (e) =>
  preference("quiet", e.target.checked);
for (const key of ["quietStart", "quietEnd"])
  document.querySelector("#" + key).onchange = (e) => {
    const [h, m] = e.target.value.split(":").map(Number);
    if (Number.isInteger(h) && Number.isInteger(m)) preference(key, h * 60 + m);
  };
document.querySelector("#mute").onclick = () =>
  preference("mutedUntil", Date.now() + 3600000);
document.querySelector("#unmute").onclick = async () => {
  await preference("mutedUntil", 0);
  await preference("quietOverrideUntil", Date.now() + 3600000);
};
document.querySelector("#refresh").onclick = () => command("refresh");
document.querySelector("#update").onclick = () => command("check-update");
api.bootstrap().then(render);
api.on("state", render);
