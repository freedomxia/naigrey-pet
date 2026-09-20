"use strict";
// Windows release channel is selected from installer assets, never Mac tag versions.
// This module downloads and validates only. It never launches or installs anything.
const fs = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");
const { createHash, timingSafeEqual } = require("node:crypto");
const REPO = "https://github.com/freedomxia/naigrey-pet";
const API = "https://api.github.com/repos/freedomxia/naigrey-pet/releases";
const DAY = 86400000,
  MAX_INSTALLER = 512 * 1024 * 1024;
class UpdateError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "UpdateError";
    this.code = code;
  }
}
const failure = (code) =>
  new UpdateError(
    code,
    {
      network: "无法连接更新服务器，请稍后重试。",
      feed: "更新信息不完整，请稍后重试。",
      origin: "更新下载地址不受信任。",
      size: "更新文件大小超出限制或下载不完整。",
      checksum: "安装包 SHA-256 校验失败，已删除下载文件。",
      cancelled: "更新操作已取消。",
      timeout: "更新请求超时，请稍后重试。",
      busy: "另一个安装包正在下载。",
    }[code] || "更新操作未完成。",
  );
function semver(value) {
  if (typeof value !== "string" || value.length > 100) return null;
  const m =
    /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/.exec(
      value,
    );
  if (!m) return null;
  const core = m.slice(1, 4).map(Number),
    pre = m[4]?.split(".") || [];
  if (
    core.some((n) => !Number.isSafeInteger(n)) ||
    pre.some((v) => /^\d+$/.test(v) && v.length > 1 && v[0] === "0")
  )
    return null;
  return { core, pre };
}
function compareVersions(a, b) {
  const x = semver(a),
    y = semver(b);
  if (!x || !y) throw failure("feed");
  for (let i = 0; i < 3; i++)
    if (x.core[i] !== y.core[i]) return x.core[i] > y.core[i] ? 1 : -1;
  if (!x.pre.length || !y.pre.length)
    return x.pre.length === y.pre.length ? 0 : x.pre.length ? -1 : 1;
  for (let i = 0; i < Math.max(x.pre.length, y.pre.length); i++) {
    if (x.pre[i] === undefined) return -1;
    if (y.pre[i] === undefined) return 1;
    const l = x.pre[i],
      r = y.pre[i];
    if (l === r) continue;
    const ln = /^\d+$/.test(l),
      rn = /^\d+$/.test(r);
    if (ln && rn) return BigInt(l) > BigInt(r) ? 1 : -1;
    if (ln !== rn) return ln ? -1 : 1;
    return l > r ? 1 : -1;
  }
  return 0;
}
function assetVersion(name) {
  if (typeof name !== "string") return null;
  const match = /^naigrey-windows-(.+)-x64-setup\.exe$/.exec(name);
  return match && semver(match[1]) ? match[1] : null;
}
function officialAsset(tag, name, value) {
  if (
    typeof tag !== "string" ||
    !/^[0-9A-Za-z][0-9A-Za-z._+-]{0,120}$/.test(tag)
  )
    return false;
  try {
    const url = new URL(value);
    return (
      url.origin === new URL(REPO).origin &&
      !url.username &&
      !url.password &&
      !url.search &&
      !url.hash &&
      decodeURIComponent(url.pathname) ===
        `/freedomxia/naigrey-pet/releases/download/${tag}/${name}`
    );
  } catch {
    return false;
  }
}
function pickRelease(releases, { currentVersion, allowPrerelease = false }) {
  if (!semver(currentVersion) || !Array.isArray(releases))
    throw failure("feed");
  const candidates = [];
  for (const release of releases) {
    if (
      !release ||
      release.draft ||
      (release.prerelease && !allowPrerelease) ||
      !Array.isArray(release.assets)
    )
      continue;
    const manifests = release.assets.filter(
      (a) => a?.name === "SHA256SUMS.txt",
    );
    if (
      manifests.length !== 1 ||
      !officialAsset(
        release.tag_name,
        manifests[0].name,
        manifests[0].browser_download_url,
      )
    )
      continue;
    for (const a of release.assets) {
      const version = assetVersion(a?.name);
      if (
        !version ||
        compareVersions(version, currentVersion) <= 0 ||
        (semver(version).pre.length && !allowPrerelease)
      )
        continue;
      if (
        release.assets.filter((other) => other?.name === a.name).length !== 1 ||
        (a.state && a.state !== "uploaded")
      )
        continue;
      if (
        !Number.isSafeInteger(a.size) ||
        a.size <= 0 ||
        a.size > MAX_INSTALLER ||
        !officialAsset(release.tag_name, a.name, a.browser_download_url)
      )
        continue;
      candidates.push({
        version,
        tag: release.tag_name,
        name:
          typeof release.name === "string"
            ? release.name.slice(0, 200)
            : `Windows ${version}`,
        notes:
          typeof release.body === "string" ? release.body.slice(0, 4000) : "",
        url: `${REPO}/releases/tag/${encodeURIComponent(release.tag_name)}`,
        prerelease:
          release.prerelease === true || semver(version).pre.length > 0,
        assetName: a.name,
        size: a.size,
        downloadURL: a.browser_download_url,
        checksumURL: manifests[0].browser_download_url,
      });
    }
  }
  candidates.sort((a, b) => compareVersions(b.version, a.version));
  return candidates[0] || null;
}
function abortable(promise, signal) {
  if (signal.aborted)
    return Promise.reject(signal.reason || failure("cancelled"));
  return new Promise((resolve, reject) => {
    const abort = () => reject(signal.reason || failure("cancelled"));
    signal.addEventListener("abort", abort, { once: true });
    Promise.resolve(promise).then(
      (value) => {
        signal.removeEventListener("abort", abort);
        signal.aborted ? abort() : resolve(value);
      },
      (error) => {
        signal.removeEventListener("abort", abort);
        reject(error);
      },
    );
  });
}
function redirectAllowed(value, kind) {
  try {
    const url = new URL(value);
    if (
      url.protocol !== "https:" ||
      url.port ||
      url.username ||
      url.password ||
      url.hash
    )
      return false;
    if (kind === "feed")
      return (
        url.origin === "https://api.github.com" &&
        url.pathname === "/repos/freedomxia/naigrey-pet/releases"
      );
    if (url.hostname === "github.com")
      return url.pathname.startsWith(
        "/freedomxia/naigrey-pet/releases/download/",
      );
    return [
      "release-assets.githubusercontent.com",
      "objects.githubusercontent.com",
    ].includes(url.hostname);
  } catch {
    return false;
  }
}
function checksumFor(text, name) {
  const matches = [];
  for (const line of text.replace(/^\uFEFF/, "").split(/\r?\n/)) {
    const m = /^([a-fA-F0-9]{64})[ \t]+\*?([^\r\n]+)$/.exec(line);
    if (m && m[2] === name) matches.push(m[1].toLowerCase());
  }
  if (matches.length !== 1) throw failure("checksum");
  return matches[0];
}
class Updater {
  constructor({
    currentVersion,
    fetchImpl = globalThis.fetch,
    directory = path.join(os.tmpdir(), "naigrey-updates"),
    allowPrerelease = false,
    now = Date.now,
  } = {}) {
    if (!semver(currentVersion)) throw failure("feed");
    Object.assign(this, {
      currentVersion,
      fetchImpl,
      directory,
      allowPrerelease,
      now,
    });
    this.controllers = new Set();
    this.owned = new Set();
    this.lastCheck = null;
    this.cached = null;
    this.pendingCheck = null;
    this.pendingDownload = null;
  }
  async operation(timeout, task) {
    const controller = new AbortController();
    this.controllers.add(controller);
    const timer = setTimeout(
      () => controller.abort(failure("timeout")),
      timeout,
    );
    timer.unref?.();
    try {
      return await task(controller.signal);
    } catch (error) {
      throw controller.signal.aborted
        ? controller.signal.reason
        : error instanceof UpdateError
          ? error
          : failure("network");
    } finally {
      clearTimeout(timer);
      this.controllers.delete(controller);
    }
  }
  async request(input, kind, signal) {
    let url = input;
    for (let redirects = 0; redirects <= 5; redirects++) {
      signal.throwIfAborted();
      if (!redirectAllowed(url, kind)) throw failure("origin");
      const response = await abortable(
        Promise.resolve().then(() =>
          this.fetchImpl(url, {
            method: "GET",
            redirect: "manual",
            signal,
            cache: "no-store",
            credentials: "omit",
            headers: {
              Accept:
                kind === "feed"
                  ? "application/vnd.github+json"
                  : "application/octet-stream",
              "User-Agent": "Naigrey-Windows-Updater",
              "Cache-Control": "no-cache",
            },
          }),
        ),
        signal,
      );
      if ([301, 302, 303, 307, 308].includes(response.status)) {
        void response.body?.cancel().catch(() => {});
        const location = response.headers.get("location");
        if (!location || redirects === 5) throw failure("origin");
        try {
          url = new URL(location, url).href;
        } catch {
          throw failure("origin");
        }
        continue;
      }
      if (response.status !== 200) {
        void response.body?.cancel().catch(() => {});
        throw failure("network");
      }
      return response;
    }
    throw failure("origin");
  }
  async consume(response, limit, signal, onChunk) {
    const declared = Number(response.headers.get("content-length"));
    if (declared > limit) {
      void response.body?.cancel().catch(() => {});
      throw failure("size");
    }
    if (!response.body) throw failure("feed");
    const reader = response.body.getReader();
    let bytes = 0;
    try {
      for (;;) {
        const { done, value } = await abortable(reader.read(), signal);
        if (done) break;
        bytes += value.byteLength;
        if (bytes > limit) throw failure("size");
        await onChunk(Buffer.from(value));
        signal.throwIfAborted();
      }
    } finally {
      void reader.cancel().catch(() => {});
      try {
        reader.releaseLock();
      } catch {}
    }
    return bytes;
  }
  async text(url, kind, limit, signal) {
    const chunks = [];
    await this.consume(
      await this.request(url, kind, signal),
      limit,
      signal,
      (chunk) => chunks.push(chunk),
    );
    return Buffer.concat(chunks).toString("utf8");
  }
  check({ force = false } = {}) {
    if (this.pendingCheck) return this.pendingCheck;
    if (!force && this.lastCheck !== null && this.now() - this.lastCheck < DAY)
      return Promise.resolve(structuredClone(this.cached));
    this.lastCheck = this.now();
    const task = this.operation(20000, async (signal) => {
      const releases = [];
      for (let page = 1; page <= 3; page++) {
        let batch;
        try {
          batch = JSON.parse(
            await this.text(
              `${API}?per_page=100&page=${page}`,
              "feed",
              2 * 1024 * 1024,
              signal,
            ),
          );
        } catch (error) {
          if (error instanceof UpdateError) throw error;
          throw failure("feed");
        }
        if (!Array.isArray(batch)) throw failure("feed");
        releases.push(...batch.slice(0, 100));
        if (batch.length < 100) break;
      }
      this.cached = pickRelease(releases, this);
      return structuredClone(this.cached);
    }).finally(() => {
      if (this.pendingCheck === task) this.pendingCheck = null;
    });
    this.pendingCheck = task;
    return task;
  }
  download(release) {
    if (this.pendingDownload) return Promise.reject(failure("busy"));
    const valid =
      release &&
      assetVersion(release.assetName) === release.version &&
      semver(release.version) &&
      compareVersions(release.version, this.currentVersion) > 0 &&
      ((!release.prerelease && !semver(release.version).pre.length) ||
        this.allowPrerelease) &&
      Number.isSafeInteger(release.size) &&
      release.size > 0 &&
      release.size <= MAX_INSTALLER &&
      officialAsset(release.tag, release.assetName, release.downloadURL) &&
      officialAsset(release.tag, "SHA256SUMS.txt", release.checksumURL);
    if (!valid) return Promise.reject(failure("feed"));
    const info = { ...release };
    const task = this.operation(300000, async (signal) => {
      let scratch,
        handle,
        success = false;
      try {
        await fs.mkdir(this.directory, { recursive: true });
        signal.throwIfAborted();
        scratch = await fs.mkdtemp(
          path.join(this.directory, "naigrey-update-"),
        );
        this.owned.add(scratch);
        signal.throwIfAborted();
        const checksum = checksumFor(
          await this.text(info.checksumURL, "asset", 65536, signal),
          info.assetName,
        );
        const partial = path.join(scratch, "installer.part"),
          destination = path.join(scratch, info.assetName),
          hash = createHash("sha256");
        handle = await fs.open(partial, "wx", 0o600);
        signal.throwIfAborted();
        const response = await this.request(info.downloadURL, "asset", signal);
        const bytes = await this.consume(
          response,
          Math.min(MAX_INSTALLER, info.size),
          signal,
          async (chunk) => {
            hash.update(chunk);
            await handle.writeFile(chunk);
          },
        );
        if (
          bytes !== info.size ||
          !timingSafeEqual(hash.digest(), Buffer.from(checksum, "hex"))
        )
          throw failure("checksum");
        await handle.sync();
        await handle.close();
        handle = null;
        signal.throwIfAborted();
        await fs.rename(partial, destination);
        signal.throwIfAborted();
        success = true;
        return destination;
      } finally {
        await handle?.close().catch(() => {});
        if (scratch && !success) {
          await fs
            .rm(scratch, { recursive: true, force: true })
            .catch(() => {});
          this.owned.delete(scratch);
        }
      }
    }).finally(() => {
      if (this.pendingDownload === task) this.pendingDownload = null;
    });
    this.pendingDownload = task;
    return task;
  }
  cancel() {
    for (const c of this.controllers) c.abort(failure("cancelled"));
  }
  async cleanup() {
    this.cancel();
    await Promise.allSettled([this.pendingCheck, this.pendingDownload]);
    for (const dir of this.owned) {
      await fs.rm(dir, { recursive: true, force: true }).catch(() => {});
      this.owned.delete(dir);
    }
  }
}
module.exports = { Updater, UpdateError, pickRelease, compareVersions };
