# FramePort

FramePort is a native macOS player for HDMI capture cards. It turns 30 fps console footage into a 60 fps preview on Apple silicon and upscales 1080p video to the display's resolution. The player uses AVFoundation, VideoToolbox, Metal and Core Image. Processing runs on the Mac.

## Getting started

The current build targets Apple silicon and macOS 26 or later. It has been tested on an M4 Pro with a UVC card named **USB Video** reporting 1920 × 1080 at 60 Hz and a 2560 × 1440 display. Other device names need capture-device selection support. The app previews video only.

Connect the console to the card's HDMI input and connect the card to the Mac over USB. Build the app with the macOS 26 SDK and open it.

```sh
./scripts/build.sh
open build/FramePort.app
```

Allow Camera access when macOS asks. FramePort looks for the external capture card, then opens in full screen, preferring a connected BenQ display or otherwise the main display. The USB input can carry duplicate pictures when a game renders at 30 fps. FramePort detects the source cadence and interpolates a midpoint between consecutive game pictures.

| Control | Action |
| --- | --- |
| ⌘G | Toggle frame generation. Switch it off for native 60 fps footage. |
| ⌘1 / ⌘2 | Show original pixels / fit the window with the source aspect ratio. |
| ⌘I | Toggle the metrics overlay in full screen. |
| Control–⌘–F | Enter or leave native full screen. |
| ⌘R | Record ten seconds of the player window. FramePort → Show Recordings opens the local folder. |

## What the latency number measures

The overlay measures capture-sample timestamp to Metal's actual presentation timestamp. Capture-callback-to-presentation time is shown separately. Physical controller response, console rendering, capture-card delay before timestamping, and panel response fall outside this measurement.

In six one-second samples of moving gameplay on the tested setup, the preview presented 56–60 fps at 81–92 ms capture-to-presentation latency. Five samples had a 16.7 ms p95 presentation interval and one had 33.4 ms. Screen recording was active. Device, game and display affect the result.

## Development

The capture UI lives in `Direct/Main.m`. `Direct/MeasuredPreview.m` owns the interpolation schedule and presentation timing. `Direct/PlaybackPicture.m` handles color, enlargement and sharpening. The Metal shaders and interpolation engine live in `Sources/`.

Run `./scripts/check-video.sh` on supported Apple silicon to exercise the synthetic video and color checks. Launch with `open build/FramePort.app --args --verify-preview` to save a ten-second window recording and one raw USB reference still locally. For changes to timing or scaling, verify dimensions, orientation, cadence and capture-to-presentation delay on a real card.

Contributions are welcome as focused PRs. Describe the behavior, the before/after evidence, and how to revert the change. The project uses the [MIT license](LICENSE).

## Disk images

Download the Apple silicon DMG and its SHA-256 file from [Releases](https://github.com/shivamgupta021/FramePort/releases). In the downloads folder, run `shasum -a 256 -c FramePort-*.dmg.sha256` for the downloaded checksum file, open the image, and drag **FramePort** to **Applications**. Check each release's signing status. Gatekeeper may block downloaded ad-hoc builds. Building from source is also supported.

Run `./scripts/package-dmg.sh alpha.1` for a local ad-hoc build. The script builds a fresh arm64 app into a temporary directory, verifies the disk image and writes both the DMG and its checksum to `dist/`. Maintainers with a Developer ID Application certificate can set `FRAMEPORT_SIGN_IDENTITY` to its name and `FRAMEPORT_NOTARY_PROFILE` to a Keychain notarytool profile to sign, notarize and staple the disk image.
