#import "MeasuredPreview.h"

// Observe the handoff from the real capture/interpolation path to the display queue.
// The test needs a Metal device, but never opens a capture card or a window.
@interface PreviewSlot : NSObject
@property(nonatomic, readonly) BOOL generated, originalSample;
@property(nonatomic, readonly) FPFrame *frame;
@end
@interface ObservedPreview : MeasuredPreview
@property(nonatomic, copy) NSArray<PreviewSlot *> *published;
@end
@implementation ObservedPreview
- (void)publish:(NSArray<PreviewSlot *> *)slots epoch:(NSUInteger)epoch { self.published = slots; }
@end

static BOOL deliver(ObservedPreview *preview, FPFrame *source) {
    CMVideoFormatDescriptionRef fmt = NULL;
    CMSampleBufferRef sample = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(NULL,source.pixels,&fmt)) return NO;
    CMSampleTimingInfo timing = {CMTimeMake(1,30),source.time,kCMTimeInvalid};
    OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(NULL,source.pixels,fmt,&timing,&sample);
    CFRelease(fmt);
    if (status) return NO;
    double timestamp = CMTimeGetSeconds(source.time);
    [preview displaySample:sample captureTime:timestamp deliveryTime:timestamp];
    CFRelease(sample);
    return preview.generationError == nil;
}
static BOOL checkGPUReadiness(FPFrame *picture) {
    id<MTLDevice> gpu=MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> producer=[gpu newCommandQueue], another=[gpu newCommandQueue];
    id<MTLSharedEvent> gate=[gpu newSharedEvent];
    id<MTLCommandBuffer> command=[producer commandBuffer];
    if (!producer || !another || !gate || !command) return NO;
    FPFrame *pending=[FPFrame frame:picture.pixels time:picture.time producedBy:command];
    BOOL rejectedBeforeCommit=![pending isReadyForQueue:producer];
    [command encodeWaitForEvent:gate value:1];
    [command commit];
    BOOL orderedOnProducer=[pending isReadyForQueue:producer];
    BOOL rejectsOtherQueue=![pending isReadyForQueue:another] && ![pending isReadyForQueue:nil];
    gate.signaledValue=1;
    [command waitUntilCompleted];
    return rejectedBeforeCommit && orderedOnProducer && rejectsOtherQueue &&
        [pending isReadyForQueue:another] && [pending isReadyForQueue:nil];
}

int main(void) { @autoreleasepool {
    ObservedPreview *preview = [ObservedPreview new];
    if (!preview) return 2;
    [preview prepareGenerationForWidth:1920 height:1080];
    preview.visible = YES;
    FPPattern *pattern = [[FPPattern alloc] initWithWidth:1920 height:1080];
    if (!checkGPUReadiness([pattern frameAtIndex:0])) return 1;
    puts("GPU readiness distinguishes ordered work from completed output.");
    int index = 0;
    for (NSNumber *mode in @[@(FPGenerationGuided),@(FPGenerationMetalNative),@(FPGenerationGuided)]) { @autoreleasepool {
        preview.generationEngine = mode.integerValue;
        if (!deliver(preview,[pattern frameAtIndex:index++]) || preview.published.count != 1 || !preview.published.firstObject.originalSample) return 1;
        if (!deliver(preview,[pattern frameAtIndex:index++]) || preview.published.count != 2) return 1;
        PreviewSlot *mid = preview.published.firstObject;
        if (!mid.generated || mid.originalSample || !preview.published.lastObject.originalSample ||
            CVPixelBufferGetWidth(mid.frame.pixels) != 1920 || CVPixelBufferGetHeight(mid.frame.pixels) != 1080) return 1;
    }}
    puts("Detail → Fast Metal → Detail: each switch starts with a real frame, then generates a 1920 × 1080 midpoint.");
    return 0;
} }
