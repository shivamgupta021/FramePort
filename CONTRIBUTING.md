# Contributing

Build on Apple silicon with the macOS 26 SDK.

```sh
./scripts/build.sh
./scripts/check-video.sh
```

GitHub Actions builds and verifies the app signature. Run the video checks on a physical Mac to exercise Metal, VideoToolbox, color consistency, and playback of captured samples.

Capture and the metrics dashboard live in `Direct/Main.m`. `Direct/MeasuredPreview.m` handles frame selection and presentation. `Direct/PlaybackPicture.m` manages SDR color and upscaling. Frame generators and Metal shaders live in `Sources/`.

Open a focused pull request and describe the behavior, the checks you ran, and the hardware when relevant. For timing changes, use the same source and display settings across trials. Record capture and presentation rates, generated FPS, gaps between presentations, and the endpoints of each latency measurement. Keep recordings and installers out of source commits.

## How playback works

AVFoundation receives the 1080p feed. Frame generation selects pairs of source pictures, uses VideoToolbox interpolation at 720p as a motion guide, and reconstructs a 1080p midpoint with Metal. Core Image scales each picture to fit the drawable while preserving the aspect ratio. A 16:9 feed can fill a 2560 × 1440 display in full screen.

## What the latency number measures

The overlay reports the mean delay from the capture sample timestamp to Metal-confirmed presentation. Its second reading starts at the capture callback. Controller response, console rendering, any time the capture card spends before timestamping, and panel response fall outside the measurement.

## Comparing interpolation modes

Earlier local experiments replayed 72 held-out gameplay pictures on an M4 Pro. Mean midpoint generation time was 11.72 ms for Detail and 5.44 ms for experimental Fast Metal. Mean absolute luma error at reference edges was 17.22 and 25.19 respectively on an 8-bit scale. The 0.1 app uses Detail.

## Disk images

Run `./scripts/package-dmg.sh` for an ad-hoc signed disk image. The script builds an arm64 app, verifies the disk image, and saves a local checksum in `dist/`. For distribution with Developer ID and notarization, set `APP_SIGN_IDENTITY` and `APP_NOTARY_PROFILE` and run `./scripts/package-dmg.sh --release`.
