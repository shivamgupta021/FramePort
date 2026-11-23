#import "Cadence.h"
#include <math.h>
#include <string.h>

// Compare active samples only. MJPEG capture can change individual pixel values
// between two deliveries of the same HDMI image. Local means damp that noise.
FPImageChange FPCompareFrames(CVPixelBufferRef a, CVPixelBufferRef b) {
    FPImageChange unknown = {INFINITY, 1, NO, NO};
    if (CVPixelBufferGetWidth(a)!=CVPixelBufferGetWidth(b) || CVPixelBufferGetHeight(a)!=CVPixelBufferGetHeight(b) ||
        CVPixelBufferGetPixelFormatType(a)!=CVPixelBufferGetPixelFormatType(b)) return unknown;
    if (a==b) return (FPImageChange){0,0,YES,YES};
    if (CVPixelBufferLockBaseAddress(a,kCVPixelBufferLock_ReadOnly)) return unknown;
    if (CVPixelBufferLockBaseAddress(b,kCVPixelBufferLock_ReadOnly)) {
        CVPixelBufferUnlockBaseAddress(a,kCVPixelBufferLock_ReadOnly); return unknown;
    }
    OSType type=CVPixelBufferGetPixelFormatType(a);
    BOOL nv12=type==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || type==kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    FPImageChange result = unknown;
    size_t width=CVPixelBufferGetWidth(a), height=CVPixelBufferGetHeight(a);
    if (nv12) {
        uint64_t residual=0, changed=0, samples=0;
        BOOL identical=YES;
        for (int plane=0;plane<2;plane++) {
            const uint8_t *left=CVPixelBufferGetBaseAddressOfPlane(a,plane), *right=CVPixelBufferGetBaseAddressOfPlane(b,plane);
            size_t sa=CVPixelBufferGetBytesPerRowOfPlane(a,plane), sb=CVPixelBufferGetBytesPerRowOfPlane(b,plane);
            size_t h=CVPixelBufferGetHeightOfPlane(a,plane);
            // Keep U and V independent, to detect color-only HUD changes.
            int channels=plane ? 2:1;
            for (size_t y=0;y+3<h;y+=4) for (size_t x=0;x+4*channels<=width;x+=4*channels) {
                for(int channel=0;channel<channels;channel++) {
                    int sum=0;
                    for(int j=0;j<4;j++) {
                        const uint8_t *l=left+(y+j)*sa+x+channel,*r=right+(y+j)*sb+x+channel;
                        for(int i=0;i<4;i++) {int delta=l[i*channels]-r[i*channels];sum+=delta;identical &= delta==0;}
                    }
                    unsigned magnitude=abs(sum);
                    residual+=magnitude; changed+=magnitude>4*16; samples++;
                }
            }
        }
        if (samples) result=(FPImageChange){(double)residual/(samples*16),(double)changed/samples,identical,YES};
    } else {
        int bytes=type==kCVPixelFormatType_32BGRA ? 4 :
            (type==kCVPixelFormatType_422YpCbCr8 || type==kCVPixelFormatType_422YpCbCr8_yuvs ? 2:0);
        if(bytes) {
            const uint8_t *l=CVPixelBufferGetBaseAddress(a),*r=CVPixelBufferGetBaseAddress(b);
            BOOL equal=YES;
            for(size_t y=0;y<height && equal;y++)
                equal=memcmp(l+y*CVPixelBufferGetBytesPerRow(a),r+y*CVPixelBufferGetBytesPerRow(b),width*bytes)==0;
            result=(FPImageChange){equal?0:1,equal?0:1,equal,NO};
        }
    }
    CVPixelBufferUnlockBaseAddress(b,kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(a,kCVPixelBufferLock_ReadOnly);
    return result;
}

BOOL FPLikelyRepeatedSlot(FPImageChange before, FPImageChange after) {
    if (after.identical || !isfinite(after.mean)) return NO;
    if (before.identical) return YES;
    return before.hasLuma && before.mean<0.6 && before.changedFraction<0.001 &&
        after.mean>fmax(0.12,before.mean*2.2) && after.changedFraction>before.changedFraction*3;
}
