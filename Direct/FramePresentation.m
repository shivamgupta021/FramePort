#import "FramePresentation.h"
#import <math.h>

@implementation PreviewSlot
+ (instancetype)slotWithFrame:(FPFrame *)frame capture:(double)capture delivery:(double)delivery kind:(FPFrameKind)kind {
    PreviewSlot *slot = [self new];
    slot->_frame = frame;
    slot->_capture = capture;
    slot->_delivery = delivery;
    slot->_kind = kind;
    return slot;
}
- (BOOL)generated { return self.kind == FPFrameGenerated; }
- (BOOL)originalSample { return self.kind == FPFrameOriginal; }
@end

@implementation FPFramePresentation {
    PreviewSlot *_original, *_midpoint;
    double _originalDue, _observedReadyOffset;
}
- (void)markDropped:(PreviewSlot *)slot {
    if (!slot) return;
    switch (slot.kind) {
        case FPFrameOriginal: _drops.originals++; break;
        case FPFrameGenerated: _drops.generated++; break;
        case FPFrameHeld: _drops.held++; break;
    }
}
- (void)reset {
    _original = _midpoint = nil;
    _observedReadyOffset = 0;
    _originalDue = 0;
    _version++;
}
- (void)publishOriginal:(PreviewSlot *)original midpoint:(PreviewSlot *)midpoint now:(double)now {
    // A backed-up display gets the latest original. Inserting another midpoint
    // ahead of it would consume the display slot the previous original missed.
    if (_original) {
        [self markDropped:midpoint];
        midpoint = nil;
    }
    [self markDropped:_midpoint];
    [self markDropped:_original];
    _original = original;
    _midpoint = midpoint;
    _originalDue = now;
    _version++;
    if (!midpoint) return;

    double readyOffset = now - original.capture;
    if (isfinite(readyOffset)) {
        if (_observedReadyOffset <= 0 || fabs(_observedReadyOffset - readyOffset) > .030)
            _observedReadyOffset = readyOffset;
        else
            _observedReadyOffset += .12 * (readyOffset - _observedReadyOffset);
    }
    double anchor = isfinite(readyOffset) ? original.capture + _observedReadyOffset : now;
    _originalDue = MAX(now, anchor + 1.0 / 60);
}
- (double)delayUntilNextAt:(double)now {
    if (!_original) return INFINITY;
    return _midpoint ? 0 : MAX(0, _originalDue - now);
}
- (PreviewSlot *)takeDueAt:(double)now renderQueue:(id<MTLCommandQueue>)queue {
    if (_midpoint) {
        PreviewSlot *slot = _midpoint;
        _midpoint = nil;
        if (now < _originalDue && [slot.frame isReadyForQueue:queue]) return slot;
        [self markDropped:slot];
        _originalDue = now;
    }
    if (now < _originalDue) return nil;
    PreviewSlot *slot = _original;
    _original = nil;
    return slot;
}
@end
