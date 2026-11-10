#ifndef LIBFUTURO_TESTS_NESTURBATOR_SAVE_FIXTURE_H
#define LIBFUTURO_TESTS_NESTURBATOR_SAVE_FIXTURE_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define LF_NESTURBATOR_SAVE_FIXTURE_PRG_BANKS 2U
#define LF_NESTURBATOR_SAVE_FIXTURE_CHR_BANKS 1U
#define LF_NESTURBATOR_SAVE_FIXTURE_HEADER_BYTES 16U
#define LF_NESTURBATOR_SAVE_FIXTURE_PRG_BYTES (32U * 1024U)
#define LF_NESTURBATOR_SAVE_FIXTURE_CHR_BYTES (8U * 1024U)
#define LF_NESTURBATOR_SAVE_FIXTURE_TOTAL_BYTES \
  (LF_NESTURBATOR_SAVE_FIXTURE_HEADER_BYTES + \
   LF_NESTURBATOR_SAVE_FIXTURE_PRG_BYTES + \
   LF_NESTURBATOR_SAVE_FIXTURE_CHR_BYTES)
#define LF_NESTURBATOR_SAVE_FIXTURE_ADC_OPCODE_OFFSET 19U
#define LF_NESTURBATOR_SAVE_FIXTURE_ADC_OPERAND_OFFSET 20U

static const uint8_t lf_nesturbator_save_fixture_program[] = {
    0x78U,                   /* SEI */
    0xD8U,                   /* CLD */
    0xA9U, 0x00U,             /* LDA #$00 */
    0x8DU, 0x00U, 0x20U,      /* STA $2000: disable NMI */
    0x8DU, 0x01U, 0x20U,      /* STA $2001: disable rendering */
    0xADU, 0x02U, 0x20U,      /* wait: LDA $2002 */
    0x10U, 0xFBU,             /* BPL wait */
    0xADU, 0x00U, 0x60U,      /* LDA $6000 */
    0x18U,                   /* CLC */
    0x69U, 0x01U,             /* ADC #$01 */
    0x8DU, 0x00U, 0x60U,      /* STA $6000: guest changes battery RAM */
    0x4CU, 0x0AU, 0x80U       /* JMP wait */
};

/* Original project-authored iNES 1 MMC1 image. All content bytes are built
   from these declared inputs; no upstream test helper or binary is embedded. */
static inline size_t lf_build_nesturbator_save_fixture(uint8_t *destination,
                                                        size_t capacity) {
  static const uint16_t reset_vector = UINT16_C(0x8000);
  const size_t header_bytes = (size_t)LF_NESTURBATOR_SAVE_FIXTURE_HEADER_BYTES;
  const size_t prg_bytes = (size_t)LF_NESTURBATOR_SAVE_FIXTURE_PRG_BYTES;
  const size_t total_bytes =
      (size_t)LF_NESTURBATOR_SAVE_FIXTURE_TOTAL_BYTES;
  const size_t vector_offset = prg_bytes - 6U;
  size_t vector_index = 0U;
  if (destination == NULL || capacity < total_bytes ||
      sizeof(lf_nesturbator_save_fixture_program) > prg_bytes) {
    return 0U;
  }
  memset(destination, 0, total_bytes);
  destination[0] = (uint8_t)'N';
  destination[1] = (uint8_t)'E';
  destination[2] = (uint8_t)'S';
  destination[3] = 0x1AU;
  destination[4] = (uint8_t)LF_NESTURBATOR_SAVE_FIXTURE_PRG_BANKS;
  destination[5] = (uint8_t)LF_NESTURBATOR_SAVE_FIXTURE_CHR_BANKS;
  destination[6] = 0x12U; /* MMC1 mapper 1 and battery-backed PRG RAM. */
  destination[7] = 0U; /* Mapper high bits, format flags, and reserved bits. */
  memset(destination + header_bytes, 0xEA, prg_bytes);
  memcpy(destination + header_bytes, lf_nesturbator_save_fixture_program,
         sizeof(lf_nesturbator_save_fixture_program));
  for (vector_index = 0U; vector_index < 6U; vector_index += 2U) {
    const size_t offset = header_bytes + vector_offset + vector_index;
    destination[offset] = (uint8_t)(reset_vector & UINT16_C(0x00FF));
    destination[offset + 1U] =
        (uint8_t)((reset_vector >> 8U) & UINT16_C(0x00FF));
  }
  return total_bytes;
}

/* Same-sized generated negative-control image: guard the authored ADC #$01
   instruction, then change only its immediate to #$02. */
static inline size_t lf_build_nesturbator_alternate_save_fixture(
    uint8_t *destination, size_t capacity) {
  const size_t fixture_bytes =
      lf_build_nesturbator_save_fixture(destination, capacity);
  const size_t program_offset =
      (size_t)LF_NESTURBATOR_SAVE_FIXTURE_HEADER_BYTES;
  const size_t opcode_offset =
      program_offset + (size_t)LF_NESTURBATOR_SAVE_FIXTURE_ADC_OPCODE_OFFSET;
  const size_t operand_offset =
      program_offset + (size_t)LF_NESTURBATOR_SAVE_FIXTURE_ADC_OPERAND_OFFSET;
  if (fixture_bytes != (size_t)LF_NESTURBATOR_SAVE_FIXTURE_TOTAL_BYTES ||
      destination[opcode_offset] != 0x69U ||
      destination[operand_offset] != 0x01U) {
    return 0U;
  }
  destination[operand_offset] = 0x02U;
  return fixture_bytes;
}

typedef struct lf_nesturbator_fixture_sha256_context {
  uint32_t state[8];
  uint64_t bit_count;
  uint8_t block[64];
  size_t block_bytes;
} lf_nesturbator_fixture_sha256_context;

static inline uint32_t lf_nesturbator_fixture_rotr(uint32_t value,
                                                    unsigned int count) {
  return (value >> count) | (value << (32U - count));
}

static inline void lf_nesturbator_fixture_sha256_block(
    lf_nesturbator_fixture_sha256_context *context, const uint8_t block[64]) {
  static const uint32_t round_constants[64] = {
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
  uint32_t words[64];
  uint32_t a = context->state[0];
  uint32_t b = context->state[1];
  uint32_t c = context->state[2];
  uint32_t d = context->state[3];
  uint32_t e = context->state[4];
  uint32_t f = context->state[5];
  uint32_t g = context->state[6];
  uint32_t h = context->state[7];
  size_t index = 0U;
  for (index = 0U; index < 16U; ++index) {
    const size_t offset = index * 4U;
    words[index] = ((uint32_t)block[offset] << 24U) |
                   ((uint32_t)block[offset + 1U] << 16U) |
                   ((uint32_t)block[offset + 2U] << 8U) |
                   (uint32_t)block[offset + 3U];
  }
  for (index = 16U; index < 64U; ++index) {
    const uint32_t x = words[index - 15U];
    const uint32_t y = words[index - 2U];
    const uint32_t sigma0 = lf_nesturbator_fixture_rotr(x, 7U) ^
                            lf_nesturbator_fixture_rotr(x, 18U) ^ (x >> 3U);
    const uint32_t sigma1 = lf_nesturbator_fixture_rotr(y, 17U) ^
                            lf_nesturbator_fixture_rotr(y, 19U) ^ (y >> 10U);
    words[index] = words[index - 16U] + sigma0 + words[index - 7U] + sigma1;
  }
  for (index = 0U; index < 64U; ++index) {
    const uint32_t upper1 = lf_nesturbator_fixture_rotr(e, 6U) ^
                            lf_nesturbator_fixture_rotr(e, 11U) ^
                            lf_nesturbator_fixture_rotr(e, 25U);
    const uint32_t choose = (e & f) ^ ((~e) & g);
    const uint32_t temporary1 =
        h + upper1 + choose + round_constants[index] + words[index];
    const uint32_t upper0 = lf_nesturbator_fixture_rotr(a, 2U) ^
                            lf_nesturbator_fixture_rotr(a, 13U) ^
                            lf_nesturbator_fixture_rotr(a, 22U);
    const uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
    const uint32_t temporary2 = upper0 + majority;
    h = g;
    g = f;
    f = e;
    e = d + temporary1;
    d = c;
    c = b;
    b = a;
    a = temporary1 + temporary2;
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

static inline int lf_nesturbator_save_fixture_sha256(const uint8_t *data,
                                                     size_t extent_bytes,
                                                     uint8_t digest[32]) {
  lf_nesturbator_fixture_sha256_context context = {
      .state = {UINT32_C(0x6A09E667), UINT32_C(0xBB67AE85),
                UINT32_C(0x3C6EF372), UINT32_C(0xA54FF53A),
                UINT32_C(0x510E527F), UINT32_C(0x9B05688C),
                UINT32_C(0x1F83D9AB), UINT32_C(0x5BE0CD19)},
      .bit_count = 0U,
      .block = {0U},
      .block_bytes = 0U,
  };
  size_t offset = 0U;
  uint64_t original_bit_count = 0U;
  size_t index = 0U;
  if (digest == NULL || (extent_bytes != 0U && data == NULL) ||
      (uint64_t)extent_bytes > UINT64_MAX / UINT64_C(8)) {
    return 0;
  }
  context.bit_count = (uint64_t)extent_bytes * UINT64_C(8);
  while (offset < extent_bytes) {
    const size_t available = sizeof(context.block) - context.block_bytes;
    const size_t remaining = extent_bytes - offset;
    const size_t amount = available < remaining ? available : remaining;
    memcpy(context.block + context.block_bytes, data + offset, amount);
    context.block_bytes += amount;
    offset += amount;
    if (context.block_bytes == sizeof(context.block)) {
      lf_nesturbator_fixture_sha256_block(&context, context.block);
      context.block_bytes = 0U;
    }
  }
  original_bit_count = context.bit_count;
  context.block[context.block_bytes] = 0x80U;
  context.block_bytes += 1U;
  if (context.block_bytes > 56U) {
    memset(context.block + context.block_bytes, 0,
           sizeof(context.block) - context.block_bytes);
    lf_nesturbator_fixture_sha256_block(&context, context.block);
    context.block_bytes = 0U;
  }
  memset(context.block + context.block_bytes, 0, 56U - context.block_bytes);
  for (index = 0U; index < 8U; ++index) {
    const unsigned int shift = (unsigned int)((7U - index) * 8U);
    context.block[56U + index] = (uint8_t)(original_bit_count >> shift);
  }
  lf_nesturbator_fixture_sha256_block(&context, context.block);
  for (index = 0U; index < 8U; ++index) {
    const uint32_t word = context.state[index];
    const size_t digest_offset = index * 4U;
    digest[digest_offset] = (uint8_t)(word >> 24U);
    digest[digest_offset + 1U] = (uint8_t)(word >> 16U);
    digest[digest_offset + 2U] = (uint8_t)(word >> 8U);
    digest[digest_offset + 3U] = (uint8_t)word;
  }
  return 1;
}

#endif
