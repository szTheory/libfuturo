#ifndef LIBFUTURO_TESTS_NESTURBATOR_SAVE_ORACLE_H
#define LIBFUTURO_TESTS_NESTURBATOR_SAVE_ORACLE_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define LF_SAVE_ORACLE_EXTENT_BYTES 8192U
#define LF_SAVE_ORACLE_INITIAL_BYTE UINT8_C(0x00)
#define LF_SAVE_ORACLE_COMMITTED_BYTE UINT8_C(0x03)
#define LF_SAVE_ORACLE_CONTINUATION_BYTE UINT8_C(0x04)
#define LF_SAVE_ORACLE_FILL_BYTE UINT8_C(0x00)
#define LF_SAVE_ORACLE_SHA256_HEX \
  "2282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9"
#define LF_SAVE_ORACLE_CONTENT_IDENTITY \
  "sha256:" LF_SAVE_ORACLE_SHA256_HEX
#define LF_SAVE_ORACLE_MEDIA_IDENTITY "nesturbator-save-ram-v1"
#define LF_SAVE_ORACLE_CONFIGURATION_IDENTITY "nesturbator-default"
#define LF_SAVE_ORACLE_CONTENT_IDENTITY_CAPACITY 80U
#define LF_SAVE_ORACLE_CONFIGURATION_IDENTITY_CAPACITY 40U
#define LF_SAVE_ORACLE_MEDIA_IDENTITY_CAPACITY 40U

#define LF_BATTERY_SNAPSHOT_CAPTURE_BYTE UINT8_C(0x02)
#define LF_BATTERY_SNAPSHOT_NEWER_BYTE UINT8_C(0x03)
#define LF_BATTERY_SNAPSHOT_REPLAY_BYTE UINT8_C(0x03)
#define LF_BATTERY_SNAPSHOT_REPLAY_FRAMES UINT64_C(3)
#define LF_BATTERY_SNAPSHOT_REPLAY_TICKS UINT64_C(2144280)
#define LF_BATTERY_SNAPSHOT_REPLAY_AUDIO_SAMPLES 799U
#define LF_BATTERY_SNAPSHOT_REPLAY_AUDIO_SAMPLE INT16_C(0)
#define LF_BATTERY_SNAPSHOT_REPLAY_RGB_RED UINT8_C(0x5A)
#define LF_BATTERY_SNAPSHOT_REPLAY_RGB_GREEN UINT8_C(0x5A)
#define LF_BATTERY_SNAPSHOT_REPLAY_RGB_BLUE UINT8_C(0x5A)

/* Keep the relocated consumer's literal oracle aligned with the source route:
   three 714732-tick work units end at 714768, 1429512, and 2144280 ticks as
   each frame runner completes its active CPU instruction (36, 12, and 36 tick
   overrun). The MMC1 fixture writes $6000 once per unit, disables rendering
   and every APU channel, and therefore yields the reset backdrop 0x5A5A5A,
   audio samples of zero, and the carried third-unit count of 799. */

/* Independent literal model: the committed span is [0x03, 0x00 ... 0x00],
   and one restored frame continues it to [0x04, 0x00 ... 0x00]. */
static inline int lf_save_oracle_matches(const uint8_t *bytes,
                                         size_t extent_bytes,
                                         uint8_t first_byte) {
  size_t index = 0U;
  if (bytes == NULL || extent_bytes != (size_t)LF_SAVE_ORACLE_EXTENT_BYTES ||
      bytes[0] != first_byte) {
    return 0;
  }
  for (index = 1U; index < extent_bytes; ++index) {
    if (bytes[index] != (uint8_t)LF_SAVE_ORACLE_FILL_BYTE) {
      return 0;
    }
  }
  return 1;
}

static inline int lf_save_oracle_sha256_matches(const uint8_t *actual,
                                                size_t actual_bytes) {
  static const char expected_hex[] = LF_SAVE_ORACLE_SHA256_HEX;
  static const char hex_digits[] = "0123456789abcdef";
  size_t index = 0U;
  if (actual == NULL || actual_bytes != 32U || strlen(expected_hex) != 64U) {
    return 0;
  }
  for (index = 0U; index < actual_bytes; ++index) {
    if (hex_digits[(size_t)(actual[index] >> 4U)] !=
            expected_hex[index * 2U] ||
        hex_digits[(size_t)(actual[index] & 0x0FU)] !=
            expected_hex[index * 2U + 1U]) {
      return 0;
    }
  }
  return 1;
}

#endif
