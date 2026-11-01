#include <stdio.h>
#include <string.h>

#include <libfuturo/libfuturo.h>
#include "synthetic_oracle.h"

#define REQUIRE(condition, label)                                             \
  do {                                                                         \
    if (!(condition)) {                                                        \
      (void)fprintf(stderr, "synthetic_session: %s failed\n", (label));      \
      exit_code = 1;                                                           \
      goto cleanup;                                                            \
    }                                                                          \
  } while (0)

static int check_capability(const char *name, lf_capability capability,
                            lf_status expected_status,
                            uint32_t expected_supported) {
  uint32_t supported = UINT32_MAX;
  const lf_status status =
      lf_get_capability("synthetic-v1", capability, &supported);
  if (status != expected_status || supported != expected_supported) {
    (void)fprintf(stderr,
                  "synthetic_session: capability %s expected status=%d supported=%u, "
                  "got status=%d supported=%u\n",
                  name, (int)expected_status, expected_supported, (int)status,
                  supported);
    return 0;
  }
  return 1;
}

int main(int argc, char **argv) {
  lf_profile profile = {.struct_size = sizeof(profile)};
  lf_instance *instance = NULL;
  uint8_t video[3][4];
  int16_t audio[3][4];
  uint8_t media[3][4];
  uint8_t retained_video[4] = {0U};
  int16_t retained_audio[2] = {0, 0};
  uint8_t retained_media[4] = {0U};
  size_t retained_audio_count = 0U;
  size_t row_index = 0U;
  int exit_code = 0;
  int wrong_expected_video = 0;

  if (argc == 2 && strcmp(argv[1], "--wrong-expected-video") == 0) {
    wrong_expected_video = 1;
  } else if (argc != 1) {
    (void)fprintf(stderr, "synthetic_session: unknown argument\n");
    return 2;
  }

  REQUIRE(lf_get_profile("synthetic-v1", &profile) == LF_OK,
          "synthetic-v1 profile query");
  REQUIRE(profile.struct_size == sizeof(profile), "profile record size");
  REQUIRE(profile.profile_id != NULL && strcmp(profile.profile_id, "synthetic-v1") == 0,
          "profile identity");
  REQUIRE(profile.core_id != NULL && strcmp(profile.core_id, "synthetic") == 0,
          "core identity");
  REQUIRE(profile.build_id != NULL && profile.build_id[0] != '\0', "build identity");
  REQUIRE(profile.api_revision == 1U && profile.behavior_revision == 1U,
          "API and behavior revisions");
  REQUIRE(profile.input_mask == 3U && profile.max_work_units == 4U &&
              profile.max_guest_units == 8U &&
              profile.atomic_quantum_units == 1U &&
              profile.max_overshoot_units == 0U,
          "input and execution limits");
  REQUIRE(profile.time_unit == LF_TIME_SYNTHETIC_STEP &&
              profile.input_sampling == LF_INPUT_AT_ADVANCE_START,
          "time unit and input sampling");
  REQUIRE(profile.video_format == LF_VIDEO_GRAY8 && profile.video_width == 2U &&
              profile.video_height == 2U && profile.video_bytes_per_pixel == 1U &&
              profile.min_video_stride_bytes == 2U,
          "video profile metadata");
  REQUIRE(profile.audio_encoding == LF_AUDIO_S16_NATIVE &&
              profile.audio_layout == LF_AUDIO_INTERLEAVED &&
              profile.audio_rate_numerator == 8000U &&
              profile.audio_rate_denominator == 1U &&
              profile.audio_channels == 1U &&
              profile.max_audio_samples_per_call == 8U,
          "audio profile metadata");
  REQUIRE(profile.media_extent_bytes == 4U, "media profile extent");

  REQUIRE(check_capability("logical input", LF_CAP_LOGICAL_INPUT, LF_OK, 1U),
          "logical-input capability");
  REQUIRE(check_capability("bounded execution", LF_CAP_BOUNDED_EXECUTION, LF_OK, 1U),
          "bounded-execution capability");
  REQUIRE(check_capability("software video", LF_CAP_SOFTWARE_VIDEO, LF_OK, 1U),
          "software-video capability");
  REQUIRE(check_capability("audio", LF_CAP_AUDIO, LF_OK, 1U), "audio capability");
  REQUIRE(check_capability("in-memory media copy", LF_CAP_IN_MEMORY_MEDIA_COPY,
                           LF_OK, 1U),
          "in-memory-media capability");
  REQUIRE(check_capability("snapshot", LF_CAP_SNAPSHOT, LF_UNSUPPORTED, 0U),
          "unsupported snapshot capability");
  REQUIRE(check_capability("hardware video", LF_CAP_HARDWARE_VIDEO,
                           LF_UNSUPPORTED, 0U),
          "unsupported hardware-video capability");
  REQUIRE(check_capability("concurrent use", LF_CAP_CONCURRENT_USE,
                           LF_UNSUPPORTED, 0U),
          "unsupported concurrent-use capability");

  REQUIRE(lf_create("synthetic-v1", NULL, &instance) == LF_OK && instance != NULL,
          "owned instance creation");
  for (row_index = 0U; row_index < 3U; ++row_index) {
    const synthetic_oracle_row *expected = &synthetic_oracle_rows[row_index];
    lf_input input = {
        .struct_size = sizeof(input),
        .buttons = expected->input_buttons,
    };
    lf_run_request request = {
        .struct_size = sizeof(request),
        .work_units = expected->requested_units,
        .video_data = video[row_index],
        .video_capacity_bytes = sizeof(video[row_index]),
        .video_stride_bytes = 2U,
        .audio_data = audio[row_index],
        .audio_capacity_samples = sizeof(audio[row_index]) / sizeof(audio[row_index][0]),
    };
    lf_run_result result = {.struct_size = sizeof(result)};
    lf_media_info media_info = {.struct_size = sizeof(media_info)};

    memset(video[row_index], 0xA5, sizeof(video[row_index]));
    for (size_t sample = 0U; sample < 4U; ++sample) {
      audio[row_index][sample] = INT16_C(1234);
    }
    memset(media[row_index], 0xA5, sizeof(media[row_index]));

    REQUIRE(lf_set_input(instance, &input) == LF_OK, "set logical input");
    REQUIRE(lf_advance(instance, &request, &result) == LF_OK,
            "advance prescribed work");
    REQUIRE(result.struct_size == sizeof(result), "result record size");
    REQUIRE(result.requested_units == expected->requested_units &&
                result.actual_units == expected->requested_units &&
                result.overshoot_units == 0U &&
                result.sampled_buttons == expected->input_buttons &&
                result.cumulative_units == expected->cumulative_units &&
                result.stop_reason == LF_STOP_BUDGET_REACHED,
            "literal progress and stop result");
    REQUIRE(result.video_valid == 1U && result.audio_valid == 1U &&
                result.time_unit == LF_TIME_SYNTHETIC_STEP,
            "valid output and guest-time metadata");
    REQUIRE(result.video_format == LF_VIDEO_GRAY8 && result.video_width == 2U &&
                result.video_height == 2U && result.video_stride_bytes == 2U &&
                result.video_extent_bytes == 4U,
            "video output metadata");
    REQUIRE(result.audio_encoding == LF_AUDIO_S16_NATIVE &&
                result.audio_layout == LF_AUDIO_INTERLEAVED &&
                result.audio_rate_numerator == 8000U &&
                result.audio_rate_denominator == 1U &&
                result.audio_channels == 1U &&
                result.audio_produced_samples == expected->audio_sample_count,
            "audio output metadata");
    for (size_t pixel = 0U; pixel < 4U; ++pixel) {
      uint8_t expected_pixel = expected->video_bytes[pixel];
      if (wrong_expected_video && row_index == 2U && pixel == 3U) {
        expected_pixel = 13U;
      }
      if (video[row_index][pixel] != expected_pixel) {
        (void)fprintf(stderr,
                      "synthetic_session: video mismatch at row %zu pixel %zu expected=%u actual=%u\n",
                      row_index, pixel, (unsigned int)expected_pixel,
                      (unsigned int)video[row_index][pixel]);
        exit_code = 1;
        goto cleanup;
      }
    }
    for (size_t sample = 0U; sample < expected->audio_sample_count; ++sample) {
      REQUIRE(audio[row_index][sample] == expected->audio_samples[sample],
              "independent literal audio sample");
    }
    for (size_t sample = expected->audio_sample_count; sample < 4U; ++sample) {
      REQUIRE(audio[row_index][sample] == INT16_C(1234),
              "unused audio tail remains host-owned");
    }

    REQUIRE(lf_copy_media(instance, media[row_index], sizeof(media[row_index]),
                          &media_info) == LF_OK,
            "copy media to host buffer");
    REQUIRE(media_info.struct_size == sizeof(media_info) &&
                media_info.identity != NULL &&
                strcmp(media_info.identity, "synthetic-media-v1") == 0 &&
                media_info.extent_bytes == 4U &&
                media_info.guest_generation == expected->media_generation,
            "media identity and generation metadata");
    for (size_t byte = 0U; byte < 4U; ++byte) {
      REQUIRE(media[row_index][byte] == expected->media_bytes[byte],
              "independent literal media byte");
    }

    if (row_index == 0U) {
      memcpy(retained_video, video[row_index], sizeof(retained_video));
      retained_audio_count = expected->audio_sample_count;
      memcpy(retained_audio, audio[row_index],
             retained_audio_count * sizeof(retained_audio[0]));
      memcpy(retained_media, media[row_index], sizeof(retained_media));
    } else {
      REQUIRE(memcmp(retained_video, video[0], sizeof(retained_video)) == 0,
              "video output retained across later calls");
      REQUIRE(memcmp(retained_audio, audio[0],
                     retained_audio_count * sizeof(retained_audio[0])) == 0,
              "audio output retained across later calls");
      REQUIRE(memcmp(retained_media, media[0], sizeof(retained_media)) == 0,
              "media output retained across later calls");
    }
  }

  REQUIRE(lf_destroy(&instance) == LF_OK, "owned instance destruction");
  REQUIRE(instance == NULL, "destroy clears owner handle");
  REQUIRE(lf_destroy(&instance) == LF_OK, "destroying null owner is harmless");
  REQUIRE(memcmp(retained_video, video[0], sizeof(retained_video)) == 0,
          "video output survives destruction");
  REQUIRE(memcmp(retained_audio, audio[0],
                 retained_audio_count * sizeof(retained_audio[0])) == 0,
          "audio output survives destruction");
  REQUIRE(memcmp(retained_media, media[0], sizeof(retained_media)) == 0,
          "media output survives destruction");
  (void)printf("synthetic_session: three literal session rows passed\n");
  return 0;

cleanup:
  (void)lf_destroy(&instance);
  return exit_code;
}
