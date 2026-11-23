#import "Video.h"
#import <CoreImage/CoreImage.h>

/// One color interpretation for the connected SDR capture session.
@interface PlaybackPicture : NSObject
- (instancetype)initWithSample:(CMSampleBufferRef)sample;
- (FPFrame *)frameFromSample:(CMSampleBufferRef)sample;
- (CIImage *)imageForFrame:(FPFrame *)frame size:(CGSize)size;
@end
