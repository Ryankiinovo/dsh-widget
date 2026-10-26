#!/usr/bin/env bash
# 给 DSH 小组件的 bridge 挂一条 Cloudflare 临时隧道。
#
# 地址写进 ~/.dsh/widget-public-url，bridge 每次请求都重读这个文件，
# 所以换隧道、换网络都不用重启 DSH。
#
#   ./src/scripts/tunnel.sh start    起隧道并登记地址
#   ./src/scripts/tunnel.sh status   看进程 / 登记地址 / 公网可达性
#   ./src/scripts/tunnel.sh stop     停隧道并清掉地址（避免留下死链）
set -euo pipefail

DISCOVERY_FILE="$HOME/.dsh/widget-bridge.json"
DEFAULT_PORT=49827
# bridge 每次启动可能换端口（写进 discovery），隧道必须指向它实际在听的那个。
resolve_port() {
  if [ -n "${DSH_BRIDGE_PORT:-}" ]; then printf '%s' "$DSH_BRIDGE_PORT"; return 0; fi
  local port
  if [ -f "$DISCOVERY_FILE" ]; then
    port="$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DISCOVERY_FILE" | head -1)"
  fi
  printf '%s' "${port:-$DEFAULT_PORT}"
}
URL_FILE="$HOME/.dsh/widget-public-url"
LOG_DIR="${HOME}/Library/Logs/dshwidget"
mkdir -p "$LOG_DIR"
PID_FILE="${LOG_DIR}/cloudflared.pid"
LOG_FILE="${LOG_DIR}/cloudflared.log"
LOG_MAX_BYTES=$((5 * 1024 * 1024))

# cloudflared 自己不做轮转：拉起前把超过 5MB 的日志挪成 .1（只留一代）。
rotate_log() {
  local file="$1" size
  if [ ! -f "$file" ]; then return 0; fi
  size="$(wc -c <"$file" | tr -d ' ')"
  if [ "${size:-0}" -gt "$LOG_MAX_BYTES" ]; then mv -f "$file" "${file}.1"; fi
}

say() { printf '%s\n' "$*"; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }

find_cloudflared() {
  local path
  path="$(command -v cloudflared || true)"
  if [ -z "$path" ]; then
    for candidate in /opt/homebrew/bin/cloudflared /usr/local/bin/cloudflared; do
      if [ -x "$candidate" ]; then path="$candidate"; break; fi
    done
  fi
  if [ -z "$path" ]; then die "没找到 cloudflared，先 brew install cloudflared"; fi
  printf '%s' "$path"
}

tunnel_url_from_log() {
  if [ ! -f "$LOG_FILE" ]; then return 0; fi
  # 日志里还没有地址时 grep 退出码是 1，pipefail + set -e 会让整个脚本静默退出，
  # 所以这里必须兜住失败（首次循环必然没有地址）。
  grep -Eo 'https://[a-z0-9][a-z0-9-]*\.trycloudflare\.com' "$LOG_FILE" 2>/dev/null | tail -1 || true
}

running_pid() {
  if [ ! -f "$PID_FILE" ]; then return 0; fi
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -z "$pid" ]; then return 0; fi
  if kill -0 "$pid" 2>/dev/null; then printf '%s' "$pid"; fi
}

# 返回 HTTP 码；401 也算通（请求已经打到 bridge，只是没带 token）。
probe() {
  local url="$1" host ip code
  host="${url#https://}"
  code="$(curl -s -o /dev/null -m 8 -w '%{http_code}' "$url/v1/health" 2>/dev/null || true)"
  if [ -z "$code" ] || [ "$code" = "000" ]; then
    ip="$(dig +short @1.1.1.1 "$host" 2>/dev/null | tail -1)"
    if [ -n "$ip" ]; then
      code="$(curl -s -o /dev/null -m 8 -w '%{http_code}' \
        --resolve "$host:443:$ip" "$url/v1/health" 2>/dev/null || true)"
    fi
  fi
  printf '%s' "${code:-000}"
}

write_url() {
  mkdir -p "$(dirname "$URL_FILE")"
  printf '%s\n' "$1" > "$URL_FILE"
  chmod 600 "$URL_FILE"
}

cmd_start() {
  local cf pid url code i port current_target
  cf="$(find_cloudflared)"
  port="$(resolve_port)"
  say "bridge 端口：${port}"

  pid="$(running_pid)"
  if [ -n "$pid" ] && url="$(tunnel_url_from_log)" && [ -n "$url" ]; then
    current_target="$(ps -o args= -p "$pid" 2>/dev/null | grep -o 'http://127[^ ]*' | head -1)"
    if [ "$current_target" = "http://127.0.0.1:${port}" ]; then
      write_url "$url"
      say "隧道已经在跑 pid=${pid}，复用地址：${url}"
      say "公网探测 HTTP $(probe "$url")"
      return 0
    fi
    say "隧道指向 ${current_target:-未知}，但 bridge 现在在 ${port}，重建隧道"
    kill "$pid" 2>/dev/null || true
    sleep 1
    rm -f "$PID_FILE"
  fi

  rotate_log "$LOG_FILE"
  : > "$LOG_FILE"
  nohup "$cf" tunnel --url "http://127.0.0.1:${port}" --no-autoupdate \
    --logfile "$LOG_FILE" >/dev/null 2>&1 &
  pid=$!
  printf '%s\n' "$pid" > "$PID_FILE"

  say "启动 cloudflared pid=${pid}，指向 127.0.0.1:${port}，等待分配地址…"
  url=""
  for i in $(seq 1 60); do
    sleep 1
    url="$(tunnel_url_from_log)"
    if [ -n "$url" ]; then break; fi
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
  done
  if [ -z "$url" ]; then die "60 秒内没拿到地址，日志：$LOG_FILE"; fi

  write_url "$url"
  say "隧道地址：${url}"
  say "已写入 ${URL_FILE}，bridge 每次请求都重读，不需要重启 DSH"

  code="$(probe "$url")"
  case "$code" in
    200|401) say "公网探测 HTTP ${code}，隧道已打到 bridge" ;;
    000)     say "公网探测连不上（本机 DNS 可能被代理拦），手机侧仍可能可用；稍后重跑 status" ;;
    *)       say "公网探测 HTTP ${code}，预期 200 或 401" ;;
  esac
}

cmd_stop() {
  local pid
  pid="$(running_pid)"
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    say "已停止 cloudflared pid=${pid}"
  else
    say "没有在跑的 cloudflared"
  fi
  rm -f "$PID_FILE"
  if [ -f "$URL_FILE" ]; then
    rm -f "$URL_FILE"
    say "已清除 ${URL_FILE}，避免手机拿到死链"
  fi
}

# 供 launchd 常驻用：前台跑一条 cloudflared，持续把域名写进登记文件。
# 不 nohup、不 fork 到后台——进程必须活在这个脚本下面，launchd 才能 KeepAlive。
cmd_run() {
  local cf port pid url i last_port
  cf="$(find_cloudflared)"
  port="$(resolve_port)"
  say "launchd 模式启动：指向 127.0.0.1:${port}"
  rotate_log "$LOG_FILE"
  : > "$LOG_FILE"
  "$cf" tunnel --url "http://127.0.0.1:${port}" --no-autoupdate --logfile "$LOG_FILE" &
  pid=$!
  printf '%s\n' "$pid" > "$PID_FILE"

  url=""
  for i in $(seq 1 60); do
    sleep 1
    url="$(tunnel_url_from_log)"
    if [ -n "$url" ]; then write_url "$url"; say "隧道地址：${url}"; break; fi
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
  done
  if [ -z "$url" ]; then say "60 秒内没拿到地址，等 launchd 重启（日志 ${LOG_FILE}）"; fi

  # bridge 换端口（DSH 重启）就自杀一次，交给 launchd 用新端口重建。
  #
  # 另一个失败模式：Cloudflare 会从它那侧回收 quick tunnel（日志里写
  # "Tunnel not found"）。此时 cloudflared 进程还活着、kill -0 依然成功，
  # 但公网永远连不上——只看进程存活会让手机在蜂窝下彻底失联。所以每约
  # 60 秒探一次登记地址，连续两次不通就自杀，让 launchd 换一条新隧道。
  local tick=0 bad=0 code
  while kill -0 "$pid" 2>/dev/null; do
    sleep 15
    last_port="$(resolve_port)"
    if [ "${last_port}" != "${port}" ]; then
      say "bridge 端口从 ${port} 变成 ${last_port}，重建隧道"
      kill "$pid" 2>/dev/null || true
      break
    fi
    tick=$((tick + 1))
    if [ "${tick}" -lt 4 ]; then continue; fi
    tick=0
    url="$(cat "$URL_FILE" 2>/dev/null || true)"
    if [ -z "$url" ]; then continue; fi
    code="$(probe "$url")"
    case "$code" in
      200|401) bad=0 ;;
      *)
        bad=$((bad + 1))
        say "公网探测 HTTP ${code}（连续第 ${bad} 次），隧道可能已被 Cloudflare 回收"
        if [ "${bad}" -ge 2 ]; then
          kill "$pid" 2>/dev/null || true
          break
        fi
        ;;
    esac
  done
  wait "$pid" 2>/dev/null || true
  say "cloudflared 已退出，最后登记地址：$(cat "$URL_FILE" 2>/dev/null || true)"
}

cmd_status() {
  local pid url code
  pid="$(running_pid)"
  url="$(cat "$URL_FILE" 2>/dev/null || true)"

  say "bridge 端口：$(resolve_port)"
  if [ -n "$pid" ]; then say "cloudflared 进程：${pid}"; else say "cloudflared 进程：未运行"; fi
  if [ -n "$pid" ]; then say "隧道指向：$(ps -o args= -p "$pid" 2>/dev/null | grep -o 'http://127[^ ]*' | head -1)"; fi
  if [ -n "$url" ]; then say "登记地址：${url}"; else say "登记地址：空"; fi
  if [ -n "$url" ]; then
    code="$(probe "$url")"
    say "公网探测 HTTP ${code}"
    case "$code" in
      200|401) say "结论：可用" ;;
      000)     say "结论：连不上（隧道已停，或本机 DNS 被拦）" ;;
      *)       say "结论：异常状态码" ;;
    esac
  else
    say "结论：没有登记地址，手机只能用局域网"
  fi
}

case "${1:-status}" in
  start) cmd_start ;;
  run) cmd_run ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  *) die "用法：$0 start|run|status|stop" ;;
esac
