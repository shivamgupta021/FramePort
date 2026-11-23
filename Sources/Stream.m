#import "Stream.h"
#import "Cadence.h"
#import <QuartzCore/QuartzCore.h>

@interface FPTimedFrame : NSObject
@property(nonatomic, strong) FPFrame *frame;
@property double deadline;
@end
@implementation FPTimedFrame
@end

// All starts and stops share this queue so reopening the same card releases the old input first.
static dispatch_queue_t sessionQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("local.frameport.capture", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

@implementation FPStream {
    BOOL _generate;
    BOOL _generationFailed;
    double _genMs, _scaleMs, _waitMs, _deliveryMs;
    AVCaptureSession *_capture;
    dispatch_source_t _timer, _presentTimer;
    FPPattern *_pattern;
    FPFrame *_previous, *_beforePrevious;
    FPImageChange _lastChange;
    FPInterpolator *_interpolator;
    NSMutableArray<FPTimedFrame *> *_pending;
    double _anchor, _lastInputAt;
    NSUInteger _inputCount, _sourceCount, _generatedCount, _presentedCount, _drops;
    NSUInteger _lastInput, _lastSource, _lastGenerated, _lastPresented;
    double _lastReport;
    size_t _width, _height, _genHeight;
    BOOL _stopped, _failed;
    id _runtimeObserver, _disconnectObserver;
}
+ (NSArray<AVCaptureDevice *> *)devices {
    return [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeExternal]
        mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionUnspecified].devices;
}
- (instancetype)initWithGeneration:(BOOL)generation {
    if (!(self = [super init])) return nil;
    _generate = generation;
    _captureRate = generation ? 30 : 60;
    _pending = [NSMutableArray array];
    _message = @"Starting…";
    _lastReport = CACurrentMediaTime();
    _anchor = NAN;
    return self;
}
- (BOOL)stopped { @synchronized(self) { return _stopped; } }
- (void)fail:(NSString *)message {
    @synchronized(self) {
        if (_stopped) return;
        _failed = YES;
        self.message = message;
    }
    [self stop];
}
- (BOOL)failed { @synchronized(self) { return _failed; } }
// A single one-shot timer always targets the head of the bounded output queue.
- (void)onFrameReady:(dispatch_block_t)render {
    _presentTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, dispatch_get_main_queue());
    dispatch_source_set_event_handler(_presentTimer, render);
    dispatch_source_set_timer(_presentTimer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    dispatch_resume(_presentTimer);
}
- (void)armPresentation {
    if (!_presentTimer || _stopped) return;
    double delay = _pending.count ? MAX(0, _pending.firstObject.deadline-CACurrentMediaTime()) : 0;
    dispatch_time_t fire = _pending.count ? dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay*NSEC_PER_SEC)) : DISPATCH_TIME_FOREVER;
    dispatch_source_set_timer(_presentTimer, fire, DISPATCH_TIME_FOREVER, 0);
}
- (void)startPattern {
    dispatch_async(sessionQueue(), ^{
        if (self.stopped) return;
        self->_pattern = [[FPPattern alloc] initWithWidth:1920 height:1080];
        if (!self->_pattern) { [self fail:@"Could not allocate the test pattern."]; return; }
        self.message = @"Test pattern";
        self->_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, sessionQueue());
        double origin = CACurrentMediaTime();
        dispatch_source_set_timer(self->_timer, DISPATCH_TIME_NOW, NSEC_PER_SEC/30, NSEC_PER_MSEC);
        __weak FPStream *weakSelf = self;
        dispatch_source_set_event_handler(self->_timer, ^{ @autoreleasepool {
            FPStream *stream = weakSelf;
            if (!stream || stream.stopped) return;
            int64_t index = llround((CACurrentMediaTime() - origin)*30);
            FPFrame *frame = [stream->_pattern frameAtIndex:index];
            if (frame) [stream receive:frame];
        } });
        dispatch_resume(self->_timer);
    });
}
static AVCaptureDeviceFormat *selectFormat(AVCaptureDevice *device, double targetFPS, CMTime *duration) {
    double best = INFINITY;
    AVCaptureDeviceFormat *format = nil;
    for (AVCaptureDeviceFormat *candidate in device.formats) {
        CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(candidate.formatDescription);
        if (dim.width <= 0 || dim.height <= 0) continue;
        for (AVFrameRateRange *range in candidate.videoSupportedFrameRateRanges) {
            double fps = MIN(MAX(targetFPS, range.minFrameRate), range.maxFrameRate);
            if (fps <= 0) continue;
            // Prefer full HD, then a workable transport cadence. Favor 60 over 24 for a 30 Hz game.
            double distance = fabs(log2(dim.width/1920.0)) + fabs(log2(dim.height/1080.0));
            double score = 1000*distance + (dim.width > 1920 || dim.height > 1080 ? 2000 : 0)
                + (fps < targetFPS - 0.2 ? 100 : 0) + fabs(fps-targetFPS);
            if (score >= best) continue;
            format = candidate;
            best = score;
            *duration = fps == range.maxFrameRate ? range.minFrameDuration :
                fps == range.minFrameRate ? range.maxFrameDuration : CMTimeMake(1, (int32_t)targetFPS);
        }
    }
    return format;
}
static BOOL applyCaptureMode(AVCaptureDevice *device, AVCaptureDeviceFormat *format, CMTime duration, NSError **error) {
    if (![device lockForConfiguration:error]) return NO;
    @try {
        device.activeFormat = format;
        device.activeVideoMinFrameDuration = duration;
        device.activeVideoMaxFrameDuration = duration;
    } @catch (NSException *exception) {
        *error = FPError(exception.reason ?: @"The capture card rejected the requested video mode.");
        return NO;
    } @finally {
        [device unlockForConfiguration];
    }
    return YES;
}

static BOOL matchesCaptureMode(AVCaptureDevice *device, AVCaptureDeviceFormat *format, CMTime duration) {
    return CMFormatDescriptionEqual(device.activeFormat.formatDescription, format.formatDescription)
        && CMTIME_IS_NUMERIC(device.activeVideoMinFrameDuration)
        && CMTIME_IS_NUMERIC(device.activeVideoMaxFrameDuration)
        && fabs(CMTimeGetSeconds(CMTimeSubtract(device.activeVideoMinFrameDuration, duration))) < 0.00005
        && fabs(CMTimeGetSeconds(CMTimeSubtract(device.activeVideoMaxFrameDuration, duration))) < 0.00005;
}
- (void)startCapture:(AVCaptureDevice *)device {
    dispatch_async(sessionQueue(), ^{ @autoreleasepool {
        if (self.stopped) return;
        NSError *error = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
        if (!input) { [self fail:error.localizedDescription ?: @"Cannot open the capture card."]; return; }
        AVCaptureSession *session = [AVCaptureSession new];
        AVCaptureVideoDataOutput *output = [AVCaptureVideoDataOutput new];
        output.alwaysDiscardsLateVideoFrames = YES;
        [session beginConfiguration];
        if (![session canAddInput:input]) { [session commitConfiguration]; [self fail:@"Cannot attach the selected card."]; return; }
        [session addInput:input];
        CMTime duration = kCMTimeInvalid;
        AVCaptureDeviceFormat *format = selectFormat(device, self.captureRate, &duration);
        if (!format || !applyCaptureMode(device, format, duration, &error)) {
            [session commitConfiguration]; [self fail:error.localizedDescription ?: @"No usable capture mode."]; return;
        }
        if (![session canAddOutput:output]) { [session commitConfiguration]; [self fail:@"Cannot read frames from the card."]; return; }
        [session addOutput:output];
        NSArray *supported = output.availableVideoCVPixelFormatTypes;
        NSArray *preferred = @[@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            @(kCVPixelFormatType_422YpCbCr8), @(kCVPixelFormatType_422YpCbCr8_yuvs),
            @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange), @(kCVPixelFormatType_32BGRA)];
        NSNumber *selected = nil;
        for (NSNumber *type in preferred) {
            if ([supported containsObject:type]) { selected = type; break; }
        }
        // A nil setting lets AVFoundation negotiate its default uncompressed output.
        output.videoSettings = selected ? @{(id)kCVPixelBufferPixelFormatTypeKey:selected} : nil;
        [output setSampleBufferDelegate:self queue:sessionQueue()];
        [session commitConfiguration];
        self->_capture = session;
        __weak FPStream *weakSelf = self;
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        self->_runtimeObserver = [center addObserverForName:AVCaptureSessionRuntimeErrorNotification object:session queue:nil usingBlock:^(NSNotification *note) {
            NSError *failure = note.userInfo[AVCaptureSessionErrorKey];
            [weakSelf fail:failure.localizedDescription ?: @"The capture session ended."];
        }];
        self->_disconnectObserver = [center addObserverForName:AVCaptureDeviceWasDisconnectedNotification object:device queue:nil usingBlock:^(NSNotification *note) {
            [weakSelf fail:@"Capture card disconnected. Reconnect it and start again."];
        }];
        [session startRunning];
        if (!session.running) { [self fail:@"The card could not start. Close any other capture app and retry."]; return; }
        // The macOS session preset can replace the UVC frame interval as streaming starts.
        if (!matchesCaptureMode(device, format, duration) && !applyCaptureMode(device, format, duration, &error)) {
            [self fail:error.localizedDescription ?: @"Could not restore the requested capture mode."];
            return;
        }
        double activePeriod = CMTimeGetSeconds(device.activeVideoMinFrameDuration);
        self.message = (isfinite(activePeriod) && activePeriod > 0)
            ? [NSString stringWithFormat:@"%@ · %.2f Hz active capture mode", device.localizedName, 1.0/activePeriod]
            : [NSString stringWithFormat:@"%@ · Live capture", device.localizedName];
    } });
}
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool {
        CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sample);
        CMTime time = CMSampleBufferGetPresentationTimeStamp(sample);
        if (pixels && CMTIME_IS_NUMERIC(time) && !self.stopped)
            [self receive:[FPFrame frame:pixels time:CMTimeConvertScale(time, 60000, kCMTimeRoundingMethod_Default)]];
    }
}
- (void)captureOutput:(AVCaptureOutput *)output didDropSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection {
    @synchronized(self) { _drops++; }
}
static double smooth(double old, double value) { return old == 0 ? value : old*0.95 + value*0.05; }
- (FPFrame *)generateBetween:(FPFrame *)a and:(FPFrame *)b {
    NSError *error = nil;
    if (!_interpolator) _interpolator = [[FPInterpolator alloc] initWithWidth:CVPixelBufferGetWidth(b.pixels)
        height:CVPixelBufferGetHeight(b.pixels) engine:self.engine error:&error];
    FPFrame *mid = [_interpolator midpointFrom:a to:b error:&error];
    if (!mid) {
        _generationFailed = YES;
        @synchronized(self) { _genHeight = 0; }
        self.message = [NSString stringWithFormat:@"Source only · %@", error.localizedDescription ?: @"Frame generation unavailable"];
    }
    return mid;
}
// At 60 Hz retain a real middle frame unless its pixels support replacing a
// repeated transport slot. One frame of lookahead distinguishes A,A,B from A,B,C.
- (void)receiveFastFrame:(FPFrame *)frame {
    FPImageChange change = FPCompareFrames(_previous.pixels, frame.pixels);
    if (_beforePrevious) {
        FPFrame *output = _previous;
        BOOL candidate = FPLikelyRepeatedSlot(_lastChange,change) && change.mean < 24;
        if (candidate) {
            FPFrame *mid = [self generateBetween:_beforePrevious and:frame];
            if(mid) {
                output = [FPFrame frame:mid.pixels time:_previous.time];
                output.receivedAt = frame.receivedAt;
            }
        }
        double now = CACurrentMediaTime();
        output.readyAt = now;
        @synchronized(self) {
            if (_stopped) return;
            if (output == _previous) _sourceCount++;
            else {
                _generatedCount++;
                _genHeight = CVPixelBufferGetHeight(output.pixels);
                _genMs = smooth(_genMs,1000*(now-frame.receivedAt));
            }
            double pts = CMTimeGetSeconds(output.time);
            if (!isfinite(_anchor) || _anchor+pts < now-0.012 || _anchor+pts > now+0.035)
                _anchor = now+(self.lowLatency ? 0.003 : 1.0/60)-pts;
            [self enqueue:output at:_anchor+pts];
        }
    }
    _beforePrevious = _previous; _previous = frame; _lastChange = change;
}
- (void)receive:(FPFrame *)frame {
    size_t width = CVPixelBufferGetWidth(frame.pixels), height = CVPixelBufferGetHeight(frame.pixels);
    frame.receivedAt = CACurrentMediaTime();
    BOOL resized;
    @synchronized(self) {
        _inputCount++; _lastInputAt = CACurrentMediaTime();
        resized = width != _width || height != _height;
        _width = width; _height = height;
    }
    if (resized) { _beforePrevious = nil; _previous = nil; _interpolator = nil; _generationFailed = NO; }
    double delta = _previous ? CMTimeGetSeconds(CMTimeSubtract(frame.time, _previous.time)) : 0;
    BOOL reset = !_previous || delta <= 0 || delta > 0.055;
    if (_generate && !_generationFailed && !reset && delta < 0.0245) {
        [self receiveFastFrame:frame];
        return;
    }
    // A gap after a high-rate run is a discontinuity, not evidence of 30 Hz content.
    if (_beforePrevious) reset = YES;
    _beforePrevious = nil;
    FPFrame *mid = nil;
    if (_generate && !_generationFailed && !reset) {
        FPImageChange change = FPCompareFrames(_previous.pixels,frame.pixels);
        if (!change.identical && change.mean < 24) mid = [self generateBetween:_previous and:frame];
    }
    _previous = frame;
    @synchronized(self) {
        if (_stopped) return;
        _sourceCount++;
        double now = CACurrentMediaTime();
        frame.readyAt = now;
        if (mid) {
            mid.receivedAt = frame.receivedAt;
            mid.readyAt = now;
            _genMs = smooth(_genMs, (now-frame.receivedAt)*1000);
        }
        if (!mid) {
            _drops += _pending.count; [_pending removeAllObjects]; _anchor = NAN;
            [self enqueue:frame at:now];
            return;
        }
        _generatedCount++;
        _genHeight = CVPixelBufferGetHeight(mid.pixels);
        double pts = CMTimeGetSeconds(mid.time);
        if (!isfinite(_anchor) || _anchor+pts < now-0.020 || _anchor+pts > now+0.050) {
            _drops += _pending.count; [_pending removeAllObjects];
            _anchor = now + (self.lowLatency ? 0.003 : 1.0/60.0) - pts;
        }
        // Leave a few ms for variation in USB delivery, then follow the media
        // clock. A delayed capture immediately shortens the next wait.
        if (self.lowLatency) _anchor = MIN(MAX(_anchor, now-pts), now+0.004-pts);
        [self enqueue:mid at:_anchor+pts];
        [self enqueue:frame at:_anchor+CMTimeGetSeconds(frame.time)];
    }
}
- (void)enqueue:(FPFrame *)frame at:(double)deadline {
    if (_pending.count >= 4) { [_pending removeObjectAtIndex:0]; _drops++; }
    FPTimedFrame *entry = [FPTimedFrame new];
    entry.frame = frame; entry.deadline = deadline; frame.targetTime = deadline;
    [_pending addObject:entry];
    [self armPresentation];
}
- (FPFrame *)frameDueAt:(double)hostTime {
    @synchronized(self) {
        // The capture clock and display clock run independently. Take the slot
        // closest to this refresh, keeping adjacent frames in order at the boundary.
        const double halfRefresh = 0.5/60.0;
        while (_pending.count > 1 && _pending[1].deadline <= hostTime-halfRefresh) {
            [_pending removeObjectAtIndex:0];
            _drops++;
        }
        if (!_pending.count || _pending[0].deadline > hostTime+(_presentTimer ? 0.0001 : halfRefresh)) {
            [self armPresentation]; return nil;
        }
        FPFrame *frame = _pending[0].frame;
        [_pending removeObjectAtIndex:0];
        [self armPresentation];
        return frame;
    }
}
- (void)didPresentAt:(double)time frame:(FPFrame *)frame submittedAt:(double)submitted {
    @synchronized(self) {
        _presentedCount++;
        _waitMs = smooth(_waitMs, MAX(0,submitted-frame.readyAt)*1000);
        _deliveryMs = smooth(_deliveryMs, MAX(0,time-frame.receivedAt)*1000);
    }
}
- (void)recordRenderGPUTime:(double)seconds {
    if (seconds > 0) @synchronized(self) { _scaleMs = smooth(_scaleMs, seconds*1000); }
}
- (NSString *)timingSummary {
    @synchronized(self) {
        return [NSString stringWithFormat:@"Generation %.1f ms   ·   Render GPU %.1f ms   ·   Queue %.1f ms   ·   Delivery to display %.1f ms",
            _genMs, _scaleMs, _waitMs, _deliveryMs];
    }
}
- (NSString *)statisticsAt:(double)now drawableSize:(CGSize)size {
    @synchronized(self) {
        double dt = MAX(0.001, now-_lastReport);
        NSString *detail = [NSString stringWithFormat:@"%zu×%zu in  ·  %.0f received  /  %.0f source  /  %.0f generated  /  %.0f shown per sec  ·  %.0f×%.0f out  ·  %lu drops",
            _width, _height, (_inputCount-_lastInput)/dt, (_sourceCount-_lastSource)/dt, (_generatedCount-_lastGenerated)/dt,
            (_presentedCount-_lastPresented)/dt, size.width, size.height, (unsigned long)_drops];
        _lastReport=now; _lastInput=_inputCount; _lastSource=_sourceCount; _lastGenerated=_generatedCount; _lastPresented=_presentedCount;
        if (!_width) return @"Waiting for video frames";
        if (now-_lastInputAt > 2) return @"No incoming frames · Check the HDMI signal and the selected input";
        if (_genHeight) detail = [detail stringByAppendingFormat:@"  ·  %zup generation", _genHeight];
        return detail;
    }
}
- (void)stop {
    @synchronized(self) { if (_stopped) return; _stopped = YES; [_pending removeAllObjects];
        if (_presentTimer) { dispatch_source_cancel(_presentTimer); _presentTimer = nil; } }
    dispatch_async(sessionQueue(), ^{
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        if (self->_runtimeObserver) [center removeObserver:self->_runtimeObserver];
        if (self->_disconnectObserver) [center removeObserver:self->_disconnectObserver];
        if (self->_timer) { dispatch_source_cancel(self->_timer); self->_timer = nil; }
        [self->_capture stopRunning];
        self->_capture = nil; self->_previous = nil; self->_beforePrevious = nil; self->_interpolator = nil; self->_pattern = nil;
    });
}
@end
