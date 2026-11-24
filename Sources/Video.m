#import "Video.h"
#import "MetalMotion.h"
#import <CoreImage/CoreImage.h>

NSError *FPError(NSString *message) {
    return [NSError errorWithDomain:@"FramePort" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}

@implementation FPFrame {
    id<MTLCommandBuffer> _producer;
}
+ (instancetype)frame:(CVPixelBufferRef)pixels time:(CMTime)time {
    return [self frame:pixels time:time producedBy:nil];
}
+ (instancetype)frame:(CVPixelBufferRef)pixels time:(CMTime)time producedBy:(id<MTLCommandBuffer>)command {
    FPFrame *frame = [self new];
    frame->_pixels = CVPixelBufferRetain(pixels);
    frame->_time = time;
    frame->_producer = command;
    return frame;
}
- (BOOL)isReadyForQueue:(id<MTLCommandQueue>)queue {
    if (!_producer) return YES;
    MTLCommandBufferStatus status = _producer.status;
    if (status == MTLCommandBufferStatusCompleted) return YES;
    return queue == _producer.commandQueue && status >= MTLCommandBufferStatusCommitted &&
        status < MTLCommandBufferStatusCompleted;
}
- (void)dealloc { CVPixelBufferRelease(_pixels); }
@end

@interface FPAppleSession : NSObject
- (instancetype)initWithWidth:(size_t)width height:(size_t)height error:(NSError **)error;
- (FPFrame *)midpointFrom:(FPFrame *)a to:(FPFrame *)b error:(NSError **)error;
@end

@implementation FPAppleSession {
    VTFrameProcessor *_processor;
    CVPixelBufferPoolRef _pool;
}
- (instancetype)initWithWidth:(size_t)width height:(size_t)height error:(NSError **)error {
    if (!(self = [super init])) return nil;
    VTLowLatencyFrameInterpolationConfiguration *config = nil;
    if (VTLowLatencyFrameInterpolationConfiguration.isSupported) {
        config = [[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:width frameHeight:height numberOfInterpolatedFrames:1];
    }
    if (!config || ![config.frameSupportedPixelFormats containsObject:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)]) {
        *error = FPError(@"Apple frame generation is unavailable for this size or pixel format.");
        return nil;
    }
    NSMutableDictionary *attrs = config.destinationPixelBufferAttributes.mutableCopy;
    attrs[(id)kCVPixelBufferMetalCompatibilityKey] = @YES;
    if (CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attrs, &_pool) != kCVReturnSuccess) {
        *error = FPError(@"Could not allocate the interpolation buffer pool.");
        return nil;
    }
    VTFrameProcessor *processor = [VTFrameProcessor new];
    if (![processor startSessionWithConfiguration:config error:error]) return nil;
    _processor = processor;
    return self;
}
- (FPFrame *)midpointFrom:(FPFrame *)a to:(FPFrame *)b error:(NSError **)error {
    CMTime mid = CMTimeAdd(a.time, CMTimeMultiplyByRatio(CMTimeSubtract(b.time, a.time), 1, 2));
    CVPixelBufferRef dest = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, _pool, &dest) != kCVReturnSuccess) {
        *error = FPError(@"Could not allocate a generated frame.");
        return nil;
    }
    CVBufferPropagateAttachments(b.pixels, dest);
    VTFrameProcessorFrame *previous = [[VTFrameProcessorFrame alloc] initWithBuffer:a.pixels presentationTimeStamp:a.time];
    VTFrameProcessorFrame *current = [[VTFrameProcessorFrame alloc] initWithBuffer:b.pixels presentationTimeStamp:b.time];
    VTFrameProcessorFrame *output = [[VTFrameProcessorFrame alloc] initWithBuffer:dest presentationTimeStamp:mid];
    FPFrame *result = nil;
    if (previous && current && output) {
        VTLowLatencyFrameInterpolationParameters *params = [[VTLowLatencyFrameInterpolationParameters alloc] initWithSourceFrame:current previousFrame:previous interpolationPhase:@[@0.5] destinationFrames:@[output]];
        if (params && [_processor processWithParameters:params error:error]) result = [FPFrame frame:dest time:mid];
        if (!params) *error = FPError(@"Apple rejected the interpolation parameters.");
    } else {
        *error = FPError(@"The capture device did not supply a GPU-compatible buffer.");
    }
    CVPixelBufferRelease(dest);
    return result;
}
- (void)dealloc {
    [_processor endSession];
    if (_pool) CVPixelBufferPoolRelease(_pool);
}
@end

// Converts the card's native pixel layout and, when necessary, resizes both references.
@interface FPFrameConverter : NSObject
- (instancetype)initWithWidth:(size_t)width height:(size_t)height;
- (FPFrame *)convert:(FPFrame *)frame;
@end

@implementation FPFrameConverter {
    VTPixelTransferSessionRef _transfer;
    CVPixelBufferPoolRef _pool;
    FPFrame *_lastInput, *_lastOutput;
}
- (instancetype)initWithWidth:(size_t)width height:(size_t)height {
    if (!(self = [super init])) return nil;
    NSDictionary *attrs = @{(id)kCVPixelBufferWidthKey:@(width), (id)kCVPixelBufferHeightKey:@(height),
        (id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferMetalCompatibilityKey:@YES, (id)kCVPixelBufferIOSurfacePropertiesKey:@{}};
    if (VTPixelTransferSessionCreate(NULL, &_transfer) != noErr ||
        CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attrs, &_pool) != kCVReturnSuccess) return nil;
    return self;
}
- (FPFrame *)convert:(FPFrame *)frame {
    if (frame == _lastInput) return _lastOutput;
    CVPixelBufferRef dest = NULL;
    FPFrame *result = nil;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, _pool, &dest) == kCVReturnSuccess) {
        if (VTPixelTransferSessionTransferImage(_transfer, frame.pixels, dest) == noErr)
            result = [FPFrame frame:dest time:frame.time];
        CVPixelBufferRelease(dest);
    }
    _lastInput = frame;
    _lastOutput = result;
    return result;
}
- (void)dealloc {
    if (_transfer) { VTPixelTransferSessionInvalidate(_transfer); CFRelease(_transfer); }
    if (_pool) CVPixelBufferPoolRelease(_pool);
}
@end

@implementation FPInterpolator {
    FPAppleSession *_session;
    FPFrameConverter *_converter;
    size_t _width, _height;
    BOOL _reduced;
    FPMetalMotion *_metal;
    FPMetalMotion *_reconstruction;
}
- (instancetype)initWithWidth:(size_t)width height:(size_t)height error:(NSError **)error {
    return [self initWithWidth:width height:height engine:FPGenerationApple error:error];
}
- (instancetype)initWithWidth:(size_t)width height:(size_t)height engine:(FPGenerationEngine)engine error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _width = width;
    _height = height;
    if (engine == FPGenerationGuided) {
        if (width <= 1280) {
            _session = [[FPAppleSession alloc] initWithWidth:width height:height error:error];
            return _session ? self : nil;
        }
        if (![self startReducedSession:error]) return nil;
        _reconstruction = [[FPMetalMotion alloc] initWithWidth:width height:height outputWidth:width outputHeight:height error:error];
        return _reconstruction ? self : nil;
    }
    if (engine != FPGenerationApple) {
        size_t outHeight = engine == FPGenerationMetal1440 ? 1440 : height;
        size_t outWidth = 2 * lround(width*(double)outHeight/height/2);
        _metal = [[FPMetalMotion alloc] initWithWidth:width height:height outputWidth:outWidth outputHeight:outHeight error:error];
        return _metal ? self : nil;
    }
    _session = [[FPAppleSession alloc] initWithWidth:width height:height error:error];
    if (!_session && ![self startReducedSession:error]) return nil;
    return self;
}
- (void)usePresentationQueue:(id<MTLCommandQueue>)queue { _reconstruction.presentationQueue = queue; }
- (BOOL)startReducedSession:(NSError **)error {
    if (_width <= 1280 || _width * 9 != _height * 16 || _reduced) return NO;
    _session = nil;
    _session = [[FPAppleSession alloc] initWithWidth:1280 height:720 error:error];
    if (!_session) return NO;
    _reduced = YES;
    _converter = [[FPFrameConverter alloc] initWithWidth:1280 height:720];
    if (!_converter) *error = FPError(@"Could not allocate the interpolation input buffers.");
    return _converter != nil;
}
- (FPFrame *)processFrom:(FPFrame *)a to:(FPFrame *)b error:(NSError **)error {
    if (_converter) {
        a = [_converter convert:a];
        b = [_converter convert:b];
        if (!a || !b) { *error = FPError(@"Could not convert a capture frame for interpolation."); return nil; }
    }
    return _metal ? [_metal midpointFrom:a to:b error:error] : [_session midpointFrom:a to:b error:error];
}
- (FPFrame *)midpointFrom:(FPFrame *)a to:(FPFrame *)b error:(NSError **)error {
    if (!_converter && (CVPixelBufferGetPixelFormatType(b.pixels) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                        !CVPixelBufferGetIOSurface(b.pixels) || !CVPixelBufferGetIOSurface(a.pixels))) {
        _converter = [[FPFrameConverter alloc] initWithWidth:_width height:_height];
        if (!_converter) { *error = FPError(@"Could not prepare the capture card's pixel format."); return nil; }
    }
    id<MTLCommandBuffer> motion = [_reconstruction estimateDetailFrom:a to:b error:error];
    if (_reconstruction && !motion) return nil;
    FPFrame *result = [self processFrom:a to:b error:error];
    // On macOS 26, 1080p can pass session setup and fail on the first actual pair.
    if (!result && !_metal && [self startReducedSession:error]) result = [self processFrom:a to:b error:error];
    if (result && _reconstruction) return [_reconstruction reconstructGuide:result from:a to:b motion:motion error:error];
    return result;
}
@end

@implementation FPPattern {
    CVPixelBufferPoolRef _pool;
    int _width, _height;
}
- (instancetype)initWithWidth:(int)width height:(int)height {
    if (!(self = [super init])) return nil;
    NSDictionary *attrs = @{(id)kCVPixelBufferWidthKey:@(width), (id)kCVPixelBufferHeightKey:@(height),
        (id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferIOSurfacePropertiesKey:@{}, (id)kCVPixelBufferMetalCompatibilityKey:@YES};
    if (CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attrs, &_pool) != kCVReturnSuccess) return nil;
    _width = width;
    _height = height;
    return self;
}
- (FPFrame *)frameAtIndex:(int64_t)index {
    CVPixelBufferRef pixels = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, _pool, &pixels) != kCVReturnSuccess) return nil;
    CVPixelBufferLockBaseAddress(pixels, 0);
    uint8_t *yPlane = CVPixelBufferGetBaseAddressOfPlane(pixels, 0);
    size_t stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0);
    // Architectural grid and moving striped tile reveal pan judder and doubling.
    int tile = _height / 4;
    int left = 16 + (int)((index * 12) % (_width - tile - 32));
    int top = (_height - tile) / 2;
    for (int y = 0; y < _height; y++) {
        uint8_t *row = yPlane + y * stride;
        memset(row, y % 90 < 2 ? 76 : 37 + y * 12 / _height, _width);
        if (y % 90 >= 2) for (int x = 0; x < _width-1; x += 90) { row[x] = row[x+1] = 64; }
        if (y >= top && y < top + tile) {
            memset(row + left, 209, tile);
            if (y > top + 8 && y < top + tile - 8)
                for (int x = 12; x < tile - 10; x += 24) memset(row + left + x, 100, 6);
        }
    }
    uint8_t *uv = CVPixelBufferGetBaseAddressOfPlane(pixels, 1);
    size_t uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 1);
    memset(uv, 128, uvStride * CVPixelBufferGetHeightOfPlane(pixels, 1));
    for (int y = top / 2; y < (top + tile) / 2; y++)
        for (int x = left & ~1; x < left + tile - 1; x += 2) {
            uv[y * uvStride + x] = 82;
            uv[y * uvStride + x + 1] = 100;
        }
    CVPixelBufferUnlockBaseAddress(pixels, 0);
    CVBufferSetAttachment(pixels, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixels, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixels, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    FPFrame *frame = [FPFrame frame:pixels time:CMTimeMake(index * 2000, 60000)];
    CVPixelBufferRelease(pixels);
    return frame;
}
- (void)dealloc { if (_pool) CVPixelBufferPoolRelease(_pool); }
@end

@implementation FPScaler {
    CIContext *_context;
    CGColorSpaceRef _outputSpace;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if (!(self = [super init])) return nil;
    _outputSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    _context = [CIContext contextWithMTLDevice:device options:@{kCIContextCacheIntermediates:@NO, kCIContextName:@"Second Frame display"}];
    return self;
}
- (void)render:(FPFrame *)frame into:(id<MTLTexture>)texture command:(id<MTLCommandBuffer>)command {
    CIImage *source = [CIImage imageWithCVPixelBuffer:frame.pixels];
    CGRect bounds = CGRectMake(0, 0, texture.width, texture.height);
    double scale = MIN(bounds.size.width/source.extent.size.width, bounds.size.height/source.extent.size.height);
    CIImage *scaled = source;
    if (_fastScaling) {
        scaled = [source imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale) highQualityDownsample:NO];
    } else if (fabs(scale - 1) > 0.0001) {
        scaled = [[source imageByClampingToExtent] imageByApplyingFilter:@"CILanczosScaleTransform"
            withInputParameters:@{kCIInputScaleKey:@(scale), kCIInputAspectRatioKey:@1}];
        scaled = [scaled imageByCroppingToRect:CGRectApplyAffineTransform(source.extent, CGAffineTransformMakeScale(scale, scale))];
    }
    double dx = round((bounds.size.width - scaled.extent.size.width)/2);
    double dy = round((bounds.size.height - scaled.extent.size.height)/2);
    CIImage *centered = [scaled imageByApplyingTransform:CGAffineTransformMakeTranslation(dx, dy)];
    CIImage *canvas = [centered imageByCompositingOverImage:[CIImage imageWithColor:CIColor.blackColor]];
    [_context render:canvas toMTLTexture:texture commandBuffer:command bounds:bounds colorSpace:_outputSpace];
}
- (void)dealloc { CGColorSpaceRelease(_outputSpace); }
@end
