#!/usr/bin/env bash
# Renders the README showcase images in docs/images/ from the Mac app's screenshot harness,
# which shows demo data only (sample dictations, a sample host; nothing is saved).
#
#   docs/images/src/render.sh          # build the client (Debug), capture, compose, optimise
#   docs/images/src/render.sh <dir>    # compose from captures already in <dir>
#
# Raw captures go to a temporary folder and are never committed; only the composed images
# are. Optimises with pngquant and oxipng when they are on PATH. Look at every image before
# committing: the harness reads this Mac's settings file, so check nothing personal shows.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
macos="$here/../../../apps/macos"
out="$here/.."
raw="${1:-}"

if [[ -z "$raw" ]]; then
  raw="$(mktemp -d)/raw"
  "$macos/scripts/build.sh" --app client
  name="$(sed -nE 's/^MV_DISPLAY_NAME = (.*)$/\1/p' "$macos/Config/Base.xcconfig")"
  app="$macos/build/Build/Products/Debug/$name.app"
  exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
  "$app/Contents/MacOS/$exe" --screenshots "$raw"
fi

compose() { # <capture> <theme> <output name> [compose.swift options]
  swift "$here/compose.swift" "$raw/$1-$2.png" "$out/$3-$2.png" "$2" "${@:4}"
}
for theme in light dark; do
  compose home "$theme" home
  compose models-library "$theme" models
  compose onboarding-4-model "$theme" setup --width 1200
  # The second pill in the showcase: listening, with the words so far.
  compose pill "$theme" pill --crop 239,345,1042,174 --radius 50 --pad 110 --width 1200
done

images=("$out"/{home,models,setup,pill}-{light,dark}.png)
if command -v pngquant >/dev/null; then pngquant --quality 70-92 --speed 1 --skip-if-larger --force --ext .png "${images[@]}" || true; fi
if command -v oxipng >/dev/null; then oxipng -q -o 4 --strip safe "${images[@]}"; fi
ls -l "${images[@]}"
