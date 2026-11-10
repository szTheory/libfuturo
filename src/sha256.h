#ifndef LIBFUTURO_SHA256_H
#define LIBFUTURO_SHA256_H

#include <stddef.h>
#include <stdint.h>

/* Computes the FIPS 180-4 SHA-256 digest of a byte span. */
int lf_sha256_bytes(const uint8_t *data, size_t extent_bytes,
                    uint8_t digest[32]);

#endif
