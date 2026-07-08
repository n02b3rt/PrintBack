#include "runtime_config_parse.h"

#include <stdlib.h>
#include <string.h>

static bool find_int_field(const char *json, const char *key, int *out)
{
    const char *p = strstr(json, key);
    if (!p) return false;

    p = strchr(p + strlen(key), ':');
    if (!p) return false;
    p++;

    char *end;
    long val = strtol(p, &end, 10);
    if (end == p) return false; /* no digits found after ':' */

    *out = (int)val;
    return true;
}

bool runtime_config_extract_json(const char *json, size_t len,
                                  int *rssi_floor_out, int *returning_window_days_out)
{
    if (!json || len == 0) return false;

    if (!find_int_field(json, "\"rssi_floor\"", rssi_floor_out)) return false;
    if (!find_int_field(json, "\"returning_window_days\"", returning_window_days_out)) return false;

    return true;
}

bool runtime_config_validate(int rssi_floor, int returning_window_days)
{
    if (rssi_floor < RUNTIME_CONFIG_RSSI_FLOOR_MIN || rssi_floor > RUNTIME_CONFIG_RSSI_FLOOR_MAX) {
        return false;
    }
    if (returning_window_days < RUNTIME_CONFIG_RETURNING_WINDOW_DAYS_MIN ||
        returning_window_days > RUNTIME_CONFIG_RETURNING_WINDOW_DAYS_MAX) {
        return false;
    }
    return true;
}
