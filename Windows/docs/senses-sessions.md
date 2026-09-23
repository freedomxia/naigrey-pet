# Windows 系统感知与本地会话

本模块移植 `Source/Senses.swift` 和 `Source/AICompanion/Sessions.swift` 的规则。JS 域规则可在任意 Node 平台测试；真实输入来自 Windows helper，不以模拟状态代替不可用接口。

## 原生来源与隐私

`native/Naigrey.Senses.cs` 用 `WH_KEYBOARD_LL` 监听按下事件，只记录单调时钟时间。回调不读取 `KBDLLHOOKSTRUCT`，不提取键码、字符、窗口标题或输入文本。主进程只收到距上次按键的秒数；鼠标活动不会误当作打字。主线程运行 Windows 消息循环，Core Audio 查询在独立 MTA 线程执行，不阻塞键盘回调。键盘来源不可用时明确输出 `keyboardAvailable:false`。

音频来源是所有活动输出设备（最多 64 个）的 Core Audio 会话状态：排除系统声音、桌宠主进程及同名媒体子进程、静音或音量为零的会话，仅检查 `AudioSessionStateActive`。非默认输出设备上的应用音频同样参与判断，设备移除时会继续检查其他设备。不打开捕获流，不读取音频样本。没有输出设备或所有设备均无法读取时输出 null，由 JS 标记 `audioAvailable:false`。在开发环境中父程序名为 Electron 时，其他同名 Electron 音频进程也会被排除；安装后的产品名称独立。

与 Mac 相同，连续音频活动 8 秒进入听音乐，静止 4 秒退出；短提示音不触发。打字需最近 6 秒内至少 8 次可观察按键变化、持续至少 2.5 秒，最近按键年龄小于 1.2 秒；停顿超过 2 秒退出。打字动画速率限制为 0.7–1.4 倍。检测的是播放会话活动，不断言声音内容就是音乐。

进程身份查询使用 Windows `Process.StartTime`，仅返回 PID 对应的 UTC 启动时间。进程消失或权限不足返回 null，不把“PID 存在”当作身份匹配。

Microsoft 原始接口文档：[LowLevelKeyboardProc](https://learn.microsoft.com/en-us/windows/win32/winmsg/lowlevelkeyboardproc)、[GetProcessId](https://learn.microsoft.com/en-us/windows/win32/api/audiopolicy/nf-audiopolicy-iaudiosessioncontrol2-getprocessid)、[Core Audio](https://learn.microsoft.com/en-us/windows/win32/api/_coreaudio/)。

## 构建与集成

在 Windows 10/11 x64 或 windows-latest CI 的 `Windows/` 目录运行：

```powershell
pwsh -File scripts/build-native.ps1
pwsh -File scripts/test-native.ps1
```

构建使用系统 `.NET Framework 4.x` 的 x64 `csc.exe`，不下载依赖，不需要管理员权限。输出 `native/Naigrey.Senses.exe`，请在 Electron builder 的 `extraResources` 中复制为 `native/Naigrey.Senses.exe`。源代码和生成二进制分离，二进制不提交 Git。原生烟测验证进程启动时间、实际采样消息、RPC 和正常管道退出；无交互桌面或音频设备时，只报告接口可用性，不能代替真人敲键盘、播放音乐验收。

```js
const { NativeSenses } = require('./senses.cjs');
const { SessionReader, SessionRules } = require('./sessions.cjs');
const senses = new NativeSenses({
  helperPath: app.isPackaged
    ? path.join(process.resourcesPath, 'native', 'Naigrey.Senses.exe')
    : path.join(__dirname, '../native/Naigrey.Senses.exe'),
  excludedPids: [process.pid],
});
senses.on('change', normalizedState => broadcast(normalizedState));
senses.start();
const reader = new SessionReader({
  processStart: pid => senses.processStart(pid),
  ignoredPids: () => quotaCLIPids,
});
const rules = new SessionRules();
const sessions = await reader.read(new Set(consentedProviders));
const alerts = rules.observe(sessions, Date.now());
// On provider consent change: invalidate in-flight reads and old cache.
reader.clearCache();
// On complete disconnect: clear alert transition history.
rules.observe([], Date.now());
// Application shutdown:
senses.stop();
```

主进程发给渲染进程的感知负载是 `senses.snapshot()` 再加上 `pointer`、`gazing`、`fixated`。`gazing` 对应 Mac `gazeFocus()` 返回非 nil（毛线球在玩、被抓住或还在滚），此时 `pointer` 指向球而不是鼠标；`fixated` 更窄，只有真在玩或球被抓住才为真，对应 Mac 同名字段。两者不可互相替代：撸猫判定必须排除 `gazing`，否则球划过头顶会被当成撸猫。

`senses.snapshot()` 为 `{status, typing, music, typingRate, pace, keyAge, keyboardAvailable, audioAvailable}`，status 为 `stopped | starting | unsupported | unavailable | partial | ok`。`start/stop` 幂等，非 Windows 不启动进程。helper 输出有界，超过 5 秒没有采样会停用并清空活动；进程 RPC 最多同时 64 个，每个 2 秒超时。helper 在父进程关闭 stdin 时退出，不留下后台键盘监听。

## 会话读取边界

默认没有启用提供方就不读取会话文件。仅扫描传给 `read()` 的已授权提供方；变更授权时必须调用 `clearCache()` 取消在途读取结果。模块不读写凭证，不联网，不启动 Claude/Codex CLI。

- Claude：`$CLAUDE_CONFIG_DIR/sessions/*.json`，默认 `~/.claude/sessions`。最多 64 个文件，每个最多 64 KiB；仅信任匹配进程实际启动时间的记录，允许初次身份时间相差 5 秒。缓存命中仍重新检查进程存活和启动时间（误差不超过 1 秒），不信任复用 PID。调用方传入额度 CLI 的动态 PID 集合，扫描前与返回前都排除。
- Codex：`$CODEX_HOME/sessions/YYYY/MM/DD/*.jsonl`，默认 `~/.codex`。仅 UTC 今天和昨天目录，每目录最多枚举 1024 项；不递归历史。选最近修改的 12 个文件，仅考虑 15 分钟内变化，每个读最后 256 KiB；截去不完整首行。匹配最新开始事件的 turn ID，旧轮次迟到完成不能结束新轮次。
- 缓存最多 128 条，按文件修改时间和大小判断；仅保存归一化状态、进程身份及文件签名，不保存会话正文或原始 JSON。显式 busy 超过 120 秒无变化降为 unknown；仅根据文件变化推导的 busy 超过 8 秒降为 unknown。
- 返回 `{id, provider, name, state, evidence, updatedAt}`；Claude 的 name 仅工作目录末级名称，Codex 使用“本地任务”。不返回 cwd 全路径、用户消息、助手消息、工具参数或日志内容。
- 提醒只从新鲜显式状态转换生成：busy→waiting，或 ended/success/failure、busy→idle；更新时间必须前进，且与当前时间相差不超过 60 秒。首个快照、derived/unknown 和重复采样都不提醒。

本机 macOS 测试使用临时合成会话与受控 native transport；未读取开发机真实会话。Windows 实际 API、键盘、音频和原生编译结果必须以 Windows CI/目标机结果确认。
