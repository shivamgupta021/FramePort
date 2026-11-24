#import "MeasuredPreview.h"
#import "FramePresentation.h"

// Observe the handoff from the real capture/interpolation path to the display queue.
// The test needs a Metal device, but never opens a capture card or a window.
@interface ObservedPreview : MeasuredPreview
@property(nonatomic, copy) NSArray<PreviewSlot *> *published;
@end
@implementation ObservedPreview
- (void)publishOriginal:(PreviewSlot *)original midpoint:(PreviewSlot *)midpoint epoch:(NSUInteger)epoch {
    (void)epoch;
    self.published = midpoint ? @[midpoint, original] : @[original];
}
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
    puts("Detail → Fast Metal → Detail generates 1080p midpoints.");

    for (int scenario = 0; scenario < 3; scenario++) {
        ObservedPreview *replay = [ObservedPreview new];
        replay.generationEngine = FPGenerationMetalNative;
        [replay prepareGenerationForWidth:1920 height:1080];
        replay.visible = YES;
        int originalCount = 0, generatedCount = 0;
        for (int i = 0; i < 64; i++) { @autoreleasepool {
            int pictureIndex = scenario == 0 ? i : scenario == 1 ? i/2 : i<32 ? i/2 : 16+i-32;
            FPFrame *picture = [pattern frameAtIndex:pictureIndex];
            replay.published = nil;
            if (!deliver(replay,[FPFrame frame:picture.pixels time:CMTimeMake(i,60)])) return 1;
            for (PreviewSlot *slot in replay.published) {
                originalCount += slot.originalSample;
                generatedCount += slot.generated;
            }
            if (scenario == 0 && (!replay.published.lastObject.originalSample ||
                CMTimeCompare(replay.published.lastObject.frame.time,CMTimeMake(i,60)) != 0)) return 1;
        }}
        const int originalCounts[] = {64,32,48}, generatedCounts[] = {0,31,16};
        printf("Live cadence scenario %d: %d originals and %d midpoints\n",scenario,originalCount,generatedCount);
        if (originalCount != originalCounts[scenario] || generatedCount != generatedCounts[scenario]) return 1;
    }
    return 0;
} }
