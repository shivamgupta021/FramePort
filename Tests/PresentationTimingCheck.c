#include "../Direct/PresentationTiming.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    FPSourceTiming sum = {0};
    assert(isnan(FPSourceTimingMeanMS(sum).app));
    FPRecordSourceTiming(&sum, 1, 1.021, 1.053, 1.090);
    FPRecordSourceTiming(&sum, 2, 2.023, 2.051, 2.086);
    FPRecordSourceTiming(&sum, NAN, 0, 0, 0);
    FPRecordSourceTiming(&sum, 3, 2, 4, 5);
    FPRecordSourceTiming(&sum, 1, 3, 2, 4);
    FPRecordSourceTiming(&sum, 1, 2, 4, 3);
    FPSourceTiming means = FPSourceTimingMeanMS(sum);
    assert(means.count == 2 && fabs(means.input-22)<1e-8 && fabs(means.app-30)<1e-8 && fabs(means.display-36)<1e-8);
    assert(fabs(means.input + means.app + means.display - 88)<1e-8);
    puts("Two valid real-frame timelines: 22 ms input + 30 ms app + 36 ms display = 88 ms total.");
}
