#import "FramePresentation.h"

typedef NS_ENUM(NSUInteger, FPSourceDecision) {
    FPSourceOriginal,
    FPSourceRepeat,
    FPSourceInterpolate,
    FPSourceHold,
    FPSourceDiscontinuity,
    FPSourceUnsupported,
};

/// Selects source pictures from the capture clock and measured image changes.
@interface FPSourceCadence : NSObject
@property(nonatomic, readonly) PreviewSlot *previousOriginal;
- (FPSourceDecision)acceptOriginal:(PreviewSlot *)original;
- (void)reset;
@end
