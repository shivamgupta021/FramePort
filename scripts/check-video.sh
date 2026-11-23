#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p build
cp Sources/Motion.metal build/
xcrun clang -O2 -Wall -fobjc-arc -mmacosx-version-min=26.0 -ISources Sources/Video.m Sources/MetalMotion.m Tests/VideoCheck.m \
  -framework Foundation -framework CoreMedia -framework CoreVideo -framework Metal -framework QuartzCore \
  -framework CoreImage -framework VideoToolbox -framework CoreGraphics -o build/video-check
xcrun clang -O2 -Wall -fobjc-arc -mmacosx-version-min=26.0 -ISources Sources/Video.m Sources/MetalMotion.m Sources/Stream.m Sources/Cadence.m Tests/CaptureCheck.m \
  -framework Foundation -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework Metal \
  -framework QuartzCore -framework CoreImage -framework VideoToolbox -framework CoreGraphics -o build/capture-check
xcrun clang -O2 -Wall -fobjc-arc -mmacosx-version-min=26.0 -ISources Sources/Video.m Sources/MetalMotion.m Tests/ContourCheck.m \
  -framework Foundation -framework CoreMedia -framework CoreVideo -framework Metal -framework QuartzCore \
  -framework CoreImage -framework VideoToolbox -framework CoreGraphics -o build/contour-check
xcrun clang -O2 -Wall -fobjc-arc -mmacosx-version-min=26.0 -IDirect -ISources Direct/PlaybackPicture.m Tests/PlaybackPictureCheck.m Sources/Video.m Sources/MetalMotion.m \
  -framework Foundation -framework CoreMedia -framework CoreVideo -framework Metal -framework QuartzCore \
  -framework CoreImage -framework VideoToolbox -framework CoreGraphics -o build/playback-picture-check
./build/playback-picture-check
./build/video-check
./build/video-check guided
./build/video-check native
./build/video-check 1440
./build/capture-check
./build/contour-check
