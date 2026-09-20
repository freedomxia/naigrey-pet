"use strict";
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
  powerMonitor,
  dialog,
} = require("electron");
const fs = require("node:fs"),
  path = require("node:path");
const {
  clampPosition,
  panelPosition,
  advanceWalk,
  WINDOW_WIDTH: W,
  WINDOW_HEIGHT: H,
  CENTER_X: CX,
  GROUND,
} = require("./pet-model.cjs");
const { QuotaService } = require("./quota.cjs");
const { Companion } = require("./companion.cjs");
const { NativeSenses } = require("./senses.cjs");
const { SessionReader, SessionRules } = require("./sessions.cjs");
const { ReminderCenter } = require("./reminder-center.cjs");
const { YarnBall } = require("./pet-ball.cjs");
const { Updater } = require("./updater.cjs");
const clipMetadata = require("../assets/clips/clips.json");
const playClip = clipMetadata.clips.find((c) => c.name === "play");
const demo = process.argv.includes("--demo"),
  smoke = process.argv.includes("--smoke-test");
if (smoke)
  app.setPath(
    "userData",
    path.join(app.getPath("temp"), "naigrey-windows-smoke-" + process.pid),
  );
app.setName("奶灰桌宠 Windows");
app.setAppUserModelId("com.freedomxia.naigrey.windows");
const primary = app.requestSingleInstanceLock();
if (!primary) app.quit();
let pet,
  panel,
  settingsWindow,
  ballWindow,
  tray,
  service,
  senses,
  reader,
  companion,
  updater;
let petReady = false,
  quitting = false,
  suspended = false,
  drag = null,
  phase = "idle",
  direction = -1,
  walkX = null,
  company = "none",
  typeRate = 1;
let timer,
  tickTimer,
  physicsTimer,
  sessionBusy = false,
  sessions = [],
  sessionGeneration = 0,
  lastSessionScan = 0,
  lastRefresh = 0,
  walkUntil = 0,
  walkDuration = 0,
  lastPointerSend = 0;
let ball = null,
  playState = "off",
  playUntil = 0,
  playEnergy = 1,
  lastPhysics = 0,
  playStarted = 0,
  updateRelease = null,
  updating = false;
const cliPids = new Set(),
  sessionRules = new SessionRules(),
  reminders = new ReminderCenter(),
  presentationQueue = [];
const booleanPrefs = [
  "notifications",
  "sound",
  "quiet",
  "countdown",
  "motion",
  "autonomous",
  "startup",
  "roaming",
  "routine",
  "company",
  "claudeRenewal",
  "notifyWaiting",
  "notifyEnded",
  "notifyReset",
];
let prefs = {
  providers: [],
  notifications: false,
  sound: false,
  quiet: false,
  countdown: true,
  motion: true,
  autonomous: true,
  startup: false,
  roaming: true,
  routine: true,
  company: true,
  claudeRenewal: false,
  notifyWaiting: true,
  notifyEnded: true,
  notifyReset: true,
  catHeight: 140,
  systemCompanion: true,
  mutedProviders: [],
  quietStart: 1320,
  quietEnd: 480,
  onceState: {},
};
const prefsFile = () => path.join(app.getPath("userData"), "settings.json");
function save() {
  if (smoke) return;
  fs.mkdirSync(app.getPath("userData"), { recursive: true });
  fs.writeFileSync(prefsFile(), JSON.stringify(prefs), { mode: 0o600 });
}
function load() {
  try {
    const v = JSON.parse(fs.readFileSync(prefsFile(), "utf8"));
    for (const k of booleanPrefs)
      if (typeof v[k] === "boolean") prefs[k] = v[k];
    prefs.providers = Array.isArray(v.providers)
      ? v.providers.filter((p) => ["codex", "claude"].includes(p))
      : [];
    prefs.mutedProviders = Array.isArray(v.mutedProviders)
      ? v.mutedProviders.filter((p) => ["codex", "claude"].includes(p))
      : [];
    if ([72, 100, 130, 140, 170].includes(v.catHeight))
      prefs.catHeight = v.catHeight;
    if (Number.isFinite(v.position?.x) && Number.isFinite(v.position?.y))
      prefs.position = v.position;
    for (const key of ["mutedUntil", "quietOverrideUntil"])
      if (Number.isFinite(v[key])) prefs[key] = v[key];
    for (const key of ["quietStart", "quietEnd"])
      if (Number.isInteger(v[key]) && v[key] >= 0 && v[key] < 1440)
        prefs[key] = v[key];
    if (
      v.onceState &&
      typeof v.onceState === "object" &&
      !Array.isArray(v.onceState)
    )
      prefs.onceState = Object.fromEntries(
        Object.entries(v.onceState).filter(
          ([k, x]) =>
            ["morning", "lunch", "evening", "late"].includes(k) &&
            /^\d{4}-\d{2}-\d{2}$/.test(x),
        ),
      );
  } catch {}
}
function send(w, type, value) {
  if (w && !w.isDestroyed() && !w.webContents.isDestroyed())
    w.webContents.send(type, value);
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
        id: i ? "session" : "primary",
        label: i ? "当前会话" : "5 小时额度",
        usedPercent: i ? 80 : 68,
        resetsAt: new Date(Date.now() + 7200000).toISOString(),
      },
      {
        id: i ? "weekly_all" : "secondary",
        label: "每周额度",
        usedPercent: 33,
        resetsAt: new Date(Date.now() + 3 * 86400000).toISOString(),
      },
    ],
    message: "演示数据 · 未连接真实账号",
  }));
}
function reminderPrefs() {
  return {
    ...prefs,
    quietStart: prefs.quiet ? prefs.quietStart : null,
    quietEnd: prefs.quiet ? prefs.quietEnd : null,
  };
}
function pointerSenses() {
  const b = pet?.getBounds(),
    p = screen.getCursorScreenPoint();
  const focus = ball && (playState !== "off" || ball.held || !ball.isResting);
  const target = focus ? { x: ball.x, y: ball.y } : p;
  return {
    ...senses?.snapshot(),
    pointer: { x: target.x - (b?.x || 0), y: target.y - (b?.y || 0) },
    fixated: !!focus,
  };
}
function snapshot() {
  return {
    usage: demo ? demoData() : service?.snapshot() || [],
    prefs,
    demo,
    smoke,
    sessions,
    company,
    typeRate,
    direction,
    senses: pointerSenses(),
    ball: ball?.snapshot(),
    reminders: reminders.snapshot(),
    update: updateRelease ? { version: updateRelease.version } : null,
  };
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
      backgroundThrottling: !["pet.html", "pet-ball.html"].includes(file),
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
  const pos = panelPosition(b, a);
  panel.setPosition(pos.x, pos.y);
}
function showPanel() {
  if (smoke || !panel) return;
  reminders.markRead();
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
    width: 420,
    height: 680,
    resizable: false,
    title: "奶灰 · 设置",
    backgroundColor: "#f8f5ef",
  });
  settingsWindow.once("ready-to-show", () => settingsWindow.show());
  settingsWindow.on("closed", () => (settingsWindow = null));
}
function present(type, value) {
  if (!petReady) {
    presentationQueue.push([type, value]);
    return;
  }
  send(pet, type, value);
}
function act(action, { manual = false, duration = 0 } = {}) {
  if (manual) {
    companion?.manual(action, Date.now());
    company = "none";
    if (companion) companion.company = "none";
    typeRate = 1;
    if (action !== "play") stopPlaying();
  }
  if (action === "walk") {
    direction = Math.random() < 0.5 ? -1 : 1;
    walkDuration = duration || 7000;
    walkUntil = 0;
  }
  if (["sleep", "idle", "stop"].includes(action)) {
    walkUntil = 0;
    walkDuration = 0;
  }
  if (action === "sleep") stopPlaying();
  send(pet, "state", snapshot());
  present("action", action);
}
function userAction(action) {
  if (action === "play") {
    companion.manual(action, Date.now());
    toggleBall();
    return;
  }
  act(action, { manual: true });
}
function applyCompanion(result) {
  company = result.company;
  typeRate = result.typeRate;
  if (result.action && !["type", "music"].includes(result.action))
    act(result.action, { duration: result.duration });
  if (result.bubble) present("bubble", result.bubble);
}
function stopPlaying(close = false) {
  playState = "off";
  if (!close) {
    if (ball) ball.held = false;
    if (ballWindow && !ballWindow.isDestroyed()) ballWindow.showInactive();
    return;
  }
  ball = null;
  if (ballWindow && !ballWindow.isDestroyed()) ballWindow.close();
  ballWindow = null;
}
function toggleBall() {
  if (ball) {
    stopPlaying(true);
    act("idle");
    return;
  }
  act("stop");
  company = "none";
  const b = pet.getBounds(),
    a = screen.getDisplayMatching(b).workArea,
    r = Math.max(7, prefs.catHeight * 0.13);
  ball = new YarnBall({
    radius: r,
    x: Math.min(a.x + a.width - r, b.x + CX + prefs.catHeight * 1.4),
    y: b.y + GROUND - prefs.catHeight * 1.1,
  });
  playState = "watch";
  playUntil = Date.now() + 400;
  playEnergy = 1;
  const size = Math.ceil(r * 2 + 6);
  ballWindow = windowFor("pet-ball.html", {
    width: size,
    height: size,
    x: Math.round(ball.x - r - 3),
    y: Math.round(ball.y - r - 3),
    frame: false,
    transparent: true,
    resizable: false,
    alwaysOnTop: true,
    skipTaskbar: true,
    hasShadow: false,
    backgroundColor: "#00000000",
  });
  const win = ballWindow;
  win.once("ready-to-show", () => {
    if (!win.isDestroyed()) win.showInactive();
  });
  win.on("closed", () => {
    if (ballWindow === win) {
      ballWindow = null;
      ball = null;
      playState = "off";
    }
  });
}
function stepBall() {
  if (!ball || !pet || suspended) return;
  const now = Date.now(),
    dt = Math.min(0.05, (now - lastPhysics) / 1000 || 0.016);
  lastPhysics = now;
  const b = pet.getBounds(),
    a = screen.getDisplayMatching(b).workArea;
  ball.step(dt, Math.min(a.y + a.height, b.y + GROUND), [a.x, a.x + a.width]);
  if (ballWindow && !ballWindow.isDestroyed()) {
    const cursor = screen.getCursorScreenPoint();
    ballWindow.setIgnoreMouseEvents(
      !ball.held && !ball.contains(cursor.x, cursor.y),
      { forward: true },
    );
    const r = ball.radius;
    ballWindow.setPosition(
      Math.round(ball.x - r - 3),
      Math.round(ball.y - r - 3),
    );
    send(ballWindow, "state", { ball: ball.snapshot() });
  }
  if (playState === "off") return;
  playEnergy = Math.max(0, playEnergy - dt / 60);
  if (!playEnergy && phase === "idle") {
    stopPlaying();
    present("bubble", "玩累啦～");
    return;
  }
  if (drag || ["sleep", "lieDown"].includes(phase)) {
    stopPlaying();
    return;
  }
  const dx = ball.x - (b.x + CX),
    side = dx >= 0 ? 1 : -1,
    reach =
      (Math.abs(playClip.ballStart[0] - playClip.start[0]) * prefs.catHeight) /
      clipMetadata.sitHeight;
  if (
    playState === "watch" &&
    phase === "idle" &&
    now >= playUntil &&
    !ball.held &&
    ball.speed < 90
  ) {
    direction = side;
    if (Math.abs(Math.abs(dx) - reach) < reach * 0.45) {
      playState = "windup";
      playUntil = now + 450;
    } else {
      playState = "chase";
      direction = ball.x - side * reach > b.x + CX ? 1 : -1;
      walkDuration = 30000;
      walkUntil = 0;
      send(pet, "state", snapshot());
      present("action", "walk");
    }
  } else if (playState === "chase") {
    const goal = ball.x - side * reach,
      heading = goal > b.x + CX ? 1 : -1;
    if (
      ball.held ||
      ball.speed > 400 ||
      !["walk", "standUp", "idle"].includes(phase) ||
      Math.abs(goal - b.x - CX) < reach * 0.25 ||
      heading !== direction
    ) {
      walkUntil = 0;
      walkDuration = 0;
      present("action", "idle");
      playState = "watch";
      playUntil = now + 500;
    }
  } else if (playState === "windup" && now >= playUntil) {
    if (
      ball.held ||
      ball.speed > 150 ||
      Math.abs(Math.abs(dx) - reach) > reach * 0.6
    ) {
      playState = "watch";
      playUntil = now + 300;
      return;
    }
    direction = side;
    send(pet, "state", snapshot());
    playState = "swat";
    playStarted = now;
    ball.held = true;
    present("action", "play");
  } else if (
    playState === "swat" &&
    phase === "idle" &&
    now - playStarted > 1000
  ) {
    ball.held = false;
    ballWindow?.showInactive();
    playState = "watch";
    playUntil = now + 800;
  }
}
async function checkUpdates(manual = false) {
  if (smoke || demo || updating) return;
  try {
    const release = await updater.check({ force: manual });
    if (!release) {
      if (manual)
        dialog.showMessageBox(pet, {
          type: "info",
          message: "当前 Windows 版本已是最新版本。",
        });
      return;
    }
    updateRelease = release;
    tray?.setContextMenu(menu());
    if (!manual) {
      present(
        "bubble",
        `奶灰 Windows ${release.version} 可以更新啦，右键菜单可安装。`,
      );
      return;
    }
    const choice = await dialog.showMessageBox(pet, {
      type: "question",
      message: `发现 Windows ${release.version}`,
      detail: "下载并校验安装包后启动安装。现有设置会保留。",
      buttons: ["下载并安装", "稍后"],
      defaultId: 1,
      cancelId: 1,
    });
    if (choice.response !== 0) return;
    updating = true;
    const file = await updater.download(release);
    const error = await shell.openPath(file);
    if (error) throw new Error("installer");
    app.quit();
  } catch {
    if (manual)
      dialog.showMessageBox(pet, {
        type: "error",
        message: "更新未完成，请稍后重试。",
        detail: "未运行未经校验的安装包。",
      });
  } finally {
    updating = false;
  }
}
function menu() {
  return Menu.buildFromTemplate([
    { label: "奶灰 · 你的桌面小伙伴", enabled: false },
    { label: "查看 AI 额度", click: showPanel },
    { type: "separator" },
    ...Object.entries({
      wave: "招招手",
      play: ball ? "收起毛线球" : "玩毛线球",
      type: "敲键盘",
      stretch: "伸懒腰",
      yawn: "打哈欠",
      walk: "走一走",
      music: "听音乐",
      sleep: "睡觉",
      idle: "叫醒",
    }).map(([a, label]) => ({ label, click: () => userAction(a) })),
    { type: "separator" },
    ...Object.entries({
      roaming: "自由走动",
      company: "陪我工作和听歌",
      routine: "跟随我的作息",
    }).map(([key, label]) => ({
      label,
      type: "checkbox",
      checked: prefs[key],
      click: () => setPreference(key, !prefs[key]),
    })),
    {
      label: "猫咪大小",
      submenu: [72, 100, 130, 140, 170].map((size) => ({
        label: `${size} px`,
        type: "radio",
        checked: prefs.catHeight === size,
        click: () => setPreference("catHeight", size),
      })),
    },
    {
      label: "提醒静音一小时",
      click: () => setPreference("mutedUntil", Date.now() + 3600000),
    },
    {
      label: "恢复提醒",
      click: () => {
        prefs.mutedUntil = 0;
        prefs.quietOverrideUntil = Date.now() + 3600000;
        save();
        all("state", snapshot());
      },
    },
    { label: "设置", click: showSettings },
    {
      label: "回到屏幕中央",
      click: () => {
        const a = screen.getPrimaryDisplay().workArea;
        pet.setPosition(
          Math.round(a.x + a.width / 2 - W / 2),
          Math.round(a.y + a.height / 2 - H / 2),
        );
        walkX = pet.getBounds().x;
      },
    },
    {
      label: updateRelease
        ? `安装 Windows ${updateRelease.version}`
        : "检查更新",
      click: () => checkUpdates(true),
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
  return [pet, panel, settingsWindow, ballWindow].some(
    (w) =>
      w &&
      !w.isDestroyed() &&
      e.sender === w.webContents &&
      e.senderFrame === w.webContents.mainFrame,
  );
}
function setPreference(key, value) {
  if (booleanPrefs.includes(key) && typeof value === "boolean")
    prefs[key] = value;
  else if (key === "catHeight" && [72, 100, 130, 140, 170].includes(value)) {
    prefs[key] = value;
    stopPlaying(true);
  } else if (
    ["mutedUntil", "quietOverrideUntil"].includes(key) &&
    Number.isFinite(value) &&
    value >= 0 &&
    value <= Date.now() + 86400000
  )
    prefs[key] = value;
  else if (
    ["quietStart", "quietEnd"].includes(key) &&
    Number.isInteger(value) &&
    value >= 0 &&
    value < 1440
  )
    prefs[key] = value;
  else if (
    key === "mutedProviders" &&
    Array.isArray(value) &&
    value.every((v) => ["codex", "claude"].includes(v))
  )
    prefs[key] = [...new Set(value)];
  else return;
  if (key === "startup" && process.platform === "win32")
    app.setLoginItemSettings({ openAtLogin: value });
  if (key === "claudeRenewal") service.setClaudeRenewalEnabled(value);
  save();
  tray?.setContextMenu(menu());
  all("state", snapshot());
}
async function scanSessions() {
  if (demo || smoke || sessionBusy || suspended || !prefs.providers.length)
    return;
  sessionBusy = true;
  const generation = sessionGeneration;
  try {
    const found = await reader.read(prefs.providers);
    if (generation !== sessionGeneration || quitting) return;
    sessions = found;
    service.setActive(sessions.some((s) => s.state === "busy"));
    reminders.accept(
      sessionRules.observe(sessions),
      service.snapshot(),
      sessions,
      reminderPrefs(),
    );
  } finally {
    sessionBusy = false;
  }
}
function tick() {
  if (!petReady || suspended) return;
  const now = Date.now(),
    oldOnce = JSON.stringify(prefs.onceState);
  applyCompanion(
    companion.tick({
      now,
      idleSeconds: powerMonitor.getSystemIdleTime(),
      senses: senses.snapshot(),
      prefs: { ...prefs, demo: smoke },
      phase,
      dragging: !!drag,
      playing: playState !== "off",
    }),
  );
  if (oldOnce !== JSON.stringify(prefs.onceState)) save();
  if (phase === "walk" && walkUntil && now >= walkUntil) {
    walkUntil = 0;
    present("action", "idle");
  }
  if (now - lastSessionScan >= 2000) {
    lastSessionScan = now;
    void scanSessions();
  }
  const inApp = phase === "idle" && !drag && playState === "off";
  const event = reminders.drain({
    usage: service.snapshot(),
    sessions,
    prefs: reminderPrefs(),
    canPresent: inApp || (prefs.notifications && Notification.isSupported()),
  });
  if (event) {
    if (inApp) {
      present("bubble", event.body);
      if (prefs.motion) present("action", "blink");
    } else if (prefs.notifications)
      new Notification({
        title: event.title,
        body: event.body,
        silent: !prefs.sound,
      }).show();
  }
  send(pet, "state", snapshot());
  if (panel.isVisible()) send(panel, "state", snapshot());
}
if (primary)
  app.whenReady().then(() => {
    load();
    companion = new Companion({ onceState: prefs.onceState });
    service = new QuotaService({ stateDirectory: app.getPath("userData") });
    service.setClaudeRenewalEnabled(prefs.claudeRenewal);
    senses = new NativeSenses({
      helperPath: app.isPackaged
        ? path.join(process.resourcesPath, "native", "Naigrey.Senses.exe")
        : path.join(__dirname, "../native/Naigrey.Senses.exe"),
    });
    reader = new SessionReader({
      processStart: (pid) => senses.processStart(pid),
      ignoredPids: () => cliPids,
    });
    updater = new Updater({
      currentVersion: app.getVersion(),
      allowPrerelease: true,
      directory: path.join(app.getPath("userData"), "updates"),
    });
    service.on("cli-process", ({ pid, active }) => {
      if (active) cliPids.add(pid);
      else cliPids.delete(pid);
    });
    service.on("change", () => {
      reminders.accept([], service.snapshot(), sessions, reminderPrefs());
      all("state", snapshot());
    });
    service.on("reminder", (r) => {
      reminders.accept([r], service.snapshot(), sessions, reminderPrefs());
    });
    service.on("renewal", (r) => {
      if (r.status === "failed")
        present("bubble", r.message || "Claude 登录续期未完成，请重新登录。");
    });
    const area = screen.getPrimaryDisplay().workArea;
    const position = clampPosition(
      prefs.position || {
        x: area.x + area.width - W - 30,
        y: area.y + area.height - H - 160,
      },
      { width: W, height: H },
      screen.getDisplayNearestPoint(prefs.position || { x: area.x, y: area.y })
        .workArea,
    );
    pet = windowFor("pet.html", {
      ...position,
      width: W,
      height: H,
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
    pet.once("ready-to-show", () => pet.showInactive());
    pet.on("move", () => {
      if (panel.isVisible()) repositionPanel();
      clearTimeout(timer);
      timer = setTimeout(() => {
        if (pet.isDestroyed()) return;
        const [x, y] = pet.getPosition();
        prefs.position = { x, y };
        save();
      }, 300);
    });
    pet.on("close", (e) => {
      if (!quitting) {
        e.preventDefault();
        pet.hide();
      }
    });
    screen.on("display-removed", () => {
      const b = pet.getBounds(),
        a = screen.getPrimaryDisplay().workArea,
        p = clampPosition(b, b, a);
      pet.setPosition(p.x, p.y);
      walkX = p.x;
      stopPlaying(true);
    });
    if (!smoke) {
      let icon = nativeImage.createFromPath(
        path.join(__dirname, "../assets/tray.png"),
      );
      if (icon.isEmpty())
        icon = nativeImage
          .createFromPath(path.join(__dirname, "../assets/cats.png"))
          .resize({ width: 32, height: 18 });
      tray = new Tray(icon);
      tray.setToolTip("奶灰桌宠");
      tray.setContextMenu(menu());
      tray.on("click", () => {
        pet.showInactive();
        showPanel();
      });
    }
    ipcMain.handle("bootstrap", (e) => (trusted(e) ? snapshot() : null));
    ipcMain.handle("command", async (e, name, value) => {
      if (!trusted(e)) return;
      const isPet = e.sender === pet.webContents,
        isBall = ballWindow && e.sender === ballWindow.webContents;
      if (name === "ready" && isPet) {
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
          "yawn",
          "walk",
          "music",
          "sleep",
        ].includes(value)
      ) {
        userAction(value);
        return;
      }
      if (
        name === "interaction" &&
        isPet &&
        ["wave", "sleep", "idle"].includes(value)
      ) {
        userAction(value);
        return;
      }
      if (name === "refresh" && !demo && Date.now() - lastRefresh >= 15000) {
        lastRefresh = Date.now();
        await service.refresh();
        return snapshot();
      }
      if (name === "connect" && ["codex", "claude"].includes(value) && !demo) {
        if (!prefs.providers.includes(value)) prefs.providers.push(value);
        sessionGeneration++;
        reader.clearCache();
        save();
        await service.connect(value);
        return snapshot();
      }
      if (
        name === "disconnect" &&
        ["codex", "claude"].includes(value) &&
        !demo
      ) {
        prefs.providers = prefs.providers.filter((p) => p !== value);
        sessionGeneration++;
        reader.clearCache();
        sessions = sessions.filter((s) => s.provider !== value);
        sessionRules.observe(sessions);
        reminders.clearProvider(value);
        save();
        service.disconnect(value);
        return snapshot();
      }
      if (name === "preference" && value) {
        setPreference(value.key, value.value);
        return snapshot();
      }
      if (name === "check-update") {
        void checkUpdates(true);
        return;
      }
      if (
        name === "phase" &&
        isPet &&
        [
          "idle",
          "wave",
          "yawn",
          "stretch",
          "play",
          "walk",
          "standUp",
          "sitDown",
          "type",
          "typeIn",
          "typeOut",
          "music",
          "musicIn",
          "musicOut",
          "lieDown",
          "sleep",
          "wake",
        ].includes(value)
      ) {
        phase = value;
        if (phase === "walk" && walkDuration) {
          walkUntil = Date.now() + walkDuration;
          walkDuration = 0;
        }
        if (phase === "idle") walkUntil = 0;
        walkX = ["walk", "standUp", "sitDown"].includes(phase)
          ? pet.getBounds().x
          : null;
        if (phase === "play" && playState === "swat") ballWindow?.hide();
        return;
      }
      if (
        name === "walk-step" &&
        isPet &&
        ["walk", "standUp", "sitDown"].includes(phase) &&
        !drag &&
        Number.isFinite(value) &&
        Math.abs(value) <= 8
      ) {
        const b = pet.getBounds(),
          a = screen.getDisplayMatching(b).workArea;
        const proposed = (walkX ?? b.x) + value;
        walkX = advanceWalk(walkX ?? b.x, value, b.width, a);
        if (
          phase === "walk" &&
          (proposed < a.x || proposed > a.x + a.width - b.width)
        ) {
          direction = proposed < a.x ? 1 : -1;
          send(pet, "state", snapshot());
        }
        const p = clampPosition({ x: walkX, y: b.y }, b, a);
        pet.setPosition(p.x, p.y);
        return;
      }
      if (name === "pointer" && isPet && typeof value === "boolean" && !drag) {
        pet.setIgnoreMouseEvents(!value, { forward: true });
        return;
      }
      if (name === "drag-start" && isPet) {
        companion.manual("drag");
        company = "none";
        stopPlaying();
        drag = {
          cursor: screen.getCursorScreenPoint(),
          bounds: pet.getBounds(),
        };
        pet.setIgnoreMouseEvents(false);
        return;
      }
      if (name === "drag-move" && isPet && drag) {
        const c = screen.getCursorScreenPoint(),
          p = clampPosition(
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
      if (name === "drag-end" && isPet) {
        drag = null;
        walkX = pet.getBounds().x;
        return;
      }
      if (
        isBall &&
        ball &&
        ["ball-grab", "ball-move", "ball-release"].includes(name)
      ) {
        const c = screen.getCursorScreenPoint(),
          t = Date.now() / 1000;
        if (name === "ball-grab") ball.grab(c.x, c.y, t);
        else if (ball.held && name === "ball-move") ball.drag(c.x, c.y, t);
        else if (ball.held) {
          ball.release(c.x, c.y, t);
          playEnergy = Math.min(1, playEnergy + 0.6);
          if (!["sleep", "lieDown"].includes(phase)) playState = "watch";
          playUntil = Date.now() + 400;
        }
        return;
      }
      if (
        name === "ball-hand-off" &&
        isPet &&
        ball &&
        playState === "swat" &&
        value &&
        [
          value.point?.x,
          value.point?.y,
          value.velocity?.x,
          value.velocity?.y,
        ].every(Number.isFinite) &&
        Math.abs(value.point.x) < W * 2 &&
        Math.abs(value.point.y) < H * 2
      ) {
        const b = pet.getBounds();
        ball.x = b.x + value.point.x;
        ball.y = Math.min(b.y + value.point.y, b.y + GROUND - ball.radius);
        const away = value.velocity.x >= 0 ? 1 : -1;
        ball.kick(
          away *
            Math.max(
              Math.min(Math.abs(value.velocity.x), 1400),
              260 + Math.random() * 120,
            ),
          0,
        );
        ballWindow?.showInactive();
        playState = "watch";
        playUntil = Date.now() + 800;
        return;
      }
      if (name === "smoke-result" && smoke && isPet) {
        console.log("NAIGREY_SMOKE " + JSON.stringify(value));
        app.exit(value?.ok ? 0 : 1);
      }
    });
    powerMonitor.on("lock-screen", () =>
      applyCompanion(companion.locked(Date.now(), prefs)),
    );
    powerMonitor.on("unlock-screen", () =>
      applyCompanion(companion.unlocked()),
    );
    powerMonitor.on("suspend", () => {
      suspended = true;
      service.stop();
      senses.stop();
      reader.clearCache();
      sessionGeneration++;
    });
    powerMonitor.on("resume", () => {
      suspended = false;
      if (!demo && !smoke) service.start();
      if (!smoke) senses.start();
      applyCompanion(companion.unlocked());
    });
    if (smoke)
      setTimeout(() => {
        console.error("Smoke test timeout");
        app.exit(1);
      }, 60000).unref();
    else {
      senses.start();
      tickTimer = setInterval(tick, 250);
      physicsTimer = setInterval(() => {
        stepBall();
        if (petReady && !suspended && Date.now() - lastPointerSend >= 32) {
          lastPointerSend = Date.now();
          send(pet, "state", { senses: pointerSenses() });
        }
      }, 1000 / 60);
      if (!demo) {
        for (const p of prefs.providers) void service.connect(p);
        service.start();
        void checkUpdates();
      }
    }
  });
app.on("second-instance", () => {
  pet?.showInactive();
  showPanel();
});
app.on("before-quit", () => {
  quitting = true;
  clearTimeout(timer);
  clearInterval(tickTimer);
  clearInterval(physicsTimer);
  sessionGeneration++;
  reader?.clearCache();
  senses?.stop();
  service?.stop();
  updater?.cancel();
});
app.on("window-all-closed", () => {
  if (quitting) app.quit();
});
