#ifndef LIBFUTURO_TESTS_INSTALLED_CONSUMER_MUHTARI_SAVE_ORACLE_H
#define LIBFUTURO_TESTS_INSTALLED_CONSUMER_MUHTARI_SAVE_ORACLE_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define LF_MUHTARI_SAVE_FIXTURE_SOURCE_COMMIT \
  "4642ded6d026f456acf798a43efb081b76987018"
#define LF_MUHTARI_SAVE_FIXTURE_LICENSE "MIT"
#define LF_MUHTARI_SAVE_FIXTURE_SHA256 \
  "10f5bc279d8147b3348e102ca9f7e4dc496dd31b5099adb2ef64320e987fb4d4"
#define LF_MUHTARI_SAVE_FIXTURE_BYTES 16512U
#define LF_MUHTARI_SAVE_MEDIA_BYTES 34816U
#define LF_MUHTARI_SAVE_HSC_LOW_OFFSET 0x0100U
#define LF_MUHTARI_SAVE_HSC_HIGH_OFFSET 0x0101U
#define LF_MUHTARI_SAVE_EEPROM_LOW_OFFSET 0x6800U
#define LF_MUHTARI_SAVE_EEPROM_HIGH_OFFSET 0x6801U

static inline void lf_muhtari_save_oracle_fill(uint8_t *expected,
                                                uint8_t counter) {
  memset(expected, UINT8_C(0xFF), LF_MUHTARI_SAVE_MEDIA_BYTES);
  expected[LF_MUHTARI_SAVE_HSC_LOW_OFFSET] = counter;
  expected[LF_MUHTARI_SAVE_HSC_HIGH_OFFSET] = UINT8_C(0x00);
  expected[LF_MUHTARI_SAVE_EEPROM_LOW_OFFSET] = counter;
  expected[LF_MUHTARI_SAVE_EEPROM_HIGH_OFFSET] = UINT8_C(0x00);
}

static inline int lf_muhtari_save_oracle_matches(const uint8_t *actual,
                                                  uint8_t counter) {
  uint8_t expected[LF_MUHTARI_SAVE_MEDIA_BYTES];
  if (actual == NULL) {
    return 0;
  }
  lf_muhtari_save_oracle_fill(expected, counter);
  return memcmp(actual, expected, sizeof(expected)) == 0;
}

static inline int lf_muhtari_save_oracle_is_fresh(const uint8_t *actual) {
  if (actual == NULL) {
    return 0;
  }
  for (size_t index = 0U; index < LF_MUHTARI_SAVE_MEDIA_BYTES; ++index) {
    if (actual[index] != UINT8_C(0xFF)) {
      return 0;
    }
  }
  return 1;
}

#endif
