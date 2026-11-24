#import "PreviewRecording.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>

@interface PreviewRecording () <SCRecordingOutputDelegate, SCStreamDelegate>
@property(nonatomic, strong) SCStream *stream;
@property(nonatomic, strong) SCRecordingOutput *output;
@property(nonatomic, copy) void (^completion)(NSError *);
@property(nonatomic, strong) NSURL *outputURL;
@property(nonatomic) NSUInteger attempt;
@end

@implementation PreviewRecording
- (BOOL)busy { return self.outputURL != nil; }

- (void)finishAttempt:(NSUInteger)attempt error:(NSError *)error {
    if (!self.busy || attempt != self.attempt) return;
    void (^done)(NSError *) = self.completion;
    NSURL *url = self.outputURL;
    self.completion = nil;
    self.stream = nil;
    self.output = nil;
    self.outputURL = nil;
    if (error) [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
    if (done) done(error);
}

- (void)recordWindow:(NSWindow *)window toURL:(NSURL *)url
          completion:(void (^)(NSError *))completion {
    if (self.busy) return;
    NSUInteger attempt = ++self.attempt;
    self.completion = completion;
    self.outputURL = url;
    CGWindowID windowID = (CGWindowID)window.windowNumber;
    [SCShareableContent getCurrentProcessShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.busy || self.attempt != attempt) return;
            SCWindow *target = nil;
            for (SCWindow *candidate in content.windows) {
                if (candidate.windowID == windowID) { target = candidate; break; }
            }
            if (!target) {
                NSError *missingWindow = error ?: [NSError errorWithDomain:@"SecondFrame.Recording" code:1 userInfo:@{
                    NSLocalizedDescriptionKey:@"macOS could not find the preview window to record."
                }];
                [self finishAttempt:attempt error:missingWindow];
                return;
            }
            [self startAttempt:attempt window:target];
        });
    }];
}

- (void)startAttempt:(NSUInteger)attempt window:(SCWindow *)window {
    SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:window];
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
    file.outputURL = self.outputURL;
    self.output = [[SCRecordingOutput alloc] initWithConfiguration:file delegate:self];
    NSError *error = nil;
    if (![self.stream addRecordingOutput:self.output error:&error]) {
        [self finishAttempt:attempt error:error ?: [NSError errorWithDomain:@"SecondFrame.Recording" code:2 userInfo:@{
            NSLocalizedDescriptionKey:@"macOS could not prepare the recording output."
        }]];
        return;
    }
    [self.stream startCaptureWithCompletionHandler:^(NSError *startError) {
        if (startError) dispatch_async(dispatch_get_main_queue(), ^{
            [self finishAttempt:attempt error:startError];
        });
    }];
}

- (void)recordingOutputDidStartRecording:(SCRecordingOutput *)output {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (output != self.output) return;
        NSUInteger attempt = self.attempt;
        [self.stream stopCaptureWithCompletionHandler:^(NSError *error) {
            if (error) dispatch_async(dispatch_get_main_queue(), ^{
                [self finishAttempt:attempt error:error];
            });
        }];
    });
}

- (void)recordingOutputDidFinishRecording:(SCRecordingOutput *)output {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (output == self.output) [self finishAttempt:self.attempt error:nil];
    });
}

- (void)recordingOutput:(SCRecordingOutput *)output didFailWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (output == self.output) [self finishAttempt:self.attempt error:error];
    });
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (stream == self.stream) [self finishAttempt:self.attempt error:error];
    });
}
@end
