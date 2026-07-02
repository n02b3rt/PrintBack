#pragma once

#include <stdbool.h>

/* Hard rule: hourly aggregates with fewer than
 * this many distinct events must not be published at hourly resolution —
 * collapse them into the daily aggregate instead. */
#define KANON_MIN_HOURLY_COUNT 5

/* Returns true if an hourly aggregate with `unique_count` events may be
 * published as-is. Returns false if it must be folded into the daily
 * aggregate instead (k-anonymity threshold not met). */
bool kanon_hourly_publishable(int unique_count);
