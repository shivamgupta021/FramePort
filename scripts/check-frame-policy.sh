#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p build
cc -O2 -Wall Tests/PresentationTimingCheck.c -o build/check-timing
./build/check-timing
xcrun clang -O2 -Wall -fobjc-arc -mmacosx-version-min=26.0 -IDirect -ISources \
  Tests/FramePolicyCheck.m Direct/{FramePresentation,SourceCadence}.m Sources/{Cadence,Video,MetalMotion}.m \
  -framework Foundation -framework CoreGraphics -framework CoreMedia -framework CoreVideo -framework CoreImage \
  -framework Metal -framework VideoToolbox -framework QuartzCore -o build/check-frame-policy
./build/check-frame-policy
