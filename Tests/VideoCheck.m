#import "Video.h"
#import <QuartzCore/QuartzCore.h>
#include <stdio.h>

// The test tile moves 12 pixels per input frame. Locate its bright outer edges.
static double tileCenter(FPFrame *frame) {
    CVPixelBufferRef pixels = frame.pixels;
    CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
    size_t width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels);
    uint8_t *row = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixels, 0)
        + height/2 * CVPixelBufferGetBytesPerRowOfPlane(pixels, 0);
    int left = 0, right = (int)width-1;
    while (left < width && row[left] < 155) left++;
    while (right >= 0 && row[right] < 155) right--;
    CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
    return left <= right ? (left + right)/2.0 : NAN;
}

int main(int argc, const char **argv) { @autoreleasepool {
    id<MTLDevice> gpu = MTLCreateSystemDefaultDevice();
    if (!gpu) { fprintf(stderr, "Metal device unavailable\n"); return 1; }
    id<MTLCommandQueue> queue = [gpu newCommandQueue];
    FPScaler *scaler = [[FPScaler alloc] initWithDevice:gpu];
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:2560 height:1440 mipmapped:NO];
    desc.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    desc.storageMode = MTLStorageModeShared;
    id<MTLTexture> target = [gpu newTextureWithDescriptor:desc];
    NSError *error = nil;
    FPGenerationEngine engine = argc > 1 && !strcmp(argv[1],"1440") ? FPGenerationMetal1440 :
        argc > 1 && !strcmp(argv[1],"native") ? FPGenerationMetalNative :
        argc > 1 && !strcmp(argv[1],"guided") ? FPGenerationGuided : FPGenerationApple;
    scaler.fastScaling = argc < 3 || strcmp(argv[2],"lanczos");
    double genSum = 0, gpuSum = 0;
    FPInterpolator *interpolator = [[FPInterpolator alloc] initWithWidth:1920 height:1080 engine:engine error:&error];
    if (!interpolator) { NSLog(@"%@", error); return 1; }
    FPPattern *pattern = [[FPPattern alloc] initWithWidth:1920 height:1080];
    FPFrame *last = [pattern frameAtIndex:0];
    NSMutableArray<NSNumber *> *elapsed = [NSMutableArray array];
    double worstCenterError = 0;
    for (int i = 1; i <= 95; i++) { @autoreleasepool {
        FPFrame *next = [pattern frameAtIndex:i];
        double start = CACurrentMediaTime();
        FPFrame *mid = [interpolator midpointFrom:last to:next error:&error];
        if (i > 5) genSum += CACurrentMediaTime()-start;
        if (!mid || fabs(CMTimeGetSeconds(mid.time) - (i - 0.5)/30.0) > 0.0001) {
            NSLog(@"Midpoint failed: %@", error); return 1;
        }
        if (engine == FPGenerationGuided && (CVPixelBufferGetWidth(mid.pixels) != 1920 || CVPixelBufferGetHeight(mid.pixels) != 1080)) return 1;
        double ratio = (double)CVPixelBufferGetWidth(next.pixels)/CVPixelBufferGetWidth(mid.pixels);
        double center = (tileCenter(mid) + 0.5)*ratio - 0.5;
        if (i == 1) printf("Generated buffer %zu × %zu\n", CVPixelBufferGetWidth(mid.pixels), CVPixelBufferGetHeight(mid.pixels));
        double expected = (tileCenter(last) + tileCenter(next))/2;
        if (!isfinite(center)) return 1;
        worstCenterError = MAX(worstCenterError, fabs(center-expected));
        for (FPFrame *frame in @[mid, next]) {
            id<MTLCommandBuffer> cmd = [queue commandBuffer];
            [scaler render:frame into:target command:cmd];
            [cmd commit];
            [cmd waitUntilCompleted];
            if (i > 5) gpuSum += cmd.GPUEndTime-cmd.GPUStartTime;
            if (cmd.status != MTLCommandBufferStatusCompleted) { NSLog(@"%@", cmd.error); return 1; }
        }
        if (i > 5) [elapsed addObject:@((CACurrentMediaTime()-start)*1000)];
        last = next;
    } }
    uint8_t tile[4]={}, background[4]={};
    NSUInteger x = lround(tileCenter(last)*4.0/3.0);
    [target getBytes:tile bytesPerRow:4 fromRegion:MTLRegionMake2D(x,720,1,1) mipmapLevel:0];
    [target getBytes:background bytesPerRow:4 fromRegion:MTLRegionMake2D(4,720,1,1) mipmapLevel:0];
    NSArray *sorted = [elapsed sortedArrayUsingSelector:@selector(compare:)];
    printf("%s | 95 pairs, 1920x1080 -> 2560x1440 | worst midpoint displacement error %.1f px\n", gpu.name.UTF8String,worstCenterError);
    printf("Warm generation + two synchronous scales: median %.2f ms, p95 %.2f ms; 30 Hz budget 33.33 ms. Output tile G %d, background G %d.\n",
        [sorted[45] doubleValue], [sorted[85] doubleValue], tile[1], background[1]);
    printf("Mean generation %.2f ms; mean render GPU %.2f ms/frame\n",genSum*1000/90,gpuSum*1000/180);
    return worstCenterError < 4 && tile[1] > background[1]+40 ? 0 : 1;
} }
