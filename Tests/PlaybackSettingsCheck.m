#import "PlaybackSettings.h"
#import "PlaybackPicture.h"

static NSData *render(CIContext *context, PlaybackPicture *picture, FPFrame *frame, CGSize size, FPPictureOptions options) {
    CIImage *image = [picture imageForFrame:frame size:size options:options];
    if (!CGRectEqualToRect(image.extent, (CGRect){CGPointZero,size})) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:4*(NSUInteger)size.width*(NSUInteger)size.height];
    CGColorSpaceRef rgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    [context render:image toBitmap:data.mutableBytes rowBytes:4*(NSUInteger)size.width bounds:image.extent format:kCIFormatRGBA8 colorSpace:rgb];
    CGColorSpaceRelease(rgb);
    return data;
}
static BOOL checkPixels(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return NO;
    CIContext *context = [CIContext contextWithMTLDevice:device];
    FPFrame *frame = [[[FPPattern alloc] initWithWidth:256 height:144] frameAtIndex:1];
    CMVideoFormatDescriptionRef format = NULL;
    CMSampleBufferRef sample = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(NULL,frame.pixels,&format)) return NO;
    CMSampleTimingInfo timing = {CMTimeMake(1,30), frame.time, kCMTimeInvalid};
    OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(NULL,frame.pixels,format,&timing,&sample);
    CFRelease(format);
    if (status) return NO;
    PlaybackPicture *picture = [[PlaybackPicture alloc] initWithSample:sample];
    CFRelease(sample);
    CGSize enlarged = CGSizeMake(384,216), native = CGSizeMake(256,144);
    NSMutableSet<NSData *> *enlargements = [NSMutableSet set];
    NSData *source = render(context,picture,frame,native,FPDetailPictureOptions());
    for (int filter=0; filter<2; filter++) for (NSNumber *strength in @[@0,@0.15,@0.35]) {
        FPPictureOptions options = {filter, strength.doubleValue};
        NSData *result = render(context,picture,frame,enlarged,options);
        if (!result || ![source isEqual:render(context,picture,frame,native,options)]) return NO;
        [enlargements addObject:result];
    }
    return enlargements.count == 6;
}

static BOOL checkPanel(NSUserDefaults *defaults) {
    PlaybackSettings *settings = [[PlaybackSettings alloc] initWithDefaults:defaults];
    if (settings.pictureOptions.filter != FPResizeLanczos || settings.pictureOptions.sharpness != 0.15 || !settings.startsFullScreen || settings.generationEngine != FPGenerationGuided) { NSLog(@"Unexpected default settings"); return NO; }
    NSGridView *grid = (NSGridView *)settings.window.contentView.subviews.firstObject;
    if (![grid isKindOfClass:NSGridView.class]) { NSLog(@"Missing settings grid in %@",settings.window); return NO; }
    NSPopUpButton *filter = (NSPopUpButton *)[grid cellAtColumnIndex:1 rowIndex:0].contentView;
    NSPopUpButton *sharpness = (NSPopUpButton *)[grid cellAtColumnIndex:1 rowIndex:1].contentView;
    NSPopUpButton *engine = (NSPopUpButton *)[grid cellAtColumnIndex:1 rowIndex:2].contentView;
    NSButton *startup = (NSButton *)[grid cellAtColumnIndex:1 rowIndex:3].contentView;
    __block FPGenerationEngine selected = FPGenerationGuided;
    settings.engineDidChange = ^(FPGenerationEngine mode) { selected = mode; };
    [engine selectItemAtIndex:1];
    [engine sendAction:engine.action to:engine.target];
    __block NSUInteger notifications = 0;
    __block FPPictureOptions applied = FPDetailPictureOptions();
    settings.pictureDidChange = ^(FPPictureOptions options) { notifications++; applied = options; };
    [filter selectItemAtIndex:1];
    [filter sendAction:filter.action to:filter.target];
    [sharpness selectItemAtIndex:2];
    [sharpness sendAction:sharpness.action to:sharpness.target];
    startup.state = NSControlStateValueOff;
    [startup sendAction:startup.action to:startup.target];
    PlaybackSettings *next = [[PlaybackSettings alloc] initWithDefaults:defaults];
    NSLog(@"Callbacks %lu; last %ld, %.2f; reopened %ld, %.2f; fullscreen %d", notifications, (long)applied.filter, applied.sharpness, (long)next.pictureOptions.filter, next.pictureOptions.sharpness, next.startsFullScreen);
    return selected == FPGenerationMetalNative && next.generationEngine == selected && notifications == 2 && applied.filter == FPResizeBilinear && applied.sharpness == 0.35 &&
        next.pictureOptions.filter == FPResizeBilinear && next.pictureOptions.sharpness == 0.35 && !next.startsFullScreen;
}
int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    NSString *suite = [@"io.frameport.settings-test." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    BOOL panel = checkPanel(defaults), pixels = checkPixels();
    [defaults removePersistentDomainForName:suite];
    printf("Settings window actions, immediate updates and persistence: %s\n",panel ? "pass" : "FAIL");
    printf("Six distinct filter/sharpening outputs, identical original-size pixels: %s\n",pixels ? "pass" : "FAIL");
    return !(panel && pixels);
} }
