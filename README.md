# 奶灰桌宠

一只住在 macOS 桌面上的奶灰小猫。待机时是实时逐部位动画（看鼠标、眨眼、呼吸、被撸会眯眼），做动作时播放抠好的透明视频片段（招手、打哈欠、伸懒腰、走路、趴下睡觉、醒来、玩毛线球），动作之间会起身、转身、坐下，像一镜到底，并会跟着你用电脑的作息自己犯困、入睡、醒来和打招呼。

![版本](https://img.shields.io/github/v/release/freedomxia/naigrey-pet)

## 安装

到 [Releases](https://github.com/freedomxia/naigrey-pet/releases/latest) 下载 `naigrey-mac.zip`，解压后把 `奶灰.app` 拖进「应用程序」，双击打开。

App 是本机 ad-hoc 签名、没有做 Apple 公证，所以第一次打开可能会被拦。右键点图标选「打开」，或者在「系统设置 → 隐私与安全性」里点「仍要打开」。

要求 macOS 13 或更新版本，Apple 芯片。

## 用法

菜单栏的猫爪图标里有全部开关。桌面上：单击招手，双击睡觉/叫醒，拖动搬家，在头顶来回划是撸猫。详见 [使用说明.md](使用说明.md)。

## 在线更新

奶灰每天最多查一次更新，发现新版本会冒个泡告诉你，点菜单里的「换上新衣服」就会自己下载、校验、替换并重启，位置和设置都保留。也可以随时点「检查更新…」。

更新源是这个仓库里的 [`updates/latest.json`](updates/latest.json)，安装包发在 Releases 里。因为 App 没有做公证，Gatekeeper 不会替你把关，所以更新器自己做了这件事：

- 每个安装包都用一把 Ed25519 私钥签名，公钥编译在 App 里，**签名对不上就直接丢掉**；
- 另外比对 SHA-256，用来发现下载不完整；
- 装之前还会检查解压出来的确实是同一个 App（bundle id 与构建号），并验证它的代码签名；
- 构建号只增不减，不会被降级；
- 换上去之前，旧版本会留一份在 `~/Library/Application Support/奶灰/backup/`。

私钥只存在发布者本机（`~/.naigrey/release-key`），不在仓库里。

## 自己构建

```sh
./build.command        # 编译 + 打包成 奶灰.app
./Tests/verify.command # 25 项自检
```

需要 Xcode 命令行工具，不依赖任何第三方包。

发布新版本（需要私钥和 `gh`）：

```sh
Tools/release.command 3.0.4 "这次改了什么"
```

## 目录

| 位置 | 是什么 |
| --- | --- |
| `Source/` | App 源码：素材切分、绑定与蒙版、Metal 渲染、动作行为、毛线球、视频片段、更新器 |
| `Assets/clips/` | 抠好的透明动作片段（HEVC with alpha）和它们的元数据 |
| `Tools/clips/` | 从绿幕视频里切片段的脚本 |
| `Tools/clipcheck/`、`Tools/preview/`、`Tools/fadecheck/`、`Tools/joincheck/` | 片段与画的猫并排比对、离屏预览动画、交接合成检查、动作接缝检查 |
| `Tools/relkey/`、`Tools/release.command` | 发布签名密钥工具与发布流程 |
| `验收记录.md` | 每个版本实测了什么、边界在哪 |

## Windows

暂时没有。现在这只猫是 AppKit + Metal + AVFoundation 写的，Windows 版等于换一套技术重做，做出来会在这里发布。更新源的格式已经按多平台留好位置（`windows` 字段）。

## 素材

猫的形象与动作片段由 AI 生成后抠像处理，仅供个人使用。
