# Contributing

Build on Apple silicon with the macOS 26 SDK.

```sh
./scripts/build.sh
./scripts/check-frame-policy.sh
./scripts/check-settings.sh
./scripts/check-video.sh
```

GitHub Actions builds and signs the app and checks the frame policy on macOS. Run the settings and video suites on a physical Mac to exercise Metal and VideoToolbox.

## Playback code

- Capture-device selection, AVFoundation, and the metrics dashboard live in `Direct/Main.m`.
- The live path enters `Direct/MeasuredPreview.m`. Source cadence and presentation policy have their own modules in `Direct/`.
- Picture rendering lives in `Direct/PlaybackPicture.m`. Frame generators and shaders live in `Sources/`.

Open a focused pull request with the behavior, the check you ran, and the hardware when relevant. For timing changes, use the same source sequence and display settings across trials. Record original and generated fps, gaps between presentations, and the start and end points of each latency measurement.

For a visual change, follow the [before-and-after recording guide](docs/recording-demo.md) and attach the clips to the pull request. Keep footage, app bundles, and installer files out of source commits. GitHub releases carry the DMG.

## How playback works

AVFoundation receives the 1080p capture as NV12 pixel buffers. The player compares pictures to detect repeated deliveries. Two distinct pictures from a 30 fps source give the generator a slot for one midpoint. The default Detail engine uses VideoToolbox's low-latency interpolation at 720p as a motion guide and reconstructs the midpoint at capture resolution with Metal. The experimental Fast Metal option estimates motion directly from the full-size capture.

Core Image scales each selected picture to fit the Metal drawable while preserving the source aspect ratio. On a 2560 × 1440 screen, a 16:9 picture can fill the 1440p drawable. Lanczos or bilinear scaling and optional luminance sharpening apply equally to captured and generated pictures.

## What the latency number measures

The overlay measures capture-sample timestamp to Metal's actual presentation timestamp. Capture-callback-to-presentation time is shown separately. Physical controller response, console rendering, capture-card delay before timestamping, and panel response fall outside this measurement.

In six one-second samples of moving gameplay on an earlier build, the preview presented 56–60 fps at 81–92 ms capture-to-presentation latency. Five samples had a 16.7 ms p95 presentation interval and one had 33.4 ms. Screen recording was active. Device, game and display affect the result.

### Reading the latency breakdown

**⌘I** shows three means for presented source pictures. **Input** runs from the capture timestamp to the app's callback. **App** runs from that callback to submission for presentation, including processing and scheduling. **Display** runs from submission to Metal-confirmed presentation. The three values add up to the source-picture mean. The larger headline also includes generated and held pictures, whose timestamps sit between inputs. The display interval excludes the panel's physical response.

The dashboard reports dropped original and generated frames separately. Held-frame drops are included in the total and listed in the tooltip. Run `./scripts/check-frame-policy.sh` to exercise cadence, priority, and timing arithmetic.

### Comparing interpolation modes

**Settings → Frame interpolation** switches the active engine during playback. **Detail (Apple + Metal)** is the default. It uses Apple's temporal model and reconstructs 1080p detail. **Fast Metal (experimental)** uses the project's full-resolution motion estimator. It spends less time generating a synthetic midpoint on the tested M4 Pro. Complex camera turns, thin geometry and HUD text can break up. Use the same moving scene, display mode and scaling settings when comparing actual presentation delay in the overlay.

In a local replay of 72 held-out gameplay pictures on an M4 Pro, mean generation time was 11.72 ms for Detail and 5.44 ms for Fast Metal. Mean absolute luma error at reference edges rose from 17.22 to 25.19 on an 8-bit scale. The test synthesized a withheld picture between two recorded neighbors. The replay measures reconstruction cost and error. Capture-to-screen delay requires a live test.

## Disk images

Run `./scripts/package-dmg.sh` for a local ad-hoc build. The script builds a fresh arm64 app into a temporary directory, verifies the disk image and writes the DMG and a local checksum to `dist/`. To check a local build, run `shasum -a 256 -c SecondFrame-0.1-macOS-arm64.dmg.sha256` from `dist/`. Maintainers with a Developer ID Application certificate can set `APP_SIGN_IDENTITY` to its name and `APP_NOTARY_PROFILE` to a Keychain notarytool profile to sign, notarize and staple the disk image.
