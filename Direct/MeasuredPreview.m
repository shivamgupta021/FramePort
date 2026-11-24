#import "MeasuredPreview.h"
#import "PlaybackPicture.h"
#import <CoreImage/CoreImage.h>
#import <QuartzCore/CADisplayLink.h>
#import <AppKit/NSView.h>

#import "SourceCadence.h"
#import "Cadence.h"

@interface MeasuredPreview ()
@property(atomic, readwrite, copy) NSString *generationError;
@end

@implementation MeasuredPreview {
    CIContext *_context;
    id<MTLCommandQueue> _queue;
    CGColorSpaceRef _colorSpace;
    dispatch_queue_t _generationQueue;
    CADisplayLink *_displayLink;
    dispatch_queue_t _renderQueue;
    BOOL _renderBusy;
    BOOL _generationBusy;
    double _retryAt;
    FPFramePresentation *_presentation;
    NSUInteger _epoch, _captureEpoch;
    BOOL _visible, _generationEnabled;
    CGSize _inputSize;
    NSUInteger _received, _presented, _originalPresented, _generatedPresented, _timed, _captureDrops;
    NSUInteger _intervals[1002];
    FPSourceTiming _sourceTiming;
    double _captureDelay, _deliveryDelay, _lastRead, _lastPresented;
    // The capture queue owns the reference history. The generation queue owns the engine.
    PlaybackPicture *_picture;
    FPInterpolator *_engine;
    FPGenerationEngine _generationEngine, _preparedEngine;
    FPSourceCadence *_cadence;
    size_t _engineWidth, _engineHeight;
    NSUInteger _workerEpoch;
    FPFrameConverter *_captureConverter; // Owned by the generation queue.
    size_t _converterWidth, _converterHeight;
    BOOL _unsupportedLayout;
}
- (instancetype)init {
    if (!(self=[super init])) return nil;
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    _queue=[device newCommandQueue];
    if (!_queue) return nil;
    _context=[CIContext contextWithMTLCommandQueue:_queue options:@{kCIContextCacheIntermediates:@NO}];
    _colorSpace=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    _layer=[CAMetalLayer layer];
    _layer.device=device; _layer.pixelFormat=MTLPixelFormatBGRA8Unorm;
    _layer.colorspace=_colorSpace; _layer.framebufferOnly=NO; _layer.displaySyncEnabled=YES; _layer.opaque=YES;
    _presentation=[FPFramePresentation new];
    _cadence=[FPSourceCadence new];
    _layer.maximumDrawableCount=2;
    _generationQueue=dispatch_queue_create("local.secondframe.generation",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0));
    _renderQueue = dispatch_queue_create("local.secondframe.display",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0));
    _generationEngine=FPGenerationGuided;
    _generationEnabled=YES;
    _pictureOptions=FPDetailPictureOptions();
    _lastRead=CACurrentMediaTime();
    return self;
}
- (void)dealloc {
    [_displayLink invalidate];
    if (_colorSpace) CGColorSpaceRelease(_colorSpace);
}
- (void)startPresentationInView:(NSView *)view {
    if (_displayLink) return;
    _displayLink = [view displayLinkWithTarget:self selector:@selector(displayLinkFired:)];
    _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(60, 60, 60);
    _displayLink.paused = !self.visible;
    [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
- (void)stopPresentation {
    [_displayLink invalidate];
    _displayLink = nil;
    self.visible = NO;
}
- (BOOL)visible { @synchronized(self) { return _visible; } }
- (void)setVisible:(BOOL)value {
    @synchronized(self) {
        if (_visible==value) return;
        _visible=value; _epoch++; [_presentation reset]; _lastPresented=0;
    }
    _displayLink.paused = !value;
}
- (BOOL)generationEnabled { @synchronized(self) { return _generationEnabled; } }
- (void)setGenerationEnabled:(BOOL)value {
    @synchronized(self) {
        if (_generationEnabled==value) return;
        _generationEnabled=value; _epoch++; [_presentation reset];
        if (value) self.generationError = nil;
    }
}
- (FPGenerationEngine)generationEngine { @synchronized(self) { return _generationEngine; } }
- (void)setGenerationEngine:(FPGenerationEngine)engine {
    @synchronized(self) {
        if (_generationEngine==engine) return;
        _generationEngine=engine;
        self.generationError = nil;
        _epoch++;
        [_presentation reset];
    }
}
- (void)prepareGenerationForWidth:(size_t)width height:(size_t)height {
    FPGenerationEngine selected = self.generationEngine;
    dispatch_sync(_generationQueue, ^{
        self.generationError = [self prepareEngine:selected width:width height:height];
    });
}
- (FPInterpolator *)newInterpolatorForEngine:(FPGenerationEngine)engine width:(size_t)width
                                       height:(size_t)height error:(NSError **)error {
    return [[FPInterpolator alloc] initWithWidth:width height:height engine:engine error:error];
}
- (NSString *)prepareEngine:(FPGenerationEngine)engine width:(size_t)width height:(size_t)height {
    NSError *error = nil;
    _engine = [self newInterpolatorForEngine:engine width:width height:height error:&error];
    _preparedEngine = engine;
    _engineWidth = width;
    _engineHeight = height;
    return _engine ? nil : (error.localizedDescription ?: @"Interpolation unavailable");
}
- (void)captureDropped {
    [_cadence reset];
    @synchronized(self) {
        _captureDrops++;
        [_presentation cancelMidpoint];
    }
}
static BOOL needsConversion(FPFrame *frame) {
    return CVPixelBufferGetPixelFormatType(frame.pixels) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        !CVPixelBufferGetIOSurface(frame.pixels);
}
- (void)generateFrom:(PreviewSlot *)previous to:(PreviewSlot *)original engine:(FPGenerationEngine)selected
               epoch:(NSUInteger)epoch version:(NSUInteger)version {
    @autoreleasepool {
        if (_workerEpoch != epoch) {
            _workerEpoch = epoch;
            _retryAt = 0;
        }
        size_t width = CVPixelBufferGetWidth(original.frame.pixels);
        size_t height = CVPixelBufferGetHeight(original.frame.pixels);
        if (_preparedEngine != selected || _engineWidth != width || _engineHeight != height) {
            _engine = nil;
            _retryAt = 0;
        }
        NSString *failure = nil;
        FPFrame *frame = nil;
        FPFrameKind kind = FPFrameGenerated;
        double now = CACurrentMediaTime();
        if (now >= _retryAt) {
            FPFrame *before = previous.frame, *after = original.frame;
            BOOL normalize = needsConversion(before) || needsConversion(after);
            if (normalize) {
                if (!_captureConverter || _converterWidth != width || _converterHeight != height) {
                    _captureConverter = [[FPFrameConverter alloc] initWithWidth:width height:height];
                    _converterWidth = width;
                    _converterHeight = height;
                }
                before = [_captureConverter convert:before];
                after = [_captureConverter convert:after];
            }
            if (!before || !after) {
                failure = @"Could not convert the capture format for frame generation. Showing originals.";
                _retryAt = now + .10;
            } else if (normalize && FPCompareFrames(before.pixels, after.pixels).mean >= 24) {
                frame = previous.frame;
                kind = FPFrameHeld;
            } else {
                if (!_engine) {
                    failure = [self prepareEngine:selected width:width height:height];
                    if (failure) _retryAt = now + 1;
                }
                if (_engine) {
                    NSError *error = nil;
                    // Generation has its own Metal queue. Its GPU work cannot
                    // block the original's command buffer on the display queue.
                    frame = [_engine midpointFrom:before to:after error:&error];
                    if (!frame) {
                        failure = error.localizedDescription ?: @"Interpolation unavailable";
                        _engine = nil;
                        _retryAt = CACurrentMediaTime() + .10;
                    }
                }
            }
        }
        @synchronized(self) {
            _generationBusy = NO;
            if (epoch != _epoch) return;
            if (frame) {
                self.generationError = nil;
                PreviewSlot *midpoint = [PreviewSlot slotWithFrame:frame capture:(previous.capture+original.capture)*.5
                    delivery:(previous.delivery+original.delivery)*.5 kind:kind];
                [_presentation publishMidpoint:midpoint forVersion:version];
            } else {
                if (failure) self.generationError = failure;
                [_presentation skipMidpointForVersion:version kind:FPFrameGenerated];
            }
        }
    }
}
- (void)displaySample:(CMSampleBufferRef)sample captureTime:(double)captureTime deliveryTime:(double)deliveryTime {
    CVPixelBufferRef pixels=CMSampleBufferGetImageBuffer(sample);
    if (!pixels) return;
    size_t width=CVPixelBufferGetWidth(pixels), height=CVPixelBufferGetHeight(pixels);
    NSUInteger epoch;
    BOOL enabled;
    FPGenerationEngine selectedEngine;
    @synchronized(self) {
        _received++;
        _inputSize=CGSizeMake(width,height);
        if (!_visible) return;
        epoch=_epoch; enabled=_generationEnabled; selectedEngine=_generationEngine;
    }
    if (epoch!=_captureEpoch) { [_cadence reset]; _captureEpoch=epoch; }
    if (!_picture) _picture=[[PlaybackPicture alloc] initWithSample:sample];
    FPFrame *input=[_picture frameFromSample:sample];
    PreviewSlot *real=[PreviewSlot slotWithFrame:input capture:captureTime delivery:deliveryTime kind:FPFrameOriginal];

    FPSourceDecision decision = enabled ? [_cadence acceptOriginal:real] : FPSourceOriginal;
    if (decision == FPSourceRepeat) return;
    PreviewSlot *previous = _cadence.previousOriginal;
    @synchronized(self) {
        if (_epoch != epoch || !_visible) return;
        if (decision == FPSourceUnsupported && !_unsupportedLayout) {
            _unsupportedLayout = YES;
            _epoch++;
            self.generationError = @"The capture format is unsupported for frame generation. Showing originals.";
        } else if (enabled && decision != FPSourceUnsupported && _unsupportedLayout) {
            _unsupportedLayout = NO;
            self.generationError = nil;
        }
        if (decision == FPSourceDiscontinuity) [_presentation cancelMidpoint];
        BOOL interpolate = decision == FPSourceInterpolate && !_generationBusy;
        BOOL hold = decision == FPSourceHold && !self.generationError;
        NSUInteger version = [_presentation publishOriginal:real expectsMidpoint:interpolate || hold
            now:isfinite(deliveryTime) ? deliveryTime : CACurrentMediaTime()];
        if (hold) {
            PreviewSlot *midpoint = [PreviewSlot slotWithFrame:previous.frame
                capture:(previous.capture+captureTime)*.5 delivery:(previous.delivery+deliveryTime)*.5 kind:FPFrameHeld];
            [_presentation publishMidpoint:midpoint forVersion:version];
        }
        if (decision != FPSourceInterpolate) return;
        if (!interpolate || ![_presentation acceptsMidpointForVersion:version]) {
            [_presentation skipMidpointForVersion:version kind:FPFrameGenerated];
            return;
        }
        _generationBusy = YES;
        dispatch_async(_generationQueue, ^{
            [self generateFrom:previous to:real engine:selectedEngine epoch:epoch version:version];
        });
    }
}
- (PreviewSlot *)frameForDisplayTime:(double)target interval:(double)interval now:(double)now epoch:(NSUInteger *)epoch {
    @synchronized(self) {
        if (!_visible) return nil;
        if (epoch) *epoch = _epoch;
        return [_presentation takeForDisplayTime:target interval:interval now:now];
    }
}
- (void)displayLinkFired:(CADisplayLink *)link {
    double target = link.targetTimestamp;
    double interval = target - link.timestamp;
    @synchronized(self) {
        if (!_visible || _renderBusy || !_presentation.hasPendingFrame) return;
        _renderBusy = YES;
    }
    dispatch_async(_renderQueue, ^{
        @autoreleasepool {
            id<CAMetalDrawable> drawable = [self->_layer nextDrawable];
            if (drawable) {
                NSUInteger epoch;
                PreviewSlot *frame = [self frameForDisplayTime:target interval:interval
                    now:CACurrentMediaTime() epoch:&epoch];
                if (frame) [self draw:frame on:drawable epoch:epoch];
            }
            @synchronized(self) { self->_renderBusy = NO; }
        }
    });
}
- (void)draw:(PreviewSlot *)slot on:(id<CAMetalDrawable>)drawable epoch:(NSUInteger)epoch {
    id<MTLCommandBuffer> command=[_queue commandBuffer];
    if (!drawable || !command) { @synchronized(self) { [_presentation markDropped:slot]; } return; }
    CGRect output=CGRectMake(0,0,drawable.texture.width,drawable.texture.height);
    CIImage *image=[_picture imageForFrame:slot.frame size:output.size options:self.pictureOptions];
    [_context render:image toMTLTexture:drawable.texture commandBuffer:command bounds:output colorSpace:_colorSpace];
    [command addCompletedHandler:^(id<MTLCommandBuffer> done) {
        (void)slot.frame;
        if (done.status==MTLCommandBufferStatusError) NSLog(@"Preview render failed: %@",done.error);
    }];
    double submitted=CACurrentMediaTime();
    [drawable addPresentedHandler:^(id<MTLDrawable> frame) {
        double shown=frame.presentedTime;
        @synchronized(self) {
            if (self->_epoch!=epoch) return;
            if (shown<=0) { [self->_presentation markDropped:slot]; return; }
            self->_presented++; self->_originalPresented+=slot.originalSample; self->_generatedPresented+=slot.generated;
            self->_deliveryDelay+=shown-slot.delivery;
            if (slot.originalSample) FPRecordSourceTiming(&self->_sourceTiming,slot.capture,slot.delivery,submitted,shown);
            if (isfinite(slot.capture) && slot.capture<=shown) {
                self->_timed++; self->_captureDelay+=shown-slot.capture;
            }
            double interval=shown-self->_lastPresented;
            if (self->_lastPresented>0 && interval>0)
                self->_intervals[MIN(1001,lround(interval*10000))]++;
            self->_lastPresented=MAX(shown,self->_lastPresented);
        }
    }];
    [command presentDrawable:drawable];
    [command commit];
}
- (PreviewStatistics)readStatistics {
    @synchronized(self) {
        double now=CACurrentMediaTime(), dt=MAX(now-_lastRead, .000001);
        NSUInteger total=0, cum=0;
        double p95=NAN;
        for (int i=0;i<1002;i++) total+=_intervals[i];
        for (int i=0;total && i<1002;i++) {
            cum+=_intervals[i];
            if (cum>=ceil(.95*total)) { p95=i*.1; break; }
        }
        FPFrameDrops drops=_presentation.drops;
        PreviewStatistics result={ .inputSize=_inputSize, .inputFPS=_received/dt, .outputFPS=_presented/dt,
            .originalFPS=_originalPresented/dt, .generatedFPS=_generatedPresented/dt, .intervalP95MS=p95,
            .captureToPresentMS=_timed ? _captureDelay*1000/_timed : NAN,
            .deliveryToPresentMS=_presented ? _deliveryDelay*1000/_presented : NAN,
            .captureDrops=_captureDrops,.previewDrops=drops.originals+drops.generated+drops.held, .originalDrops=drops.originals, .generatedDrops=drops.generated, .heldDrops=drops.held, .realFrameMS=FPSourceTimingMeanMS(_sourceTiming) };
        _lastRead=now; _received=_presented=_originalPresented=_generatedPresented=_timed=0;
        _sourceTiming=(FPSourceTiming){0};
        _captureDelay=_deliveryDelay=0; memset(_intervals,0,sizeof(_intervals));
        return result;
    }
}
@end
