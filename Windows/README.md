# 奶灰桌宠 · Windows 预览版

支持 Windows 10 / 11 x64。独立 Electron 实现，沿用奶灰形象与 16 段透明动作。

## 安装与使用

下载 [Windows x64 预览包](https://github.com/freedomxia/naigrey-pet/actions/runs/35483112585/artifacts/10596751478)，解压后运行 `naigrey-windows-0.1.1-x64-setup.exe` 安装；也可解压其中的便携 ZIP，运行 `奶灰桌宠.exe`。GitHub Actions 工件需要登录 GitHub 下载，保留 14 天。

[Windows 自动构建](../.github/workflows/windows.yml)已启用。成功运行会提供 `naigrey-windows-x64-preview` 工件，包含 NSIS 安装程序、便携 ZIP 和 SHA-256 校验文件。构建记录见 [GitHub Actions](https://github.com/freedomxia/naigrey-pet/actions/workflows/windows.yml)。

首版安装包尚未使用 Windows 代码签名证书。安装前核对来源和同包 `SHA256SUMS.txt`。

- 默认自主活动：启动后招手，随后间隔选择走动、伸懒腰、打哈欠和短暂小睡。可在设置关闭。
- 单击招手，双击睡觉 / 叫醒，拖动搬家，头顶移动鼠标摸摸猫。
- 右键小猫或点击托盘菜单，选择玩球、打字、伸懒腰、走路、听音乐。
- 点击 AI 按钮打开猫咪下方的横版额度卡片，点击别处收起。屏幕下方空间不足时面板放到猫咪上方。
- 首次点击连接后才读取本机账号。连接选择会保留，重启后继续刷新；点击断开后停止读取。
- 设置可调整开机启动、倒计时、系统通知、通知声音、夜间免打扰与提醒动作。系统通知默认关闭。

## 额度来源与边界

Codex 从 `%USERPROFILE%\.codex\auth.json` 读取默认账号；设置了 `CODEX_HOME` 时使用该目录。Claude Code 从 `%USERPROFILE%\.claude\.credentials.json` 读取 OAuth；支持 `CLAUDE_CONFIG_DIR`。

仅使用凭证请求相应服务的固定 HTTPS 额度接口，不把令牌传给页面或写入设置。登录过期时请在原客户端登录续期；失败时显示状态，不生成模拟额度。

阈值和重置检测从现有 Codenotch 对齐代码移植。Windows 首版暂未实现 Claude Desktop 缓存、CLI `/usage` 回退及自动凭证续期，因此不宣称与 macOS 完全等同。使用 WSL 内独立登录的账号，需要后续单独适配。详见 [额度来源记录](docs/quota-sources.md)。

## 开发

```sh
cd Windows
npm ci
npm test
npm run demo     # 演示额度，不连接真实账号
npm start        # 正常模式，需手动连接
npm run smoke   # Chromium 解码 / 透明通道检查
npm run dist    # 在 Windows 构建 NSIS 安装包与便携 ZIP
```

依赖版本固定在 package-lock.json。主进程负责账号和窗口，沙箱页面仅通过窄 IPC 接口操作。Windows GitHub Actions 会运行 Node 测试、打包，并在打包后的应用中检查全部 16 段视频的首帧解码、透明通道，以及招手片段播放结束事件。

动作素材的转换说明见 [assets/README.md](assets/README.md)。原始 HEVC alpha 需要在 macOS 用 AVFoundation 导出；已转换的素材随仓库提供，Windows 构建无需 Apple 工具。

## 验收范围

自动测试覆盖解析、阈值去重、重置、账号切换、限流、超时、断开、动作路径及面板位置。解码检查不能替代真实 Windows 上的安装、鼠标穿透、多显示器、连续动画和真实账号验收。首版作为预览包提供，未经实机验证的项目不视为已通过。

当前通过 Releases 页面手动下载新版，尚未接入 Windows 自动替换更新。
