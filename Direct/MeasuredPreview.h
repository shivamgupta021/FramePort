#import <QuartzCore/CAMetalLayer.h>
#import <CoreMedia/CoreMedia.h>
#import "PictureOptions.h"
#import "Video.h"
#import "PresentationTiming.h"
#import "FramePresentation.h"

typedef struct {
    CGSize inputSize;
    double inputFPS, outputFPS, originalFPS, generatedFPS, captureToPresentMS, deliveryToPresentMS, intervalP95MS;
    NSUInteger captureDrops, previewDrops, originalDrops, generatedDrops, heldDrops;
    FPSourceTiming realFrameMS;
} PreviewStatistics;

@class NSView;

@interface MeasuredPreview : NSObject
@property(nonatomic, readonly) CAMetalLayer *layer;
@property(atomic) BOOL visible;
@property(atomic) BOOL generationEnabled;
@property(atomic) FPGenerationEngine generationEngine;
@property(atomic) FPPictureOptions pictureOptions;
@property(atomic, readonly, copy) NSString *generationError;
- (void)prepareGenerationForWidth:(size_t)width height:(size_t)height;
- (void)displaySample:(CMSampleBufferRef)sample captureTime:(double)captureTime deliveryTime:(double)deliveryTime;
- (void)captureDropped;
- (void)startPresentationInView:(NSView *)view;
- (void)stopPresentation;
/// Shared by the display link and synthetic presentation checks.
- (PreviewSlot *)frameForDisplayTime:(double)target interval:(double)interval now:(double)now epoch:(NSUInteger *)epoch;
- (PreviewStatistics)readStatistics;
@end
