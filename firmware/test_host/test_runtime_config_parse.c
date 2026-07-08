#include <stdio.h>
#include "runtime_config_parse.h"

static int failures = 0;

#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s\n", msg); failures++; } \
    else { printf("ok: %s\n", msg); } \
} while (0)

int main(void)
{
    int rssi, days;

    /* extraction: normal order, matches docs/DATA_MODEL.md CONFIG payload */
    CHECK(runtime_config_extract_json(
              "{\"rssi_floor\":-85,\"returning_window_days\":30}", 46, &rssi, &days) == true,
          "extract: normal order");
    CHECK(rssi == -85, "extract: rssi_floor value");
    CHECK(days == 30, "extract: returning_window_days value");

    /* extraction: reversed key order, whitespace after colons - a
     * reformatting client shouldn't break this */
    CHECK(runtime_config_extract_json(
              "{\"returning_window_days\": 14, \"rssi_floor\": -70}", 48, &rssi, &days) == true,
          "extract: reversed order with spaces");
    CHECK(rssi == -70, "extract: rssi_floor value (reversed)");
    CHECK(days == 14, "extract: returning_window_days value (reversed)");

    /* extraction failures */
    CHECK(runtime_config_extract_json("{\"rssi_floor\":-85}", 18, &rssi, &days) == false,
          "extract: missing returning_window_days fails");
    CHECK(runtime_config_extract_json("{\"returning_window_days\":30}", 28, &rssi, &days) == false,
          "extract: missing rssi_floor fails");
    CHECK(runtime_config_extract_json("not json at all", 15, &rssi, &days) == false,
          "extract: garbage input fails");
    CHECK(runtime_config_extract_json("", 0, &rssi, &days) == false,
          "extract: empty input fails");
    CHECK(runtime_config_extract_json("{\"rssi_floor\":abc,\"returning_window_days\":30}", 46,
                                       &rssi, &days) == false,
          "extract: non-numeric rssi_floor value fails");

    /* validation: in-range */
    CHECK(runtime_config_validate(-85, 30) == true,  "validate: production defaults");
    CHECK(runtime_config_validate(-100, 1) == true,  "validate: at minimums");
    CHECK(runtime_config_validate(-20, 90) == true,  "validate: at maximums");

    /* validation: out of range */
    CHECK(runtime_config_validate(-101, 30) == false, "validate: rssi_floor below min");
    CHECK(runtime_config_validate(-19, 30)  == false, "validate: rssi_floor above max");
    CHECK(runtime_config_validate(-85, 0)   == false, "validate: returning_window_days below min");
    CHECK(runtime_config_validate(-85, 91)  == false, "validate: returning_window_days above max");

    if (failures) {
        printf("%d test(s) FAILED\n", failures);
        return 1;
    }
    printf("all tests passed\n");
    return 0;
}
