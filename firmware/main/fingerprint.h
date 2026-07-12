#pragma once

#include <stdint.h>
#include <stddef.h>

#define FINGERPRINT_HASH_BYTES 8
#define FINGERPRINT_HEX_LEN    (FINGERPRINT_HASH_BYTES * 2 + 1)
#define FINGERPRINT_SALT_BYTES 16

typedef struct {
    uint8_t  hash[FINGERPRINT_HASH_BYTES];
    char     hex[FINGERPRINT_HEX_LEN];
    uint8_t  ie_count;
    uint16_t payload_len;
} fingerprint_t;

/* Sets a per-device secret salt mixed into every fingerprint hash before
 * the IE bytes. With a random 16-byte salt (generated once per device and
 * kept in NVS), the same phone produces a DIFFERENT hash on each physical
 * unit - so a fingerprint captured on one device can't be correlated with
 * the same phone seen by another device (docs/compliance/README.md). Call
 * once at boot before any fingerprint_from_ies(). `len` is clamped to
 * FINGERPRINT_SALT_BYTES. */
void fingerprint_set_salt(const uint8_t *salt, size_t len);

/* Build a stable fingerprint from the Information Elements of a probe
 * request frame body. `ie_buf` points at the first IE (after the fixed
 * mgmt header + variable fields). Returns 0 on success. */
int fingerprint_from_ies(const uint8_t *ie_buf, size_t ie_len,
                         fingerprint_t *out);
