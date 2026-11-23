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
int main(void) { @autoreleasepool {
    ObservedPreview *preview = [ObservedPreview new];
    if (!preview) return 2;
    [preview prepareGenerationForWidth:1920 height:1080];
    preview.visible = YES;
    FPPattern *pattern = [[FPPattern alloc] initWithWidth:1920 height:1080];
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
