#ifndef LIBFUTURO_TESTS_INSTALLED_CONSUMER_MUHTARI_FIXTURE_H
#define LIBFUTURO_TESTS_INSTALLED_CONSUMER_MUHTARI_FIXTURE_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define LF_MUHTARI_FIXTURE_HEADER_BYTES 128U
#define LF_MUHTARI_FIXTURE_ROM_BYTES (16U * 1024U)
#define LF_MUHTARI_FIXTURE_TOTAL_BYTES \
  (LF_MUHTARI_FIXTURE_HEADER_BYTES + LF_MUHTARI_FIXTURE_ROM_BYTES)

/* Original 6502 code reads both one-button fire inputs and each active-low
   SWCHA direction pin. Each supported control selects a distinct raw
   background index, and TIA channel 0 plays a fixed tone. */
static const uint8_t lf_muhtari_fixture_program[] = {
    0x78U, 0xD8U, 0xA9U, 0x0FU, 0x85U, 0x19U, 0xA9U, 0x04U,
    0x85U, 0x15U, 0xA9U, 0x00U, 0x85U, 0x17U,
    0xADU, 0x0CU, 0x00U, 0x30U, 0x0FU, 0xADU, 0x0DU, 0x00U,
    0x30U, 0x05U, 0xA9U, 0x44U, 0x4CU, 0x91U, 0xC0U,
    0xA9U, 0x11U, 0x4CU, 0x91U, 0xC0U,
    0xADU, 0x0DU, 0x00U, 0x30U, 0x05U, 0xA9U, 0x22U,
    0x4CU, 0x91U, 0xC0U,
    /* Read the joystick-direction pins in documented active-low SWCHA
       order: port 0 bits 4..7, then port 1 bits 0..3. */
    0xA9U, 0x10U, 0x2CU, 0x80U, 0x02U, 0xF0U, 0x36U,
    0xA9U, 0x20U, 0x2CU, 0x80U, 0x02U, 0xF0U, 0x34U,
    0xA9U, 0x40U, 0x2CU, 0x80U, 0x02U, 0xF0U, 0x32U,
    0xA9U, 0x80U, 0x2CU, 0x80U, 0x02U, 0xF0U, 0x30U,
    0xA9U, 0x01U, 0x2CU, 0x80U, 0x02U, 0xF0U, 0x2EU,
    0xA9U, 0x02U, 0x2CU, 0x80U, 0x02U, 0xF0U, 0x2CU,
    0xA9U, 0x04U, 0x2CU, 0x80U, 0x02U, 0xF0U, 0x2AU,
    0xA9U, 0x08U, 0x2CU, 0x80U, 0x02U, 0xF0U, 0x28U,
    0xA9U, 0x33U, 0x4CU, 0x91U, 0xC0U,
    0xA9U, 0x51U, 0x4CU, 0x91U, 0xC0U,
    0xA9U, 0x52U, 0x4CU, 0x91U, 0xC0U,
    0xA9U, 0x53U, 0x4CU, 0x91U, 0xC0U,
    0xA9U, 0x54U, 0x4CU, 0x91U, 0xC0U,
    0xA9U, 0x61U, 0x4CU, 0x91U, 0xC0U,
    0xA9U, 0x62U, 0x4CU, 0x91U, 0xC0U,
    0xA9U, 0x63U, 0x4CU, 0x91U, 0xC0U,
    0xA9U, 0x64U, 0x4CU, 0x91U, 0xC0U,
    0x8DU, 0x20U, 0x00U, 0x4CU, 0x0EU, 0xC0U
};

/* Original A78-v1 image: one linear 16 KiB ROM, NTSC, two joystick ports,
   reset vector at $C000, and no external BIOS or firmware. */
static inline size_t lf_build_muhtari_fixture(uint8_t *destination,
                                               size_t capacity) {
  static const uint8_t magic[9] = {'A', 'T', 'A', 'R', 'I', '7', '8', '0', '0'};
  static const char title[] = "libfuturo input audio diagnostic";
  const size_t header_bytes = (size_t)LF_MUHTARI_FIXTURE_HEADER_BYTES;
  const size_t rom_bytes = (size_t)LF_MUHTARI_FIXTURE_ROM_BYTES;
  const size_t total_bytes = (size_t)LF_MUHTARI_FIXTURE_TOTAL_BYTES;
  const size_t vector_offset = rom_bytes - 6U;
  const uint16_t reset_vector = UINT16_C(0xC000);
  if (destination == NULL || capacity < total_bytes ||
      sizeof(lf_muhtari_fixture_program) > rom_bytes ||
      sizeof(title) > 33U) {
    return 0U;
  }
  memset(destination, 0, total_bytes);
  destination[0] = 1U;
  memcpy(destination + 1U, magic, sizeof(magic));
  memcpy(destination + 17U, title, sizeof(title) - 1U);
  destination[49] = (uint8_t)((rom_bytes >> 24U) & 0xFFU);
  destination[50] = (uint8_t)((rom_bytes >> 16U) & 0xFFU);
  destination[51] = (uint8_t)((rom_bytes >> 8U) & 0xFFU);
  destination[52] = (uint8_t)(rom_bytes & 0xFFU);
  destination[55] = 5U; /* MUHTARI_PORT_JOYSTICK */
  destination[56] = 5U;
  memset(destination + header_bytes, 0xEA, rom_bytes);
  memcpy(destination + header_bytes, lf_muhtari_fixture_program,
         sizeof(lf_muhtari_fixture_program));
  for (size_t vector = 0U; vector < 6U; vector += 2U) {
    const size_t at = header_bytes + vector_offset + vector;
    destination[at] = (uint8_t)(reset_vector & UINT16_C(0x00FF));
    destination[at + 1U] = (uint8_t)(reset_vector >> 8U);
  }
  return total_bytes;
}

#endif
