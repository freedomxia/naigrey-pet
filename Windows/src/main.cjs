const {
  app,
  BrowserWindow,
  ipcMain,
  Tray,
  Menu,
  nativeImage,
  screen,
  Notification,
  shell,
} = require("electron");
const fs = require("node:fs");
const path = require("node:path");
const {
  clampPosition,
  panelPosition,
  advanceWalk,
} = require("./pet-model.cjs");
const { QuotaService } = require("./quota.cjs");
const demo = process.argv.includes("--demo"),
  smoke = process.argv.includes("--smoke-test");
if (smoke)
  app.setPath(
    "userData",
    path.join(app.getPath("temp"), "naigrey-windows-smoke-" + process.pid),
  );
app.setName("奶灰桌宠 Windows");
app.setAppUserModelId("com.freedomxia.naigrey.windows");
if (!app.requestSingleInstanceLock()) app.quit();
let pet,
  panel,
  settingsWindow,
  tray,
  service,
  drag,
  timer,
  quitting = false,
  petReady = false,
  walking = false,
  walkX = null;
const presentationQueue = [];
let prefs = {
  providers: [],
  notifications: false,
  sound: false,
  quiet: false,
  countdown: true,
  motion: true,
  autonomous: true,
  startup: false,
};
const prefsFile = () => path.join(app.getPath("userData"), "settings.json");
function save() {
  fs.mkdirSync(app.getPath("userData"), { recursive: true });
  fs.writeFileSync(prefsFile(), JSON.stringify(prefs), { mode: 0o600 });
}
function load() {
  try {
    const v = JSON.parse(fs.readFileSync(prefsFile(), "utf8"));
    for (const k of [
      "notifications",
      "sound",
      "quiet",
      "countdown",
      "motion",
      "autonomous",
      "startup",
    ])
      if (typeof v[k] === "boolean") prefs[k] = v[k];
    prefs.providers = Array.isArray(v.providers)
      ? v.providers.filter((p) => ["codex", "claude"].includes(p))
      : [];
    if (Number.isFinite(v.position?.x) && Number.isFinite(v.position?.y))
      prefs.position = v.position;
  } catch {}
}
function send(win, type, value) {
  if (win && !win.isDestroyed() && !win.webContents.isDestroyed())
    win.webContents.send(type, value);
}
function all(type, value) {
  for (const w of [pet, panel, settingsWindow]) send(w, type, value);
}
function demoData() {
  return ["codex", "claude"].map((provider, i) => ({
    provider,
    status: "ok",
    source: "演示数据",
    windows: [
      {
        id: "session",
        label: i ? "当前会话" : "5 小时额度",
        usedPercent: i ? 80 : 68,
        resetsAt: new Date(Date.now() + 7200000).toISOString(),
      },
      {
        id: "weekly",
        label: "每周额度",
        usedPercent: 33,
        resetsAt: new Date(Date.now() + 3 * 86400000).toISOString(),
      },
    ],
    message: "演示数据 · 未连接真实账号",
  }));
}
function snapshot() {
  return { usage: demo ? demoData() : service.snapshot(), prefs, demo, smoke };
}
function windowFor(file, options) {
  const w = new BrowserWindow({
    show: false,
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      // A desktop companion must keep drawing while other applications have focus.
      backgroundThrottling: file !== "pet.html",
    },
    ...options,
  });
  w.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  w.webContents.on("will-navigate", (e) => e.preventDefault());
  w.loadFile(path.join(__dirname, file));
  return w;
}
function repositionPanel() {
  if (!pet || !panel) return;
  const b = pet.getBounds(),
    a = screen.getDisplayMatching(b).workArea;
  panel.setPosition(...Object.values(panelPosition(b, a)));
}
function showPanel() {
  if (smoke) return;
  repositionPanel();
  panel.show();
  panel.focus();
  send(panel, "state", snapshot());
}
function showSettings() {
  if (settingsWindow && !settingsWindow.isDestroyed()) {
    settingsWindow.show();
    return;
  }
  settingsWindow = windowFor("settings.html", {
    width: 380,
    height: 470,
    resizable: false,
    title: "奶灰 · 设置",
    backgroundColor: "#f8f5ef",
  });
  settingsWindow.once("ready-to-show", () => settingsWindow.show());
  settingsWindow.on("closed", () => (settingsWindow = null));
}
function act(action) {
  if (!petReady) {
    presentationQueue.push(["action", action]);
    return;
  }
  send(pet, "action", action);
}
function present(type, value) {
  if (!petReady) {
    presentationQueue.push([type, value]);
    return;
  }
  send(pet, type, value);
}
function menu() {
  return Menu.buildFromTemplate([
    { label: "查看 AI 额度", click: showPanel },
    { type: "separator" },
    ...[
      ["wave", "招招手"],
      ["play", "玩毛线球"],
      ["type", "敲键盘"],
      ["stretch", "伸懒腰"],
      ["walk", "走一走"],
      ["music", "听音乐"],
      ["sleep", "睡觉"],
      ["idle", "叫醒"],
    ].map(([a, label]) => ({ label, click: () => act(a) })),
    { type: "separator" },
    { label: "设置", click: showSettings },
    {
      label: "回到屏幕中央",
      click: () => {
        const a = screen.getPrimaryDisplay().workArea;
        pet.setPosition(
          Math.round(a.x + a.width / 2 - 210),
          Math.round(a.y + a.height / 2 - 130),
        );
        walkX = pet.getBounds().x;
      },
    },
    {
      label: "下载与版本",
      click: () =>
        shell.openExternal(
          "https://github.com/freedomxia/naigrey-pet/releases",
        ),
    },
    { type: "separator" },
    { label: "退出奶灰", click: () => app.quit() },
  ]);
}
function trusted(e) {
  return [pet, panel, settingsWindow].some(
    (w) =>
      w &&
      !w.isDestroyed() &&
      e.sender === w.webContents &&
      e.senderFrame === w.webContents.mainFrame,
  );
}
function muted() {
  return (
    prefs.quiet && (new Date().getHours() >= 22 || new Date().getHours() < 8)
  );
}
app.whenReady().then(() => {
  load();
  service = new QuotaService();
  service.on("change", () => all("state", snapshot()));
  service.on("reminder", (r) => {
    if (muted()) return;
    present("bubble", r.body || r.title);
    if (prefs.motion) act("wave");
    if (prefs.notifications && Notification.isSupported())
      new Notification({
        title: r.title,
        body: r.body || "",
        silent: !prefs.sound,
      }).show();
  });
  const area = screen.getPrimaryDisplay().workArea;
  const position = clampPosition(
    prefs.position || {
      x: area.x + area.width - 450,
      y: area.y + area.height - 520,
    },
    { width: 420, height: 260 },
    screen.getDisplayNearestPoint(prefs.position || { x: area.x, y: area.y })
      .workArea,
  );
  pet = windowFor("pet.html", {
    ...position,
    width: 420,
    height: 260,
    frame: false,
    transparent: true,
    resizable: false,
    hasShadow: false,
    alwaysOnTop: true,
    skipTaskbar: true,
    backgroundColor: "#00000000",
    title: "奶灰桌宠 Windows",
  });
  panel = windowFor("panel.html", {
    width: 360,
    height: 230,
    frame: false,
    resizable: false,
    alwaysOnTop: true,
    skipTaskbar: true,
    backgroundColor: "#f8f5ef",
    title: "奶灰 · AI 额度",
  });
  panel.on("blur", () => panel.hide());
  panel.on("close", (e) => {
    if (!quitting) {
      e.preventDefault();
      panel.hide();
    }
  });
  pet.once("ready-to-show", () => {
    if (!smoke) pet.showInactive();
  });
  pet.on("move", () => {
    if (panel.isVisible()) repositionPanel();
    clearTimeout(timer);
    timer = setTimeout(() => {
      prefs.position = pet
        .getPosition()
        .reduce((p, v, i) => ({ ...p, [i ? "y" : "x"]: v }), {});
      if (!smoke) save();
    }, 300);
  });
  pet.on("close", (e) => {
    if (!quitting) {
      e.preventDefault();
      pet.hide();
    }
  });
  screen.on("display-removed", () => {
    const a = screen.getPrimaryDisplay().workArea;
    const p = clampPosition(
      { x: pet.getBounds().x, y: pet.getBounds().y },
      pet.getBounds(),
      a,
    );
    pet.setPosition(p.x, p.y);
    walkX = pet.getBounds().x;
  });
  if (!smoke) {
    const icon = nativeImage.createFromPath(
      path.join(__dirname, "../assets/tray.png"),
    );
    tray = new Tray(
      icon.isEmpty()
        ? nativeImage
            .createFromPath(path.join(__dirname, "../assets/cats.png"))
            .resize({ width: 32, height: 18 })
        : icon,
    );
    tray.setToolTip("奶灰桌宠");
    tray.setContextMenu(menu());
    tray.on("click", () => {
      pet.showInactive();
      showPanel();
    });
  }
  ipcMain.handle("bootstrap", (e) => {
    if (!trusted(e)) return null;
    return snapshot();
  });
  ipcMain.handle("command", async (e, name, value) => {
    if (!trusted(e)) return;
    if (name === "ready" && e.sender === pet.webContents) {
      petReady = true;
      for (const [type, v] of presentationQueue.splice(0)) send(pet, type, v);
      return;
    }
    if (name === "panel") {
      showPanel();
      return;
    }
    if (name === "hide-panel") {
      panel.hide();
      return;
    }
    if (name === "settings") {
      showSettings();
      return;
    }
    if (name === "menu") {
      Menu.setApplicationMenu(null);
      menu().popup({ window: pet });
      return;
    }
    if (
      name === "action" &&
      [
        "idle",
        "wave",
        "play",
        "type",
        "stretch",
        "walk",
        "music",
        "sleep",
      ].includes(value)
    ) {
      act(value);
      return;
    }
    if (name === "refresh" && !demo) {
      await service.refresh();
      return snapshot();
    }
    if (name === "connect" && ["codex", "claude"].includes(value) && !demo) {
      if (!prefs.providers.includes(value)) prefs.providers.push(value);
      save();
      await service.connect(value);
      return snapshot();
    }
    if (name === "disconnect" && ["codex", "claude"].includes(value) && !demo) {
      prefs.providers = prefs.providers.filter((p) => p !== value);
      save();
      service.disconnect(value);
      return snapshot();
    }
    if (
      name === "preference" &&
      value &&
      [
        "notifications",
        "sound",
        "quiet",
        "countdown",
        "motion",
        "autonomous",
        "startup",
      ].includes(value.key) &&
      typeof value.value === "boolean"
    ) {
      prefs[value.key] = value.value;
      if (value.key === "startup" && process.platform === "win32")
        app.setLoginItemSettings({ openAtLogin: value.value });
      save();
      all("state", snapshot());
      return snapshot();
    }
    if (name === "phase" && e.sender === pet.webContents) {
      walking = value === "walk";
      walkX = walking ? pet.getBounds().x : null;
      return;
    }
    if (
      name === "walk-step" &&
      e.sender === pet.webContents &&
      walking &&
      !drag &&
      Number.isFinite(value) &&
      Math.abs(value) <= 8
    ) {
      const b = pet.getBounds(),
        a = screen.getDisplayMatching(b).workArea;
      walkX = advanceWalk(walkX ?? b.x, value, b.width, a);
      const p = clampPosition({ x: walkX, y: b.y }, b, a);
      pet.setPosition(p.x, p.y);
      return;
    }
    if (
      name === "pointer" &&
      e.sender === pet.webContents &&
      typeof value === "boolean" &&
      !drag
    ) {
      pet.setIgnoreMouseEvents(!value, { forward: true });
      return;
    }
    if (name === "drag-start" && e.sender === pet.webContents) {
      drag = { cursor: screen.getCursorScreenPoint(), bounds: pet.getBounds() };
      pet.setIgnoreMouseEvents(false);
      return;
    }
    if (name === "drag-move" && e.sender === pet.webContents && drag) {
      const c = screen.getCursorScreenPoint();
      const p = clampPosition(
        {
          x: drag.bounds.x + c.x - drag.cursor.x,
          y: drag.bounds.y + c.y - drag.cursor.y,
        },
        drag.bounds,
        screen.getDisplayNearestPoint(c).workArea,
      );
      pet.setPosition(p.x, p.y);
      return;
    }
    if (name === "drag-end") {
      drag = null;
      walkX = pet.getBounds().x;
      return;
    }
    if (name === "smoke-result" && smoke) {
      console.log("NAIGREY_SMOKE " + JSON.stringify(value));
      app.exit(value?.ok ? 0 : 1);
    }
  });
  if (smoke)
    setTimeout(() => {
      console.error("Smoke test timeout");
      app.exit(1);
    }, 60000).unref();
  else if (!demo) {
    for (const p of prefs.providers) service.connect(p);
    service.start();
  }
});
app.on("second-instance", () => {
  pet?.showInactive();
  showPanel();
});
app.on("before-quit", () => {
  quitting = true;
  clearTimeout(timer);
  service?.stop();
});
app.on("window-all-closed", () => {
  if (quitting) app.quit();
});
