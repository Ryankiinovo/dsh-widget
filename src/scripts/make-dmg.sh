#!/bin/zsh
# Build a distributable DMG for DSHWidget.
# The DMG contains the app only; the bridge plugin is installed from source.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$ROOT/../.." && pwd)"
APP="$PROJECT/dist/DSHWidget.app"
BUILD=1

usage() {
  cat <<'USAGE'
用法：./src/scripts/make-dmg.sh [--skip-build]

默认先执行 ./src/macos/build.sh，再把 dist/DSHWidget.app 打成 DMG。
产物：dist/DSHWidget-<version>-macos-<arch>.dmg 与 .sha256

  --skip-build   使用已有的 dist/DSHWidget.app
USAGE
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --skip-build) BUILD=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
  shift
done

if [[ "$BUILD" -eq 1 ]]; then
  "$ROOT/../macos/build.sh"
fi

if [[ ! -d "$APP" ]]; then
  echo "找不到 ${APP}，请先运行 ./src/macos/build.sh" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCH="$(uname -m)"
OUT="$PROJECT/dist/DSHWidget-${VERSION}-macos-${ARCH}.dmg"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/dshwidget-dmg.XXXXXX")"
MOUNT=""

cleanup() {
  if [[ -n "$MOUNT" && -d "$MOUNT" ]]; then
    hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
  fi
  rm -rf "$STAGE"
}
trap cleanup EXIT

ditto "$APP" "$STAGE/DSHWidget.app"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/安装说明.txt" <<'TXT'
DSH Widget
==========

1. 把 DSHWidget.app 拖到 Applications（应用程序）文件夹。
2. 这个 App 只是桌面端；还需要安装 dsh-widget-bridge 插件：
   从项目源码目录执行 ./src/scripts/install.sh
3. 完全退出 DSH（Cmd+Q）再重新打开，让插件加载。
4. 启动 DSHWidget.app。

当前版本为 ad-hoc 签名、未公证。首次打开如果被 Gatekeeper 拦截：
右键 DSHWidget.app -> 打开；或执行：
  xattr -dr com.apple.quarantine /Applications/DSHWidget.app

只对你信任的构建做这一步。需要 macOS 14+ 和 Apple Silicon。
TXT

rm -f "$OUT" "$OUT.sha256"
hdiutil create \
  -volname "DSHWidget ${VERSION}" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$OUT" >/dev/null

hdiutil verify "$OUT" >/dev/null

MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/dshwidget-mount.XXXXXX")"
hdiutil attach "$OUT" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null
[[ -d "$MOUNT/DSHWidget.app" ]] || { echo "DMG 校验失败：缺少 App" >&2; exit 1; }
[[ -L "$MOUNT/Applications" ]] || { echo "DMG 校验失败：缺少 Applications 链接" >&2; exit 1; }
hdiutil detach "$MOUNT" >/dev/null
rmdir "$MOUNT"
MOUNT=""

shasum -a 256 "$OUT" > "$OUT.sha256"

echo "built: $OUT"
echo "sha256: $(awk '{print $1}' "$OUT.sha256")"
echo "note: ad-hoc signed, not notarized; see README for Gatekeeper instructions."
