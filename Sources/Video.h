#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <MetalKit/MetalKit.h>
#import <VideoToolbox/VideoToolbox.h>

/// Owned pixel buffer and its capture-clock timestamp.
@interface FPFrame : NSObject
@property(nonatomic, readonly) CVPixelBufferRef pixels;
@property(nonatomic, readonly) CMTime time;
@property(nonatomic) double receivedAt, readyAt, targetTime;
+ (instancetype)frame:(CVPixelBufferRef)pixels time:(CMTime)time;
+ (instancetype)frame:(CVPixelBufferRef)pixels time:(CMTime)time producedBy:(id<MTLCommandBuffer>)command;
/// nil requires GPU completion. A committed producer may be read on its own queue.
- (BOOL)isReadyForQueue:(id<MTLCommandQueue>)queue;
@end

typedef NS_ENUM(NSInteger, FPGenerationEngine) {
    FPGenerationApple, FPGenerationMetalNative, FPGenerationMetal1440, FPGenerationGuided
};

/// Converts supported CoreVideo pixel buffers to IOSurface-backed video-range NV12.
@interface FPFrameConverter : NSObject
- (instancetype)initWithWidth:(size_t)width height:(size_t)height;
- (FPFrame *)convert:(FPFrame *)frame;
@end

@interface FPInterpolator : NSObject
// Enable ordered GPU-to-GPU handoff for the live detail renderer.
- (void)usePresentationQueue:(id<MTLCommandQueue>)queue;
- (instancetype)initWithWidth:(size_t)width height:(size_t)height error:(NSError **)error;
- (instancetype)initWithWidth:(size_t)width height:(size_t)height engine:(FPGenerationEngine)engine error:(NSError **)error;
- (FPFrame *)midpointFrom:(FPFrame *)a to:(FPFrame *)b error:(NSError **)error;
@end

/// The pattern and the capture delegate both supply IOSurface-backed SDR NV12.
@interface FPPattern : NSObject
- (instancetype)initWithWidth:(int)width height:(int)height;
- (FPFrame *)frameAtIndex:(int64_t)index;
@end

/// Aspect-fit, color-managed Lanczos output to a Metal texture in physical pixels.
@interface FPScaler : NSObject
@property(nonatomic) BOOL fastScaling;
- (instancetype)initWithDevice:(id<MTLDevice>)device;
- (void)render:(FPFrame *)frame into:(id<MTLTexture>)texture command:(id<MTLCommandBuffer>)command;
@end
NSError *FPError(NSString *message);
