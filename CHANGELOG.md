# Changelog

本项目的重要变更都记在这里，格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

## [0.8.0] - 2026-10-26

### Added

- **App 右上角「重启 DSH」按钮**（`power`，在 `qrcode` 左侧，中间一条 14pt 竖分隔线）：确认后重启 DSH 桌面端，界面上不再需要 Cmd+Q 再手动打开。确认框用 `NSAlert.runModal()` 而不是 SwiftUI `.alert`——面板挂在 `desktopIconWindow + 1` 桌面层级，sheet 会被普通窗口盖住。
- bridge 新增 `POST /v1/dsh/restart`（device token）与 `capabilities.dshRestart`，手机端设置页可以触发同一个动作。响应先回 200 再动手：这个请求由即将被重启的进程处理，不先回就发不出响应。

### Changed

- **重启改由一次性 launchd job 执行**：桌面端 `launchctl submit -l com.ryankiin.dshwidget.restart`、bridge 端 `com.ryankiin.dshwidget.bridge-restart`，脚本内按序「取主进程 pid（`ppid == 1`，不是 `/v1/health` 返回的 Host 子进程）→ `kill -TERM` → 等其消失 → `open -n -a` → 轮询新进程出现 → 末尾 `launchctl remove` 自清」。起因是实测发现：从普通进程（App 本身，或 DSH 进程树里 `spawn(detached)` 的脚本）在 DSH 刚被 `SIGTERM` 的瞬间发起 `open` / `NSWorkspace.openApplication`，**请求会被 LaunchServices 静默丢弃**——退出码 0、进程没出现、系统日志里连一条 launch 记录都没有；`createsNewApplicationInstance = true`、`open -n` 均无效，直接 exec 二进制则被系统 `SIGKILL`。同一时刻从 launchd job 里执行同样的 `open -n -a`，一秒内就起来。

### Fixed

- 桌面端点重启后状态栏「闪一下绿 → 断约 3 秒 → 再变绿」：等待逻辑改为先确认主进程真的消失（最多 20 秒），再开始计「已连上」，期间一直是「重启中…」。
- `src/scripts/test-reconnect.sh` 的 `cut` 场景断言过时：它要求 `settle reason=reconcile`，而这个 reason 早已改名为 `reconcile-idle`，且只在宿主仍上报 busy 时才触发（那由 `stall` 场景覆盖）。改为断言「确实发生了结算且 `last=12`」，不锁死具体 reason。

## [0.7.0] - 2026-10-26

### Added

- **DSH 设置页新增「Widget」一栏**（`src/bridge/panel.js` + `src/bridge/client.js`）：一行 `DSHWidget.app` 状态（未运行时给「启动」按钮，点了直接用 `open -b` 拉起），下面是「生成配对码」——点一下就地生成二维码、6 位码与 120 秒倒计时，过期显示「已过期」并给「刷新」，不自动重发；码下方一行显示二维码里带的地址（局域网 · 公网），公网不通时标「公网未连接」，不至于扫了才发现连不上。
- 二维码由 `src/bridge/qr.js` 现场编码（byte 模式、ECC M、版本 1–10、单 path SVG），不引第三方依赖——本机没有 `qrencode`，宿主也不是浏览器环境，图标库里没有现成的编码器；版本 1–10 全部用 Vision 解码验过。
- 宿主侧路由 `GET /widget-panel/status`、`POST /widget-panel/app/launch`、`POST /widget-panel/pair`：每条 handler 先过 `connection.requestRejection`，POST 只收 `application/json` 且 body 上限 16 KiB。
- `package.json` 补 `exports['./client']` 与 `dsh.client`，宿主按 `dsh.client` 自动发现浏览器半边并注册 `settings.section`（id `desktop-widget`，order 35）；`cordis.patch.yml` 不用动。
- `WidgetBridge.pairingTicket()`：把「开票 + 候选地址 + URI」收成一处，`POST /v1/pair/start` 与设置页面板共用，审计照记。

### Changed

- 设置页那一栏只做「配对」与「启动 App」，不提供退出 App、也不提供隧道开关：DSH Web 只监听 127.0.0.1，这一栏只能在 Mac 本机打开，出门在外的场景本来就够不到它。隧道与退出的控制留在 Mac App 里。

## [0.6.0] - 2026-10-26

### Added

- `GET /v1/sessions` 默认隐藏 0 消息的空会话（`blank: true`，`?includeBlank=1` 保留全部），未分组列表与 `GET /v1/workspaces` 的 `sessionCount`/`runningCount` 同步剔除。起因：手机列表 68 条里 59 条是空会话，AI-Work 显示 11 条点开只有 5 条有内容——都是「首页点一下就新建」留下的壳。
- 未读黄灯改由 bridge 兜底：bridge 每 5 秒观察一次运行状态，把「在跑 → 不跑」记成 `endedAt`（ms），`GET /v1/sessions` 每行带上该字段；新增 `POST /v1/sessions/{id}/read` 供手机清灯。起因：App 被系统回收后重启会丢本地基线，那一次翻转就补不回来。
- `GET /v1/sessions` 默认隐藏 subagent 会话（`origin: "subagent"`，`?includeSubagents=1` 保留全部），未分组列表与 `GET /v1/workspaces` 的 `sessionCount`/`runningCount` 同步剔除。起因：手机工作区里出现一批电脑上找不到、点开就 409 的会话——它们是 subagent 委派会话（history 报 `subagent Sessions require their durable parent address`），而 `normalizeSession` 当时把 `origin`/`parentSessionId` 丢了，客户端无法区分。

### Fixed

- `GET /v1/workspaces` 的 `runningCount` 恒为 0：`controller.list()` 的行只有 `sessionId` 没有 `id`，收集 running 集合时改取 `row.sessionId ?? row.id`；`test-mock.mjs` 补了 runningCount 的回归断言。

### Changed

- 隧道日志不再写 `/tmp`，统一到 `~/Library/Logs/dshwidget/`：`cloudflared.log`（超过 5 MB 自动轮转为 `.1`）、`tunnel.out.log`、`tunnel.err.log`、`cloudflared.pid`；`install-launchd.sh` 重新安装时也会轮转旧文件。`/tmp` 重启即清空，放那里既留不住证据也看不出长期趋势。

## [0.5.0] - 2026-10-25

### Fixed

- **打开大会话卡顿**：首屏不再 `/history?all=1` 全量拉取，改为约 200 条的窗口，窗口上沿「加载更早」按需向前翻页；`Transcript` 从逐条 O(n²) 文本比较改成一次遍历建索引（id/seq/turn+step/pendingUser/text），相似度只扫尾部 80 条；`applyHistory` 用 `Set` 判重；Markdown 解析结果进 `NSCache`（400 条上限）。562 条会话的打开时间从数十秒降到首屏直出。
- **「思考中」不收敛**：`assistant_end`/`turn_end` 现在清掉所有 `streaming` 标记（原来只清命中 `streamingID` 的那条，`turn=-1 step=-1` 的流式块会把气泡永久钉在 streaming），对账条件补上 `activity.isRunning`，静默 3 秒后允许自愈补拉，不再被 `hasStreamingBubble` 永久挡住。

### Added

- bridge 的 `GET /v1/sessions/{id}/history` 新增窗口语义：不传 `all`/`after`/`before` 时由 `readWindow` 从尾部向前翻页、攒够 `limit` 条再返回，并给出 `oldestSeq`/`hasMore`，客户端据此显示「加载更早」。
- App 消息区顶部新增「加载更早」按钮（加载中转圈）；`BridgeClient.history` 支持 `before` 参数。

## [0.4.0] - 2026-10-25

### Added

- 隧道改为 macOS 用户级常驻服务：新增 `src/scripts/install-launchd.sh`（install/status/uninstall）与 `tunnel.sh run` 前台模式。脚本副本装到 `~/Library/Application Support/dshwidget-tunnel/`（`~/Documents` 受 TCC 保护，launchd 直接读那里会 `Operation not permitted`，退出码 126），plist 落 `~/Library/LaunchAgents/com.ryankiin.dshwidget.tunnel.plist`，`RunAtLoad` + `KeepAlive`。起因：隧道是 DSH 派生的子进程，`nohup` 挡不住 DSH 退出时的进程树清理，每次 Cmd+Q 都会被 SIGTERM 带走、域名再变、蜂窝必断。
- `tunnel.sh run` 每 15 秒比对一次 discovery 里的端口，bridge 换端口就自行退出、由 launchd 用新端口重建。

- 重连回放这一轮已产生的思考（`reasoning_replay`）：bridge 在内存里缓存正在流出的 `reasoning-delta`（按 `attemptId:index` 去重，同一会话多订阅者不会重复拼接；`assistant/message` 落库的整段覆盖缓存），新订阅者连上时在 `ready` 之后补发一条 `reasoning_replay`（`turn`/`step`/`text`/`startedAt` 毫秒），`turn/end` 清空。配合 iOS 端的 `BridgeEvent.reasoningReplay` 与 `ThinkingState`，解决「切后台/退会话再进来，思考框是空的、计时从 0 重来」。

- 新增 `GET /v1/endpoints`（需设备 token）：返回此刻的候选地址（局域网 + 隧道）。配合 iOS 端 `BridgeClient.endpoints()` 与 `AppEnvironment.refreshCandidates()`——手机每次连上（在家 Wi-Fi 即可）就把候选地址刷新成最新的，quick tunnel 重建换了域名也不用重新扫配对码。

- 隧道地址改为运行时可换：bridge 每次 `pair/start` 都重读 `~/.dsh/widget-public-url`（`runtimePublicUrl`），磁盘上有值就覆盖启动配置里的 `publicUrl`；换隧道、换网络都不用重启 DSH。`cordis.patch.yml` 里不再写死地址。
- 新增 `src/scripts/tunnel.sh start|status|stop`：起 Cloudflare quick tunnel → 抓分配到的地址 → 写 `~/.dsh/widget-public-url`（0600）→ 探测 `/v1/health`（本机 DNS 被代理拦时用 `dig @1.1.1.1` 取 IP 再 `curl --resolve` 兜底，200 与 401 都算通）。端口默认跟随 `~/.dsh/widget-bridge.json` 里的实际端口，bridge 换端口后重跑 `start` 会自动重建隧道；`stop` 同时删地址文件，避免手机拿到死链。

- SSE 事件带 `id:`（单连接内单调序号），并接受 `Last-Event-ID` 请求头（当前只记日志，跨连接回放留给云网关阶段）；旧客户端忽略未知行，无行为变化。

- bridge 的工作区与归档能力，供 iOS 端做两级导航：
  - `GET /v1/workspaces` 返回 `{id,title,path,sessionCount,updatedAt}`，按更新时间倒序；title 为空时用路径尾段。
  - `GET /v1/sessions` 每项补 `workspaceId` 与 `archived`；**默认隐藏归档会话**（`?includeArchived=1` 可关），支持 `?workspaceId=` 过滤。
  - 不属于任何工作区的旧会话归入合成的「未分组」桶（`__ungrouped`），避免它们从手机上消失。
  - `capabilities` 增加 `workspaces`、`archivedFilter`。
  - 端口被占用（EADDRINUSE）时回退随机端口而不是整个 bridge 起不来；`cordis.patch.yml` 固定 `port: 49827`。
- bridge 具备公网访问前置能力（协议 version 1 → 2，旧客户端不受影响）：
  - 设备配对：`POST /v1/pair/start`（需主 token）开 120 秒的 6 位码窗口，`POST /v1/pair/claim {code, name}` 换取设备 token；码单次使用、错 10 次锁定，明文 token 只返回一次，磁盘上只存 sha256。
  - 设备管理：`GET /v1/devices` 列出设备，`DELETE /v1/devices/{id}` 立即吊销。
  - 限流：每 IP 60 秒 240 次、全局 1200 次，超限 429 + `retry-after`；未认证请求连续失败 10 次锁 5 分钟。
  - 审计：`~/.dsh/widget-audit.log`（JSONL、0600、2 MB 轮转）记录 ip/方法/路径/状态/耗时与设备。
  - `GET /v1/health` 增加 `publicMode` 与 `capabilities` 对象（配对、设备吊销、图片上限、reasoning、toolTrace、push=false）。
  - 带 `Origin` 的请求一律拒绝；`POST /v1/push/register` 预留返回 501。
  - 协议文档 `docs/protocol.md` 升到 v2，并同步到 iOS 仓副本。
- 新增 `src/bridge/security.js`（配对窗口、设备存储、限流器、审计日志）；bridge 测试新增配对、设备、吊销、501 与限流用例。
- `GET /v1/sessions/{id}/history` 新增 `before=<seq>`：返回比该 seq 更早的一页（取最靠近 `before` 的 `limit` 条），`hasMore` 表示是否还有更早，供客户端向上翻历史；不传 `all`/`after`/`before` 时仍是尾部快照。协议文档同步。

- 配对二维码：`POST /v1/pair/start` 的响应在票据之外新增 `addrs` 与 `uri`。
  - `addrs`：`lanAddresses(port)` 枚举 `networkInterfaces()` 里非 internal 的 IPv4（跳过 169.254. 链接本地），形如 `http://192.168.1.18:49827`；配置了 `publicUrl`（或环境变量 `DSH_BRIDGE_PUBLIC_URL`）时追加该地址；一个都没有时回落 `http://127.0.0.1:<port>`。
  - `uri`：`dshwidget://pair?v=1&u=<addrs[0]>&c=<6 位码>`，多地址时再带 `a=<addrs.join(",")>`，手机扫一次即拿到全部候选地址。
- Mac 端「手机配对」卡片（`src/macos/DSHWidget/PairingView.swift`）：header 新增二维码按钮，卡片里是白底二维码（Core Image `qrCodeGenerator`，纠错级 M、8 倍放大）、`479 878` 形式的配对码与复制按钮、按秒刷新的有效期倒计时、前 3 个地址（标首选/备用）、「重新生成」。`BridgeClient.startPairing()` 对应 `POST v1/pair/start`；`WidgetModel.startPairing()` 在桥还没连上时先等最多 3 秒再请求，避免首次点击直接报「DSH 返回了无效响应」。
- `test-mock.mjs` 新增 8 条配对 URI 断言（前缀、`v`/`u`/`c` 取值、`addrs` 与 `a` 的一致性）。

### Fixed

- iOS 思考更新太碎：DSH 实测每秒约 8 片 `reasoning_delta`，原实现每片都整条复制一次消息列表，长回复下渲染追不上真实进度（表现为移动端还在思考、桌面已经答完，然后突然追平）。改为 120ms 合并写一次气泡；`reasoning_block`、`reasoning_replay`、`turn_end` 到来时立即冲刷，最终文本不丢。

- 隧道脚本在 macOS 自带 bash 3.2 上会静默退出：`tunnel_url_from_log` 第一次循环时日志里还没有地址，`grep` 退出码 1 经 `pipefail` + `set -e` 直接把脚本干掉，表现是只打印「等待分配地址…」就结束、地址文件仍留着旧域名。函数尾部补 `|| true` 兜住。

- 状态行残留：iOS 端「已回复结束但仍显示思考中」的根因是 `turn_end` 只在流里到达，断线、切后台或切走会话都会错过它，`ThinkingState` 于是永远停在 `.thinking`，会话列表也一直显示运行中。bridge 的 `ready` 帧新增 `running`（订阅时服务端的真实状态，取 `controller.list()` 里该会话的 `row.running`）；iOS 每次（重）连用它和服务端对账：服务端已 idle 就把残留状态收掉并补做 `settleBubbles()` 与思考回填，服务端还在跑就把状态行恢复出来。旧 bridge 不带该字段，客户端行为不变。

- 客户端请求的条数少于 20 时，`history` 返回 400、SSE 返回 `error` 事件，文案是 `turnWindow.minMessages must be a positive safe integer no greater than maxMessages`：固定窗口的 `minMessages`(20) 大于 `maxMessages`(limit)。新增 `turnWindowFor(limit)` 把 `minMessages` 压到请求值，4 处 `follow/page` 全部改用它；测试里 mock controller 增加 `minMessages <= maxMessages` 断言与 `limit=3` 的回归用例。iOS 端另加 `BridgeClient.windowSafe(_:)` 下限兜底，连旧 bridge 也不会失败。

## [0.2.0] - 2026-10-24

> 2026-10-24：本版（消息图片缩略条与查看器翻页、输入框逐行增高、粘贴图片、图片拖放、409 修复、同轮重复气泡与尾部重复修复、会话运行状态行与工具流水等）已通过用户验收，并已发布（tag `v0.2.0`，GitHub Release 附 DMG 与 SHA256）。

### Added

- 运行工具时的工具流水：状态行下方最多保留最近 3 个工具调用（和思考尾巴同样是「最近 3 步」，但一步 = 一次调用，参数摘要不限行数、完整折行，结果只留第一行）——5pt 圆点（运行中蓝、已完成绿、失败黄）+ 摘要标题（代码/命令/搜索/读取/写入/编辑）+ 参数摘要（run_code 取 description，bash 取 command，grep 取 pattern，read/write/edit 取 file_path，压成一行、超 300 字截断；正在运行的调用完整展开并标「运行中」，已完成的收束到 4 行）+ 耗时；只显示工具阶段，思考阶段仍是思考尾巴，生成阶段两者都不显示。bridge 的 `tool_call` 帧新增 `detail` 字段（`summarizeToolArguments`）。
- 修「回复写完后又多出一段尾部文字」：流式气泡还没结束就被 reconcile 判成 idle，settle 收掉 streaming 标记后，尾部补拉把完整回复当新消息追加；同时 addingSynced 在 history 带 turn/step、本地流式气泡不带时直接放弃匹配。现在 matchIndex 在步骤匹配失败后回落文本相似度，相似度判定增加「后半段是完整正文的后缀」这一支，并给 settle 加 2.5 秒静默期（同一步内不会误判）。
- 状态行的位置改为「生成中的气泡之上」：正在流式的那条回复还没写完时，状态行紧挨在它上面（上面是生成状态、下面长气泡），没有流式气泡时才落在会话末尾。它不挂在任何已完成的气泡上，所以气泡增长不会把它顶走，也不会贴到旧回复上方。
- 状态行顶部加 0.5pt 分隔线；思考尾巴只在「思考中」阶段显示，进入「生成回答」后隐藏——正文已开始流式，尾巴贴在其下容易被看成第二条回复。
- 秒格条可见窗口抽成 `ThinkingActivity.visibleRange(progress:capacity:)`：窗口随进度左移，最多画一屏刻度，进度再长也不会出现空区间。
- 会话运行时的「思考中」状态行：灯（思考/生成绿 #5FD68F、跑工具蓝 #6FB6FF、等待黄 #F0C36D，0.9 秒呼吸一次）+ 动作名（思考中 / 运行 <工具名> / 生成回答）+ 从本段开始计时的「已用 Ns」+ 满宽秒格条（每 0.1 秒一格、状态行 20 fps 刷新、最新一格按实际时间连续生长；铺满后触边清空、从左边重新读条）+ 右侧固定的「第 N 步」，整个 turn 期间常驻，结束时淡出。
- 状态行下方「思考尾巴」：保留最近 3 步思考（2 段归档 + 当前 1 段），当前段完整向下展开、不截行，切换到下一步后归档收束为 4 行；每步前面一个 7pt 绿灯（历史常亮、当前呼吸），旧步文字压暗、当前步末字带光标；reasoning 为空则整条隐藏。
- 点状态行展开最近 3 步时间线（思考摘要 / 工具名 + 耗时 / 结果一行），再点收起；数据来自 bridge 新转发的 reasoning_delta、tool_call、tool_result。
- bridge：streamEvents 转发 reasoning-delta（→ reasoning_delta）与 tool/call、tool/result 事件（→ tool_call、tool_result），tool 结果正文截到 300 字；新增 turn/end → `turn_end`（状态行在回合结束时的收起依据）。
- bridge 新增 `reasoning_block`：DSH 把每一步的完整 reasoning 落在 `assistant/message` 里，某些回合并不推送 reasoning-delta 分片；现在提交消息到达时补发一条 `reasoning_block`，App 用它替换尾巴（替换而非追加，不会与分片重复）。
- Composer: 图片文件可直接拖进输入框（`NSDraggingDestination`，接受 png/jpeg/webp/gif/heic/tiff/bmp），读成 `ComposerImage` 进入待发送缩略条，和文字一起发送；非图片文件不拦截，仍交给 AppKit。事件日志新增 `composer-drag-enter` / `composer-drop`。文件类型过滤抽成 `ComposerDrop`（纯函数，5 条单测），单测总数 37 → 42。

- 输入框支持多行草稿：Enter 发送、Shift+Enter 换行（Option/Control+Enter 也换行；输入法组词时回车交给输入法）。
  输入框改为 AppKit 自绘 `NSTextView`，替换原 SwiftUI `TextField`。
- 输入框高度跟随草稿行数：默认一行（30pt），每换一行长高一行，约 7 行（140pt）后内部滚动，发送或清空后回到一行。
- 点击消息里的缩略图打开应用内查看器：黑底大图，同一条消息内的图片可用 ←/→ 翻页并显示标题与「2 / 3」计数；点空白 / ✕ / Esc 关闭；右键仍保留「在预览中打开」。
- 消息图片改为缩略条：56×56 缩略图排成一行（最多 9 格，超过时第 9 格压暗显示 +N），单图也是 56pt；缩略条在文字气泡上方、按消息一侧对齐，纯图消息不再画空气泡。
- 输入框支持直接粘贴图片（⌘V），与文字一起发送：最多 6 张、长边压到 1600px（PNG 超 4MB 自动转 JPEG），缩略图右上角 ✕ 可单独移除；没有文字也能只发图。
  bridge 的 prompt 路由新增 `images`，以编码图片块转给 DSH 的 prompt admission 落库；乐观气泡先显示本地预览，回显后按附件 id 加载。
- 消息间距按角色区分：同一角色的连续消息 6pt，角色切换 16pt，长对话的段落感更清楚。
- `~/.dsh/widget-events.log`：只记连接、重连、快照合并、结算、补拉等事件名与计数，不记消息正文；
  `DSHWIDGET_EVENT_LOG=off` 可关闭。
- Markdown 支持竖线表格：表头加粗、分隔行、按列对齐；单元格里的行内格式仍生效。
- 代码块右上角复制按钮（点击后变勾选）、整条消息复制（悬停气泡时出现）、流式回复的脉冲小点、表格最大宽度 560pt。
- 图片附件输出：bridge 解析消息里的 `image` 内容块、新增只读 `GET /v1/attachments/{id}`（校验 sha256 + 路径白名单）；App 按附件 id 加载缩略图，加载失败显示占位。
- 会话菜单给「正在运行 agent」的会话加绿色圆点（bridge 已有 `running`；菜单用带颜色的 `AttributedString` 渲染，空闲会话不变）。
- 会话列表轮询改为自适应：空闲 5 秒、有会话运行中 2 秒；选中会话收到 `assistant_start` / `assistant_end` 时绿点**即时**翻转，不再等下一次轮询。

### Fixed

- 修「生成结束的一瞬间又分出一个气泡」（第二次）：思考/工具期间长时间没有正文分片时，3 秒对账会在 DSH 已经 idle 的两次观测后把流式气泡结算成普通消息，随后补拉把完整回复当新消息插入，屏幕上就有两条。现在对账遇到 idle 只做静默补拉（`silentSyncHistory`），流式气泡存在时补拉直接跳过（`tail-sync-skip`），结算只保留给「快照非 running」与 2.5 秒静默期两条路径。
- 一条回复在小组件里被拆成两个气泡、同一段文字出现两遍：同一条答案可能经两条路径各来一次（SSE 提交消息与 /history 补拉），彼此的 id、seq、turn/step 都可能对不上，旧的合并只会 append。现在合并与补拉都增加文本相似兜底——同角色、正文 ≥ 40 字且一方完整包含另一方（短/长 > 0.8）时视为同一条，保留较长文本；同时不再用空的 turn/step 覆盖已有标记。单测新增 4 条断言。
- 状态行在步骤之间整行消失：原先它只挂在流式气泡上，每步 `assistant_end` 一到气泡就变普通消息、状态行随之不见（工具执行期间最明显）。现在它不挂任何气泡，由 bridge 新增的 `turn_end`（DSH `turn/end` 事件）统一收起；隔离 fixture 验证「工具执行中蓝灯常在 → turn 结束才淡出」。
- 长时间运行的回合（约 20 秒后）小组件崩溃（SIGTRAP，栈在 `TickStripView` 的 Canvas）：秒格条的可见窗口按 `firstVisible..<lastVisible` 遍历，进度超过两屏后 `firstVisible > lastVisible`，Swift 的 Range 反转直接 trap。现在窗口由 `visibleRange` 计算并夹紧，单测 92 → 97（新增 5 条覆盖空条、半满、满窗滑动、超长回合、容量为 0）。
- 修复带图消息被 DSH 拒绝（HTTP 409 `session/agent-busy`）：bridge 不再预先把图片解析成附件引用，改为把编码图片原样交给 DSH 自己的 prompt admission 落库；DSH 对已解析的块会二次 admission 失败，并把它统一包成 agent-busy。2026-10-23 真机验证：文字 + 3 张图成功收入会话，附件落库、小组件回显、输入框清空。
- SSE 长连接断开期间完成的回复不再丢失：重连后的 `snapshot` 改为按 id/seq/turn+step 合并进现有转录，
  不再整段丢弃；新增 3 秒对账与 `/history?after=<seq>` 静默补拉，空气泡会自行清算。
- SSE 资源超时从 1 小时放宽到 24 小时，并新增 60 秒无字节的 stall 看门狗（睡眠唤醒后的假连接也能重连）。
- 消息区不再在流式输出时把正在回看的读者拽回底部：只在贴着底部时自动跟随；上滑后暂停，右下角出现「回到底部」小箭头，滑回底部自动恢复。

### Changed

- 思考尾巴按「最近 3 步」显示：每步前面一个 7pt 绿灯——已经想过的步常亮不闪，当前这一步按 0.9 秒呼吸，历史步文字压到 0.62，一眼能分清「想完了」和「正在想」。
- 秒格条再加速并改为连续流动：0.25 秒一格改为 0.1 秒一格（每秒 10 格），状态行刷新从 0.5 秒提到 0.05 秒，秒格条改用 Canvas 绘制、最新一格按下一次整格前的实际时间连续生长；铺满后窗口向左滑动、不再清空重来（2026-10-23 23:5x 按反馈改回触边重读）。
- 尾巴最多显示 3 步（tailRounds = 2 归档 + 当前 1 段），超出时最早的一段被挤出；尾巴绿灯改用 0.15 秒一帧刷新，呼吸更连贯。
- 修「换步之后只剩当前轮」：3 秒对账会把状态机短暂置为 settled，下一步开始时旧逻辑会清空归档。现在只有换 turn 才清空，同 turn 内续步会先把上一段思考推进归档（`pushRoundIfNeeded`）。
- 纯函数测试共 114 条（转录合并/结算/补拉、键盘规则、滚动跟随、缩略条布局、拖放文件类型过滤、思考状态机的尾巴/秒格条/计时/阶段切换），`./src/scripts/test-reconnect.sh --unit` 可离线运行。
- 助手气泡改为按内容收缩（原先强制撑满整行），底色 0.07 → 0.09；短回复不再是大色块，长回复照常换行。

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
