#import <QuartzCore/CAMetalLayer.h>
#import <CoreMedia/CoreMedia.h>
#import "PictureOptions.h"
#import "PresentationTiming.h"

typedef struct {
    CGSize inputSize;
    double inputFPS, outputFPS, generatedFPS, changeFPS, captureToPresentMS, deliveryToPresentMS, intervalP95MS;
    NSUInteger captureDrops, previewDrops;
    FPSourceTiming realFrameMS;
} PreviewStatistics;

@interface MeasuredPreview : NSObject
@property(nonatomic, readonly) CAMetalLayer *layer;
@property(atomic) BOOL visible;
@property(atomic) BOOL generationEnabled;
@property(atomic) FPPictureOptions pictureOptions;
@property(atomic, readonly, copy) NSString *generationError;
- (void)prepareGenerationForWidth:(size_t)width height:(size_t)height;
- (void)displaySample:(CMSampleBufferRef)sample captureTime:(double)captureTime deliveryTime:(double)deliveryTime;
- (void)captureDropped;
- (PreviewStatistics)readStatistics;
@end
