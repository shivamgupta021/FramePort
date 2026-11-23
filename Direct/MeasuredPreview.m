#import "MeasuredPreview.h"
#import "PlaybackPicture.h"
#import <CoreImage/CoreImage.h>


// A sparse patch comparison distinguishes a moving pedestrian from compression
// noise without reading every pixel on the capture callback.
typedef struct { double mean, changed; } SceneChange;
static SceneChange comparePictures(CVPixelBufferRef a, CVPixelBufferRef b) {
    if (!CVPixelBufferIsPlanar(a) || !CVPixelBufferIsPlanar(b) ||
        CVPixelBufferGetWidth(a) != CVPixelBufferGetWidth(b) || CVPixelBufferGetHeight(a) != CVPixelBufferGetHeight(b))
        return (SceneChange){INFINITY,1};
    if (CVPixelBufferLockBaseAddress(a,kCVPixelBufferLock_ReadOnly)) return (SceneChange){INFINITY,1};
    if (CVPixelBufferLockBaseAddress(b,kCVPixelBufferLock_ReadOnly)) {
        CVPixelBufferUnlockBaseAddress(a,kCVPixelBufferLock_ReadOnly); return (SceneChange){INFINITY,1};
    }
    double sum = 0;
    NSUInteger count = 0, changed = 0;
    for (size_t plane=0; plane<2; ++plane) {
        const uint8_t *left=CVPixelBufferGetBaseAddressOfPlane(a,plane), *right=CVPixelBufferGetBaseAddressOfPlane(b,plane);
        size_t sa=CVPixelBufferGetBytesPerRowOfPlane(a,plane), sb=CVPixelBufferGetBytesPerRowOfPlane(b,plane);
        size_t height=CVPixelBufferGetHeightOfPlane(a,plane), width=CVPixelBufferGetWidth(a);
        size_t channels = plane ? 2 : 1;
        for (size_t y=2; y+2<height; y+=12) for (size_t x=4; x+2*channels<width; x+=16) {
            for (size_t c=0; c<channels; ++c) {
                int delta = 0;
                for (int j=0; j<3; ++j) for (int i=0; i<3; ++i)
                    delta += left[(y+j)*sa+x+i*channels+c] - right[(y+j)*sb+x+i*channels+c];
                sum += abs(delta);
                changed += abs(delta)>9*8;
                count++;
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(b,kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(a,kCVPixelBufferLock_ReadOnly);
    return (SceneChange){sum / MAX(1,9*count),(double)changed / MAX(1,count)};
}

@interface PreviewSlot : NSObject
@property(nonatomic,strong) FPFrame *frame;
@property(nonatomic) double capture, delivery, releaseTime;
@property(nonatomic) BOOL generated;
@end
@implementation PreviewSlot
@end

static PreviewSlot *slotFor(FPFrame *frame, double capture, double delivery, BOOL generated) {
    PreviewSlot *slot = [PreviewSlot new];
    slot.frame=frame; slot.capture=capture; slot.delivery=delivery; slot.generated=generated;
    return slot;
}

@interface MeasuredPreview ()
@property(atomic, readwrite, copy) NSString *generationError;
@end

@implementation MeasuredPreview {
    CIContext *_context;
    id<MTLCommandQueue> _queue;
    CGColorSpaceRef _colorSpace;
    dispatch_queue_t _renderQueue;
    NSUInteger _timerVersion;
    double _pairReadyOffset;
    NSMutableArray<PreviewSlot *> *_pending;
    NSUInteger _epoch, _captureEpoch;
    BOOL _visible, _generationEnabled;
    CGSize _inputSize;
    NSUInteger _received, _presented, _generatedPresented, _changes, _timed, _captureDrops, _previewDrops;
    NSUInteger _intervals[1002];
    double _captureDelay, _deliveryDelay, _lastRead, _lastPresented;
    // The serial capture queue owns the interpolator and reference history.
    PlaybackPicture *_picture;
    FPInterpolator *_engine;
    FPFrame *_previousUSB;
    PreviewSlot *_reference;
    int _phase, _referencePhase;
    double _scores[2];
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
    _pending=[NSMutableArray arrayWithCapacity:3];
    _layer.maximumDrawableCount=2;
    _renderQueue=dispatch_queue_create("local.frameport.presentation",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0));
    _generationEnabled=YES;
    _lastRead=CACurrentMediaTime();
    return self;
}
- (void)dealloc { if (_colorSpace) CGColorSpaceRelease(_colorSpace); }
- (BOOL)visible { @synchronized(self) { return _visible; } }
- (void)setVisible:(BOOL)value {
    @synchronized(self) {
        if (_visible==value) return;
        _visible=value; _epoch++; [_pending removeAllObjects]; _lastPresented=0;
    }

}
- (BOOL)generationEnabled { @synchronized(self) { return _generationEnabled; } }
- (void)setGenerationEnabled:(BOOL)value {
    @synchronized(self) {
        if (_generationEnabled==value) return;
        _generationEnabled=value; _epoch++; [_pending removeAllObjects];
    }
}
- (void)prepareGenerationForWidth:(size_t)width height:(size_t)height {
    NSError *error=nil;
    _engine=[[FPInterpolator alloc] initWithWidth:width height:height engine:FPGenerationGuided error:&error];
    [_engine usePresentationQueue:_queue];
    if (!_engine) self.generationError=error.localizedDescription ?: @"Apple interpolation unavailable";
}
- (void)resetHistory {
    _reference=nil; _previousUSB=nil; _phase=0; _referencePhase=0; _scores[0]=_scores[1]=0; _pairReadyOffset=0;
}
- (void)captureDropped {
    [self resetHistory];
    @synchronized(self) { _captureDrops++; [_pending removeAllObjects]; }
}
- (void)publish:(NSArray<PreviewSlot *> *)slots epoch:(NSUInteger)epoch {
    @synchronized(self) {
        if (_epoch!=epoch || !_visible) return;
        // Each pair supersedes any older frames that missed their display slot.
        _previewDrops+=_pending.count;
        [_pending removeAllObjects];
        [_pending addObjectsFromArray:slots];
        NSUInteger version=++_timerVersion;
        dispatch_async(_renderQueue,^{ [self renderVersion:version]; });

    }
}
- (void)displaySample:(CMSampleBufferRef)sample captureTime:(double)captureTime deliveryTime:(double)deliveryTime {
    CVPixelBufferRef pixels=CMSampleBufferGetImageBuffer(sample);
    if (!pixels) return;
    NSUInteger epoch;
    BOOL enabled;
    @synchronized(self) {
        _received++; _inputSize=CGSizeMake(CVPixelBufferGetWidth(pixels),CVPixelBufferGetHeight(pixels));
        if (!_visible) return;
        epoch=_epoch; enabled=_generationEnabled;
    }
    if (epoch!=_captureEpoch) { [self resetHistory]; _captureEpoch=epoch; }
    if (!_picture) _picture=[[PlaybackPicture alloc] initWithSample:sample];
    FPFrame *input=[_picture frameFromSample:sample];
    pixels=input.pixels;
    PreviewSlot *real=slotFor(input,captureTime,deliveryTime,NO);
    if (!enabled || !_engine || self.generationError) {
        [self publish:@[real] epoch:epoch]; return;
    }
    double dt=_previousUSB ? CMTimeGetSeconds(CMTimeSubtract(input.time,_previousUSB.time)) : 0;
    if (!(dt>0 && dt<.046)) [self resetHistory];
    BOOL transport30=dt>.025 && dt<.046;
    if (!_reference) {
        _reference=real; _previousUSB=input; [self publish:@[real] epoch:epoch]; return;
    }
    SceneChange successive=comparePictures(_previousUSB.pixels,pixels);
    _previousUSB=input;
    if (!transport30) {
        _phase ^= 1;
        _scores[_phase]=.75*_scores[_phase]+.25*MIN(8,successive.mean);
        // Prefer the first delivery of each real game picture. Keep the phase
        // across still or localized movement; windowed USB input stays at 60 Hz.
        int other=1-_referencePhase;
        if (_scores[other]>.09+2.6*_scores[_referencePhase]) _referencePhase=other;
        if (_phase!=_referencePhase) return;
    }
    PreviewSlot *previous=_reference;
    _reference=real;
    double distance=CMTimeGetSeconds(CMTimeSubtract(input.time,previous.frame.time));
    if (!(distance>.022 && distance<.046)) { [self publish:@[real] epoch:epoch]; return; }
    SceneChange pair=transport30 ? successive : comparePictures(previous.frame.pixels,pixels);
    BOOL moving=pair.changed>.00016 || pair.mean>.35;
    if (moving) { @synchronized(self) { _changes++; } }
    FPFrame *mid=nil;
    if (moving && pair.mean<24) {
        NSError *error=nil;
        mid=[_engine midpointFrom:previous.frame to:input error:&error];
        if (!mid) self.generationError=error.localizedDescription ?: @"Interpolation unavailable";
    }
    // The midpoint represents the instant halfway between the two source PTS.
    // During a cut the outgoing image holds until the new real picture is due.
    PreviewSlot *between=slotFor(mid ?: previous.frame,(previous.capture+captureTime)*.5,
                                (previous.delivery+deliveryTime)*.5,mid!=nil);
    // Anchor both slots to the source clock, filtering variation in USB transfer
    // and generation time. The first slot is ready now; the original follows
    // one refresh later. A late pair never adds a full interval to the next pair.
    double now=CACurrentMediaTime();
    double readyOffset=now-captureTime;
    if (isfinite(readyOffset)) {
        if (_pairReadyOffset<=0 || fabs(_pairReadyOffset-readyOffset)>.030) _pairReadyOffset=readyOffset;
        else _pairReadyOffset+=.12*(readyOffset-_pairReadyOffset);
    }
    real.releaseTime=isfinite(captureTime) ? captureTime+_pairReadyOffset+1./60 : now+1./60;
    [self publish:@[between,real] epoch:epoch];
}
- (void)renderVersion:(NSUInteger)version {
    @autoreleasepool {
        @synchronized(self) {
            if (version!=_timerVersion || !_visible || !_pending.count) return;
            double delay=_pending.firstObject.releaseTime-CACurrentMediaTime();
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
            if (version!=_timerVersion || !_visible || !_pending.count) return;
            epoch=_epoch; slot=_pending.firstObject; [_pending removeObjectAtIndex:0];
        }
        [self draw:slot on:drawable epoch:epoch];
        dispatch_async(_renderQueue,^{ [self renderVersion:version]; });
    }
}
- (void)draw:(PreviewSlot *)slot on:(id<CAMetalDrawable>)drawable epoch:(NSUInteger)epoch {
    id<MTLCommandBuffer> command=[_queue commandBuffer];
    if (!drawable || !command) { @synchronized(self) { _previewDrops++; } return; }
    CGRect output=CGRectMake(0,0,drawable.texture.width,drawable.texture.height);
    CIImage *image=[_picture imageForFrame:slot.frame size:output.size];
    [_context render:image toMTLTexture:drawable.texture commandBuffer:command bounds:output colorSpace:_colorSpace];
    [command addCompletedHandler:^(id<MTLCommandBuffer> done) {
        (void)slot.frame;
        if (done.status==MTLCommandBufferStatusError) NSLog(@"Preview render failed: %@",done.error);
    }];
    [drawable addPresentedHandler:^(id<MTLDrawable> frame) {
        double shown=frame.presentedTime;
        @synchronized(self) {
            if (self->_epoch!=epoch) return;
            if (shown<=0) { self->_previewDrops++; return; }
            self->_presented++; self->_generatedPresented+=slot.generated;
            self->_deliveryDelay+=shown-slot.delivery;
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
        PreviewStatistics result={ .inputSize=_inputSize, .inputFPS=_received/dt, .outputFPS=_presented/dt,
            .generatedFPS=_generatedPresented/dt, .changeFPS=_changes/dt, .intervalP95MS=p95,
            .captureToPresentMS=_timed ? _captureDelay*1000/_timed : NAN,
            .deliveryToPresentMS=_presented ? _deliveryDelay*1000/_presented : NAN,
            .captureDrops=_captureDrops,.previewDrops=_previewDrops };
        _lastRead=now; _received=_presented=_generatedPresented=_changes=_timed=0;
        _captureDelay=_deliveryDelay=0; memset(_intervals,0,sizeof(_intervals));
        return result;
    }
}
@end
