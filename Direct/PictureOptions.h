#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, FPResizeFilter) {
    FPResizeLanczos,
    FPResizeBilinear
};
typedef struct {
    FPResizeFilter filter;
    double sharpness;
} FPPictureOptions;

static inline FPPictureOptions FPDetailPictureOptions(void) {
    return (FPPictureOptions){FPResizeLanczos, 0.15};
}
