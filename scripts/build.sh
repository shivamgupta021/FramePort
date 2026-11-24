#!/bin/zsh
set -eu
cd "${0:A:h:h}"
app_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' Info.plist)
executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' Info.plist)
bundle=${APP_BUNDLE:-${FRAMEPORT_BUNDLE:-build/$app_name.app}}
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp Sources/Motion.metal "$bundle/Contents/Resources/"
xcrun clang -arch arm64 -O2 -Wall -Wextra -Wno-unused-parameter -fobjc-arc -mmacosx-version-min=26.0 -ISources \
  Direct/*.m Sources/Video.m Sources/MetalMotion.m Sources/Cadence.m \
  -framework Cocoa -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework ScreenCaptureKit \
  -framework QuartzCore -framework CoreImage -framework CoreGraphics -framework Metal -framework VideoToolbox \
  -o "$bundle/Contents/MacOS/$executable"
cp Info.plist "$bundle/Contents/"
cp LICENSE "$bundle/Contents/Resources/"
signer=${APP_SIGN_IDENTITY:-${FRAMEPORT_SIGN_IDENTITY:--}}
sign_flags=()
if [[ "$signer" != "-" ]]; then
  sign_flags=(--options runtime --timestamp)
fi
codesign --force --sign "$signer" "${sign_flags[@]}" --entitlements macOS.entitlements "$bundle"
codesign --verify --strict "$bundle"
echo "Built ${bundle:A}"
