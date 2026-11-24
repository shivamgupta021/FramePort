#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import "PreviewRecording.h"
#import "MeasuredPreview.h"
#import "PlaybackSettings.h"

@interface CardView : NSView
@property(nonatomic, strong) MeasuredPreview *preview;
@property(nonatomic) CGSize sourceSize;
@property(nonatomic) BOOL originalSize;
@end
@implementation CardView
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; self.needsLayout = YES; }
- (void)layout {
    [super layout];
    if (!self.preview || self.sourceSize.width <= 0 || self.sourceSize.height <= 0) return;
    NSRect canvas = [self convertRectToBacking:self.bounds];
    // Fit the entire capture with one scale factor for both axes.
    CGFloat scale = MIN(canvas.size.width / self.sourceSize.width, canvas.size.height / self.sourceSize.height);
    if (self.originalSize) scale = MIN(1, scale);
    CGFloat w = round(scale * self.sourceSize.width), h = round(scale * self.sourceSize.height);
    NSRect pixels = NSMakeRect(floor(NSMidX(canvas) - w / 2), floor(NSMidY(canvas) - h / 2), w, h);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.preview.layer.frame = [self convertRectFromBacking:pixels];
    self.preview.layer.contentsScale = self.window.backingScaleFactor;
    self.preview.layer.drawableSize = pixels.size;
    [CATransaction commit];
}
@end

static BOOL setMode(AVCaptureDevice *device, AVCaptureDeviceFormat *format, CMTime interval, NSError **error) {
    if (![device lockForConfiguration:error]) return NO;
    @try {
        device.activeFormat = format;
        device.activeVideoMinFrameDuration = interval;
        device.activeVideoMaxFrameDuration = interval;
    } @catch (NSException *exception) {
        *error = [NSError errorWithDomain:@"FramePort" code:2 userInfo:@{NSLocalizedDescriptionKey:exception.reason}];
        return NO;
    } @finally {
        [device unlockForConfiguration];
    }
    return YES;
}

@interface DirectPlayer : NSObject <NSApplicationDelegate, NSWindowDelegate, AVCaptureVideoDataOutputSampleBufferDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) CardView *view;
@property(nonatomic, strong) AVCaptureSession *session;
@property(nonatomic, strong) PreviewRecording *recorder;
@property(nonatomic, strong) NSURL *recordingDirectory;
@property(nonatomic, strong) NSURL *referenceURL;
@property(atomic) BOOL takeReference;
@property(nonatomic) BOOL verify;
@property(nonatomic, strong) NSArray<NSTextField *> *values;
@property(nonatomic, strong) NSArray<NSTextField *> *details;
@property(nonatomic, strong) NSButton *generationButton;
@property(nonatomic, strong) PlaybackSettings *settings;
@property(nonatomic, strong) NSMenuItem *generationItem;
@property(nonatomic, strong) NSStackView *metricsBar;
@property(nonatomic, strong) NSMenuItem *metricsItem;
@property(nonatomic, strong) NSLayoutConstraint *videoBottom;
@property(nonatomic) BOOL fullScreenLayout, showFullScreenMetrics;
@property(nonatomic) double verificationEnd;
@end

@implementation DirectPlayer
- (void)report:(NSString *)message {
    NSLog(@"%@", message);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"gta60fps";
        alert.informativeText = message;
        [alert runModal];
    });
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.verify = [NSProcessInfo.processInfo.arguments containsObject:@"--verify-preview"];
    self.recordingDirectory = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
        inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"FramePort Recordings" isDirectory:YES];
    self.recorder = [PreviewRecording new];
    self.settings = [[PlaybackSettings alloc] initWithDefaults:NSUserDefaults.standardUserDefaults];
    NSMenu *bar = [NSMenu new], *app = [NSMenu new];
    [bar addItem:[NSMenuItem new]];
    [bar setSubmenu:app forItem:bar.itemArray.firstObject];
    [[app addItemWithTitle:@"Settings…" action:@selector(showWindow:) keyEquivalent:@","] setTarget:self.settings];
    [app addItem:[NSMenuItem separatorItem]];
    [[app addItemWithTitle:@"Record 10 Seconds of Preview" action:@selector(record:) keyEquivalent:@"r"] setTarget:self];
    [[app addItemWithTitle:@"Show Recordings" action:@selector(showRecordings:) keyEquivalent:@""] setTarget:self];
    [app addItem:[NSMenuItem separatorItem]];
    [app addItemWithTitle:@"Quit gta60fps" action:@selector(terminate:) keyEquivalent:@"q"];
    NSMenu *sizeMenu = [[NSMenu alloc] initWithTitle:@"View"];
    NSMenuItem *viewItem = [bar addItemWithTitle:@"View" action:nil keyEquivalent:@""];
    viewItem.submenu = sizeMenu;
    NSMenuItem *native = [sizeMenu addItemWithTitle:@"Original Size" action:@selector(selectSize:) keyEquivalent:@"1"];
    native.target = self;
    native.tag = 1;
    NSMenuItem *fit = [sizeMenu addItemWithTitle:@"Fit to Window" action:@selector(selectSize:) keyEquivalent:@"2"];
    fit.target = self;
    fit.state = NSControlStateValueOn;
    [sizeMenu addItem:[NSMenuItem separatorItem]];
    self.generationItem = [sizeMenu addItemWithTitle:@"Frame Generation" action:@selector(toggleGeneration:) keyEquivalent:@"g"];
    self.generationItem.target = self;
    self.generationItem.state = NSControlStateValueOn;
    self.metricsItem = [sizeMenu addItemWithTitle:@"Full Screen Metrics" action:@selector(toggleMetrics:) keyEquivalent:@"i"];
    self.metricsItem.target = self;
    NSMenuItem *fullScreen = [sizeMenu addItemWithTitle:@"Enter Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"];
    fullScreen.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagCommand;
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [bar addItemWithTitle:@"Window" action:nil keyEquivalent:@""].submenu = windowMenu;
    [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
    NSApp.windowsMenu = windowMenu;
    NSApp.mainMenu = bar;
    NSScreen *screen = NSScreen.mainScreen;
    for (NSScreen *candidate in NSScreen.screens) {
        if ([candidate.localizedName localizedCaseInsensitiveContainsString:@"BenQ"]) { screen = candidate; break; }
    }
    NSRect desktop = screen.visibleFrame;
    NSRect normal = NSMakeRect(0, 0, MIN(1120, desktop.size.width * .85), MIN(720, desktop.size.height * .85));
    self.window = [[NSWindow alloc] initWithContentRect:normal styleMask:NSWindowStyleMaskTitled |
        NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.delegate = self;
    self.window.title = @"gta60fps";
    self.window.subtitle = @"USB Video · Low Latency";
    self.generationButton = [NSButton checkboxWithTitle:@"Frame generation · 30 → 60" target:self action:@selector(toggleGeneration:)];
    self.generationButton.state = NSControlStateValueOn;
    [self.generationButton sizeToFit];
    NSTitlebarAccessoryViewController *accessory = [NSTitlebarAccessoryViewController new];
    accessory.layoutAttribute = NSLayoutAttributeRight;
    accessory.view = self.generationButton;
    [self.window addTitlebarAccessoryViewController:accessory];
    self.window.releasedWhenClosed = NO;
    self.window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    self.window.opaque = YES;
    self.window.backgroundColor = NSColor.blackColor;
    self.window.contentMinSize = NSMakeSize(720, 320);
    NSRect frame = self.window.frame;
    frame.origin = NSMakePoint(floor(NSMidX(desktop) - frame.size.width/2), floor(NSMidY(desktop) - frame.size.height/2));
    [self.window setFrame:frame display:NO];
    self.view = [[CardView alloc] initWithFrame:NSZeroRect];
    self.view.wantsLayer = YES;
    self.view.layer.backgroundColor = NSColor.blackColor.CGColor;
    [self installDashboard];
    self.view.preview = [MeasuredPreview new];
    if (!self.view.preview) { [self report:@"A Metal device is required for the measured preview."]; return; }
    self.view.preview.pictureOptions = self.settings.pictureOptions;
    MeasuredPreview *preview = self.view.preview;
    preview.generationEngine = self.settings.generationEngine;
    self.settings.engineDidChange = ^(FPGenerationEngine engine) { preview.generationEngine = engine; };
    self.settings.pictureDidChange = ^(FPPictureOptions options) { preview.pictureOptions = options; };
    [self.view.layer addSublayer:preview.layer];
    [self.window zoom:nil];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    self.session = [AVCaptureSession new];
    [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(refreshStatistics:) userInfo:nil repeats:YES];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(sessionError:) name:AVCaptureSessionRuntimeErrorNotification object:self.session];
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL allowed) {
        if (!allowed) { [self report:@"Allow gta60fps Camera access in System Settings to open your capture card."]; return; }
        dispatch_async(dispatch_get_main_queue(), ^{ [self chooseCaptureDevice]; });
    }];
}
- (void)updateMetricsLayout {
    self.metricsBar.hidden = self.fullScreenLayout && !self.showFullScreenMetrics;
    self.metricsItem.state = self.showFullScreenMetrics ? NSControlStateValueOn : NSControlStateValueOff;
    self.videoBottom.constant = self.fullScreenLayout ? 0 : -75;
    self.metricsBar.layer.backgroundColor = self.fullScreenLayout ? [NSColor colorWithWhite:.08 alpha:.9].CGColor : nil;
    [self.window.contentView layoutSubtreeIfNeeded];
}
- (void)toggleMetrics:(id)sender {
    self.showFullScreenMetrics = !self.showFullScreenMetrics;
    [self updateMetricsLayout];
}
- (void)windowWillEnterFullScreen:(NSNotification *)notification {
    self.fullScreenLayout = YES;
    [self updateMetricsLayout];
}
- (void)windowDidEnterFullScreen:(NSNotification *)notification {
    [NSCursor setHiddenUntilMouseMoves:YES];
    if (self.verify) NSLog(@"Native full screen on %@ · video %.0f × %.0f px", self.window.screen.localizedName,
        self.view.preview.layer.drawableSize.width,self.view.preview.layer.drawableSize.height);
}
- (void)windowWillExitFullScreen:(NSNotification *)notification {
    self.fullScreenLayout = NO;
    [self updateMetricsLayout];
}
- (void)windowDidFailToEnterFullScreen:(NSWindow *)window {
    self.fullScreenLayout = NO;
    [self updateMetricsLayout];
}
- (void)windowDidFailToExitFullScreen:(NSWindow *)window {
    self.fullScreenLayout = YES;
    [self updateMetricsLayout];
}
- (NSApplicationPresentationOptions)window:(NSWindow *)window
    willUseFullScreenPresentationOptions:(NSApplicationPresentationOptions)options {
    return (options & ~(NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar)) |
        NSApplicationPresentationFullScreen | NSApplicationPresentationAutoHideDock |
        NSApplicationPresentationAutoHideMenuBar | NSApplicationPresentationAutoHideToolbar;
}
- (NSRect)windowWillUseStandardFrame:(NSWindow *)window defaultFrame:(NSRect)frame {
    return window.screen ? window.screen.visibleFrame : frame;
}
- (void)windowDidChangeOcclusionState:(NSNotification *)notification {
    self.view.preview.visible = self.view.sourceSize.width > 0 && (self.window.occlusionState & NSWindowOcclusionStateVisible);
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }
- (void)installDashboard {
    NSView *root = self.window.contentView;
    NSStackView *bar = [NSStackView stackViewWithViews:@[]];
    self.metricsBar = bar;
    bar.wantsLayer = YES;
    bar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    bar.distribution = NSStackViewDistributionFillEqually;
    bar.spacing = 14;
    NSArray *titles = @[@"Capture input", @"Presented output", @"Preview latency", @"Dropped frames", @"Generated output"];
    NSArray *hints = @[@"Buffers delivered by the capture device, including repeated game images.",
        @"Drawables macOS reports as presented. Size is the game image in display pixels. P95 is the 95th percentile of the intervals between presentations.",
        @"Total includes generated pictures. The breakdown uses real pictures only: capture timestamp to input callback, callback to presentation submission, then submission to Metal-confirmed presentation.",
        @"Cumulative AVFoundation drops and preview frames skipped or reported as undisplayed.",
        @"Motion-interpolated frames confirmed as presented per second. Included in Presented output. The count below it includes original frames confirmed as presented."];
    NSMutableArray *values = [NSMutableArray array], *details = [NSMutableArray array];
    for (NSUInteger i = 0; i < titles.count; i++) {
        NSTextField *label = [NSTextField labelWithString:titles[i]];
        label.textColor = NSColor.secondaryLabelColor;
        NSTextField *value = [NSTextField labelWithString:@"—"];
        value.font = [NSFont monospacedDigitSystemFontOfSize:20 weight:NSFontWeightSemibold];
        NSTextField *detail = [NSTextField labelWithString:@"Waiting for video"];
        detail.font = [NSFont systemFontOfSize:11];
        detail.textColor = NSColor.secondaryLabelColor;
        NSStackView *column = [NSStackView stackViewWithViews:@[label, value, detail]];
        column.orientation = NSUserInterfaceLayoutOrientationVertical;
        column.alignment = NSLayoutAttributeLeading;
        column.spacing = 1;
        column.toolTip = hints[i];
        [bar addArrangedSubview:column]; [values addObject:value]; [details addObject:detail];
    }
    self.values = values; self.details = details;
    [root addSubview:self.view]; [root addSubview:bar];
    self.view.translatesAutoresizingMaskIntoConstraints = NO;
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    self.videoBottom = [self.view.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-75];
    [NSLayoutConstraint activateConstraints:@[
        [self.view.topAnchor constraintEqualToAnchor:root.topAnchor],
        [self.view.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [self.view.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        self.videoBottom,
        [bar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:16],
        [bar.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-16],
        [bar.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-10],
        [bar.heightAnchor constraintEqualToConstant:57]
    ]];
}
- (void)refreshStatistics:(NSTimer *)timer {
    PreviewStatistics s = [self.view.preview readStatistics];
    if (s.inputSize.width <= 0) return;
    CGSize size = self.view.preview.layer.drawableSize;
    self.values[0].stringValue = [NSString stringWithFormat:@"%.1f fps",s.inputFPS];
    self.values[1].stringValue = [NSString stringWithFormat:@"%.1f fps",s.outputFPS];
    self.values[2].stringValue = isfinite(s.captureToPresentMS) ? [NSString stringWithFormat:@"%.1f ms",s.captureToPresentMS] : @"—";
    self.values[3].stringValue = [NSString stringWithFormat:@"%lu",s.captureDrops + s.previewDrops];
    self.details[0].stringValue = [NSString stringWithFormat:@"USB · %.0f × %.0f",s.inputSize.width,s.inputSize.height];
    NSString *pacing = isfinite(s.intervalP95MS) ? [NSString stringWithFormat:@" · %.1f ms p95",s.intervalP95MS] : @"";
    self.details[1].stringValue = [NSString stringWithFormat:@"%.0f × %.0f px%@",size.width,size.height,pacing];
    FPSourceTiming timing = s.realFrameMS;
    self.details[2].stringValue = timing.count ? [NSString stringWithFormat:@"Input %.0f · app %.0f · display %.0f ms",
        timing.input,timing.app,timing.display] : @"Awaiting a presented source frame";
    self.details[2].toolTip = [NSString stringWithFormat:@"Real pictures: capture to callback, callback to submit, submit to presentation. All pictures averaged %.1f ms from app delivery.",s.deliveryToPresentMS];
    self.details[3].stringValue = [NSString stringWithFormat:@"%lu capture · %lu original · %lu generated",
        s.captureDrops,s.originalDrops,s.generatedDrops];
    self.details[3].toolTip = [NSString stringWithFormat:@"%lu held frames also missed a display slot.",
        s.previewDrops-s.originalDrops-s.generatedDrops];
    NSString *error = self.view.preview.generationError;
    BOOL enabled = self.view.preview.generationEnabled;
    self.values[4].stringValue = !enabled ? @"Off" : error ? @"Unavailable" : [NSString stringWithFormat:@"%.1f fps",s.generatedFPS];
    self.details[4].stringValue = !enabled || error ? @"Source preview" : [NSString stringWithFormat:@"%.1f original fps",s.originalFPS];
    self.values[4].toolTip = error ?: @"Motion-interpolated frames actually presented per second.";
    if (self.verify && (self.recorder.busy || CACurrentMediaTime() < self.verificationEnd)) NSLog(@"USB %.1f · source changes %.1f · shown %.1f · generated shown %.1f · latency %.1f ms · delivery %.1f ms · p95 %.1f ms · drops %lu/%lu · real[%zu] input/app/display %.1f/%.1f/%.1f ms",
        s.inputFPS,s.changeFPS,s.outputFPS,s.generatedFPS,s.captureToPresentMS,s.deliveryToPresentMS,s.intervalP95MS,s.captureDrops,s.previewDrops,timing.count,timing.input,timing.app,timing.display);
}
- (void)toggleGeneration:(id)sender {
    BOOL enable = !self.view.preview.generationEnabled;
    self.view.preview.generationEnabled = enable;
    self.generationButton.state = self.generationItem.state = enable ? NSControlStateValueOn : NSControlStateValueOff;
}
- (void)selectSize:(NSMenuItem *)sender {
    self.view.originalSize = sender.tag == 1;
    for (NSMenuItem *item in sender.menu.itemArray)
        if (item.action == @selector(selectSize:)) item.state = item == sender ? NSControlStateValueOn : NSControlStateValueOff;
    self.view.needsLayout = YES;
}
- (void)sessionError:(NSNotification *)note { [self report:[note.userInfo[AVCaptureSessionErrorKey] localizedDescription]]; }
- (void)chooseCaptureDevice {
    NSArray<AVCaptureDevice *> *devices = [AVCaptureDeviceDiscoverySession
        discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeExternal]
        mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionUnspecified].devices;
    if (!devices.count) { [self report:@"Connect a USB capture card, then reopen gta60fps."]; return; }

    AVCaptureDevice *card = devices.firstObject;
    if (devices.count > 1) {
        NSPopUpButton *picker = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 300, 26) pullsDown:NO];
        for (NSUInteger i = 0; i < devices.count; i++) {
            NSString *name = devices[i].localizedName;
            [picker.menu addItem:[[NSMenuItem alloc] initWithTitle:name action:nil keyEquivalent:@""]];
            if ([name isEqualToString:@"USB Video"]) [picker selectItemAtIndex:i];
        }
        if (picker.indexOfSelectedItem < 0) [picker selectItemAtIndex:0];
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Choose a capture device";
        alert.informativeText = @"Select the USB capture card connected to your console.";
        alert.accessoryView = picker;
        [alert addButtonWithTitle:@"Open"];
        [alert addButtonWithTitle:@"Quit"];
        if ([alert runModal] != NSAlertFirstButtonReturn) { [NSApp terminate:nil]; return; }
        card = devices[picker.indexOfSelectedItem];
    }

    self.window.subtitle = card.localizedName;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [self startCard:card]; });
}
- (void)startCard:(AVCaptureDevice *)card {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(cardDisconnected:)
        name:AVCaptureDeviceWasDisconnectedNotification object:card];
    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:card error:&error];
    if (!input || ![self.session canAddInput:input]) { [self report:error.localizedDescription ?: @"Could not open the selected capture device."]; return; }
    // Request the full 1080p transport, allowing the console to send repeated images at its own cadence.
    double nearestRateError = INFINITY;
    CMTime interval = kCMTimeInvalid;
    AVCaptureDeviceFormat *format = nil;
    for (AVCaptureDeviceFormat *candidate in card.formats) {
        CMVideoDimensions size = CMVideoFormatDescriptionGetDimensions(candidate.formatDescription);
        if (size.width != 1920 || size.height != 1080) continue;
        for (AVFrameRateRange *range in candidate.videoSupportedFrameRateRanges) {
            // A UVC interval of 166666 units of 100 ns is nominal 60 Hz (60.000240001).
            double hz = MIN(MAX(60.0, range.minFrameRate), range.maxFrameRate);
            double rateError = fabs(hz - 60.0);
            if (rateError >= nearestRateError) continue;
            nearestRateError = rateError;
            interval = hz == range.maxFrameRate ? range.minFrameDuration :
                hz == range.minFrameRate ? range.maxFrameDuration : CMTimeMake(1, 60);
            format = candidate;
        }
    }
    if (!format) { [self report:@"The selected capture device offers no 1920 × 1080 mode."]; return; }
    [self.session beginConfiguration];
    [self.session addInput:input];
    AVCaptureVideoDataOutput *tap = [AVCaptureVideoDataOutput new];
    if (![self.session canAddOutput:tap]) {
        [self.session commitConfiguration]; [self report:@"Could not attach the USB video output."]; return;
    }
    [self.session addOutput:tap];
    tap.alwaysDiscardsLateVideoFrames = YES;
    if ([tap.availableVideoCVPixelFormatTypes containsObject:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)])
        tap.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
    [tap setSampleBufferDelegate:self queue:dispatch_queue_create("local.frameport.capture", DISPATCH_QUEUE_SERIAL)];
    AVCaptureConnection *connection = [tap connectionWithMediaType:AVMediaTypeVideo];
    if (connection.isVideoMirroringSupported) {
        connection.automaticallyAdjustsVideoMirroring = NO;
        connection.videoMirrored = NO;
    }
    BOOL configured = setMode(card, format, interval, &error);
    [self.session commitConfiguration];
    if (!configured) { [self report:error.localizedDescription]; return; }
    CMVideoDimensions encoded = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
    [self.view.preview prepareGenerationForWidth:encoded.width height:encoded.height];
    [self.session startRunning];
    if (!self.session.running) { [self report:@"The selected capture device could not start."]; return; }
    // Some UVC drivers change their interval while starting a session.
    if (card.activeFormat != format || CMTimeCompare(card.activeVideoMinFrameDuration,interval) ||
        CMTimeCompare(card.activeVideoMaxFrameDuration,interval)) {
        if (!setMode(card, format, interval, &error)) { [self report:error.localizedDescription]; return; }
    }
    CGSize presentation = CMVideoFormatDescriptionGetPresentationDimensions(card.activeFormat.formatDescription, YES, YES);
    dispatch_async(dispatch_get_main_queue(), ^{
        self.view.sourceSize = presentation;
        self.view.needsLayout = YES;
        [self.view layoutSubtreeIfNeeded];
        self.view.preview.visible = (self.window.occlusionState & NSWindowOcclusionStateVisible) != 0;
        if (self.settings.startsFullScreen && !(self.window.styleMask & NSWindowStyleMaskFullScreen)) [self.window toggleFullScreen:nil];
        NSLog(@"%@ on %@, capture %.2f Hz, presentation %@, preview in backing pixels %@",
            card.localizedName, self.window.screen.localizedName, 1 / CMTimeGetSeconds(card.activeVideoMinFrameDuration),
            NSStringFromSize(presentation), NSStringFromRect([self.view convertRectToBacking:self.view.preview.layer.frame]));
        if (self.verify) {
            self.verificationEnd = CACurrentMediaTime() + 60;
            [self performSelector:@selector(record:) withObject:nil afterDelay:4];
        }
    });
}
- (void)cardDisconnected:(NSNotification *)note { [self report:@"The capture device disconnected. Reconnect the card and reopen gta60fps."]; }
- (void)record:(id)sender {
    if (self.recorder.busy || !self.session.running) return;
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:self.recordingDirectory withIntermediateDirectories:YES
        attributes:nil error:&error]) { [self report:error.localizedDescription]; return; }
    NSString *name = [NSString stringWithFormat:@"Direct-%.0f", NSDate.date.timeIntervalSince1970 * 1000];
    NSURL *base = [self.recordingDirectory URLByAppendingPathComponent:name];
    NSURL *movie = [base URLByAppendingPathExtension:@"mp4"];
    if (self.verify) {
        self.referenceURL = [base URLByAppendingPathExtension:@"png"];
        NSRect game = [self.view convertRect:self.view.preview.layer.frame toView:nil];
        double backing = self.window.backingScaleFactor;
        NSLog(@"Recording video rectangle (top-left pixels): %.0f,%.0f,%.0f,%.0f",
            game.origin.x * backing, (self.window.frame.size.height - NSMaxY(game)) * backing,
            game.size.width * backing, game.size.height * backing);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ self.takeReference = YES; });
    }
    [self.recorder recordWindow:self.window toURL:movie completion:^(NSError *recordError) {
        if (recordError) [self report:recordError.localizedDescription];
        else NSLog(@"Recorded %@",movie.path);
    }];
}
- (void)showRecordings:(id)sender {
    [NSFileManager.defaultManager createDirectoryAtURL:self.recordingDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    [NSWorkspace.sharedWorkspace openURL:self.recordingDirectory];
}
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection {
    double delivery = CACurrentMediaTime(), capture = NAN;
    CMClockRef clock = self.session.synchronizationClock;
    if (clock) capture = CMTimeGetSeconds(CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sample), clock, CMClockGetHostTimeClock()));
    [self.view.preview displaySample:sample captureTime:capture deliveryTime:delivery];
    if (!self.takeReference) return;
    self.takeReference = NO;
    CVPixelBufferRef buffer = CMSampleBufferGetImageBuffer(sample);
    if (!buffer) return;
    NSURL *url = self.referenceURL;
    CVPixelBufferRetain(buffer);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        CGColorSpaceRef rgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        NSError *error = nil;
        [[CIContext contextWithOptions:nil] writePNGRepresentationOfImage:[CIImage imageWithCVPixelBuffer:buffer]
            toURL:url format:kCIFormatRGBA8 colorSpace:rgb options:@{} error:&error];
        CGColorSpaceRelease(rgb);
        CVPixelBufferRelease(buffer);
        if (error) [self report:error.localizedDescription];
    });
}
- (void)captureOutput:(AVCaptureOutput *)output didDropSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection {
    [self.view.preview captureDropped];
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (self.session.running) [self.session stopRunning];
}
@end

int main(void) { @autoreleasepool {
    NSApplication *app = NSApplication.sharedApplication;
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    __attribute__((objc_precise_lifetime)) DirectPlayer *player = [DirectPlayer new];
    app.delegate = player;
    [app run];
    (void)player;
} return 0; }
