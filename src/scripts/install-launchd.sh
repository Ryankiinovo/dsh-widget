#!/usr/bin/env bash
# 把隧道装成 macOS 用户级常驻服务（launchd）。
#
# 为什么不直接让 launchd 跑项目里的 tunnel.sh：~/Documents 受 TCC 保护，
# launchd 拉起 /bin/bash 读那里的脚本会 Operation not permitted（exit 126）。
# 所以脚本复制一份到 ~/Library/Application Support/ 下，plist 指向副本。
#
#   ./src/scripts/install-launchd.sh          安装 / 更新并启动
#   ./src/scripts/install-launchd.sh status   看状态
#   ./src/scripts/install-launchd.sh uninstall 卸载
set -euo pipefail

LABEL="com.ryankiin.dshwidget.tunnel"
DEST_DIR="$HOME/Library/Application Support/dshwidget-tunnel"
DEST="$DEST_DIR/tunnel.sh"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
SRC="$(cd "$(dirname "$0")" && pwd)/tunnel.sh"
LOG_DIR="$HOME/Library/Logs/dshwidget"

say() { printf '%s\n' "$*"; }
uid_num() { id -u; }

install_service() {
  mkdir -p "$DEST_DIR" "$(dirname "$PLIST")" "$LOG_DIR"
  # launchd 自己不会切日志：装/更新时把旧文件挪成 .1，避免无限增长。
  for f in "$LOG_DIR/tunnel.out.log" "$LOG_DIR/tunnel.err.log"; do
    if [ -f "$f" ] && [ "$(wc -c <"$f" | tr -d ' ')" -gt 5242880 ]; then mv -f "$f" "${f}.1"; fi
  done
  cp "$SRC" "$DEST"
  chmod 755 "$DEST"
  say "脚本副本：$DEST"

  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${DEST}</string>
		<string>run</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>10</integer>
	<key>StandardOutPath</key>
	<string>${LOG_DIR}/tunnel.out.log</string>
	<key>StandardErrorPath</key>
	<string>${LOG_DIR}/tunnel.err.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
	</dict>
</dict>
</plist>
PLIST
  say "plist：$PLIST"

  # 先停掉手工起的隧道，避免两条抢同一个 bridge
  pkill -f 'cloudflared tunnel --url http://127.0.0.1' 2>/dev/null || true
  rm -f "$LOG_DIR/cloudflared.pid"
  sleep 1

  launchctl bootout "gui/$(uid_num)/${LABEL}" 2>/dev/null || true
  launchctl bootstrap "gui/$(uid_num)" "$PLIST"
  launchctl enable "gui/$(uid_num)/${LABEL}"
  say "已交给 launchd。等 20 秒后看状态：$0 status"
}

status_service() {
  launchctl print "gui/$(uid_num)/${LABEL}" 2>/dev/null | grep -E 'state|pid =|last exit' | head -6 || say "服务未安装"
  say "---"
  "$SRC" status || true
}

uninstall_service() {
  launchctl bootout "gui/$(uid_num)/${LABEL}" 2>/dev/null || true
  rm -f "$PLIST"
  "$SRC" stop || true
  say "已卸载 launchd 服务；脚本副本留在 $DEST（可以删）"
}

case "${1:-install}" in
  install) install_service ;;
  status) status_service ;;
  uninstall) uninstall_service ;;
  *) say "用法：$0 install|status|uninstall"; exit 1 ;;
esac
