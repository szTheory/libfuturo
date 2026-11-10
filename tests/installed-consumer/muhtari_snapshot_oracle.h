#ifndef LIBFUTURO_TESTS_INSTALLED_CONSUMER_MUHTARI_SNAPSHOT_ORACLE_H
#define LIBFUTURO_TESTS_INSTALLED_CONSUMER_MUHTARI_SNAPSHOT_ORACLE_H

#include "muhtari_oracle.h"
#include "muhtari_snapshot_fixture.h"

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define LF_MUHTARI_SNAPSHOT_R2_FRAME 2U
#define LF_MUHTARI_SNAPSHOT_R2_HSC_VALUE UINT8_C(0x43)
#define LF_MUHTARI_SNAPSHOT_R2_SAVEKEY_VALUE UINT8_C(0xFF)
#define LF_MUHTARI_SNAPSHOT_R2_GENERATION UINT64_C(836)
#define LF_MUHTARI_SNAPSHOT_R2_AUDIO_SAMPLES 801U
#define LF_MUHTARI_SNAPSHOT_R2_VIDEO_SHA256 \
  "40290f536a0e1b2540d868d1a8d2f88c59a0e2d072e49bac762678f245fbb79a"
#define LF_MUHTARI_SNAPSHOT_R2_PCM_SHA256 \
  "d4f75a98b2ac3685eae765036512f04f70d8c952340d8347f602c4b43c1ed15c"
#define LF_MUHTARI_SNAPSHOT_R2_BATTERY_SHA256 \
  "036d171c7642abeb0acc3670afc5a67422bf028b0086d0d8720a95985fdfdb64"

#define LF_MUHTARI_SNAPSHOT_R3_FRAME 3U
#define LF_MUHTARI_SNAPSHOT_R3_HSC_VALUE UINT8_C(0x37)
#define LF_MUHTARI_SNAPSHOT_R3_SAVEKEY_VALUE UINT8_C(0x5A)
#define LF_MUHTARI_SNAPSHOT_R3_GENERATION UINT64_C(4153)
#define LF_MUHTARI_SNAPSHOT_R3_AUDIO_SAMPLES 801U
#define LF_MUHTARI_SNAPSHOT_R3_VIDEO_SHA256 \
  "59b78332303fa3c631ae7cd522ad45627f739b49a48e8c0b0c07f45ea79bd225"
#define LF_MUHTARI_SNAPSHOT_R3_PCM_SHA256 \
  "09474df08fabeb22495ea69a6becd73374879d6840862382d0691c6e7a13a13f"
#define LF_MUHTARI_SNAPSHOT_R3_BATTERY_SHA256 \
  "495ead1f5e803049666b25490aa47495e529eda7c8516eb3513947b403b4a583"

#define LF_MUHTARI_SNAPSHOT_FRAME1_AUDIO_SAMPLES 54U
#define LF_MUHTARI_SNAPSHOT_FRAME1_VIDEO_SHA256 \
  "a2039dfec6c6b253a800d8f2a22c917aee174787618bf83508d04408901840fa"
#define LF_MUHTARI_SNAPSHOT_FRAME1_PCM_SHA256 \
  "77133f431d5e12dd850002c0d3d4e0fecbe3a7a699d604dc8c5eae9976e1d260"
#define LF_MUHTARI_SNAPSHOT_FRAME1_BATTERY_SHA256 \
  "526d5e5ef52a683b7c1b56bd4f930811aa8d7217114a21fa2270c581382d63cc"
#define LF_MUHTARI_SNAPSHOT_VIDEO_WIDTH 320U
#define LF_MUHTARI_SNAPSHOT_VIDEO_HEIGHT 242U

typedef struct lf_muhtari_snapshot_expected_frame {
  size_t audio_samples;
  const char *video_sha256;
  const char *pcm_sha256;
  const char *battery_sha256;
  uint8_t hsc_value;
  uint8_t savekey_value;
  uint64_t generation;
} lf_muhtari_snapshot_expected_frame;

static inline int lf_muhtari_snapshot_expected(
    uint32_t frame, lf_muhtari_snapshot_expected_frame *out) {
  if (out == NULL) {
    return 0;
  }
  switch (frame) {
    case 1U:
      *out = (lf_muhtari_snapshot_expected_frame){
          LF_MUHTARI_SNAPSHOT_FRAME1_AUDIO_SAMPLES,
          LF_MUHTARI_SNAPSHOT_FRAME1_VIDEO_SHA256,
          LF_MUHTARI_SNAPSHOT_FRAME1_PCM_SHA256,
          LF_MUHTARI_SNAPSHOT_FRAME1_BATTERY_SHA256,
          UINT8_C(0xFF), UINT8_C(0xFF), UINT64_C(0)};
      return 1;
    case LF_MUHTARI_SNAPSHOT_R2_FRAME:
      *out = (lf_muhtari_snapshot_expected_frame){
          LF_MUHTARI_SNAPSHOT_R2_AUDIO_SAMPLES,
          LF_MUHTARI_SNAPSHOT_R2_VIDEO_SHA256,
          LF_MUHTARI_SNAPSHOT_R2_PCM_SHA256,
          LF_MUHTARI_SNAPSHOT_R2_BATTERY_SHA256,
          LF_MUHTARI_SNAPSHOT_R2_HSC_VALUE,
          LF_MUHTARI_SNAPSHOT_R2_SAVEKEY_VALUE,
          LF_MUHTARI_SNAPSHOT_R2_GENERATION};
      return 1;
    case LF_MUHTARI_SNAPSHOT_R3_FRAME:
      *out = (lf_muhtari_snapshot_expected_frame){
          LF_MUHTARI_SNAPSHOT_R3_AUDIO_SAMPLES,
          LF_MUHTARI_SNAPSHOT_R3_VIDEO_SHA256,
          LF_MUHTARI_SNAPSHOT_R3_PCM_SHA256,
          LF_MUHTARI_SNAPSHOT_R3_BATTERY_SHA256,
          LF_MUHTARI_SNAPSHOT_R3_HSC_VALUE,
          LF_MUHTARI_SNAPSHOT_R3_SAVEKEY_VALUE,
          LF_MUHTARI_SNAPSHOT_R3_GENERATION};
      return 1;
    default:
      return 0;
  }
}

/* Independently defined full-span expectations: fresh HSC and EEPROM bytes
   are FF except the generated HSC counter and EEPROM address 3. */
static inline int lf_muhtari_snapshot_fill_expected_battery(
    uint32_t frame, uint8_t expected[LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES]) {
  if (expected == NULL || frame < 1U || frame > 3U) {
    return 0;
  }
  memset(expected, UINT8_C(0xFF),
         LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES);
  if (frame == LF_MUHTARI_SNAPSHOT_R2_FRAME) {
    expected[LF_MUHTARI_SNAPSHOT_FIXTURE_HSC_OFFSET] =
        LF_MUHTARI_SNAPSHOT_R2_HSC_VALUE;
    return 1;
  }
  if (frame == LF_MUHTARI_SNAPSHOT_R3_FRAME) {
    expected[LF_MUHTARI_SNAPSHOT_FIXTURE_HSC_OFFSET] =
        LF_MUHTARI_SNAPSHOT_R3_HSC_VALUE;
    expected[LF_MUHTARI_SNAPSHOT_FIXTURE_SAVEKEY_OFFSET] =
        LF_MUHTARI_SNAPSHOT_R3_SAVEKEY_VALUE;
  }
  return 1;
}

static inline const char *lf_muhtari_snapshot_first_mismatch(
    const uint8_t *video, const int16_t *audio, size_t audio_samples,
    const uint8_t *media, uint32_t frame, size_t expected_audio_samples,
    const char *expected_video_sha256, const char *expected_pcm_sha256,
    const uint8_t expected_media[LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES]) {
  char actual_digest[65];
  uint8_t expected_battery[LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES];
  if (frame == 0U || frame > 3U || video == NULL || audio == NULL ||
      media == NULL || expected_video_sha256 == NULL ||
      expected_pcm_sha256 == NULL || expected_media == NULL ||
      audio_samples != expected_audio_samples) {
    return "frame";
  }
  lf_muhtari_oracle_sha256 context;
  uint8_t digest[32];
  lf_muhtari_oracle_sha256_init(&context);
  lf_muhtari_oracle_sha256_update(
      &context, video,
      (size_t)LF_MUHTARI_SNAPSHOT_VIDEO_WIDTH *
          (size_t)LF_MUHTARI_SNAPSHOT_VIDEO_HEIGHT);
  lf_muhtari_oracle_sha256_finish(&context, digest);
  lf_muhtari_oracle_hex_digest(digest, actual_digest);
  if (strcmp(actual_digest, expected_video_sha256) != 0) {
    return "video";
  }
  lf_muhtari_oracle_pcm_digest(audio, audio_samples, actual_digest);
  if (strcmp(actual_digest, expected_pcm_sha256) != 0) {
    return "audio";
  }
  if (!lf_muhtari_snapshot_fill_expected_battery(frame, expected_battery) ||
      memcmp(expected_media, expected_battery, sizeof(expected_battery)) != 0 ||
      memcmp(media, expected_battery, sizeof(expected_battery)) != 0) {
    return "battery";
  }
  return NULL;
}

#endif
