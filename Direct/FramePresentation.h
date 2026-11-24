#import "Video.h"

typedef NS_ENUM(NSUInteger, FPFrameKind) {
    FPFrameOriginal,
    FPFrameGenerated,
    FPFrameHeld,
};

@interface PreviewSlot : NSObject
@property(nonatomic, readonly) FPFrame *frame;
@property(nonatomic, readonly) double capture, delivery;
@property(nonatomic, readonly) FPFrameKind kind;
@property(nonatomic, readonly) BOOL generated, originalSample;
+ (instancetype)slotWithFrame:(FPFrame *)frame capture:(double)capture delivery:(double)delivery kind:(FPFrameKind)kind;
@end

typedef struct {
    NSUInteger originals, generated, held;
} FPFrameDrops;

/// The caller serializes access and supplies one monotonic host clock.
@interface FPFramePresentation : NSObject
@property(nonatomic, readonly) NSUInteger version;
@property(nonatomic, readonly) FPFrameDrops drops;
- (void)reset;
- (void)publishOriginal:(PreviewSlot *)original midpoint:(PreviewSlot *)midpoint now:(double)now;
- (double)delayUntilNextAt:(double)now;
- (PreviewSlot *)takeDueAt:(double)now renderQueue:(id<MTLCommandQueue>)queue;
- (void)markDropped:(PreviewSlot *)slot;
@end
