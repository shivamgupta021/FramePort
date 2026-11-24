#import "SourceCadence.h"
#import "Cadence.h"

static BOOL isNV12(CVPixelBufferRef buffer) {
    OSType format = CVPixelBufferGetPixelFormatType(buffer);
    return format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
}

@implementation FPSourceCadence {
    PreviewSlot *_latestOriginal;
    CMTime _lastInputTime;
    BOOL _hadRepeat;
}
- (void)reset {
    _previousOriginal = _latestOriginal = nil;
    _lastInputTime = kCMTimeInvalid;
    _hadRepeat = NO;
}
- (FPSourceDecision)acceptOriginal:(PreviewSlot *)original {
    FPFrame *picture = original.frame;
    if (!isNV12(picture.pixels)) {
        [self reset];
        return FPSourceUnsupported;
    }
    double delta = CMTimeGetSeconds(CMTimeSubtract(picture.time, _lastInputTime));
    double distance = CMTimeGetSeconds(CMTimeSubtract(picture.time, _latestOriginal ? _latestOriginal.frame.time : kCMTimeInvalid));
    _lastInputTime = picture.time;
    _previousOriginal = _latestOriginal;
    if (!_latestOriginal || !(delta > 0 && delta < .046) ||
        CVPixelBufferGetWidth(picture.pixels) != CVPixelBufferGetWidth(_latestOriginal.frame.pixels) ||
        CVPixelBufferGetHeight(picture.pixels) != CVPixelBufferGetHeight(_latestOriginal.frame.pixels) ||
        CVPixelBufferGetPixelFormatType(picture.pixels) != CVPixelBufferGetPixelFormatType(_latestOriginal.frame.pixels)) {
        _latestOriginal = original;
        _previousOriginal = nil;
        _hadRepeat = NO;
        return FPSourceDiscontinuity;
    }

    FPImageChange change = FPCompareFrames(_latestOriginal.frame.pixels, picture.pixels);
    BOOL nearRepeat = change.hasLuma && change.mean < .24 && change.changedFraction < .0005;
    BOOL repeated = delta < .0245 && distance < .022 && (change.identical || nearRepeat);
    if (repeated) {
        _hadRepeat = YES;
        return FPSourceRepeat;
    }

    _latestOriginal = original;
    BOOL pairAt30 = distance > .022 && distance < .046 && (delta > .025 || _hadRepeat);
    _hadRepeat = NO;
    if (!pairAt30 || !isfinite(change.mean)) return FPSourceOriginal;
    if (!change.identical && change.mean < 24 && (change.mean > .35 || change.changedFraction > .00016))
        return FPSourceInterpolate;
    return FPSourceHold;
}
@end
