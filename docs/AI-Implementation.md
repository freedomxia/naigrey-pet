> 2026-09-19 更新：额度逻辑已按用户要求对齐 Codenotch v1.14.0，以下早期方案中的自定义阈值、持久去重和保守重置规则已被替代。当前实现与验证见 [AI-Codenotch对齐记录.md](AI-Codenotch对齐记录.md)。

# AI 额度与动作联动实施记录

依据：AI-Spec.md。独立 feature/ai-companion 工作区；本轮实现只读额度、事件规则、任务观察、设置与提醒 UI。保留现有待机和手动交互，未验收大动作不接入。

- [x] 平台读取与契约及 fixture 测试（Codex 文件登录 / Claude OAuth）
- [x] 额度/会话规则及去重测试
- [x] 服务、单飞、退避、持久化、取消与睡眠生命周期
- [x] AppKit 面板、菜单、徽标及提醒桥
- [x] 独立预览包、回归、代码审查、修复、验收说明
- [ ] 真实账号对照、通知投递、锁屏后可见 UI 复验和性能实测

Ruling: 原生 worktree 工具因当前 cwd 非 Git 仓库失败；在实际子仓库用 Git 创建同级隔离工作区，不覆盖现有资源。
Ruling: subagent-driven-development 技能用于明确接口的子模块，主代理负责服务与 UI。
Ruling: 未明确连接不读取账户；代码完成不等于真实账户读数已验证。

Ruling: 使用独立预览包交付，不替换原应用；保留 feature/ai-companion 分支，未发布、未推送、未合并。
