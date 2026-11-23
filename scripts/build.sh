#!/bin/zsh
set -eu
cd "${0:A:h:h}"
bundle=${FRAMEPORT_BUNDLE:-build/FramePort.app}
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp Sources/Motion.metal "$bundle/Contents/Resources/"
xcrun clang -O2 -Wall -Wextra -Wno-unused-parameter -fobjc-arc -mmacosx-version-min=26.0 -ISources \
  Direct/*.m Sources/Video.m Sources/MetalMotion.m Sources/Cadence.m \
  -framework Cocoa -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework ScreenCaptureKit \
  -framework QuartzCore -framework CoreImage -framework CoreGraphics -framework Metal -framework VideoToolbox \
  -o "$bundle/Contents/MacOS/FramePort"
cp Info.plist "$bundle/Contents/"
codesign --force --sign - --entitlements FramePort.entitlements "$bundle"
codesign --verify --strict "$bundle"
echo "Built ${bundle:A}"
