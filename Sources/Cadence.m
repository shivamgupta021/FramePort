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
        const uint8_t *left[2], *right[2];
        size_t leftStride[2], rightStride[2], rows[2];
        BOOL readable = width > 0 && height > 0 && !(width % 2) && !(height % 2) &&
            CVPixelBufferGetPlaneCount(a) == 2 && CVPixelBufferGetPlaneCount(b) == 2;
        BOOL identical = readable;
        for (size_t plane=0; plane<2 && readable; plane++) {
            const size_t planeWidth = plane ? width / 2 : width;
            rows[plane] = plane ? height / 2 : height;
            left[plane] = CVPixelBufferGetBaseAddressOfPlane(a,plane);
            right[plane] = CVPixelBufferGetBaseAddressOfPlane(b,plane);
            leftStride[plane] = CVPixelBufferGetBytesPerRowOfPlane(a,plane);
            rightStride[plane] = CVPixelBufferGetBytesPerRowOfPlane(b,plane);
            readable = left[plane] && right[plane] && leftStride[plane] >= width && rightStride[plane] >= width &&
                CVPixelBufferGetWidthOfPlane(a,plane) == planeWidth && CVPixelBufferGetWidthOfPlane(b,plane) == planeWidth &&
                CVPixelBufferGetHeightOfPlane(a,plane) == rows[plane] && CVPixelBufferGetHeightOfPlane(b,plane) == rows[plane] &&
                leftStride[plane] <= SIZE_MAX / rows[plane] && rightStride[plane] <= SIZE_MAX / rows[plane];
            for (size_t y=0; readable && identical && y<rows[plane]; y++)
                identical = memcmp(left[plane]+y*leftStride[plane],right[plane]+y*rightStride[plane],width)==0;
        }
        if (readable && identical) {
            result = (FPImageChange){0,0,YES,YES};
        } else if (readable) {
            uint64_t residual=0, changed=0, samples=0;
            for (size_t plane=0; plane<2; plane++) {
                const size_t channels=plane ? 2 : 1;
                for (size_t y=0;y+3<rows[plane];y+=4) for (size_t x=0;x+4*channels<=width;x+=4*channels) {
                    for(size_t channel=0;channel<channels;channel++) {
                        int sum=0;
                        for(size_t j=0;j<4;j++) {
                            const uint8_t *l=left[plane]+(y+j)*leftStride[plane]+x+channel;
                            const uint8_t *r=right[plane]+(y+j)*rightStride[plane]+x+channel;
                            for(size_t i=0;i<4;i++) sum+=l[i*channels]-r[i*channels];
                        }
                        unsigned magnitude=abs(sum);
                        residual+=magnitude; changed+=magnitude>4*16; samples++;
                    }
                }
            }
            if (samples) result=(FPImageChange){(double)residual/(samples*16),(double)changed/samples,NO,YES};
        }
    } else {
        int bytes=type==kCVPixelFormatType_32BGRA ? 4 :
            (type==kCVPixelFormatType_422YpCbCr8 || type==kCVPixelFormatType_422YpCbCr8_yuvs ? 2:0);
        if (bytes && width <= SIZE_MAX / bytes) {
            const uint8_t *l=CVPixelBufferGetBaseAddress(a),*r=CVPixelBufferGetBaseAddress(b);
            size_t sa=CVPixelBufferGetBytesPerRow(a), sb=CVPixelBufferGetBytesPerRow(b);
            if (l && r && height && sa >= width*bytes && sb >= width*bytes &&
                sa <= SIZE_MAX/height && sb <= SIZE_MAX/height) {
                BOOL equal=YES;
                for(size_t y=0;y<height && equal;y++)
                    equal=memcmp(l+y*sa,r+y*sb,width*bytes)==0;
                result=(FPImageChange){equal?0:1,equal?0:1,equal,NO};
            }
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
