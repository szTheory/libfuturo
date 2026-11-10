/*
 * Original LibFuturo implementation of SHA-256 as specified by NIST FIPS
 * 180-4. No third-party implementation code is copied into this file.
 * Distributed under the project Apache-2.0 license; see LICENSE.
 */
#include "sha256.h"

#include <string.h>

static const uint32_t k_round_constants[64] = {
    UINT32_C(0x428a2f98), UINT32_C(0x71374491), UINT32_C(0xb5c0fbcf),
    UINT32_C(0xe9b5dba5), UINT32_C(0x3956c25b), UINT32_C(0x59f111f1),
    UINT32_C(0x923f82a4), UINT32_C(0xab1c5ed5), UINT32_C(0xd807aa98),
    UINT32_C(0x12835b01), UINT32_C(0x243185be), UINT32_C(0x550c7dc3),
    UINT32_C(0x72be5d74), UINT32_C(0x80deb1fe), UINT32_C(0x9bdc06a7),
    UINT32_C(0xc19bf174), UINT32_C(0xe49b69c1), UINT32_C(0xefbe4786),
    UINT32_C(0x0fc19dc6), UINT32_C(0x240ca1cc), UINT32_C(0x2de92c6f),
    UINT32_C(0x4a7484aa), UINT32_C(0x5cb0a9dc), UINT32_C(0x76f988da),
    UINT32_C(0x983e5152), UINT32_C(0xa831c66d), UINT32_C(0xb00327c8),
    UINT32_C(0xbf597fc7), UINT32_C(0xc6e00bf3), UINT32_C(0xd5a79147),
    UINT32_C(0x06ca6351), UINT32_C(0x14292967), UINT32_C(0x27b70a85),
    UINT32_C(0x2e1b2138), UINT32_C(0x4d2c6dfc), UINT32_C(0x53380d13),
    UINT32_C(0x650a7354), UINT32_C(0x766a0abb), UINT32_C(0x81c2c92e),
    UINT32_C(0x92722c85), UINT32_C(0xa2bfe8a1), UINT32_C(0xa81a664b),
    UINT32_C(0xc24b8b70), UINT32_C(0xc76c51a3), UINT32_C(0xd192e819),
    UINT32_C(0xd6990624), UINT32_C(0xf40e3585), UINT32_C(0x106aa070),
    UINT32_C(0x19a4c116), UINT32_C(0x1e376c08), UINT32_C(0x2748774c),
    UINT32_C(0x34b0bcb5), UINT32_C(0x391c0cb3), UINT32_C(0x4ed8aa4a),
    UINT32_C(0x5b9cca4f), UINT32_C(0x682e6ff3), UINT32_C(0x748f82ee),
    UINT32_C(0x78a5636f), UINT32_C(0x84c87814), UINT32_C(0x8cc70208),
    UINT32_C(0x90befffa), UINT32_C(0xa4506ceb), UINT32_C(0xbef9a3f7),
    UINT32_C(0xc67178f2)};

static uint32_t rotate_right(uint32_t value, unsigned int amount) {
  return (value >> amount) | (value << (32U - amount));
}

static uint32_t read_be32(const uint8_t *bytes) {
  return ((uint32_t)bytes[0] << 24U) | ((uint32_t)bytes[1] << 16U) |
         ((uint32_t)bytes[2] << 8U) | (uint32_t)bytes[3];
}

static void write_be32(uint8_t *bytes, uint32_t value) {
  bytes[0] = (uint8_t)(value >> 24U);
  bytes[1] = (uint8_t)(value >> 16U);
  bytes[2] = (uint8_t)(value >> 8U);
  bytes[3] = (uint8_t)value;
}

static void transform(uint32_t state[8], const uint8_t block[64]) {
  uint32_t words[64];
  uint32_t a = state[0];
  uint32_t b = state[1];
  uint32_t c = state[2];
  uint32_t d = state[3];
  uint32_t e = state[4];
  uint32_t f = state[5];
  uint32_t g = state[6];
  uint32_t h = state[7];
  size_t index = 0U;

  for (index = 0U; index < 16U; ++index) {
    words[index] = read_be32(block + index * 4U);
  }
  for (index = 16U; index < 64U; ++index) {
    const uint32_t x = words[index - 15U];
    const uint32_t y = words[index - 2U];
    const uint32_t sigma0 = rotate_right(x, 7U) ^ rotate_right(x, 18U) ^
                            (x >> 3U);
    const uint32_t sigma1 = rotate_right(y, 17U) ^ rotate_right(y, 19U) ^
                            (y >> 10U);
    words[index] = words[index - 16U] + sigma0 + words[index - 7U] + sigma1;
  }

  for (index = 0U; index < 64U; ++index) {
    const uint32_t sum1 = rotate_right(e, 6U) ^ rotate_right(e, 11U) ^
                          rotate_right(e, 25U);
    const uint32_t choice = (e & f) ^ (~e & g);
    const uint32_t temp1 = h + sum1 + choice + k_round_constants[index] +
                           words[index];
    const uint32_t sum0 = rotate_right(a, 2U) ^ rotate_right(a, 13U) ^
                          rotate_right(a, 22U);
    const uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
    const uint32_t temp2 = sum0 + majority;
    h = g;
    g = f;
    f = e;
    e = d + temp1;
    d = c;
    c = b;
    b = a;
    a = temp1 + temp2;
  }

  state[0] += a;
  state[1] += b;
  state[2] += c;
  state[3] += d;
  state[4] += e;
  state[5] += f;
  state[6] += g;
  state[7] += h;
}

int lf_sha256_bytes(const uint8_t *data, size_t extent_bytes,
                    uint8_t digest[32]) {
  uint32_t state[8] = {UINT32_C(0x6a09e667), UINT32_C(0xbb67ae85),
                       UINT32_C(0x3c6ef372), UINT32_C(0xa54ff53a),
                       UINT32_C(0x510e527f), UINT32_C(0x9b05688c),
                       UINT32_C(0x1f83d9ab), UINT32_C(0x5be0cd19)};
  uint8_t final_blocks[128] = {0U};
  uint64_t bit_count = 0U;
  size_t offset = 0U;
  size_t remainder = 0U;
  size_t final_offset = 0U;
  size_t index = 0U;

  if (digest == NULL || (extent_bytes != 0U && data == NULL)) {
    return 0;
  }
#if SIZE_MAX > UINT64_MAX
  if (extent_bytes > (size_t)(UINT64_MAX / UINT64_C(8))) {
    return 0;
  }
#endif
  bit_count = (uint64_t)extent_bytes * UINT64_C(8);
  while (extent_bytes - offset >= 64U) {
    transform(state, data + offset);
    offset += 64U;
  }

  remainder = extent_bytes - offset;
  if (remainder != 0U) {
    memcpy(final_blocks, data + offset, remainder);
  }
  final_blocks[remainder] = 0x80U;
  if (remainder >= 56U) {
    transform(state, final_blocks);
    memset(final_blocks, 0, 64U);
    final_offset = 64U;
  }
  for (index = 0U; index < 8U; ++index) {
    final_blocks[final_offset + 63U - index] =
        (uint8_t)(bit_count >> (index * 8U));
  }
  transform(state, final_blocks + final_offset);

  for (index = 0U; index < 8U; ++index) {
    write_be32(digest + index * 4U, state[index]);
  }
  memset(state, 0, sizeof(state));
  memset(final_blocks, 0, sizeof(final_blocks));
  return 1;
}
