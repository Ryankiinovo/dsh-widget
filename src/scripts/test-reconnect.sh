#!/bin/zsh
# Reconnect regression tests for the widget.
#
#   ./src/scripts/test-reconnect.sh          # unit + both end-to-end scenarios
#   ./src/scripts/test-reconnect.sh --unit   # unit tests only (fast)
#
# The end-to-end passes launch the real app against a throwaway bridge that
# breaks the event stream mid-reply in two ways:
#   cut   - the socket is destroyed (network blip / bridge restart)
#   stall - the socket stays open but goes silent (macOS sleep)
# and assert, from the app's own event log, that the finished reply is restored.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MACOS="$ROOT/src/macos"
MODE="${1:-all}"

run_unit() {
  local out=/tmp/dshwidget-transcript-tests
  swiftc -swift-version 5 -O \
    "$MACOS/DSHWidget/Models.swift" \
    "$MACOS/DSHWidget/ImageStripLayout.swift" \
    "$MACOS/DSHWidget/ThinkingActivity.swift" \
    "$MACOS/DSHWidget/Transcript.swift" \
    "$MACOS/DSHWidget/ScrollFollow.swift" \
    "$MACOS/DSHWidget/ComposerKey.swift" \
    "$MACOS/DSHWidget/ComposerDrop.swift" \
    "$MACOS/tests/main.swift" \
    -o "$out"
  "$out"
}

if [[ "$MODE" == "--unit" || "$MODE" == "unit" ]]; then
  run_unit
  exit 0
fi

run_unit

if [[ ! -x "$ROOT/dist/DSHWidget.app/Contents/MacOS/DSHWidget" ]]; then
  "$MACOS/build.sh"
fi

# run_scenario <cut|stall> <required log patterns...>
run_scenario() {
  local mode="$1"
  shift
  local work log discovery port_file bridge_log app_log bridge_pid app_pid port
  work="$(mktemp -d /tmp/dshwidget-e2e.XXXXXX)"
  log="$work/events.log"
  discovery="$work/discovery.json"
  port_file="$work/port"
  bridge_log="$work/bridge.log"
  app_log="$work/app.log"

  FAKE_BRIDGE_MODE="$mode" node "$MACOS/tests/fake-bridge.mjs" "$port_file" > "$bridge_log" 2>&1 &
  bridge_pid=$!

  local i
  for i in {1..100}; do
    [[ -s "$port_file" ]] && break
    sleep 0.1
  done
  if [[ ! -s "$port_file" ]]; then
    echo "FAIL [$mode]: fake bridge did not start"
    cat "$bridge_log"
    kill "$bridge_pid" 2>/dev/null || true
    rm -rf "$work"
    return 1
  fi
  port="$(cat "$port_file")"
  printf '{"port":%s,"token":"test-token","pid":%s}\n' "$port" "$bridge_pid" > "$discovery"

  DSHWIDGET_DISCOVERY="$discovery" \
  DSHWIDGET_EVENT_LOG="$log" \
  DSHWIDGET_TEST=1 \
  DSHWIDGET_STALL_SECONDS=3 \
    "$ROOT/dist/DSHWidget.app/Contents/MacOS/DSHWidget" > "$app_log" 2>&1 &
  app_pid=$!

  local deadline=$((SECONDS + 40)) ok=1 pattern
  while (( SECONDS < deadline )); do
    ok=1
    for pattern in "$@"; do
      if [[ ! -f "$log" ]] || ! grep -q "$pattern" "$log"; then
        ok=0
        break
      fi
    done
    (( ok == 1 )) && break
    sleep 0.5
  done

  kill "$app_pid" 2>/dev/null || true
  kill "$bridge_pid" 2>/dev/null || true

  if (( ok == 1 )); then
    echo "PASS [$mode]: reply finished while the stream was down is restored"
    grep -E "stream-(open|end|retry|stall)|snapshot|reconcile|settle|tail-sync" "$log" 2>/dev/null | sed 's/^/  /'
    rm -rf "$work"
    return 0
  fi

  echo "FAIL [$mode]: expectations not met within 40s"
  for pattern in "$@"; do
    grep -q "$pattern" "$log" 2>/dev/null || echo "  missing: $pattern"
  done
  echo "--- events ---"
  cat "$log" 2>/dev/null || echo "(no event log)"
  echo "--- app ---"
  tail -20 "$app_log"
  echo "--- bridge ---"
  tail -10 "$bridge_log"
  rm -rf "$work"
  return 1
}

failures=0
# The cut scenario is settled by the reconnect snapshot (`settle reason=snapshot`).
# The "reconcile" reason this used to assert no longer exists — that path was
# renamed to `reconcile-idle` and only fires while the host still reports busy,
# which `stall` covers. Assert the settle happened without pinning its reason.
run_scenario cut "snapshot in=2 out=2" "settle reason=" "last=12" || failures=$((failures + 1))
run_scenario stall "stream-stall" "snapshot in=2 out=2" "last=12" || failures=$((failures + 1))

if (( failures > 0 )); then
  echo "reconnect tests failed: $failures scenario(s)"
  exit 1
fi
echo "reconnect tests passed"
