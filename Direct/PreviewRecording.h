#import <AppKit/AppKit.h>

// Captures only the app's own window, including the surrounding black margins.
@interface PreviewRecording : NSObject
@property(nonatomic, readonly) BOOL busy;
- (void)recordWindow:(NSWindow *)window toURL:(NSURL *)url
          completion:(void (^)(NSError *error))completion;
@end
