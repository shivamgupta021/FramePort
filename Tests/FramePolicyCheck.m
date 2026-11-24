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
    [display publishOriginal:original midpoint:midpoint now:.050];
    CHECK([display delayUntilNextAt:.050] == 0);
    CHECK([display takeDueAt:.051 renderQueue:nil] == midpoint);
    CHECK([display delayUntilNextAt:.050] > .016);
    CHECK([display takeDueAt:.060 renderQueue:nil] == nil);
    CHECK([display takeDueAt:.067 renderQueue:nil] == original);
    CHECK(isinf([display delayUntilNextAt:.067]));

    [display publishOriginal:original midpoint:midpoint now:.070];
    CHECK([display takeDueAt:.120 renderQueue:nil] == original);
    CHECK(display.drops.generated == 1);

    [display publishOriginal:original midpoint:midpoint now:.120];
    PreviewSlot *next = picture(pattern,2,4,FPFrameOriginal);
    NSUInteger stale = display.version;
    [display publishOriginal:next midpoint:midpoint now:.140];
    CHECK(display.version != stale);
    CHECK([display takeDueAt:.140 renderQueue:nil] == next);
    CHECK(display.drops.originals == 1 && display.drops.generated == 3);

    [display publishOriginal:next midpoint:nil now:.160];
    [display reset];
    CHECK([display takeDueAt:.160 renderQueue:nil] == nil);
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

    CVPixelBufferRef packed = NULL;
    CHECK(!CVPixelBufferCreate(NULL,256,144,kCVPixelFormatType_32BGRA,NULL,&packed));
    PreviewSlot *other = [PreviewSlot slotWithFrame:[FPFrame frame:packed time:CMTimeMake(24,60)]
        capture:.400 delivery:.410 kind:FPFrameOriginal];
    CFRelease(packed);
    CHECK([cadence acceptOriginal:other] == FPSourceUnsupported);
    CHECK([cadence acceptOriginal:picture(pattern,5,25,FPFrameOriginal)] == FPSourceDiscontinuity);
    return YES;
}

int main(void) { @autoreleasepool {
    if (!checkCadence() || !checkPresentation()) return 1;
    puts("Source formats, cadence changes, timing resets and original-frame priority passed.");
    return 0;
}}
