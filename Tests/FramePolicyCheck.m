#import "FramePresentation.h"
#import "SourceCadence.h"

#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "Failed at line %d\n", __LINE__); return NO; } } while (0)

static PreviewSlot *picture(FPPattern *pattern, int index, int tick, FPFrameKind kind) {
    FPFrame *image = [pattern frameAtIndex:index];
    FPFrame *frame = [FPFrame frame:image.pixels time:CMTimeMake(tick,60)];
    return [PreviewSlot slotWithFrame:frame capture:tick/60.0 delivery:tick/60.0+.010 kind:kind];
}

static BOOL checkPresentation(void) {
    FPPattern *pattern = [[FPPattern alloc] initWithWidth:256 height:144];
    FPFramePresentation *display = [FPFramePresentation new];
    PreviewSlot *original = picture(pattern,1,2,FPFrameOriginal);
    PreviewSlot *midpoint = picture(pattern,0,1,FPFrameGenerated);
    NSUInteger version = [display publishOriginal:original expectsMidpoint:YES now:.050];
    CHECK([display takeForDisplayTime:.060 interval:.0167 now:.050] == nil);
    [display publishMidpoint:midpoint forVersion:version];
    CHECK([display takeForDisplayTime:.060 interval:.0167 now:.050] == midpoint);
    CHECK([display takeForDisplayTime:.077 interval:.0167 now:.066] == original);

    // A compositor target three refreshes in the future still consumes only
    // this callback's slot. Reserve the next callback across a new capture.
    version = [display publishOriginal:original expectsMidpoint:YES now:.200];
    CHECK([display takeForDisplayTime:.253 interval:.0167 now:.203] == nil);
    [display publishMidpoint:midpoint forVersion:version];
    CHECK([display takeForDisplayTime:.270 interval:.0167 now:.220] == midpoint);
    PreviewSlot *later = picture(pattern,4,6,FPFrameOriginal);
    [display publishOriginal:later expectsMidpoint:NO now:.2333];
    CHECK([display takeForDisplayTime:.287 interval:.0167 now:.237] == original);
    CHECK([display takeForDisplayTime:.304 interval:.0167 now:.254] == later);

    version = [display publishOriginal:original expectsMidpoint:YES now:.050];
    [display publishMidpoint:midpoint forVersion:version];
    CHECK([display takeForDisplayTime:.135 interval:.0167 now:.085] == original);
    CHECK(display.drops.generated == 1);

    NSUInteger stale = [display publishOriginal:original expectsMidpoint:YES now:.120];
    PreviewSlot *next = picture(pattern,2,4,FPFrameOriginal);
    version = [display publishOriginal:next expectsMidpoint:YES now:.140];
    CHECK(version != stale && ![display acceptsMidpointForVersion:version]);
    [display publishMidpoint:midpoint forVersion:stale];
    CHECK([display takeForDisplayTime:.145 interval:.0167 now:.140] == next);
    CHECK(display.drops.originals == 1 && display.drops.generated == 2);

    [display publishOriginal:next expectsMidpoint:NO now:.160];
    [display reset];
    CHECK([display takeForDisplayTime:.165 interval:.0167 now:.160] == nil);
    return YES;
}

static BOOL checkDisplayPhases(void) {
    FPPattern *pattern = [[FPPattern alloc] initWithWidth:256 height:144];
    PreviewSlot *original = picture(pattern,1,2,FPFrameOriginal);
    PreviewSlot *midpoint = picture(pattern,0,1,FPFrameGenerated);
    const double refresh = 1.0/60;
    for (int phase=1; phase<17; phase++) {
        FPFramePresentation *display = [FPFramePresentation new];
        double capture=0, ready=INFINITY, tick=phase/1000.0;
        NSUInteger version=0, originals=0, generated=0;
        while (tick < 2) {
            if (capture <= tick && capture <= ready) {
                version = [display publishOriginal:original expectsMidpoint:YES now:capture];
                ready = capture + .009;
                capture += 2 * refresh;
            } else if (ready <= tick) {
                [display publishMidpoint:midpoint forVersion:version];
                ready = INFINITY;
            } else {
                PreviewSlot *slot = [display takeForDisplayTime:tick+.050 interval:refresh now:tick];
                originals += slot.originalSample;
                generated += slot.generated;
                tick += refresh;
            }
        }
        CHECK(originals >= 58 && generated >= 58 && display.drops.originals == 0);
    }
    return YES;
}

static BOOL checkCadence(void) {
    FPPattern *pattern = [[FPPattern alloc] initWithWidth:256 height:144];
    FPSourceCadence *cadence = [FPSourceCadence new];
    PreviewSlot *a = picture(pattern,0,0,FPFrameOriginal);
    CHECK([cadence acceptOriginal:a] == FPSourceDiscontinuity);
    CHECK([cadence acceptOriginal:picture(pattern,0,1,FPFrameOriginal)] == FPSourceRepeat);
    CHECK([cadence acceptOriginal:picture(pattern,1,2,FPFrameOriginal)] == FPSourceInterpolate);
    CHECK(cadence.previousOriginal == a);
    CHECK([cadence acceptOriginal:picture(pattern,2,3,FPFrameOriginal)] == FPSourceOriginal);
    CHECK([cadence acceptOriginal:picture(pattern,3,4,FPFrameOriginal)] == FPSourceOriginal);
    CHECK([cadence acceptOriginal:picture(pattern,4,20,FPFrameOriginal)] == FPSourceDiscontinuity);
    CHECK(cadence.previousOriginal == nil);
    CHECK([cadence acceptOriginal:picture(pattern,4,22,FPFrameOriginal)] == FPSourceHold);

    // Two real 60 Hz pictures differ by one luma sample in the same 4x4 block.
    PreviewSlot *flat = picture(pattern,0,0,FPFrameOriginal), *subtle = picture(pattern,0,1,FPFrameOriginal);
    CVPixelBufferRef buffer = subtle.frame.pixels;
    CHECK(CVPixelBufferLockBaseAddress(buffer, 0) == kCVReturnSuccess);
    ((uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buffer, 0))[1] ^= 1;
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    [cadence reset];
    CHECK([cadence acceptOriginal:flat] == FPSourceDiscontinuity);
    CHECK([cadence acceptOriginal:subtle] == FPSourceOriginal);
    [cadence reset];

    CVPixelBufferRef packed = NULL;
    CHECK(!CVPixelBufferCreate(NULL,256,144,kCVPixelFormatType_32RGBA,NULL,&packed));
    PreviewSlot *other = [PreviewSlot slotWithFrame:[FPFrame frame:packed time:CMTimeMake(24,60)]
        capture:.400 delivery:.410 kind:FPFrameOriginal];
    CFRelease(packed);
    CHECK([cadence acceptOriginal:other] == FPSourceUnsupported);
    CHECK([cadence acceptOriginal:picture(pattern,5,25,FPFrameOriginal)] == FPSourceDiscontinuity);
    return YES;
}

int main(void) { @autoreleasepool {
    if (!checkCadence() || !checkPresentation() || !checkDisplayPhases()) return 1;
    puts("Source formats, cadence changes, timing resets and original-frame priority passed.");
    return 0;
}}
