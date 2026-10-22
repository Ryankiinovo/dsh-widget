#!/bin/zsh
set -euo pipefail

PROFILE="${DSH_PROFILE_DIR:-$HOME/.dsh/profiles/desktop}"
PATCH="$PROFILE/cordis.patch.yml"
TARGET="$PROFILE/node_modules/dsh-widget-bridge"
DISC="$HOME/.dsh/widget-bridge.json"

if [[ -L "$TARGET" ]]; then
  rm -f "$TARGET"
  echo "已移除符号链接 $TARGET"
fi

if [[ -f "$PATCH" ]] && grep -q "id: dsh-widget-bridge" "$PATCH"; then
  BACKUP="$PATCH.bak-uninstall-$(date +%Y%m%d-%H%M%S)"
  cp -p "$PATCH" "$BACKUP"
  python3 - "$PATCH" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text().splitlines(keepends=True)
out = []
i = 0
removed = False
while i < len(lines):
    line = lines[i]
    if line.strip() == "- insert:":
        j = i + 1
        block = [line]
        while j < len(lines):
            nxt = lines[j]
            if nxt.startswith("- "):
                break
            if nxt.strip() and not nxt.startswith((" ", "\t")):
                break
            block.append(nxt)
            j += 1
        if any("id: dsh-widget-bridge" in item for item in block):
            removed = True
            i = j
            continue
    out.append(line)
    i += 1
if not removed:
    raise SystemExit("未找到可移除的 dsh-widget-bridge insert 块")
path.write_text("".join(out))
PY
  if grep -q "id: dsh-widget-bridge" "$PATCH"; then
    echo "警告：patch 里仍残留 dsh-widget-bridge，未完成卸载。" >&2
    exit 1
  fi
  echo "已备份 patch 到 $BACKUP 并移除 dsh-widget-bridge 条目。"
fi

if [[ "${1:-}" == "--remove-discovery" ]]; then
  rm -f "$DISC"
  echo "已删除 discovery：$DISC"
else
  echo "已保留 discovery：$DISC"
  echo "它包含正在运行桥的 pid/port/token；确认 DSH 已完全退出后，可运行：$0 --remove-discovery"
fi
