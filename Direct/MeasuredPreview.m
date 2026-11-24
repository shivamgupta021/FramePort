#import "MeasuredPreview.h"
#import "PlaybackPicture.h"
#import <CoreImage/CoreImage.h>

#import "SourceCadence.h"

@interface MeasuredPreview ()
@property(atomic, readwrite, copy) NSString *generationError;
@end

@implementation MeasuredPreview {
    CIContext *_context;
    id<MTLCommandQueue> _queue;
    CGColorSpaceRef _colorSpace;
    dispatch_queue_t _renderQueue;
    FPFramePresentation *_presentation;
    NSUInteger _epoch, _captureEpoch;
    BOOL _visible, _generationEnabled;
    CGSize _inputSize;
    NSUInteger _received, _presented, _originalPresented, _generatedPresented, _changes, _timed, _captureDrops;
    NSUInteger _intervals[1002];
    FPSourceTiming _sourceTiming;
    double _captureDelay, _deliveryDelay, _lastRead, _lastPresented;
    // The serial capture queue owns the interpolator and reference history.
    PlaybackPicture *_picture;
    FPInterpolator *_engine;
    FPGenerationEngine _generationEngine, _preparedEngine;
    FPSourceCadence *_cadence;
    size_t _engineWidth, _engineHeight;
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
    _renderQueue=dispatch_queue_create("local.frameport.presentation",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0));
    _generationEngine=FPGenerationGuided;
    _generationEnabled=YES;
    _pictureOptions=FPDetailPictureOptions();
    _lastRead=CACurrentMediaTime();
    return self;
}
- (void)dealloc { if (_colorSpace) CGColorSpaceRelease(_colorSpace); }
- (BOOL)visible { @synchronized(self) { return _visible; } }
- (void)setVisible:(BOOL)value {
    @synchronized(self) {
        if (_visible==value) return;
        _visible=value; _epoch++; [_presentation reset]; _lastPresented=0;
    }

}
- (BOOL)generationEnabled { @synchronized(self) { return _generationEnabled; } }
- (void)setGenerationEnabled:(BOOL)value {
    @synchronized(self) {
        if (_generationEnabled==value) return;
        _generationEnabled=value; _epoch++; [_presentation reset];
    }
}
- (FPGenerationEngine)generationEngine { @synchronized(self) { return _generationEngine; } }
- (void)setGenerationEngine:(FPGenerationEngine)engine {
    @synchronized(self) {
        if (_generationEngine==engine) return;
        _generationEngine=engine;
        _epoch++;
        [_presentation reset];
    }
}
- (void)prepareGenerationForWidth:(size_t)width height:(size_t)height {
    [self prepareEngine:self.generationEngine width:width height:height];
}
// Initial setup occurs before capture starts. Live switches occur on the serial capture queue.
- (void)prepareEngine:(FPGenerationEngine)engine width:(size_t)width height:(size_t)height {
    NSError *error=nil;
    _engine=[[FPInterpolator alloc] initWithWidth:width height:height engine:engine error:&error];
    [_engine usePresentationQueue:_queue];
    _preparedEngine=engine;
    _engineWidth=width;
    _engineHeight=height;
    self.generationError=_engine ? nil : (error.localizedDescription ?: @"Interpolation unavailable");
}
- (void)captureDropped {
    [_cadence reset];
    @synchronized(self) {
        _captureDrops++;
        _epoch++;
        [_presentation reset];
    }
}
- (void)publishOriginal:(PreviewSlot *)original midpoint:(PreviewSlot *)midpoint epoch:(NSUInteger)epoch {
    @synchronized(self) {
        if (_epoch!=epoch || !_visible) return;
        [_presentation publishOriginal:original midpoint:midpoint now:CACurrentMediaTime()];
        NSUInteger version=_presentation.version;
        dispatch_async(_renderQueue,^{ [self renderVersion:version]; });
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

    if (!enabled) {
        [self publishOriginal:real midpoint:nil epoch:epoch];
        return;
    }

    FPSourceDecision decision=[_cadence acceptOriginal:real];
    if (decision==FPSourceUnsupported) {
        if (!_unsupportedLayout) self.generationError=@"The capture device is not delivering NV12. Showing original frames.";
        _unsupportedLayout=YES;
        [self publishOriginal:real midpoint:nil epoch:epoch];
        return;
    }
    if (_unsupportedLayout || _preparedEngine!=selectedEngine || _engineWidth!=width || _engineHeight!=height) {
        _unsupportedLayout=NO;
        [self prepareEngine:selectedEngine width:width height:height];
    }
    if (!_engine || self.generationError) {
        [self publishOriginal:real midpoint:nil epoch:epoch];
        return;
    }

    if (decision==FPSourceRepeat) return;
    if (decision==FPSourceDiscontinuity) {
        @synchronized(self) { if (_epoch==epoch) [_presentation reset]; }
    }
    if (decision!=FPSourceInterpolate && decision!=FPSourceHold) {
        [self publishOriginal:real midpoint:nil epoch:epoch];
        return;
    }

    PreviewSlot *previous=_cadence.previousOriginal;
    FPFrame *mid=nil;
    if (decision==FPSourceInterpolate) {
        @synchronized(self) { _changes++; }
        NSError *error=nil;
        mid=[_engine midpointFrom:previous.frame to:input error:&error];
        if (!mid) {
            self.generationError=error.localizedDescription ?: @"Interpolation unavailable";
            [self publishOriginal:real midpoint:nil epoch:epoch];
            return;
        }
    }

    PreviewSlot *between=[PreviewSlot slotWithFrame:mid ?: previous.frame
        capture:(previous.capture+captureTime)*.5 delivery:(previous.delivery+deliveryTime)*.5
        kind:mid ? FPFrameGenerated : FPFrameHeld];
    [self publishOriginal:real midpoint:between epoch:epoch];
}
- (void)renderVersion:(NSUInteger)version {
    @autoreleasepool {
        @synchronized(self) {
            if (version!=_presentation.version || !_visible) return;
            double delay=[_presentation delayUntilNextAt:CACurrentMediaTime()];
            if (!isfinite(delay)) return;
            if (delay>0) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),_renderQueue,^{
                    [self renderVersion:version];
                });
                return;
            }
        }
        id<CAMetalDrawable> drawable=[_layer nextDrawable];
        PreviewSlot *slot;
        NSUInteger epoch;
        @synchronized(self) {
            if (version!=_presentation.version || !_visible) return;
            epoch=_epoch;
            slot=[_presentation takeDueAt:CACurrentMediaTime() renderQueue:_queue];
        }
        if (slot) [self draw:slot on:drawable epoch:epoch];
        dispatch_async(_renderQueue,^{ [self renderVersion:version]; });
    }
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
        double now=CACurrentMediaTime(), dt=now-_lastRead;
        NSUInteger total=0, cum=0;
        double p95=NAN;
        for (int i=0;i<1002;i++) total+=_intervals[i];
        for (int i=0;total && i<1002;i++) {
            cum+=_intervals[i];
            if (cum>=ceil(.95*total)) { p95=i*.1; break; }
        }
        FPFrameDrops drops=_presentation.drops;
        PreviewStatistics result={ .inputSize=_inputSize, .inputFPS=_received/dt, .outputFPS=_presented/dt,
            .originalFPS=_originalPresented/dt, .generatedFPS=_generatedPresented/dt, .changeFPS=_changes/dt, .intervalP95MS=p95,
            .captureToPresentMS=_timed ? _captureDelay*1000/_timed : NAN,
            .deliveryToPresentMS=_presented ? _deliveryDelay*1000/_presented : NAN,
            .captureDrops=_captureDrops,.previewDrops=drops.originals+drops.generated+drops.held, .originalDrops=drops.originals, .generatedDrops=drops.generated, .realFrameMS=FPSourceTimingMeanMS(_sourceTiming) };
        _lastRead=now; _received=_presented=_originalPresented=_generatedPresented=_changes=_timed=0;
        _sourceTiming=(FPSourceTiming){0};
        _captureDelay=_deliveryDelay=0; memset(_intervals,0,sizeof(_intervals));
        return result;
    }
}
@end
