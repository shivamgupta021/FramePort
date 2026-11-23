#import <AppKit/AppKit.h>

// Captures only gta60fps's own window, including the surrounding black margins.
@interface PreviewRecording : NSObject
@property(nonatomic, readonly) BOOL busy;
- (void)recordWindow:(NSWindow *)window toURL:(NSURL *)url
          completion:(void (^)(NSError *error))completion;
@end
