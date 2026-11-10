#include <inttypes.h>
#include <stdio.h>
#include <string.h>

#include <libfuturo/libfuturo.h>

/* Happy-path example for the shared obligations indexed in docs/contract.md:
   LC-LIFE-01, LC-OWN-01, LC-LOAD-01, LC-INPUT-01, LC-TIME-01, LC-LIMIT-01,
   LC-ERROR-01, and LC-HOST-01. Profile-specific refusal cases are tested
   separately. */

static const char *status_name(lf_status status) {
  switch (status) {
    case LF_OK: return "LF_OK";
    case LF_INVALID_ARGUMENT: return "LF_INVALID_ARGUMENT";
    case LF_UNSUPPORTED: return "LF_UNSUPPORTED";
    case LF_LIMIT_EXCEEDED: return "LF_LIMIT_EXCEEDED";
    case LF_BUFFER_TOO_SMALL: return "LF_BUFFER_TOO_SMALL";
    case LF_RESOURCE_EXHAUSTED: return "LF_RESOURCE_EXHAUSTED";
  }
  return "unknown status";
}

static const char *stop_name(lf_stop_reason stop_reason) {
  switch (stop_reason) {
    case LF_STOP_BUDGET_REACHED: return "LF_STOP_BUDGET_REACHED";
    case LF_STOP_REJECTED: return "LF_STOP_REJECTED";
    case LF_STOP_CORE_HALTED: return "LF_STOP_CORE_HALTED";
  }
  return "unknown stop reason";
}

static void report_status(const char *operation, lf_status actual) {
  (void)fprintf(stderr, "synthetic_host: %s failed: %s\n", operation,
                status_name(actual));
}

static int require_capability(const char *name, const char *profile_id,
                              lf_capability capability, lf_status expected_status,
                              uint32_t expected_supported) {
  uint32_t supported = UINT32_MAX;
  const lf_status status =
      lf_get_capability(profile_id, NULL, capability, &supported);
  if (status != expected_status || supported != expected_supported) {
    (void)fprintf(stderr,
                  "synthetic_host: capability %s expected %s/%u, got %s/%u\n",
                  name, status_name(expected_status), expected_supported,
                  status_name(status), supported);
    return 0;
  }
  (void)printf("capability %s: %s, supported=%u\n", name, status_name(status),
               supported);
  return 1;
}

int main(void) {
  static const uint32_t inputs[3] = {0U, 1U, 2U};
  static const uint32_t work_units[3] = {1U, 2U, 1U};
  static const uint64_t cumulative_units[3] = {1U, 3U, 4U};
  lf_profile profile = {.struct_size = sizeof(profile)};
  lf_instance *instance = NULL;
  uint8_t video[3][4];
  int16_t audio[3][4];
  uint8_t media[3][4];
  uint8_t retained_video[4] = {0U};
  int16_t retained_audio[2] = {0, 0};
  uint8_t retained_media[4] = {0U};
  int exit_code = 1;
  size_t row_index = 0U;

  {
    const lf_status status = lf_get_profile("synthetic-v1", NULL, &profile);
    if (status != LF_OK) {
      report_status("profile query", status);
      goto cleanup;
    }
  }
  if (profile.profile_id == NULL || profile.core_id == NULL ||
      profile.build_id == NULL) {
    (void)fprintf(stderr, "synthetic_host: profile query returned incomplete identity\n");
    goto cleanup;
  }
  if (strcmp(profile.profile_id, "synthetic-v1") != 0 ||
      strcmp(profile.core_id, "synthetic") != 0 || profile.api_revision != 1U ||
      profile.behavior_revision != 1U || profile.input_mask != 3U ||
      profile.max_work_units != 4U || profile.max_guest_units != 8U ||
      profile.atomic_quantum_units != 1U || profile.max_overshoot_units != 0U ||
      profile.time_unit != LF_TIME_SYNTHETIC_STEP ||
      profile.input_sampling != LF_INPUT_AT_ADVANCE_START ||
      profile.video_format != LF_VIDEO_GRAY8 || profile.video_width != 2U ||
      profile.video_height != 2U || profile.video_bytes_per_pixel != 1U ||
      profile.audio_encoding != LF_AUDIO_S16_NATIVE ||
      profile.audio_layout != LF_AUDIO_INTERLEAVED ||
      profile.audio_rate_numerator != 8000U ||
      profile.audio_rate_denominator != 1U || profile.audio_channels != 1U ||
      profile.min_video_stride_bytes != 2U ||
      profile.max_audio_samples_per_call != 8U ||
      profile.media_extent_bytes != 4U) {
    (void)fprintf(stderr, "synthetic_host: profile metadata did not match synthetic-v1\n");
    goto cleanup;
  }

  (void)printf("profile: %s core=%s build=%s api=%u behavior=%u\n",
               profile.profile_id, profile.core_id, profile.build_id,
               profile.api_revision, profile.behavior_revision);
  (void)printf("limits: input-mask=%u work/call=%u guest/session=%u quantum=%u overshoot=%u\n",
               profile.input_mask, profile.max_work_units,
               profile.max_guest_units, profile.atomic_quantum_units,
               profile.max_overshoot_units);
  if (!require_capability("logical-input", profile.profile_id,
                          LF_CAP_LOGICAL_INPUT, LF_OK, 1U) ||
      !require_capability("bounded-execution", profile.profile_id,
                          LF_CAP_BOUNDED_EXECUTION, LF_OK, 1U) ||
      !require_capability("software-video", profile.profile_id,
                          LF_CAP_SOFTWARE_VIDEO, LF_OK, 1U) ||
      !require_capability("audio", profile.profile_id, LF_CAP_AUDIO, LF_OK, 1U) ||
      !require_capability("in-memory-media-copy", profile.profile_id,
                          LF_CAP_IN_MEMORY_MEDIA_COPY, LF_OK, 1U) ||
      !require_capability("snapshot", profile.profile_id, LF_CAP_SNAPSHOT,
                          LF_UNSUPPORTED, 0U) ||
      !require_capability("hardware-video", profile.profile_id,
                          LF_CAP_HARDWARE_VIDEO, LF_UNSUPPORTED, 0U) ||
      !require_capability("concurrent-use", profile.profile_id,
                          LF_CAP_CONCURRENT_USE, LF_UNSUPPORTED, 0U)) {
    goto cleanup;
  }

  {
    const lf_status status = lf_create("synthetic-v1", NULL, &instance);
    if (status != LF_OK || instance == NULL) {
      report_status("instance creation", status);
      goto cleanup;
    }
  }

  for (row_index = 0U; row_index < 3U; ++row_index) {
    lf_input input = {
        .struct_size = sizeof(input),
        .buttons = inputs[row_index],
    };
    lf_run_request request = {
        .struct_size = sizeof(request),
        .work_units = work_units[row_index],
        .video_data = video[row_index],
        .video_capacity_bytes = sizeof(video[row_index]),
        .video_stride_bytes = 2U,
        .audio_data = audio[row_index],
        .audio_capacity_samples = sizeof(audio[row_index]) / sizeof(audio[row_index][0]),
    };
    lf_run_result result = {.struct_size = sizeof(result)};
    lf_media_info media_info = {.struct_size = sizeof(media_info)};
    lf_status status = LF_OK;

    memset(video[row_index], 0xA5, sizeof(video[row_index]));
    for (size_t sample = 0U; sample < 4U; ++sample) {
      audio[row_index][sample] = INT16_C(1234);
    }
    memset(media[row_index], 0xA5, sizeof(media[row_index]));

    status = lf_set_input(instance, &input);
    if (status != LF_OK) {
      report_status("input update", status);
      goto cleanup;
    }
    status = lf_advance(instance, &request, &result);
    if (status != LF_OK) {
      report_status("advance", status);
      goto cleanup;
    }
    status = lf_copy_media(instance, media[row_index], sizeof(media[row_index]),
                           &media_info);
    if (status != LF_OK) {
      report_status("media copy", status);
      goto cleanup;
    }
    if (result.requested_units != work_units[row_index] ||
        result.actual_units != work_units[row_index] ||
        result.overshoot_units != 0U || result.sampled_buttons != inputs[row_index] ||
        result.video_valid != 1U || result.audio_valid != 1U ||
        result.cumulative_units != cumulative_units[row_index] ||
        result.time_unit != LF_TIME_SYNTHETIC_STEP ||
        result.stop_reason != LF_STOP_BUDGET_REACHED ||
        result.video_format != LF_VIDEO_GRAY8 || result.video_width != 2U ||
        result.video_height != 2U || result.video_stride_bytes != 2U ||
        result.video_extent_bytes != 4U ||
        result.audio_encoding != LF_AUDIO_S16_NATIVE ||
        result.audio_layout != LF_AUDIO_INTERLEAVED ||
        result.audio_rate_numerator != 8000U ||
        result.audio_rate_denominator != 1U || result.audio_channels != 1U ||
        result.audio_produced_samples != work_units[row_index] * 2U ||
        media_info.identity == NULL ||
        strcmp(media_info.identity, "synthetic-media-v1") != 0 ||
        media_info.extent_bytes != 4U ||
        media_info.guest_generation != cumulative_units[row_index]) {
      (void)fprintf(stderr, "synthetic_host: row %zu metadata mismatch\n", row_index + 1U);
      goto cleanup;
    }

    (void)printf("call %zu input=%u requested=%u actual=%u cumulative=%" PRIu64
                 " stop=%s overshoot=%u\n",
                 row_index + 1U, inputs[row_index], result.requested_units,
                 result.actual_units, result.cumulative_units,
                 stop_name(result.stop_reason), result.overshoot_units);
    (void)printf("  video=Gray8 2x2 stride=%zu extent=%zu bytes=%u,%u,%u,%u\n",
                 result.video_stride_bytes, result.video_extent_bytes,
                 (unsigned int)video[row_index][0],
                 (unsigned int)video[row_index][1],
                 (unsigned int)video[row_index][2],
                 (unsigned int)video[row_index][3]);
    (void)printf("  audio=S16_NATIVE mono interleaved rate=8000/1 samples=%zu:",
                 result.audio_produced_samples);
    for (size_t sample = 0U; sample < result.audio_produced_samples; ++sample) {
      (void)printf(" %d", (int)audio[row_index][sample]);
    }
    (void)printf("\n  media=%s extent=%zu generation=%" PRIu64 " bytes=%u,%u,%u,%u\n",
                 media_info.identity, media_info.extent_bytes,
                 media_info.guest_generation, (unsigned int)media[row_index][0],
                 (unsigned int)media[row_index][1],
                 (unsigned int)media[row_index][2],
                 (unsigned int)media[row_index][3]);

    if (row_index == 0U) {
      memcpy(retained_video, video[row_index], sizeof(retained_video));
      memcpy(retained_audio, audio[row_index], sizeof(retained_audio));
      memcpy(retained_media, media[row_index], sizeof(retained_media));
    } else if (memcmp(retained_video, video[0], sizeof(retained_video)) != 0 ||
               memcmp(retained_audio, audio[0], sizeof(retained_audio)) != 0 ||
               memcmp(retained_media, media[0], sizeof(retained_media)) != 0) {
      (void)fprintf(stderr, "synthetic_host: host-owned first-call output changed\n");
      goto cleanup;
    }
  }

  exit_code = 0;

cleanup:
  {
    const lf_status status = lf_destroy(&instance);
    if (status != LF_OK) {
      report_status("instance destruction", status);
      exit_code = 1;
    }
  }
  if (exit_code == 0 &&
      (memcmp(retained_video, video[0], sizeof(retained_video)) != 0 ||
       memcmp(retained_audio, audio[0], sizeof(retained_audio)) != 0 ||
       memcmp(retained_media, media[0], sizeof(retained_media)) != 0)) {
    (void)fprintf(stderr, "synthetic_host: retained host-owned output changed after destroy\n");
    exit_code = 1;
  }
  return exit_code;
}
