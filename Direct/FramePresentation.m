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
    PreviewSlot *_original, *_midpoint, *_reservedOriginal;
    double _midpointDeadline;
    BOOL _expectsMidpoint;
}
- (BOOL)hasPendingFrame { return _original || _reservedOriginal; }
- (void)markKindDropped:(FPFrameKind)kind {
    switch (kind) {
        case FPFrameOriginal: _drops.originals++; break;
        case FPFrameGenerated: _drops.generated++; break;
        case FPFrameHeld: _drops.held++; break;
    }
}
- (void)markDropped:(PreviewSlot *)slot {
    if (slot) [self markKindDropped:slot.kind];
}
- (void)reset {
    [self markDropped:_original];
    [self markDropped:_midpoint];
    [self markDropped:_reservedOriginal];
    _original = _midpoint = _reservedOriginal = nil;
    _expectsMidpoint = NO;
    _version++;
}
- (NSUInteger)publishOriginal:(PreviewSlot *)original expectsMidpoint:(BOOL)expectsMidpoint now:(double)now {
    // Backpressure favors the latest original, including over its own midpoint.
    BOOL wasBackedUp = _original != nil;
    [self markDropped:_original];
    [self markDropped:_midpoint];
    _original = original;
    _midpoint = nil;
    _expectsMidpoint = expectsMidpoint && !wasBackedUp;
    // Bound the time spent waiting for generation in the callback clock.
    // The display link's presentation timestamp can be several refreshes ahead.
    _midpointDeadline = now + 2.0 / 60.0;
    return ++_version;
}
- (BOOL)acceptsMidpointForVersion:(NSUInteger)version {
    return _expectsMidpoint && _original && version == _version;
}
- (void)cancelMidpoint {
    [self markDropped:_midpoint];
    _midpoint = nil;
    _expectsMidpoint = NO;
}
- (void)publishMidpoint:(PreviewSlot *)midpoint forVersion:(NSUInteger)version {
    if (![self acceptsMidpointForVersion:version]) {
        [self markDropped:midpoint];
        return;
    }
    [self markDropped:_midpoint];
    _midpoint = midpoint;
}
- (void)skipMidpointForVersion:(NSUInteger)version kind:(FPFrameKind)kind {
    [self markKindDropped:kind];
    if (version == _version) {
        _midpoint = nil;
        _expectsMidpoint = NO;
    }
}
- (PreviewSlot *)takeForDisplayTime:(double)target interval:(double)interval now:(double)now {
    if (_reservedOriginal) {
        PreviewSlot *original = _reservedOriginal;
        _reservedOriginal = nil;
        return original;
    }
    if (!_original) return nil;
    if (_expectsMidpoint && isfinite(target) && target >= now &&
        isfinite(interval) && interval > 0 && now < _midpointDeadline) {
        if (_midpoint && [_midpoint.frame isReadyForQueue:nil]) {
            PreviewSlot *slot = _midpoint;
            _midpoint = nil;
            _expectsMidpoint = NO;
            _reservedOriginal = _original;
            _original = nil;
            return slot;
        }
        if (now + interval < _midpointDeadline) return nil;
    }
    [self markDropped:_midpoint];
    _midpoint = nil;
    _expectsMidpoint = NO;
    PreviewSlot *slot = _original;
    _original = nil;
    return slot;
}
@end
