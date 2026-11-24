#import <AppKit/AppKit.h>
#import "PictureOptions.h"

@interface PlaybackSettings : NSWindowController
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
@property(nonatomic, readonly) FPPictureOptions pictureOptions;
@property(nonatomic, readonly) BOOL startsFullScreen;
@property(nonatomic, copy) void (^pictureDidChange)(FPPictureOptions options);
@end
