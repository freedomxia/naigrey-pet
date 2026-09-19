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
  if (!value) return "重置时间未知";
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return "重置时间未知";
  const left = date - Date.now();
  if (left <= 0) return "等待额度刷新";
  if (!state.prefs.countdown)
    return (
      date.toLocaleString("zh-CN", {
        weekday: "short",
        hour: "2-digit",
        minute: "2-digit",
      }) + "重置"
    );
  const m = Math.ceil(left / 60000),
    d = Math.floor(m / 1440),
    h = Math.floor((m % 1440) / 60);
  return `${d ? d + "天 " : ""}${h ? h + "小时 " : ""}${m % 60}分钟后重置`;
}
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
    if (usage?.windows?.length) {
      for (const w of usage.windows.slice(0, 2)) {
        const s = node("section"),
          line = node("div", undefined, "label"),
          remaining = Math.max(0, 100 - w.usedPercent);
        line.append(
          node("span", w.label),
          node(
            "span",
            `剩余 ${Math.round(remaining)}%`,
            "value" + (remaining <= 20 ? " low" : ""),
          ),
        );
        const bar = node("progress");
        bar.max = 100;
        bar.value = remaining;
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
    if (!connected) {
      const b = node("button", "连接 " + names[id], "connect");
      b.onclick = () => command("connect", id);
      box.append(b);
    }
    root.append(box);
  }
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
