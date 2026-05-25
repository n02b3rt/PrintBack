#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "fingerprint.h"

#define WHITELIST_MAX 128

void     whitelist_init(void);
bool     whitelist_contains(const uint8_t *fp);
bool     whitelist_add(const uint8_t *fp);
bool     whitelist_remove(const uint8_t *fp);
void     whitelist_clear(void);
uint16_t whitelist_count(void);
