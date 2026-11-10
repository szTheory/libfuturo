#ifndef LIBFUTURO_TESTS_INSTALLED_CONSUMER_MUHTARI_ORACLE_H
#define LIBFUTURO_TESTS_INSTALLED_CONSUMER_MUHTARI_ORACLE_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define LF_MUHTARI_ORACLE_FIRST_FRAME_SAMPLES 54U
#define LF_MUHTARI_ORACLE_STEADY_FRAME_SAMPLES 801U
#define LF_MUHTARI_ORACLE_FIRST_BACKGROUND_ROW 224U
#define LF_MUHTARI_ORACLE_FIRST_CHANGED_PIXEL 64U
#define LF_MUHTARI_ORACLE_PORT0_FIRE_COLOR UINT8_C(0x11)
#define LF_MUHTARI_ORACLE_PORT1_FIRE_COLOR UINT8_C(0x22)
#define LF_MUHTARI_ORACLE_RELEASED_COLOR UINT8_C(0x33)
#define LF_MUHTARI_ORACLE_BOTH_FIRE_COLOR UINT8_C(0x44)
#define LF_MUHTARI_ORACLE_PORT0_UP_COLOR UINT8_C(0x51)
#define LF_MUHTARI_ORACLE_PORT0_DOWN_COLOR UINT8_C(0x52)
#define LF_MUHTARI_ORACLE_PORT0_LEFT_COLOR UINT8_C(0x53)
#define LF_MUHTARI_ORACLE_PORT0_RIGHT_COLOR UINT8_C(0x54)
#define LF_MUHTARI_ORACLE_PORT1_UP_COLOR UINT8_C(0x61)
#define LF_MUHTARI_ORACLE_PORT1_DOWN_COLOR UINT8_C(0x62)
#define LF_MUHTARI_ORACLE_PORT1_LEFT_COLOR UINT8_C(0x63)
#define LF_MUHTARI_ORACLE_PORT1_RIGHT_COLOR UINT8_C(0x64)
#define LF_MUHTARI_ORACLE_FRAME_COUNT 15U

static const size_t lf_muhtari_oracle_sample_counts[LF_MUHTARI_ORACLE_FRAME_COUNT] = {
    54U, 801U, 801U, 800U, 801U, 800U, 801U, 800U, 801U, 800U,
    801U, 801U, 800U, 801U, 800U};

static const char *const
    lf_muhtari_oracle_pcm_sha256[LF_MUHTARI_ORACLE_FRAME_COUNT] = {
        "fb41844364ec4a777d23f430416dd2ad5d8d4140824e9e56b96ded43b830854b",
        "2c8ebfc099b8c89d6b332be438b0efe5a72a957582ffa273baf3f6b1de1e829e",
        "e9962af07750cf89fb391c0f614b93ddca864654888f82fd02795ea789039b12",
        "7255cb571bc7b274ddbef84838114400ceaaaac76ab7e5fd1292bcb214d89b70",
        "980e16f8e70303f99f8388261bfac745ced5321ccec02eef7823463f418a41aa",
        "955707f0202495f2fa2871625734acc613efd79c322d04c86c82595642de72a8",
        "93a0be09e4e0af765777cc06a2df09f3827471db9b18d10a792507842539b9fb",
        "9a6e602bb2e65dec142e1ef47e9ef8a26ea51a3f2541b9e8cac45825f52f1757",
        "bdf01306accb602ee8f51b96b513185efddcd6a65156aca3af621ea4651802ab",
        "57ed718ffd46bea2ca6fa6dfdec9e2a7df4bf48cdaa64d3f12bf7c2a1f445fd6",
        "e08ab2af6be4c450c54155a208e2611e5c393ab946b5c3f90d13e17735956ed3",
        "b72f89b6dd668fb490cb8fbdbff149b5fc13da51fba5f691f7bc3bf2c0c24319",
        "a78f073437b866b8780d068585705e63eed97fac21a1334d8eba2bae22c95af1",
        "9790aedf8a6eb74929a0cf31710aa7ac2715737f2e455bd4283aae6879a979d0",
        "25878cf4f2a29d87440e3889536591e21b28669f654b06920983ee36797a0220"};

typedef struct lf_muhtari_oracle_sha256 {
  uint32_t state[8];
  uint64_t bit_count;
  uint8_t block[64];
  size_t block_size;
} lf_muhtari_oracle_sha256;

static const uint32_t lf_muhtari_oracle_sha256_round_constants[64] = {
    UINT32_C(0x428A2F98), UINT32_C(0x71374491), UINT32_C(0xB5C0FBCF),
    UINT32_C(0xE9B5DBA5), UINT32_C(0x3956C25B), UINT32_C(0x59F111F1),
    UINT32_C(0x923F82A4), UINT32_C(0xAB1C5ED5), UINT32_C(0xD807AA98),
    UINT32_C(0x12835B01), UINT32_C(0x243185BE), UINT32_C(0x550C7DC3),
    UINT32_C(0x72BE5D74), UINT32_C(0x80DEB1FE), UINT32_C(0x9BDC06A7),
    UINT32_C(0xC19BF174), UINT32_C(0xE49B69C1), UINT32_C(0xEFBE4786),
    UINT32_C(0x0FC19DC6), UINT32_C(0x240CA1CC), UINT32_C(0x2DE92C6F),
    UINT32_C(0x4A7484AA), UINT32_C(0x5CB0A9DC), UINT32_C(0x76F988DA),
    UINT32_C(0x983E5152), UINT32_C(0xA831C66D), UINT32_C(0xB00327C8),
    UINT32_C(0xBF597FC7), UINT32_C(0xC6E00BF3), UINT32_C(0xD5A79147),
    UINT32_C(0x06CA6351), UINT32_C(0x14292967), UINT32_C(0x27B70A85),
    UINT32_C(0x2E1B2138), UINT32_C(0x4D2C6DFC), UINT32_C(0x53380D13),
    UINT32_C(0x650A7354), UINT32_C(0x766A0ABB), UINT32_C(0x81C2C92E),
    UINT32_C(0x92722C85), UINT32_C(0xA2BFE8A1), UINT32_C(0xA81A664B),
    UINT32_C(0xC24B8B70), UINT32_C(0xC76C51A3), UINT32_C(0xD192E819),
    UINT32_C(0xD6990624), UINT32_C(0xF40E3585), UINT32_C(0x106AA070),
    UINT32_C(0x19A4C116), UINT32_C(0x1E376C08), UINT32_C(0x2748774C),
    UINT32_C(0x34B0BCB5), UINT32_C(0x391C0CB3), UINT32_C(0x4ED8AA4A),
    UINT32_C(0x5B9CCA4F), UINT32_C(0x682E6FF3), UINT32_C(0x748F82EE),
    UINT32_C(0x78A5636F), UINT32_C(0x84C87814), UINT32_C(0x8CC70208),
    UINT32_C(0x90BEFFFA), UINT32_C(0xA4506CEB), UINT32_C(0xBEF9A3F7),
    UINT32_C(0xC67178F2)};

static inline uint32_t lf_muhtari_oracle_rotr(uint32_t value,
                                              unsigned amount) {
  return (value >> amount) | (value << (32U - amount));
}

static inline uint32_t lf_muhtari_oracle_load_be32(const uint8_t *bytes) {
  return ((uint32_t)bytes[0] << 24U) | ((uint32_t)bytes[1] << 16U) |
         ((uint32_t)bytes[2] << 8U) | (uint32_t)bytes[3];
}

static inline void lf_muhtari_oracle_sha256_transform(
    lf_muhtari_oracle_sha256 *context) {
  uint32_t words[64];
  uint32_t a = context->state[0];
  uint32_t b = context->state[1];
  uint32_t c = context->state[2];
  uint32_t d = context->state[3];
  uint32_t e = context->state[4];
  uint32_t f = context->state[5];
  uint32_t g = context->state[6];
  uint32_t h = context->state[7];
  for (size_t index = 0U; index < 16U; ++index) {
    words[index] = lf_muhtari_oracle_load_be32(context->block + index * 4U);
  }
  for (size_t index = 16U; index < 64U; ++index) {
    const uint32_t x = words[index - 15U];
    const uint32_t y = words[index - 2U];
    const uint32_t sigma0 = lf_muhtari_oracle_rotr(x, 7U) ^
                            lf_muhtari_oracle_rotr(x, 18U) ^ (x >> 3U);
    const uint32_t sigma1 = lf_muhtari_oracle_rotr(y, 17U) ^
                            lf_muhtari_oracle_rotr(y, 19U) ^ (y >> 10U);
    words[index] = words[index - 16U] + sigma0 + words[index - 7U] + sigma1;
  }
  for (size_t index = 0U; index < 64U; ++index) {
    const uint32_t sum1 = lf_muhtari_oracle_rotr(e, 6U) ^
                          lf_muhtari_oracle_rotr(e, 11U) ^
                          lf_muhtari_oracle_rotr(e, 25U);
    const uint32_t choose = (e & f) ^ (~e & g);
    const uint32_t t1 = h + sum1 + choose +
                        lf_muhtari_oracle_sha256_round_constants[index] +
                        words[index];
    const uint32_t sum0 = lf_muhtari_oracle_rotr(a, 2U) ^
                          lf_muhtari_oracle_rotr(a, 13U) ^
                          lf_muhtari_oracle_rotr(a, 22U);
    const uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
    const uint32_t t2 = sum0 + majority;
    h = g;
    g = f;
    f = e;
    e = d + t1;
    d = c;
    c = b;
    b = a;
    a = t1 + t2;
  }
  context->state[0] += a;
  context->state[1] += b;
  context->state[2] += c;
  context->state[3] += d;
  context->state[4] += e;
  context->state[5] += f;
  context->state[6] += g;
  context->state[7] += h;
}

static inline void lf_muhtari_oracle_sha256_init(
    lf_muhtari_oracle_sha256 *context) {
  static const uint32_t initial[8] = {
      UINT32_C(0x6A09E667), UINT32_C(0xBB67AE85), UINT32_C(0x3C6EF372),
      UINT32_C(0xA54FF53A), UINT32_C(0x510E527F), UINT32_C(0x9B05688C),
      UINT32_C(0x1F83D9AB), UINT32_C(0x5BE0CD19)};
  memcpy(context->state, initial, sizeof(initial));
  context->bit_count = 0U;
  context->block_size = 0U;
}

static inline void lf_muhtari_oracle_sha256_update(
    lf_muhtari_oracle_sha256 *context, const uint8_t *bytes, size_t count) {
  for (size_t index = 0U; index < count; ++index) {
    context->block[context->block_size++] = bytes[index];
    context->bit_count += 8U;
    if (context->block_size == sizeof(context->block)) {
      lf_muhtari_oracle_sha256_transform(context);
      context->block_size = 0U;
    }
  }
}

static inline void lf_muhtari_oracle_sha256_finish(
    lf_muhtari_oracle_sha256 *context, uint8_t digest[32]) {
  const uint64_t bit_count = context->bit_count;
  context->block[context->block_size++] = UINT8_C(0x80);
  if (context->block_size > 56U) {
    while (context->block_size < sizeof(context->block)) {
      context->block[context->block_size++] = 0U;
    }
    lf_muhtari_oracle_sha256_transform(context);
    context->block_size = 0U;
  }
  while (context->block_size < 56U) {
    context->block[context->block_size++] = 0U;
  }
  for (size_t index = 0U; index < 8U; ++index) {
    context->block[56U + index] =
        (uint8_t)(bit_count >> (56U - (unsigned)index * 8U));
  }
  lf_muhtari_oracle_sha256_transform(context);
  for (size_t index = 0U; index < 8U; ++index) {
    digest[index * 4U] = (uint8_t)(context->state[index] >> 24U);
    digest[index * 4U + 1U] = (uint8_t)(context->state[index] >> 16U);
    digest[index * 4U + 2U] = (uint8_t)(context->state[index] >> 8U);
    digest[index * 4U + 3U] = (uint8_t)context->state[index];
  }
}

static inline void lf_muhtari_oracle_hex_digest(const uint8_t digest[32],
                                                 char hex[65]) {
  static const char digits[] = "0123456789abcdef";
  for (size_t index = 0U; index < 32U; ++index) {
    hex[index * 2U] = digits[digest[index] >> 4U];
    hex[index * 2U + 1U] = digits[digest[index] & UINT8_C(0x0F)];
  }
  hex[64] = '\0';
}

static inline void lf_muhtari_oracle_pcm_digest(const int16_t *samples,
                                                size_t count,
                                                char hex[65]) {
  lf_muhtari_oracle_sha256 context;
  uint8_t digest[32];
  lf_muhtari_oracle_sha256_init(&context);
  for (size_t index = 0U; index < count; ++index) {
    const uint16_t sample = (uint16_t)samples[index];
    const uint8_t bytes[2] = {(uint8_t)sample, (uint8_t)(sample >> 8U)};
    lf_muhtari_oracle_sha256_update(&context, bytes, sizeof(bytes));
  }
  lf_muhtari_oracle_sha256_finish(&context, digest);
  lf_muhtari_oracle_hex_digest(digest, hex);
}

static inline int lf_muhtari_oracle_sha256_self_check(void) {
  static const uint8_t sample[] = {'a', 'b', 'c'};
  static const char expected[] =
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
  lf_muhtari_oracle_sha256 context;
  uint8_t digest[32];
  char actual[65];
  lf_muhtari_oracle_sha256_init(&context);
  lf_muhtari_oracle_sha256_update(&context, sample, sizeof(sample));
  lf_muhtari_oracle_sha256_finish(&context, digest);
  lf_muhtari_oracle_hex_digest(digest, actual);
  return strcmp(actual, expected) == 0;
}

static inline int lf_muhtari_oracle_pcm_matches(const int16_t *samples,
                                                size_t count,
                                                size_t interval_index,
                                                char actual[65]) {
  if (samples == NULL || interval_index >= LF_MUHTARI_ORACLE_FRAME_COUNT ||
      count != lf_muhtari_oracle_sample_counts[interval_index]) {
    return 0;
  }
  lf_muhtari_oracle_pcm_digest(samples, count, actual);
  return strcmp(actual, lf_muhtari_oracle_pcm_sha256[interval_index]) == 0;
}

/* Independent startup oracle: the 6502 instruction recipe writes $11 to
   BACKGRND at raster 240, tick 198. Pixels 0..63 were already emitted; the
   remaining pixels of row 224 and rows 225..241 use $11. The 8,190-tick
   handoff starts at line 240,t24 and ends at line 258,t42. Rows 0..223 have
   not been scanned since load and are cleared by Muhtari. */
static inline int lf_muhtari_oracle_first_image(const uint8_t *video,
                                                 size_t stride,
                                                 uint8_t color) {
  if (video == NULL || stride < 320U) {
    return 0;
  }
  for (size_t y = 0U; y < LF_MUHTARI_ORACLE_FIRST_BACKGROUND_ROW; ++y) {
    for (size_t x = 0U; x < 320U; ++x) {
      if (video[y * stride + x] != UINT8_C(0x00)) {
        return 0;
      }
    }
  }
  for (size_t x = 0U; x < 320U; ++x) {
    const uint8_t expected =
        x < LF_MUHTARI_ORACLE_FIRST_CHANGED_PIXEL ? UINT8_C(0x00) : color;
    if (video[LF_MUHTARI_ORACLE_FIRST_BACKGROUND_ROW * stride + x] !=
        expected) {
      return 0;
    }
  }
  for (size_t y = LF_MUHTARI_ORACLE_FIRST_BACKGROUND_ROW + 1U; y < 242U;
       ++y) {
    for (size_t x = 0U; x < 320U; ++x) {
      if (video[y * stride + x] != color) {
        return 0;
      }
    }
  }
  return 1;
}

static inline int lf_muhtari_oracle_steady_image(const uint8_t *video,
                                                  size_t stride,
                                                  uint8_t color) {
  if (video == NULL || stride < 320U) {
    return 0;
  }
  for (size_t y = 0U; y < 242U; ++y) {
    for (size_t x = 0U; x < 320U; ++x) {
      if (video[y * stride + x] != color) {
        return 0;
      }
    }
  }
  return 1;
}

static inline int lf_muhtari_oracle_audio_non_silent(const int16_t *audio,
                                                      size_t samples) {
  if (audio == NULL || samples == 0U) {
    return 0;
  }
  for (size_t index = 0U; index < samples; ++index) {
    if (audio[index] != 0) {
      return 1;
    }
  }
  return 0;
}

#endif
