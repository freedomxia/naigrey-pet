# Windows 预览版验证记录

日期：2026-09-20。平台：macOS Apple Silicon 本地预览及 GitHub Actions Windows 构建机。

## 已验证

- `npm test`：25 项通过。覆盖额度解析、阈值去重、账号变化、重置、限流、超时和取消，以及睡眠请求、面板边界、动作坐标和高刷新率位移累计。
- `npm run smoke`：16 段视频由 Electron Chromium 实际解码，逐段首帧 alpha 同时含透明和不透明像素，招手片段播放到 ended 事件。输出 `ok: true`、`clips: 16`、`transparent: true`、`playbackCompleted: true`。
- 视频转换：全部 1,417 帧保留，AVFoundation 导出与 libvpx 解码均验证 alpha 0–255。
- 本机 Electron 预览：猫咪显示，AI 卡片打开、失焦收起、重新打开，设置窗口及敲键盘入口动作。
- 独立代码审查：修复重复睡眠冻结、启动提醒丢失、许可证遗漏、连接恢复说明及高刷新率位移丢失。

- [Windows CI 运行 35455662509](https://github.com/freedomxia/naigrey-pet/actions/runs/35455662509)：25 项测试通过，NSIS x64 安装程序和便携 ZIP 构建成功。打包后的 Windows 程序完成全部 16 段视频透明解码及招手片段播放。
- GitHub workflow 授权完成，工作流已启用。

## 尚未完成

- 真实 Windows 安装 / 卸载、托盘、透明窗口、鼠标穿透、多屏、长时间动画与真实账号读取未实机验收。
- Claude Desktop 缓存、CLI 回退、自动续期及 Windows 自动更新不在当前实现中，详见 quota-sources.md。

便携包为未签名预览包，不作为已完成 Windows 实机验收的正式版本。

## 0.1.1 待机修复

- 已确认 0.1.0 缺少 Mac 版的自主行为调度，现补充启动招手、间隔活动、自动小睡及醒来，并允许独立关闭。
- 桌宠窗口关闭后台动画节流，额度面板仍使用默认节流。
- 新增持续渲染回归检查。隐藏窗口在 Windows CI 不刷新，因此检查改为与安装版一致的 showInactive 状态，未放宽帧数和像素变化断言。
- [Windows CI 35483112585](https://github.com/freedomxia/naigrey-pet/actions/runs/35483112585)：28 项测试通过；待机检查前 1.5 秒内至少 10 帧且像素改变，整个解码/播放检查累计 388 次画布更新；16 段透明解码和完整招手播放通过，0.1.1 NSIS/ZIP 构建成功。
- 以上证明构建机普通窗口状态下持续渲染。用户机器上的静止现象仍需安装新版确认，不能据此宣称所有 Windows 驱动/多屏环境均已验证。
