# gta60fps

gta60fps is a native macOS player for HDMI capture cards. It turns 30 fps console footage into a 60 fps preview on Apple silicon and upscales 1080p video to the display's resolution. The player uses AVFoundation, VideoToolbox, Metal and Core Image. Processing runs on the Mac.

## Install and play

You need an Apple-silicon Mac running **macOS 26 or later**, a USB HDMI capture card with a **1080p** capture mode, and a console. The app has been tested on an M4 Pro with a UVC card listed as **USB Video** and a 2560 × 1440 monitor. The current release previews video.

1. Connect the console to the card's HDMI input and the card to the Mac over USB.
2. Download the arm64 disk image from [GitHub Releases](https://github.com/shivamgupta021/gta60fps/releases), open it, and drag **gta60fps** into **Applications**.
3. Open the app from Applications. Allow **Camera** access so macOS can deliver frames from the USB card, then select the card if asked. The preview starts in full screen by default. If the card offers 1080p but the console feed is blank, try setting the console's HDMI output to 1080p.

Check the release notes for signing status. An ad-hoc prerelease can be blocked by Gatekeeper. Apple explains the first-launch options for a downloaded app you trust. You can also build a local copy from source. [Apple's opening instructions](https://support.apple.com/en-us/102445)

| Control | Action |
| --- | --- |
| ⌘G | Toggle frame generation. Distinct 60 fps inputs pass through automatically. |
| ⌘1 / ⌘2 | Show original pixels / fit the window with the source aspect ratio. |
| ⌘I | Toggle the metrics overlay in full screen. |
| Control–⌘–F | Enter or leave native full screen. |
| ⌘R | Record ten seconds of the player window. gta60fps → Show Recordings opens the local folder. |

## What the latency number measures

The overlay measures capture-sample timestamp to Metal's actual presentation timestamp. Capture-callback-to-presentation time is shown separately. Physical controller response, console rendering, capture-card delay before timestamping, and panel response fall outside this measurement.

In six one-second samples of moving gameplay on the tested setup, the preview presented 56–60 fps at 81–92 ms capture-to-presentation latency. Five samples had a 16.7 ms p95 presentation interval and one had 33.4 ms. Screen recording was active. Device, game and display affect the result.

## Development

Build with the macOS 26 SDK using `./scripts/build.sh`, then open `build/gta60fps.app`. Start with [the contribution guide](CONTRIBUTING.md) for the checks and production playback entry points. The project uses the [MIT license](LICENSE).

## Disk images

Download the Apple silicon DMG and its SHA-256 file from [Releases](https://github.com/shivamgupta021/gta60fps/releases). In the downloads folder, run `shasum -a 256 -c gta60fps-*.dmg.sha256` for the downloaded checksum file, open the image, and drag **gta60fps** to **Applications**. Check each release's signing status. Gatekeeper may block downloaded ad-hoc builds. Building from source is also supported.

Run `./scripts/package-dmg.sh alpha.1` for a local ad-hoc build. The script builds a fresh arm64 app into a temporary directory, verifies the disk image and writes both the DMG and its checksum to `dist/`. Maintainers with a Developer ID Application certificate can set `FRAMEPORT_SIGN_IDENTITY` to its name and `FRAMEPORT_NOTARY_PROFILE` to a Keychain notarytool profile to sign, notarize and staple the disk image.

## Playback settings

Open **gta60fps → Settings…** with **⌘,**. Choose Lanczos or bilinear enlargement, and off, mild or strong luminance sharpening. Picture settings apply to original and generated frames as you change them. Original-size playback uses the captured pixels. The defaults are Lanczos and mild sharpening. The **Start in full screen** preference applies the next time the capture starts. Preferences are stored on the Mac.

Run `./scripts/check-settings.sh` to exercise the panel controls, preference restoration and all six rendered filter/sharpening combinations with a synthetic input.

### Reading the latency breakdown

**⌘I** shows three means for presented source pictures. **Input** runs from the capture timestamp to the app's callback. **App** runs from that callback to submission for presentation, including processing and scheduling. **Display** runs from submission to Metal-confirmed presentation. The three values add up to the source-picture mean. The larger headline also includes generated and held pictures, whose timestamps sit between inputs. The display interval excludes the panel's physical response.

The dashboard reports dropped original and generated frames separately. Held-frame drops are included in the total and listed in the tooltip. Run `./scripts/check-frame-policy.sh` to exercise cadence, priority, and timing arithmetic.

### Comparing interpolation modes

**Settings → Frame interpolation** switches the active engine during playback. **Detail (Apple + Metal)** is the default. It uses Apple's temporal model and reconstructs 1080p detail. **Fast Metal (experimental)** uses the project's full-resolution motion estimator. It spends less time generating a synthetic midpoint on the tested M4 Pro. Complex camera turns, thin geometry and HUD text can break up. Use the same moving scene, display mode and scaling settings when comparing actual presentation delay in the overlay.

In a local replay of 72 held-out gameplay pictures on an M4 Pro, mean generation time was 11.72 ms for Detail and 5.44 ms for Fast Metal. Mean absolute luma error at reference edges rose from 17.22 to 25.19 on an 8-bit scale. The test synthesized a withheld picture between two recorded neighbors. It measures reconstruction cost and error, not capture-to-screen delay.

[Comparison with Meyra](docs/meyra-comparison.md) covers the original Reddit feedback, the two renderers and the next capture, latency and HUD experiments.
