#import <AppKit/AppKit.h>
#import "PictureOptions.h"
#import "Video.h"

@interface PlaybackSettings : NSWindowController
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
@property(nonatomic, readonly) FPPictureOptions pictureOptions;
@property(nonatomic, readonly) BOOL startsFullScreen;
@property(nonatomic, readonly) FPGenerationEngine generationEngine;
@property(nonatomic, copy) void (^engineDidChange)(FPGenerationEngine engine);
@property(nonatomic, copy) void (^pictureDidChange)(FPPictureOptions options);
@end
