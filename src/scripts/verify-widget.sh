#!/bin/zsh
# Verify the locally installed DSH widget bridge without printing its token.
set -u

LOG="$HOME/.dsh/widget-verify.log"
mkdir -p "$HOME/.dsh"
exec >>"$LOG" 2>&1
echo "=== $(date '+%Y-%m-%d %H:%M:%S') ==="

DISC="$HOME/.dsh/widget-bridge.json"
for _ in {1..30}; do
  [[ -f "$DISC" ]] && break
  sleep 1
done

if [[ ! -f "$DISC" ]]; then
  echo "FAIL: discovery file not found: $DISC"
  echo "HINT: fully quit and reopen DSH, then run this again."
  exit 1
fi

read -r PORT TOKEN <<< "$(python3 - "$DISC" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
print(data["port"], data["token"])
PY
)"

if [[ -z "${PORT:-}" || -z "${TOKEN:-}" ]]; then
  echo "FAIL: discovery file is incomplete"
  exit 1
fi

HEALTH="$(curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/v1/health" 2>&1)" || {
  echo "FAIL: health endpoint unreachable on 127.0.0.1:${PORT}"
  echo "$HEALTH"
  exit 1
}
echo "health: $HEALTH"

SESSIONS="$(curl -fsS --max-time 10 -H "Authorization: Bearer ${TOKEN}" "http://127.0.0.1:${PORT}/v1/sessions" 2>&1)" || {
  echo "FAIL: sessions endpoint rejected or unreachable"
  echo "$SESSIONS"
  exit 1
}
COUNT="$(printf '%s' "$SESSIONS" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("sessions", [])))' 2>/dev/null)" || {
  echo "FAIL: sessions response is not valid JSON"
  exit 1
}
echo "sessions: $COUNT"

if pgrep -x DSHWidget >/dev/null 2>&1; then
  echo "widget: running"
else
  echo "widget: not running (open dist/DSHWidget.app)"
fi

echo "OK: bridge is reachable and authenticated"
osascript -e 'display notification "DSH 小组件桥已连接" with title "DSH Widget"' >/dev/null 2>&1 || true
