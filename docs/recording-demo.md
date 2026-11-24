# Record a before-and-after demo

## Frame generation

1. Choose a 30 fps game mode, if available. Keep the same HDMI signal, capture card, window size, display refresh rate, upscaling and sharpening settings for both clips.
2. Load a repeatable scene with moving detail, such as a steady camera pan past railings or buildings. Keep the metrics dashboard visible in a window, or use **⌘I** in full screen.
3. Turn frame generation off with **⌘G**. Press **⌘R** and do the camera move. The app records ten seconds of its preview window.
4. Return to the same spot. Turn frame generation on with **⌘G** and record the same move again. Wait until the metrics show generated pictures before pressing **⌘R**.
5. Open **Show Recordings** from the app menu. Label the clips `30-fps-generation-off` and `30-fps-detail-on`. Note the observed playback FPS and generated FPS in the pull request.

## Upscaling

Leave frame generation off. On the same display, compare **⌘1** for the 1080p original-size view and **⌘2** for fit-to-window output. Keep the display and window the same size. Record an area with readable fine detail such as HUD text, or add full-size stills. Note the source and output dimensions.

## Attach the clips

Edit the pull request description and drag its clips into **Evidence**. Use H.264 at 60 fps if exporting the motion comparison. Keep each clip under 10 MB for GitHub's free-plan video limit. Retain the original clips locally so compression in the attachment can be distinguished from picture quality in the app. [GitHub's attachment instructions](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/attaching-files)

The clips show the app preview. A controller-to-screen latency comparison needs an external camera that can see the physical controller input and the display together.
