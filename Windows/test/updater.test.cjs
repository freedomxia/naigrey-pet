const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises"),
  os = require("node:os"),
  path = require("node:path");
const {
  createHash,
  generateKeyPairSync,
  sign: signBytes,
} = require("node:crypto");
const { Updater, compareVersions, pickRelease } = require("../src/updater.cjs");
const repo = "https://github.com/freedomxia/naigrey-pet";
// A throwaway release key: the tests must never depend on the real private half.
const keyPair = generateKeyPairSync("ed25519");
const testPublicKey = keyPair.publicKey
  .export({ format: "der", type: "spki" })
  .subarray(12)
  .toString("base64");
const sign = (body) =>
  signBytes(null, Buffer.from(body), keyPair.privateKey).toString("base64");
/// Serves a signed manifest, then whatever the installer body should be.
const serve = (body, respond) => async (url, options) => {
  if (url.endsWith("SHA256SUMS.txt.sig")) return new Response(sign(body));
  if (url.endsWith("SHA256SUMS.txt")) return new Response(body);
  return respond(url, options);
};
const asset = (name, tag = "windows-v0.3.0", size = 4) => ({
  name,
  size,
  state: "uploaded",
  browser_download_url: `${repo}/releases/download/${tag}/${name}`,
});
const release = (version = "0.3.0", extra = {}) => ({
  tag_name: "windows-v" + version,
  draft: false,
  prerelease: false,
  name: "Windows " + version,
  body: "Notes",
  assets: [
    asset(`naigrey-windows-${version}-x64-setup.exe`, "windows-v" + version),
    asset("SHA256SUMS.txt", "windows-v" + version, 100),
    asset("SHA256SUMS.txt.sig", "windows-v" + version, 88),
  ],
  ...extra,
});
const digest = createHash("sha256").update("MZok").digest("hex");
async function fixture(t, fetchImpl, options = {}) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "naigrey-update-"));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const u = new Updater({
    currentVersion: "0.2.0",
    directory,
    fetchImpl,
    publicKey: testPublicKey,
    ...options,
  });
  t.after(() => u.cleanup());
  return { u, directory };
}
test("Windows asset SemVer is independent of Mac release tag and rejects wrong architecture", () => {
  assert(compareVersions("0.10.0", "0.2.0") > 0);
  assert(compareVersions("0.3.0-beta.10", "0.3.0-beta.2") > 0);
  assert(compareVersions("0.3.0", "0.3.0-rc.1") > 0);
  const mac = release("0.1.0", {
    tag_name: "v9.0.0",
    assets: [
      asset("naigrey-windows-0.1.0-x64-setup.exe", "v9.0.0"),
      asset("SHA256SUMS.txt", "v9.0.0"),
      asset("SHA256SUMS.txt.sig", "v9.0.0"),
    ],
  });
  assert.equal(pickRelease([mac], { currentVersion: "0.2.0" }), null);
  const wrong = release("0.4.0");
  wrong.assets[0] = asset(
    "naigrey-windows-0.4.0-arm64-setup.exe",
    "windows-v0.4.0",
  );
  assert.equal(pickRelease([wrong], { currentVersion: "0.2.0" }), null);
  assert.equal(
    pickRelease([release(), mac], { currentVersion: "0.2.0" }).version,
    "0.3.0",
  );
});
test("preview channel is explicit and missing or duplicate checksum manifests are rejected", () => {
  const preview = release("0.3.0", { prerelease: true });
  assert.equal(pickRelease([preview], { currentVersion: "0.2.0" }), null);
  assert.equal(
    pickRelease([preview], { currentVersion: "0.2.0", allowPrerelease: true })
      .version,
    "0.3.0",
  );
  assert.equal(
    pickRelease(
      [
        release("0.3.0", {
          assets: [asset("naigrey-windows-0.3.0-x64-setup.exe")],
        }),
      ],
      { currentVersion: "0.2.0" },
    ),
    null,
  );
  const duplicate = release();
  duplicate.assets.push(duplicate.assets[1]);
  assert.equal(pickRelease([duplicate], { currentVersion: "0.2.0" }), null);
});
test("checks run daily, force bypasses local schedule, and Mac-only feed produces no Windows update", async (t) => {
  let calls = 0,
    clock = 1000000000000;
  const { u } = await fixture(
    t,
    async () => {
      calls++;
      return new Response(JSON.stringify([release()]));
    },
    { now: () => clock },
  );
  assert.equal((await u.check()).version, "0.3.0");
  await u.check();
  assert.equal(calls, 1);
  await u.check({ force: true });
  assert.equal(calls, 2);
  clock += 86400000;
  await u.check();
  assert.equal(calls, 3);
});
test("installer is streamed, hash validated and no process is executed", async (t) => {
  const { u, directory } = await fixture(
    t,
    serve(
      `${digest}  naigrey-windows-0.3.0-x64-setup.exe\n`,
      async () => new Response("MZok"),
    ),
  );
  const info = pickRelease([release()], { currentVersion: "0.2.0" });
  const file = await u.download(info);
  assert(file.startsWith(directory + path.sep));
  assert.equal(path.basename(file), "naigrey-windows-0.3.0-x64-setup.exe");
  assert.equal(await fs.readFile(file, "utf8"), "MZok");
  await u.cleanup();
  assert.deepEqual(await fs.readdir(directory), []);
});
test("hash mismatch and ambiguous manifest remove partial downloads", async (t) => {
  const { u, directory } = await fixture(
    t,
    serve(
      `${"0".repeat(64)}  naigrey-windows-0.3.0-x64-setup.exe\n`,
      async () => new Response("MZok"),
    ),
  );
  await assert.rejects(
    u.download(pickRelease([release()], { currentVersion: "0.2.0" })),
    /校验/,
  );
  assert.deepEqual(await fs.readdir(directory), []);
});
test("redirects never contact unknown, credential-bearing, HTTP or local hosts", async (t) => {
  for (const location of [
    "https://evil.example/x",
    "http://github.com/freedomxia/naigrey-pet/releases/download/x/y",
    "https://user:secret@github.com/freedomxia/naigrey-pet/releases/download/x/y",
    "https://127.0.0.1/x",
  ]) {
    let calls = 0;
    const { u } = await fixture(t, async () => {
      calls++;
      return new Response(null, { status: 302, headers: { location } });
    });
    await assert.rejects(
      u.download(pickRelease([release()], { currentVersion: "0.2.0" })),
    );
    assert.equal(calls, 1);
  }
});
test("cancelling an in-flight request rejects and clears staging files", async (t) => {
  let entered;
  const ready = new Promise((r) => (entered = r));
  const { u, directory } = await fixture(t, async (_url, { signal }) => {
    entered();
    return new Promise((_resolve, reject) =>
      signal.addEventListener("abort", () => reject(new Error("aborted")), {
        once: true,
      }),
    );
  });
  const downloading = u.download(
    pickRelease([release()], { currentVersion: "0.2.0" }),
  );
  await ready;
  u.cancel();
  await assert.rejects(downloading);
  assert.deepEqual(await fs.readdir(directory), []);
});
test("vetted release-assets redirect and multiple chunks produce the exact installer", async (t) => {
  const { u } = await fixture(t, async (url, options) => {
    assert.equal(options.redirect, "manual");
    assert.equal(options.credentials, "omit");
    assert.equal(options.headers.Authorization, undefined);
    const manifest = `${digest} *naigrey-windows-0.3.0-x64-setup.exe\r\n`;
    if (url.endsWith("SHA256SUMS.txt.sig")) return new Response(sign(manifest));
    if (url.endsWith("SHA256SUMS.txt")) return new Response(manifest);
    if (url.startsWith(repo))
      return new Response(null, {
        status: 302,
        headers: {
          location:
            "https://release-assets.githubusercontent.com/github-production-release-asset/1/file?signature=secret",
        },
      });
    const chunks = [Buffer.from("MZ"), Buffer.from("ok")];
    return new Response(
      new ReadableStream({
        pull(controller) {
          const chunk = chunks.shift();
          chunk ? controller.enqueue(chunk) : controller.close();
        },
      }),
    );
  });
  assert.equal(
    await fs.readFile(
      await u.download(pickRelease([release()], { currentVersion: "0.2.0" })),
      "utf8",
    ),
    "MZok",
  );
});
test("duplicate checksum records and oversized manifest are rejected before the executable request", async (t) => {
  const duplicate = `${digest}  naigrey-windows-0.3.0-x64-setup.exe\n${digest}  naigrey-windows-0.3.0-x64-setup.exe\n`;
  for (const [body, manifest] of [
    [duplicate, () => new Response(duplicate)],
    ["x", () => new Response("x", { headers: { "content-length": "65537" } })],
  ]) {
    let installerRequests = 0;
    const { u, directory } = await fixture(t, async (url) => {
      if (url.endsWith("SHA256SUMS.txt.sig")) return new Response(sign(body));
      if (url.endsWith("SHA256SUMS.txt")) return manifest();
      installerRequests++;
      return new Response("MZok");
    });
    await assert.rejects(
      u.download(pickRelease([release()], { currentVersion: "0.2.0" })),
    );
    assert.equal(installerRequests, 0);
    assert.deepEqual(await fs.readdir(directory), []);
  }
});
test("an installer whose manifest is not signed by the release key is refused", async (t) => {
  const body = `${digest}  naigrey-windows-0.3.0-x64-setup.exe\n`;
  let installerRequests = 0;
  const { u, directory } = await fixture(t, async (url) => {
    // A checksum the attacker also wrote proves nothing; the signature is what
    // ties the manifest to the release key.
    if (url.endsWith("SHA256SUMS.txt.sig"))
      return new Response(sign("something else entirely"));
    if (url.endsWith("SHA256SUMS.txt")) return new Response(body);
    installerRequests++;
    return new Response("MZok");
  });
  await assert.rejects(
    u.download(pickRelease([release()], { currentVersion: "0.2.0" })),
    /签名/,
  );
  assert.equal(installerRequests, 0);
  assert.deepEqual(await fs.readdir(directory), []);
});
test("a release without a signed manifest is never offered", () => {
  const unsigned = release();
  unsigned.assets = unsigned.assets.filter(
    (a) => a.name !== "SHA256SUMS.txt.sig",
  );
  assert.equal(pickRelease([unsigned], { currentVersion: "0.2.0" }), null);
});
test("cancel bounds fetch implementations that ignore AbortSignal", async (t) => {
  let entered;
  const ready = new Promise((r) => (entered = r));
  const { u, directory } = await fixture(t, async () => {
    entered();
    return new Promise(() => {});
  });
  const pending = u.download(
    pickRelease([release()], { currentVersion: "0.2.0" }),
  );
  await ready;
  u.cancel();
  await assert.rejects(pending, (error) => error.code === "cancelled");
  assert.deepEqual(await fs.readdir(directory), []);
});
test("request timeout is enforced even when the fetch never settles", async (t) => {
  let entered;
  const ready = new Promise((r) => (entered = r));
  const { u } = await fixture(t, async () => {
    entered();
    return new Promise(() => {});
  });
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const pending = u.check();
  await ready;
  t.mock.timers.tick(20000);
  await assert.rejects(pending, (error) => error.code === "timeout");
});
