#include "fingerprint.h"

#include <string.h>
#include "mbedtls/sha256.h"

/* IEs that vary per-probe or per-network and must be excluded so the
 * fingerprint stays stable across SSID scans and random-MAC rotations. */
static bool ie_is_volatile(uint8_t tag)
{
    switch (tag) {
        case 0:    /* SSID */
        case 3:    /* DS Parameter Set (channel) */
        case 7:    /* Country */
        case 11:   /* QBSS Load */
        case 221:  /* Vendor Specific — handled separately */
            return true;
        default:
            return false;
    }
}

static void hex_encode(const uint8_t *in, size_t n, char *out)
{
    static const char hex[] = "0123456789abcdef";
    for (size_t i = 0; i < n; i++) {
        out[i * 2]     = hex[in[i] >> 4];
        out[i * 2 + 1] = hex[in[i] & 0x0f];
    }
    out[n * 2] = '\0';
}

int fingerprint_from_ies(const uint8_t *ie_buf, size_t ie_len,
                         fingerprint_t *out)
{
    if (!ie_buf || !out) return -1;

    mbedtls_sha256_context ctx;
    mbedtls_sha256_init(&ctx);
    mbedtls_sha256_starts(&ctx, 0);

    size_t off = 0;
    uint8_t count = 0;

    while (off + 2 <= ie_len) {
        uint8_t tag = ie_buf[off];
        uint8_t len = ie_buf[off + 1];
        if (off + 2 + len > ie_len) break;

        const uint8_t *val = &ie_buf[off + 2];

        if (!ie_is_volatile(tag)) {
            mbedtls_sha256_update(&ctx, &tag, 1);
            mbedtls_sha256_update(&ctx, &len, 1);
            mbedtls_sha256_update(&ctx, val, len);
            count++;
        } else if (tag == 221 && len >= 3) {
            /* Hash only the OUI of vendor-specific IEs — the payload
             * often carries WPS UUIDs and other per-device randoms. */
            mbedtls_sha256_update(&ctx, &tag, 1);
            mbedtls_sha256_update(&ctx, val, 3);
            count++;
        }

        off += 2 + len;
    }

    uint8_t digest[32];
    mbedtls_sha256_finish(&ctx, digest);
    mbedtls_sha256_free(&ctx);

    memcpy(out->hash, digest, FINGERPRINT_HASH_BYTES);
    hex_encode(out->hash, FINGERPRINT_HASH_BYTES, out->hex);
    out->ie_count    = count;
    out->payload_len = (uint16_t)ie_len;
    return 0;
}
