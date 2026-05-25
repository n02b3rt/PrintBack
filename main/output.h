#pragma once

#include <stdbool.h>
#include "wifi_sniffer.h"

void output_emit(const probe_observation_t *obs, bool fresh);
