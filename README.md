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

## Playback settings

Open **FramePort → Settings…** with **⌘,**. Choose Lanczos or bilinear enlargement, and off, mild or strong luminance sharpening. Picture settings apply to original and generated frames as you change them. Original-size playback uses the captured pixels. The defaults are Lanczos and mild sharpening. The **Start in full screen** preference applies the next time the capture starts. Preferences are stored on the Mac.

Run `./scripts/check-settings.sh` to exercise the panel controls, preference restoration and all six rendered filter/sharpening combinations with a synthetic input.

### Reading the latency breakdown

**⌘I** shows three means for presented source pictures. **Input** runs from the capture timestamp to the app's callback. **App** runs from that callback to submission for presentation, including processing and scheduling. **Display** runs from submission to Metal-confirmed presentation. The three values add up to the source-picture mean. The larger headline also includes generated and held pictures, whose timestamps sit between inputs. The display interval excludes the panel's physical response.

Run `cc Tests/PresentationTimingCheck.c -o build/check-timing && ./build/check-timing` after building the app to verify the stage arithmetic.

### Comparing interpolation modes

**Settings → Frame interpolation** switches the active engine during playback. **Detail (Apple + Metal)** is the default. It uses Apple's temporal model and reconstructs 1080p detail. **Fast Metal (experimental)** uses the project's full-resolution motion estimator. It spends less time generating a synthetic midpoint on the tested M4 Pro. Complex camera turns, thin geometry and HUD text can break up. Use the same moving scene, display mode and scaling settings when comparing actual presentation delay in the overlay.

In a local replay of 72 held-out gameplay pictures on an M4 Pro, mean generation time was 11.72 ms for Detail and 5.44 ms for Fast Metal. Mean absolute luma error at reference edges rose from 17.22 to 25.19 on an 8-bit scale. The test synthesized a withheld picture between two recorded neighbors. It measures reconstruction cost and error, not capture-to-screen delay.
