# Windows Mac 行为完整移植

用户授权：以本仓库 Source 的 Mac 3.4.0 行为为标准完整移植，保留原 Mac 代码与素材。Windows 现有实现是基础，不以首版 scope 限制此次任务。系统 API 适配必须明确证据，不伪造状态。

## Task 1: 动画和互动
移植 Source/Rig.swift、Renderer.swift、Motion.swift 中的待机变形、眨眼、视线、撸猫、耳朵尾巴动作。尽量直接导出原 rig 数据并移植着色器/参数，避免近似重画。对照 main.swift 的动作过渡、拖拽、走路转向、睡眠唤醒与 Ball.swift 玩球行为。负责 Windows/src/pet*、新动画模块、导出工具和资产、对应测试。不得修改 main.cjs/quota.cjs。

## Task 2: 额度服务
移植 Source/AICompanion 的额度来源选择、刷新、缓存解析、CLI fallback、提醒重置规则和身份稳定性到 Windows。负责 quota.cjs、新 quota 相关模块和测试/来源文档。凭证不泄漏，不读取开发机真实账号用于测试。续期遵循上游固定端点，取消/超时安全。原 Mac 专用路径不能硬套 Windows；所有不支持项记录具体原因。不得修改 main.cjs/pet*。

## Task 3: 系统感知和会话
移植 Senses.swift、Sessions.swift，提供 Windows 原生系统感知（仅按键节奏、不记录键值；仅音频活动、不采集音频）和有界本地会话扫描。新模块和必要本地 helper/build 脚本及测试。不得修改 main.cjs/pet*/quota.cjs/package.json/workflow，集成点报告 root。

## Task 4: 主进程集成及验收
Root 对照 Mac main.swift/CompanionService/设置面板补作息、陪伴模式、AI 会话联动、大小/漫游/提醒设置、更新检查与安装等。整合前三任务接口；单元和集成测试，实际 Electron 渲染检查，Windows CI 安装包测试。版本升级为 0.2.0。写逐项对照表，明确代码完成和真实机器验证的区别。最终进行独立审查、修复发现问题、推送现有 feature/windows-desktop 和更新 PR，生成安装包。

## 接口与约束
动画 renderer 通过 state 获得 prefs、senses 和 sessions；主进程 action/bubble 事件保持。新增传感器接口应无 Electron 依赖，主进程提供生命周期；跨进程只传归一化状态。测试应先覆盖原缺失行为，再实施。各任务仅提交自己的文件，不回退别人修改。不操作其他 worktree，不读取用户会话正文到日志。不改用户现有凭证，除非用户开启续期且原子安全写入。
