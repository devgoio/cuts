#!/bin/zsh
set -euo pipefail

if [[ $# -ne 3 || ( "$1" != --preview && "$1" != --release ) ]]; then
  print -u2 'Usage: zsh scripts/package-dmg.sh --preview|--release /path/to/Cuts.app /path/to/output.dmg'
  exit 64
fi
MODE=$1
APP_DIR=${2:A}
IMAGE=${3:A}
[[ "${APP_DIR:t}" == Cuts.app && -f "$APP_DIR/Contents/Info.plist" && "${IMAGE:e}" == dmg && ! -e "$IMAGE" ]] || exit 64
CUTS_VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP_DIR/Contents/Info.plist")
codesign --verify --strict "$APP_DIR"

if [[ "$MODE" == --release ]]; then
  [[ "${CUTS_DMG_SIGN_IDENTITY:-}" == 'Developer ID Application:'* && -n "${CUTS_NOTARY_PROFILE:-}" ]] || {
    print -u2 'Release requires a Developer ID Application identity and a notarytool Keychain profile.'
    exit 65
  }
  if ! codesign -dv --verbose=4 "$APP_DIR" 2>&1 | awk '/^Authority=Developer ID Application:/{signed=1} /^Timestamp=/{timed=1} END{exit ! (signed && timed)}'; then
    print -u2 'Rebuild the app with Developer ID Application signing and a secure timestamp before packaging.'
    exit 65
  fi
fi

stage=$(mktemp -d /private/tmp/cuts-dmg-stage.XXXXXXXX)
trap '[[ "$stage" == /private/tmp/cuts-dmg-stage.* ]] && /bin/rm -r -- "$stage"' EXIT
ditto "$APP_DIR" "$stage/Cuts.app"
ln -s /Applications "$stage/Applications"
volume="Cuts $CUTS_VERSION"
if [[ "$MODE" == --preview ]]; then
  volume+=' Preview'
  print 'Local preview only. Not Developer ID signed or notarized.' > "$stage/Preview.txt"
fi
hdiutil create -volname "$volume" -srcfolder "$stage" -fs HFS+ -format UDZO "$IMAGE"
hdiutil verify "$IMAGE"
if [[ "$MODE" == --release ]]; then
  codesign --sign "$CUTS_DMG_SIGN_IDENTITY" --timestamp --identifier com.psn.Cuts.disk-image "$IMAGE"
  xcrun notarytool submit "$IMAGE" --keychain-profile "$CUTS_NOTARY_PROFILE" --wait
  xcrun stapler staple "$IMAGE"
  xcrun stapler validate "$IMAGE"
  spctl --assess --type open --context context:primary-signature --verbose "$IMAGE"
fi
shasum -a 256 "$IMAGE"
