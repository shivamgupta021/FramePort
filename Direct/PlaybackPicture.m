#import "PlaybackPicture.h"

static NSArray<NSString *> *colorKeys(void) {
    static NSArray *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[(__bridge NSString *)kCVImageBufferColorPrimariesKey,
                 (__bridge NSString *)kCVImageBufferTransferFunctionKey,
                 (__bridge NSString *)kCVImageBufferYCbCrMatrixKey,
                 (__bridge NSString *)kCVImageBufferGammaLevelKey,
                 (__bridge NSString *)kCVImageBufferCGColorSpaceKey,
                 (__bridge NSString *)kCVImageBufferICCProfileKey];
    });
    return keys;
}

@implementation PlaybackPicture {
    NSDictionary<NSString *, id> *_tags;
    NSDictionary *_imageOptions;
    BOOL _verify, _lastNeededRepair;
}
- (instancetype)initWithSample:(CMSampleBufferRef)sample {
    if (!(self = [super init])) return nil;
    CVPixelBufferRef buffer = CMSampleBufferGetImageBuffer(sample);
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
    NSMutableDictionary *tags = [NSMutableDictionary dictionary];
    for (NSString *key in colorKeys()) {
        id value = CFBridgingRelease(CVBufferCopyAttachment(buffer, (__bridge CFStringRef)key, NULL));
        if (!value && format) value = (__bridge id)CMFormatDescriptionGetExtension(format, (__bridge CFStringRef)key);
        if (value) tags[key] = value;
    }
    // The configured USB card advertises sRGB SDR and can omit its HD matrix.
    // Prefer every color characteristic supplied by the first capture.
    NSString *primaries = (__bridge NSString *)kCVImageBufferColorPrimariesKey;
    NSString *transfer = (__bridge NSString *)kCVImageBufferTransferFunctionKey;
    NSString *matrix = (__bridge NSString *)kCVImageBufferYCbCrMatrixKey;
    if (!tags[primaries]) tags[primaries] = (__bridge id)kCVImageBufferColorPrimaries_ITU_R_709_2;
    if (!tags[transfer]) tags[transfer] = tags[(__bridge NSString *)kCVImageBufferGammaLevelKey] ?
        (__bridge id)kCVImageBufferTransferFunction_UseGamma : (__bridge id)kCVImageBufferTransferFunction_sRGB;
    if (!tags[matrix]) tags[matrix] = (__bridge id)kCVImageBufferYCbCrMatrix_ITU_R_709_2;

    CGColorSpaceRef space = CVImageBufferCreateColorSpaceFromAttachments((__bridge CFDictionaryRef)tags);
    if (!space) space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    _tags = [tags copy];
    _imageOptions = @{ kCIImageColorSpace: CFBridgingRelease(space) };
    _verify = [NSProcessInfo.processInfo.arguments containsObject:@"--verify-preview"];
    if (_verify) NSLog(@"Capture color · primaries %@ · transfer %@ · matrix %@", tags[primaries], tags[transfer], tags[matrix]);
    return self;
}
- (FPFrame *)frameFromSample:(CMSampleBufferRef)sample {
    CVPixelBufferRef source = CMSampleBufferGetImageBuffer(sample);
    CMTime time = CMSampleBufferGetPresentationTimeStamp(sample);
    NSString *differentKey = nil;
    for (NSString *key in colorKeys()) {
        CVAttachmentMode mode;
        id value = CFBridgingRelease(CVBufferCopyAttachment(source, (__bridge CFStringRef)key, &mode));
        id expected = _tags[key];
        if (value == nil && expected == nil) continue;
        if (![value isEqual:expected] || mode != kCVAttachmentMode_ShouldPropagate) { differentKey = key; break; }
    }
    BOOL repair = differentKey != nil;
    if (_verify && repair != _lastNeededRepair)
        NSLog(@"Capture color · %@", repair ? [@"normalized missing, changed or non-propagating tag " stringByAppendingString:differentKey] : @"tags match session");
    _lastNeededRepair = repair;
    if (!repair || !CVPixelBufferGetIOSurface(source)) return [FPFrame frame:source time:time];

    // Core Image and VideoToolbox both see the same tags. The zero-copy view
    // owns the camera buffer until the last consumer finishes with its surface.
    CVPixelBufferRef view = NULL;
    if (CVPixelBufferCreateWithIOSurface(NULL, CVPixelBufferGetIOSurface(source), NULL, &view) != kCVReturnSuccess)
        return [FPFrame frame:source time:time];
    CVBufferPropagateAttachments(source, view);
    for (NSString *key in colorKeys()) CVBufferRemoveAttachment(view, (__bridge CFStringRef)key);
    CVBufferSetAttachments(view, (__bridge CFDictionaryRef)_tags, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(view, CFSTR("FramePortCaptureOwner"), source, kCVAttachmentMode_ShouldNotPropagate);
    FPFrame *frame = [FPFrame frame:view time:time];
    CVPixelBufferRelease(view);
    return frame;
}
- (CIImage *)imageForFrame:(FPFrame *)frame size:(CGSize)size {
    CIImage *image = [CIImage imageWithCVPixelBuffer:frame.pixels options:_imageOptions];
    if (CGSizeEqualToSize(image.extent.size, size)) return image;
    double sx = size.width / image.extent.size.width, sy = size.height / image.extent.size.height;
    CGRect bounds = CGRectMake(0, 0, size.width, size.height);
    CIImage *scaled = [[image imageByClampingToExtent] imageByApplyingFilter:@"CILanczosScaleTransform"
        withInputParameters:@{kCIInputScaleKey:@(sy), kCIInputAspectRatioKey:@(sx/sy)}];
    if (sx > 1 && sy > 1) {
        scaled = [scaled imageByApplyingFilter:@"CISharpenLuminance"
            withInputParameters:@{kCIInputSharpnessKey:@0.15, kCIInputRadiusKey:@0.9}];
    }
    return [scaled imageByCroppingToRect:bounds];
}
@end
