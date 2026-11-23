#import "Video.h"
#include <stdio.h>

// The background pans right, the foreground moves left, and the HUD stays fixed.
// Render all three instants directly so the middle image is an independent reference.
static FPFrame *scene(int index, int speed) {
    const int width=960,height=540;
    NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
    CVPixelBufferRef pixels=NULL;
    if (CVPixelBufferCreate(NULL,width,height,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            (__bridge CFDictionaryRef)attrs,&pixels)) return nil;
    CVPixelBufferLockBaseAddress(pixels,0);
    int left=340-8*index;
    for(int y=0;y<height;y++) {
        uint8_t *row=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixels,0)+y*CVPixelBufferGetBytesPerRowOfPlane(pixels,0);
        for(int x=0;x<width;x++) {
            int world=(x+width-index*speed)%width;
            row[x]=45+((world/13+3*(y/9))%5)*15+((world*31u+y*17u)^(world*y*7u))%28;
            if(x>=left && x<left+180 && y>=190 && y<350) row[x]=190+((x-left)/5+y/4)%20;
            if(x>=285 && x<370 && y>=255 && y<259) row[x]=224;
        }
    }
    memset(CVPixelBufferGetBaseAddressOfPlane(pixels,1),128,CVPixelBufferGetBytesPerRowOfPlane(pixels,1)*height/2);
    CVPixelBufferUnlockBaseAddress(pixels,0);
    FPFrame *frame=[FPFrame frame:pixels time:CMTimeMake(index,60)]; CVPixelBufferRelease(pixels);
    return frame;
}

int main(void) { @autoreleasepool {
    NSError *error=nil;
    FPInterpolator *engine=[[FPInterpolator alloc] initWithWidth:960 height:540 engine:FPGenerationMetalNative error:&error];
    if (!engine) { NSLog(@"%@",error); return 1; }
    double generatedError=0,blendError=0,holdError=0;
    unsigned count=0;
    for(int speed=4;speed<=32;speed*=2) { @autoreleasepool {
        FPFrame *a=scene(0,speed), *truth=scene(1,speed), *b=scene(2,speed);
        FPFrame *mid=[engine midpointFrom:a to:b error:&error];
        if(!mid) { NSLog(@"%@",error);return 1; }
        NSArray<FPFrame *> *frames=@[a,b,truth,mid];
        for(FPFrame *f in frames) CVPixelBufferLockBaseAddress(f.pixels,kCVPixelBufferLock_ReadOnly);
        for(int y=174;y<366;y++){
            const uint8_t *rows[4];
            for(int i=0;i<4;i++) rows[i]=(uint8_t*)CVPixelBufferGetBaseAddressOfPlane(frames[i].pixels,0)+y*CVPixelBufferGetBytesPerRowOfPlane(frames[i].pixels,0);
            for(int x=316;x<528;x++){
                if(y>=206 && y<334 && x>=348 && x<496 && (y<250 || y>264))continue;
                generatedError+=abs(rows[3][x]-rows[2][x]);
                blendError+=fabs(0.5*(rows[0][x]+rows[1][x])-rows[2][x]);
                holdError+=abs(rows[0][x]-rows[2][x]);count++;
            }
        }
        for(FPFrame *f in frames) CVPixelBufferUnlockBaseAddress(f.pixels,kCVPixelBufferLock_ReadOnly);
    }}
    printf("Held-out contour/HUD luma error: generated %.2f, blend %.2f, hold %.2f\n",generatedError/count,blendError/count,holdError/count);
    return generatedError < blendError && generatedError < holdError ? 0:1;
}}
