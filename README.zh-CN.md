# DSH Widget（DSH 桌面小组件）

[English](README.md) · **简体中文**

把 DeepSeek Harness 的当前会话放到 macOS 桌面上：右上角常驻、直接发消息、看流式回复、切换会话。

> 非官方社区项目，与 DeepSeek 无隶属关系。
> 早期版本：**Apple Silicon / macOS 14+**，ad-hoc 签名，**未公证**。

**最新版本：** [v0.4.0](https://github.com/Ryankiinovo/dsh-widget/releases/tag/v0.4.0)

## 功能

- 固定在桌面窗口层级：位于普通应用窗口之下、壁纸之上。
- 列出当前工作区的会话，并可在会话之间切换。
- 直接发送消息，流式显示助手回复。输入框支持多行草稿：**Enter 发送，Shift+Enter 换行**。
- 打开会话时加载最近约 200 条的窗口，更早的内容按需点「加载更早」向前翻页；保留本地缓存，断线后可用同步按钮补齐。
- 支持基础 Markdown：段落、标题、列表、引用、分隔线、代码块，以及行内粗体/斜体/代码/链接。
- 提供工作区菜单，可在当前工作区新建会话。
- Agent 运行时在会话末尾常驻一条状态行：呼吸灯（绿＝思考/生成回答，蓝＝运行工具，黄＝等待或出错）、动作名、已用计时、第 N 步、秒格条、最近 3 段思考，以及最近 3 个工具调用的流水。
- 消息里的图片以缩略条显示（56pt、一行最多 9 格、超出显示 +N），点击打开查看器、←/→ 翻页、Esc 关闭；输入框支持粘贴与拖放图片文件。
- 手机配对：header 的二维码按钮弹出卡片（白底二维码 + 6 位配对码 + 倒计时 + 候选地址），移动端扫码即配对；配对后设备 token 可单独吊销。
- DSH 设置页也能配对：设置 →「Widget」一栏显示 App 是否在跑（未运行时可点「启动」直接拉起），点「生成配对码」就地出二维码与 6 位码，120 秒倒计时、过期点「刷新」重新生成；码下方标出二维码里带的局域网与公网地址，公网不通写明「公网未连接」。不开 App 也能给新设备配对。
- 可选远程访问：`src/scripts/tunnel.sh` 起 Cloudflare quick tunnel 并把地址写入 `~/.dsh/widget-public-url`，`install-launchd.sh` 把它装成用户级常驻服务（登录自启、挂了自动拉起、不受 DSH 退出影响）；`GET /v1/endpoints` 让客户端自动刷新候选地址，隧道换域名不必重扫配对码。

## 环境要求

- Apple Silicon Mac，macOS 14 或更高版本。
- 已安装并运行 DeepSeek Harness 桌面端。
- 已把 **dsh-widget-bridge** 插件安装到 DSH desktop profile。
- 从源码构建时需要 Xcode Command Line Tools 和 Node.js 22+。

> DMG 里只有 App。桥插件是必需组件，需要从源码树安装。

## 安装

### 1. 安装桥插件

```bash
git clone https://github.com/Ryankiinovo/dsh-widget.git
cd dsh-widget
./src/scripts/install.sh
```

脚本会：

1. 把 `src/bridge` 符号链接到 `~/.dsh/profiles/desktop/node_modules/dsh-widget-bridge`。
2. 备份 `~/.dsh/profiles/desktop/cordis.patch.yml`，并只追加一次插件条目。

然后**完全退出 DSH（Cmd+Q）再重新打开**。只关窗口不算；插件只在 Host 启动时加载。出现 `~/.dsh/widget-bridge.json` 就说明桥已运行。

### 2. 安装 App

从 Releases 下载最新的 `DSHWidget-<version>-macos-arm64.dmg`，打开后把 `DSHWidget.app` 拖进“应用程序”。

当前构建是 ad-hoc 签名、未公证，Gatekeeper 可能拦截首次启动。请使用**右键 → 打开**，或在终端执行：

```bash
xattr -dr com.apple.quarantine /Applications/DSHWidget.app
```

只对你信任的构建执行这个操作。后续版本可以改为 Developer ID 签名并公证。

### 3. 启动

打开 `DSHWidget.app`。小组件默认出现在桌面右上角；拖动边缘可以调整大小。如果显示“等待 DSH”，启动或重新打开 DSH，让桥写入 discovery 文件。

## 从源码构建

```bash
git clone https://github.com/Ryankiinovo/dsh-widget.git
cd dsh-widget

# 1. 安装桥插件到 DSH desktop profile
./src/scripts/install.sh

# 2. 构建 App（原生架构，目前为 arm64）
./src/macos/build.sh

# 3. 可选：构建 DMG
./src/scripts/make-dmg.sh --skip-build

# 4. 运行
open dist/DSHWidget.app
```

DMG 输出到 `dist/DSHWidget-<version>-macos-<arch>.dmg`，同时生成 `.sha256` 文件。

### 测试

```bash
node --check src/bridge/index.js
node src/bridge/test-mock.mjs
./src/scripts/verify-widget.sh
tail -n 20 ~/.dsh/widget-verify.log
```

mock 测试不需要运行中的 DSH Host。

## 工作原理

```text
DSH Host
  └─ dsh-widget-bridge 插件（src/bridge）
       ├─ 在 127.0.0.1:<随机端口> 上提供 HTTP + SSE
       ├─ 写入 ~/.dsh/widget-bridge.json（pid/port/token，权限 0600）
       └─ 调 DSH session controller：list/create/prompt/cancel/follow/page
                 ▲
                 │ Bearer token
                 ▼
        DSHWidget.app（src/macos）
          ├─ 读取 discovery，加载完整历史，然后跟随 SSE
          └─ 桌面层级 NSPanel
```

桥不复制 DSH 的业务逻辑，只把已有的会话能力暴露为本地 HTTP/SSE API。App 不读取 DSH cookie、启动 token、Keychain 项或 API Key。

## 安全

- 只监听 `127.0.0.1`，使用随机端口和每 Host 随机的 token。
- 拒绝带浏览器 `Origin` 头的请求。
- discovery 文件权限为 `0600`，应视为本地机密。
- 请求体上限 1 MB；历史分页最多 500 条记录。
- 不收集遥测数据。

## 已知限制

- 仅支持 Apple Silicon；此构建不支持 Intel Mac。
- 需要 macOS 14+。
- ad-hoc 签名、未公证；首次启动需要右键打开或移除 quarantine。
- 依赖运行中的 DSH desktop host 和桥插件。
- Markdown 只支持基础子集；表格、原始 HTML 和深层嵌套不渲染。
- 小组件位于桌面层级，全屏应用会遮住它，这是设计行为。
- 没有协议版本协商；未来 DSH 版本可能修改插件 API。
- 首屏是约 200 条的窗口，更早的消息按需翻页加载；全量导入（`?all=1`）最多 200 页。
- Cloudflare quick tunnel 会把 `text/event-stream` 响应体缓冲约 40–50 秒，蜂窝网络下客户端会降级为轮询：能读能发，但没有实时的「思考中」状态行。需要稳定流式请用自建隧道（frp + Caddy 或 Cloudflare named tunnel）。

## 许可证

MIT License，见 [LICENSE](LICENSE)。

Copyright (c) 2026 Ryankiin.

## 参与贡献

欢迎提交 Issue 和 Pull Request。请不要包含 token、DSH discovery 文件、私有会话内容或含个人数据的截图。

提交前请运行：

```bash
node --check src/bridge/index.js
node src/bridge/test-mock.mjs
./src/macos/build.sh
```
