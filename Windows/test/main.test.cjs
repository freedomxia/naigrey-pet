"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs"),
  os = require("node:os"),
  path = require("node:path"),
  vm = require("node:vm");
const { EventEmitter } = require("node:events"),
  { createRequire } = require("node:module");
const mainFile = require.resolve("../src/main.cjs"),
  realRequire = createRequire(mainFile);
async function harness(t) {
  const directory = fs.mkdtempSync(
      path.join(os.tmpdir(), "naigrey-main-test-"),
    ),
    paths = { temp: directory, userData: path.join(directory, "state") },
    handlers = {},
    windows = [],
    events = [];
  let now = Date.now(),
    cursor = { x: 300, y: 200 };
  const area = { x: 0, y: 0, width: 1920, height: 1080 };
  class Window extends EventEmitter {
    constructor(options) {
      super();
      this.options = options;
      this.bounds = {
        x: options.x || 0,
        y: options.y || 0,
        width: options.width,
        height: options.height,
      };
      this.destroyed = false;
      this.visible = false;
      this.webContents = new EventEmitter();
      Object.assign(this.webContents, {
        mainFrame: {},
        isDestroyed: () => this.destroyed,
        send: (...message) =>
          events.push({
            window: this,
            ...JSON.parse(JSON.stringify({ message })),
          }),
        setWindowOpenHandler() {},
      });
      windows.push(this);
    }
    loadFile(file) {
      this.file = file;
      return Promise.resolve();
    }
    isDestroyed() {
      return this.destroyed;
    }
    getBounds() {
      return { ...this.bounds };
    }
    getPosition() {
      return [this.bounds.x, this.bounds.y];
    }
    setPosition(x, y) {
      this.bounds.x = x;
      this.bounds.y = y;
    }
    setIgnoreMouseEvents(ignore) {
      this.ignoresMouse = ignore;
    }
    showInactive() {
      this.visible = true;
    }
    show() {
      this.visible = true;
    }
    hide() {
      this.visible = false;
    }
    isVisible() {
      return this.visible;
    }
    focus() {}
    close() {
      this.destroyed = true;
      this.emit("closed");
    }
  }
  const app = new EventEmitter();
  Object.assign(app, {
    setName() {},
    setAppUserModelId() {},
    requestSingleInstanceLock: () => true,
    whenReady: () => Promise.resolve(),
    setPath: (key, value) => (paths[key] = value),
    getPath: (key) => paths[key] || directory,
    getVersion: () => "0.2.0",
    quit() {},
    exit() {},
    isPackaged: false,
  });
  const screen = new EventEmitter();
  Object.assign(screen, {
    getCursorScreenPoint: () => cursor,
    getPrimaryDisplay: () => ({ workArea: area }),
    getDisplayMatching: () => ({ workArea: area }),
    getDisplayNearestPoint: () => ({ workArea: area }),
  });
  const powerMonitor = new EventEmitter();
  powerMonitor.getSystemIdleTime = () => 0;
  const electron = {
    app,
    screen,
    powerMonitor,
    BrowserWindow: Window,
    ipcMain: { handle: (name, fn) => (handlers[name] = fn) },
    Notification: { isSupported: () => false },
    Menu: {
      buildFromTemplate: (items) => ({ items, popup() {} }),
      setApplicationMenu() {},
    },
    shell: {},
    dialog: {},
  };
  class Clock extends Date {
    constructor(...args) {
      super(...(args.length ? args : [now]));
    }
    static now() {
      return now;
    }
  }
  const context = vm.createContext({
    require: (name) => (name === "electron" ? electron : realRequire(name)),
    __dirname: path.dirname(mainFile),
    process: {
      ...process,
      argv: ["electron", "test", "--smoke-test", "--demo"],
    },
    console,
    Date: Clock,
    setTimeout: () => ({ unref() {} }),
    clearTimeout() {},
    setInterval: () => ({}),
    clearInterval() {},
  });
  vm.runInContext(fs.readFileSync(mainFile, "utf8"), context, {
    filename: mainFile,
  });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(
    windows.length,
    2,
    "actual app initialization creates pet and panel",
  );
  const pet = windows[0],
    event = { sender: pet.webContents, senderFrame: pet.webContents.mainFrame };
  const command = (name, value, e = event) => handlers.command(e, name, value);
  await command("ready");
  pet.setPosition(0, 0);
  events.length = 0;
  t.after(() => {
    app.emit("before-quit");
    fs.rmSync(directory, { recursive: true, force: true });
  });
  return {
    context,
    command,
    events,
    pet,
    powerMonitor,
    run: (code) => vm.runInContext(code, context),
    advance: (ms) => (now += ms),
    setCursor: (p) => (cursor = p),
    bootstrap: () => handlers.bootstrap(event),
    directory,
  };
}
test("actual main initializes with isolated state and rejects untrusted IPC", async (t) => {
  const h = await harness(t);
  assert.ok(h.run("app.getPath('userData').startsWith(app.getPath('temp'))"));
  await h.command("interaction", "sleep", { sender: {}, senderFrame: {} });
  assert.equal(h.events.length, 0);
  assert.equal(h.bootstrap().prefs.providers.length, 0);
});
test("renderer interaction informs manual sleep and clears company before action", async (t) => {
  const h = await harness(t);
  h.run("company='typing';companion.company='typing'");
  await h.command("interaction", "sleep");
  assert.equal(h.run("companion.sleeping"), true);
  assert.equal(h.run("companion.autoSlept"), false);
  const messages = h.events.map((e) => e.message);
  const action = messages.findIndex((m) => m[0] === "action");
  assert.deepEqual(messages[action], ["action", "sleep"]);
  assert.equal(messages[action - 1][0], "state");
  assert.equal(messages[action - 1][1].company, "none");
  // The Mac says 呼噜… z Z when you put it to sleep from the menu.
  assert.deepEqual(messages.at(-1), ["bubble", { text: "呼噜… z Z" }]);
});
test("the tray menu matches the Mac's entries and reflects sleep and update state", async (t) => {
  const h = await harness(t);
  const labels = () => h.run("menu().items").map((i) => i.label);
  const initial = labels();
  assert.ok(initial.includes("让奶灰睡觉"));
  assert.ok(!initial.includes("叫醒奶灰"));
  // The Mac has no menu entry for typing or listening to music.
  assert.ok(!initial.includes("敲键盘"));
  assert.ok(!initial.includes("听音乐"));
  assert.ok(initial.includes("刷新 AI 额度"));
  assert.ok(initial.includes("把奶灰叫回来"));
  assert.ok(
    initial.includes("单击招手 · 双击睡觉 · 拖动搬家 · 头上划一划是撸猫"),
  );
  assert.deepEqual(
    h
      .run("menu().items")
      .find((i) => i.label === "猫咪大小")
      .submenu.map(({ label, checked }) => ({ label, checked })),
    ["迷你", "小巧", "标准", "大只"].map((label) => ({
      label,
      checked: label === "小巧",
    })),
  );
  await h.command("phase", "lieDown");
  assert.ok(labels().includes("叫醒奶灰"));
  h.run("updating=true");
  assert.ok(labels().includes("正在检查更新…"));
  assert.equal(
    h.run("menu().items").find((i) => i.label === "正在检查更新…").enabled,
    false,
  );
});
test("preview shows a sample bubble without touching any account", async (t) => {
  const h = await harness(t);
  await h.command("preview");
  assert.deepEqual(h.events.at(-1).message, [
    "bubble",
    { text: "剩余 20%，58 分钟后重置。", seconds: 6 },
  ]);
});
test("a live ball is gazed at without counting as fixation or as petting", async (t) => {
  const h = await harness(t);
  // Still rolling with the game off: the eyes follow it, but this is neither a
  // game in progress nor a hand on the cat's head.
  h.run(
    "ball={x:900,y:400,radius:12,held:false,isResting:false,snapshot:()=>({})};playState='off'",
  );
  const rolling = h.run("pointerSenses()");
  assert.equal(rolling.gazing, true);
  assert.equal(rolling.fixated, false);
  assert.equal(rolling.pointer.x, 900 - h.run("pet.getBounds().x"));
  h.run("playState='watch'");
  assert.equal(h.run("pointerSenses()").fixated, true);
  h.run("ball=null;playState='off'");
  const free = h.run("pointerSenses()");
  assert.equal(free.gazing, false);
  assert.equal(free.fixated, false);
});
test("queued walk starts deadline at walk phase and repeated edge messages preserve direction", async (t) => {
  const h = await harness(t);
  h.run("act('walk',{manual:true,duration:9000})");
  await h.command("phase", "idle");
  await h.command("phase", "standUp");
  h.advance(5500);
  await h.command("phase", "walk");
  assert.equal(h.run("walkUntil-Date.now()"), 9000);
  // Park the cat where its silhouette meets the left edge. The window reaches
  // past it, because the window's sides are transparent.
  h.run(
    "(() => { const a = roamArea(screen.getPrimaryDisplay().workArea); pet.setPosition(a.x, 0); walkX = a.x; })()",
  );
  await h.command("walk-step", -2);
  await h.command("walk-step", -2);
  assert.equal(h.bootstrap().direction, 1);
  h.advance(9001);
  h.run("tick()");
  assert.ok(
    h.events.some((e) => e.message[0] === "action" && e.message[1] === "idle"),
  );
});
test("ball uses exact clip reach, moves away when too close, and clamps handoff above floor", async (t) => {
  const h = await harness(t);
  h.run(
    "phase='idle';ball=new YarnBall({radius:18,x:CX+30,y:GROUND-18});playState='watch';playUntil=0;lastPhysics=Date.now();stepBall()",
  );
  assert.equal(h.run("playState"), "windup");
  h.run(
    "ball=new YarnBall({radius:18,x:CX+10,y:GROUND-18});playState='watch';playUntil=0;stepBall()",
  );
  assert.equal(h.run("playState"), "chase");
  assert.equal(h.bootstrap().direction, -1);
  h.run("playState='swat'");
  await h.command("ball-hand-off", {
    point: { x: 350, y: 400 },
    velocity: { x: 20, y: 0 },
  });
  const ball = h.bootstrap().ball;
  assert.equal(ball.y, 289);
  assert.equal(ball.held, false);
  assert.ok(ball.speed >= 260);
});
test("stopping play retains a resting ball; explicit toggle removes its window", async (t) => {
  const h = await harness(t);
  await h.command("action", "play");
  assert.ok(h.bootstrap().ball);
  h.run("stopPlaying()");
  assert.ok(h.bootstrap().ball);
  assert.equal(h.run("playState"), "off");
  await h.command("action", "play");
  assert.equal(h.bootstrap().ball, undefined);
});
test("suspend and resume discard pending presentation and old session evidence", async (t) => {
  const h = await harness(t);
  h.run(
    "sessions=[{provider:'codex',id:'old',state:'waiting',evidence:'explicit'}];reminders.accept([{provider:'codex',kind:'waiting',sessionID:'old',body:'waiting'}],[],sessions,{})",
  );
  assert.equal(h.bootstrap().reminders.history.length, 1);
  h.powerMonitor.emit("suspend");
  assert.equal(h.run("suspended"), true);
  assert.equal(h.bootstrap().sessions.length, 0);
  assert.equal(
    h.run(
      "reminders.drain({sessions:[{provider:'codex',id:'old',state:'waiting',evidence:'explicit'}],canPresent:true})",
    ),
    null,
  );
  assert.equal(h.bootstrap().reminders.history.length, 1);
  h.powerMonitor.emit("resume");
  assert.equal(h.run("suspended"), false);
  assert.equal(h.bootstrap().sessions.length, 0);
  assert.equal(
    h.run(
      "reminders.drain({sessions:[{provider:'codex',id:'old',state:'waiting',evidence:'explicit'}],canPresent:true})",
    ),
    null,
  );
});
test("visible settings receive session and sensor changes without a quota event", async (t) => {
  const h = await harness(t);
  await h.command("settings");
  h.run(
    'settingsWindow.show();sessions=[{provider:"codex",id:"active",state:"busy",evidence:"explicit"}]',
  );
  h.events.length = 0;
  h.run("tick()");
  assert.ok(
    h.events.some(
      (e) =>
        e.window.file.endsWith("settings.html") &&
        e.message[0] === "state" &&
        e.message[1].sessions[0]?.state === "busy",
    ),
  );
});
