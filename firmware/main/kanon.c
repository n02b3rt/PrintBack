#include "kanon.h"

bool kanon_hourly_publishable(int unique_count)
{
    return unique_count >= KANON_MIN_HOURLY_COUNT;
}
