#!/usr/bin/env bash
# Build Release and install to ~/Applications (no admin needed), then launch it.
#   scripts/install.sh                 # Bark
#   scripts/install.sh --app server    # Bark Server
#   scripts/install.sh --app all       # both
set -euo pipefail
cd "$(dirname "$0")/.."
APP="client"
if [[ "${1:-}" == "--app" ]]; then APP="${2:?--app needs client, server or all}"; fi
scripts/build.sh release --app "$APP"
names=()
case "$APP" in
  client) names=("$(sed -nE 's/^MV_DISPLAY_NAME = (.*)$/\1/p' Config/Base.xcconfig)") ;;
  server) names=("$(sed -nE 's/^MV_DISPLAY_NAME = (.*)$/\1/p' Config/Server.xcconfig)") ;;
  all) names=("$(sed -nE 's/^MV_DISPLAY_NAME = (.*)$/\1/p' Config/Base.xcconfig)" "$(sed -nE 's/^MV_DISPLAY_NAME = (.*)$/\1/p' Config/Server.xcconfig)") ;;
esac
mkdir -p "$HOME/Applications"
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }
for name in "${names[@]}"; do
  SRC="build/Build/Products/Release/$name.app"
  DEST="$HOME/Applications/$name.app"
  BUNDLE_ID="$(plist "$SRC" CFBundleIdentifier)"
  EXE="$(plist "$SRC" CFBundleExecutable)"
  osascript -e "quit app id \"$BUNDLE_ID\"" 2>/dev/null || true
  pkill -x "$EXE" 2>/dev/null || true
  rm -rf "$DEST"
  # A copy installed before the rename to Bark is named after the executable, which kept the
  # old name (Fairspoken.app, Fairspoken Server.app). Remove it if it is the same app.
  OLD="$HOME/Applications/$EXE.app"
  if [[ "$OLD" != "$DEST" && -d "$OLD" && "$(plist "$OLD" CFBundleIdentifier)" == "$BUNDLE_ID" ]]; then
    rm -rf "$OLD"
    echo "Removed the copy installed under the old name: $OLD"
  fi
  ditto "$SRC" "$DEST"
  echo "Installed: $DEST"
  open "$DEST"
done
