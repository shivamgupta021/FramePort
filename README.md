# gta60fps

gta60fps is a native macOS player for HDMI capture cards. It turns 30 fps console footage into a 60 fps preview on Apple silicon and upscales 1080p video to the display's resolution. The player uses AVFoundation, VideoToolbox, Metal and Core Image. Processing runs on the Mac.

## Getting started

The current build targets Apple silicon and macOS 26 or later. It has been tested on an M4 Pro with a UVC card named **USB Video** reporting 1920 × 1080 at 60 Hz and a 2560 × 1440 display. Other device names need capture-device selection support. The app previews video only.

Connect the console to the card's HDMI input and connect the card to the Mac over USB. Build the app with the macOS 26 SDK and open it.

```sh
./scripts/build.sh
open build/gta60fps.app
```

Allow Camera access when macOS asks. gta60fps looks for the external capture card, then opens in full screen, preferring a connected BenQ display or otherwise the main display. The USB input can carry duplicate pictures when a game renders at 30 fps. gta60fps detects the source cadence and interpolates a midpoint between consecutive game pictures.

| Control | Action |
| --- | --- |
| ⌘G | Toggle frame generation. Switch it off for native 60 fps footage. |
| ⌘1 / ⌘2 | Show original pixels / fit the window with the source aspect ratio. |
| ⌘I | Toggle the metrics overlay in full screen. |
| Control–⌘–F | Enter or leave native full screen. |
| ⌘R | Record ten seconds of the player window. gta60fps → Show Recordings opens the local folder. |

## What the latency number measures

The overlay measures capture-sample timestamp to Metal's actual presentation timestamp. Capture-callback-to-presentation time is shown separately. Physical controller response, console rendering, capture-card delay before timestamping, and panel response fall outside this measurement.

In six one-second samples of moving gameplay on the tested setup, the preview presented 56–60 fps at 81–92 ms capture-to-presentation latency. Five samples had a 16.7 ms p95 presentation interval and one had 33.4 ms. Screen recording was active. Device, game and display affect the result.

## Development

The capture UI lives in `Direct/Main.m`. `Direct/MeasuredPreview.m` owns the interpolation schedule and presentation timing. `Direct/PlaybackPicture.m` handles color, enlargement and sharpening. The Metal shaders and interpolation engine live in `Sources/`.

Run `./scripts/check-video.sh` on supported Apple silicon to exercise the synthetic video and color checks. Launch with `open build/gta60fps.app --args --verify-preview` to save a ten-second window recording and one raw USB reference still locally. For changes to timing or scaling, verify dimensions, orientation, cadence and capture-to-presentation delay on a real card.

Contributions are welcome as focused PRs. Describe the behavior, the before/after evidence, and how to revert the change. The project uses the [MIT license](LICENSE).
