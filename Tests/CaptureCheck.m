#import "Stream.h"
#import <QuartzCore/QuartzCore.h>
#include <stdio.h>

@interface FPStream (InspectSchedule)
- (void)enqueue:(FPFrame *)frame at:(double)deadline;
@end

@interface ObservedStream : FPStream
@property(nonatomic, strong) NSMutableArray<FPFrame *> *scheduled;
@end
@implementation ObservedStream
- (void)enqueue:(FPFrame *)frame at:(double)deadline {
    [self.scheduled addObject:frame];
    [super enqueue:frame at:deadline];
}
@end

// Deliver a real CMSampleBuffer through the card delegate, including its transport PTS.
static BOOL deliver(ObservedStream *stream, CVPixelBufferRef pixels, CMTime time) {
    CMVideoFormatDescriptionRef format = NULL;
    CMSampleBufferRef sample = NULL;
    CMSampleTimingInfo timing = {CMTimeMake(1001,60000),time,kCMTimeInvalid};
    if (CMVideoFormatDescriptionCreateForImageBuffer(NULL,pixels,&format) != noErr) return NO;
    OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(NULL,pixels,format,&timing,&sample);
    CFRelease(format);
    if (status != noErr) return NO;
    // The simulated card has no AVCaptureConnection. The delegate only reads sample.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
    [stream captureOutput:nil didOutputSampleBuffer:sample fromConnection:nil];
#pragma clang diagnostic pop
    CFRelease(sample);
    return YES;
}

// Non-IOSurface BGRA exercises the converter path used by cards with other pixel layouts.
static CVPixelBufferRef newCardFrame(int index) {
    CVPixelBufferRef pixels = NULL;
    if (CVPixelBufferCreate(NULL,1280,720,kCVPixelFormatType_32BGRA,NULL,&pixels) != kCVReturnSuccess) return NULL;
    CVPixelBufferLockBaseAddress(pixels, 0);
    size_t stride = CVPixelBufferGetBytesPerRow(pixels);
    for (int y = 0; y < 720; y++) {
        uint32_t *row = (uint32_t *)((uint8_t *)CVPixelBufferGetBaseAddress(pixels)+y*stride);
        for (int x = 0; x < 1280; x++) row[x] = (x >= index*10+10 && x < index*10+110) ? 0xffeeeeee : 0xff303030;
    }
    CVPixelBufferUnlockBaseAddress(pixels, 0);
    return pixels;
}
int main(void) { @autoreleasepool {
    for (int generate = 0; generate <= 1; generate++) {
        ObservedStream *stream = [[ObservedStream alloc] initWithGeneration:generate];
        stream.scheduled = [NSMutableArray array];
        for (int i = 0; i < 5; i++) {
            CVPixelBufferRef pixels = newCardFrame(i);
            if (!pixels) return 1;
            for (int repeat = 0; repeat < 2; repeat++) {
                if (!deliver(stream,pixels,CMTimeMake((i*2+repeat)*1001,60000))) return 1;
            }
            CVPixelBufferRelease(pixels);
        }
        NSUInteger expected = generate ? 9 : 10;
        if (stream.scheduled.count != expected) { NSLog(@"Unexpected output count %lu. %@",stream.scheduled.count,stream.message); return 1; }
        for (NSUInteger i = 0; i < expected; i++) {
            FPFrame *frame = stream.scheduled[i];
            // Original BGRA and generated NV12 frames must alternate at the half-frame timestamps.
            OSType type = generate && i%2 ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA;
            if (CVPixelBufferGetPixelFormatType(frame.pixels) != type ||
                CMTimeCompare(frame.time,CMTimeMake(i*1001,60000)) != 0) {
                NSLog(@"Mode %d output %lu format %u expected %u, time %.8f expected %.8f", generate,i,
                    CVPixelBufferGetPixelFormatType(frame.pixels),type,CMTimeGetSeconds(frame.time),i*1001/60000.0);
                return 1;
            }
        }
        CVPixelBufferRef afterGap = newCardFrame(10);
        if (!afterGap || !deliver(stream,afterGap,CMTimeMake(1,1))) return 1;
        CVPixelBufferRelease(afterGap);
        if (stream.scheduled.count != expected+1 ||
            CMTimeCompare([stream frameDueAt:CACurrentMediaTime()+1].time, CMTimeMake(1,1)) != 0 ||
            [stream frameDueAt:CACurrentMediaTime()+1] != nil) { NSLog(@"Gap recovery mode %d", generate); return 1; }
        [stream stop];
    }
    // A true 60 Hz camera pan and uneven repeat runs each carry real frames
    // in odd transport slots. The middle frame must survive when its pixels change.
    const int sequence[] = {0,0,0,1,2,2,3,4,5,6};
    ObservedStream *mixed = [[ObservedStream alloc] initWithGeneration:YES];
    mixed.scheduled = [NSMutableArray array];
    NSMutableArray *originals = [NSMutableArray array];
    for (int i=0; i<10; ++i) {
        CVPixelBufferRef pixels = newCardFrame(sequence[i]);
        [originals addObject:(__bridge id)pixels];
        if (!deliver(mixed,pixels,CMTimeMake(i,60))) return 1;
        CVPixelBufferRelease(pixels);
    }
    if (mixed.scheduled.count != 9) return 1;
    for (int i=0; i<9; ++i) {
        BOOL generated = i==2 || i==5;
        FPFrame *out = mixed.scheduled[i];
        if (CMTimeCompare(out.time,CMTimeMake(i,60))!=0 ||
            (!generated && out.pixels != (__bridge CVPixelBufferRef)originals[i]) ||
            (generated && CVPixelBufferGetPixelFormatType(out.pixels)==kCVPixelFormatType_32BGRA)) {
            NSLog(@"Wrong real/generated image at transport slot %d",i); return 1;
        }
    }
    [mixed stop];
    // A display tick straddling the media deadline must not turn a one-ms
    // timing error into a repeated refresh followed by a discarded frame.
    FPStream *timingStream = [[FPStream alloc] initWithGeneration:YES];
    CVPixelBufferRef pixels = newCardFrame(1);
    FPFrame *first = [FPFrame frame:pixels time:CMTimeMake(0,60)];
    FPFrame *second = [FPFrame frame:pixels time:CMTimeMake(1,60)];
    CVPixelBufferRelease(pixels);
    [timingStream enqueue:first at:1];
    [timingStream enqueue:second at:1+1.0/60];
    if ([timingStream frameDueAt:0.999] != first || [timingStream frameDueAt:1.018] != second) {
        NSLog(@"Display phase jitter skipped a scheduled frame"); return 1;
    }
    [timingStream enqueue:first at:2];
    [timingStream enqueue:second at:2+1.0/60];
    if ([timingStream frameDueAt:2.100] != second) return 1;
    puts("Legacy stream capture check passed: BGRA conversion, 59.94 Hz duplicate transport, generated timestamps, direct playback and discontinuity recovery.");
    return 0;
} }
