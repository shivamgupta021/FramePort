#import "PreviewRecording.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>

@interface PreviewRecording () <SCRecordingOutputDelegate, SCStreamDelegate>
@property(nonatomic, strong) SCStream *stream;
@property(nonatomic, strong) SCRecordingOutput *output;
@property(nonatomic, copy) void (^completion)(NSError *);
@end

@implementation PreviewRecording
- (BOOL)busy { return self.completion != nil; }
- (void)finish:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        void (^done)(NSError *) = self.completion;
        self.completion = nil;
        self.stream = nil;
        self.output = nil;
        if (done) done(error);
    });
}
- (void)recordWindow:(NSWindow *)window toURL:(NSURL *)url
          completion:(void (^)(NSError *))completion {
    if (self.busy) return;
    self.completion = completion;
    CGWindowID windowID = (CGWindowID)window.windowNumber;
    [SCShareableContent getCurrentProcessShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
        SCWindow *target = nil;
        for (SCWindow *candidate in content.windows) {
            if (candidate.windowID == windowID) { target = candidate; break; }
        }
        if (!target) {
            [self finish:error ?: [NSError errorWithDomain:@"FramePort" code:1 userInfo:@{
                NSLocalizedDescriptionKey:@"macOS could not find the preview window to record."}]];
            return;
        }
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:target];
        SCStreamConfiguration *config = [SCStreamConfiguration new];
        config.width = lround(filter.contentRect.size.width * filter.pointPixelScale);
        config.height = lround(filter.contentRect.size.height * filter.pointPixelScale);
        config.minimumFrameInterval = CMTimeMake(1, 60);
        config.showsCursor = NO;
        config.capturesAudio = NO;
        config.captureMicrophone = NO;
        config.includeChildWindows = NO;
        config.ignoreShadowsSingleWindow = YES;
        config.backgroundColor = NSColor.blackColor.CGColor;
        self.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
        SCRecordingOutputConfiguration *file = [SCRecordingOutputConfiguration new];
        file.outputURL = url;
        self.output = [[SCRecordingOutput alloc] initWithConfiguration:file delegate:self];
        NSError *setupError = nil;
        if (![self.stream addRecordingOutput:self.output error:&setupError]) { [self finish:setupError]; return; }
        [self.stream startCaptureWithCompletionHandler:^(NSError *startError) {
            if (startError) [self finish:startError];
        }];
    }];
}
- (void)recordingOutputDidStartRecording:(SCRecordingOutput *)recordingOutput {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (recordingOutput != self.output) return;
        [self.stream stopCaptureWithCompletionHandler:^(NSError *error) {
            if (error) [self finish:error];
        }];
    });
}
- (void)recordingOutputDidFinishRecording:(SCRecordingOutput *)output { [self finish:nil]; }
- (void)recordingOutput:(SCRecordingOutput *)output didFailWithError:(NSError *)error { [self finish:error]; }
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error { [self finish:error]; }
@end
