# Windows 0.2.0 验证记录

日期：2026-09-20。基于原 Mac 3.4.0 代码移植，逐项说明见 [行为对照](mac-parity.md)。

## 已验证

- Node 134 项测试通过，含实际主进程初始化/IPC、动作取消竞态、原生双击间隔、原 Swift 动画参数对照、所有视频实际alpha边界、额度/提醒/续期/会话/更新规则。
- [Windows CI 35490792288](https://github.com/freedomxia/naigrey-pet/actions/runs/35490792288)：134项测试通过；C#原生helper编译成功，keyboardAvailable=true；持续传感器协议与进程身份检查NATIVE_TRANSPORT_OK。
- Windows打包程序 smoke：16段透明动画，701次累计待机帧更新，完整动作播放，连续走路5圈（超过原4圈截止），局部状态更新不破坏方向/AI指示。
- NSIS x64安装包及便携ZIP构建完成，随包提供SHA256SUMS.txt。
- 本机Electron smoke同样通过。独立审查发现的大尺寸裁切、旧视频失败覆盖新动作、续期时机、进程PID竞态、双击误挥手、旧会话提醒等已修复并回归测试。

## 尚需目标机器验证

CI没有音频端点（audioAvailable=false），所以只验证音频API可执行、不可用时诚实报告，不能声称已验证真实音乐应用。真实Windows安装/卸载、系统托盘、混合DPI多屏、用户输入法/音乐应用、真实登录与长期性能仍需目标机器验收。本轮Mac锁屏，最后的目视检查未完成。

预览安装包未使用Windows代码签名。GPU从Metal改为WebGL2，公式与素材一致，不承诺不同系统/显卡逐像素一致。
