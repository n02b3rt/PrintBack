#pragma once

#include <stdint.h>
#include <stddef.h>

#define FINGERPRINT_HASH_BYTES 8
#define FINGERPRINT_HEX_LEN    (FINGERPRINT_HASH_BYTES * 2 + 1)

typedef struct {
    uint8_t  hash[FINGERPRINT_HASH_BYTES];
    char     hex[FINGERPRINT_HEX_LEN];
    uint8_t  ie_count;
    uint16_t payload_len;
} fingerprint_t;

/* Build a stable fingerprint from the Information Elements of a probe
 * request frame body. `ie_buf` points at the first IE (after the fixed
 * mgmt header + variable fields). Returns 0 on success. */
int fingerprint_from_ies(const uint8_t *ie_buf, size_t ie_len,
                         fingerprint_t *out);
