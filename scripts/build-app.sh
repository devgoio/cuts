#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h:h}
APP_DIR=${CUTS_APP_OUTPUT_DIR:-"$PROJECT_DIR/dist/Cuts.app"}
CONTENTS_DIR="$APP_DIR/Contents"
BUILD_DIR="$PROJECT_DIR/.build/manual"
ICONSET_DIR="$BUILD_DIR/Cuts.iconset"
SIGNING_IDENTITY=${CUTS_CODESIGN_IDENTITY:--}

if [[ "$(uname -sm)" != 'Darwin arm64' ]]; then
  print -u2 'Cuts requires an Apple silicon Mac.'
  exit 1
fi
if [[ -z "${CUTS_WEBP_PREFIX:-}" ]]; then
  if ! command -v brew >/dev/null || ! CUTS_WEBP_PREFIX="$(brew --prefix webp 2>/dev/null)"; then
    print -u2 'Install libwebp with brew install webp or set CUTS_WEBP_PREFIX.'
    exit 1
  fi
fi
for library in libwebp libsharpyuv; do
  if [[ ! -r "$CUTS_WEBP_PREFIX/lib/$library.a" ]]; then
    print -u2 "Missing static library: $library. Install libwebp with brew install webp."
    exit 1
  fi
done

mkdir -p "$BUILD_DIR" "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources" "$ICONSET_DIR"
xcrun swiftc -swift-version 5 -target arm64-apple-macos26.0 -O \
  -o "$CONTENTS_DIR/MacOS/PsnAppRebuild" \
  "$PROJECT_DIR"/Sources/PsnAppRebuild/*.swift \
  "$CUTS_WEBP_PREFIX/lib/libwebp.a" "$CUTS_WEBP_PREFIX/lib/libsharpyuv.a" \
  -framework AppKit -framework ApplicationServices -framework Carbon \
  -framework CoreGraphics -framework CryptoKit -framework ImageIO -framework ScreenCaptureKit \
  -framework ServiceManagement -framework Vision
cp "$PROJECT_DIR/Support/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR"/Support/{CutsDefault,Mosaic}.svg "$CONTENTS_DIR/Resources/"
cp "$PROJECT_DIR/LICENSE" "$CONTENTS_DIR/Resources/Cuts-LICENSE.txt"
for notice in COPYING PATENTS; do
  [[ ! -r "$CUTS_WEBP_PREFIX/$notice" ]] || cp "$CUTS_WEBP_PREFIX/$notice" "$CONTENTS_DIR/Resources/libwebp-$notice.txt"
done
"$CONTENTS_DIR/MacOS/PsnAppRebuild" --render-iconset "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$CONTENTS_DIR/Resources/Cuts.icns"
timestamp=(--timestamp=none)
if [[ "$SIGNING_IDENTITY" == 'Developer ID Application:'* ]]; then timestamp=(--timestamp); fi
codesign --force --sign "$SIGNING_IDENTITY" "${timestamp[@]}" --options runtime "$APP_DIR"
codesign --verify --strict "$APP_DIR"
print -r -- "$APP_DIR"
