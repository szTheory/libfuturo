#define _POSIX_C_SOURCE 200809L

#include <libfuturo/libfuturo.h>

#include "muhtari_fixture.h"
#include "muhtari_oracle.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef LIBFUTURO_MUHTARI_SOURCE_REVISION
#define LIBFUTURO_MUHTARI_SOURCE_REVISION "unverified"
#endif

#define VIDEO_WIDTH 320U
#define VIDEO_HEIGHT 242U
#define VIDEO_PADDING 3U
#define VIDEO_STRIDE ((size_t)VIDEO_WIDTH + (size_t)VIDEO_PADDING)
#define VIDEO_BUFFER_BYTES (VIDEO_STRIDE * (size_t)VIDEO_HEIGHT + 7U)
#define AUDIO_BUFFER_SAMPLES 805U
#define OUTPUT_SENTINEL UINT8_C(0xA5)
#define AUDIO_SENTINEL INT16_C(0x5A5A)

static int g_wrong_index_oracle = 0;

static int fail(const char *message) {
  (void)fprintf(stderr, "muhtari_session: %s failed\n", message);
  return 1;
}

static int profile_matches(const lf_profile *profile,
                           const char *configuration_id,
                           uint32_t input_mask) {
  return profile->profile_id != NULL &&
         strcmp(profile->profile_id, "muhtari-ntsc-v1") == 0 &&
         profile->core_id != NULL && strcmp(profile->core_id, "muhtari") == 0 &&
         profile->api_revision == 7U && profile->behavior_revision == 6U &&
         profile->input_mask == input_mask &&
         profile->max_work_units == 1U &&
         profile->max_guest_units == UINT32_MAX &&
         profile->atomic_quantum_units == 1U &&
         profile->max_overshoot_units == 0U &&
         profile->time_unit == LF_TIME_FRAME &&
         profile->input_sampling == LF_INPUT_AT_ADVANCE_START &&
         profile->video_format == LF_VIDEO_INDEX8 &&
         profile->video_width == VIDEO_WIDTH &&
         profile->video_height == VIDEO_HEIGHT &&
         profile->video_bytes_per_pixel == 1U &&
         profile->frame_rate_numerator == 39375000U &&
         profile->frame_rate_denominator == 656711U &&
         profile->audio_encoding == LF_AUDIO_S16_NATIVE &&
         profile->audio_layout == LF_AUDIO_INTERLEAVED &&
         profile->audio_rate_numerator == 48000U &&
         profile->audio_rate_denominator == 1U &&
         profile->audio_channels == 1U &&
         profile->max_audio_samples_per_call == 801U &&
         profile->max_content_bytes == 1048704U &&
         profile->effective_configuration_id != NULL &&
         strcmp(profile->effective_configuration_id, configuration_id) == 0;
}

static int capabilities_match(void) {
  static const lf_capability supported[] = {
      LF_CAP_LOGICAL_INPUT,
      LF_CAP_BOUNDED_EXECUTION,
      LF_CAP_SOFTWARE_VIDEO,
      LF_CAP_AUDIO,
  };
  static const lf_capability unsupported[] = {
      LF_CAP_IN_MEMORY_MEDIA_COPY,
      LF_CAP_SNAPSHOT,
      LF_CAP_HARDWARE_VIDEO,
      LF_CAP_CONCURRENT_USE,
  };
  uint32_t value = 0U;
  for (size_t index = 0U; index < sizeof(supported) / sizeof(supported[0]);
       ++index) {
    value = 0U;
    if (lf_get_capability("muhtari-ntsc-v1", NULL, supported[index],
                          &value) !=
            LF_OK ||
        value != 1U) {
      return 0;
    }
  }
  for (size_t index = 0U;
       index < sizeof(unsupported) / sizeof(unsupported[0]); ++index) {
    value = 1U;
    if (lf_get_capability("muhtari-ntsc-v1", NULL, unsupported[index],
                          &value) !=
            LF_UNSUPPORTED ||
        value != 0U) {
      return 0;
    }
  }
  value = 0U;
  if (lf_get_capability("muhtari-ntsc-v1",
                        "muhtari-ntsc-battery-diagnostic",
                        LF_CAP_IN_MEMORY_MEDIA_COPY, &value) != LF_OK ||
      value != 1U) {
    return 0;
  }
  value = 0U;
  if (lf_get_capability("muhtari-ntsc-v1", "unknown-configuration",
                        LF_CAP_LOGICAL_INPUT, &value) != LF_UNSUPPORTED ||
      value != 0U) {
    return 0;
  }
  return 1;
}

static int padding_is_untouched(const uint8_t *video) {
  for (size_t row = 0U; row < (size_t)VIDEO_HEIGHT; ++row) {
    for (size_t padding = 0U; padding < (size_t)VIDEO_PADDING; ++padding) {
      if (video[row * VIDEO_STRIDE + (size_t)VIDEO_WIDTH + padding] !=
          OUTPUT_SENTINEL) {
        return 0;
      }
    }
  }
  for (size_t at = VIDEO_STRIDE * (size_t)VIDEO_HEIGHT;
       at < VIDEO_BUFFER_BYTES; ++at) {
    if (video[at] != OUTPUT_SENTINEL) {
      return 0;
    }
  }
  return 1;
}

static int output_tail_is_untouched(const int16_t *audio, size_t produced) {
  for (size_t index = produced; index < (size_t)AUDIO_BUFFER_SAMPLES;
       ++index) {
    if (audio[index] != AUDIO_SENTINEL) {
      return 0;
    }
  }
  return 1;
}

static int indexed_image_matches(const uint8_t *video, size_t stride,
                                 size_t interval_index, uint8_t color) {
  if (video == NULL || stride < (size_t)VIDEO_WIDTH ||
      interval_index >= LF_MUHTARI_ORACLE_FRAME_COUNT) {
    return 0;
  }
  for (size_t y = 0U; y < (size_t)VIDEO_HEIGHT; ++y) {
    for (size_t x = 0U; x < (size_t)VIDEO_WIDTH; ++x) {
      uint8_t expected = color;
      if (interval_index == 0U &&
          (y < LF_MUHTARI_ORACLE_FIRST_BACKGROUND_ROW ||
           (y == LF_MUHTARI_ORACLE_FIRST_BACKGROUND_ROW &&
            x < LF_MUHTARI_ORACLE_FIRST_CHANGED_PIXEL))) {
        expected = UINT8_C(0x00);
      }
      if (g_wrong_index_oracle != 0 && interval_index == 0U && y == 0U &&
          x == 0U) {
        expected = UINT8_C(0x01);
      }
      if (video[y * stride + x] != expected) {
        (void)fprintf(stderr,
                      "muhtari_oracle: index mismatch row=%zu pixel=%zu "
                      "expected=0x%02x actual=0x%02x\n",
                      y, x, (unsigned int)expected,
                      (unsigned int)video[y * stride + x]);
        return 0;
      }
    }
  }
  return 1;
}

static int advance_and_check(lf_instance *instance, uint32_t buttons,
                             uint8_t expected_color, size_t interval_index,
                             uint8_t *video, int16_t *audio,
                             lf_run_result *result, int submit_input) {
  const size_t expected_samples =
      lf_muhtari_oracle_sample_counts[interval_index];
  lf_input input = {.struct_size = sizeof(input), .buttons = buttons};
  lf_run_request request = {
      .struct_size = sizeof(request),
      .work_units = 1U,
      .video_data = video,
      .video_capacity_bytes = VIDEO_BUFFER_BYTES,
      .video_stride_bytes = VIDEO_STRIDE,
      .audio_data = audio,
      .audio_capacity_samples = (size_t)AUDIO_BUFFER_SAMPLES,
  };
  if (submit_input != 0 && lf_set_input(instance, &input) != LF_OK) {
    return 0;
  }
  memset(video, OUTPUT_SENTINEL, VIDEO_BUFFER_BYTES);
  for (size_t index = 0U; index < (size_t)AUDIO_BUFFER_SAMPLES; ++index) {
    audio[index] = AUDIO_SENTINEL;
  }
  *result = (lf_run_result){.struct_size = sizeof(*result)};
  {
    const lf_status status = lf_advance(instance, &request, result);
    if (status != LF_OK) {
      (void)fprintf(stderr, "muhtari_session: advance status=%d\n",
                    (int)status);
      return 0;
    }
  }
  if (
      result->requested_units != 1U || result->actual_units != 1U ||
      result->overshoot_units != 0U || result->sampled_buttons != buttons ||
      result->video_valid != 1U || result->audio_valid != 1U ||
      result->cumulative_units != (uint64_t)interval_index + 1U ||
      result->core_ticks_valid != 0U ||
      result->cumulative_core_ticks != 0U || result->video_format != LF_VIDEO_INDEX8 ||
      result->audio_produced_samples != expected_samples ||
      result->video_extent_bytes !=
          (VIDEO_STRIDE * ((size_t)VIDEO_HEIGHT - 1U) + (size_t)VIDEO_WIDTH)) {
    (void)fprintf(stderr,
                  "muhtari_session: progress=%" PRIu64 " actual=%" PRIu32
                  " samples=%zu extent=%zu\n",
                  result->cumulative_units, result->actual_units,
                  result->audio_produced_samples, result->video_extent_bytes);
    return 0;
  }
  if (!indexed_image_matches(video, VIDEO_STRIDE, interval_index,
                             expected_color)) {
    return 0;
  }
  {
    char actual_pcm[65];
    if (!lf_muhtari_oracle_pcm_matches(audio, expected_samples,
                                       interval_index, actual_pcm)) {
      (void)fprintf(stderr,
                    "muhtari_session: PCM interval=%zu samples=%zu "
                    "expected=%s actual=%s\n",
                    interval_index + 1U, expected_samples,
                    interval_index < LF_MUHTARI_ORACLE_FRAME_COUNT
                        ? lf_muhtari_oracle_pcm_sha256[interval_index]
                        : "out-of-range",
                    actual_pcm);
      return 0;
    }
  }
  if (!padding_is_untouched(video) ||
      !output_tail_is_untouched(audio, expected_samples) ||
      !lf_muhtari_oracle_audio_non_silent(audio, expected_samples)) {
    (void)fprintf(stderr,
                  "muhtari_session: output guards/non-silence padding=%d "
                  "tail=%d audio0=%d\n",
                  padding_is_untouched(video),
                  output_tail_is_untouched(audio, expected_samples),
                  (int)audio[0]);
    return 0;
  }
  return 1;
}

static int load_result_matches(const lf_load_result *result, int loaded,
                               size_t content_bytes) {
  return result != NULL && result->struct_size == sizeof(*result) &&
         result->loaded == (loaded != 0 ? 1U : 0U) &&
         result->content_size_bytes == (loaded != 0 ? content_bytes : 0U) &&
         (loaded != 0
              ? result->effective_configuration_id != NULL &&
                    strcmp(result->effective_configuration_id,
                           "muhtari-ntsc-joystick-default") == 0
              : result->effective_configuration_id == NULL);
}

static void digest_bytes(const uint8_t *bytes, size_t count, uint8_t digest[32]) {
  lf_muhtari_oracle_sha256 context;
  lf_muhtari_oracle_sha256_init(&context);
  lf_muhtari_oracle_sha256_update(&context, bytes, count);
  lf_muhtari_oracle_sha256_finish(&context, digest);
}

typedef struct load_refusal_case {
  const char *name;
  lf_status expected;
  lf_load_request request;
  const lf_load_request *request_pointer;
  const uint8_t *content;
  size_t content_bytes;
} load_refusal_case;

typedef struct load_allocation_tracker {
  void *live[32];
  size_t live_count;
  size_t calls;
  size_t successful_allocations;
  size_t frees;
  size_t fail_at_call;
  size_t failed_allocations;
  size_t invalid_frees;
} load_allocation_tracker;

static void *load_tracked_allocate(void *context, size_t bytes) {
  load_allocation_tracker *tracker = (load_allocation_tracker *)context;
  void *allocation = NULL;
  if (tracker == NULL) {
    return NULL;
  }
  tracker->calls += 1U;
  if (tracker->fail_at_call != 0U && tracker->calls == tracker->fail_at_call) {
    tracker->failed_allocations += 1U;
    return NULL;
  }
  if (tracker->live_count >= sizeof(tracker->live) / sizeof(tracker->live[0])) {
    return NULL;
  }
  allocation = malloc(bytes == 0U ? 1U : bytes);
  if (allocation == NULL) {
    return NULL;
  }
  tracker->live[tracker->live_count] = allocation;
  tracker->live_count += 1U;
  tracker->successful_allocations += 1U;
  return allocation;
}

static void load_tracked_deallocate(void *context, void *allocation) {
  load_allocation_tracker *tracker = (load_allocation_tracker *)context;
  if (tracker == NULL || allocation == NULL) {
    return;
  }
  for (size_t index = 0U; index < tracker->live_count; ++index) {
    if (tracker->live[index] == allocation) {
      tracker->live[index] = tracker->live[tracker->live_count - 1U];
      tracker->live[tracker->live_count - 1U] = NULL;
      tracker->live_count -= 1U;
      tracker->frees += 1U;
      free(allocation);
      return;
    }
  }
  tracker->invalid_frees += 1U;
}

static int create_tracked_instance(load_allocation_tracker *tracker,
                                   lf_instance **instance) {
  const lf_create_options options = {
      .struct_size = sizeof(options),
      .allocate = load_tracked_allocate,
      .deallocate = load_tracked_deallocate,
      .allocator_context = tracker,
  };
  return tracker != NULL && instance != NULL &&
         lf_create("muhtari-ntsc-v1", &options, instance) == LF_OK &&
         *instance != NULL;
}

static int load_fixture(lf_instance *instance, const uint8_t *content,
                        size_t content_bytes, const char *configuration,
                        lf_load_result *result) {
  const lf_load_request request = {
      .struct_size = sizeof(request),
      .content_data = content,
      .content_size_bytes = content_bytes,
      .configuration_id = configuration,
  };
  *result = (lf_load_result){.struct_size = sizeof(*result)};
  return lf_load(instance, &request, result) == LF_OK &&
         load_result_matches(result, 1, content_bytes);
}

static int attempt_refusal(const load_refusal_case *test_case,
                           lf_instance *subject, int was_loaded,
                           size_t active_extent, uint8_t *content_snapshot,
                           size_t snapshot_bytes) {
  lf_load_result result = {.struct_size = sizeof(result)};
  uint8_t before_digest[32] = {0};
  uint8_t after_digest[32] = {0};
  if (test_case == NULL || subject == NULL ||
      (test_case->content != NULL &&
       (content_snapshot == NULL || snapshot_bytes != test_case->content_bytes))) {
    return 0;
  }
  if (test_case->content != NULL) {
    digest_bytes(test_case->content, test_case->content_bytes, before_digest);
    memcpy(content_snapshot, test_case->content, snapshot_bytes);
  }
  result = (lf_load_result){.struct_size = sizeof(result)};
  if (lf_load(subject, test_case->request_pointer, &result) !=
          test_case->expected ||
      !load_result_matches(&result, was_loaded, active_extent)) {
    (void)fprintf(stderr,
                  "muhtari_session: refusal case=%s status/state mismatch\n",
                  test_case->name);
    return 0;
  }
  if (test_case->content != NULL) {
    digest_bytes(test_case->content, test_case->content_bytes, after_digest);
    if (memcmp(before_digest, after_digest, sizeof(before_digest)) != 0 ||
        memcmp(content_snapshot, test_case->content, snapshot_bytes) != 0) {
      (void)fprintf(stderr,
                    "muhtari_session: refusal case=%s caller bytes changed\n",
                    test_case->name);
      return 0;
    }
  }
  return 1;
}

static int continue_after_refusal(const load_refusal_case *test_case,
                                  const uint8_t *fixture,
                                  size_t fixture_bytes, int loaded_history) {
  lf_instance *subject = NULL;
  lf_instance *control = NULL;
  lf_load_result subject_load = {.struct_size = sizeof(subject_load)};
  lf_load_result control_load = {.struct_size = sizeof(control_load)};
  lf_load_result unloaded_result = {.struct_size = sizeof(unloaded_result)};
  lf_run_result subject_run = {.struct_size = sizeof(subject_run)};
  lf_run_result control_run = {.struct_size = sizeof(control_run)};
  uint8_t *candidate_snapshot = NULL;
  uint8_t subject_video[VIDEO_BUFFER_BYTES];
  uint8_t control_video[VIDEO_BUFFER_BYTES];
  int16_t subject_audio[AUDIO_BUFFER_SAMPLES];
  int16_t control_audio[AUDIO_BUFFER_SAMPLES];
  int ok = 0;

  if (test_case->content != NULL) {
    candidate_snapshot = (uint8_t *)malloc(test_case->content_bytes);
    if (candidate_snapshot == NULL) {
      goto cleanup;
    }
  }
  if (lf_create("muhtari-ntsc-v1", NULL, &subject) != LF_OK ||
      subject == NULL) {
    goto cleanup;
  }
  if (loaded_history != 0) {
    if (lf_create("muhtari-ntsc-v1", NULL, &control) != LF_OK ||
        control == NULL ||
        !load_fixture(subject, fixture, fixture_bytes,
                      "muhtari-ntsc-joystick-default", &subject_load) ||
        !load_fixture(control, fixture, fixture_bytes,
                      "muhtari-ntsc-joystick-default", &control_load) ||
        !advance_and_check(subject, UINT32_C(0x0001),
                           LF_MUHTARI_ORACLE_PORT0_FIRE_COLOR, 0U,
                           subject_video, subject_audio, &subject_run, 1) ||
        !advance_and_check(control, UINT32_C(0x0001),
                           LF_MUHTARI_ORACLE_PORT0_FIRE_COLOR, 0U,
                           control_video, control_audio, &control_run, 1)) {
      goto cleanup;
    }
    if (lf_set_input(subject,
                     &(lf_input){.struct_size = sizeof(lf_input),
                                 .buttons = UINT32_C(0x0100)}) != LF_OK ||
        lf_set_input(control,
                     &(lf_input){.struct_size = sizeof(lf_input),
                                 .buttons = UINT32_C(0x0100)}) != LF_OK) {
      goto cleanup;
    }
    if (!attempt_refusal(test_case, subject, 1, fixture_bytes,
                         candidate_snapshot, test_case->content_bytes)) {
      goto cleanup;
    }
    for (size_t step = 0U; step < 3U; ++step) {
      const uint32_t input = step == 0U ? UINT32_C(0x0100)
                              : step == 1U ? UINT32_C(0x0000)
                                           : UINT32_C(0x0101);
      const uint8_t color = step == 0U ? LF_MUHTARI_ORACLE_PORT1_FIRE_COLOR
                             : step == 1U ? LF_MUHTARI_ORACLE_RELEASED_COLOR
                                          : LF_MUHTARI_ORACLE_BOTH_FIRE_COLOR;
      const size_t interval_index = step + 1U;
      if (!advance_and_check(subject, input, color, interval_index,
                             subject_video, subject_audio, &subject_run,
                             step != 0U) ||
          !advance_and_check(control, input, color, interval_index,
                             control_video, control_audio, &control_run,
                             step != 0U) ||
          memcmp(subject_video, control_video, sizeof(subject_video)) != 0 ||
          memcmp(subject_audio, control_audio, sizeof(subject_audio)) != 0) {
        (void)fprintf(stderr,
                      "muhtari_session: refusal case=%s continuation=%zu mismatch\n",
                      test_case->name, step + 1U);
        goto cleanup;
      }
    }
  } else {
    if (!attempt_refusal(test_case, subject, 0, 0U, candidate_snapshot,
                         test_case->content_bytes) ||
        !load_fixture(subject, fixture, fixture_bytes, NULL, &unloaded_result) ||
        !advance_and_check(subject, UINT32_C(0x0001),
                           LF_MUHTARI_ORACLE_PORT0_FIRE_COLOR, 0U,
                           subject_video, subject_audio, &subject_run, 1)) {
      goto cleanup;
    }
  }
  ok = 1;
cleanup:
  if (lf_destroy(&subject) != LF_OK || lf_destroy(&control) != LF_OK) {
    ok = 0;
  }
  free(candidate_snapshot);
  return ok;
}

static int tracker_unchanged(const load_allocation_tracker *tracker,
                             const void *const *expected,
                             size_t expected_count) {
  if (tracker == NULL || tracker->live_count != expected_count ||
      tracker->invalid_frees != 0U) {
    return 0;
  }
  for (size_t index = 0U; index < expected_count; ++index) {
    int found = 0;
    for (size_t live = 0U; live < tracker->live_count; ++live) {
      if (tracker->live[live] == expected[index]) {
        found = 1;
        break;
      }
    }
    if (found == 0) {
      return 0;
    }
  }
  return 1;
}

static size_t measure_candidate_allocations(const uint8_t *fixture,
                                            size_t fixture_bytes) {
  load_allocation_tracker tracker = {0};
  lf_instance *instance = NULL;
  lf_load_result result = {.struct_size = sizeof(result)};
  size_t calls_before = 0U;
  size_t allocations = 0U;
  if (!create_tracked_instance(&tracker, &instance)) {
    goto cleanup;
  }
  if (!load_fixture(instance, fixture, fixture_bytes, NULL, &result)) {
    goto cleanup;
  }
  calls_before = tracker.calls;
  if (!load_fixture(instance, fixture, fixture_bytes, NULL, &result)) {
    goto cleanup;
  }
  allocations = tracker.calls - calls_before;
cleanup:
  if (lf_destroy(&instance) != LF_OK || tracker.live_count != 0U ||
      tracker.invalid_frees != 0U) {
    allocations = 0U;
  }
  return allocations;
}

static int allocator_refusal_continues(const uint8_t *fixture,
                                       size_t fixture_bytes,
                                       size_t ordinal) {
  load_allocation_tracker tracker = {0};
  lf_instance *subject = NULL;
  lf_instance *control = NULL;
  lf_load_result loaded = {.struct_size = sizeof(loaded)};
  lf_load_result refused = {.struct_size = sizeof(refused)};
  lf_run_result subject_run = {.struct_size = sizeof(subject_run)};
  lf_run_result control_run = {.struct_size = sizeof(control_run)};
  uint8_t subject_video[VIDEO_BUFFER_BYTES];
  uint8_t control_video[VIDEO_BUFFER_BYTES];
  int16_t subject_audio[AUDIO_BUFFER_SAMPLES];
  int16_t control_audio[AUDIO_BUFFER_SAMPLES];
  void *live_before[32] = {0};
  size_t live_count_before = 0U;
  size_t calls_before = 0U;
  int ok = 0;

  if (!create_tracked_instance(&tracker, &subject) ||
      lf_create("muhtari-ntsc-v1", NULL, &control) != LF_OK ||
      control == NULL ||
      !load_fixture(subject, fixture, fixture_bytes, NULL, &loaded) ||
      !load_fixture(control, fixture, fixture_bytes, NULL, &loaded) ||
      !advance_and_check(subject, UINT32_C(0x0001),
                         LF_MUHTARI_ORACLE_PORT0_FIRE_COLOR, 0U,
                         subject_video, subject_audio, &subject_run, 1) ||
      !advance_and_check(control, UINT32_C(0x0001),
                         LF_MUHTARI_ORACLE_PORT0_FIRE_COLOR, 0U,
                         control_video, control_audio, &control_run, 1) ||
      lf_set_input(subject,
                   &(lf_input){.struct_size = sizeof(lf_input),
                               .buttons = UINT32_C(0x0100)}) != LF_OK ||
      lf_set_input(control,
                   &(lf_input){.struct_size = sizeof(lf_input),
                               .buttons = UINT32_C(0x0100)}) != LF_OK) {
    goto cleanup;
  }

  calls_before = tracker.calls;
  live_count_before = tracker.live_count;
  memcpy(live_before, tracker.live,
         live_count_before * sizeof(live_before[0]));
  tracker.fail_at_call = calls_before + ordinal;
  refused.struct_size = sizeof(refused);
  if (lf_load(subject,
              &(lf_load_request){.struct_size = sizeof(lf_load_request),
                                 .content_data = fixture,
                                 .content_size_bytes = fixture_bytes},
              &refused) != LF_RESOURCE_EXHAUSTED ||
      !load_result_matches(&refused, 1, fixture_bytes) ||
      tracker.failed_allocations != 1U ||
      tracker.calls != calls_before + ordinal ||
      !tracker_unchanged(&tracker, (const void *const *)live_before,
                         live_count_before)) {
    (void)fprintf(stderr,
                  "muhtari_session: allocation-refusal ordinal=%zu state/ownership mismatch\n",
                  ordinal);
    goto cleanup;
  }
  tracker.fail_at_call = 0U;
  for (size_t step = 0U; step < 3U; ++step) {
    const uint32_t input = step == 0U ? UINT32_C(0x0100)
                            : step == 1U ? UINT32_C(0x0000)
                                         : UINT32_C(0x0101);
    const uint8_t color = step == 0U ? LF_MUHTARI_ORACLE_PORT1_FIRE_COLOR
                           : step == 1U ? LF_MUHTARI_ORACLE_RELEASED_COLOR
                                        : LF_MUHTARI_ORACLE_BOTH_FIRE_COLOR;
    const size_t interval_index = step + 1U;
    if (!advance_and_check(subject, input, color, interval_index,
                           subject_video, subject_audio, &subject_run,
                           step != 0U) ||
        !advance_and_check(control, input, color, interval_index,
                           control_video, control_audio, &control_run,
                           step != 0U) ||
        memcmp(subject_video, control_video, sizeof(subject_video)) != 0 ||
        memcmp(subject_audio, control_audio, sizeof(subject_audio)) != 0) {
      goto cleanup;
    }
  }
  ok = 1;
cleanup:
  if (lf_destroy(&subject) != LF_OK || lf_destroy(&control) != LF_OK ||
      tracker.live_count != 0U || tracker.invalid_frees != 0U ||
      tracker.successful_allocations != tracker.frees) {
    ok = 0;
  }
  return ok;
}

static int replacement_resets(const char *initial_configuration,
                              const char *replacement_configuration) {
  uint8_t content[LF_MUHTARI_FIXTURE_TOTAL_BYTES];
  uint8_t video[VIDEO_BUFFER_BYTES];
  int16_t audio[AUDIO_BUFFER_SAMPLES];
  lf_instance *instance = NULL;
  lf_load_result loaded = {.struct_size = sizeof(loaded)};
  lf_load_result replaced = {.struct_size = sizeof(replaced)};
  lf_run_result result = {.struct_size = sizeof(result)};
  const size_t content_bytes =
      lf_build_muhtari_fixture(content, sizeof(content));
  int ok = 0;

  if (content_bytes != sizeof(content) ||
      lf_create("muhtari-ntsc-v1", NULL, &instance) != LF_OK ||
      instance == NULL ||
      !load_fixture(instance, content, content_bytes, initial_configuration,
                    &loaded) ||
      !advance_and_check(instance, UINT32_C(0x0001),
                         LF_MUHTARI_ORACLE_PORT0_FIRE_COLOR, 0U, video, audio,
                         &result, 1) ||
      lf_set_input(instance,
                   &(lf_input){.struct_size = sizeof(lf_input),
                               .buttons = UINT32_C(0x0100)}) != LF_OK ||
      !load_fixture(instance, content, content_bytes,
                    replacement_configuration, &replaced) ||
      replaced.content_size_bytes != content_bytes ||
      replaced.effective_configuration_id == NULL ||
      strcmp(replaced.effective_configuration_id,
             "muhtari-ntsc-joystick-default") != 0) {
    goto cleanup;
  }

  /* A successful replacement owns its bytes before the caller can change them. */
  content[0] ^= UINT8_C(0xFF);
  memset(video, OUTPUT_SENTINEL, sizeof(video));
  for (size_t index = 0U; index < AUDIO_BUFFER_SAMPLES; ++index) {
    audio[index] = AUDIO_SENTINEL;
  }
  result.struct_size = sizeof(result);
  if (lf_advance(instance,
                 &(lf_run_request){.struct_size = sizeof(lf_run_request),
                                   .work_units = 1U,
                                   .video_data = video,
                                   .video_capacity_bytes = sizeof(video),
                                   .video_stride_bytes = VIDEO_STRIDE,
                                   .audio_data = audio,
                                   .audio_capacity_samples = AUDIO_BUFFER_SAMPLES},
                 &result) != LF_OK ||
      result.actual_units != 1U || result.sampled_buttons != 0U ||
      result.cumulative_units != 1U || result.audio_produced_samples != 54U ||
      result.video_valid != 1U || result.audio_valid != 1U ||
      !lf_muhtari_oracle_pcm_matches(audio, 54U, 0U, (char[65]){0}) ||
      !output_tail_is_untouched(audio, 54U) || !padding_is_untouched(video)) {
    goto cleanup;
  }
  if (!advance_and_check(instance, UINT32_C(0x0001),
                         LF_MUHTARI_ORACLE_PORT0_FIRE_COLOR, 1U, video, audio,
                         &result, 1)) {
    goto cleanup;
  }
  ok = 1;
cleanup:
  if (lf_destroy(&instance) != LF_OK) {
    ok = 0;
  }
  return ok;
}

static int run_load_refusals(void) {
  static const char unavailable_configuration[] = "muhtari-ntsc-pal";
  const size_t max_plus_one = (size_t)1048704U + 1U;
  uint8_t *oversized_content = (uint8_t *)malloc(max_plus_one);
  uint8_t unsupported_2600[2048] = {0};
  uint8_t fixture[LF_MUHTARI_FIXTURE_TOTAL_BYTES];
  const size_t fixture_bytes = lf_build_muhtari_fixture(fixture, sizeof(fixture));
  load_refusal_case cases[8];
  size_t case_count = 0U;
  int result = 1;

  if (oversized_content == NULL || fixture_bytes != sizeof(fixture)) {
    goto cleanup;
  }
  memset(oversized_content, UINT8_C(0x69), max_plus_one);
  cases[case_count++] = (load_refusal_case){
      .name = "null-request", .expected = LF_INVALID_ARGUMENT,
      .request_pointer = NULL};
  cases[case_count] = (load_refusal_case){
      .name = "bad-record-size", .expected = LF_INVALID_ARGUMENT,
      .request = {.struct_size = sizeof(lf_load_request) - 1U,
                  .content_data = fixture, .content_size_bytes = fixture_bytes},
      .content = fixture, .content_bytes = fixture_bytes};
  cases[case_count].request_pointer = &cases[case_count].request;
  case_count += 1U;
  cases[case_count] = (load_refusal_case){
      .name = "null-content", .expected = LF_INVALID_ARGUMENT,
      .request = {.struct_size = sizeof(lf_load_request),
                  .content_data = NULL, .content_size_bytes = fixture_bytes}};
  cases[case_count].request_pointer = &cases[case_count].request;
  case_count += 1U;
  cases[case_count] = (load_refusal_case){
      .name = "empty-content", .expected = LF_INVALID_ARGUMENT,
      .request = {.struct_size = sizeof(lf_load_request),
                  .content_data = fixture, .content_size_bytes = 0U},
      .content = fixture, .content_bytes = fixture_bytes};
  cases[case_count].request_pointer = &cases[case_count].request;
  case_count += 1U;
  cases[case_count] = (load_refusal_case){
      .name = "unavailable-configuration", .expected = LF_UNSUPPORTED,
      .request = {.struct_size = sizeof(lf_load_request),
                  .content_data = fixture, .content_size_bytes = fixture_bytes,
                  .configuration_id = unavailable_configuration},
      .content = fixture, .content_bytes = fixture_bytes};
  cases[case_count].request_pointer = &cases[case_count].request;
  case_count += 1U;
  cases[case_count] = (load_refusal_case){
      .name = "content-limit-plus-one", .expected = LF_LIMIT_EXCEEDED,
      .request = {.struct_size = sizeof(lf_load_request),
                  .content_data = oversized_content,
                  .content_size_bytes = max_plus_one},
      .content = oversized_content, .content_bytes = max_plus_one};
  cases[case_count].request_pointer = &cases[case_count].request;
  case_count += 1U;
  cases[case_count] = (load_refusal_case){
      .name = "native-truncated-a78", .expected = LF_INVALID_ARGUMENT,
      .request = {.struct_size = sizeof(lf_load_request),
                  .content_data = fixture,
                  .content_size_bytes = LF_MUHTARI_FIXTURE_HEADER_BYTES},
      .content = fixture, .content_bytes = fixture_bytes};
  cases[case_count].request_pointer = &cases[case_count].request;
  case_count += 1U;
  cases[case_count] = (load_refusal_case){
      .name = "native-unsupported-2600", .expected = LF_UNSUPPORTED,
      .request = {.struct_size = sizeof(lf_load_request),
                  .content_data = unsupported_2600,
                  .content_size_bytes = sizeof(unsupported_2600)},
      .content = unsupported_2600, .content_bytes = sizeof(unsupported_2600)};
  cases[case_count].request_pointer = &cases[case_count].request;
  case_count += 1U;

  if (case_count != sizeof(cases) / sizeof(cases[0])) {
    goto cleanup;
  }
  for (size_t index = 0U; index < case_count; ++index) {
    if (!continue_after_refusal(&cases[index], fixture, fixture_bytes, 1) ||
        !continue_after_refusal(&cases[index], fixture, fixture_bytes, 0)) {
      goto cleanup;
    }
  }

  {
    const size_t observed_allocations =
        measure_candidate_allocations(fixture, fixture_bytes);
    if (observed_allocations == 0U) {
      (void)fail("candidate allocation baseline is measured and balanced");
      goto cleanup;
    }
    for (size_t ordinal = 1U; ordinal <= observed_allocations; ++ordinal) {
      if (!allocator_refusal_continues(fixture, fixture_bytes, ordinal)) {
        (void)fprintf(stderr,
                      "muhtari_session: allocation refusal ordinal=%zu failed\n",
                      ordinal);
        goto cleanup;
      }
    }
    if (!replacement_resets(NULL, "muhtari-ntsc-joystick-default") ||
        !replacement_resets("muhtari-ntsc-joystick-default", NULL)) {
      (void)fail("successful default/explicit replacement resets input and progress");
      goto cleanup;
    }
  }

  result = 0;
cleanup:
  free(oversized_content);
  if (result == 0) {
    (void)printf("muhtari_load_refusals: cases=%zu histories=loaded,unloaded "
                 "continuation=3 allocation-ordinals=measured "
                 "default-reset=pass result=pass\n",
                 case_count);
  }
  return result;
}

typedef enum boundary_rejection {
  BOUNDARY_SHORT_REQUEST,
  BOUNDARY_LARGE_REQUEST,
  BOUNDARY_SHORT_RESULT,
  BOUNDARY_LARGE_RESULT,
  BOUNDARY_NULL_RESULT,
  BOUNDARY_UNLOADED,
  BOUNDARY_NULL_VIDEO,
  BOUNDARY_NULL_AUDIO,
  BOUNDARY_TWO_WORK_UNITS,
  BOUNDARY_SHORT_STRIDE,
  BOUNDARY_OVERFLOWING_STRIDE,
  BOUNDARY_OVERFLOWING_STRIDE_ADD,
  BOUNDARY_SHORT_VIDEO_CAPACITY,
  BOUNDARY_SHORT_AUDIO_CAPACITY
} boundary_rejection;

static int boundary_pair_create(lf_instance **subject, lf_instance **control,
                                int load) {
  uint8_t fixture[LF_MUHTARI_FIXTURE_TOTAL_BYTES];
  const size_t fixture_bytes = lf_build_muhtari_fixture(fixture, sizeof(fixture));
  lf_load_result result = {.struct_size = sizeof(result)};
  if (fixture_bytes != sizeof(fixture) ||
      lf_create("muhtari-ntsc-v1", NULL, subject) != LF_OK ||
      lf_create("muhtari-ntsc-v1", NULL, control) != LF_OK) {
    return 0;
  }
  if (load != 0 &&
      (!load_fixture(*subject, fixture, fixture_bytes, NULL, &result) ||
       !load_fixture(*control, fixture, fixture_bytes, NULL, &result))) {
    return 0;
  }
  return 1;
}

static int boundary_queue_input(lf_instance *subject, lf_instance *control,
                                uint32_t buttons) {
  const lf_input input = {.struct_size = sizeof(input), .buttons = buttons};
  return lf_set_input(subject, &input) == LF_OK &&
         lf_set_input(control, &input) == LF_OK;
}

static int boundary_followup(lf_instance *subject, lf_instance *control,
                             uint32_t buttons) {
  uint8_t subject_video[VIDEO_BUFFER_BYTES];
  uint8_t control_video[VIDEO_BUFFER_BYTES];
  int16_t subject_audio[AUDIO_BUFFER_SAMPLES];
  int16_t control_audio[AUDIO_BUFFER_SAMPLES];
  lf_run_result subject_result = {.struct_size = sizeof(subject_result)};
  lf_run_result control_result = {.struct_size = sizeof(control_result)};
  const uint8_t expected_color =
      buttons == UINT32_C(0x0001) ? LF_MUHTARI_ORACLE_PORT0_FIRE_COLOR
      : buttons == UINT32_C(0x0100) ? LF_MUHTARI_ORACLE_PORT1_FIRE_COLOR
      : buttons == UINT32_C(0x0101) ? LF_MUHTARI_ORACLE_BOTH_FIRE_COLOR
                                    : LF_MUHTARI_ORACLE_RELEASED_COLOR;
  return advance_and_check(subject, buttons, expected_color, 0U,
                           subject_video, subject_audio, &subject_result, 0) &&
         advance_and_check(control, buttons, expected_color, 0U,
                           control_video, control_audio, &control_result, 0) &&
         memcmp(subject_video, control_video, sizeof(subject_video)) == 0 &&
         memcmp(subject_audio, control_audio, sizeof(subject_audio)) == 0;
}

static int boundary_result_is_rejected(const lf_run_result *result) {
  return result != NULL && result->struct_size == sizeof(*result) &&
         result->actual_units == 0U && result->overshoot_units == 0U &&
         result->sampled_buttons == 0U && result->video_valid == 0U &&
         result->audio_valid == 0U && result->cumulative_units == 0U &&
         result->video_extent_bytes == 0U &&
         result->audio_produced_samples == 0U &&
         result->stop_reason == LF_STOP_REJECTED;
}

static int reject_frame_and_continue(boundary_rejection which,
                                     const char *name) {
  lf_instance *subject = NULL;
  lf_instance *control = NULL;
  uint8_t subject_video[VIDEO_BUFFER_BYTES];
  int16_t subject_audio[AUDIO_BUFFER_SAMPLES];
  uint8_t video_before[VIDEO_BUFFER_BYTES];
  int16_t audio_before[AUDIO_BUFFER_SAMPLES];
  lf_run_request request = {
      .struct_size = sizeof(request),
      .work_units = 1U,
      .video_data = subject_video,
      .video_capacity_bytes = sizeof(subject_video),
      .video_stride_bytes = VIDEO_STRIDE,
      .audio_data = subject_audio,
      .audio_capacity_samples = AUDIO_BUFFER_SAMPLES,
  };
  lf_run_result result;
  lf_run_result result_before;
  const size_t out_struct_size = sizeof(result);
  lf_status expected = LF_INVALID_ARGUMENT;
  int load = which != BOUNDARY_UNLOADED;
  int ok = 0;

  if (!boundary_pair_create(&subject, &control, load) || subject == NULL ||
      control == NULL) {
    goto cleanup;
  }
  if (load != 0 && !boundary_queue_input(subject, control, UINT32_C(0x0100))) {
    goto cleanup;
  }
  switch (which) {
  case BOUNDARY_SHORT_REQUEST:
    request.struct_size -= 1U;
    break;
  case BOUNDARY_LARGE_REQUEST:
    request.struct_size += 1U;
    break;
  case BOUNDARY_SHORT_RESULT:
    expected = LF_INVALID_ARGUMENT;
    break;
  case BOUNDARY_LARGE_RESULT:
    expected = LF_INVALID_ARGUMENT;
    break;
  case BOUNDARY_NULL_RESULT:
    break;
  case BOUNDARY_UNLOADED:
    break;
  case BOUNDARY_NULL_VIDEO:
    request.video_data = NULL;
    break;
  case BOUNDARY_NULL_AUDIO:
    request.audio_data = NULL;
    break;
  case BOUNDARY_TWO_WORK_UNITS:
    request.work_units = 2U;
    expected = LF_LIMIT_EXCEEDED;
    break;
  case BOUNDARY_SHORT_STRIDE:
    request.video_stride_bytes = (size_t)VIDEO_WIDTH - 1U;
    break;
  case BOUNDARY_OVERFLOWING_STRIDE:
    request.video_stride_bytes = SIZE_MAX;
    expected = LF_LIMIT_EXCEEDED;
    break;
  case BOUNDARY_OVERFLOWING_STRIDE_ADD:
    request.video_stride_bytes =
        SIZE_MAX / ((size_t)VIDEO_HEIGHT - 1U);
    expected = LF_LIMIT_EXCEEDED;
    break;
  case BOUNDARY_SHORT_VIDEO_CAPACITY:
    request.video_stride_bytes = (size_t)VIDEO_WIDTH;
    request.video_capacity_bytes =
        (size_t)VIDEO_WIDTH * (size_t)VIDEO_HEIGHT - 1U;
    expected = LF_BUFFER_TOO_SMALL;
    break;
  case BOUNDARY_SHORT_AUDIO_CAPACITY:
    request.audio_capacity_samples = 800U;
    expected = LF_BUFFER_TOO_SMALL;
    break;
  }

  memset(subject_video, OUTPUT_SENTINEL, sizeof(subject_video));
  for (size_t index = 0U; index < AUDIO_BUFFER_SAMPLES; ++index) {
    subject_audio[index] = AUDIO_SENTINEL;
  }
  memcpy(video_before, subject_video, sizeof(subject_video));
  memcpy(audio_before, subject_audio, sizeof(subject_audio));
  memset(&result, 0x5A, sizeof(result));
  result.struct_size = out_struct_size;
  if (which == BOUNDARY_SHORT_RESULT) {
    result.struct_size -= 1U;
  } else if (which == BOUNDARY_LARGE_RESULT) {
    result.struct_size += 1U;
  }
  result_before = result;
  {
    const lf_status status =
        which == BOUNDARY_NULL_RESULT
            ? lf_advance(subject, &request, NULL)
            : lf_advance(subject, &request, &result);
    if (status != expected) {
      (void)fprintf(stderr,
                    "muhtari_frame_boundaries: case=%s status=%d expected=%d\n",
                    name, (int)status, (int)expected);
      goto cleanup;
    }
  }
  if (memcmp(subject_video, video_before, sizeof(subject_video)) != 0 ||
      memcmp(subject_audio, audio_before, sizeof(subject_audio)) != 0) {
    (void)fprintf(stderr,
                  "muhtari_frame_boundaries: case=%s changed output before rejection\n",
                  name);
    goto cleanup;
  }
  if (which == BOUNDARY_SHORT_RESULT || which == BOUNDARY_LARGE_RESULT) {
    if (memcmp(&result, &result_before, sizeof(result)) != 0) {
      goto cleanup;
    }
  } else if (which != BOUNDARY_NULL_RESULT &&
             !boundary_result_is_rejected(&result)) {
    (void)fprintf(stderr,
                  "muhtari_frame_boundaries: case=%s result was not a zero-work rejection\n",
                  name);
    goto cleanup;
  }

  if (load == 0) {
    uint8_t fixture[LF_MUHTARI_FIXTURE_TOTAL_BYTES];
    const size_t fixture_bytes =
        lf_build_muhtari_fixture(fixture, sizeof(fixture));
    lf_load_result loaded = {.struct_size = sizeof(loaded)};
    if (!load_fixture(subject, fixture, fixture_bytes, NULL, &loaded) ||
        !load_fixture(control, fixture, fixture_bytes, NULL, &loaded) ||
        !boundary_queue_input(subject, control, UINT32_C(0x0100))) {
      goto cleanup;
    }
  }
  ok = boundary_followup(subject, control, UINT32_C(0x0100));
cleanup:
  if (lf_destroy(&subject) != LF_OK || lf_destroy(&control) != LF_OK) {
    ok = 0;
  }
  return ok;
}

static int reject_input_and_continue(size_t struct_size, uint32_t buttons,
                                     const char *name) {
  lf_instance *subject = NULL;
  lf_instance *control = NULL;
  lf_input input = {.struct_size = sizeof(input), .buttons = buttons};
  int ok = 0;
  if (!boundary_pair_create(&subject, &control, 1) || subject == NULL ||
      control == NULL ||
      !boundary_queue_input(subject, control, UINT32_C(0x0100))) {
    goto cleanup;
  }
  input.struct_size = struct_size;
  if (lf_set_input(subject, &input) != LF_INVALID_ARGUMENT ||
      !boundary_followup(subject, control, UINT32_C(0x0100))) {
    (void)fprintf(stderr,
                  "muhtari_frame_boundaries: input case=%s altered pending input\n",
                  name);
    goto cleanup;
  }
  ok = 1;
cleanup:
  if (lf_destroy(&subject) != LF_OK || lf_destroy(&control) != LF_OK) {
    ok = 0;
  }
  return ok;
}

static int valid_boundary_outputs(size_t stride, size_t video_capacity,
                                  size_t audio_capacity) {
  uint8_t content[LF_MUHTARI_FIXTURE_TOTAL_BYTES];
  uint8_t video[80000U];
  int16_t audio[805U];
  lf_instance *instance = NULL;
  lf_load_result loaded = {.struct_size = sizeof(loaded)};
  lf_run_result result = {.struct_size = sizeof(result)};
  lf_run_request request = {
      .struct_size = sizeof(request), .work_units = 1U,
      .video_data = video, .video_capacity_bytes = video_capacity,
      .video_stride_bytes = stride, .audio_data = audio,
      .audio_capacity_samples = audio_capacity,
  };
  const size_t fixture_bytes = lf_build_muhtari_fixture(content, sizeof(content));
  const size_t extent = stride * ((size_t)VIDEO_HEIGHT - 1U) +
                        (size_t)VIDEO_WIDTH;
  int ok = 0;
  if (video_capacity > sizeof(video) || audio_capacity > 805U ||
      fixture_bytes != sizeof(content) ||
      lf_create("muhtari-ntsc-v1", NULL, &instance) != LF_OK ||
      instance == NULL ||
      !load_fixture(instance, content, fixture_bytes, NULL, &loaded) ||
      lf_set_input(instance,
                   &(lf_input){.struct_size = sizeof(lf_input),
                               .buttons = UINT32_C(0x0100)}) != LF_OK) {
    goto cleanup;
  }
  memset(video, OUTPUT_SENTINEL, sizeof(video));
  for (size_t index = 0U; index < 805U; ++index) {
    audio[index] = AUDIO_SENTINEL;
  }
  if (lf_advance(instance, &request, &result) != LF_OK ||
      result.actual_units != 1U || result.cumulative_units != 1U ||
      result.sampled_buttons != UINT32_C(0x0100) ||
      result.audio_produced_samples != LF_MUHTARI_ORACLE_FIRST_FRAME_SAMPLES ||
      result.video_extent_bytes != extent ||
      !indexed_image_matches(video, stride, 0U,
                             LF_MUHTARI_ORACLE_PORT1_FIRE_COLOR) ||
      !lf_muhtari_oracle_pcm_matches(
          audio, LF_MUHTARI_ORACLE_FIRST_FRAME_SAMPLES, 0U, (char[65]){0}) ||
      !output_tail_is_untouched(audio,
                                LF_MUHTARI_ORACLE_FIRST_FRAME_SAMPLES)) {
    goto cleanup;
  }
  for (size_t row = 0U; row < (size_t)VIDEO_HEIGHT; ++row) {
    for (size_t x = (size_t)VIDEO_WIDTH; x < stride; ++x) {
      if (video[row * stride + x] != OUTPUT_SENTINEL) {
        goto cleanup;
      }
    }
  }
  for (size_t index = extent; index < sizeof(video); ++index) {
    if (video[index] != OUTPUT_SENTINEL) {
      goto cleanup;
    }
  }
  ok = 1;
cleanup:
  if (lf_destroy(&instance) != LF_OK) {
    ok = 0;
  }
  return ok;
}

static int zero_work_is_noop(void) {
  lf_instance *subject = NULL;
  lf_instance *control = NULL;
  uint8_t video[VIDEO_BUFFER_BYTES];
  int16_t audio[AUDIO_BUFFER_SAMPLES];
  lf_run_result result = {.struct_size = sizeof(result)};
  lf_run_request request = {
      .struct_size = sizeof(request), .work_units = 0U,
      .video_data = video, .video_capacity_bytes = 0U,
      .video_stride_bytes = 0U, .audio_data = audio,
      .audio_capacity_samples = 0U,
  };
  int ok = 0;
  if (!boundary_pair_create(&subject, &control, 1) || subject == NULL ||
      control == NULL ||
      !boundary_queue_input(subject, control, UINT32_C(0x0100))) {
    goto cleanup;
  }
  memset(video, OUTPUT_SENTINEL, sizeof(video));
  for (size_t index = 0U; index < AUDIO_BUFFER_SAMPLES; ++index) {
    audio[index] = AUDIO_SENTINEL;
  }
  if (lf_advance(subject, &request, &result) != LF_OK ||
      result.actual_units != 0U || result.cumulative_units != 0U ||
      result.video_valid != 0U || result.audio_valid != 0U ||
      result.stop_reason != LF_STOP_BUDGET_REACHED ||
      !padding_is_untouched(video) || !output_tail_is_untouched(audio, 0U) ||
      !boundary_followup(subject, control, UINT32_C(0x0100))) {
    goto cleanup;
  }
  ok = 1;
cleanup:
  if (lf_destroy(&subject) != LF_OK || lf_destroy(&control) != LF_OK) {
    ok = 0;
  }
  return ok;
}

static int run_frame_boundaries(void) {
  static const struct {
    boundary_rejection which;
    const char *name;
  } rejected[] = {
      {BOUNDARY_SHORT_REQUEST, "short-request"},
      {BOUNDARY_LARGE_REQUEST, "large-request"},
      {BOUNDARY_SHORT_RESULT, "short-result"},
      {BOUNDARY_LARGE_RESULT, "large-result"},
      {BOUNDARY_NULL_RESULT, "null-result"},
      {BOUNDARY_UNLOADED, "unloaded"},
      {BOUNDARY_NULL_VIDEO, "null-video"},
      {BOUNDARY_NULL_AUDIO, "null-audio"},
      {BOUNDARY_TWO_WORK_UNITS, "two-work-units"},
      {BOUNDARY_SHORT_STRIDE, "stride-319"},
      {BOUNDARY_OVERFLOWING_STRIDE, "stride-multiplication-overflow"},
      {BOUNDARY_OVERFLOWING_STRIDE_ADD, "stride-addition-overflow"},
      {BOUNDARY_SHORT_VIDEO_CAPACITY, "video-extent-minus-one"},
      {BOUNDARY_SHORT_AUDIO_CAPACITY, "audio-capacity-800"},
  };
  static const unsigned int unsupported_input_bits[] = {1U, 2U, 3U, 9U, 10U, 11U};
  const size_t exact_extent =
      (size_t)VIDEO_WIDTH * (size_t)VIDEO_HEIGHT;
  const size_t padded_stride = (size_t)VIDEO_WIDTH + 1U;
  const size_t padded_extent = padded_stride * ((size_t)VIDEO_HEIGHT - 1U) +
                               (size_t)VIDEO_WIDTH;
  for (size_t index = 0U; index < sizeof(rejected) / sizeof(rejected[0]);
       ++index) {
    if (!reject_frame_and_continue(rejected[index].which,
                                   rejected[index].name)) {
      return fail("rejected frame preflight preserves pending input and continuation");
    }
  }
  if (!reject_input_and_continue(sizeof(lf_input) - 1U, UINT32_C(0x0100),
                                 "short-input-record") ||
      !reject_input_and_continue(sizeof(lf_input) + 1U, UINT32_C(0x0100),
                                 "large-input-record")) {
    return fail("invalid input records preserve pending input");
  }
  for (size_t index = 0U;
       index < sizeof(unsupported_input_bits) / sizeof(unsupported_input_bits[0]);
       ++index) {
    const unsigned int bit = unsupported_input_bits[index];
    if (!reject_input_and_continue(sizeof(lf_input), UINT32_C(1) << bit,
                                   "unsupported-input-bit")) {
      return fail("every unsupported input bit preserves pending input");
    }
  }
  if (!zero_work_is_noop() ||
      !valid_boundary_outputs((size_t)VIDEO_WIDTH, exact_extent, 801U) ||
      !valid_boundary_outputs((size_t)VIDEO_WIDTH, exact_extent + 1U, 802U) ||
      !valid_boundary_outputs(padded_stride, padded_extent, 801U) ||
      !valid_boundary_outputs((size_t)VIDEO_WIDTH, exact_extent, 802U)) {
    return fail("zero/one work and exact stride, extent, audio thresholds");
  }
  (void)printf("muhtari_frame_boundaries: rejected=%zu unsupported-input-bits=6 "
               "stride=319,320,321 video-extent=minus-one,exact,plus-one "
               "stride-overflow=multiply,add audio-capacity=800,801,802 "
               "zero-work=noop result=pass\n",
               sizeof(rejected) / sizeof(rejected[0]));
  return 0;
}

static int run_session(void) {
  lf_profile profile = {.struct_size = sizeof(profile)};
  lf_profile explicit_default_profile = {.struct_size = sizeof(profile)};
  lf_profile diagnostic_profile = {.struct_size = sizeof(profile)};
  lf_instance *instance = NULL;
  uint8_t content[LF_MUHTARI_FIXTURE_TOTAL_BYTES];
  uint8_t video[VIDEO_BUFFER_BYTES];
  uint8_t first_video_copy[VIDEO_BUFFER_BYTES];
  int16_t audio[AUDIO_BUFFER_SAMPLES];
  int16_t first_audio_copy[LF_MUHTARI_ORACLE_FIRST_FRAME_SAMPLES];
  lf_load_result loaded = {.struct_size = sizeof(loaded)};
  lf_run_result first_result = {.struct_size = sizeof(first_result)};
  lf_run_result zero_result = {.struct_size = sizeof(zero_result)};
  lf_run_result steady_result = {.struct_size = sizeof(steady_result)};
  lf_run_result control_result = {.struct_size = sizeof(control_result)};
  const size_t content_bytes =
      lf_build_muhtari_fixture(content, sizeof(content));
  int result = 1;

  if (!lf_muhtari_oracle_sha256_self_check()) {
    (void)fail("test-only SHA-256 matches the published abc vector");
    goto cleanup;
  }
  if (lf_get_profile("muhtari-ntsc-v1", NULL, &profile) != LF_OK ||
      !profile_matches(&profile, "muhtari-ntsc-joystick-default",
                       UINT32_C(0xF1F1)) ||
      lf_get_profile("muhtari-ntsc-v1",
                     "muhtari-ntsc-joystick-default",
                     &explicit_default_profile) != LF_OK ||
      !profile_matches(&explicit_default_profile,
                       "muhtari-ntsc-joystick-default",
                       UINT32_C(0xF1F1)) ||
      lf_get_profile("muhtari-ntsc-v1",
                     "muhtari-ntsc-battery-diagnostic",
                     &diagnostic_profile) != LF_OK ||
      !profile_matches(&diagnostic_profile,
                       "muhtari-ntsc-battery-diagnostic",
                       UINT32_C(0xF1)) ||
      lf_get_profile("muhtari-ntsc-v1", "unknown-configuration",
                     &diagnostic_profile) != LF_UNSUPPORTED) {
    (void)fail("profile metadata matches the selected NTSC contract");
    goto cleanup;
  }
  if (!capabilities_match()) {
    (void)fail("profile capabilities match the implemented boundary");
    goto cleanup;
  }
  if (content_bytes != sizeof(content) ||
      lf_create("muhtari-ntsc-v1", NULL, &instance) != LF_OK ||
      instance == NULL) {
    (void)fail("fixture build and instance creation");
    goto cleanup;
  }
  if (lf_load(instance,
              &(lf_load_request){
                  .struct_size = sizeof(lf_load_request),
                  .content_data = content,
                  .content_size_bytes = content_bytes,
                  .configuration_id = "muhtari-ntsc-joystick-default",
              },
              &loaded) != LF_OK ||
      loaded.loaded != 1U || loaded.content_size_bytes != content_bytes ||
      loaded.effective_configuration_id == NULL ||
      strcmp(loaded.effective_configuration_id,
             "muhtari-ntsc-joystick-default") != 0) {
    (void)fail("owned A78 diagnostic load");
    goto cleanup;
  }

  if (!advance_and_check(instance, UINT32_C(0x0001),
                         LF_MUHTARI_ORACLE_PORT0_FIRE_COLOR, 0U, video, audio,
                         &first_result, 1)) {
    (void)fail("first partial port-0 session and 54-sample audio interval");
    goto cleanup;
  }
  memcpy(first_video_copy, video, sizeof(video));
  memcpy(first_audio_copy, audio, sizeof(first_audio_copy));

  {
    lf_input input = {.struct_size = sizeof(input), .buttons = UINT32_C(0x0100)};
    lf_run_request zero_request = {.struct_size = sizeof(zero_request),
                                   .work_units = 0U};
    if (lf_set_input(instance, &input) != LF_OK ||
        lf_advance(instance, &zero_request, &zero_result) != LF_OK ||
        zero_result.cumulative_units != 1U || zero_result.actual_units != 0U) {
      (void)fail("input change queues without advancing guest work");
      goto cleanup;
    }
  }
  if (!advance_and_check(instance, UINT32_C(0x0100),
                         LF_MUHTARI_ORACLE_PORT1_FIRE_COLOR, 1U, video, audio,
                         &steady_result, 1) ||
      memcmp(first_video_copy +
                 (size_t)(LF_MUHTARI_ORACLE_FIRST_BACKGROUND_ROW + 1U) *
                     VIDEO_STRIDE,
             video + (size_t)(LF_MUHTARI_ORACLE_FIRST_BACKGROUND_ROW + 1U) *
                         VIDEO_STRIDE,
             (size_t)VIDEO_WIDTH) == 0 ||
      first_video_copy[(size_t)(LF_MUHTARI_ORACLE_FIRST_BACKGROUND_ROW + 1U) *
                       VIDEO_STRIDE] != LF_MUHTARI_ORACLE_PORT0_FIRE_COLOR ||
      first_audio_copy[0] == AUDIO_SENTINEL) {
    (void)fail("changed port-1 input advances a complete steady frame");
    goto cleanup;
  }

  if (!advance_and_check(instance, 0U,
                         LF_MUHTARI_ORACLE_RELEASED_COLOR, 2U, video, audio,
                         &control_result, 1) ||
      !advance_and_check(instance, UINT32_C(0x0101),
                         LF_MUHTARI_ORACLE_BOTH_FIRE_COLOR, 3U, video, audio,
                         &control_result, 1)) {
    (void)fail("released and both-fire inputs have distinct guest output");
    goto cleanup;
  }

  {
    static const struct {
      uint32_t input;
      uint8_t color;
    } direction_cases[] = {
        {UINT32_C(0x0010), LF_MUHTARI_ORACLE_PORT0_UP_COLOR},
        {UINT32_C(0x0020), LF_MUHTARI_ORACLE_PORT0_DOWN_COLOR},
        {UINT32_C(0x0040), LF_MUHTARI_ORACLE_PORT0_LEFT_COLOR},
        {UINT32_C(0x0080), LF_MUHTARI_ORACLE_PORT0_RIGHT_COLOR},
        {UINT32_C(0x1000), LF_MUHTARI_ORACLE_PORT1_UP_COLOR},
        {UINT32_C(0x2000), LF_MUHTARI_ORACLE_PORT1_DOWN_COLOR},
        {UINT32_C(0x4000), LF_MUHTARI_ORACLE_PORT1_LEFT_COLOR},
        {UINT32_C(0x8000), LF_MUHTARI_ORACLE_PORT1_RIGHT_COLOR},
    };
    for (size_t index = 0U;
         index < sizeof(direction_cases) / sizeof(direction_cases[0]);
         ++index) {
      const size_t interval_index = index + 4U;
      if (!advance_and_check(instance, direction_cases[index].input,
                             direction_cases[index].color, interval_index,
                             video, audio, &control_result, 1)) {
        (void)fail("each direction on both ports reaches distinct guest output");
        goto cleanup;
      }
    }
  }

  if (!advance_and_check(instance, UINT32_C(0x2010),
                         LF_MUHTARI_ORACLE_PORT0_UP_COLOR, 12U, video, audio,
                         &control_result, 1) ||
      !advance_and_check(instance, UINT32_C(0x2010),
                         LF_MUHTARI_ORACLE_PORT0_UP_COLOR, 13U, video, audio,
                         &control_result, 1) ||
      !advance_and_check(instance, UINT32_C(0x8000),
                         LF_MUHTARI_ORACLE_PORT1_RIGHT_COLOR, 14U, video,
                         audio, &control_result, 1)) {
    (void)fail("mixed inputs, repeated held input, and later change have distinct output");
    goto cleanup;
  }
  if (!lf_muhtari_oracle_first_image(first_video_copy, VIDEO_STRIDE,
                                     LF_MUHTARI_ORACLE_PORT0_FIRE_COLOR) ||
      !lf_muhtari_oracle_pcm_matches(first_audio_copy,
                                     LF_MUHTARI_ORACLE_FIRST_FRAME_SAMPLES,
                                     0U, (char[65]){0})) {
    (void)fail("retained first-call outputs remain valid through later frames");
    goto cleanup;
  }

  result = 0;
cleanup:
  if (lf_destroy(&instance) != LF_OK || instance != NULL) {
    (void)fail("instance destruction clears caller ownership");
    result = 1;
  }
  if (result == 0 &&
      (!lf_muhtari_oracle_first_image(first_video_copy, VIDEO_STRIDE,
                                      LF_MUHTARI_ORACLE_PORT0_FIRE_COLOR) ||
       !lf_muhtari_oracle_pcm_matches(first_audio_copy,
                                      LF_MUHTARI_ORACLE_FIRST_FRAME_SAMPLES,
                                      0U, (char[65]){0}))) {
    (void)fail("retained caller-owned outputs survive instance destruction");
    result = 1;
  }
  if (result == 0) {
    (void)printf("muhtari_session: source=%s profile=muhtari-ntsc-v1 "
                 "fixture=owned-a78-linear-16k ports=two "
                 "first_samples=54 steady_samples=801 raw_video=INDEX8 "
                 "non_silent_audio=pass result=pass\n",
                 LIBFUTURO_MUHTARI_SOURCE_REVISION);
  }
  return result;
}

static int emit_fixture(const char *path) {
  uint8_t content[LF_MUHTARI_FIXTURE_TOTAL_BYTES];
  const size_t content_bytes =
      lf_build_muhtari_fixture(content, sizeof(content));
  FILE *output = NULL;
  size_t written = 0U;
  int close_failed = 0;
  if (path == NULL || path[0] == '\0' || content_bytes != sizeof(content)) {
    return fail("fixture output path");
  }
  output = fopen(path, "wb");
  if (output == NULL) {
    return fail("fixture output open");
  }
  written = fwrite(content, 1U, content_bytes, output);
  close_failed = fclose(output) != 0;
  if (written != content_bytes || close_failed != 0) {
    return fail("fixture output write");
  }
  (void)printf("muhtari_fixture: bytes=%zu source=project-authored-C-generator "
               "license=Apache-2.0 output=build-only result=pass\n",
               content_bytes);
  return 0;
}

int main(int argc, char **argv) {
  if (argc == 3 && strcmp(argv[1], "--emit-fixture") == 0) {
    return emit_fixture(argv[2]);
  }
  if (argc == 2 && strcmp(argv[1], "--load-refusals") == 0) {
    return run_load_refusals();
  }
  if (argc == 2 && strcmp(argv[1], "--frame-boundaries") == 0) {
    return run_frame_boundaries();
  }
  if (argc == 2 && strcmp(argv[1], "--wrong-index-oracle") == 0) {
    g_wrong_index_oracle = 1;
    return run_session();
  }
  if (argc != 1) {
    (void)fprintf(stderr,
                  "usage: muhtari_session [--emit-fixture build-path|--load-refusals|--frame-boundaries|--wrong-index-oracle]\n");
    return 2;
  }
  return run_session();
}
