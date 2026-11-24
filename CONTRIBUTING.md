# Contributing

Build on Apple silicon with the macOS 26 SDK.

```sh
./scripts/build.sh
./scripts/check-frame-policy.sh
./scripts/check-settings.sh
./scripts/check-video.sh
```

The settings and video suites exercise Metal and VideoToolbox on a physical Mac.

## Playback code

- Capture-device selection, AVFoundation, and the metrics dashboard live in `Direct/Main.m`.
- The live path enters `Direct/MeasuredPreview.m`. Source cadence and presentation policy have their own modules in `Direct/`.
- Picture rendering lives in `Direct/PlaybackPicture.m`. Frame generators and shaders live in `Sources/`.

Open a focused pull request with the behavior, the check you ran, and the hardware when relevant. For timing changes, use the same source sequence and display settings across trials. Record original and generated fps, gaps between presentations, and the start and end points of each latency measurement.

Keep gameplay footage, local app bundles, and installer files out of source commits. GitHub releases carry the DMG and its checksum.
