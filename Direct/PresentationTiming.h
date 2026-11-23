#pragma once
#include <math.h>
#include <stdbool.h>
#include <stddef.h>

// All four timestamps must describe the same source picture on the host clock.
typedef struct {
    size_t count;
    double input, app, display;
} FPSourceTiming;

static inline void FPRecordSourceTiming(FPSourceTiming *sum, double capture, double arrival, double submit, double shown) {
    if (!isfinite(capture) || !isfinite(arrival) || !isfinite(submit) || !isfinite(shown) ||
        capture > arrival || arrival > submit || submit > shown || shown <= 0) return;
    sum->count++;
    sum->input += arrival-capture;
    sum->app += submit-arrival;
    sum->display += shown-submit;
}

static inline FPSourceTiming FPSourceTimingMeanMS(FPSourceTiming sum) {
    double scale = sum.count ? 1000.0/sum.count : NAN;
    return (FPSourceTiming){sum.count,sum.input*scale,sum.app*scale,sum.display*scale};
}
