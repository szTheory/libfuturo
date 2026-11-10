#ifndef LIBFUTURO_TESTS_INSTALLED_CONSUMER_MUHTARI_SNAPSHOT_FIXTURE_H
#define LIBFUTURO_TESTS_INSTALLED_CONSUMER_MUHTARI_SNAPSHOT_FIXTURE_H

#include "muhtari_fixture.h"

#include <string.h>

#define LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES 34816U
#define LF_MUHTARI_SNAPSHOT_FIXTURE_SAVEKEY_OFFSET 2051U
#define LF_MUHTARI_SNAPSHOT_FIXTURE_HSC_OFFSET 0x0100U
#define LF_MUHTARI_SNAPSHOT_FIXTURE_SOURCE_LICENSE "Apache-2.0"
#define LF_MUHTARI_SNAPSHOT_FIXTURE_DELAY_OUTER 100U
#define LF_MUHTARI_SNAPSHOT_FIXTURE_DELAY_INNER 46U

static inline int lf_muhtari_snapshot_emit(uint8_t *program, size_t capacity,
                                            size_t *length, uint16_t address,
                                            uint8_t value) {
  const uint8_t code[] = {0xA9U, value, 0x8DU, (uint8_t)address,
                          (uint8_t)(address >> 8U)};
  if (*length > capacity || sizeof(code) > capacity - *length) {
    return 0;
  }
  memcpy(program + *length, code, sizeof(code));
  *length += sizeof(code);
  return 1;
}

static inline int lf_muhtari_snapshot_pin(uint8_t *program, size_t capacity,
                                           size_t *length, unsigned scl,
                                           unsigned sda) {
  const uint8_t value = (uint8_t)((scl == 0U ? 8U : 0U) |
                                  (sda == 0U ? 4U : 0U));
  return lf_muhtari_snapshot_emit(program, capacity, length, 0x0281U, value);
}

static inline int lf_muhtari_snapshot_byte(uint8_t *program, size_t capacity,
                                            size_t *length, uint8_t value) {
  for (unsigned bit = 0U; bit < 8U; ++bit) {
    const unsigned level = (unsigned)(value >> (7U - bit)) & 1U;
    if (!lf_muhtari_snapshot_pin(program, capacity, length, 0U, level) ||
        !lf_muhtari_snapshot_pin(program, capacity, length, 1U, level) ||
        !lf_muhtari_snapshot_pin(program, capacity, length, 0U, level)) {
      return 0;
    }
  }
  return lf_muhtari_snapshot_pin(program, capacity, length, 0U, 1U) &&
         lf_muhtari_snapshot_pin(program, capacity, length, 1U, 1U) &&
         lf_muhtari_snapshot_pin(program, capacity, length, 0U, 1U);
}

/* The guest's F000 preamble sends one SaveKey page byte at aggregate offset
   2051, then the C000 loop increments HSC offset 0x0100 once per instruction
   pair. The nested-delay cycle count places the EEPROM busy window across the
   first public frame boundary; only public copies establish the result. */
static inline size_t lf_build_muhtari_snapshot_fixture(uint8_t *destination,
                                                        size_t capacity) {
  static const uint8_t title[] = "API8 snapshot HSC SaveKey";
  static const uint8_t frame_program[] = {
      0x78U, 0xD8U,             /* SEI; CLD */
      0xA9U, 0x0FU, 0x85U, 0x19U, /* COLUP0 = 0x0F */
      0xA9U, 0x04U, 0x85U, 0x15U, /* AUDC0 = 4 */
      0xA9U, 0x00U, 0x85U, 0x17U, /* AUDF0 = 0 */
      0xA9U, 0x33U, 0x8DU, 0x20U, 0x00U}; /* BACKGRND = 0x33 */
  const size_t total_bytes = (size_t)LF_MUHTARI_FIXTURE_TOTAL_BYTES;
  const size_t header_bytes = (size_t)LF_MUHTARI_FIXTURE_HEADER_BYTES;
  const size_t rom_bytes = (size_t)LF_MUHTARI_FIXTURE_ROM_BYTES;
  const size_t rom_offset = header_bytes;
  const size_t preamble_offset = rom_bytes - 4096U;
  uint8_t preamble[4096U];
  size_t preamble_length = 0U;
  size_t main_length = sizeof(frame_program);
  uint16_t loop_address = 0U;
  uint16_t reset_vector = 0xF000U;

  if (destination == NULL || capacity < total_bytes ||
      sizeof(title) > 33U || sizeof(frame_program) + 6U > rom_bytes) {
    return 0U;
  }
  if (lf_build_muhtari_fixture(destination, capacity) != total_bytes) {
    return 0U;
  }
  memset(destination + 17U, 0, 32U);
  memcpy(destination + 17U, title, sizeof(title) - 1U);
  memset(destination + rom_offset, 0xEA, rom_bytes);
  memcpy(destination + rom_offset, frame_program, sizeof(frame_program));
  loop_address = (uint16_t)(0xC000U + (uint16_t)main_length);
  destination[rom_offset + main_length++] = 0xEEU; /* INC $1100 (HSC byte 0x100) */
  destination[rom_offset + main_length++] = 0x00U;
  destination[rom_offset + main_length++] = 0x11U;
  destination[rom_offset + main_length++] = 0x4CU; /* JMP HSC loop */
  destination[rom_offset + main_length++] = (uint8_t)loop_address;
  destination[rom_offset + main_length++] = (uint8_t)(loop_address >> 8U);

  memset(preamble, 0xEA, sizeof(preamble));
  preamble[preamble_length++] = 0x78U; /* SEI */
  preamble[preamble_length++] = 0xD8U; /* CLD */
  preamble[preamble_length++] = 0xA2U;
  preamble[preamble_length++] = (uint8_t)LF_MUHTARI_SNAPSHOT_FIXTURE_DELAY_OUTER;
  preamble[preamble_length++] = 0xA0U;
  preamble[preamble_length++] = (uint8_t)LF_MUHTARI_SNAPSHOT_FIXTURE_DELAY_INNER;
  preamble[preamble_length++] = 0x88U; /* DEY */
  preamble[preamble_length++] = 0xD0U; /* BNE DEY */
  preamble[preamble_length++] = 0xFDU;
  preamble[preamble_length++] = 0xCAU; /* DEX */
  preamble[preamble_length++] = 0xD0U; /* BNE LDY */
  preamble[preamble_length++] = 0xF8U;
  if (!lf_muhtari_snapshot_emit(preamble, sizeof(preamble), &preamble_length,
                                0x0280U, 0U) ||
      !lf_muhtari_snapshot_pin(preamble, sizeof(preamble), &preamble_length,
                               1U, 1U) ||
      !lf_muhtari_snapshot_pin(preamble, sizeof(preamble), &preamble_length,
                               1U, 0U) ||
      !lf_muhtari_snapshot_pin(preamble, sizeof(preamble), &preamble_length,
                               0U, 0U) ||
      !lf_muhtari_snapshot_byte(preamble, sizeof(preamble), &preamble_length,
                                0xA0U) ||
      !lf_muhtari_snapshot_byte(preamble, sizeof(preamble), &preamble_length,
                                0x00U) ||
      !lf_muhtari_snapshot_byte(preamble, sizeof(preamble), &preamble_length,
                                0x03U) ||
      !lf_muhtari_snapshot_byte(preamble, sizeof(preamble), &preamble_length,
                                0x5AU) ||
      !lf_muhtari_snapshot_pin(preamble, sizeof(preamble), &preamble_length,
                               0U, 0U) ||
      !lf_muhtari_snapshot_pin(preamble, sizeof(preamble), &preamble_length,
                               1U, 0U) ||
      !lf_muhtari_snapshot_pin(preamble, sizeof(preamble), &preamble_length,
                               1U, 1U) ||
      preamble_length + 3U > sizeof(preamble)) {
    return 0U;
  }
  preamble[preamble_length++] = 0x4CU; /* JMP C000 */
  preamble[preamble_length++] = 0x00U;
  preamble[preamble_length++] = 0xC0U;
  memcpy(destination + rom_offset + preamble_offset, preamble,
         preamble_length);
  for (size_t vector = 0U; vector < 6U; vector += 2U) {
    const size_t at = rom_offset + rom_bytes - 6U + vector;
    destination[at] = (uint8_t)reset_vector;
    destination[at + 1U] = (uint8_t)(reset_vector >> 8U);
  }
  return total_bytes;
}

#endif
