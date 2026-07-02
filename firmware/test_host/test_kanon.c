#include <stdio.h>
#include "kanon.h"

static int failures = 0;

#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s\n", msg); failures++; } \
    else { printf("ok: %s\n", msg); } \
} while (0)

int main(void)
{
    CHECK(kanon_hourly_publishable(5)   == true,  "5 events: at threshold, publishable");
    CHECK(kanon_hourly_publishable(4)   == false, "4 events: below threshold, collapse to daily");
    CHECK(kanon_hourly_publishable(0)   == false, "0 events: below threshold");
    CHECK(kanon_hourly_publishable(100) == true,  "100 events: publishable");

    if (failures) {
        printf("%d test(s) FAILED\n", failures);
        return 1;
    }
    printf("all tests passed\n");
    return 0;
}
