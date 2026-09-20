# Windows 更新下载器

`src/updater.cjs` 只检查和下载，不执行安装、不替换当前程序、不启动子进程。主进程收到用户明确点击后，再使用返回的已校验路径打开安装器。

```js
const { Updater } = require('./updater.cjs');
const updater = new Updater({
  currentVersion: app.getVersion(),
  directory: path.join(app.getPath('userData'), 'updates'),
  allowPrerelease: true, // 当前 Windows 预览渠道；正式渠道设为 false。
});
const release = await updater.check(); // 同一实例每天最多查询一次；返回缓存结果。
// 手动检查：await updater.check({force:true})
// 用户点击“下载安装”以后：
const installer = await updater.download(release);
// 主进程单独负责用户确认后的 shell.openPath(installer)。
// 取消或退出：updater.cancel(); await updater.cleanup();
```

`check()` 返回 null 或 `{version,tag,name,notes,url,prerelease,assetName,size,downloadURL,checksumURL}`。`download()` 返回本机安装包路径。`cancel()` 中止在途网络和流读取；`cleanup()` 等待取消完成，再删除本实例创建的临时目录，不清空调用方指定的整个目录。主进程安排每日检查定时器；模块本身不维持后台检查定时器。

## 发布约定与渠道

从固定仓库的 [GitHub Releases API](https://docs.github.com/en/rest/releases/releases) 读取最近最多 300 个发布。Windows 版本只来自完全匹配的 `naigrey-windows-<SemVer>-x64-setup.exe` 文件名，不把 Mac `v3.x` 标签当作 Windows 版本。忽略草稿、旧版本、其他架构、ZIP、缺少校验清单或同名重复资产的发布。

同一发布必须包含唯一 `SHA256SUMS.txt`，其中对该安装包有且仅有一条标准 SHA-256 记录。支持 `hash  filename` 和 `hash *filename` 两种格式。安装包和清单的初始 URL 必须精确指向 `github.com/freedomxia/naigrey-pet/releases/download/<tag>/<asset>`。

默认正式渠道拒绝 GitHub `prerelease:true` 和带 SemVer 预发布后缀的安装包。Windows 当前使用预览渠道时，调用方显式传 `allowPrerelease:true`。不因 Windows 包描述包含“预览”自动改变渠道。

## 网络、磁盘与取消边界

- 仅 HTTPS，无 Cookie、无认证令牌，禁用自动跳转与缓存。手动逐跳验证，最多 5 次重定向。
- 下载只允许本仓库 GitHub release 路径以及精确主机名 `release-assets.githubusercontent.com`、`objects.githubusercontent.com`；拒绝任意子域、HTTP、非标准端口、用户名密码 URL 和本地地址。API 仅允许固定仓库 releases 路径。
- 检查总超时 20 秒；下载总超时 300 秒。检查每页响应最多 2 MiB、最多 3 页；清单最多 64 KiB；安装包最多 512 MiB，并须与 GitHub 资产大小一致。
- 下载分块写入独立临时目录中的 `installer.part`，同时计算 SHA-256。大小和哈希均通过后才重命名为安装包名称；异常、取消、校验失败都删除本次暂存文件。不缓存授权 URL 到设置或日志。
- 即使测试替身忽略 AbortSignal，取消和超时也能结束当前操作。并发检查合并；同时只能下载一个安装包。

SHA-256 校验检测损坏和清单不匹配；它不是发布者数字签名。Mac `Updater.swift` 的 Ed25519 签名验证和 app bundle 替换机制没有被宣称为 Windows 已有能力。Windows 当前分发 NSIS 安装包，安装由用户触发，代码签名证书状态应在发布说明中明确。

测试使用合成 GitHub 响应和临时目录，不下载真实安装器、不执行任何程序。真实 GitHub 重定向下载和 Windows 安装流程由集成验收单独确认。
