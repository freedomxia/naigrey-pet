# 奶灰桌宠 · Windows 预览版

支持 Windows 10 / 11 x64。独立 Electron 实现，沿用奶灰形象与 16 段透明动作。

## 安装与使用

**[下载 Windows 安装程序（.exe）](https://github.com/freedomxia/naigrey-pet/releases/download/windows-v0.2.3/naigrey-windows-0.2.3-x64-setup.exe)**

文件名：`naigrey-windows-0.2.3-x64-setup.exe`。支持 **Windows 10 / 11，x64（64 位）**。

1. 退出正在运行的旧版奶灰。
2. 双击下载的 `.exe` 文件，选择安装位置并完成安装。
3. 打开桌面上的「奶灰桌宠」快捷方式。

**直接下载安装，不需要压缩包、不需要解压、不需要登录 GitHub。** Releases 的 `Source code (zip)` / `Source code (tar.gz)` 是源码，请忽略。`SHA256SUMS.txt` 是可选的文件校验信息，不是安装程序。

[Windows 自动构建](../.github/workflows/windows.yml)已启用。成功运行会提供 `naigrey-windows-x64-preview` 工件，包含 NSIS 安装程序、便携 ZIP 和 SHA-256 校验文件。构建记录见 [GitHub Actions](https://github.com/freedomxia/naigrey-pet/actions/workflows/windows.yml)。

Windows 安装包尚未使用 Windows 代码签名证书。安装前核对来源和同包 `SHA256SUMS.txt`。应用内的自动更新另有一层发布者 Ed25519 签名校验（见 [更新下载器](docs/updater.md)），这和 Windows 代码签名证书是两件事。

- 原版动态待机：呼吸、尾巴、耳朵、眼神跟随和撸猫；自主走动、伸懒腰、打哈欠与小睡，可在设置独立关闭。
- 单击招手，双击睡觉 / 叫醒，拖动搬家，头顶移动鼠标摸摸猫。
- 右键小猫或点击托盘菜单，选择打招呼、散步、伸懒腰、打哈欠、丢毛线球、睡觉 / 叫醒，以及猫咪大小四档（迷你 / 小巧 / 标准 / 大只，默认小巧）。
- 点击 AI 按钮打开猫咪下方的横版额度卡片，点击别处收起。屏幕下方空间不足时面板放到猫咪上方。卡片按剩余额度分三档配色（≤10% 红、≤20% 橙，其余绿），数据过期会整列转灰并标注「历史记录」，不会把过期或未知读数显示成正常额度。
- 首次点击连接后才读取本机账号。连接选择会保留，重启后继续刷新；点击断开后停止读取。
- 设置可调整开机启动、重置时间显示为倒计时（默认为绝对日期）、系统通知、通知声音、夜间免打扰与提醒动作，也可预览提醒气泡。系统通知默认关闭。

## 额度来源与边界

Codex 从 `%USERPROFILE%\.codex\auth.json` 读取默认账号；设置了 `CODEX_HOME` 时使用该目录。Claude Code 从 `%USERPROFILE%\.claude\.credentials.json` 读取 OAuth；支持 `CLAUDE_CONFIG_DIR`。

仅使用凭证请求相应服务的固定 HTTPS 额度接口，不把令牌传给页面或写入设置。可在设置明确开启 Claude CLI 查询及续期；未开启时不会启动 CLI。失败时显示真实状态，不生成模拟额度。

阈值和重置检测从现有 Codenotch 对齐代码移植。0.2.0 已移植 Claude Desktop 缓存、授权后的 CLI `/usage` 回退及登录续期、会话状态、作息与陪伴。完整对照和平台边界见 [Mac 行为对照](docs/mac-parity.md)。使用 WSL 内独立登录的账号，需要后续单独适配。详见 [额度来源记录](docs/quota-sources.md)。

## 开发

```sh
cd Windows
npm ci
npm test
npm run demo     # 演示额度，不连接真实账号
npm start        # 正常模式，需手动连接
npm run smoke   # Chromium 解码 / 透明通道检查
npm run build:native # Windows 上构建本地感知组件
npm run dist    # 在 Windows 构建 NSIS 安装包与便携 ZIP
```

依赖版本固定在 package-lock.json。主进程负责账号和窗口，沙箱页面仅通过窄 IPC 接口操作。Windows GitHub Actions 会运行 Node 测试、打包，并在打包后的应用中检查全部 16 段视频的首帧解码、透明通道，以及招手片段播放结束事件。

动作素材的转换说明见 [assets/README.md](assets/README.md)。原始 HEVC alpha 需要在 macOS 用 AVFoundation 导出；已转换的素材随仓库提供，Windows 构建无需 Apple 工具。

## 验收范围

自动测试覆盖解析、阈值去重、重置、账号切换、限流、超时、断开、动作路径及面板位置。解码检查不能替代真实 Windows 上的安装、鼠标穿透、多显示器、连续动画和真实账号验收。首版作为预览包提供，未经实机验证的项目不视为已通过。

已加入每日更新检查：按 Windows 安装包版本判断新旧，用户确认后下载。先用内置的发布公钥验证 `SHA256SUMS.txt.sig`，再用清单里的 SHA-256 校验安装包，然后启动安装程序。缺少签名的发布不会被提供为更新。预览渠道保持开启，现有的 Windows 预览发布照常提示更新。
