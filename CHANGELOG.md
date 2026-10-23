# Changelog

本项目的重要变更都记在这里，格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Added

- 输入框支持多行草稿：Enter 发送、Shift+Enter 换行（Option/Control+Enter 也换行；输入法组词时回车交给输入法）。
  输入框改为 AppKit 自绘 `NSTextView`，替换原 SwiftUI `TextField`。
- `~/.dsh/widget-events.log`：只记连接、重连、快照合并、结算、补拉等事件名与计数，不记消息正文；
  `DSHWIDGET_EVENT_LOG=off` 可关闭。

### Fixed

- SSE 长连接断开期间完成的回复不再丢失：重连后的 `snapshot` 改为按 id/seq/turn+step 合并进现有转录，
  不再整段丢弃；新增 3 秒对账与 `/history?after=<seq>` 静默补拉，空气泡会自行清算。
- SSE 资源超时从 1 小时放宽到 24 小时，并新增 60 秒无字节的 stall 看门狗（睡眠唤醒后的假连接也能重连）。

### Changed

- 新增纯函数测试 25 条（转录合并/结算/补拉 17 条 + 键盘规则 8 条），`./src/scripts/test-reconnect.sh --unit` 可离线运行。

## [0.1.0] - 2026-10-22

首个公开版本。

### Added

- 把 DSH 当前会话放到 macOS 桌面层级：右上角常驻，不盖住普通应用窗口。
- 当前工作区的会话列表与切换、工作区菜单、新建会话并自动归入工作区。
- 直接发送消息、流式显示回复、停止生成；失败时撤回气泡并恢复草稿。
- 分页加载全量历史并缓存；断线后可手动增量同步。
- 基础 Markdown 渲染（段落、标题、列表、引用、分隔线、代码块、行内格式）。
- 桥插件 `dsh-widget-bridge`：本地 HTTP + SSE，token 鉴权，启动时补齐漏挂到工作区的历史会话。
- DMG 安装包（App 本体，ad-hoc 签名、未公证）与 SHA256。

[Unreleased]: https://github.com/Ryankiinovo/dsh-widget/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Ryankiinovo/dsh-widget/releases/tag/v0.1.0
