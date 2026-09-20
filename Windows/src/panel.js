const api = window.naigrey;
let state;
const names = { codex: "Codex", claude: "Claude" };
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
    if (connected && !state.demo) {
      const b = node("button", "断开");
      b.title = "断开 " + names[id];
      b.onclick = () => command("disconnect", id);
      heading.append(b);
    }
    box.append(heading);
    const sourceTime = Date.parse(usage?.sourceAt || usage?.observedAt);
    const valid =
      state.demo ||
      (usage?.status === "ok" &&
        Number.isFinite(sourceTime) &&
        Date.now() - sourceTime <= 900000);
    if (!valid) box.classList.add("stale");
    if (usage?.windows?.length) {
      for (const w of usage.windows.slice(0, 2)) {
        const s = node("section"),
          line = node("div", undefined, "label"),
          remaining = Math.max(0, 100 - w.usedPercent);
        line.append(
          node("span", w.label),
          node(
            "span",
            w.unlimited
              ? "不限额"
              : `剩余 ${remaining > 0 && remaining < 1 ? "<1" : Math.round(remaining)}%`,
            "value" + (remaining <= 20 ? " low" : ""),
          ),
        );
        const bar = node("progress");
        bar.max = 100;
        if (!w.unlimited) bar.value = remaining;
        bar.setAttribute("aria-label", w.label + "剩余额度");
        s.append(line, bar, node("div", resetText(w.resetsAt), "reset"));
        box.append(s);
      }
    } else
      box.append(
        node(
          "div",
          usage?.message || "连接本机已登录的账号，查看真实额度。",
          "message",
        ),
      );
    if (usage?.windows?.length > 2)
      box.append(
        node(
          "div",
          `另有 ${usage.windows.length - 2} 个窗口，设置中查看`,
          "reset",
        ),
      );
    if (!valid && usage?.windows?.length)
      box.append(
        node(
          "div",
          "历史记录 · " +
            (Number.isFinite(sourceTime)
              ? Math.max(0, Math.floor((Date.now() - sourceTime) / 60000)) +
                " 分钟前"
              : "时间未知"),
          "reset",
        ),
      );
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
