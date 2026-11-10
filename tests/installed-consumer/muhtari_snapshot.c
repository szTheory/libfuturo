#define _POSIX_C_SOURCE 200809L

#include <libfuturo/libfuturo.h>

#include "muhtari_fixture.h"
#include "muhtari_oracle.h"
#include "muhtari_snapshot_fixture.h"
#include "muhtari_snapshot_faults.h"
#include "muhtari_snapshot_host.h"
#include "muhtari_snapshot_oracle.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LF_MUHTARI_API8_PROFILE "muhtari-ntsc-v2"
#define LF_MUHTARI_API8_CONFIGURATION "muhtari-ntsc-battery-diagnostic"
#define LF_MUHTARI_API8_VIDEO_WIDTH 320U
#define LF_MUHTARI_API8_VIDEO_HEIGHT 242U
#define LF_MUHTARI_API8_AUDIO_SAMPLES 801U

static int fail(const char *message, lf_status status) {
  (void)fprintf(stderr, "muhtari_api8_profile: %s status=%d\n", message,
                (int)status);
  return 1;
}

static void snapshot_digest(const uint8_t *bytes, size_t extent,
                            char hex[65]) {
  lf_muhtari_oracle_sha256 context;
  uint8_t digest[32];
  lf_muhtari_oracle_sha256_init(&context);
  lf_muhtari_oracle_sha256_update(&context, bytes, extent);
  lf_muhtari_oracle_sha256_finish(&context, digest);
  lf_muhtari_oracle_hex_digest(digest, hex);
}

static int fixture_boundary(int oracle_controls) {
  uint8_t content[LF_MUHTARI_FIXTURE_TOTAL_BYTES];
  uint8_t video[LF_MUHTARI_API8_VIDEO_WIDTH * LF_MUHTARI_API8_VIDEO_HEIGHT];
  int16_t audio[LF_MUHTARI_API8_AUDIO_SAMPLES];
  uint8_t media[LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES];
  uint8_t expected_media[LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES];
  uint8_t wrong_media[LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES];
  char fixture_digest[65];
  lf_instance *instance = NULL;
  lf_load_result load_result = {.struct_size = sizeof(load_result)};
  lf_run_result run_result = {.struct_size = sizeof(run_result)};
  lf_media_info media_info = {.struct_size = sizeof(media_info)};
  const lf_load_request load_request = {
      .struct_size = sizeof(load_request),
      .content_data = content,
      .content_size_bytes = sizeof(content),
      .configuration_id = LF_MUHTARI_API8_CONFIGURATION,
  };
  const lf_run_request run_request = {
      .struct_size = sizeof(run_request),
      .work_units = 1U,
      .video_data = video,
      .video_capacity_bytes = sizeof(video),
      .video_stride_bytes = LF_MUHTARI_API8_VIDEO_WIDTH,
      .audio_data = audio,
      .audio_capacity_samples = LF_MUHTARI_API8_AUDIO_SAMPLES,
  };
  lf_status status = LF_OK;

  if (lf_build_muhtari_snapshot_fixture(content, sizeof(content)) !=
      sizeof(content)) {
    return fail("generated HSC/SaveKey A78 construction failed",
                LF_INVALID_ARGUMENT);
  }
  if (!lf_muhtari_oracle_sha256_self_check()) {
    return fail("independent SHA-256 known-vector check failed",
                LF_UNSUPPORTED);
  }
  snapshot_digest(content, sizeof(content), fixture_digest);
  (void)printf("muhtari_api8_fixture_identity: bytes=%zu sha256=%s program=generated-linear-a78 topology=HSC-2048+SaveKey-32768 delay-outer=%u delay-inner=%u\n",
               sizeof(content), fixture_digest,
               LF_MUHTARI_SNAPSHOT_FIXTURE_DELAY_OUTER,
               LF_MUHTARI_SNAPSHOT_FIXTURE_DELAY_INNER);
  status = lf_create(LF_MUHTARI_API8_PROFILE, NULL, &instance);
  if (status != LF_OK || instance == NULL) {
    return fail("public API 8 instance creation failed", status);
  }
  status = lf_load(instance, &load_request, &load_result);
  if (status != LF_OK || load_result.loaded != 1U) {
    (void)lf_destroy(&instance);
    return fail("generated HSC/SaveKey fixture load failed", status);
  }
  memset(media, 0xA5, sizeof(media));
  status = lf_copy_media(instance, media, sizeof(media), &media_info);
  if (status != LF_OK || media_info.extent_bytes != sizeof(media) ||
      media_info.identity == NULL ||
      strcmp(media_info.identity, "muhtari-battery-v1") != 0) {
    (void)lf_destroy(&instance);
    return fail("initial 34816-byte battery span metadata mismatch", status);
  }
  for (size_t index = 0U; index < sizeof(media); ++index) {
    if (media[index] != UINT8_C(0xFF)) {
      (void)lf_destroy(&instance);
      return fail("initial HSC/SaveKey byte is not the independent 0xFF literal",
                  LF_UNSUPPORTED);
    }
  }
  for (uint32_t frame = 1U; frame <= 3U; ++frame) {
    char video_digest[65];
    char audio_digest[65];
    char battery_digest[65];
    lf_muhtari_snapshot_expected_frame expected;
    status = lf_advance(instance, &run_request, &run_result);
    if (status != LF_OK || run_result.actual_units != 1U ||
        run_result.video_valid != 1U || run_result.audio_valid != 1U ||
        run_result.cumulative_units != frame) {
      (void)lf_destroy(&instance);
      return fail("public frame did not produce diagnostic outputs", status);
    }
    status = lf_copy_media(instance, media, sizeof(media), &media_info);
    if (status != LF_OK || media_info.extent_bytes != sizeof(media)) {
      (void)lf_destroy(&instance);
      return fail("public frame battery copy failed", status);
    }
    if (!lf_muhtari_snapshot_expected(frame, &expected) ||
        !lf_muhtari_snapshot_fill_expected_battery(frame, expected_media)) {
      (void)lf_destroy(&instance);
      return fail("fixed public-frame oracle is unavailable", LF_UNSUPPORTED);
    }
    {
      const char *mismatch = lf_muhtari_snapshot_first_mismatch(
          video, audio, run_result.audio_produced_samples, media, frame,
          expected.audio_samples, expected.video_sha256, expected.pcm_sha256,
          expected_media);
      if (mismatch != NULL ||
          media_info.guest_generation != expected.generation) {
        (void)fprintf(stderr,
                      "muhtari_api8_fixture_boundary: independent %s literal failed at frame %u generation=%llu expected-generation=%llu\n",
                      mismatch != NULL ? mismatch : "generation", frame,
                      (unsigned long long)media_info.guest_generation,
                      (unsigned long long)expected.generation);
        (void)lf_destroy(&instance);
        return 1;
      }
    }
    snapshot_digest(video, sizeof(video), video_digest);
    lf_muhtari_oracle_pcm_digest(audio, run_result.audio_produced_samples,
                                 audio_digest);
    snapshot_digest(media, sizeof(media), battery_digest);
    if (strcmp(battery_digest, expected.battery_sha256) != 0) {
      (void)lf_destroy(&instance);
      return fail("independent full-span battery digest mismatch",
                  LF_UNSUPPORTED);
    }
    (void)printf("muhtari_api8_fixture_vector: frame=%u samples=%zu video=%s pcm=%s battery=%s hsc=%02X savekey=%02X generation=%llu\n",
                 frame, run_result.audio_produced_samples, video_digest,
                 audio_digest, battery_digest,
                 media[LF_MUHTARI_SNAPSHOT_FIXTURE_HSC_OFFSET],
                 media[LF_MUHTARI_SNAPSHOT_FIXTURE_SAVEKEY_OFFSET],
                 (unsigned long long)media_info.guest_generation);
    if (frame == LF_MUHTARI_SNAPSHOT_R2_FRAME &&
        media[LF_MUHTARI_SNAPSHOT_FIXTURE_SAVEKEY_OFFSET] !=
            LF_MUHTARI_SNAPSHOT_R2_SAVEKEY_VALUE) {
      (void)fprintf(stderr,
                    "muhtari_api8_fixture_boundary: pending R2 SaveKey literal at aggregate offset %u expected 0x%02X, observed 0x%02X after frame %u\n",
                    LF_MUHTARI_SNAPSHOT_FIXTURE_SAVEKEY_OFFSET,
                    LF_MUHTARI_SNAPSHOT_R2_SAVEKEY_VALUE,
                    media[LF_MUHTARI_SNAPSHOT_FIXTURE_SAVEKEY_OFFSET], frame);
      (void)lf_destroy(&instance);
      return 1;
    }
    if (frame == LF_MUHTARI_SNAPSHOT_R3_FRAME &&
        media[LF_MUHTARI_SNAPSHOT_FIXTURE_SAVEKEY_OFFSET] !=
            LF_MUHTARI_SNAPSHOT_R3_SAVEKEY_VALUE) {
      (void)fprintf(stderr,
                    "muhtari_api8_fixture_boundary: published R3 SaveKey literal at aggregate offset %u expected 0x%02X, observed 0x%02X after frame %u\n",
                    LF_MUHTARI_SNAPSHOT_FIXTURE_SAVEKEY_OFFSET,
                    LF_MUHTARI_SNAPSHOT_R3_SAVEKEY_VALUE,
                    media[LF_MUHTARI_SNAPSHOT_FIXTURE_SAVEKEY_OFFSET], frame);
      (void)lf_destroy(&instance);
      return 1;
    }
  }
  if (oracle_controls != 0) {
    lf_muhtari_snapshot_expected_frame expected;
    char wrong_video[65];
    char wrong_pcm[65];
    const char *mismatch = NULL;
    if (!lf_muhtari_snapshot_expected(LF_MUHTARI_SNAPSHOT_R3_FRAME,
                                      &expected) ||
        !lf_muhtari_snapshot_fill_expected_battery(
            LF_MUHTARI_SNAPSHOT_R3_FRAME, expected_media)) {
      (void)lf_destroy(&instance);
      return fail("oracle-control expectations are unavailable",
                  LF_UNSUPPORTED);
    }
    memcpy(wrong_media, expected_media, sizeof(wrong_media));
    wrong_media[LF_MUHTARI_SNAPSHOT_FIXTURE_SAVEKEY_OFFSET] ^= UINT8_C(0x01);
    memcpy(wrong_video, expected.video_sha256, sizeof(wrong_video));
    wrong_video[0] = wrong_video[0] == '0' ? '1' : '0';
    memcpy(wrong_pcm, expected.pcm_sha256, sizeof(wrong_pcm));
    wrong_pcm[0] = wrong_pcm[0] == '0' ? '1' : '0';
    mismatch = lf_muhtari_snapshot_first_mismatch(
        video, audio, run_result.audio_produced_samples, media,
        LF_MUHTARI_SNAPSHOT_R3_FRAME, expected.audio_samples + 1U,
        expected.video_sha256, expected.pcm_sha256, expected_media);
    if (mismatch == NULL || strcmp(mismatch, "frame") != 0) {
      (void)lf_destroy(&instance);
      return fail("wrong frame-count oracle did not fail at frame assertion",
                  LF_UNSUPPORTED);
    }
    mismatch = lf_muhtari_snapshot_first_mismatch(
        video, audio, run_result.audio_produced_samples, media,
        LF_MUHTARI_SNAPSHOT_R3_FRAME, expected.audio_samples, wrong_video,
        expected.pcm_sha256, expected_media);
    if (mismatch == NULL || strcmp(mismatch, "video") != 0) {
      (void)lf_destroy(&instance);
      return fail("wrong video oracle did not fail at video assertion",
                  LF_UNSUPPORTED);
    }
    mismatch = lf_muhtari_snapshot_first_mismatch(
        video, audio, run_result.audio_produced_samples, media,
        LF_MUHTARI_SNAPSHOT_R3_FRAME, expected.audio_samples,
        expected.video_sha256, wrong_pcm, expected_media);
    if (mismatch == NULL || strcmp(mismatch, "audio") != 0) {
      (void)lf_destroy(&instance);
      return fail("wrong audio oracle did not fail at audio assertion",
                  LF_UNSUPPORTED);
    }
    mismatch = lf_muhtari_snapshot_first_mismatch(
        video, audio, run_result.audio_produced_samples, media,
        LF_MUHTARI_SNAPSHOT_R3_FRAME, expected.audio_samples,
        expected.video_sha256, expected.pcm_sha256, wrong_media);
    if (mismatch == NULL || strcmp(mismatch, "battery") != 0) {
      (void)lf_destroy(&instance);
      return fail("wrong battery oracle did not fail at full-span assertion",
                  LF_UNSUPPORTED);
    }
    (void)puts("muhtari_api8_fixture_oracle_controls: frame,video,audio,battery literals rejected");
  }
  status = lf_destroy(&instance);
  if (status != LF_OK || instance != NULL) {
    return fail("public instance destruction failed", status);
  }
  (void)puts("muhtari_api8_fixture_boundary: R2 frame 2 pending page and R3 frame 3 published; full-span literals verified");
  return 0;
}

static int snapshot_check_frame(lf_instance *instance, uint32_t frame,
                                uint32_t expected_buttons,
                                uint8_t *media, lf_media_info *media_info) {
  uint8_t video[LF_MUHTARI_API8_VIDEO_WIDTH * LF_MUHTARI_API8_VIDEO_HEIGHT];
  int16_t audio[LF_MUHTARI_API8_AUDIO_SAMPLES];
  lf_run_result run_result = {.struct_size = sizeof(run_result)};
  const lf_run_request run_request = {
      .struct_size = sizeof(run_request),
      .work_units = 1U,
      .video_data = video,
      .video_capacity_bytes = sizeof(video),
      .video_stride_bytes = LF_MUHTARI_API8_VIDEO_WIDTH,
      .audio_data = audio,
      .audio_capacity_samples = LF_MUHTARI_API8_AUDIO_SAMPLES,
  };
  lf_muhtari_snapshot_expected_frame expected;
  uint8_t expected_media[LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES];
  lf_status status = lf_advance(instance, &run_request, &run_result);
  if (status != LF_OK || run_result.actual_units != 1U ||
      run_result.cumulative_units != frame || run_result.video_valid != 1U ||
      run_result.audio_valid != 1U ||
      run_result.sampled_buttons != expected_buttons ||
      !lf_muhtari_snapshot_expected(frame, &expected) ||
      !lf_muhtari_snapshot_fill_expected_battery(frame, expected_media)) {
    (void)fprintf(stderr,
                  "muhtari_api8_snapshot_contract: frame %u advance metadata mismatch status=%d cumulative=%llu\n",
                  frame, (int)status,
                  (unsigned long long)run_result.cumulative_units);
    return 0;
  }
  status = lf_copy_media(instance, media,
                         LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES, media_info);
  if (status != LF_OK ||
      lf_muhtari_snapshot_first_mismatch(
          video, audio, run_result.audio_produced_samples, media, frame,
          expected.audio_samples, expected.video_sha256, expected.pcm_sha256,
          expected_media) != NULL) {
    (void)fprintf(stderr,
                  "muhtari_api8_snapshot_contract: frame %u independent video/audio oracle mismatch status=%d\n",
                  frame, (int)status);
    return 0;
  }
  if (memcmp(media, expected_media, sizeof(expected_media)) != 0) {
    (void)fprintf(stderr,
                  "muhtari_api8_snapshot_contract: frame %u full-span battery oracle mismatch\n",
                  frame);
    return 0;
  }
  return media_info->extent_bytes ==
             LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES &&
         media_info->identity != NULL &&
         strcmp(media_info->identity, "muhtari-battery-v1") == 0;
}

static int fresh_process_wrong_oracle_frame(
    lf_instance *instance, uint32_t frame, uint32_t expected_buttons,
    const char *wrong_oracle, uint8_t *media, lf_media_info *media_info,
    const char **observed_mismatch) {
  uint8_t video[LF_MUHTARI_API8_VIDEO_WIDTH * LF_MUHTARI_API8_VIDEO_HEIGHT];
  int16_t audio[LF_MUHTARI_API8_AUDIO_SAMPLES];
  uint8_t expected_media[LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES];
  uint8_t wrong_media[LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES];
  char wrong_video[65];
  char wrong_pcm[65];
  lf_run_result run_result = {.struct_size = sizeof(run_result)};
  const lf_run_request run_request = {
      .struct_size = sizeof(run_request),
      .work_units = 1U,
      .video_data = video,
      .video_capacity_bytes = sizeof(video),
      .video_stride_bytes = LF_MUHTARI_API8_VIDEO_WIDTH,
      .audio_data = audio,
      .audio_capacity_samples = LF_MUHTARI_API8_AUDIO_SAMPLES,
  };
  lf_muhtari_snapshot_expected_frame expected;
  const char *baseline_mismatch = NULL;
  const char *mismatch = NULL;

  if (instance == NULL || wrong_oracle == NULL || media == NULL ||
      media_info == NULL || observed_mismatch == NULL ||
      !lf_muhtari_snapshot_expected(frame, &expected) ||
      !lf_muhtari_snapshot_fill_expected_battery(frame, expected_media)) {
    return 0;
  }
  if (lf_advance(instance, &run_request, &run_result) != LF_OK ||
      run_result.actual_units != 1U ||
      run_result.cumulative_units != (uint64_t)frame ||
      run_result.video_valid != 1U || run_result.audio_valid != 1U ||
      run_result.sampled_buttons != expected_buttons ||
      lf_copy_media(instance, media,
                    LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES,
                    media_info) != LF_OK ||
      media_info->extent_bytes !=
          LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES ||
      media_info->identity == NULL ||
      strcmp(media_info->identity, "muhtari-battery-v1") != 0) {
    return 0;
  }
  baseline_mismatch = lf_muhtari_snapshot_first_mismatch(
      video, audio, run_result.audio_produced_samples, media, frame,
      expected.audio_samples, expected.video_sha256, expected.pcm_sha256,
      expected_media);
  if (baseline_mismatch != NULL) {
    return 0;
  }
  memcpy(wrong_video, expected.video_sha256, sizeof(wrong_video));
  memcpy(wrong_pcm, expected.pcm_sha256, sizeof(wrong_pcm));
  memcpy(wrong_media, expected_media, sizeof(wrong_media));
  if (strcmp(wrong_oracle, "frame") == 0) {
    mismatch = lf_muhtari_snapshot_first_mismatch(
        video, audio, run_result.audio_produced_samples, media, frame,
        expected.audio_samples + 1U, expected.video_sha256,
        expected.pcm_sha256, expected_media);
  } else if (strcmp(wrong_oracle, "video") == 0) {
    wrong_video[0] = wrong_video[0] == '0' ? '1' : '0';
    mismatch = lf_muhtari_snapshot_first_mismatch(
        video, audio, run_result.audio_produced_samples, media, frame,
        expected.audio_samples, wrong_video, expected.pcm_sha256,
        expected_media);
  } else if (strcmp(wrong_oracle, "audio") == 0) {
    wrong_pcm[0] = wrong_pcm[0] == '0' ? '1' : '0';
    mismatch = lf_muhtari_snapshot_first_mismatch(
        video, audio, run_result.audio_produced_samples, media, frame,
        expected.audio_samples, expected.video_sha256, wrong_pcm,
        expected_media);
  } else if (strcmp(wrong_oracle, "media") == 0) {
    wrong_media[LF_MUHTARI_SNAPSHOT_FIXTURE_SAVEKEY_OFFSET] ^= UINT8_C(0x01);
    mismatch = lf_muhtari_snapshot_first_mismatch(
        video, audio, run_result.audio_produced_samples, media, frame,
        expected.audio_samples, expected.video_sha256,
        expected.pcm_sha256, wrong_media);
  } else {
    return 0;
  }
  if (mismatch == NULL ||
      strcmp(mismatch,
             strcmp(wrong_oracle, "media") == 0 ? "battery" : wrong_oracle) !=
          0) {
    return 0;
  }
  *observed_mismatch = mismatch;
  return 1;
}

static int snapshot_buffer_matches(lf_instance *instance, const uint8_t *prior,
                                   size_t extent_bytes) {
  uint8_t *current = (uint8_t *)malloc(extent_bytes);
  int matches = 0;
  if (current == NULL) {
    return 0;
  }
  if (lf_capture_snapshot(instance, current, extent_bytes) == LF_OK) {
    matches = memcmp(current, prior, extent_bytes) == 0;
  }
  free(current);
  return matches;
}

static int snapshot_contract(void) {
  uint8_t content[LF_MUHTARI_FIXTURE_TOTAL_BYTES];
  uint8_t altered_content[LF_MUHTARI_FIXTURE_TOTAL_BYTES];
  uint8_t media[LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES];
  uint8_t expected_media[LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES];
  uint8_t *snapshot = NULL;
  uint8_t *snapshot_with_canary = NULL;
  uint8_t *baseline = NULL;
  uint32_t supported = 0U;
  size_t required_bytes = 0U;
  lf_instance *producer = NULL;
  lf_instance *receiver = NULL;
  lf_instance *default_route = NULL;
  lf_instance *wrong_content = NULL;
  lf_load_result load_result = {.struct_size = sizeof(load_result)};
  lf_media_info media_info = {.struct_size = sizeof(media_info)};
  lf_status status = LF_OK;
  const lf_load_request load_request = {
      .struct_size = sizeof(load_request),
      .content_data = content,
      .content_size_bytes = sizeof(content),
      .configuration_id = LF_MUHTARI_API8_CONFIGURATION,
  };

  status = lf_get_capability(LF_MUHTARI_API8_PROFILE,
                             LF_MUHTARI_API8_CONFIGURATION,
                             LF_CAP_SNAPSHOT, &supported);
  if (status != LF_OK || supported != 1U) {
    (void)fprintf(stderr,
                  "muhtari_api8_snapshot_contract: selected API 8 battery configuration expected supported=1, status=%d supported=%u\n",
                  (int)status, supported);
    return 1;
  }
  supported = 99U;
  status = lf_get_capability(LF_MUHTARI_API8_PROFILE, NULL,
                             LF_CAP_SNAPSHOT, &supported);
  if (status != LF_UNSUPPORTED || supported != 0U) {
    return fail("default API 8 configuration unexpectedly advertises snapshots",
                status);
  }
  if (lf_build_muhtari_snapshot_fixture(content, sizeof(content)) !=
      sizeof(content)) {
    return fail("generated A78 fixture construction failed", LF_INVALID_ARGUMENT);
  }
  memcpy(altered_content, content, sizeof(content));
  altered_content[17U] ^= UINT8_C(0x01);

  status = lf_create(LF_MUHTARI_API8_PROFILE, NULL, &producer);
  if (status != LF_OK || producer == NULL) {
    return fail("snapshot producer creation failed", status);
  }
  if (lf_get_snapshot_size(producer, &required_bytes) != LF_INVALID_ARGUMENT ||
      lf_capture_snapshot(producer, content, sizeof(content)) !=
          LF_INVALID_ARGUMENT ||
      lf_restore_snapshot(producer, content, sizeof(content)) !=
          LF_INVALID_ARGUMENT ||
      lf_get_snapshot_size(producer, NULL) != LF_INVALID_ARGUMENT ||
      lf_capture_snapshot(producer, NULL, 0U) != LF_INVALID_ARGUMENT ||
      lf_restore_snapshot(producer, NULL, 0U) != LF_INVALID_ARGUMENT) {
    (void)lf_destroy(&producer);
    return fail("pre-load snapshot operation did not reject", LF_UNSUPPORTED);
  }
  status = lf_load(producer, &load_request, &load_result);
  if (status != LF_OK || load_result.loaded != 1U) {
    (void)lf_destroy(&producer);
    return fail("snapshot producer fixture load failed", status);
  }
  if (!snapshot_check_frame(producer, 1U, 0U, media, &media_info) ||
      !snapshot_check_frame(producer, LF_MUHTARI_SNAPSHOT_R2_FRAME, 0U, media,
                            &media_info)) {
    (void)lf_destroy(&producer);
    return 1;
  }
  if (!lf_muhtari_snapshot_fill_expected_battery(
          LF_MUHTARI_SNAPSHOT_R2_FRAME, expected_media) ||
      lf_copy_media(producer, media, sizeof(media), &media_info) != LF_OK ||
      memcmp(media, expected_media, sizeof(media)) != 0 ||
      media_info.guest_generation != LF_MUHTARI_SNAPSHOT_R2_GENERATION) {
    (void)lf_destroy(&producer);
    return fail("producer did not reach literal R2 battery state",
                LF_UNSUPPORTED);
  }
  {
    const lf_input pending_input = {.struct_size = sizeof(pending_input),
                                    .buttons = 1U};
    status = lf_set_input(producer, &pending_input);
    if (status != LF_OK) {
      (void)lf_destroy(&producer);
      return fail("pending snapshot input setup failed", status);
    }
  }
  status = lf_get_snapshot_size(producer, &required_bytes);
  if (status != LF_OK ||
      required_bytes <= LF_MUHTARI_HOST_SNAPSHOT_HEADER_BYTES ||
      required_bytes > 128U * 1024U * 1024U) {
    (void)lf_destroy(&producer);
    return fail("qualified snapshot size query failed", status);
  }
  {
    uint8_t short_buffer[64];
    int short_buffer_unchanged = 1;
    memset(short_buffer, 0xA5, sizeof(short_buffer));
    if (lf_capture_snapshot(producer, short_buffer, sizeof(short_buffer)) !=
        LF_BUFFER_TOO_SMALL) {
      short_buffer_unchanged = 0;
    }
    for (size_t index = 0U; index < sizeof(short_buffer); ++index) {
      if (short_buffer[index] != 0xA5U) {
        short_buffer_unchanged = 0;
      }
    }
    if (!short_buffer_unchanged) {
      (void)lf_destroy(&producer);
      return fail("short snapshot capture changed caller bytes",
                  LF_UNSUPPORTED);
    }
  }
  if (lf_capture_snapshot(producer, NULL, 0U) != LF_INVALID_ARGUMENT ||
      lf_restore_snapshot(producer, NULL, required_bytes) !=
          LF_INVALID_ARGUMENT) {
    (void)lf_destroy(&producer);
    return fail("null snapshot input was not rejected", LF_UNSUPPORTED);
  }
  snapshot_with_canary = (uint8_t *)malloc(required_bytes + 32U);
  if (snapshot_with_canary == NULL) {
    (void)lf_destroy(&producer);
    return fail("snapshot caller buffer allocation failed", LF_RESOURCE_EXHAUSTED);
  }
  memset(snapshot_with_canary, 0xA5, required_bytes + 32U);
  if (lf_capture_snapshot(producer, snapshot_with_canary,
                          required_bytes + 32U) != LF_OK) {
    free(snapshot_with_canary);
    (void)lf_destroy(&producer);
    return fail("qualified snapshot capture failed", LF_UNSUPPORTED);
  }
  for (size_t index = required_bytes; index < required_bytes + 32U; ++index) {
    if (snapshot_with_canary[index] != 0xA5U) {
      free(snapshot_with_canary);
      (void)lf_destroy(&producer);
      return fail("snapshot capture overwrote caller suffix", LF_UNSUPPORTED);
    }
  }
  snapshot = (uint8_t *)malloc(required_bytes);
  if (snapshot == NULL) {
    free(snapshot_with_canary);
    (void)lf_destroy(&producer);
    return fail("snapshot caller buffer allocation failed", LF_RESOURCE_EXHAUSTED);
  }
  memcpy(snapshot, snapshot_with_canary, required_bytes);
  if (lf_get_snapshot_size(producer, &required_bytes) != LF_OK ||
      lf_capture_snapshot(producer, snapshot_with_canary,
                          required_bytes + 32U) != LF_OK ||
      memcmp(snapshot_with_canary, snapshot, required_bytes) != 0 ||
      lf_copy_media(producer, media, sizeof(media), &media_info) != LF_OK ||
      media_info.guest_generation != LF_MUHTARI_SNAPSHOT_R2_GENERATION ||
      memcmp(media, expected_media, sizeof(media)) != 0) {
    free(snapshot);
    free(snapshot_with_canary);
    (void)lf_destroy(&producer);
    return fail("size/capture advanced or changed the R2 machine state",
                LF_UNSUPPORTED);
  }
  free(snapshot_with_canary);
  snapshot_with_canary = NULL;

  if (!snapshot_check_frame(producer, LF_MUHTARI_SNAPSHOT_R3_FRAME, 1U, media,
                            &media_info)) {
    free(snapshot);
    (void)lf_destroy(&producer);
    return 1;
  }
  {
    const uint64_t generation_after_r3 = media_info.guest_generation;
    status = lf_restore_snapshot(producer, snapshot, required_bytes);
    if (status != LF_OK ||
        lf_copy_media(producer, media, sizeof(media), &media_info) != LF_OK ||
        memcmp(media, expected_media, sizeof(media)) != 0 ||
        media_info.guest_generation != generation_after_r3 + 1U) {
      free(snapshot);
      (void)lf_destroy(&producer);
      return fail("changed restore did not apply one receiver-local generation",
                  status);
    }
    status = lf_restore_snapshot(producer, snapshot, required_bytes);
    if (status != LF_OK ||
        lf_copy_media(producer, media, sizeof(media), &media_info) != LF_OK ||
        media_info.guest_generation != generation_after_r3 + 1U) {
      free(snapshot);
      (void)lf_destroy(&producer);
      return fail("identical battery restore changed receiver-local generation",
                  status);
    }
  }
  if (!snapshot_check_frame(producer, LF_MUHTARI_SNAPSHOT_R3_FRAME, 1U, media,
                            &media_info)) {
    free(snapshot);
    (void)lf_destroy(&producer);
    return 1;
  }
  status = lf_load(producer, &load_request, &load_result);
  if (status != LF_OK ||
      lf_restore_snapshot(producer, snapshot, required_bytes) !=
          LF_INVALID_ARGUMENT ||
      lf_copy_media(producer, media, sizeof(media), &media_info) != LF_OK) {
    free(snapshot);
    (void)lf_destroy(&producer);
    return fail("same-instance stale-load snapshot was not rejected", status);
  }
  for (size_t index = 0U; index < sizeof(media); ++index) {
    if (media[index] != UINT8_C(0xFF)) {
      free(snapshot);
      (void)lf_destroy(&producer);
      return fail("stale snapshot rejection changed reloaded media",
                  LF_UNSUPPORTED);
    }
  }
  {
    uint8_t *mutated_snapshot = (uint8_t *)malloc(required_bytes);
    if (mutated_snapshot == NULL) {
      free(snapshot);
      (void)lf_destroy(&producer);
      return fail("stale snapshot identity mutation allocation failed",
                  LF_RESOURCE_EXHAUSTED);
    }
    memcpy(mutated_snapshot, snapshot, required_bytes);
    mutated_snapshot[316U] ^= UINT8_C(0x01);
    status = lf_restore_snapshot(producer, mutated_snapshot, required_bytes);
    free(mutated_snapshot);
    if (status != LF_INVALID_ARGUMENT ||
        lf_copy_media(producer, media, sizeof(media), &media_info) != LF_OK) {
      free(snapshot);
      (void)lf_destroy(&producer);
      return fail("mutated stale snapshot identity was not rejected", status);
    }
    for (size_t index = 0U; index < sizeof(media); ++index) {
      if (media[index] != UINT8_C(0xFF)) {
        free(snapshot);
        (void)lf_destroy(&producer);
        return fail("mutated stale snapshot changed reloaded media",
                    LF_UNSUPPORTED);
      }
    }
  }
  status = lf_destroy(&producer);
  if (status != LF_OK || producer != NULL) {
    free(snapshot);
    return fail("snapshot producer destruction failed", status);
  }

  status = lf_create(LF_MUHTARI_API8_PROFILE, NULL, &receiver);
  if (status != LF_OK || receiver == NULL) {
    free(snapshot);
    return fail("snapshot receiver creation failed", status);
  }
  status = lf_load(receiver, &load_request, &load_result);
  if (status != LF_OK || load_result.loaded != 1U) {
    free(snapshot);
    (void)lf_destroy(&receiver);
    return fail("snapshot receiver fixture load failed", status);
  }
  status = lf_get_snapshot_size(receiver, &required_bytes);
  if (status != LF_OK) {
    free(snapshot);
    (void)lf_destroy(&receiver);
    return fail("receiver snapshot size query failed", status);
  }
  baseline = (uint8_t *)malloc(required_bytes);
  if (baseline == NULL ||
      lf_capture_snapshot(receiver, baseline, required_bytes) != LF_OK) {
    free(baseline);
    free(snapshot);
    (void)lf_destroy(&receiver);
    return fail("receiver baseline snapshot failed", LF_RESOURCE_EXHAUSTED);
  }
  {
    uint8_t *mutated = (uint8_t *)malloc(required_bytes);
    if (mutated == NULL) {
      free(baseline);
      free(snapshot);
      (void)lf_destroy(&receiver);
      return fail("snapshot mutation buffer allocation failed",
                  LF_RESOURCE_EXHAUSTED);
    }
    memcpy(mutated, snapshot, required_bytes);
    mutated[220U] ^= UINT8_C(0x01);
    if (lf_restore_snapshot(receiver, mutated, required_bytes) !=
            LF_INVALID_ARGUMENT ||
        !snapshot_buffer_matches(receiver, baseline, required_bytes)) {
      free(mutated);
      free(baseline);
      free(snapshot);
      (void)lf_destroy(&receiver);
      return fail("configuration identity preflight mutated receiver",
                  LF_UNSUPPORTED);
    }
    memcpy(mutated, snapshot, required_bytes);
    mutated[44U] ^= UINT8_C(0x01);
    if (lf_restore_snapshot(receiver, mutated, required_bytes) !=
            LF_INVALID_ARGUMENT ||
        !snapshot_buffer_matches(receiver, baseline, required_bytes)) {
      free(mutated);
      free(baseline);
      free(snapshot);
      (void)lf_destroy(&receiver);
      return fail("build identity preflight mutated receiver", LF_UNSUPPORTED);
    }
    memcpy(mutated, snapshot, required_bytes);
    mutated[16U] ^= UINT8_C(0x01);
    if (lf_restore_snapshot(receiver, mutated, required_bytes) !=
            LF_INVALID_ARGUMENT ||
        !snapshot_buffer_matches(receiver, baseline, required_bytes)) {
      free(mutated);
      free(baseline);
      free(snapshot);
      (void)lf_destroy(&receiver);
      return fail("envelope extent preflight mutated receiver",
                  LF_UNSUPPORTED);
    }
    memcpy(mutated, snapshot, required_bytes);
    mutated[376U] = 0x80U;
    if (lf_restore_snapshot(receiver, mutated, required_bytes) !=
            LF_INVALID_ARGUMENT ||
        !snapshot_buffer_matches(receiver, baseline, required_bytes)) {
      free(mutated);
      free(baseline);
      free(snapshot);
      (void)lf_destroy(&receiver);
      return fail("continuation preflight mutated receiver", LF_UNSUPPORTED);
    }
    memcpy(mutated, snapshot, required_bytes);
    mutated[372U] = 0x02U;
    if (lf_restore_snapshot(receiver, mutated, required_bytes) !=
            LF_INVALID_ARGUMENT ||
        !snapshot_buffer_matches(receiver, baseline, required_bytes)) {
      free(mutated);
      free(baseline);
      free(snapshot);
      (void)lf_destroy(&receiver);
      return fail("pending-input preflight mutated receiver", LF_UNSUPPORTED);
    }
    memcpy(mutated, snapshot, required_bytes);
    mutated[required_bytes - 1U] ^= UINT8_C(0x01);
    if (lf_restore_snapshot(receiver, mutated, required_bytes) !=
            LF_INVALID_ARGUMENT ||
        !snapshot_buffer_matches(receiver, baseline, required_bytes)) {
      free(mutated);
      free(baseline);
      free(snapshot);
      (void)lf_destroy(&receiver);
      return fail("native state rejection mutated receiver", LF_UNSUPPORTED);
    }
    free(mutated);
  }
  if (lf_restore_snapshot(receiver, snapshot, required_bytes - 1U) !=
          LF_INVALID_ARGUMENT ||
      lf_restore_snapshot(receiver, snapshot, SIZE_MAX) != LF_LIMIT_EXCEEDED ||
      !snapshot_buffer_matches(receiver, baseline, required_bytes)) {
    free(baseline);
    free(snapshot);
    (void)lf_destroy(&receiver);
    return fail("invalid snapshot extents changed receiver", LF_UNSUPPORTED);
  }
  status = lf_restore_snapshot(receiver, snapshot, required_bytes);
  if (status != LF_OK ||
      !lf_muhtari_snapshot_fill_expected_battery(
          LF_MUHTARI_SNAPSHOT_R2_FRAME, expected_media) ||
      lf_copy_media(receiver, media, sizeof(media), &media_info) != LF_OK ||
      memcmp(media, expected_media, sizeof(media)) != 0 ||
      media_info.guest_generation != 1U) {
    free(baseline);
    free(snapshot);
    (void)lf_destroy(&receiver);
    return fail("new instance failed exact-content snapshot restore", status);
  }
  status = lf_restore_snapshot(receiver, snapshot, required_bytes);
  if (status != LF_OK ||
      lf_copy_media(receiver, media, sizeof(media), &media_info) != LF_OK ||
      media_info.guest_generation != 1U ||
      lf_import_media(receiver, media_info.identity, media, sizeof(media)) !=
          LF_INVALID_ARGUMENT) {
    free(baseline);
    free(snapshot);
    (void)lf_destroy(&receiver);
    return fail("identical restore or restored import lifecycle mismatch",
                status);
  }
  free(baseline);
  baseline = NULL;
  if (!snapshot_check_frame(receiver, LF_MUHTARI_SNAPSHOT_R3_FRAME, 1U, media,
                            &media_info)) {
    free(snapshot);
    (void)lf_destroy(&receiver);
    return 1;
  }
  status = lf_destroy(&receiver);
  if (status != LF_OK || receiver != NULL) {
    return fail("snapshot receiver destruction failed", status);
  }

  status = lf_create(LF_MUHTARI_API8_PROFILE, NULL, &default_route);
  if (status != LF_OK || default_route == NULL) {
    return fail("default route instance creation failed", status);
  }
  {
    const lf_load_request default_request = {
        .struct_size = sizeof(default_request),
        .content_data = content,
        .content_size_bytes = sizeof(content),
        .configuration_id = NULL,
    };
    status = lf_load(default_route, &default_request, &load_result);
  }
  if (status != LF_OK ||
      lf_get_snapshot_size(default_route, &required_bytes) != LF_UNSUPPORTED ||
      lf_restore_snapshot(default_route, snapshot, required_bytes) !=
          LF_UNSUPPORTED) {
    (void)lf_destroy(&default_route);
    return fail("default configuration unexpectedly qualified for snapshots",
                status);
  }
  (void)lf_destroy(&default_route);

  status = lf_create(LF_MUHTARI_API8_PROFILE, NULL, &wrong_content);
  if (status != LF_OK || wrong_content == NULL) {
    return fail("wrong-content instance creation failed", status);
  }
  {
    const lf_load_request wrong_request = {
        .struct_size = sizeof(wrong_request),
        .content_data = altered_content,
        .content_size_bytes = sizeof(altered_content),
        .configuration_id = LF_MUHTARI_API8_CONFIGURATION,
    };
    status = lf_load(wrong_content, &wrong_request, &load_result);
  }
  if (status != LF_OK ||
      lf_get_snapshot_size(wrong_content, &required_bytes) != LF_UNSUPPORTED ||
      lf_restore_snapshot(wrong_content, snapshot, required_bytes) !=
          LF_UNSUPPORTED) {
    (void)lf_destroy(&wrong_content);
    return fail("non-qualified content unexpectedly qualified for snapshots",
                status);
  }
  (void)lf_destroy(&wrong_content);
  free(snapshot);

  (void)puts("muhtari_api8_snapshot_contract: capability, bounded capture, identity preflight, cross-instance replay, stale-load rejection, and receiver-local battery generation verified");
  return 0;
}

static unsigned int fresh_process_snapshot_operation_calls = 0U;
static const char *fresh_process_capability_override = NULL;

static lf_status fresh_process_get_snapshot_size(
    lf_instance *instance, size_t *required_bytes) {
  ++fresh_process_snapshot_operation_calls;
  return lf_get_snapshot_size(instance, required_bytes);
}

static lf_status fresh_process_capture_snapshot(
    lf_instance *instance, uint8_t *destination, size_t capacity_bytes) {
  ++fresh_process_snapshot_operation_calls;
  return lf_capture_snapshot(instance, destination, capacity_bytes);
}

static lf_status fresh_process_restore_snapshot(
    lf_instance *instance, const uint8_t *source, size_t extent_bytes) {
  ++fresh_process_snapshot_operation_calls;
  return lf_restore_snapshot(instance, source, extent_bytes);
}

/* These interception wrappers are local to this consumer test executable. */
#define lf_get_snapshot_size(instance, required_bytes) \
  fresh_process_get_snapshot_size((instance), (required_bytes))
#define lf_capture_snapshot(instance, destination, capacity_bytes) \
  fresh_process_capture_snapshot((instance), (destination), (capacity_bytes))
#define lf_restore_snapshot(instance, source, extent_bytes) \
  fresh_process_restore_snapshot((instance), (source), (extent_bytes))

static int fresh_process_capability(const char *stage) {
  uint32_t supported = 0U;
  lf_status status = lf_get_capability(
      LF_MUHTARI_API8_PROFILE, LF_MUHTARI_API8_CONFIGURATION,
      LF_CAP_SNAPSHOT, &supported);
  if (fresh_process_capability_override != NULL &&
      strcmp(fresh_process_capability_override, "deny-status") == 0) {
    status = LF_UNSUPPORTED;
  } else if (fresh_process_capability_override != NULL &&
             strcmp(fresh_process_capability_override,
                    "deny-supported") == 0) {
    status = LF_OK;
    supported = 0U;
  }
  (void)printf("event=capability stage=%s status=%d supported=%u\n", stage,
               (int)status, supported);
  if (status != LF_OK || supported != 1U) {
    if (fresh_process_capability_override != NULL &&
        fresh_process_snapshot_operation_calls == 0U) {
      (void)printf("event=capability-control stage=%s mode=%s status=%d supported=%u snapshot-calls=0 result=pass\n",
                   stage, fresh_process_capability_override, (int)status,
                   supported);
    }
    (void)fprintf(stderr,
                  "muhtari_api8_process_%s: snapshot capability must be supported before snapshot operations status=%d supported=%u\n",
                  stage, (int)status, supported);
    return 0;
  }
  return 1;
}

static int fresh_process_load(const uint8_t *content, lf_instance **instance,
                              lf_load_result *load_result) {
  const lf_load_request load_request = {
      .struct_size = sizeof(load_request),
      .content_data = content,
      .content_size_bytes = LF_MUHTARI_FIXTURE_TOTAL_BYTES,
      .configuration_id = LF_MUHTARI_API8_CONFIGURATION,
  };
  lf_status status = lf_create(LF_MUHTARI_API8_PROFILE, NULL, instance);
  if (status != LF_OK || *instance == NULL) {
    (void)fprintf(stderr,
                  "muhtari_api8_process: public API 8 instance creation failed status=%d\n",
                  (int)status);
    return 0;
  }
  status = lf_load(*instance, &load_request, load_result);
  if (status != LF_OK || load_result->loaded != 1U ||
      load_result->content_size_bytes !=
          LF_MUHTARI_FIXTURE_TOTAL_BYTES ||
      load_result->effective_configuration_id == NULL ||
      strcmp(load_result->effective_configuration_id,
             LF_MUHTARI_API8_CONFIGURATION) != 0) {
    (void)fprintf(stderr,
                  "muhtari_api8_process: exact generated fixture load failed status=%d\n",
                  (int)status);
    (void)lf_destroy(instance);
    return 0;
  }
  return 1;
}

static int fresh_process_media_is(lf_instance *instance,
                                  const uint8_t *expected_media,
                                  lf_media_info *media_info,
                                  uint64_t *generation_out) {
  uint8_t media[LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES] = {0U};
  const lf_status status =
      lf_copy_media(instance, media, sizeof(media), media_info);
  if (status != LF_OK) {
    (void)fprintf(stderr,
                  "muhtari_api8_process: battery span copy failed status=%d\n",
                  (int)status);
    return 0;
  }
  const int extent_matches = media_info->extent_bytes == sizeof(media);
  const int identity_matches =
      media_info->identity != NULL &&
      strcmp(media_info->identity, "muhtari-battery-v1") == 0;
  const int payload_matches = memcmp(media, expected_media, sizeof(media)) == 0;
  if (!extent_matches || !identity_matches || !payload_matches) {
    uint8_t actual_digest[32];
    uint8_t expected_digest[32];
    char actual_hex[65];
    char expected_hex[65];
    lf_muhtari_host_digest(media, sizeof(media), actual_digest);
    lf_muhtari_host_digest(expected_media, sizeof(media), expected_digest);
    lf_muhtari_host_hex(actual_digest, actual_hex);
    lf_muhtari_host_hex(expected_digest, expected_hex);
    (void)fprintf(stderr,
                  "muhtari_api8_process: complete battery span mismatch extent=%d identity=%d payload=%d actual-sha256=%s expected-sha256=%s\n",
                  extent_matches, identity_matches,
                  payload_matches, actual_hex, expected_hex);
    return 0;
  }
  if (generation_out != NULL) {
    *generation_out = media_info->guest_generation;
  }
  return 1;
}

static int fresh_process_host_custody_matches(
    const char *save_path, const char *ack_path, const uint8_t *save_baseline,
    const uint8_t *ack_baseline, size_t ack_extent) {
  uint8_t *save = NULL;
  uint8_t *ack = NULL;
  int matches = 0;
  if (save_baseline == NULL || ack_baseline == NULL || ack_extent == 0U ||
      !lf_muhtari_host_read_exact_file(
          save_path, LF_MUHTARI_HOST_SAVE_TOTAL_BYTES,
          LF_MUHTARI_HOST_SAVE_TOTAL_BYTES, &save) ||
      !lf_muhtari_host_read_exact_file(ack_path, ack_extent, 160U, &ack)) {
    goto cleanup;
  }
  matches =
      memcmp(save, save_baseline, LF_MUHTARI_HOST_SAVE_TOTAL_BYTES) == 0 &&
      memcmp(ack, ack_baseline, ack_extent) == 0;

cleanup:
  free(save);
  free(ack);
  return matches;
}

static int fresh_process_run_refusal_case(
    const lf_muhtari_snapshot_fault_case *fault_case,
    const uint8_t *content, const uint8_t *checkpoint, size_t checkpoint_bytes,
    const uint8_t *expected_r2, const uint8_t *expected_r3,
    const uint8_t *r3_save_baseline, const uint8_t *r3_ack_baseline,
    size_t r3_ack_bytes, const char *save_path, const char *ack_path) {
  lf_instance *subject = NULL;
  lf_instance *control = NULL;
  lf_load_result subject_load = {.struct_size = sizeof(subject_load)};
  lf_load_result control_load = {.struct_size = sizeof(control_load)};
  lf_media_info subject_info = {.struct_size = sizeof(subject_info)};
  lf_media_info control_info = {.struct_size = sizeof(control_info)};
  uint8_t subject_media[LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES];
  uint8_t control_media[LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES];
  uint8_t *candidate = NULL;
  size_t candidate_bytes = checkpoint_bytes;
  uint64_t subject_generation = 0U;
  uint64_t control_generation = 0U;
  lf_status status = LF_OK;
  int semantic_candidate_valid = 0;
  int ok = 0;

  if (fault_case == NULL || content == NULL || checkpoint == NULL ||
      expected_r2 == NULL || expected_r3 == NULL ||
      !fresh_process_load(content, &subject, &subject_load) ||
      !fresh_process_load(content, &control, &control_load)) {
    goto cleanup;
  }
  status = lf_import_media(subject, "muhtari-battery-v1", expected_r3,
                           LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES);
  if (status != LF_OK ||
      !fresh_process_media_is(subject, expected_r3, &subject_info,
                              &subject_generation)) {
    goto cleanup;
  }
  status = lf_import_media(control, "muhtari-battery-v1", expected_r3,
                           LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES);
  if (status != LF_OK ||
      !fresh_process_media_is(control, expected_r3, &control_info,
                              &control_generation)) {
    goto cleanup;
  }
  status = lf_restore_snapshot(subject, checkpoint, checkpoint_bytes);
  if (status != LF_OK ||
      !fresh_process_media_is(subject, expected_r2, &subject_info,
                              &subject_generation)) {
    goto cleanup;
  }
  status = lf_restore_snapshot(control, checkpoint, checkpoint_bytes);
  if (status != LF_OK ||
      !fresh_process_media_is(control, expected_r2, &control_info,
                              &control_generation) ||
      subject_generation != control_generation) {
    goto cleanup;
  }
  if (!lf_muhtari_snapshot_fault_make(checkpoint, checkpoint_bytes,
                                       fault_case->fault, &candidate,
                                       &candidate_bytes)) {
    goto cleanup;
  }
  if (fault_case->fault == LF_MUHTARI_FAULT_ZERO_EXTENT) {
    candidate = (uint8_t *)checkpoint;
    candidate_bytes = 0U;
  } else if (fault_case->fault == LF_MUHTARI_FAULT_NULL_ZERO_EXTENT) {
    candidate = NULL;
    candidate_bytes = 0U;
  } else if (fault_case->fault == LF_MUHTARI_FAULT_OVERFLOW_TOTAL) {
    candidate = (uint8_t *)checkpoint;
    candidate_bytes = SIZE_MAX;
  }
  if (fault_case->fault == LF_MUHTARI_FAULT_NATIVE_SEMANTIC_INVALID) {
    semantic_candidate_valid =
        lf_muhtari_snapshot_fault_semantic_candidate_valid(candidate,
                                                           candidate_bytes);
    if (!semantic_candidate_valid) {
      goto cleanup;
    }
  }
  status = lf_restore_snapshot(subject, candidate, candidate_bytes);
  if (status != fault_case->expected_status ||
      !fresh_process_media_is(subject, expected_r2, &subject_info,
                              &control_generation) ||
      control_generation != subject_generation ||
      !fresh_process_host_custody_matches(
          save_path, ack_path, r3_save_baseline, r3_ack_baseline,
          r3_ack_bytes)) {
    goto cleanup;
  }
  if (!snapshot_check_frame(subject, LF_MUHTARI_SNAPSHOT_R3_FRAME, 1U,
                            subject_media, &subject_info) ||
      !snapshot_check_frame(control, LF_MUHTARI_SNAPSHOT_R3_FRAME, 1U,
                            control_media, &control_info) ||
      memcmp(subject_media, control_media, sizeof(subject_media)) != 0 ||
      subject_info.guest_generation != control_info.guest_generation ||
      !fresh_process_host_custody_matches(
          save_path, ack_path, r3_save_baseline, r3_ack_baseline,
          r3_ack_bytes)) {
    goto cleanup;
  }
  if (semantic_candidate_valid != 0) {
    (void)printf("event=battery-b-refusal name=%s status=%d outer=valid native-checksum=valid validator=invalid-state preservation=continuation,full-media,generation,selected-save,ack result=pass\n",
                 fault_case->name, (int)status);
  } else {
    (void)printf("event=battery-b-refusal name=%s status=%d preservation=continuation,full-media,generation,selected-save,ack result=pass\n",
                 fault_case->name, (int)status);
  }
  ok = 1;

cleanup:
  if (candidate != checkpoint) {
    free(candidate);
  }
  if (subject != NULL && lf_destroy(&subject) != LF_OK) {
    ok = 0;
  }
  if (control != NULL && lf_destroy(&control) != LF_OK) {
    ok = 0;
  }
  return ok;
}

static int fresh_process_run_refusal_matrix(
    const uint8_t *content, const uint8_t *checkpoint, size_t checkpoint_bytes,
    const uint8_t *expected_r2, const uint8_t *expected_r3,
    const uint8_t *r3_save_baseline, const uint8_t *r3_ack_baseline,
    size_t r3_ack_bytes, const char *save_path, const char *ack_path) {
  if (!lf_muhtari_snapshot_fault_crc_known_vector()) {
    (void)fprintf(stderr,
                  "muhtari_api8_process_b: test-only CRC32 known-vector check failed\n");
    return 0;
  }
  for (size_t index = 0U;
       index < sizeof(lf_muhtari_snapshot_fault_cases) /
                   sizeof(lf_muhtari_snapshot_fault_cases[0]);
       ++index) {
    if (!fresh_process_run_refusal_case(
            &lf_muhtari_snapshot_fault_cases[index], content, checkpoint,
            checkpoint_bytes, expected_r2, expected_r3, r3_save_baseline,
            r3_ack_baseline, r3_ack_bytes, save_path, ack_path)) {
      (void)fprintf(stderr,
                    "muhtari_api8_process_b: refusal case %s failed expected-status=%d\n",
                    lf_muhtari_snapshot_fault_cases[index].name,
                    (int)lf_muhtari_snapshot_fault_cases[index].expected_status);
      return 0;
    }
  }
  return 1;
}

static int fresh_process_run_same_length_content_refusal(
    const uint8_t *content, const uint8_t *checkpoint, size_t checkpoint_bytes,
    const uint8_t *r3_save_baseline, const uint8_t *r3_ack_baseline,
    size_t r3_ack_bytes, const char *save_path, const char *ack_path) {
  uint8_t altered[LF_MUHTARI_FIXTURE_TOTAL_BYTES];
  uint8_t after_media[LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES];
  uint8_t default_media[LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES];
  uint8_t video[LF_MUHTARI_API8_VIDEO_WIDTH * LF_MUHTARI_API8_VIDEO_HEIGHT];
  int16_t audio[LF_MUHTARI_API8_AUDIO_SAMPLES];
  uint8_t baseline_digest[32];
  uint8_t altered_digest[32];
  lf_instance *instance = NULL;
  lf_load_result load_result = {.struct_size = sizeof(load_result)};
  lf_media_info media_info = {.struct_size = sizeof(media_info)};
  lf_run_result run_result = {.struct_size = sizeof(run_result)};
  const lf_run_request run_request = {
      .struct_size = sizeof(run_request),
      .work_units = 1U,
      .video_data = video,
      .video_capacity_bytes = sizeof(video),
      .video_stride_bytes = LF_MUHTARI_API8_VIDEO_WIDTH,
      .audio_data = audio,
      .audio_capacity_samples = LF_MUHTARI_API8_AUDIO_SAMPLES,
  };
  lf_muhtari_snapshot_expected_frame expected_frame;
  const char *mismatch = NULL;
  lf_status status = LF_OK;
  uint64_t before_generation = 0U;
  int ok = 0;

  if (content == NULL || checkpoint == NULL || r3_save_baseline == NULL ||
      r3_ack_baseline == NULL ||
      !lf_muhtari_snapshot_fill_expected_battery(1U, default_media)) {
    goto cleanup;
  }
  memcpy(altered, content, sizeof(altered));
  altered[17U] ^= UINT8_C(0x01);
  lf_muhtari_host_digest(content, sizeof(altered), baseline_digest);
  lf_muhtari_host_digest(altered, sizeof(altered), altered_digest);
  if (sizeof(altered) != LF_MUHTARI_FIXTURE_TOTAL_BYTES ||
      memcmp(baseline_digest, altered_digest, sizeof(baseline_digest)) == 0 ||
      !fresh_process_load(altered, &instance, &load_result)) {
    goto cleanup;
  }
  if (!fresh_process_media_is(instance, default_media, &media_info,
                              &before_generation)) {
    goto cleanup;
  }
  status = lf_restore_snapshot(instance, checkpoint, checkpoint_bytes);
  if (status != LF_UNSUPPORTED ||
      !fresh_process_media_is(instance, default_media, &media_info, NULL) ||
      media_info.guest_generation != before_generation ||
      !fresh_process_host_custody_matches(
          save_path, ack_path, r3_save_baseline, r3_ack_baseline,
          r3_ack_bytes)) {
    goto cleanup;
  }
  status = lf_advance(instance, &run_request, &run_result);
  if (status != LF_OK || run_result.actual_units != 1U ||
      run_result.cumulative_units != 1U || run_result.video_valid != 1U ||
      run_result.audio_valid != 1U ||
      run_result.sampled_buttons != 0U ||
      !lf_muhtari_snapshot_expected(1U, &expected_frame) ||
      lf_copy_media(instance, after_media, sizeof(after_media), &media_info) !=
          LF_OK) {
    goto cleanup;
  }
  mismatch = lf_muhtari_snapshot_first_mismatch(
      video, audio, run_result.audio_produced_samples, after_media, 1U,
      expected_frame.audio_samples, expected_frame.video_sha256,
      expected_frame.pcm_sha256, default_media);
  if (mismatch != NULL ||
      !fresh_process_host_custody_matches(
          save_path, ack_path, r3_save_baseline, r3_ack_baseline,
          r3_ack_bytes)) {
    goto cleanup;
  }
  (void)printf("event=battery-b-refusal name=same_length_content status=%d same-length=pass different-sha256=pass snapshot-operations=unsupported preservation=continuation,full-media,generation,selected-save,ack result=pass\n",
               (int)LF_UNSUPPORTED);
  ok = 1;

cleanup:
  if (instance != NULL && lf_destroy(&instance) != LF_OK) {
    ok = 0;
  }
  return ok;
}

static int fresh_process_a(const char *checkpoint_path, const char *save_path,
                           const char *ack_path) {
  uint8_t content[LF_MUHTARI_FIXTURE_TOTAL_BYTES];
  uint8_t media[LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES];
  uint8_t expected_media[LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES];
  uint8_t *snapshot = NULL;
  size_t snapshot_bytes = 0U;
  uint64_t generation = 0U;
  char save_digest[65] = {0};
  char ack_save_digest[65] = {0};
  char checkpoint_digest[65] = {0};
  lf_instance *instance = NULL;
  lf_load_result load_result = {.struct_size = sizeof(load_result)};
  lf_media_info media_info = {.struct_size = sizeof(media_info)};
  lf_status status = LF_OK;
  int result = 1;

  if (!fresh_process_capability("a")) {
    return fresh_process_capability_override != NULL ? 77 : 1;
  }
  if (checkpoint_path == NULL || save_path == NULL || ack_path == NULL ||
      lf_build_muhtari_snapshot_fixture(content, sizeof(content)) !=
          sizeof(content) ||
      !fresh_process_load(content, &instance, &load_result)) {
    goto cleanup;
  }
  if (!snapshot_check_frame(instance, 1U, 0U, media, &media_info) ||
      !snapshot_check_frame(instance, LF_MUHTARI_SNAPSHOT_R2_FRAME, 0U, media,
                            &media_info) ||
      !lf_muhtari_snapshot_fill_expected_battery(
          LF_MUHTARI_SNAPSHOT_R2_FRAME, expected_media) ||
      !fresh_process_media_is(instance, expected_media, &media_info,
                              &generation)) {
    goto cleanup;
  }
  {
    const lf_input pending_input = {.struct_size = sizeof(pending_input),
                                    .buttons = 1U};
    status = lf_set_input(instance, &pending_input);
    if (status != LF_OK) {
      (void)fprintf(stderr,
                    "muhtari_api8_process_a: pending input setup failed status=%d\n",
                    (int)status);
      goto cleanup;
    }
  }
  status = lf_get_snapshot_size(instance, &snapshot_bytes);
  if (status != LF_OK ||
      snapshot_bytes < LF_MUHTARI_HOST_SNAPSHOT_HEADER_BYTES ||
      snapshot_bytes > LF_MUHTARI_HOST_SNAPSHOT_MAX_BYTES) {
    (void)fprintf(stderr,
                  "muhtari_api8_process_a: exact bounded snapshot size query failed status=%d\n",
                  (int)status);
    goto cleanup;
  }
  snapshot = (uint8_t *)malloc(snapshot_bytes);
  if (snapshot == NULL ||
      lf_capture_snapshot(instance, snapshot, snapshot_bytes) != LF_OK ||
      !fresh_process_media_is(instance, expected_media, &media_info,
                              &generation)) {
    (void)fprintf(stderr,
                  "muhtari_api8_process_a: R2 capture failed or advanced guest state\n");
    goto cleanup;
  }
  if (!snapshot_check_frame(instance, LF_MUHTARI_SNAPSHOT_R3_FRAME, 1U, media,
                            &media_info) ||
      !lf_muhtari_snapshot_fill_expected_battery(
          LF_MUHTARI_SNAPSHOT_R3_FRAME, expected_media) ||
      !fresh_process_media_is(instance, expected_media, &media_info,
                              &generation)) {
    goto cleanup;
  }
  if (!lf_muhtari_host_commit_save(save_path, ack_path, snapshot,
                                   snapshot_bytes, expected_media, generation,
                                   save_digest, ack_save_digest) ||
      strcmp(save_digest, ack_save_digest) != 0) {
    (void)fprintf(stderr,
                  "muhtari_api8_process_a: R3 host save commit/readback failed\n");
    goto cleanup;
  }
  (void)printf("event=selected-save-commit-r3 bytes=%u sha256=%s ack-save-sha256=%s generation=%" PRIu64 " readback=exact result=pass\n",
               (unsigned int)LF_MUHTARI_HOST_SAVE_TOTAL_BYTES, save_digest,
               ack_save_digest, generation);
  if (!lf_muhtari_host_write_checkpoint(checkpoint_path, snapshot,
                                        snapshot_bytes,
                                        checkpoint_digest)) {
    (void)fprintf(stderr,
                  "muhtari_api8_process_a: closed checkpoint write/readback failed\n");
    goto cleanup;
  }
  (void)printf("event=checkpoint-close bytes=%zu sha256=%s\n", snapshot_bytes,
               checkpoint_digest);
  status = lf_destroy(&instance);
  if (status != LF_OK || instance != NULL) {
    (void)fprintf(stderr,
                  "muhtari_api8_process_a: instance destruction failed status=%d\n",
                  (int)status);
    goto cleanup;
  }
  (void)puts("event=instance-destroyed");
  (void)printf("muhtari_api8_process_a: frames=2 capture=R2 save=R3 result=pass\n");
  result = 0;

cleanup:
  if (instance != NULL) {
    (void)lf_destroy(&instance);
  }
  free(snapshot);
  return result;
}

static int fresh_process_b(const char *checkpoint_path, const char *save_path,
                           const char *ack_path,
                           const char *wrong_oracle) {
  uint8_t content[LF_MUHTARI_FIXTURE_TOTAL_BYTES];
  uint8_t expected_r2[LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES];
  uint8_t expected_r3[LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES];
  uint8_t *current_snapshot = NULL;
  uint8_t *checkpoint = NULL;
  uint8_t *r3_media = NULL;
  uint8_t *r3_save_before = NULL;
  uint8_t *r3_save_after = NULL;
  uint8_t *r3_ack_before = NULL;
  uint8_t *r3_ack_after = NULL;
  uint8_t *r2_save = NULL;
  uint8_t *verified_r2_media = NULL;
  uint8_t candidate[LF_MUHTARI_HOST_SAVE_TOTAL_BYTES];
  uint8_t guest_media[LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES];
  size_t snapshot_bytes = 0U;
  size_t ack_bytes = 0U;
  uint64_t r3_file_generation = 0U;
  uint64_t before_restore_generation = 0U;
  uint64_t restored_generation = 0U;
  uint64_t readback_generation = 0U;
  char r3_digest[65] = {0};
  char r3_digest_after_failure[65] = {0};
  char r2_digest[65] = {0};
  char r2_committed_digest[65] = {0};
  char r2_after_guest_digest[65] = {0};
  char ack_save_digest[65] = {0};
  char ack_template[160];
  char checkpoint_digest[65] = {0};
  const char *observed_mismatch = NULL;
  lf_instance *instance = NULL;
  lf_load_result load_result = {.struct_size = sizeof(load_result)};
  lf_media_info media_info = {.struct_size = sizeof(media_info)};
  lf_status status = LF_OK;
  int result = 1;
  int deliberate_wrong_oracle = 0;

  if (!fresh_process_capability("b")) {
    return fresh_process_capability_override != NULL ? 77 : 1;
  }
  if (checkpoint_path == NULL || save_path == NULL || ack_path == NULL ||
      lf_build_muhtari_snapshot_fixture(content, sizeof(content)) !=
          sizeof(content) ||
      !fresh_process_load(content, &instance, &load_result)) {
    goto cleanup;
  }
  status = lf_get_snapshot_size(instance, &snapshot_bytes);
  if (status != LF_OK ||
      snapshot_bytes < LF_MUHTARI_HOST_SNAPSHOT_HEADER_BYTES ||
      snapshot_bytes > LF_MUHTARI_HOST_SNAPSHOT_MAX_BYTES) {
    (void)fprintf(stderr,
                  "muhtari_api8_process_b: exact bounded snapshot size query failed status=%d\n",
                  (int)status);
    goto cleanup;
  }
  current_snapshot = (uint8_t *)malloc(snapshot_bytes);
  if (current_snapshot == NULL ||
      lf_capture_snapshot(instance, current_snapshot, snapshot_bytes) != LF_OK ||
      !lf_muhtari_host_read_exact_file(
          checkpoint_path, snapshot_bytes,
          LF_MUHTARI_HOST_SNAPSHOT_MAX_BYTES, &checkpoint) ||
      !lf_muhtari_host_snapshot_identity_matches(
          checkpoint, current_snapshot, snapshot_bytes)) {
    (void)fprintf(stderr,
                  "muhtari_api8_process_b: fresh checkpoint extent or route identity mismatch\n");
    goto cleanup;
  }
  {
    uint8_t digest[32];
    lf_muhtari_host_digest(checkpoint, snapshot_bytes, digest);
    lf_muhtari_host_hex(digest, checkpoint_digest);
  }
  (void)printf("event=checkpoint-reopened bytes=%zu sha256=%s\n",
               snapshot_bytes, checkpoint_digest);
  if (!lf_muhtari_snapshot_fill_expected_battery(
          LF_MUHTARI_SNAPSHOT_R2_FRAME, expected_r2) ||
      !lf_muhtari_snapshot_fill_expected_battery(
          LF_MUHTARI_SNAPSHOT_R3_FRAME, expected_r3)) {
    (void)fprintf(stderr,
                  "muhtari_api8_process_b: frozen R2/R3 full-span oracle is unavailable\n");
    goto cleanup;
  }
  if (!lf_muhtari_host_read_save(save_path, ack_path, checkpoint,
                                 snapshot_bytes, expected_r3, &r3_media,
                                 &r3_file_generation, r3_digest)) {
    (void)fprintf(stderr,
                  "muhtari_api8_process_b: selected R3 save identity/readback failed\n");
    goto cleanup;
  }
  /* Read the exact envelope and acknowledgment after helper validation so
     later failure controls compare the complete selected host bytes. */
  if (!lf_muhtari_host_read_exact_file(
          save_path, LF_MUHTARI_HOST_SAVE_TOTAL_BYTES,
          LF_MUHTARI_HOST_SAVE_TOTAL_BYTES, &r3_save_before) ||
      !lf_muhtari_host_ack_bytes(r3_save_before,
                                 LF_MUHTARI_HOST_SAVE_TOTAL_BYTES,
                                 ack_template)) {
    (void)fprintf(stderr,
                  "muhtari_api8_process_b: selected R3 acknowledgment template failed\n");
    goto cleanup;
  }
  ack_bytes = strlen(ack_template);
  if (!lf_muhtari_host_read_exact_file(ack_path, ack_bytes, 160U,
                                       &r3_ack_before) ||
      memcmp(r3_ack_before, ack_template, ack_bytes) != 0) {
    (void)fprintf(stderr,
                  "muhtari_api8_process_b: selected R3 acknowledgment bytes mismatch\n");
    goto cleanup;
  }
  status = lf_import_media(instance, "muhtari-battery-v1", r3_media,
                           LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES);
  if (status != LF_OK ||
      !fresh_process_media_is(instance, expected_r3, &media_info,
                              &before_restore_generation)) {
    (void)fprintf(stderr,
                  "muhtari_api8_process_b: readback-verified R3 import failed status=%d\n",
                  (int)status);
    goto cleanup;
  }
  (void)printf("event=selected-save-imported-r3 sha256=%s bytes=%u generation=%" PRIu64 " before-positive-advance=pass result=pass\n",
               r3_digest, (unsigned int)LF_MUHTARI_HOST_SAVE_TOTAL_BYTES,
               before_restore_generation);

  if (!fresh_process_run_refusal_matrix(
          content, checkpoint, snapshot_bytes, expected_r2, expected_r3,
          r3_save_before, r3_ack_before, ack_bytes, save_path, ack_path)) {
    (void)fprintf(stderr,
                  "muhtari_api8_process_b: complete refusal matrix failed\n");
    goto cleanup;
  }
  if (!fresh_process_run_same_length_content_refusal(
          content, checkpoint, snapshot_bytes, r3_save_before, r3_ack_before,
          ack_bytes, save_path, ack_path)) {
    (void)fprintf(stderr,
                  "muhtari_api8_process_b: same-length altered-content control failed\n");
    goto cleanup;
  }

  status = lf_restore_snapshot(instance, checkpoint, snapshot_bytes);
  if (status != LF_OK ||
      !fresh_process_media_is(instance, expected_r2, &media_info,
                              &restored_generation) ||
      restored_generation != before_restore_generation + 1U) {
    (void)fprintf(stderr,
                  "muhtari_api8_process_b: R2 restore failed or generation was not receiver-local status=%d before=%" PRIu64 " after=%" PRIu64 "\n",
                  (int)status, before_restore_generation, restored_generation);
    goto cleanup;
  }
  {
    uint8_t *check_media = NULL;
    uint64_t check_generation = 0U;
    char check_digest[65] = {0};
    if (!lf_muhtari_host_read_save(save_path, ack_path, checkpoint,
                                   snapshot_bytes, expected_r3, &check_media,
                                   &check_generation, check_digest) ||
        check_generation != r3_file_generation ||
        strcmp(check_digest, r3_digest) != 0) {
      free(check_media);
      (void)fprintf(stderr,
                    "muhtari_api8_process_b: R3 save/ack changed during restore\n");
      goto cleanup;
    }
    free(check_media);
  }
  (void)printf("event=battery-restore-r2 bytes=%u generation=%" PRIu64 " selected-r3-preserved=pass result=pass\n",
               (unsigned int)LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES,
               restored_generation);

  if (!lf_muhtari_host_save_encode(checkpoint, snapshot_bytes, expected_r2,
                                   restored_generation, candidate) ||
      !lf_muhtari_host_pre_rename_failure(
          save_path, candidate, sizeof(candidate)) ||
      !lf_muhtari_host_read_exact_file(
          save_path, LF_MUHTARI_HOST_SAVE_TOTAL_BYTES,
          LF_MUHTARI_HOST_SAVE_TOTAL_BYTES, &r3_save_after) ||
      !lf_muhtari_host_read_exact_file(ack_path, ack_bytes, 160U,
                                       &r3_ack_after) ||
      memcmp(r3_save_before, r3_save_after,
             LF_MUHTARI_HOST_SAVE_TOTAL_BYTES) != 0 ||
      memcmp(r3_ack_before, r3_ack_after, ack_bytes) != 0 ||
      !lf_muhtari_host_save_validate(
          r3_save_after, LF_MUHTARI_HOST_SAVE_TOTAL_BYTES, checkpoint,
          snapshot_bytes, expected_r3, NULL)) {
    (void)fprintf(stderr,
                  "muhtari_api8_process_b: controlled partial staging failure changed R3 file/ack or left invalid identity\n");
    goto cleanup;
  }
  {
    uint8_t digest[32];
    lf_muhtari_host_digest(r3_save_after,
                           LF_MUHTARI_HOST_SAVE_TOTAL_BYTES, digest);
    lf_muhtari_host_hex(digest, r3_digest_after_failure);
  }
  (void)printf("event=pre-rename-failure-preserved-r3 sha256=%s bytes=%u stage-cleanup=pass result=pass\n",
               r3_digest_after_failure,
               (unsigned int)LF_MUHTARI_HOST_SAVE_TOTAL_BYTES);

  if (!lf_muhtari_host_commit_save(save_path, ack_path, checkpoint,
                                   snapshot_bytes, expected_r2,
                                   restored_generation, r2_digest,
                                   ack_save_digest) ||
      strcmp(r2_digest, ack_save_digest) != 0 ||
      !lf_muhtari_host_read_save(save_path, ack_path, checkpoint,
                                 snapshot_bytes, expected_r2,
                                 &verified_r2_media, &readback_generation,
                                 ack_save_digest) ||
      readback_generation != restored_generation ||
      memcmp(verified_r2_media, expected_r2, sizeof(expected_r2)) != 0 ||
      strcmp(r2_digest, ack_save_digest) != 0) {
    (void)fprintf(stderr,
                  "muhtari_api8_process_b: explicit R2 commit did not pass exact file and acknowledgment readback\n");
    goto cleanup;
  }
  (void)printf("event=save-r2-readback-acknowledged sha256=%s ack-save-sha256=%s bytes=%u generation=%" PRIu64 " readback=exact result=pass\n",
               r2_digest, ack_save_digest,
               (unsigned int)LF_MUHTARI_HOST_SAVE_TOTAL_BYTES,
               readback_generation);
  (void)snprintf(r2_committed_digest, sizeof(r2_committed_digest), "%s",
                 r2_digest);
  free(verified_r2_media);
  verified_r2_media = NULL;

  if (wrong_oracle != NULL) {
    if (!fresh_process_wrong_oracle_frame(
            instance, LF_MUHTARI_SNAPSHOT_R3_FRAME, 1U, wrong_oracle,
            guest_media, &media_info, &observed_mismatch)) {
      (void)fprintf(stderr,
                    "muhtari_api8_process_b: deliberate oracle control did not reach its named mismatch\n");
      goto cleanup;
    }
    deliberate_wrong_oracle = 1;
  } else if (!snapshot_check_frame(instance, LF_MUHTARI_SNAPSHOT_R3_FRAME,
                                   1U, guest_media, &media_info) ||
             !fresh_process_media_is(instance, expected_r3, &media_info,
                                     NULL)) {
    (void)fprintf(stderr,
                  "muhtari_api8_process_b: independent R3 continuation after restore failed\n");
    goto cleanup;
  }
  if (!lf_muhtari_host_read_save(save_path, ack_path, checkpoint,
                                 snapshot_bytes, expected_r2,
                                 &verified_r2_media, &readback_generation,
                                 r2_after_guest_digest) ||
      readback_generation != restored_generation ||
      memcmp(verified_r2_media, expected_r2, sizeof(expected_r2)) != 0 ||
      strcmp(r2_committed_digest, r2_after_guest_digest) != 0) {
    (void)fprintf(stderr,
                  "muhtari_api8_process_b: guest continuation changed selected host R2 save/ack\n");
    goto cleanup;
  }
  (void)printf("event=guest-r3-host-save-r2 sha256=%s generation=%" PRIu64 " guest-media=r3 host-ack=r2 result=pass\n",
               r2_after_guest_digest, readback_generation);
  if (deliberate_wrong_oracle != 0) {
    (void)printf("event=oracle-control name=%s mismatch=%s result=expected-failure\n",
                 wrong_oracle, observed_mismatch);
    (void)fprintf(stderr,
                  "muhtari_api8_process_b: deliberate wrong oracle reached B continuation assertion mismatch=%s\n",
                  observed_mismatch);
    goto cleanup;
  }
  status = lf_destroy(&instance);
  if (status != LF_OK || instance != NULL) {
    (void)fprintf(stderr,
                  "muhtari_api8_process_b: instance destruction failed status=%d\n",
                  (int)status);
    goto cleanup;
  }
  (void)puts("event=instance-destroyed");
  (void)puts("muhtari_api8_process_b: loads=1 frame=3 video=59b78332303fa3c631ae7cd522ad45627f739b49a48e8c0b0c07f45ea79bd225 pcm=09474df08fabeb22495ea69a6becd73374879d6840862382d0691c6e7a13a13f battery=full-span-r3 host-save=r2 result=pass");
  result = 0;

cleanup:
  if (instance != NULL) {
    status = lf_destroy(&instance);
    if (status == LF_OK && deliberate_wrong_oracle != 0) {
      (void)puts("event=instance-destroyed");
    }
  }
  free(current_snapshot);
  free(checkpoint);
  free(r3_media);
  free(r3_save_before);
  free(r3_save_after);
  free(r3_ack_before);
  free(r3_ack_after);
  free(r2_save);
  free(verified_r2_media);
  return result;
}

int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "--fixture-boundary") == 0) {
    return fixture_boundary(0);
  }
  if (argc == 2 && strcmp(argv[1], "--fixture-oracle-controls") == 0) {
    return fixture_boundary(1);
  }
  if (argc == 2 && strcmp(argv[1], "--snapshot-contract") == 0) {
    return snapshot_contract();
  }
  if (argc == 5 && strcmp(argv[1], "--process-a") == 0) {
    return fresh_process_a(argv[2], argv[3], argv[4]);
  }
  if (argc == 5 && strcmp(argv[1], "--process-b") == 0) {
    return fresh_process_b(argv[2], argv[3], argv[4], NULL);
  }
  if (argc == 6 && strcmp(argv[1], "--process-a") == 0 &&
      (strcmp(argv[5], "deny-status") == 0 ||
       strcmp(argv[5], "deny-supported") == 0)) {
    fresh_process_capability_override = argv[5];
    return fresh_process_a(argv[2], argv[3], argv[4]);
  }
  if (argc == 6 && strcmp(argv[1], "--process-b") == 0 &&
      (strcmp(argv[5], "deny-status") == 0 ||
       strcmp(argv[5], "deny-supported") == 0)) {
    fresh_process_capability_override = argv[5];
    return fresh_process_b(argv[2], argv[3], argv[4], NULL);
  }
  if (argc == 6 && strcmp(argv[1], "--process-b") == 0 &&
      (strcmp(argv[5], "frame") == 0 || strcmp(argv[5], "video") == 0 ||
       strcmp(argv[5], "audio") == 0 || strcmp(argv[5], "media") == 0)) {
    return fresh_process_b(argv[2], argv[3], argv[4], argv[5]);
  }
  if (argc != 1) {
    return fail("unknown command-line mode", LF_INVALID_ARGUMENT);
  }
  uint8_t content[LF_MUHTARI_FIXTURE_TOTAL_BYTES];
  uint8_t video[LF_MUHTARI_API8_VIDEO_WIDTH * LF_MUHTARI_API8_VIDEO_HEIGHT];
  int16_t audio[LF_MUHTARI_API8_AUDIO_SAMPLES];
  lf_profile profile = {.struct_size = sizeof(profile)};
  lf_instance *instance = NULL;
  lf_load_result load_result = {.struct_size = sizeof(load_result)};
  lf_run_result run_result = {.struct_size = sizeof(run_result)};
  const lf_load_request load_request = {
      .struct_size = sizeof(load_request),
      .content_data = content,
      .content_size_bytes = sizeof(content),
      .configuration_id = LF_MUHTARI_API8_CONFIGURATION,
  };
  const lf_input input = {.struct_size = sizeof(input), .buttons = 1U};
  const lf_run_request run_request = {
      .struct_size = sizeof(run_request),
      .work_units = 1U,
      .video_data = video,
      .video_capacity_bytes = sizeof(video),
      .video_stride_bytes = LF_MUHTARI_API8_VIDEO_WIDTH,
      .audio_data = audio,
      .audio_capacity_samples = LF_MUHTARI_API8_AUDIO_SAMPLES,
  };
  lf_status status = lf_get_profile(LF_MUHTARI_API8_PROFILE,
                                    LF_MUHTARI_API8_CONFIGURATION, &profile);
  if (status != LF_OK) {
    return fail("public API 8 profile query failed", status);
  }
  if (profile.profile_id == NULL ||
      strcmp(profile.profile_id, LF_MUHTARI_API8_PROFILE) != 0 ||
      profile.core_id == NULL || strcmp(profile.core_id, "muhtari") != 0 ||
      profile.api_revision != 8U || profile.behavior_revision != 6U ||
      profile.video_format != LF_VIDEO_INDEX8 ||
      profile.video_width != LF_MUHTARI_API8_VIDEO_WIDTH ||
      profile.video_height != LF_MUHTARI_API8_VIDEO_HEIGHT ||
      profile.audio_encoding != LF_AUDIO_S16_NATIVE ||
      profile.audio_layout != LF_AUDIO_INTERLEAVED ||
      profile.audio_rate_numerator != 48000U ||
      profile.audio_rate_denominator != 1U || profile.audio_channels != 1U ||
      profile.max_audio_samples_per_call != LF_MUHTARI_API8_AUDIO_SAMPLES ||
      profile.effective_configuration_id == NULL ||
      strcmp(profile.effective_configuration_id,
             LF_MUHTARI_API8_CONFIGURATION) != 0) {
    return fail("public API 8 profile metadata mismatch", LF_UNSUPPORTED);
  }
  if (lf_build_muhtari_fixture(content, sizeof(content)) != sizeof(content)) {
    return fail("generated A78 fixture construction failed", LF_INVALID_ARGUMENT);
  }
  status = lf_create(LF_MUHTARI_API8_PROFILE, NULL, &instance);
  if (status != LF_OK || instance == NULL) {
    return fail("public API 8 instance creation failed", status);
  }
  status = lf_load(instance, &load_request, &load_result);
  if (status != LF_OK || load_result.loaded != 1U ||
      load_result.content_size_bytes != sizeof(content) ||
      load_result.effective_configuration_id == NULL ||
      strcmp(load_result.effective_configuration_id,
             LF_MUHTARI_API8_CONFIGURATION) != 0) {
    (void)lf_destroy(&instance);
    return fail("generated A78 fixture load failed", status);
  }
  status = lf_set_input(instance, &input);
  if (status != LF_OK) {
    (void)lf_destroy(&instance);
    return fail("public digital input submission failed", status);
  }
  status = lf_advance(instance, &run_request, &run_result);
  if (status != LF_OK || run_result.requested_units != 1U ||
      run_result.actual_units != 1U || run_result.overshoot_units != 0U ||
      run_result.sampled_buttons != input.buttons ||
      run_result.video_valid != 1U || run_result.audio_valid != 1U ||
      run_result.video_format != LF_VIDEO_INDEX8 ||
      run_result.audio_encoding != LF_AUDIO_S16_NATIVE ||
      run_result.audio_layout != LF_AUDIO_INTERLEAVED ||
      run_result.video_width != LF_MUHTARI_API8_VIDEO_WIDTH ||
      run_result.video_height != LF_MUHTARI_API8_VIDEO_HEIGHT ||
      run_result.audio_rate_numerator != 48000U ||
      run_result.audio_rate_denominator != 1U ||
      run_result.audio_channels != 1U || run_result.audio_produced_samples == 0U ||
      run_result.audio_produced_samples > LF_MUHTARI_API8_AUDIO_SAMPLES) {
    (void)lf_destroy(&instance);
    return fail("public frame or output metadata mismatch", status);
  }
  status = lf_destroy(&instance);
  if (status != LF_OK || instance != NULL) {
    return fail("public instance destruction failed", status);
  }
  (void)puts("muhtari_api8_profile: source=d58f125297c4d63a7a8108112a5eafff6f53a76a version=0.11.1 api=8 abi=1 behavior=6 state-format=1 profile=muhtari-ntsc-v2 fixture=owned-a78-linear-16k input=1 frame=1 video=INDEX8 audio=S16_NATIVE result=pass");
  return 0;
}
