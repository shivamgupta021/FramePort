#import "Video.h"
@interface FPMetalMotion : NSObject
- (instancetype)initWithWidth:(size_t)width height:(size_t)height outputWidth:(size_t)outWidth outputHeight:(size_t)outHeight error:(NSError **)error;
- (FPFrame *)midpointFrom:(FPFrame *)a to:(FPFrame *)b error:(NSError **)error;
@property(nonatomic,strong) id<MTLCommandQueue> presentationQueue;
- (id<MTLCommandBuffer>)estimateDetailFrom:(FPFrame *)a to:(FPFrame *)b error:(NSError **)error;
- (FPFrame *)reconstructGuide:(FPFrame *)guide from:(FPFrame *)a to:(FPFrame *)b motion:(id<MTLCommandBuffer>)motion error:(NSError **)error;
// Encode on the same GPU queue as the final scale. The caller commits the buffer.
- (FPFrame *)encodeMidpointFrom:(FPFrame *)a to:(FPFrame *)b command:(id<MTLCommandBuffer>)cmd error:(NSError **)error;
@end
