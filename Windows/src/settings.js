const api = window.naigrey;
const fields = {
  countdown: "显示重置倒计时",
  notifications: "系统通知",
  sound: "通知声音",
  quiet: "夜间免打扰 · 22:00–08:00",
  autonomous: "自主活动 · 走动、伸懒腰和小睡",
  motion: "额度提醒时招招手",
  startup: "开机启动",
};
function render(state) {
  const root = document.querySelector("#options");
  root.replaceChildren();
  for (const [key, title] of Object.entries(fields)) {
    const label = document.createElement("label");
    label.textContent = title;
    const input = document.createElement("input");
    input.type = "checkbox";
    input.checked = state.prefs[key];
    input.onchange = () =>
      api.command("preference", { key, value: input.checked });
    label.append(input);
    root.append(label);
  }
}
api.bootstrap().then(render);
api.on("state", render);
