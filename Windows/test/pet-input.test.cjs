const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs"),
  vm = require("node:vm");
function renderer() {
  let now = 0,
    id = 0;
  const timers = new Map(),
    handlers = {},
    commands = [];
  const ctx = new Proxy(
    { getImageData: () => ({ data: [0, 0, 0, 255] }) },
    { get: (o, k) => o[k] || (() => {}) },
  );
  const canvas = {
    getContext: () => ctx,
    addEventListener: (name, fn) => (handlers[name] = fn),
    setPointerCapture() {},
  };
  const element = {
    addEventListener() {},
    classList: { add() {}, remove() {} },
  };
  const context = vm.createContext({
    console,
    performance: { now: () => now },
    requestAnimationFrame() {},
    setTimeout: (fn, delay) => {
      timers.set(++id, { fn, at: now + delay });
      return id;
    },
    clearTimeout: (id) => timers.delete(id),
    document: {
      querySelector: (selector) => (selector === "#cat" ? canvas : element),
      createElement: () => canvas,
    },
    window: {
      naigrey: {
        on() {},
        bootstrap: () => new Promise(() => {}),
        command: (...v) => commands.push(v),
      },
      PetModel: require("../src/pet-model.cjs"),
      PetMotion: require("../src/pet-motion.cjs"),
    },
  });
  vm.runInContext(
    fs.readFileSync(require.resolve("../src/pet.js"), "utf8"),
    context,
  );
  return {
    commands,
    run: (code) => vm.runInContext(code, context),
    event: (name, extra = {}) =>
      handlers[name]({
        button: 0,
        clientX: 100,
        clientY: 100,
        screenX: 100,
        screenY: 100,
        pointerId: 1,
        ...extra,
      }),
    advance: (target) => {
      while (true) {
        const next = [...timers]
          .filter(([, v]) => v.at <= target)
          .sort((a, b) => a[1].at - b[1].at)[0];
        if (!next) break;
        now = next[1].at;
        timers.delete(next[0]);
        next[1].fn();
      }
      now = target;
    },
    interactions: () =>
      commands.filter((c) => c[0] === "interaction").map((c) => c[1]),
  };
}
test("default Windows double click at400ms emits only sleep, never an earlier wave", () => {
  const r = renderer();
  r.event("pointerdown");
  r.event("pointerup");
  r.advance(350);
  r.event("pointerdown");
  r.advance(400);
  r.event("pointerup");
  r.event("dblclick");
  r.advance(1000);
  assert.deepEqual(r.interactions(), ["sleep"]);
});
test("native accessibility double-click interval delays a single greet; drag cancels it", () => {
  const r = renderer();
  r.run("acceptState({senses:{doubleClickInterval:1200}})");
  r.event("pointerdown");
  r.event("pointerup");
  r.advance(600);
  assert.deepEqual(r.interactions(), []);
  r.advance(1200);
  assert.deepEqual(r.interactions(), ["wave"]);
  const d = renderer();
  d.event("pointerdown");
  d.event("pointerup");
  d.advance(100);
  d.event("pointerdown");
  d.event("pointermove", { screenX: 120 });
  d.advance(1000);
  d.event("pointerup");
  assert.deepEqual(d.interactions(), []);
});
test("turning off reminder motion keeps original idle rig and requested meow alive", async () => {
  const r = renderer();
  r.run(
    "ready=true;prefs={motion:false,systemCompanion:true};rigData={sizes:{idle:[466,463]},rigs:{idle:{width:546,height:543}}};motion={updates:0,meows:0,update(){this.updates++},meow(){this.meows++}};renderer={render(){return {}}};draw(16)",
  );
  assert.equal(r.run("motion.updates"), 1);
  await r.run("requestAction('meow')");
  assert.equal(r.run("motion.meows"), 1);
});
