# Windows 额度来源与边界

此模块是 Node CommonJS，无第三方依赖。协议取自当前仓库的 `Source/AICompanion/Providers.swift`、`CNCodexUsage.swift`、`CNUsageResponse.swift`；提醒规则参考 Codenotch v1.14.0 的 `CNThresholdNotifier.swift`、`CNUsageResetWatcher.swift` 和 `CNUsageLimitWatcher.swift`（MIT，版权与许可见根目录 `THIRD_PARTY_NOTICES.md`）。下面描述的是本模块已经实现的行为，不表示已用真实 Windows 账号验收。

## 登录来源

| 提供方 | 文件 | 支持的字段 | 固定 HTTPS 请求 |
| --- | --- | --- | --- |
| Codex | `$CODEX_HOME/auth.json`，未设时为用户主目录 `.codex/auth.json` | `tokens.access_token`、`tokens.account_id`；JWT `exp` 过期检查 | `https://chatgpt.com/backend-api/wham/usage` |
| Claude Code | `$CLAUDE_CONFIG_DIR/.credentials.json`，未设时为用户主目录 `.claude/.credentials.json` | `claudeAiOauth.accessToken`、`claudeAiOauth.expiresAt`（毫秒） | `https://api.anthropic.com/api/oauth/usage` |

Codex 请求包含 `ChatGPT-Account-Id`；Claude 请求包含 `anthropic-beta: oauth-2025-04-20`。两者仅以 Bearer 方式发送访问令牌，不使用 refresh token，不修改凭证。登录续期由原客户端负责。Codex API Key 计费模式不支持订阅额度。仅存于系统凭据管理器、没有上述文件的登录方式目前不可用。

Windows 首版没有移植 macOS Claude Desktop 缓存：现有实现依赖 macOS 应用缓存布局和组织选择信息，Windows 存储路径、编码和账号对应关系未验证。也没有自动启动 Claude CLI `/usage`：现有桥接依赖 macOS CLI/终端过程，Windows 交互式认证、PTY 输出及取消行为未验证。因此 Claude 仅支持上述 OAuth 文件来源。OAuth 失败或限流时显示真实错误，不用模拟数据冒充备用来源。

## 解析与提醒

Codex 解析 `rate_limit.primary_window/secondary_window`，Spark `additional_rate_limits` 和 `code_review_rate_limit`。百分比必须是 0–100 的有限数字；异常单个窗口不会丢掉有效兄弟窗口。`reset_at` 是秒时间戳，备用 `reset_after_seconds` 是相对秒数。缺失或无效重置时间为 null。

Claude 优先读取 `limits[{kind,percent,resets_at,scope.model.display_name}]`，合并 `five_hour` 为 `session`、`seven_day` 为 `weekly_all`。同一 id 去重，当前会话排在最前。Claude 窗口要求有效 ISO 8601 重置时间；日期缺失或无效时跳过。此行为与 CNUsageResponse.swift 的 limitWindows() 一致：limits 项和命名窗口都要求非空 resetsAt；现代项缺失重置时间时，仍可由同 id 的有效命名窗口补入。没有可用窗口时返回 unsupported，绝不把缺失值当 0。

主窗口从低于 80% 跨到 80%、100% 时发对应提醒；初次连接已在阈值上方也会发阈值提醒。重复采样不重复提醒，降到下一档后可以再次跨越。每周 100% 提醒从第二次有效采样开始；跌到 95% 以下或重置时间向后推进才解除去重。

重置提醒要求历史峰值至少 15%，并满足重置日期向后推进，或用量下降至少 20 个百分点，或峰值至少 30% 后降至 10% 以下。重置时间和峰值记录避免同一变化重复提醒。提醒只看主会话和全模型周窗口，Spark/代码审查/模型专属窗口仅供显示。

Codex 使用账号 ID 的 SHA-256，Claude 使用访问令牌的 SHA-256 作为进程私有身份标记。账号变化、Claude 令牌轮换重新建立提醒基线，不把账号切换视为额度恢复，也不重播已有阈值。断开连接清除提醒基线。哈希、原始账号 ID、令牌均不进入 snapshot、change 或 reminder。

## 服务 API

```js
const { QuotaService, parseCodex, parseClaude, ReminderTracker } = require('./src/quota.cjs');
const service = new QuotaService({ home, env, fetchImpl, now }); // 所有参数可省略
service.on('change', snapshots => {});
service.on('reminder', ({ provider, title, body, kind }) => {});
service.start();                  // 幂等；每 60 秒仅刷新已连接提供方
await service.connect('codex');    // 明确连接后才读取凭证并请求
await service.refresh();          // 或 refresh('claude')；仍尊重 Retry-After
const snapshots = service.snapshot();
service.disconnect('codex');      // 取消在途请求，清空该方数据
service.stop();                   // 停止周期刷新并使在途结果失效
```

`connect`、`refresh` 返回 Promise，解析为快照数组；`disconnect`、`stop` 同步；`start` 返回服务实例。`now` 为返回毫秒时间戳的函数，也可返回 Date。快照固定按 Codex、Claude 排序：

```js
{ provider, status, source,
  windows: [{ id, label, usedPercent, resetsAt }],
  message, observedAt }
```

`status` 为 `disconnected | ok | needsAuth | accessDenied | unsupported | error`；时间均为 ISO 字符串或 null。任何失败清空 windows，避免旧账号或过期读数继续显示；成功时 message 可为 null。snapshot 和 change 均返回副本。reminder 的 kind 为 `threshold-80 | threshold-100 | weekly-limit | reset`。

解析器分别为 `parseCodex(objectOrJSON, nowMilliseconds?)`、`parseClaude(objectOrJSON)`，返回窗口数组，无有效数据会抛错。`ReminderTracker.observe(snapshot, privateFingerprint)` 返回提醒数组；`forget(provider)` 清理该提供方。

## 请求约束与验证范围

首次启动默认不连接。用户明确连接后，主进程仅保存提供方名称，后续启动按此选择重新连接；断开连接会删除对应选择。QuotaService 自身不读写设置，由主进程调用 connect 恢复已授权的选择。设置不保存访问令牌、刷新令牌、账号 ID 或凭证指纹。凭证在请求时读取，文件上限 1 MB；HTTP 响应流上限 2 MB；整个网络请求和响应读取超时 15 秒。请求拒绝所有重定向，不接受可配置端点，禁止 cookie 携带和缓存。错误文案不包含服务端响应或异常原文。相同提供方并发刷新合并。断开/停止后到达的结果失效。

429 的 Retry-After 支持秒数和 HTTP 日期，最低等待 60 秒，手动刷新和断开重连也不能跳过；限流状态仅存在进程内。自动轮询 60 秒，不启动任何外部 CLI 或凭证刷新。没有主动探测第三方登录状态。

单元测试覆盖解析、合并、非法数值/日期、阈值去重、周限额迟滞、重置、账号切换、明确连接、过期登录、自定义目录、固定端点及重定向选项、限流和到期、断开后的迟到结果、API Key 拒绝、响应大小、鉴权失败清空和敏感内容不外传。测试采用临时文件与假 HTTP 响应，不读取开发机账号、不调用真实额度接口。真实 Windows 文件登录与服务器响应尚需验收。
