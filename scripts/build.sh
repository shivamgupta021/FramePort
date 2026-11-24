#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
app_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' Info.plist)
executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' Info.plist)
destination=${APP_BUNDLE:-${FRAMEPORT_BUNDLE:-build/$app_name.app}}
destination=${destination:a}
mkdir -p "${destination:h}"
stage=$(mktemp -d "${destination:h}/.second-frame-build.XXXXXXXX")
bundle="$stage/$app_name.app"
cleanup() {
  if [[ -d "$stage/previous.app" && ! -e "$destination" ]]; then
    mv "$stage/previous.app" "$destination" || return
  fi
  rm -rf -- "$stage"
}
trap cleanup EXIT
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp Sources/Motion.metal LICENSE "$bundle/Contents/Resources/"
xcrun clang -arch arm64 -O2 -Wall -Wextra -Wno-unused-parameter -fobjc-arc -mmacosx-version-min=26.0 -ISources \
  Direct/*.m Sources/Video.m Sources/MetalMotion.m Sources/Cadence.m \
  -framework Cocoa -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework ScreenCaptureKit \
  -framework QuartzCore -framework CoreImage -framework CoreGraphics -framework Metal -framework VideoToolbox \
  -o "$bundle/Contents/MacOS/$executable"
cp Info.plist "$bundle/Contents/"
signer=${APP_SIGN_IDENTITY:-${FRAMEPORT_SIGN_IDENTITY:--}}
sign_flags=()
if [[ "$signer" != "-" ]]; then
  sign_flags=(--options runtime --timestamp)
fi
codesign --force --sign "$signer" "${sign_flags[@]}" --entitlements macOS.entitlements "$bundle"
codesign --verify --strict "$bundle"
if [[ -e "$destination" || -L "$destination" ]]; then
  identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Info.plist)
  if [[ -L "$destination" || "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")" != "$identifier" ]]; then
    print -u2 "Build destination is not a Second Frame app bundle: $destination"
    exit 2
  fi
  mv "$destination" "$stage/previous.app"
fi
mv "$bundle" "$destination"
print "Built $destination"
