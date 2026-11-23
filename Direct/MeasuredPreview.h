#import <QuartzCore/CAMetalLayer.h>
#import <CoreMedia/CoreMedia.h>

typedef struct {
    CGSize inputSize;
    double inputFPS, outputFPS, generatedFPS, changeFPS, captureToPresentMS, deliveryToPresentMS, intervalP95MS;
    NSUInteger captureDrops, previewDrops;
} PreviewStatistics;

@interface MeasuredPreview : NSObject
@property(nonatomic, readonly) CAMetalLayer *layer;
@property(atomic) BOOL visible;
@property(atomic) BOOL generationEnabled;
@property(atomic, readonly, copy) NSString *generationError;
- (void)prepareGenerationForWidth:(size_t)width height:(size_t)height;
- (void)displaySample:(CMSampleBufferRef)sample captureTime:(double)captureTime deliveryTime:(double)deliveryTime;
- (void)captureDropped;
- (PreviewStatistics)readStatistics;
@end
