#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p build
xcrun clang -O2 -Wall -fobjc-arc -mmacosx-version-min=26.0 -IDirect -ISources \
  Tests/PlaybackSettingsCheck.m Direct/PlaybackSettings.m Direct/PlaybackPicture.m Sources/Video.m Sources/MetalMotion.m \
  -framework Cocoa -framework CoreGraphics -framework CoreMedia -framework CoreVideo -framework CoreImage \
  -framework Metal -framework VideoToolbox -framework QuartzCore -o build/check-settings
./build/check-settings
cp Sources/Motion.metal build/
xcrun clang -O2 -Wall -fobjc-arc -mmacosx-version-min=26.0 -IDirect -ISources \
  Tests/EngineSwitchCheck.m Direct/{MeasuredPreview,PlaybackPicture,FramePresentation,SourceCadence}.m Sources/{Video,MetalMotion,Cadence}.m \
  -framework Cocoa -framework AVFoundation -framework CoreGraphics -framework CoreMedia -framework CoreVideo \
  -framework CoreImage -framework Metal -framework VideoToolbox -framework QuartzCore -o build/check-engine-switch
./build/check-engine-switch
