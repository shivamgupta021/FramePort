#!/bin/zsh
set -eu
cd "${0:A:h:h}"
bundle=${FRAMEPORT_BUNDLE:-build/gta60fps.app}
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp Sources/Motion.metal "$bundle/Contents/Resources/"
xcrun clang -arch arm64 -O2 -Wall -Wextra -Wno-unused-parameter -fobjc-arc -mmacosx-version-min=26.0 -ISources \
  Direct/*.m Sources/Video.m Sources/MetalMotion.m Sources/Cadence.m \
  -framework Cocoa -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework ScreenCaptureKit \
  -framework QuartzCore -framework CoreImage -framework CoreGraphics -framework Metal -framework VideoToolbox \
  -o "$bundle/Contents/MacOS/gta60fps"
cp Info.plist "$bundle/Contents/"
cp LICENSE "$bundle/Contents/Resources/"
signer=${FRAMEPORT_SIGN_IDENTITY:--}
sign_flags=()
if [[ "$signer" != "-" ]]; then
  sign_flags=(--options runtime --timestamp)
fi
codesign --force --sign "$signer" "${sign_flags[@]}" --entitlements gta60fps.entitlements "$bundle"
codesign --verify --strict "$bundle"
echo "Built ${bundle:A}"
