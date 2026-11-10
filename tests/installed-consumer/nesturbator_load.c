#include <libfuturo/libfuturo.h>

#include "nesturbator_save_fixture.h"
#include "nesturbator_save_oracle.h"

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LOAD_PROFILE_ID "nesturbator-ntsc-v1"
#define LOAD_GUARD_BYTES 32U
#define LOAD_GUARD_VALUE UINT8_C(0xc7)
#define OUTPUT_GUARD_VALUE UINT8_C(0xa5)
#define LOAD_MEDIA_BYTES 8192U
#define LOAD_VIDEO_WIDTH 256U
#define LOAD_VIDEO_HEIGHT 240U
#define LOAD_VIDEO_STRIDE 800U
#define LOAD_VIDEO_ROW_BYTES (LOAD_VIDEO_WIDTH * 3U)
#define LOAD_VIDEO_CAPACITY (LOAD_VIDEO_STRIDE * LOAD_VIDEO_HEIGHT)
#define LOAD_VIDEO_EXTENT \
  ((LOAD_VIDEO_HEIGHT - 1U) * LOAD_VIDEO_STRIDE + LOAD_VIDEO_ROW_BYTES)
#define LOAD_AUDIO_CAPACITY 799U
#define LOAD_TRACKED_ALLOCATIONS 128U
#define LOAD_LIMIT_BYTES ((size_t)67108864U)
#define LOAD_OVER_LIMIT_BYTES ((size_t)67108865U)

typedef struct allocation_tracker {
  void *live[LOAD_TRACKED_ALLOCATIONS];
  size_t live_count;
  size_t calls;
  size_t successful_allocations;
  size_t frees;
  size_t failed_allocations;
  size_t last_failed_call;
  size_t invalid_frees;
  int fail_next;
  int capacity_exceeded;
} allocation_tracker;

typedef struct refusal_case {
  const char *id;
  lf_status expected;
  const char *configuration_id;
  uint8_t *storage;
  uint8_t *content;
  size_t storage_extent;
  size_t content_extent;
  int fail_first_allocation;
} refusal_case;

typedef struct media_observation {
  uint8_t bytes[LOAD_MEDIA_BYTES];
  char identity[LF_SAVE_ORACLE_MEDIA_IDENTITY_CAPACITY];
  size_t extent_bytes;
  uint64_t generation;
} media_observation;

typedef struct frame_capture {
  _Alignas(max_align_t) uint8_t
      video[LOAD_GUARD_BYTES + LOAD_VIDEO_CAPACITY + LOAD_GUARD_BYTES];
  _Alignas(max_align_t) uint8_t
      audio[LOAD_GUARD_BYTES + LOAD_AUDIO_CAPACITY * sizeof(int16_t) +
            LOAD_GUARD_BYTES];
  lf_run_result result;
} frame_capture;

typedef struct guarded_request {
  uint64_t before;
  lf_load_request value;
  uint64_t after;
} guarded_request;

typedef struct guarded_result {
  uint64_t before;
  lf_load_result value;
  uint64_t after;
} guarded_result;

static const uint64_t LOAD_CANARY_BEFORE = UINT64_C(0x1eae6c0181fbb92d);
static const uint64_t LOAD_CANARY_AFTER = UINT64_C(0xd792bb81016cae1e);

static void report_case_failure(const char *case_id, const char *field) {
  (void)fprintf(stderr, "installed_load: case=%s field=%s\n",
                case_id == NULL ? "<none>" : case_id,
                field == NULL ? "<none>" : field);
}

static void *tracked_allocate(void *context, size_t bytes) {
  allocation_tracker *tracker = (allocation_tracker *)context;
  void *allocation = NULL;
  if (tracker == NULL) {
    return NULL;
  }
  tracker->calls += 1U;
  if (tracker->fail_next != 0) {
    tracker->fail_next = 0;
    tracker->failed_allocations += 1U;
    tracker->last_failed_call = tracker->calls;
    return NULL;
  }
  if (tracker->live_count >= LOAD_TRACKED_ALLOCATIONS) {
    tracker->capacity_exceeded = 1;
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

static void tracked_deallocate(void *context, void *allocation) {
  allocation_tracker *tracker = (allocation_tracker *)context;
  size_t index = 0U;
  if (tracker == NULL || allocation == NULL) {
    return;
  }
  for (index = 0U; index < tracker->live_count; ++index) {
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

static int tracker_create(allocation_tracker *tracker, lf_instance **instance) {
  const lf_create_options options = {
      .struct_size = sizeof(options),
      .allocate = tracked_allocate,
      .deallocate = tracked_deallocate,
      .allocator_context = tracker,
  };
  if (tracker == NULL || instance == NULL) {
    return 0;
  }
  *instance = NULL;
  return lf_create(LOAD_PROFILE_ID, &options, instance) == LF_OK &&
         *instance != NULL;
}

static int tracker_same_live_set(const allocation_tracker *before,
                                 const allocation_tracker *after) {
  size_t left = 0U;
  size_t right = 0U;
  if (before == NULL || after == NULL || before->live_count != after->live_count) {
    return 0;
  }
  for (left = 0U; left < before->live_count; ++left) {
    int found = 0;
    for (right = 0U; right < after->live_count; ++right) {
      if (before->live[left] == after->live[right]) {
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

static int tracker_balanced(const allocation_tracker *tracker) {
  return tracker != NULL && tracker->live_count == 0U &&
         tracker->successful_allocations == tracker->frees &&
         tracker->invalid_frees == 0U && tracker->capacity_exceeded == 0;
}

static int tracker_destroy_instance(allocation_tracker *tracker,
                                    lf_instance **instance) {
  int destroy_ok = 1;
  if (instance != NULL && *instance != NULL) {
    destroy_ok = lf_destroy(instance) == LF_OK;
  }
  return destroy_ok != 0 && tracker_balanced(tracker);
}

static int same_load_result(const lf_load_result *left,
                            const lf_load_result *right) {
  if (left == NULL || right == NULL || left->struct_size != right->struct_size ||
      left->loaded != right->loaded ||
      left->content_size_bytes != right->content_size_bytes) {
    return 0;
  }
  if (left->effective_configuration_id == NULL ||
      right->effective_configuration_id == NULL) {
    return left->effective_configuration_id == NULL &&
           right->effective_configuration_id == NULL;
  }
  return strcmp(left->effective_configuration_id,
                 right->effective_configuration_id) == 0;
}

static int load_result_is_active(const lf_load_result *result,
                                 size_t expected_extent) {
  return result != NULL && result->struct_size == sizeof(*result) &&
         result->loaded == 1U &&
         result->content_size_bytes == expected_extent &&
         result->effective_configuration_id != NULL &&
         strcmp(result->effective_configuration_id,
                LF_SAVE_ORACLE_CONFIGURATION_IDENTITY) == 0;
}

static int load_result_is_unloaded(const lf_load_result *result) {
  return result != NULL && result->struct_size == sizeof(*result) &&
         result->loaded == 0U && result->content_size_bytes == 0U &&
         result->effective_configuration_id == NULL;
}

static int same_profile(const lf_profile *left, const lf_profile *right) {
  return left != NULL && right != NULL &&
         left->struct_size == right->struct_size &&
         left->api_revision == right->api_revision &&
         left->behavior_revision == right->behavior_revision &&
         left->input_mask == right->input_mask &&
         left->max_work_units == right->max_work_units &&
         left->max_guest_units == right->max_guest_units &&
         left->atomic_quantum_units == right->atomic_quantum_units &&
         left->max_overshoot_units == right->max_overshoot_units &&
         left->time_unit == right->time_unit &&
         left->input_sampling == right->input_sampling &&
         left->video_format == right->video_format &&
         left->audio_encoding == right->audio_encoding &&
         left->audio_layout == right->audio_layout &&
         left->video_width == right->video_width &&
         left->video_height == right->video_height &&
         left->video_bytes_per_pixel == right->video_bytes_per_pixel &&
         left->audio_rate_numerator == right->audio_rate_numerator &&
         left->audio_rate_denominator == right->audio_rate_denominator &&
         left->audio_channels == right->audio_channels &&
         left->min_video_stride_bytes == right->min_video_stride_bytes &&
         left->max_audio_samples_per_call == right->max_audio_samples_per_call &&
         left->media_extent_bytes == right->media_extent_bytes &&
         left->max_content_bytes == right->max_content_bytes &&
         left->profile_id != NULL && right->profile_id != NULL &&
         strcmp(left->profile_id, right->profile_id) == 0 &&
         left->core_id != NULL && right->core_id != NULL &&
         strcmp(left->core_id, right->core_id) == 0 &&
         left->build_id != NULL && right->build_id != NULL &&
         strcmp(left->build_id, right->build_id) == 0 &&
         left->effective_configuration_id != NULL &&
         right->effective_configuration_id != NULL &&
         strcmp(left->effective_configuration_id,
                right->effective_configuration_id) == 0;
}

static int snapshot_profile(lf_profile *profile) {
  if (profile == NULL) {
    return 0;
  }
  memset(profile, 0, sizeof(*profile));
  profile->struct_size = sizeof(*profile);
  return lf_get_profile(LOAD_PROFILE_ID, NULL, profile) == LF_OK &&
         profile->profile_id != NULL && profile->core_id != NULL &&
         profile->build_id != NULL &&
         profile->effective_configuration_id != NULL;
}

static int copy_media(lf_instance *instance, media_observation *observation) {
  _Alignas(max_align_t) uint8_t
      storage[LOAD_GUARD_BYTES + LOAD_MEDIA_BYTES + LOAD_GUARD_BYTES];
  lf_media_info information = {.struct_size = sizeof(information)};
  const char *identity = NULL;
  size_t identity_length = 0U;
  size_t index = 0U;
  lf_status status = LF_INVALID_ARGUMENT;
  if (instance == NULL || observation == NULL) {
    return 0;
  }
  memset(storage, OUTPUT_GUARD_VALUE, sizeof(storage));
  memset(observation, 0, sizeof(*observation));
  status = lf_copy_media(instance, storage + LOAD_GUARD_BYTES,
                         LOAD_MEDIA_BYTES, &information);
  if (status != LF_OK || information.identity == NULL ||
      information.extent_bytes != LOAD_MEDIA_BYTES) {
    return 0;
  }
  identity = information.identity;
  identity_length = strlen(identity);
  if (identity_length >= sizeof(observation->identity)) {
    return 0;
  }
  for (index = 0U; index < LOAD_GUARD_BYTES; ++index) {
    if (storage[index] != OUTPUT_GUARD_VALUE ||
        storage[LOAD_GUARD_BYTES + LOAD_MEDIA_BYTES + index] !=
            OUTPUT_GUARD_VALUE) {
      return 0;
    }
  }
  memcpy(observation->bytes, storage + LOAD_GUARD_BYTES, LOAD_MEDIA_BYTES);
  memcpy(observation->identity, identity, identity_length + 1U);
  observation->extent_bytes = information.extent_bytes;
  observation->generation = information.guest_generation;
  return 1;
}

static int media_equal(const media_observation *left,
                       const media_observation *right) {
  return left != NULL && right != NULL &&
         left->extent_bytes == right->extent_bytes &&
         left->generation == right->generation &&
         strcmp(left->identity, right->identity) == 0 &&
         memcmp(left->bytes, right->bytes, LOAD_MEDIA_BYTES) == 0;
}

static int media_is_zero(const media_observation *observation) {
  size_t index = 0U;
  if (observation == NULL || observation->extent_bytes != LOAD_MEDIA_BYTES ||
      strcmp(observation->identity, LF_SAVE_ORACLE_MEDIA_IDENTITY) != 0 ||
      observation->generation != 0U ||
      !lf_save_oracle_matches(observation->bytes, observation->extent_bytes,
                              0U)) {
    return 0;
  }
  for (index = 0U; index < LOAD_MEDIA_BYTES; ++index) {
    if (observation->bytes[index] != 0U) {
      return 0;
    }
  }
  return 1;
}

static int same_run_result(const lf_run_result *left,
                           const lf_run_result *right) {
  if (left == NULL || right == NULL) {
    return 0;
  }
  return left->struct_size == right->struct_size &&
         left->requested_units == right->requested_units &&
         left->actual_units == right->actual_units &&
         left->overshoot_units == right->overshoot_units &&
         left->sampled_buttons == right->sampled_buttons &&
         left->video_valid == right->video_valid &&
         left->audio_valid == right->audio_valid &&
         left->cumulative_units == right->cumulative_units &&
         left->core_ticks_valid == right->core_ticks_valid &&
         left->cumulative_core_ticks == right->cumulative_core_ticks &&
         left->time_unit == right->time_unit &&
         left->core_tick_time_unit == right->core_tick_time_unit &&
         left->stop_reason == right->stop_reason &&
         left->video_format == right->video_format &&
         left->audio_encoding == right->audio_encoding &&
         left->audio_layout == right->audio_layout &&
         left->video_width == right->video_width &&
         left->video_height == right->video_height &&
         left->audio_rate_numerator == right->audio_rate_numerator &&
         left->audio_rate_denominator == right->audio_rate_denominator &&
         left->audio_channels == right->audio_channels &&
         left->video_stride_bytes == right->video_stride_bytes &&
         left->video_extent_bytes == right->video_extent_bytes &&
         left->audio_produced_samples == right->audio_produced_samples;
}

static int check_output_guards(const frame_capture *capture) {
  size_t index = 0U;
  size_t row = 0U;
  size_t audio_produced_bytes = 0U;
  if (capture == NULL || capture->result.video_extent_bytes != LOAD_VIDEO_EXTENT ||
      capture->result.video_stride_bytes != LOAD_VIDEO_STRIDE ||
      capture->result.audio_produced_samples > LOAD_AUDIO_CAPACITY) {
    return 0;
  }
  for (index = 0U; index < LOAD_GUARD_BYTES; ++index) {
    if (capture->video[index] != OUTPUT_GUARD_VALUE ||
        capture->video[LOAD_GUARD_BYTES + LOAD_VIDEO_CAPACITY + index] !=
            OUTPUT_GUARD_VALUE ||
        capture->audio[index] != OUTPUT_GUARD_VALUE ||
        capture->audio[LOAD_GUARD_BYTES + LOAD_AUDIO_CAPACITY * sizeof(int16_t) +
                       index] != OUTPUT_GUARD_VALUE) {
      return 0;
    }
  }
  for (row = 0U; row < LOAD_VIDEO_HEIGHT; ++row) {
    const size_t padding_start =
        LOAD_GUARD_BYTES + row * LOAD_VIDEO_STRIDE + LOAD_VIDEO_ROW_BYTES;
    for (index = LOAD_VIDEO_ROW_BYTES; index < LOAD_VIDEO_STRIDE; ++index) {
      if (capture->video[padding_start + index - LOAD_VIDEO_ROW_BYTES] !=
          OUTPUT_GUARD_VALUE) {
        return 0;
      }
    }
  }
  audio_produced_bytes = capture->result.audio_produced_samples * sizeof(int16_t);
  for (index = audio_produced_bytes;
       index < LOAD_AUDIO_CAPACITY * sizeof(int16_t); ++index) {
    if (capture->audio[LOAD_GUARD_BYTES + index] != OUTPUT_GUARD_VALUE) {
      return 0;
    }
  }
  return 1;
}

static int output_untouched(const frame_capture *capture) {
  size_t index = 0U;
  if (capture == NULL) {
    return 0;
  }
  for (index = 0U; index < sizeof(capture->video); ++index) {
    if (capture->video[index] != OUTPUT_GUARD_VALUE) {
      return 0;
    }
  }
  for (index = 0U; index < sizeof(capture->audio); ++index) {
    if (capture->audio[index] != OUTPUT_GUARD_VALUE) {
      return 0;
    }
  }
  return 1;
}

static int advance_group(lf_instance **instances, size_t instance_count,
                         int set_input, uint32_t buttons,
                         uint32_t expected_buttons, uint64_t expected_frame,
                         lf_run_result *first_result_out) {
  frame_capture captures[3];
  media_observation media[3];
  size_t index = 0U;
  lf_status status = LF_INVALID_ARGUMENT;
  if (instances == NULL || instance_count < 2U || instance_count > 3U) {
    return 0;
  }
  memset(captures, OUTPUT_GUARD_VALUE, sizeof(captures));
  for (index = 0U; index < instance_count; ++index) {
    lf_run_request request = {
        .struct_size = sizeof(request),
        .work_units = 1U,
        .video_data = captures[index].video + LOAD_GUARD_BYTES,
        .video_capacity_bytes = LOAD_VIDEO_CAPACITY,
        .video_stride_bytes = LOAD_VIDEO_STRIDE,
        .audio_data = (int16_t *)(void *)(captures[index].audio +
                                          LOAD_GUARD_BYTES),
        .audio_capacity_samples = LOAD_AUDIO_CAPACITY,
    };
    lf_input input = {.struct_size = sizeof(input), .buttons = buttons};
    captures[index].result.struct_size = sizeof(captures[index].result);
    if (set_input != 0 && lf_set_input(instances[index], &input) != LF_OK) {
      report_case_failure("frame", "set-input");
      return 0;
    }
    status = lf_advance(instances[index], &request, &captures[index].result);
    if (status != LF_OK || captures[index].result.actual_units != 1U ||
        captures[index].result.overshoot_units != 0U ||
        captures[index].result.cumulative_units != expected_frame ||
        captures[index].result.core_ticks_valid != 1U ||
        captures[index].result.cumulative_core_ticks == 0U ||
        captures[index].result.sampled_buttons != expected_buttons ||
        captures[index].result.video_valid != 1U ||
        captures[index].result.audio_valid != 1U ||
        captures[index].result.stop_reason != LF_STOP_BUDGET_REACHED ||
        captures[index].result.video_format != LF_VIDEO_RGB24 ||
        captures[index].result.audio_encoding != LF_AUDIO_S16_NATIVE ||
        captures[index].result.audio_layout != LF_AUDIO_INTERLEAVED ||
        captures[index].result.video_width != LOAD_VIDEO_WIDTH ||
        captures[index].result.video_height != LOAD_VIDEO_HEIGHT ||
        captures[index].result.audio_rate_numerator != 48000U ||
        captures[index].result.audio_rate_denominator != 1U ||
        captures[index].result.audio_channels != 1U ||
        captures[index].result.audio_produced_samples < 798U ||
        captures[index].result.audio_produced_samples > LOAD_AUDIO_CAPACITY ||
        !check_output_guards(&captures[index])) {
      report_case_failure("frame", "result-or-output-boundary");
      return 0;
    }
    if (!copy_media(instances[index], &media[index]) ||
        media[index].generation != expected_frame ||
        !lf_save_oracle_matches(media[index].bytes, media[index].extent_bytes,
                                (uint8_t)expected_frame)) {
      report_case_failure("frame", "media-oracle");
      return 0;
    }
  }
  for (index = 1U; index < instance_count; ++index) {
    if (!same_run_result(&captures[0].result, &captures[index].result) ||
        memcmp(captures[0].video, captures[index].video,
               sizeof(captures[0].video)) != 0 ||
        memcmp(captures[0].audio, captures[index].audio,
               sizeof(captures[0].audio)) != 0 ||
        !media_equal(&media[0], &media[index])) {
      report_case_failure("frame", "same-history-observation");
      return 0;
    }
  }
  if (first_result_out != NULL) {
    *first_result_out = captures[0].result;
  }
  return 1;
}

static int run_zero_work_group(lf_instance **instances,
                               size_t instance_count) {
  frame_capture captures[3];
  size_t index = 0U;
  if (instances == NULL || instance_count != 3U) {
    return 0;
  }
  memset(captures, OUTPUT_GUARD_VALUE, sizeof(captures));
  for (index = 0U; index < instance_count; ++index) {
    lf_run_request request = {
        .struct_size = sizeof(request),
        .work_units = 0U,
        .video_data = captures[index].video + LOAD_GUARD_BYTES,
        .video_capacity_bytes = LOAD_VIDEO_CAPACITY,
        .video_stride_bytes = LOAD_VIDEO_STRIDE,
        .audio_data = (int16_t *)(void *)(captures[index].audio +
                                          LOAD_GUARD_BYTES),
        .audio_capacity_samples = LOAD_AUDIO_CAPACITY,
    };
    captures[index].result.struct_size = sizeof(captures[index].result);
    if (lf_advance(instances[index], &request, &captures[index].result) !=
            LF_OK ||
        captures[index].result.requested_units != 0U ||
        captures[index].result.actual_units != 0U ||
        captures[index].result.overshoot_units != 0U ||
        captures[index].result.sampled_buttons != 0U ||
        captures[index].result.video_valid != 0U ||
        captures[index].result.audio_valid != 0U ||
        captures[index].result.cumulative_units != 0U ||
        captures[index].result.core_ticks_valid != 0U ||
        captures[index].result.cumulative_core_ticks != 0U ||
        captures[index].result.stop_reason != LF_STOP_BUDGET_REACHED ||
        captures[index].result.video_extent_bytes != 0U ||
        captures[index].result.audio_produced_samples != 0U ||
        !output_untouched(&captures[index])) {
      report_case_failure("P03", "zero-work-reset-metadata");
      return 0;
    }
  }
  for (index = 1U; index < instance_count; ++index) {
    if (!same_run_result(&captures[0].result, &captures[index].result) ||
        memcmp(captures[0].video, captures[index].video,
               sizeof(captures[0].video)) != 0 ||
        memcmp(captures[0].audio, captures[index].audio,
               sizeof(captures[0].audio)) != 0) {
      report_case_failure("P03", "zero-work-reference");
      return 0;
    }
  }
  return 1;
}

static int set_load_fixture(lf_instance *instance, const uint8_t *fixture,
                            size_t fixture_extent, const char *configuration,
                            lf_load_result *result) {
  if (instance == NULL || fixture == NULL || result == NULL) {
    return 0;
  }
  const lf_load_request request = {
      .struct_size = sizeof(request),
      .content_data = fixture,
      .content_size_bytes = fixture_extent,
      .configuration_id = configuration,
  };
  memset(result, 0, sizeof(*result));
  result->struct_size = sizeof(*result);
  return lf_load(instance, &request, result) == LF_OK &&
         load_result_is_active(result, fixture_extent);
}

static int create_case_storage(refusal_case *load_case, size_t extent,
                               uint8_t fill) {
  size_t storage_bytes = 0U;
  if (load_case == NULL || extent > SIZE_MAX - 2U * LOAD_GUARD_BYTES) {
    return 0;
  }
  storage_bytes = extent + 2U * LOAD_GUARD_BYTES;
  load_case->storage = (uint8_t *)malloc(storage_bytes);
  if (load_case->storage == NULL) {
    return 0;
  }
  memset(load_case->storage, LOAD_GUARD_VALUE, storage_bytes);
  load_case->content = load_case->storage + LOAD_GUARD_BYTES;
  load_case->storage_extent = extent;
  load_case->content_extent = extent;
  memset(load_case->content, fill, extent);
  return 1;
}

static int setup_refusal_cases(refusal_case cases[7], const uint8_t *fixture,
                               size_t fixture_extent) {
  size_t index = 0U;
  static const char unknown_configuration[] = "unknown";
  if (cases == NULL || fixture == NULL ||
      fixture_extent != LF_NESTURBATOR_SAVE_FIXTURE_TOTAL_BYTES) {
    return 0;
  }
  cases[0] = (refusal_case){
      .id = "A04-02", .expected = LF_UNSUPPORTED,
      .configuration_id = unknown_configuration,
  };
  cases[1] = (refusal_case){.id = "H01-01", .expected = LF_INVALID_ARGUMENT};
  cases[2] = (refusal_case){.id = "B50-01", .expected = LF_INVALID_ARGUMENT};
  cases[3] = (refusal_case){.id = "E02-06", .expected = LF_INVALID_ARGUMENT};
  cases[4] = (refusal_case){.id = "A05-02", .expected = LF_INVALID_ARGUMENT};
  cases[5] = (refusal_case){.id = "A05-03", .expected = LF_LIMIT_EXCEEDED};
  cases[6] = (refusal_case){
      .id = "F11", .expected = LF_RESOURCE_EXHAUSTED,
      .fail_first_allocation = 1,
  };

  for (index = 0U; index < 3U; ++index) {
    if (!create_case_storage(&cases[index], fixture_extent, 0U)) {
      return 0;
    }
    memcpy(cases[index].content, fixture, fixture_extent);
  }
  cases[1].content[0] ^= UINT8_C(0x01);
  cases[2].content[6] = UINT8_C(0x52); /* iNES mapper 5, battery set. */
  cases[2].content[7] = 0U;

  if (!create_case_storage(&cases[3], 25103U, 0U)) {
    return 0;
  }
  cases[3].content[0] = (uint8_t)'N';
  cases[3].content[1] = (uint8_t)'E';
  cases[3].content[2] = (uint8_t)'S';
  cases[3].content[3] = UINT8_C(0x1a);
  cases[3].content[4] = 1U; /* 16 KiB PRG. */
  cases[3].content[5] = 1U; /* 8 KiB CHR. */
  cases[3].content[6] = UINT8_C(0x04); /* 512-byte trainer. */
  cases[3].content[7] = UINT8_C(0x08); /* NES 2.0. */

  cases[4].storage_extent = LOAD_OVER_LIMIT_BYTES;
  cases[4].content_extent = LOAD_LIMIT_BYTES;
  cases[4].storage = (uint8_t *)malloc(
      LOAD_OVER_LIMIT_BYTES + 2U * LOAD_GUARD_BYTES);
  if (cases[4].storage == NULL) {
    return 0;
  }
  memset(cases[4].storage, LOAD_GUARD_VALUE,
         LOAD_OVER_LIMIT_BYTES + 2U * LOAD_GUARD_BYTES);
  cases[4].content = cases[4].storage + LOAD_GUARD_BYTES;
  memset(cases[4].content, UINT8_C(0x5c), LOAD_OVER_LIMIT_BYTES);
  memcpy(cases[4].content, fixture,
         LF_NESTURBATOR_SAVE_FIXTURE_HEADER_BYTES);
  cases[5].storage = cases[4].storage;
  cases[5].content = cases[4].content;
  cases[5].storage_extent = LOAD_OVER_LIMIT_BYTES;
  cases[5].content_extent = LOAD_OVER_LIMIT_BYTES;

  if (!create_case_storage(&cases[6], fixture_extent, 0U)) {
    return 0;
  }
  memcpy(cases[6].content, fixture, fixture_extent);
  return 1;
}

static int content_canaries_intact(const refusal_case *load_case) {
  size_t index = 0U;
  const size_t storage_bytes =
      load_case->storage_extent + 2U * LOAD_GUARD_BYTES;
  if (load_case == NULL || load_case->storage == NULL ||
      load_case->content == NULL) {
    return 0;
  }
  for (index = 0U; index < LOAD_GUARD_BYTES; ++index) {
    if (load_case->storage[index] != LOAD_GUARD_VALUE ||
        load_case->storage[storage_bytes - LOAD_GUARD_BYTES + index] !=
            LOAD_GUARD_VALUE) {
      return 0;
    }
  }
  return 1;
}

static int content_digest(const uint8_t *content, size_t extent,
                          uint8_t digest[32]) {
  return lf_nesturbator_save_fixture_sha256(content, extent, digest);
}

static int attempt_refusal(lf_instance *instance,
                           allocation_tracker *tracker,
                           const refusal_case *load_case,
                           int was_loaded,
                           const lf_load_result *active_before,
                           lf_instance *control,
                           const media_observation *media_before) {
  guarded_request guarded_request_value = {0};
  guarded_result guarded_result_value = {0};
  lf_profile profile_before;
  lf_profile profile_after;
  allocation_tracker tracker_before;
  media_observation media_after;
  media_observation control_after;
  uint8_t digest_before[32];
  uint8_t digest_after[32];
  size_t calls_before = 0U;
  size_t failures_before = 0U;
  lf_status status = LF_INVALID_ARGUMENT;
  if (instance == NULL || tracker == NULL || load_case == NULL ||
      !snapshot_profile(&profile_before) ||
      !content_digest(load_case->content, load_case->content_extent,
                      digest_before) ||
      !content_canaries_intact(load_case)) {
    report_case_failure(load_case == NULL ? NULL : load_case->id,
                        "refusal-setup");
    return 0;
  }
  tracker_before = *tracker;
  calls_before = tracker->calls;
  failures_before = tracker->failed_allocations;
  guarded_request_value.before = LOAD_CANARY_BEFORE;
  guarded_request_value.after = LOAD_CANARY_AFTER;
  guarded_request_value.value = (lf_load_request){
      .struct_size = sizeof(lf_load_request),
      .content_data = load_case->content,
      .content_size_bytes = load_case->content_extent,
      .configuration_id = load_case->configuration_id,
  };
  guarded_result_value.before = LOAD_CANARY_BEFORE;
  guarded_result_value.after = LOAD_CANARY_AFTER;
  if (was_loaded != 0) {
    guarded_result_value.value = *active_before;
  } else {
    guarded_result_value.value.struct_size = sizeof(lf_load_result);
  }
  if (load_case->fail_first_allocation != 0) {
    tracker->fail_next = 1;
  }
  status = lf_load(instance, &guarded_request_value.value,
                   &guarded_result_value.value);
  if (status != load_case->expected ||
      guarded_request_value.before != LOAD_CANARY_BEFORE ||
      guarded_request_value.after != LOAD_CANARY_AFTER ||
      guarded_result_value.before != LOAD_CANARY_BEFORE ||
      guarded_result_value.after != LOAD_CANARY_AFTER ||
      guarded_request_value.value.struct_size != sizeof(lf_load_request) ||
      guarded_request_value.value.content_data != load_case->content ||
      guarded_request_value.value.content_size_bytes !=
          load_case->content_extent ||
      guarded_request_value.value.configuration_id !=
          load_case->configuration_id ||
      !snapshot_profile(&profile_after) ||
      !same_profile(&profile_before, &profile_after) ||
      !tracker_same_live_set(&tracker_before, tracker) ||
      tracker->invalid_frees != tracker_before.invalid_frees ||
      tracker->capacity_exceeded != tracker_before.capacity_exceeded ||
      !content_digest(load_case->content, load_case->content_extent,
                      digest_after) ||
      memcmp(digest_before, digest_after, sizeof(digest_before)) != 0 ||
      !content_canaries_intact(load_case)) {
    report_case_failure(load_case->id, "status-record-profile-content-or-ownership");
    return 0;
  }
  if (load_case->fail_first_allocation != 0 &&
      (tracker->fail_next != 0 ||
       tracker->failed_allocations != failures_before + 1U ||
       tracker->last_failed_call != calls_before + 1U)) {
    report_case_failure(load_case->id, "first-candidate-allocation-not-refused");
    return 0;
  }
  if (was_loaded != 0) {
    if (!same_load_result(&guarded_result_value.value, active_before) ||
        control == NULL || media_before == NULL ||
        !copy_media(instance, &media_after) ||
        !copy_media(control, &control_after) ||
        !media_equal(media_before, &media_after) ||
        !media_equal(media_before, &control_after)) {
      report_case_failure(load_case->id, "immediate-loaded-preservation");
      return 0;
    }
  } else if (!load_result_is_unloaded(&guarded_result_value.value)) {
    report_case_failure(load_case->id, "unloaded-result-postcondition");
    return 0;
  }
  return 1;
}

static int unloaded_advance_rejected(lf_instance *instance,
                                     const char *case_id) {
  frame_capture capture;
  lf_run_request request = {
      .struct_size = sizeof(request),
      .work_units = 1U,
      .video_data = capture.video + LOAD_GUARD_BYTES,
      .video_capacity_bytes = LOAD_VIDEO_CAPACITY,
      .video_stride_bytes = LOAD_VIDEO_STRIDE,
      .audio_data = (int16_t *)(void *)(capture.audio + LOAD_GUARD_BYTES),
      .audio_capacity_samples = LOAD_AUDIO_CAPACITY,
  };
  memset(&capture, OUTPUT_GUARD_VALUE, sizeof(capture));
  capture.result.struct_size = sizeof(capture.result);
  if (lf_advance(instance, &request, &capture.result) != LF_INVALID_ARGUMENT) {
    report_case_failure(case_id, "unloaded-advance-status");
    return 0;
  }
  for (size_t index = 0U; index < sizeof(capture.video); ++index) {
    if (capture.video[index] != OUTPUT_GUARD_VALUE) {
      report_case_failure(case_id, "unloaded-video-untouched");
      return 0;
    }
  }
  for (size_t index = 0U; index < sizeof(capture.audio); ++index) {
    if (capture.audio[index] != OUTPUT_GUARD_VALUE) {
      report_case_failure(case_id, "unloaded-audio-untouched");
      return 0;
    }
  }
  return 1;
}

static int run_unloaded_refusal(const uint8_t *fixture, size_t fixture_extent,
                                const refusal_case *load_case) {
  allocation_tracker tracker = {0};
  lf_instance *instance = NULL;
  int ok = 0;
  if (!tracker_create(&tracker, &instance) ||
      !attempt_refusal(instance, &tracker, load_case, 0, NULL, NULL, NULL) ||
      !unloaded_advance_rejected(instance, load_case->id)) {
    goto cleanup;
  }
  (void)fixture;
  (void)fixture_extent;
  ok = 1;
cleanup:
  if (!tracker_destroy_instance(&tracker, &instance)) {
    report_case_failure(load_case == NULL ? NULL : load_case->id,
                        "unloaded-destroy-balance");
    ok = 0;
  }
  return ok;
}

static int run_loaded_refusal(const uint8_t *fixture, size_t fixture_extent,
                              const refusal_case *load_case) {
  allocation_tracker subject_tracker = {0};
  allocation_tracker control_tracker = {0};
  lf_instance *subject = NULL;
  lf_instance *control = NULL;
  lf_instance *instances[2];
  lf_load_result active_result = {.struct_size = sizeof(active_result)};
  lf_load_result control_result = {.struct_size = sizeof(control_result)};
  media_observation before_media;
  media_observation control_media;
  int ok = 0;
  if (!tracker_create(&subject_tracker, &subject) ||
      !tracker_create(&control_tracker, &control) ||
      !set_load_fixture(subject, fixture, fixture_extent, NULL, &active_result) ||
      !set_load_fixture(control, fixture, fixture_extent, NULL, &control_result) ||
      !same_load_result(&active_result, &control_result)) {
    report_case_failure(load_case->id, "loaded-pair-setup");
    goto cleanup;
  }
  instances[0] = subject;
  instances[1] = control;
  for (uint64_t frame = 1U; frame <= 3U; ++frame) {
    if (!advance_group(instances, 2U, 1, UINT32_C(0x0001),
                       UINT32_C(0x0001), frame, NULL)) {
      report_case_failure(load_case->id, "warmup-frame");
      goto cleanup;
    }
  }
  if (lf_set_input(subject, &(lf_input){.struct_size = sizeof(lf_input),
                                        .buttons = UINT32_C(0x0001)}) != LF_OK ||
      lf_set_input(control, &(lf_input){.struct_size = sizeof(lf_input),
                                        .buttons = UINT32_C(0x0001)}) != LF_OK ||
      !copy_media(subject, &before_media) ||
      !copy_media(control, &control_media) ||
      !media_equal(&before_media, &control_media) ||
      before_media.generation != 3U ||
      !lf_save_oracle_matches(before_media.bytes, before_media.extent_bytes,
                              3U) ||
      !attempt_refusal(subject, &subject_tracker, load_case, 1, &active_result,
                       control, &before_media)) {
    report_case_failure(load_case->id, "loaded-refusal-preservation");
    goto cleanup;
  }
  if (!advance_group(instances, 2U, 0, 0U, UINT32_C(0x0001), 4U, NULL) ||
      !advance_group(instances, 2U, 1, UINT32_C(0x0100), UINT32_C(0x0100), 5U,
                     NULL) ||
      !advance_group(instances, 2U, 1, 0U, 0U, 6U, NULL)) {
    report_case_failure(load_case->id, "three-frame-continuation");
    goto cleanup;
  }
  ok = 1;
cleanup:
  if (!tracker_destroy_instance(&subject_tracker, &subject)) {
    report_case_failure(load_case == NULL ? NULL : load_case->id,
                        "subject-destroy-balance");
    ok = 0;
  }
  if (!tracker_destroy_instance(&control_tracker, &control)) {
    report_case_failure(load_case == NULL ? NULL : load_case->id,
                        "loaded-destroy-balance");
    ok = 0;
  }
  return ok;
}

static int run_replacement_reset(const uint8_t *fixture,
                                 size_t fixture_extent) {
  allocation_tracker subject_tracker = {0};
  allocation_tracker peer_tracker = {0};
  allocation_tracker reference_tracker = {0};
  lf_instance *subject = NULL;
  lf_instance *peer = NULL;
  lf_instance *reference = NULL;
  lf_instance *old_instances[2];
  lf_instance *new_instances[3];
  lf_load_result subject_old = {.struct_size = sizeof(subject_old)};
  lf_load_result peer_old = {.struct_size = sizeof(peer_old)};
  lf_load_result subject_new = {.struct_size = sizeof(subject_new)};
  lf_load_result peer_new = {.struct_size = sizeof(peer_new)};
  lf_load_result reference_load = {.struct_size = sizeof(reference_load)};
  lf_profile profile_before;
  lf_profile profile_after;
  media_observation subject_media;
  media_observation peer_media;
  media_observation reference_media;
  lf_run_result old_result = {.struct_size = sizeof(old_result)};
  lf_run_result first_new_result = {.struct_size = sizeof(first_new_result)};
  uint8_t *replacement_content = NULL;
  size_t frame = 0U;
  int ok = 0;
  if (fixture == NULL || fixture_extent != LF_NESTURBATOR_SAVE_FIXTURE_TOTAL_BYTES ||
      !tracker_create(&subject_tracker, &subject) ||
      !tracker_create(&peer_tracker, &peer) ||
      !set_load_fixture(subject, fixture, fixture_extent, NULL, &subject_old) ||
      !set_load_fixture(peer, fixture, fixture_extent, NULL, &peer_old) ||
      !snapshot_profile(&profile_before)) {
    report_case_failure("P03", "old-session-setup");
    goto cleanup;
  }
  old_instances[0] = subject;
  old_instances[1] = peer;
  for (frame = 1U; frame <= 3U; ++frame) {
    if (!advance_group(old_instances, 2U, 1, UINT32_C(0x0001),
                       UINT32_C(0x0001), (uint64_t)frame, &old_result)) {
      report_case_failure("P03", "old-history");
      goto cleanup;
    }
  }
  if (old_result.cumulative_units != 3U || old_result.core_ticks_valid != 1U ||
      !copy_media(subject, &subject_media) || subject_media.generation != 3U ||
      lf_set_input(subject, &(lf_input){.struct_size = sizeof(lf_input),
                                        .buttons = UINT32_C(0x0001)}) != LF_OK ||
      lf_set_input(peer, &(lf_input){.struct_size = sizeof(lf_input),
                                     .buttons = UINT32_C(0x0001)}) != LF_OK) {
    report_case_failure("P03", "old-state-precondition");
    goto cleanup;
  }
  replacement_content = (uint8_t *)malloc(fixture_extent);
  if (replacement_content == NULL) {
    report_case_failure("P03", "replacement-allocation");
    goto cleanup;
  }
  memcpy(replacement_content, fixture, fixture_extent);
  {
    const lf_load_request subject_request = {
        .struct_size = sizeof(subject_request),
        .content_data = replacement_content,
        .content_size_bytes = fixture_extent,
        .configuration_id = NULL,
    };
    const lf_load_request peer_request = {
        .struct_size = sizeof(peer_request),
        .content_data = replacement_content,
        .content_size_bytes = fixture_extent,
        .configuration_id = LF_SAVE_ORACLE_CONFIGURATION_IDENTITY,
    };
    memset(&subject_new, 0, sizeof(subject_new));
    memset(&peer_new, 0, sizeof(peer_new));
    subject_new.struct_size = sizeof(subject_new);
    peer_new.struct_size = sizeof(peer_new);
    if (lf_load(subject, &subject_request, &subject_new) != LF_OK ||
        lf_load(peer, &peer_request, &peer_new) != LF_OK ||
        !load_result_is_active(&subject_new, fixture_extent) ||
        !load_result_is_active(&peer_new, fixture_extent)) {
      report_case_failure("P03", "replacement-load");
      goto cleanup;
    }
  }
  memset(replacement_content, UINT8_C(0xa5), fixture_extent);
  free(replacement_content);
  replacement_content = NULL;

  if (!tracker_create(&reference_tracker, &reference) ||
      !set_load_fixture(reference, fixture, fixture_extent, NULL,
                        &reference_load) ||
      !load_result_is_active(&subject_new, fixture_extent) ||
      !load_result_is_active(&peer_new, fixture_extent) ||
      !same_load_result(&subject_new, &peer_new) ||
      !snapshot_profile(&profile_after) ||
      !same_profile(&profile_before, &profile_after) ||
      !copy_media(subject, &subject_media) ||
      !copy_media(peer, &peer_media) ||
      !copy_media(reference, &reference_media) ||
      !media_is_zero(&subject_media) || !media_is_zero(&peer_media) ||
      !media_is_zero(&reference_media) ||
      !media_equal(&subject_media, &peer_media) ||
      !media_equal(&subject_media, &reference_media)) {
    report_case_failure("P03", "replacement-reset-state");
    goto cleanup;
  }
  new_instances[0] = subject;
  new_instances[1] = peer;
  new_instances[2] = reference;
  if (!run_zero_work_group(new_instances, 3U)) {
    goto cleanup;
  }
  for (frame = 1U; frame <= 3U; ++frame) {
    const uint32_t buttons = frame == 2U ? UINT32_C(0x0100) : 0U;
    lf_run_result *capture_out = frame == 1U ? &first_new_result : NULL;
    if (!advance_group(new_instances, 3U, frame == 1U ? 0 : 1, buttons,
                       buttons, (uint64_t)frame, capture_out)) {
      report_case_failure("P03", "replacement-continuation");
      goto cleanup;
    }
  }
  if (first_new_result.sampled_buttons != 0U ||
      first_new_result.cumulative_units != 1U ||
      first_new_result.core_ticks_valid != 1U ||
      first_new_result.cumulative_core_ticks >=
          old_result.cumulative_core_ticks) {
    report_case_failure("P03", "replacement-frame-tick-input-reset");
    goto cleanup;
  }
  ok = 1;
cleanup:
  free(replacement_content);
  if (!tracker_destroy_instance(&subject_tracker, &subject)) {
    report_case_failure("P03", "subject-destroy-balance");
    ok = 0;
  }
  if (!tracker_destroy_instance(&peer_tracker, &peer)) {
    report_case_failure("P03", "peer-destroy-balance");
    ok = 0;
  }
  if (!tracker_destroy_instance(&reference_tracker, &reference)) {
    report_case_failure("P03", "destroy-balance");
    ok = 0;
  }
  return ok;
}

static void free_refusal_cases(refusal_case cases[7]) {
  size_t index = 0U;
  for (index = 0U; index < 7U; ++index) {
    size_t earlier = 0U;
    int already_freed = 0;
    for (earlier = 0U; earlier < index; ++earlier) {
      if (cases[index].storage != NULL &&
          cases[index].storage == cases[earlier].storage) {
        already_freed = 1;
        break;
      }
    }
    if (already_freed == 0) {
      free(cases[index].storage);
    }
  }
  for (index = 0U; index < 7U; ++index) {
    cases[index].storage = NULL;
    cases[index].content = NULL;
  }
}

int main(void) {
  uint8_t fixture[LF_NESTURBATOR_SAVE_FIXTURE_TOTAL_BYTES];
  uint8_t fixture_digest[32];
  refusal_case cases[7] = {{0}};
  size_t fixture_extent = 0U;
  size_t index = 0U;
  int ok = 1;
  fixture_extent = lf_build_nesturbator_save_fixture(fixture, sizeof(fixture));
  if (fixture_extent != sizeof(fixture) ||
      !lf_nesturbator_save_fixture_sha256(fixture, fixture_extent,
                                          fixture_digest) ||
      !lf_save_oracle_sha256_matches(fixture_digest, sizeof(fixture_digest)) ||
      !setup_refusal_cases(cases, fixture, fixture_extent)) {
    (void)fprintf(stderr, "installed_load: fixture setup failed\n");
    free_refusal_cases(cases);
    return 1;
  }
  for (index = 0U; index < 7U; ++index) {
    if (!run_unloaded_refusal(fixture, fixture_extent, &cases[index]) ||
        !run_loaded_refusal(fixture, fixture_extent, &cases[index])) {
      ok = 0;
      break;
    }
  }
  if (ok != 0 && !run_replacement_reset(fixture, fixture_extent)) {
    ok = 0;
  }
  free_refusal_cases(cases);
  if (ok == 0) {
    return 1;
  }
  (void)puts("nesturbator_installed_load: refusals=7 replacement=reset continuation-frames=3 result=pass");
  return 0;
}
