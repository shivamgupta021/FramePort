// Compare a frame taken directly from USB Video with decoded frames from the recorded app window.
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>

enum { columns = 80, rows = 45, points = columns * rows };
typedef struct { size_t width, height, stride; const uint8_t *pixels; } Image;

static double brightness(Image image, int x, int y) {
    const uint8_t *p = image.pixels + y * image.stride + x * 4;
    return (p[0] * 29 + p[1] * 150 + p[2] * 77) / 256.0;
}
static void sampleRect(Image image, CGRect rect, double result[points]) {
    for (int y = 0; y < rows; y++)
        for (int x = 0; x < columns; x++)
            result[y*columns+x] = brightness(image, rect.origin.x + (x+.5)*rect.size.width/columns,
                                               rect.origin.y + (y+.5)*rect.size.height/rows);
}
static BOOL normalize(double samples[points]) {
    double sum = 0, energy = 0;
    for (int i = 0; i < points; i++) sum += samples[i];
    for (int i = 0; i < points; i++) { samples[i] -= sum/points; energy += samples[i]*samples[i]; }
    if (energy < points) return NO;
    for (int i = 0; i < points; i++) samples[i] /= sqrt(energy);
    return YES;
}
static double similarity(Image image, CGRect rect, const double reference[points]) {
    double values[points];
    sampleRect(image, rect, values);
    if (!normalize(values)) return 0;
    double r = 0;
    for (int i = 0; i < points; i++) r += reference[i]*values[i];
    return r;
}
// Use the same normalized samples to test each possible mirror independently.
static void mirrorScores(Image image, CGRect rect, const double reference[points], double best[3]) {
    double values[points], scores[3] = {0};
    sampleRect(image,rect,values);
    if (!normalize(values)) return;
    for (int y=0; y<rows; y++) for (int x=0; x<columns; x++) {
        double value = values[y*columns+x];
        scores[0] += value * reference[(rows-1-y)*columns+x];
        scores[1] += value * reference[y*columns+columns-1-x];
        scores[2] += value * reference[points-1-(y*columns+x)];
    }
    for (int i=0; i<3; i++) best[i] = MAX(best[i],scores[i]);
}
static double marginMean(Image image, CGRect inside) {
    double sum = 0;
    size_t n = 0;
    for (size_t y = 4; y < image.height; y += 13) {
        for (size_t x = 4; x < image.width; x += 13) {
            if (CGRectContainsPoint(inside, CGPointMake(x,y))) continue;
            sum += brightness(image,(int)x,(int)y); n++;
        }
    }
    return n ? sum/n : 0;
}
int main(int argc, const char **argv) { @autoreleasepool {
    CGRect viewport = CGRectZero;
    char trailing;
    BOOL windowed = argc == 4 && sscanf(argv[3],"--viewport=%lf,%lf,%lf,%lf%c",
        &viewport.origin.x,&viewport.origin.y,&viewport.size.width,&viewport.size.height,&trailing) == 4;
    BOOL fit = windowed || (argc == 4 && strcmp(argv[3], "--fit") == 0);
    if (argc != 3 && !fit) { fprintf(stderr,"usage: direct-check source.png window.mp4 [--fit | --viewport=x,y,w,h]\n"); return 2; }
    NSURL *source = [NSURL fileURLWithPath:@(argv[1])], *movie = [NSURL fileURLWithPath:@(argv[2])];
    CGImageSourceRef png = CGImageSourceCreateWithURL((__bridge CFURLRef)source, NULL);
    CGImageRef cg = png ? CGImageSourceCreateImageAtIndex(png,0,NULL) : NULL;
    if (!cg) return 2;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    CGColorSpaceRef rgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL,w,h,8,w*4,rgb,kCGBitmapByteOrder32Little|kCGImageAlphaNoneSkipFirst);
    if (!ctx) return 2;
    CGRect sourceRect = CGRectMake(0,0,w,h);
    CGContextDrawImage(ctx,sourceRect,cg);
    double reference[points];
    sampleRect((Image){w,h,w*4,CGBitmapContextGetData(ctx)},sourceRect,reference);
    if (!normalize(reference)) { fprintf(stderr,"The source image lacks detail to verify its geometry.\n"); return 1; }
    CGContextRelease(ctx); CGColorSpaceRelease(rgb); CGImageRelease(cg); CFRelease(png);
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:movie options:nil];
    AVAssetTrack *video = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!video) return 2;
    NSError *error = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    AVAssetReaderTrackOutput *frames = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:video
        outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)}];
    frames.alwaysCopiesSampleData = NO;
    [reader addOutput:frames];
    if (![reader startReading]) { NSLog(@"%@",reader.error); return 2; }
    int count = 0;
    double mirrors[3] = {-1,-1,-1};
    double best = -1, otherBest = -1, bestTime = 0, worstMargin = 0, worstMarginTime = 0;
    size_t windowWidth = 0, windowHeight = 0;
    CMSampleBufferRef sample;
    while ((sample = [frames copyNextSampleBuffer])) { @autoreleasepool {
        CVPixelBufferRef buffer = CMSampleBufferGetImageBuffer(sample);
        windowWidth = CVPixelBufferGetWidth(buffer); windowHeight = CVPixelBufferGetHeight(buffer);
        CGRect frame = CGRectMake(0,0,windowWidth,windowHeight);
        CGRect full = windowed ? viewport : frame;
        if (!CGRectContainsRect(frame,full) || full.size.height <= 0 || fabs(full.size.width-full.size.height*w/h) > 2 ||
            (!windowed && (windowWidth < w || windowHeight < h))) { CFRelease(sample); return 1; }
        CVPixelBufferLockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly);
        Image image = {windowWidth,windowHeight,CVPixelBufferGetBytesPerRow(buffer),CVPixelBufferGetBaseAddress(buffer)};
        double compareWidth = w, compareHeight = h;
        if (windowed && (full.size.width <= w || full.size.height <= h)) {
            compareWidth = full.size.width * .75; compareHeight = full.size.height * .75;
        }
        CGRect native = CGRectMake(floor(CGRectGetMidX(full)-compareWidth/2),floor(CGRectGetMidY(full)-compareHeight/2),compareWidth,compareHeight);
        double match = similarity(image,fit ? full : native,reference);
        mirrorScores(image,fit ? full : native,reference,mirrors);
        if (match > best) { best = match; bestTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)); }
        double alternative = similarity(image,fit ? native : full,reference);
        otherBest = MAX(otherBest,alternative);
        double margin = fit ? 0 : marginMean(image,native);
        if (margin > worstMargin) {
            worstMargin = margin;
            worstMarginTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
        }
        CVPixelBufferUnlockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly); CFRelease(sample);
        count++;
    } }
    printf("Source %zux%zu, window %zux%zu, frames %d, duration %.3fs\n",w,h,windowWidth,windowHeight,count,CMTimeGetSeconds(asset.duration));
    printf("Best %s match %.4f at %.3fs, other layout %.4f\n",windowed ? "video rectangle" : fit ? "full-window" : "original-size",best,bestTime,otherBest);
    if (!fit) printf("Maximum mean margin luma %.2f/255 at %.3fs\n",worstMargin,worstMarginTime);
    printf("Best upside-down %.4f, left-right mirror %.4f, rotated 180 degrees %.4f\n",mirrors[0],mirrors[1],mirrors[2]);
    return !(reader.status == AVAssetReaderStatusCompleted && w == 1920 && h == 1080 &&
        (windowed || (windowWidth == 2560 && windowHeight == 1440)) && count > 1 && best > .97 && best > otherBest+.015 &&
        best > MAX(mirrors[0], MAX(mirrors[1],mirrors[2]))+.015 && worstMargin < 3);
} }
