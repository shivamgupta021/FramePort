#import <CoreVideo/CoreVideo.h>

typedef struct {
    double mean;
    double changedFraction;
    BOOL identical;
    BOOL hasLuma;
} FPImageChange;

FPImageChange FPCompareFrames(CVPixelBufferRef a, CVPixelBufferRef b);
BOOL FPLikelyRepeatedSlot(FPImageChange before, FPImageChange after);
