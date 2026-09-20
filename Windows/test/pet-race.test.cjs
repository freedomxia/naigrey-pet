const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs"),
  vm = require("node:vm"),
  { EventEmitter } = require("node:events");
const flush = () => new Promise((resolve) => setImmediate(resolve));
class Video extends EventEmitter {
  constructor(readyState) {
    super();
    this.readyState = readyState;
  }
  addEventListener(name, fn) {
    this.on(name, fn);
  }
  removeEventListener(name, fn) {
    this.off(name, fn);
  }
  load() {}
  pause() {}
  play() {
    return Promise.resolve();
  }
  fail() {
    this.emit("error");
  }
}
test("cancelled decoder failure cannot clear a newer active action or emit stale idle/error", async () => {
  const events = [],
    timers = new Set(),
    surface = {
      getContext: () => ({ drawImage() {} }),
      addEventListener() {},
      classList: { add() {}, remove() {} },
    };
  const bad = new Video(0),
    good = new Video(2);
  const context = vm.createContext({
    console,
    performance: { now: () => 0 },
    setTimeout: (fn, ms) => {
      const t = setTimeout(fn, ms);
      timers.add(t);
      return t;
    },
    clearTimeout: (t) => {
      clearTimeout(t);
      timers.delete(t);
    },
    document: { querySelector: () => surface, createElement: () => surface },
    window: {
      naigrey: {
        on() {},
        bootstrap: () => new Promise(() => {}),
        command: (...x) => events.push(x),
      },
      PetModel: {
        actionPath: (_, a) => [a],
        IdleCompanion: class {
          interact() {}
        },
      },
    },
    bad,
    good,
  });
  try {
    vm.runInContext(
      fs.readFileSync(require.resolve("../src/pet.js"), "utf8"),
      context,
    );
    vm.runInContext(
      "ready=true;videos.set('bad',bad);videos.set('good',good);clips.set('bad',{});clips.set('good',{});requestAction('bad');cancelAction();requestAction('good');",
      context,
    );
    await flush();
    assert.equal(vm.runInContext("active?.name", context), "good");
    bad.fail();
    await flush();
    assert.equal(vm.runInContext("active?.name", context), "good");
    assert.deepEqual(
      events.filter((x) => x[0] === "phase"),
      [
        ["phase", "idle"],
        ["phase", "good"],
      ],
    );
  } finally {
    for (const t of timers) clearTimeout(t);
  }
});
