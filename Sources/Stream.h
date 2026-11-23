#import "Video.h"

@interface FPStream : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property(atomic, copy) NSString *message;
@property(atomic, readonly) BOOL failed;
+ (NSArray<AVCaptureDevice *> *)devices;
- (instancetype)initWithGeneration:(BOOL)generation;
@property(nonatomic) FPGenerationEngine engine;
@property(nonatomic) double captureRate;
@property(nonatomic) BOOL lowLatency;
- (void)onFrameReady:(dispatch_block_t)render;
- (void)startPattern;
- (void)startCapture:(AVCaptureDevice *)device;
- (void)stop;
- (FPFrame *)frameDueAt:(double)hostTime;
- (void)didPresentAt:(double)time frame:(FPFrame *)frame submittedAt:(double)submitted;
- (void)recordRenderGPUTime:(double)seconds;
- (NSString *)timingSummary;
- (NSString *)statisticsAt:(double)now drawableSize:(CGSize)size;
@end
