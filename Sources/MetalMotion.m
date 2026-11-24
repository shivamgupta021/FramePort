#import "MetalMotion.h"

@interface FPMetalMotion ()
@property(atomic, strong) NSError *asynchronousError;
@end

@implementation FPMetalMotion {
    id<MTLDevice> _gpu;
    id<MTLCommandQueue> _queue;
    id<MTLComputePipelineState> _downsample, _coarseMotion, _estimate, _warp, _reconstruct;
    id<MTLTexture> _field, _coarseField, _smallA, _smallB;
    CVMetalTextureCacheRef _cache;
    CVPixelBufferPoolRef _pool;
}
- (instancetype)initWithWidth:(size_t)width height:(size_t)height outputWidth:(size_t)outWidth outputHeight:(size_t)outHeight error:(NSError **)error {
    if (!(self=[super init])) return nil;
    _gpu = MTLCreateSystemDefaultDevice();
    _queue = [_gpu newCommandQueue];
    NSURL *url = [NSBundle.mainBundle URLForResource:@"Motion" withExtension:@"metal"];
    if (!url) url = [[NSBundle.mainBundle.executableURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"Motion.metal"];
    NSString *source = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:error];
    if (!source) return nil;
    id<MTLLibrary> lib = [_gpu newLibraryWithSource:source options:nil error:error];
    if (!lib) return nil;
    _downsample = [_gpu newComputePipelineStateWithFunction:[lib newFunctionWithName:@"downsample"] error:error];
    if (!_downsample) return nil;
    _coarseMotion = [_gpu newComputePipelineStateWithFunction:[lib newFunctionWithName:@"coarseMotion"] error:error];
    if (!_coarseMotion) return nil;
    _estimate = [_gpu newComputePipelineStateWithFunction:[lib newFunctionWithName:@"estimate"] error:error];
    if (!_estimate) return nil;
    _warp = [_gpu newComputePipelineStateWithFunction:[lib newFunctionWithName:@"midpoint"] error:error];
    if (!_warp) return nil;
    _reconstruct = [_gpu newComputePipelineStateWithFunction:[lib newFunctionWithName:@"reconstructGuide"] error:error];
    if (!_reconstruct) return nil;
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Float width:(width+11)/12 height:(height+11)/12 mipmapped:NO];
    desc.storageMode = MTLStorageModePrivate;
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    _field = [_gpu newTextureWithDescriptor:desc];
    desc.width = (width+47)/48; desc.height = (height+47)/48;
    _coarseField = [_gpu newTextureWithDescriptor:desc];
    desc.pixelFormat = MTLPixelFormatR8Unorm;
    desc.width = (width+3)/4; desc.height = (height+3)/4;
    _smallA = [_gpu newTextureWithDescriptor:desc];
    _smallB = [_gpu newTextureWithDescriptor:desc];
    NSDictionary *attrs = @{(id)kCVPixelBufferWidthKey:@(outWidth), (id)kCVPixelBufferHeightKey:@(outHeight),
        (id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferMetalCompatibilityKey:@YES, (id)kCVPixelBufferIOSurfacePropertiesKey:@{}};
    if (!_queue || !_field || !_coarseField || !_smallA || !_smallB || CVMetalTextureCacheCreate(NULL,NULL,_gpu,NULL,&_cache) != kCVReturnSuccess ||
        CVPixelBufferPoolCreate(NULL,NULL,(__bridge CFDictionaryRef)attrs,&_pool) != kCVReturnSuccess) {
        if (error) *error = FPError(@"Could not allocate Metal motion buffers."); return nil;
    }
    return self;
}
- (id<MTLTexture>)textureFor:(CVPixelBufferRef)buffer plane:(size_t)plane owners:(NSMutableArray *)owners {
    CVMetalTextureRef view = NULL;
    CVReturn status = CVMetalTextureCacheCreateTextureFromImage(NULL,_cache,buffer,NULL,
        plane == 0 ? MTLPixelFormatR8Unorm : MTLPixelFormatRG8Unorm, CVPixelBufferGetWidthOfPlane(buffer,plane),
        CVPixelBufferGetHeightOfPlane(buffer,plane),plane,&view);
    if (status != kCVReturnSuccess || !view) return nil;
    id<MTLTexture> texture = CVMetalTextureGetTexture(view);
    [owners addObject:CFBridgingRelease(view)];
    return texture;
}
- (BOOL)encode:(id<MTLComputePipelineState>)kernel command:(id<MTLCommandBuffer>)cmd
       textures:(NSArray<id<MTLTexture>> *)textures output:(id<MTLTexture>)output {
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    if (!enc) return NO;
    [enc setComputePipelineState:kernel];
    for (NSUInteger i=0; i<textures.count; ++i) [enc setTexture:textures[i] atIndex:i];
    [enc dispatchThreads:MTLSizeMake(output.width,output.height,1) threadsPerThreadgroup:MTLSizeMake(16,8,1)];
    [enc endEncoding];
    return YES;
}
- (FPFrame *)midpointFrom:(FPFrame *)a to:(FPFrame *)b error:(NSError **)error {
    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    FPFrame *result = [self encodeMidpointFrom:a to:b command:cmd error:error];
    if (!result) return nil;
    [cmd commit]; [cmd waitUntilCompleted];
    if (cmd.status == MTLCommandBufferStatusCompleted) return result;
    if (error) *error = cmd.error ?: FPError(@"The GPU could not finish the midpoint.");
    return nil;
}
- (BOOL)estimateFrom:(id<MTLTexture>)previous to:(id<MTLTexture>)current command:(id<MTLCommandBuffer>)cmd {
    return [self encode:_downsample command:cmd textures:@[previous,_smallA] output:_smallA] &&
           [self encode:_downsample command:cmd textures:@[current,_smallB] output:_smallB] &&
           [self encode:_coarseMotion command:cmd textures:@[_smallA,_smallB,_coarseField] output:_coarseField] &&
           [self encode:_estimate command:cmd textures:@[previous,current,_field,_coarseField] output:_field];
}
- (id<MTLCommandBuffer>)estimateDetailFrom:(FPFrame *)a to:(FPFrame *)b error:(NSError **)error {
    NSError *prior = self.asynchronousError;
    if (prior) { if (error) *error = prior; return nil; }
    NSMutableArray *owners = [NSMutableArray arrayWithObjects:a,b,nil];
    id<MTLTexture> previous = [self textureFor:a.pixels plane:0 owners:owners];
    id<MTLTexture> current = [self textureFor:b.pixels plane:0 owners:owners];
    id<MTLCommandBuffer> cmd = [(_presentationQueue ?: _queue) commandBuffer];
    if (!previous || !current || !cmd || ![self estimateFrom:previous to:current command:cmd]) {
        if (error) *error = FPError(@"Could not estimate native image detail.");
        return nil;
    }
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> done) { (void)owners.count; }];
    [cmd commit];
    return cmd;
}
- (FPFrame *)reconstructGuide:(FPFrame *)guide from:(FPFrame *)a to:(FPFrame *)b motion:(id<MTLCommandBuffer>)motion error:(NSError **)error {
    CVPixelBufferRef dest = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL,_pool,&dest) != kCVReturnSuccess) {
        if (error) *error = FPError(@"Could not allocate the reconstruction buffer."); return nil;
    }
    CVBufferPropagateAttachments(b.pixels,dest);
    __attribute__((objc_precise_lifetime)) NSMutableArray *owners = [NSMutableArray arrayWithObjects:a,b,guide,nil];
    id<MTLCommandBuffer> cmd = [(_presentationQueue ?: _queue) commandBuffer];
    BOOL valid = cmd != nil;
    for (size_t plane=0; plane<2 && valid; ++plane) {
        id<MTLTexture> previous = [self textureFor:a.pixels plane:plane owners:owners];
        id<MTLTexture> current = [self textureFor:b.pixels plane:plane owners:owners];
        id<MTLTexture> prediction = [self textureFor:guide.pixels plane:plane owners:owners];
        id<MTLTexture> out = [self textureFor:dest plane:plane owners:owners];
        valid = previous && current && prediction && out;
        if (!valid) break;
        id<MTLComputeCommandEncoder> encoder = [cmd computeCommandEncoder];
        if (!encoder) { valid = NO; break; }
        [encoder setComputePipelineState:_reconstruct];
        NSArray *textures = @[previous,current,prediction,out,_field];
        for (NSUInteger i=0; i<textures.count; i++) [encoder setTexture:textures[i] atIndex:i];
        bool luma = plane == 0;
        [encoder setBytes:&luma length:sizeof(luma) atIndex:0];
        [encoder dispatchThreads:MTLSizeMake(out.width,out.height,1) threadsPerThreadgroup:MTLSizeMake(16,8,1)];
        [encoder endEncoding];
    }
    FPFrame *result = nil;
    if (valid) {
        result = [FPFrame frame:dest time:guide.time producedBy:cmd];
        [owners addObject:(__bridge id)dest];
        [cmd addCompletedHandler:^(id<MTLCommandBuffer> done) {
            (void)owners.count;
            if (motion.error || done.error) self.asynchronousError = motion.error ?: done.error;
        }];
        [cmd commit];
        // The live renderer submits its read on this same queue. Offline callers
        // receive a CPU-readable frame only after both GPU passes have finished.
        if (!_presentationQueue) {
            [cmd waitUntilCompleted];
            if (motion.status != MTLCommandBufferStatusCompleted || cmd.status != MTLCommandBufferStatusCompleted) result = nil;
        }
    }
    if (!result && error) *error = motion.error ?: cmd.error ?: FPError(@"Could not reconstruct the interpolated picture.");
    CVPixelBufferRelease(dest);
    return result;
}
- (FPFrame *)encodeMidpointFrom:(FPFrame *)a to:(FPFrame *)b command:(id<MTLCommandBuffer>)cmd error:(NSError **)error {
    CVPixelBufferRef dest = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL,_pool,&dest) != kCVReturnSuccess) {
        if (error) *error = FPError(@"Could not allocate the Metal midpoint."); return nil;
    }
    CVBufferPropagateAttachments(b.pixels,dest);
    NSMutableArray *owners = [NSMutableArray arrayWithObjects:a, b, nil];
    id<MTLTexture> lumaA = nil, lumaB = nil;
    BOOL valid = cmd != nil;
    for (size_t plane=0; plane<2 && valid; ++plane) {
        id<MTLTexture> previous = [self textureFor:a.pixels plane:plane owners:owners];
        id<MTLTexture> current = [self textureFor:b.pixels plane:plane owners:owners];
        id<MTLTexture> out = [self textureFor:dest plane:plane owners:owners];
        valid = previous && current && out;
        if (!valid) break;
        if (plane == 0) {
            lumaA = previous; lumaB = current;
            if (![self estimateFrom:previous to:current command:cmd]) { valid = NO; break; }
        }
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        if (!enc) { valid = NO; break; }
        [enc setComputePipelineState:_warp];
        [enc setTexture:previous atIndex:0]; [enc setTexture:current atIndex:1]; [enc setTexture:_field atIndex:2]; [enc setTexture:out atIndex:3];
        [enc setTexture:lumaA atIndex:4]; [enc setTexture:lumaB atIndex:5];
        float planeScale = plane ? 2 : 1;
        [enc setBytes:&planeScale length:sizeof(planeScale) atIndex:0];
        [enc dispatchThreads:MTLSizeMake(out.width,out.height,1) threadsPerThreadgroup:MTLSizeMake(16,8,1)];
        [enc endEncoding];
    }
    FPFrame *result = nil;
    if (valid) {
        CMTime mid = CMTimeAdd(a.time,CMTimeMultiplyByRatio(CMTimeSubtract(b.time,a.time),1,2));
        result = [FPFrame frame:dest time:mid producedBy:cmd];
        [owners addObject:(__bridge id)dest];
    }
    // CVMetalTexture views and their backing pixel buffers must live through GPU completion.
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> done) { (void)owners.count; }];
    if (!result && error) *error = cmd.error ?: FPError(@"The capture buffers could not be processed by Metal.");
    CVPixelBufferRelease(dest);
    return result;
}
- (void)dealloc { if (_cache) CFRelease(_cache); if (_pool) CVPixelBufferPoolRelease(_pool); }
@end
