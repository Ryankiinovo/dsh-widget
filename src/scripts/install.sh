#!/bin/zsh
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/../.." && pwd)"
PROFILE="${DSH_PROFILE_DIR:-$HOME/.dsh/profiles/desktop}"
PATCH="$PROFILE/cordis.patch.yml"
MODULES="$PROFILE/node_modules"
TARGET="$MODULES/dsh-widget-bridge"

if [[ ! -f "$PATCH" ]]; then
  echo "找不到 ${PATCH}，请先启动一次 DSH 生成 desktop profile。" >&2
  exit 1
fi
if [[ ! -f "$PROJECT/src/bridge/index.js" ]]; then
  echo "src/bridge/index.js 不存在，项目目录不完整。" >&2
  exit 1
fi

mkdir -p "$MODULES"
if [[ -e "$TARGET" && ! -L "$TARGET" ]]; then
  echo "$TARGET 已存在且不是符号链接，停止安装，避免覆盖。" >&2
  exit 1
fi
ln -sfn "$PROJECT/src/bridge" "$TARGET"

if grep -q "id: dsh-widget-bridge" "$PATCH"; then
  echo "cordis.patch.yml 已包含 dsh-widget-bridge，跳过追加。"
else
  BACKUP="$PATCH.bak-$(date +%Y%m%d-%H%M%S)"
  cp -p "$PATCH" "$BACKUP"
  printf '\n- insert:\n    - id: dsh-widget-bridge\n      name: dsh-widget-bridge\n' >> "$PATCH"
  echo "已备份 patch 到 $BACKUP"
  echo "已向 $PATCH 追加 dsh-widget-bridge。"
fi

echo "已安装：$TARGET -> $PROJECT/src/bridge"
echo "下一步：完全退出并重新打开 DSH，然后确认 ~/.dsh/widget-bridge.json 出现。"
