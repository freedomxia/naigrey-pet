# Windows 更新下载器

`src/updater.cjs` 只检查和下载，不执行安装、不替换当前程序、不启动子进程。主进程收到用户明确点击后，再使用返回的已校验路径打开安装器。

```js
const { Updater } = require('./updater.cjs');
const updater = new Updater({
  currentVersion: app.getVersion(),
  directory: path.join(app.getPath('userData'), 'updates'),
  allowPrerelease: true, // 当前 Windows 预览渠道；正式渠道设为 false。
  // publicKey 默认为内置的发布公钥，与 Source/Updater.swift 的 Updater.publicKey 相同。
});
const release = await updater.check(); // 同一实例每天最多查询一次；返回缓存结果。
// 手动检查：await updater.check({force:true})
// 用户点击“下载安装”以后：
const installer = await updater.download(release);
// 主进程单独负责用户确认后的 shell.openPath(installer)。
// 取消或退出：updater.cancel(); await updater.cleanup();
```

`check()` 返回 null 或 `{version,tag,name,notes,url,prerelease,assetName,size,downloadURL,checksumURL,signatureURL}`。`download()` 返回本机安装包路径。`cancel()` 中止在途网络和流读取；`cleanup()` 等待取消完成，再删除本实例创建的临时目录，不清空调用方指定的整个目录。主进程安排每日检查定时器；模块本身不维持后台检查定时器。

## 发布约定与渠道

从固定仓库的 [GitHub Releases API](https://docs.github.com/en/rest/releases/releases) 读取最近最多 300 个发布。Windows 版本只来自完全匹配的 `naigrey-windows-<SemVer>-x64-setup.exe` 文件名，不把 Mac `v3.x` 标签当作 Windows 版本。忽略草稿、旧版本、其他架构、ZIP、缺少校验清单或同名重复资产的发布。

同一发布必须包含唯一 `SHA256SUMS.txt` 和唯一 `SHA256SUMS.txt.sig`，清单中对该安装包有且仅有一条标准 SHA-256 记录。支持 `hash  filename` 和 `hash *filename` 两种格式。安装包、清单和签名的初始 URL 必须精确指向 `github.com/freedomxia/naigrey-pet/releases/download/<tag>/<asset>`。缺少签名资产的发布不会被当作可用更新。

模块默认的正式渠道拒绝 GitHub `prerelease:true` 和带 SemVer 预发布后缀的安装包。Windows 当前使用预览渠道，主进程显式传 `allowPrerelease:true`——现有 Windows 发布在 GitHub 上标记为 prerelease，关掉就收不到更新提示。不因 Windows 包描述包含“预览”自动改变渠道。

## 网络、磁盘与取消边界

- 仅 HTTPS，无 Cookie、无认证令牌，禁用自动跳转与缓存。手动逐跳验证，最多 5 次重定向。
- 下载只允许本仓库 GitHub release 路径以及精确主机名 `release-assets.githubusercontent.com`、`objects.githubusercontent.com`；拒绝任意子域、HTTP、非标准端口、用户名密码 URL 和本地地址。API 仅允许固定仓库 releases 路径。
- 检查总超时 20 秒；下载总超时 300 秒。检查每页响应最多 2 MiB、最多 3 页；清单最多 64 KiB；安装包最多 512 MiB，并须与 GitHub 资产大小一致。
- 先取清单和签名（清单最多 64 KiB，签名最多 4 KiB），验签不通过就直接失败，此时还没有向安装包地址发过任何请求。
- 下载分块写入独立临时目录中的 `installer.part`，同时计算 SHA-256。大小和哈希均通过后才重命名为安装包名称；异常、取消、校验失败都删除本次暂存文件。不缓存授权 URL 到设置或日志。
- 即使测试替身忽略 AbortSignal，取消和超时也能结束当前操作。并发检查合并；同时只能下载一个安装包。

## 发布者签名

`SHA256SUMS.txt` 用 Ed25519 签名，公钥内置在 `updater.cjs`，与 `Source/Updater.swift` 的 `Updater.publicKey` 是同一把。验签通过后才采信清单里的哈希，再用它校验安装包——安装包上限 512 MiB，Node 没有流式验签接口，所以签名覆盖清单而不是安装包本体；安全性等价，因为安装包的哈希只有这一个来源。

私钥不进 CI。发布时在发布机上生成规范化清单（LF、无 BOM、两个空格）并签名：

```sh
printf '%s  %s\n' <sha256> naigrey-windows-<版本>-x64-setup.exe > SHA256SUMS.txt
relkey sign ~/.naigrey/release-key SHA256SUMS.txt
```

把输出的 base64 作为 `publish-windows.yml` 的 `manifest_signature` 输入。该 workflow 会重新生成同样的规范化清单、用同一个 `verifyManifest` 复验，通过后才上传清单和 `.sig`。

Mac `Updater.swift` 的 app bundle 替换机制仍然没有被宣称为 Windows 已有能力。Windows 分发 NSIS 安装包，安装由用户触发，代码签名证书状态应在发布说明中明确——发布者签名验证的是更新来源，不等于 Windows 代码签名证书。

测试使用合成 GitHub 响应和临时目录，不下载真实安装器、不执行任何程序。真实 GitHub 重定向下载和 Windows 安装流程由集成验收单独确认。
