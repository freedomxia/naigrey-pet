# Windows 额度来源与验证边界

协议与规则以本仓库 `Source/AICompanion` 为基准，Codenotch v1.14.0（MIT）版权见 `THIRD_PARTY_NOTICES.md`。下面区分代码和合成样本已验证的行为、真实 Windows 尚待验证的行为。

## 来源选择

Codex 从 `$CODEX_HOME/auth.json`（默认 `~/.codex/auth.json`）读取 `tokens.access_token/account_id`，拒绝 API Key 模式和过期 JWT。固定 GET `https://chatgpt.com/backend-api/wham/usage`，发送 `ChatGPT-Account-Id`。

Claude 按以下顺序选择，与 `ClaudeQuotaSources.swift` 对应：

1. Claude Desktop 缓存：`%APPDATA%/Claude/Cache/Cache_Data`。组织必须匹配 `.claude.json` 的 `oauthAccount.organizationUuid`。默认账号文件在主目录；设置 `CLAUDE_CONFIG_DIR` 时在该目录内，符合 CLI 对该变量的语义。缓存成功每次重新扫描，失败等待 5 分钟；读取不足 30 分钟且无窗口已过重置时间的数据。
2. Claude CLI `/usage`：仅用户开启「允许 Claude CLI / 续期」后运行。成功缓存 5 分钟，窗口重置后不再复用；失败也间隔 5 分钟。组织变化清空缓存和尝试时间。
3. OAuth 文件：`$CLAUDE_CONFIG_DIR/.credentials.json`（默认 `~/.claude/.credentials.json`），读取 `claudeAiOauth.accessToken/expiresAt`。固定 GET `https://api.anthropic.com/api/oauth/usage`，发送 `anthropic-beta: oauth-2025-04-20`。

OAuth 429 退避不阻止 Desktop/CLI。Claude 退避为 `min(900, max(60 × 2^min(连续限流次数,4), Retry-After))` 秒，成功清零；到期时间保存到应用状态目录 `quota-backoff.json`，重启仍生效。连续次数只在内存中，与 Mac 相同。Codex 保留 Retry-After 秒数/HTTP 日期处理和最低 60 秒等待。

## Windows CLI 和续期

自动发现原生 `.local/bin/claude.exe`、`.claude/local/claude.exe`、`.bun/bin/claude.exe` 和 PATH 绝对目录中的 `claude.exe`。npm 全局安装识别 `node_modules/@anthropic-ai/claude-code/cli.js` 并使用找到的 `node.exe` 启动，不解析或执行 `.cmd/.bat` shim、不启动 shell。查找目录最多 100 个。

`/usage` 参数完全沿用 Mac：`--print --no-session-persistence --strict-mcp-config /usage`。固定工作目录 `%LOCALAPPDATA%/Naihui/usage-scratch`（变量缺失则用户主目录/Naihui）；stdin 关闭，stderr 丢弃，stdout 最多 512 KiB，20 秒超时。CLI 输出只接受 `Current session` 和 `Current week (...)` 行，必须有会话窗口；日期支持 IANA 时区、整点/带分钟、跨年最近日期；不认识日期时保留百分比、reset 为 null。

续期检查有独立的每 60 秒生命周期，空闲额度查询仍为 300 秒，不因续期增加查询频率。断开、停止、撤销授权会中止它，并丢弃迟到结果；已有额度 CLI 工作时不重叠启动。续期对应 `CNClaudeTokenRefresher.swift`：到期不足 4 分钟才尝试；每个到期时间只尝试一次、两次尝试至少隔 10 分钟、单次最长 30 秒。运行 `-p --no-session-persistence --strict-mcp-config`，无输入、无输出保留。退出码不是成功标准，重新读取后到期时间必须推进。该行为没有直接调用刷新端点；由用户安装的 Claude CLI 自行续期并维护自己的凭证，本应用不改写凭证。CLI 的未来版本可能不再于启动时续期，此时返回明确失败并停止重复尝试。

**默认关闭所有 CLI 启动。** `/usage` 也可能在启动时续期，所以和空输入续期共用授权。取消授权、断开、停止时 AbortSignal 终止进程；Windows 使用系统 `taskkill /PID … /T /F` 终止进程树，随后兜底终止直接子进程。取消后的结果不能更新状态。若操作系统拒绝结束进程，应用最多等待额外 2 秒后返回失败；无法承诺强制结束一个拒绝终止的系统进程。

## 缓存格式与隐私

支持 Mac 使用的 Chromium Simple Cache 格式：24 字节文件头、固定 magic、最多 8 KiB key、zstd body、尾部 HTTP Date。URL 检查使用精确 HTTPS host（claude.ai / anthropic.com / api.anthropic.com）和 `/api/organizations/<org>/usage`；允许 query，不接受额外路径、端口、用户信息。只有匹配组织的条目才读取完整 body，读取后再次校验组织。非匹配文件只读取 header 和 key。

目录最多枚举 20,000 项，按修改时间排序检查最近 400 个候选；条目上限 512 KiB，解压上限 256 KiB。zstd frame 长度独立解析，避免把尾部当压缩数据；使用 Node 内置 zstd，运行时无此能力时回退下一来源。读取 Date header，缺失时使用同一文件描述符的修改时间。允许小幅服务器时钟偏差。JSON 格式改变、文件正在改写、超限、其他压缩编码都回退，无错误原文或缓存正文进入日志/快照。

## 解析、身份与提醒

Codex 的主窗口、周窗口、Spark 和代码审查窗口保留原有解析；单个无效窗口不丢掉兄弟窗口。Claude 的现代 `limits` 优先，合并 `five_hour/seven_day`；OAuth/缓存窗口要求合法 ISO reset，CLI 则允许 null。缺失值不冒充 0。百分比仅接受 0–100 有限数字。

Claude 身份使用组织 UUID，取不到时用配置目录路径，与 `ClaudeQuotaSources.swift` 相同；SHA-256 仅进程内部使用。切换来源或令牌轮换不重置提醒基线；切换组织清除旧源缓存，重新建立提醒基线；和 Mac 一样可触发新账号当前阈值，但不会将账号切换当作额度恢复。配置目录 fallback 和 Mac 一样无法辨别没有组织信息的同目录账号切换，这是明确的证据边界。原始账号、token、hash 均不进入 snapshot/change/reminder。

主窗口 80%/100% 阈值、每周 100% 和 95% 迟滞、重置峰值至少 15%、下降至少 20 个百分点或峰值 30% 后降至 10% 规则继续沿用。代码审查和 Spark 仅显示。现有 Windows 提醒事件用 `threshold-80/threshold-100` 表示已用比例；Mac EventRules 的事件名用剩余比例 `threshold-20/threshold-0`，UI 集成应按 Windows 接口解读。会话耗尽另发 `session-limit`，和每周一样使用 95% 迟滞；首个样本不会发 limit 事件。即使主窗口暂时缺失，每周仍可独立触发。超过 15 分钟的缓存读数不产生提醒。

## 集成 API

```js
const service = new QuotaService({ home, env, fetchImpl, now, stateDirectory });
service.setClaudeRenewalEnabled(savedExplicitConsent === true);
const ignored = new Set();
service.on('cli-process', ({pid, active}) => {
  if (active) ignored.add(pid); else ignored.delete(pid);
}); // 按 PID 配对，旧进程迟到退出不影响新进程。legacy cli-pid 仍兼容。
service.on('renewal', outcome => { /* refreshed + until，或 failed + message */ });
service.on('change', snapshots => {});
service.on('reminder', reminder => {});
service.setActive(sessions.some(s => s.state === "busy"));
service.start();
await service.connect('claude');
await service.refresh('claude');
service.disconnect('claude');
service.stop();
```

构造函数不读凭证、不启动进程。必须 connect 后才读取；自动刷新空闲每 300 秒、有忙碌会话或重置到期时每 60 秒；相同来源并发合并。主进程负责保存提供方选择、续期授权和通知策略。`stateDirectory` 推荐 Electron `userData`，不包含凭证，仅保存限流到期。`claudeAdapters: {desktop,cli}` 仅用于测试注入。

快照格式沿用 `{provider,status,source,windows,message,observedAt}`；缓存额外提供真实 `sourceAt`。同账号的暂时错误保留原读数，超过 15 分钟标记 `stale`；认证失败、格式不支持或账号已变化时清空窗口。CLI/缓存同样不产生跨账号旧结果。Claude 401/403 会重新读取凭证，最多再请求一次。网络响应上限 2 MB，凭证文件 1 MB，请求 15 秒超时，拒绝重定向，不携带 cookie，不缓存响应，错误不含响应正文或异常原文。

## 验证与未覆盖项

`node --test Windows/test/quota*.test.cjs` 全部使用临时目录、合成 Simple Cache/zstd 文件、假 HTTP 响应和假进程，没有读取开发机账号或调用真实额度接口。

真实 Windows 用户机器尚待验收：原生/npm CLI 启动及进程树取消、Desktop 实际缓存条目、CLI 续期结果。这里实现的是普通 Electron 用户数据目录；MSIX/商店沙箱的目录重定向没有仓库样本，不扫描猜测的 Packages 路径。Chromium 其他磁盘缓存后端/编码和仅系统凭据管理器登录没有已知字段协议，明确回退 OAuth/显示需要登录，不声称已支持。Mac Security.framework 钥匙串授权没有机械映射为 Windows Credential Manager。

## Restart persistence

With `stateDirectory`, quota readings and reminder history use bounded, atomic JSON stores. They contain sanitized usage/events and SHA-256 account identity digests, never credentials. New files request mode `0600` (Windows protection inherits the user data directory ACL). Restored readings remain hidden until the current local account matches, expire after 24 hours, and remain visibly stale until a successful live read. History restoration similarly validates the provider identity, retains at most 100 events for 24 hours, and restores neither pending presentations nor unread markers. Explicit disconnect clears that provider's store. `ReminderCenter` must receive the same `stateDirectory`; snapshots sent to renderers contain no identity digest.

`reset-copy.cjs` is shared by Node and browser scripts (`window.ResetCopy.text`). It follows `CNResetCopy.swift`: nearest-minute rounding, absolute dates after 60 rounded minutes, calendar-day comparison for the seven-day boundary, locale clocks, and days/hours or hours/minutes for remaining-time mode.
