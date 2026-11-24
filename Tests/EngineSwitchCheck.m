#import "MeasuredPreview.h"

#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "Failed at line %d\n", __LINE__); return NO; } } while (0)

static BOOL deliver(MeasuredPreview *preview, FPFrame *source) {
    CMVideoFormatDescriptionRef fmt = NULL;
    CMSampleBufferRef sample = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(NULL, source.pixels, &fmt)) return NO;
    CMSampleTimingInfo timing = {CMTimeMake(1,60), source.time, kCMTimeInvalid};
    OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(NULL,source.pixels,fmt,&timing,&sample);
    CFRelease(fmt);
    if (status) return NO;
    double timestamp = CMTimeGetSeconds(source.time);
    [preview displaySample:sample captureTime:timestamp deliveryTime:timestamp];
    CFRelease(sample);
    return YES;
}

static PreviewSlot *take(MeasuredPreview *preview, double target, double now) {
    return [preview frameForDisplayTime:target interval:1.0/60 now:now epoch:NULL];
}

static PreviewSlot *waitForSlot(MeasuredPreview *preview, double arrival) {
    double deadline = CACurrentMediaTime()+3;
    PreviewSlot *slot = nil;
    while (!slot && CACurrentMediaTime() < deadline) {
        slot = take(preview,arrival+.010,arrival+.001);
        if (!slot) [NSThread sleepForTimeInterval:.001];
    }
    return slot;
}

static BOOL checkGPUHandoff(FPFrame *picture) {
    id<MTLDevice> gpu=MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> producer=[gpu newCommandQueue];
    id<MTLSharedEvent> gate=[gpu newSharedEvent];
    id<MTLCommandBuffer> command=[producer commandBuffer];
    CHECK(gate && command);
    FPFrame *pending=[FPFrame frame:picture.pixels time:picture.time producedBy:command];
    [command encodeWaitForEvent:gate value:1];
    [command commit];
    FPFramePresentation *presenter = [FPFramePresentation new];
    PreviewSlot *original = [PreviewSlot slotWithFrame:picture capture:0 delivery:0 kind:FPFrameOriginal];
    PreviewSlot *midpoint = [PreviewSlot slotWithFrame:pending capture:0 delivery:0 kind:FPFrameGenerated];
    NSUInteger version = [presenter publishOriginal:original expectsMidpoint:YES now:1];
    [presenter publishMidpoint:midpoint forVersion:version];
    BOOL rejectedUnfinished = [presenter takeForDisplayTime:1.01 interval:1.0/60 now:1] == nil;
    BOOL returnedOriginal = [presenter takeForDisplayTime:1.085 interval:1.0/60 now:1.035] == original;
    BOOL orderedOnProducer = [pending isReadyForQueue:producer] && ![pending isReadyForQueue:nil];
    gate.signaledValue=1;
    [command waitUntilCompleted];
    return rejectedUnfinished && returnedOriginal && orderedOnProducer &&
        [pending isReadyForQueue:nil] && presenter.drops.generated == 1;
}

static BOOL checkEngineSwitch(FPPattern *pattern) {
    MeasuredPreview *preview = [MeasuredPreview new];
    [preview prepareGenerationForWidth:1920 height:1080];
    preview.visible = YES;
    int index = 0;
    for (NSNumber *mode in @[@(FPGenerationGuided),@(FPGenerationMetalNative),@(FPGenerationGuided)]) {
        preview.generationEngine = mode.integerValue;
        FPFrame *first = [pattern frameAtIndex:index++];
        FPFrame *second = [pattern frameAtIndex:index++];
        double t = CMTimeGetSeconds(first.time), next = CMTimeGetSeconds(second.time);
        CHECK(deliver(preview,first) && take(preview,t+.010,t).originalSample);
        CHECK(deliver(preview,second));
        PreviewSlot *midpoint = waitForSlot(preview,next);
        CHECK(midpoint.generated && CVPixelBufferGetWidth(midpoint.frame.pixels)==1920);
        CHECK(take(preview,next+.026,next+.017).originalSample);
    }
    return YES;
}

static BOOL checkNativeCadence(FPPattern *pattern) {
    MeasuredPreview *preview = [MeasuredPreview new];
    preview.visible = YES;
    for (int tick=0; tick<64; tick++) {
        FPFrame *picture = [pattern frameAtIndex:tick];
        FPFrame *frame = [FPFrame frame:picture.pixels time:CMTimeMake(tick,60)];
        double t = tick/60.0;
        CHECK(deliver(preview,frame));
        PreviewSlot *slot = take(preview,t+.010,t);
        CHECK(slot.originalSample && CMTimeCompare(slot.frame.time,frame.time)==0);
    }
    return YES;
}

@interface InjectedEngine : FPInterpolator
@property(nonatomic) BOOL fails;
@end
@implementation InjectedEngine
- (FPFrame *)midpointFrom:(FPFrame *)a to:(FPFrame *)b error:(NSError **)error {
    if (self.fails) {
        if (error) *error = FPError(@"Temporary frame allocation failure");
        return nil;
    }
    return b;
}
@end

@interface RecoveryPreview : MeasuredPreview
@property(nonatomic) NSUInteger engineCount;
@end
@implementation RecoveryPreview
- (FPInterpolator *)newInterpolatorForEngine:(FPGenerationEngine)engine width:(size_t)width
                                       height:(size_t)height error:(NSError **)error {
    InjectedEngine *fake = [InjectedEngine new];
    fake.fails = ++self.engineCount == 1;
    return fake;
}
@end

static BOOL checkRecovery(FPPattern *pattern) {
    RecoveryPreview *preview = [RecoveryPreview new];
    [preview prepareGenerationForWidth:1920 height:1080];
    preview.visible = YES;
    for (int i=0;i<4;i++) {
        if (i==2) {
            preview.generationEnabled=NO;
            preview.generationEnabled=YES;
        }
        FPFrame *frame = [pattern frameAtIndex:i];
        double t = CMTimeGetSeconds(frame.time);
        CHECK(deliver(preview,frame));
        PreviewSlot *slot = waitForSlot(preview,t);
        if (i==1) CHECK(slot.originalSample && preview.generationError != nil);
        else if (i==3) CHECK(slot.generated && preview.generationError == nil &&
            take(preview,t+.026,t+.017).originalSample);
        else CHECK(slot.originalSample);
    }
    return YES;
}

static BOOL checkPackedCapture(FPPattern *pattern) {
    VTPixelTransferSessionRef transfer = NULL;
    CHECK(VTPixelTransferSessionCreate(NULL,&transfer)==noErr);
    MeasuredPreview *preview = [MeasuredPreview new];
    preview.generationEngine = FPGenerationMetalNative;
    [preview prepareGenerationForWidth:1920 height:1080];
    preview.visible = YES;
    for (int i=0;i<2;i++) {
        FPFrame *source = [pattern frameAtIndex:i];
        CVPixelBufferRef packed = NULL;
        CHECK(CVPixelBufferCreate(NULL,1920,1080,kCVPixelFormatType_32BGRA,NULL,&packed)==kCVReturnSuccess);
        CHECK(VTPixelTransferSessionTransferImage(transfer,source.pixels,packed)==noErr);
        FPFrame *input = [FPFrame frame:packed time:source.time];
        CFRelease(packed);
        CHECK(deliver(preview,input));
        double t = CMTimeGetSeconds(input.time);
        PreviewSlot *slot = waitForSlot(preview,t);
        if (!i) CHECK(slot.originalSample);
        else CHECK(slot.generated && take(preview,t+.028,t+.018).originalSample);
    }
    CFRelease(transfer);
    return YES;
}

int main(void) { @autoreleasepool {
    FPPattern *pattern = [[FPPattern alloc] initWithWidth:1920 height:1080];
    if (!pattern || !checkGPUHandoff([pattern frameAtIndex:0]) || !checkNativeCadence(pattern) ||
        !checkEngineSwitch(pattern) || !checkRecovery(pattern) || !checkPackedCapture(pattern)) return 1;
    puts("Live presentation handoff: GPU deadline, native 60, 1080p engine switches, failure recovery and packed capture passed.");
    return 0;
} }
