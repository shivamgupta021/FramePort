#import "PlaybackPicture.h"

// The same HDMI samples must keep their rendered color across missing or
// conflicting per-frame tags, including a generated frame from those samples.
static CMSampleBufferRef makeSample(FPFrame *frame) {
    CMVideoFormatDescriptionRef format = NULL;
    CMSampleBufferRef sample = NULL;
    CMSampleTimingInfo timing = {CMTimeMake(1,30), frame.time, kCMTimeInvalid};
    if (CMVideoFormatDescriptionCreateForImageBuffer(NULL,frame.pixels,&format) == noErr) {
        CMSampleBufferCreateReadyWithImageBuffer(NULL,frame.pixels,format,&timing,&sample);
        CFRelease(format);
    }
    return sample;
}
static NSData *readPatch(CIContext *ctx, CIImage *image, CGPoint point) {
    NSMutableData *bytes = [NSMutableData dataWithLength:4*8*8];
    CGColorSpaceRef rgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    [ctx render:image toBitmap:bytes.mutableBytes rowBytes:4*8 bounds:CGRectMake(point.x,point.y,8,8)
          format:kCIFormatRGBA8 colorSpace:rgb];
    CGColorSpaceRelease(rgb);
    return bytes;
}
int main(int argc, const char **argv) { @autoreleasepool {
    BOOL baseline = argc == 2 && !strcmp(argv[1],"baseline");
    CIContext *ctx = [CIContext contextWithMTLDevice:MTLCreateSystemDefaultDevice()];
    FPPattern *pattern = [[FPPattern alloc] initWithWidth:1920 height:1080];
    NSError *error = nil;
    FPInterpolator *engine = [[FPInterpolator alloc] initWithWidth:1920 height:1080 engine:FPGenerationGuided error:&error];
    if (!engine) { NSLog(@"%@",error); return 2; }
    PlaybackPicture *picture = nil;
    FPFrame *previous = nil;
    NSArray<NSData *> *reference = nil;
    int worst = 0;
    // Solid but colorful patches, away from the moving tile.
    for (int index=0; index<12; index++) { @autoreleasepool {
        FPFrame *source = [pattern frameAtIndex:index];
        CVPixelBufferLockBaseAddress(source.pixels,0);
        for (int plane=0;plane<2;plane++) {
            uint8_t *base = CVPixelBufferGetBaseAddressOfPlane(source.pixels,plane);
            size_t stride = CVPixelBufferGetBytesPerRowOfPlane(source.pixels,plane);
            int divisor = plane ? 2 : 1;
            for (int y=0;y<1080/divisor;y++) for (int x=800;x<1600;x++) {
                int band=(x-800)/200;
                base[y*stride+x] = plane ? ((x&1) ? 148-band*6 : 105+band*7) : 50+band*42;
            }
        }
        CVPixelBufferUnlockBaseAddress(source.pixels,0);
        CVBufferSetAttachment(source.pixels,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_SMPTE_C,kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(source.pixels,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_601_4,kCVAttachmentMode_ShouldPropagate);
        if (index%3==1) CVBufferRemoveAttachment(source.pixels,kCVImageBufferTransferFunctionKey);
        if (index%3==2) {
            CVBufferSetAttachment(source.pixels,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_sRGB,kCVAttachmentMode_ShouldNotPropagate);
            CVBufferSetAttachment(source.pixels,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
        }
        CMSampleBufferRef sample=makeSample(source);
        if (!sample) return 2;
        if (!picture) picture=[[PlaybackPicture alloc] initWithSample:sample];
        FPFrame *real=baseline ? source : [picture frameFromSample:sample];
        CFRelease(sample);
        FPFrame *mid=previous ? [engine midpointFrom:previous to:real error:&error] : nil;
        if (previous && !mid) { NSLog(@"%@",error); return 2; }
        for (FPFrame *frame in mid ? @[mid,real] : @[real]) {
            CGSize size=CGSizeMake(2316,1303);
            CIImage *image;
            if (baseline) image=[[CIImage imageWithCVPixelBuffer:frame.pixels] imageByApplyingTransform:CGAffineTransformMakeScale(size.width/1920,size.height/1080) highQualityDownsample:NO];
            else image=[picture imageForFrame:frame size:size];
            NSMutableArray *patches=[NSMutableArray array];
            for (int band=0;band<4;band++) {
                NSData *patch=readPatch(ctx,image,CGPointMake((900+200*band)*size.width/1920,430));
                [patches addObject:patch];
                if (reference) {
                    const uint8_t *a=patch.bytes, *b=reference[band].bytes;
                    for (NSUInteger i=0;i<patch.length;i++) worst=MAX(worst,abs(a[i]-b[i]));
                }
            }
            if (!reference) reference=patches;
        }
        previous=real;
    }}
    printf("Identical source swatches across USB and generated frames: maximum RGB drift %d/255\n",worst);
    return worst>1;
} }
