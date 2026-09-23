const api = window.naigrey;
let state;
const names = { codex: "Codex", claude: "Claude" };
const STATUS_NAMES = {
  ok: "已连接",
  stale: "已过期",
  needsAuth: "需登录",
  accessDenied: "未授权",
  unsupported: "暂不支持",
  error: "更新失败",
  disconnected: "未连接",
};
function node(tag, text, className) {
  const n = document.createElement(tag);
  if (text !== undefined) n.textContent = text;
  if (className) n.className = className;
  return n;
}
function resetText(value) {
  return window.ResetCopy.text(value, {
    format: state.prefs.countdown ? "remaining" : "automatic",
  });
}
let renderSignature = "";
async function command(name, value) {
  try {
    const result = await api.command(name, value);
    if (result) {
      state = result;
      render();
    }
  } catch {
    document.querySelector("#status").textContent = "操作未完成，请稍后重试";
  }
}
function render() {
  if (!state) return;
  const signature = JSON.stringify([
    state.usage,
    state.refreshing,
    state.prefs,
    state.sessions,
    Math.floor(Date.now() / 30000),
  ]);
  if (signature === renderSignature) return;
  renderSignature = signature;
  const root = document.querySelector("#providers");
  root.replaceChildren();
  for (const id of ["codex", "claude"]) {
    const usage = state.usage.find((u) => u.provider === id),
      connected = state.prefs.providers.includes(id) || state.demo;
    const box = node("div", undefined, "provider"),
      heading = node("h2", names[id]);
    const sourceTime = Date.parse(usage?.sourceAt || usage?.observedAt);
    const valid =
      state.demo ||
      (usage?.status === "ok" &&
        Number.isFinite(sourceTime) &&
        Date.now() - sourceTime <= 900000);
    // Whether this column is live, stale or not connected at all belongs next
    // to the name, not only in the one shared line at the bottom.
    heading.append(
      node(
        "span",
        state.refreshing?.includes(id)
          ? "更新中…"
          : usage
            ? STATUS_NAMES[usage.status] || "状态未知"
            : "未连接",
        "state" + (valid ? "" : " stale-state"),
      ),
    );
    if (connected && !state.demo) {
      const b = node("button", "断开");
      b.title = "断开 " + names[id];
      b.onclick = () => command("disconnect", id);
      heading.append(b);
    }
    box.append(heading);
    if (!valid) box.classList.add("stale");
    const shown = (usage?.windows || []).filter((w) => !w.isExtra),
      total = (usage?.windows || []).length,
      extras = total - shown.length;
    // Branch on having any reading at all, as the Mac does: a provider whose
    // only windows are extras still has data and must not read as unread.
    if (total) {
      for (const w of shown) {
        const s = node("section"),
          line = node("div", undefined, "label");
        // Unknown and unlimited both mean "no remaining fraction to show", and
        // neither may borrow the healthy green of a real reading.
        const known = !w.unlimited && Number.isFinite(w.usedPercent),
          remaining = known ? Math.max(0, 100 - w.usedPercent) : null;
        const tier =
          remaining === null
            ? " unknown"
            : remaining <= 10
              ? " critical"
              : remaining <= 20
                ? " low"
                : "";
        line.append(
          node("span", w.label),
          node(
            "span",
            w.unlimited
              ? "不限额"
              : remaining === null
                ? "未知"
                : `剩余 ${remaining > 0 && remaining < 1 ? "<1" : Math.round(remaining)}%`,
            "value" + tier,
          ),
        );
        const bar = node("progress");
        bar.max = 100;
        // An empty track, never the indeterminate animation a valueless
        // <progress> would run.
        bar.value = remaining === null ? 0 : remaining;
        bar.className = tier.trim();
        bar.setAttribute("aria-label", w.label + "剩余额度");
        if (remaining === null)
          bar.setAttribute("aria-valuetext", w.unlimited ? "不限额" : "未知");
        s.append(line, bar, node("div", resetText(w.resetsAt), "reset"));
        box.append(s);
      }
    } else {
      box.append(
        node(
          "div",
          usage?.message ||
            (connected
              ? "正在读取账号额度…"
              : "连接后显示剩余额度与重置时间。"),
          "message",
        ),
      );
      // Unknown is visually grey, never a false 0% or a full green bar.
      const placeholder = node("progress");
      placeholder.max = 100;
      placeholder.value = 0;
      placeholder.className = "unknown";
      placeholder.setAttribute("aria-label", "剩余额度");
      placeholder.setAttribute("aria-valuetext", "未知");
      box.append(placeholder);
    }
    if (extras > 0)
      box.append(
        node("div", `另有 ${extras} 个额度窗口，可在设置查看`, "reset"),
      );
    const minutes = Number.isFinite(sourceTime)
      ? Math.max(0, Math.floor((Date.now() - sourceTime) / 60000))
      : null;
    if (total) {
      const age =
        minutes === null
          ? "时间未知"
          : minutes === 0
            ? "刚刚确认"
            : `${minutes} 分钟前确认`;
      if (valid) heading.title = age;
      else {
        box.append(
          node(
            "div",
            "历史记录 · " +
              (minutes === null ? "时间未知" : `${minutes} 分钟前`),
            "reset",
          ),
        );
        if (usage?.message) box.append(node("div", usage.message, "message"));
      }
    }
    if (!connected) {
      const b = node("button", "连接 " + names[id], "connect");
      b.onclick = () => command("connect", id);
      box.append(b);
    }
    root.append(box);
  }
  const list = state.sessions || [];
  document.querySelector("#sessions").textContent = list.length
    ? ["codex", "claude"]
        .map((p) => {
          const v = list.filter((x) => x.provider === p);
          if (!v.length) return "";
          const waiting = v.filter((x) => x.state === "waiting").length,
            busy = v.filter((x) => x.state === "busy").length;
          return (
            names[p] +
            " · " +
            (waiting
              ? waiting + " 个等待操作"
              : busy
                ? busy + " 个活动中"
                : v.some((x) => ["ended", "success"].includes(x.state))
                  ? "本轮结束"
                  : "空闲或状态未知")
          );
        })
        .filter(Boolean)
        .join("　")
    : "任务 · 暂无可确认的活动";
  const error = state.usage.find(
    (u) => !["ok", "disconnected", "idle"].includes(u.status),
  );
  document.querySelector("#status").textContent = state.demo
    ? "演示数据 · 未连接真实账号"
    : error?.message || "点击别处收起 · 额度在后台刷新";
}
api.bootstrap().then((s) => {
  state = s;
  render();
});
api.on("state", (s) => {
  state = s;
  render();
});
document.querySelector("#refresh").onclick = () => command("refresh");
document.querySelector("#settings").onclick = () => command("settings");
document.querySelector("#close").onclick = () => command("hide-panel");
setInterval(render, 30000);
