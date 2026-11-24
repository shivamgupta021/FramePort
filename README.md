# Second Frame

Real-time frame interpolation and GPU upscaling for live HDMI video on Apple silicon. Preview a console or other HDMI source on your Mac, smooth 30 fps motion toward 60 fps, and scale a 1080p feed to fit your display. Processing runs locally.

[**Download Second Frame 0.1**](https://github.com/shivamgupta021/second-frame/releases)

## Requirements

- Apple-silicon Mac running macOS 26 or later
- USB HDMI capture card that macOS lists as **USB Video**, with a 1920 × 1080 capture mode

## Install

1. Download `SecondFrame-0.1-macOS-arm64.dmg`, open it, and drag **FramePort Full Screen** to **Applications**.
2. Connect your HDMI source to the capture card and plug the card into your Mac over USB.
3. Open **FramePort Full Screen** and allow Camera access so it can read your USB capture card.

If macOS blocks the first launch, go to **System Settings → Privacy & Security** and choose **Open Anyway** for the app. [Apple’s first-launch instructions](https://support.apple.com/en-us/102445)

## Playback

- **Frame generation** adds intermediate frames to 30 fps gameplay. Turn it off for native 60 fps gameplay.
- **Upscaling** uses Lanczos filtering and mild luminance sharpening. A 16:9 feed can fill a 2560 × 1440 display in full screen.
- **Live metrics** show capture and output rates, generated frames, dropped frames, and preview latency. Capture hardware and display refresh rate affect the result.

| Shortcut | Action |
| --- | --- |
| ⌘G | Toggle frame generation |
| ⌘1 / ⌘2 | Show original size / fit to window |
| ⌃⌘F | Toggle full screen |
| ⌘I | Show or hide metrics in full screen |

[Build and contribute](CONTRIBUTING.md) · [MIT license](LICENSE)
