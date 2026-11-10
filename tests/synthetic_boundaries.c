#include <libfuturo/libfuturo.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(condition, label)                                               \
  do {                                                                        \
    if (!(condition)) {                                                       \
      (void)fprintf(stderr, "synthetic_boundaries: %s failed\n", (label)); \
      return 0;                                                               \
    }                                                                         \
  } while (0)

#define CHECK_GOTO(condition, label)                                          \
  do {                                                                        \
    if (!(condition)) {                                                       \
      (void)fprintf(stderr, "synthetic_boundaries: %s failed\n", (label)); \
      goto cleanup;                                                           \
    }                                                                         \
  } while (0)

typedef struct allocation_tracker {
  size_t calls;
  size_t fail_on_call;
  size_t allocations;
  size_t frees;
  size_t live;
  size_t duplicate_frees;
  void *live_allocations[8];
} allocation_tracker;

typedef enum rejected_advance_case {
  REJECT_NULL_REQUEST,
  REJECT_SHORT_REQUEST_RECORD,
  REJECT_LARGE_REQUEST_RECORD,
  REJECT_OVER_LIMIT_WORK,
  REJECT_SHORT_STRIDE,
  REJECT_OVERFLOWING_STRIDE,
  REJECT_ZERO_VIDEO_CAPACITY,
  REJECT_SHORT_VIDEO_CAPACITY,
  REJECT_ZERO_AUDIO_CAPACITY,
  REJECT_SHORT_AUDIO_CAPACITY,
  REJECT_SHORT_PADDED_VIDEO_CAPACITY,
  REJECT_FOUR_WORK_ONE_STEP_AUDIO
} rejected_advance_case;

static void *tracked_allocate(void *context, size_t bytes) {
  allocation_tracker *tracker = (allocation_tracker *)context;
  void *allocation = NULL;
  size_t index = 0U;

  tracker->calls += 1U;
  if (tracker->fail_on_call == tracker->calls) {
    return NULL;
  }

  allocation = malloc(bytes);
  if (allocation == NULL) {
    return NULL;
  }
  for (index = 0U; index < sizeof(tracker->live_allocations) /
                                  sizeof(tracker->live_allocations[0]);
       ++index) {
    if (tracker->live_allocations[index] == NULL) {
      tracker->live_allocations[index] = allocation;
      tracker->allocations += 1U;
      tracker->live += 1U;
      return allocation;
    }
  }
  free(allocation);
  return NULL;
}

static void tracked_deallocate(void *context, void *allocation) {
  allocation_tracker *tracker = (allocation_tracker *)context;
  size_t index = 0U;

  tracker->frees += 1U;
  for (index = 0U; index < sizeof(tracker->live_allocations) /
                                  sizeof(tracker->live_allocations[0]);
       ++index) {
    if (tracker->live_allocations[index] == allocation) {
      tracker->live_allocations[index] = NULL;
      tracker->live -= 1U;
      free(allocation);
      return;
    }
  }
  tracker->duplicate_frees += 1U;
}

static lf_create_options tracked_options(allocation_tracker *tracker) {
  return (lf_create_options){
      .struct_size = sizeof(lf_create_options),
      .allocate = tracked_allocate,
      .deallocate = tracked_deallocate,
      .allocator_context = tracker,
  };
}

static lf_run_request make_request(uint32_t work_units, uint8_t *video,
                                   size_t video_capacity, size_t video_stride,
                                   int16_t *audio, size_t audio_capacity) {
  return (lf_run_request){
      .struct_size = sizeof(lf_run_request),
      .work_units = work_units,
      .video_data = video,
      .video_capacity_bytes = video_capacity,
      .video_stride_bytes = video_stride,
      .audio_data = audio,
      .audio_capacity_samples = audio_capacity,
  };
}

static int result_is_rejected(const lf_run_result *result,
                              uint64_t expected_position) {
  return result->struct_size == sizeof(*result) &&
         result->actual_units == 0U && result->overshoot_units == 0U &&
         result->sampled_buttons == 0U &&
         result->video_valid == 0U && result->audio_valid == 0U &&
         result->video_extent_bytes == 0U &&
         result->audio_produced_samples == 0U &&
         result->cumulative_units == expected_position &&
         result->stop_reason == LF_STOP_REJECTED;
}

static int copy_media(lf_instance *instance, uint8_t bytes[4],
                      lf_media_info *info) {
  memset(bytes, 0, 4U);
  *info = (lf_media_info){.struct_size = sizeof(*info)};
  return lf_copy_media(instance, bytes, 4U, info) == LF_OK;
}

static int media_is(const uint8_t actual[4], const lf_media_info *info,
                    const uint8_t expected[4], uint64_t generation) {
  return memcmp(actual, expected, 4U) == 0 &&
         info->struct_size == sizeof(*info) && info->identity != NULL &&
         strcmp(info->identity, "synthetic-media-v1") == 0 &&
         info->extent_bytes == 4U && info->guest_generation == generation;
}

static int advance_seed(lf_instance *instance) {
  uint8_t video[4] = {0U};
  int16_t audio[2] = {0, 0};
  lf_input input = {.struct_size = sizeof(input), .buttons = 0U};
  lf_run_request request = make_request(1U, video, sizeof(video), 2U, audio,
                                        sizeof(audio) / sizeof(audio[0]));
  lf_run_result result = {.struct_size = sizeof(result)};

  return lf_set_input(instance, &input) == LF_OK &&
         lf_advance(instance, &request, &result) == LF_OK &&
         result.actual_units == 1U && result.cumulative_units == 1U &&
         video[0] == 1U && video[1] == 1U && video[2] == 0U &&
         video[3] == 2U && audio[0] == INT16_C(16) &&
         audio[1] == -INT16_C(16);
}

static int compare_followup(lf_instance *subject, lf_instance *reference) {
  uint8_t subject_video[6];
  uint8_t reference_video[6];
  int16_t subject_audio[4];
  int16_t reference_audio[4];
  uint8_t subject_media[4];
  uint8_t reference_media[4];
  lf_media_info subject_info = {.struct_size = sizeof(subject_info)};
  lf_media_info reference_info = {.struct_size = sizeof(reference_info)};
  lf_run_request subject_request;
  lf_run_request reference_request;
  lf_run_result subject_result = {.struct_size = sizeof(subject_result)};
  lf_run_result reference_result = {.struct_size = sizeof(reference_result)};
  const uint8_t expected_video[4] = {2U, 5U, 3U, 7U};
  const uint8_t expected_media[4] = {76U, 70U, 2U, 5U};

  memset(subject_video, 0xA5, sizeof(subject_video));
  memset(reference_video, 0xA5, sizeof(reference_video));
  for (size_t index = 0U; index < 4U; ++index) {
    subject_audio[index] = INT16_C(1234);
    reference_audio[index] = INT16_C(1234);
  }
  subject_request = make_request(1U, subject_video, sizeof(subject_video), 2U,
                                 subject_audio, 2U);
  reference_request = make_request(1U, reference_video,
                                   sizeof(reference_video), 2U,
                                   reference_audio, 2U);

  if (lf_advance(subject, &subject_request, &subject_result) != LF_OK ||
      lf_advance(reference, &reference_request, &reference_result) != LF_OK) {
    return 0;
  }
  if (subject_result.requested_units != 1U ||
      subject_result.actual_units != 1U ||
      subject_result.sampled_buttons != 3U ||
      subject_result.cumulative_units != 2U ||
      subject_result.video_extent_bytes != 4U ||
      subject_result.audio_produced_samples != 2U ||
      subject_result.stop_reason != LF_STOP_BUDGET_REACHED ||
      memcmp(subject_video, expected_video, sizeof(expected_video)) != 0 ||
      subject_audio[0] != INT16_C(80) || subject_audio[1] != -INT16_C(80) ||
      subject_video[4] != 0xA5U || subject_video[5] != 0xA5U ||
      subject_audio[2] != INT16_C(1234) ||
      subject_audio[3] != INT16_C(1234) ||
      memcmp(subject_video, reference_video, sizeof(subject_video)) != 0 ||
      memcmp(subject_audio, reference_audio, sizeof(subject_audio)) != 0) {
    return 0;
  }
  if (!copy_media(subject, subject_media, &subject_info) ||
      !copy_media(reference, reference_media, &reference_info)) {
    return 0;
  }
  return media_is(subject_media, &subject_info, expected_media, 2U) &&
         memcmp(subject_media, reference_media, sizeof(subject_media)) == 0 &&
         subject_info.guest_generation == reference_info.guest_generation;
}

static int test_allocator_lifecycle(void) {
  allocation_tracker tracker = {0};
  lf_create_options options = tracked_options(&tracker);
  lf_instance *instance = NULL;
  lf_instance *sentinel_owner = NULL;
  uint8_t retained_media[4] = {0U};
  lf_media_info retained_info = {.struct_size = sizeof(retained_info)};
  const uint8_t expected_retained_media[4] = {76U, 70U, 1U, 1U};

  CHECK(lf_destroy(NULL) == LF_INVALID_ARGUMENT, "null owner pointer rejected");
  CHECK(lf_create("synthetic-v1", NULL, NULL) == LF_INVALID_ARGUMENT,
        "null create output pointer rejected");

  for (size_t cycle = 0U; cycle < 3U; ++cycle) {
    uint8_t video[4] = {0U};
    int16_t audio[2] = {0, 0};
    lf_input input = {.struct_size = sizeof(input), .buttons = 0U};
    lf_run_request request = make_request(1U, video, sizeof(video), 2U, audio,
                                          sizeof(audio) / sizeof(audio[0]));
    lf_run_result result = {.struct_size = sizeof(result)};

    CHECK(lf_create("synthetic-v1", NULL, &instance) == LF_OK &&
              instance != NULL,
          "repeated default create succeeds");
    CHECK(lf_set_input(instance, &input) == LF_OK &&
              lf_advance(instance, &request, &result) == LF_OK,
          "fresh instance can be used");
    CHECK(copy_media(instance, retained_media, &retained_info),
          "fresh instance media can be copied");
    CHECK(lf_destroy(&instance) == LF_OK && instance == NULL,
          "destroy clears the owning handle");
    CHECK(lf_destroy(&instance) == LF_OK && instance == NULL,
          "repeated null-handle destruction is harmless");
    CHECK(media_is(retained_media, &retained_info, expected_retained_media, 1U),
          "host-owned media copy remains readable after destruction");
  }

  CHECK(lf_create("synthetic-v1", NULL, &sentinel_owner) == LF_OK,
        "valid owner available to verify failed-create output clearing");
  memset(&tracker, 0, sizeof(tracker));
  options = tracked_options(&tracker);
  instance = NULL;
  CHECK(lf_create("synthetic-v1", &options, &instance) == LF_OK &&
            instance != NULL && tracker.calls == 2U &&
            tracker.allocations == 2U && tracker.live == 2U,
        "test allocator observes both successful allocations");
  CHECK(lf_destroy(&instance) == LF_OK && instance == NULL &&
            tracker.frees == 2U && tracker.live == 0U &&
            tracker.duplicate_frees == 0U,
        "successful custom allocation path frees each block once");

  memset(&tracker, 0, sizeof(tracker));
  tracker.fail_on_call = 1U;
  options = tracked_options(&tracker);
  instance = sentinel_owner;
  CHECK(lf_create("synthetic-v1", &options, &instance) ==
                LF_RESOURCE_EXHAUSTED &&
            instance == NULL && tracker.calls == 1U &&
            tracker.allocations == 0U && tracker.frees == 0U &&
            tracker.live == 0U,
        "first allocation failure clears output and owns nothing");

  memset(&tracker, 0, sizeof(tracker));
  tracker.fail_on_call = 2U;
  options = tracked_options(&tracker);
  instance = sentinel_owner;
  CHECK(lf_create("synthetic-v1", &options, &instance) ==
                LF_RESOURCE_EXHAUSTED &&
            instance == NULL && tracker.calls == 2U &&
            tracker.allocations == 1U && tracker.frees == 1U &&
            tracker.live == 0U && tracker.duplicate_frees == 0U,
        "second allocation failure releases the first block exactly once");

  CHECK(lf_destroy(&sentinel_owner) == LF_OK && sentinel_owner == NULL,
        "sentinel owner remains valid after failed creates");

  return 1;
}

static int test_sequential_instance_independence(void) {
  lf_instance *left = NULL;
  lf_instance *right = NULL;
  lf_input left_input = {.struct_size = sizeof(left_input), .buttons = 1U};
  lf_input right_input = {.struct_size = sizeof(right_input), .buttons = 3U};
  uint8_t left_video[4] = {0U};
  uint8_t right_video[4] = {0U};
  int16_t left_audio[2] = {0, 0};
  int16_t right_audio[2] = {0, 0};
  lf_run_request left_request = make_request(1U, left_video, sizeof(left_video),
                                             2U, left_audio, 2U);
  lf_run_request right_request = make_request(1U, right_video,
                                              sizeof(right_video), 2U,
                                              right_audio, 2U);
  lf_run_result left_result = {.struct_size = sizeof(left_result)};
  lf_run_result right_result = {.struct_size = sizeof(right_result)};

  CHECK(lf_create("synthetic-v1", NULL, &left) == LF_OK &&
            lf_create("synthetic-v1", NULL, &right) == LF_OK,
        "two instances can be created");
  CHECK(lf_set_input(left, &left_input) == LF_OK &&
            lf_set_input(right, &right_input) == LF_OK,
        "each instance accepts its own input");
  CHECK(lf_advance(left, &left_request, &left_result) == LF_OK &&
            lf_advance(right, &right_request, &right_result) == LF_OK,
        "serialized interleaving succeeds");
  CHECK(left_result.cumulative_units == 1U && right_result.cumulative_units == 1U &&
            left_video[0] == 1U && left_video[1] == 2U && left_video[2] == 1U &&
            left_video[3] == 3U && right_video[0] == 1U &&
            right_video[1] == 4U && right_video[2] == 3U &&
            right_video[3] == 5U && left_audio[0] == INT16_C(32) &&
            left_audio[1] == -INT16_C(32) && right_audio[0] == INT16_C(64) &&
            right_audio[1] == -INT16_C(64),
        "interleaved instances retain independent literal state");
  CHECK(lf_destroy(&left) == LF_OK && lf_destroy(&right) == LF_OK,
        "both independent owners can be destroyed");
  return 1;
}

static int test_capability_and_synthetic_load_boundaries(void) {
  lf_instance *subject = NULL;
  lf_instance *reference = NULL;
  lf_input input = {.struct_size = sizeof(input), .buttons = 3U};
  const uint8_t content[1] = {0x5AU};
  lf_load_request request = {
      .struct_size = sizeof(request),
      .content_data = content,
      .content_size_bytes = sizeof(content),
      .configuration_id = NULL,
  };
  lf_load_result result = {.struct_size = sizeof(result)};
  uint32_t supported = UINT32_MAX;
  int succeeded = 0;

  CHECK_GOTO(lf_get_capability("synthetic-v1", NULL,
                               LF_CAP_LOGICAL_INPUT, &supported) == LF_OK &&
                 supported == 1U,
             "supported capability is reported independently");
  CHECK_GOTO(lf_get_capability("synthetic-v1", NULL,
                               LF_CAP_CONCURRENT_USE, &supported) ==
                     LF_UNSUPPORTED &&
                 supported == 0U,
             "concurrent calls are explicitly unsupported");
  CHECK_GOTO(lf_get_capability("synthetic-v1", NULL,
                               (lf_capability)999, &supported) ==
                     LF_INVALID_ARGUMENT &&
                 supported == 0U,
             "unknown capability differs from a known unavailable one");

  CHECK_GOTO(lf_create("synthetic-v1", NULL, &subject) == LF_OK,
             "synthetic load subject created");
  CHECK_GOTO(lf_create("synthetic-v1", NULL, &reference) == LF_OK,
             "synthetic load reference created");
  CHECK_GOTO(advance_seed(subject) && advance_seed(reference) &&
                 lf_set_input(subject, &input) == LF_OK &&
                 lf_set_input(reference, &input) == LF_OK,
             "synthetic load histories and pending input match");

  memset(&result, 0xA5, sizeof(result));
  result.struct_size = sizeof(result);
  CHECK_GOTO(lf_load(subject, &request, &result) == LF_UNSUPPORTED &&
                 result.struct_size == sizeof(result) && result.loaded == 0U &&
                 result.content_size_bytes == 0U &&
                 result.effective_configuration_id == NULL,
             "valid synthetic load request reports unsupported without effects");

  memset(&result, 0xA5, sizeof(result));
  result.struct_size = sizeof(result);
  CHECK_GOTO(lf_load(subject, NULL, &result) == LF_INVALID_ARGUMENT &&
                 result.struct_size == sizeof(result) && result.loaded == 0U &&
                 result.content_size_bytes == 0U &&
                 result.effective_configuration_id == NULL,
             "missing load request differs from unsupported profile operation");

  request.content_data = NULL;
  memset(&result, 0xA5, sizeof(result));
  result.struct_size = sizeof(result);
  CHECK_GOTO(lf_load(subject, &request, &result) == LF_INVALID_ARGUMENT &&
                 result.struct_size == sizeof(result) && result.loaded == 0U &&
                 result.content_size_bytes == 0U &&
                 result.effective_configuration_id == NULL,
             "missing content pointer is rejected before unsupported operation");

  request.content_data = content;
  request.content_size_bytes = 0U;
  memset(&result, 0xA5, sizeof(result));
  result.struct_size = sizeof(result);
  CHECK_GOTO(lf_load(subject, &request, &result) == LF_INVALID_ARGUMENT &&
                 result.struct_size == sizeof(result) && result.loaded == 0U &&
                 result.content_size_bytes == 0U &&
                 result.effective_configuration_id == NULL,
             "empty content span is rejected before unsupported operation");

  request.content_size_bytes = sizeof(content);
  request.struct_size -= 1U;
  memset(&result, 0xA5, sizeof(result));
  result.struct_size = sizeof(result);
  CHECK_GOTO(lf_load(subject, &request, &result) == LF_INVALID_ARGUMENT &&
                 result.struct_size == sizeof(result) && result.loaded == 0U &&
                 result.content_size_bytes == 0U &&
                 result.effective_configuration_id == NULL,
             "malformed load record is rejected before unsupported operation");
  CHECK_GOTO(content[0] == 0x5AU && compare_followup(subject, reference),
             "unsupported and invalid load requests preserve pending input and history");
  succeeded = 1;

cleanup:
  if (subject != NULL) {
    (void)lf_destroy(&subject);
  }
  if (reference != NULL) {
    (void)lf_destroy(&reference);
  }
  return succeeded;
}

static int test_synthetic_media_import_timing(void) {
  lf_instance *subject = NULL;
  lf_instance *reference = NULL;
  const uint8_t content[] = {'L', 'F', 'T', '1'};
  const uint8_t saved_media[4] = {'S', 'A', 'V', 'E'};
  const uint8_t default_media[4] = {76U, 70U, 0U, 0U};
  const uint8_t advanced_media[4] = {76U, 70U, 1U, 1U};
  uint8_t actual_media[4] = {0U};
  lf_media_info actual_info = {.struct_size = sizeof(actual_info)};
  lf_load_request request = {
      .struct_size = sizeof(request),
      .content_data = content,
      .content_size_bytes = sizeof(content),
      .configuration_id = NULL,
  };
  lf_load_result load_result = {.struct_size = sizeof(load_result)};
  lf_input pending = {.struct_size = sizeof(pending), .buttons = 3U};
  int succeeded = 0;

  CHECK_GOTO(lf_create("synthetic-v1", NULL, &subject) == LF_OK &&
                 lf_create("synthetic-v1", NULL, &reference) == LF_OK,
             "synthetic import instances created");
  CHECK_GOTO(lf_load(subject, &request, &load_result) == LF_OK &&
                 load_result.loaded == 1U &&
                 load_result.content_size_bytes == sizeof(content) &&
                 load_result.effective_configuration_id != NULL &&
                 strcmp(load_result.effective_configuration_id,
                        "synthetic-default") == 0,
             "one owned synthetic test content loads successfully");
  CHECK_GOTO(copy_media(subject, actual_media, &actual_info) &&
                 media_is(actual_media, &actual_info, default_media, 0U),
             "successful load resets synthetic media and guest generation");
  load_result = (lf_load_result){.struct_size = sizeof(load_result)};
  CHECK_GOTO(lf_load(reference, &request, &load_result) == LF_OK &&
                 load_result.loaded == 1U,
             "reference instance loads the same test content");

  CHECK_GOTO(lf_import_media(subject, "synthetic-media-v1", saved_media,
                             sizeof(saved_media)) == LF_OK &&
                 copy_media(subject, actual_media, &actual_info) &&
                 media_is(actual_media, &actual_info, saved_media, 0U),
             "valid pre-advance import preserves guest generation");
  CHECK_GOTO(lf_import_media(subject, "synthetic-media-v1", saved_media,
                             sizeof(saved_media)) == LF_OK &&
                 copy_media(subject, actual_media, &actual_info) &&
                 media_is(actual_media, &actual_info, saved_media, 0U),
             "repeating the same import is idempotent");
  CHECK_GOTO(lf_import_media(subject, "synthetic-media-v1", NULL,
                             sizeof(saved_media)) == LF_INVALID_ARGUMENT &&
                 copy_media(subject, actual_media, &actual_info) &&
                 media_is(actual_media, &actual_info, saved_media, 0U),
             "malformed null media source is rejected unchanged");
  CHECK_GOTO(lf_import_media(subject, "synthetic-media-v1", saved_media, 0U) ==
                     LF_INVALID_ARGUMENT &&
                 copy_media(subject, actual_media, &actual_info) &&
                 media_is(actual_media, &actual_info, saved_media, 0U),
             "empty media span is rejected unchanged");
  CHECK_GOTO(lf_import_media(subject, "synthetic-media-v2", saved_media,
                             sizeof(saved_media)) == LF_UNSUPPORTED &&
                 copy_media(subject, actual_media, &actual_info) &&
                 media_is(actual_media, &actual_info, saved_media, 0U),
             "wrong media identity is rejected unchanged");
  CHECK_GOTO(lf_import_media(subject, "synthetic-media-v1", saved_media,
                             sizeof(saved_media) - 1U) == LF_INVALID_ARGUMENT &&
                 copy_media(subject, actual_media, &actual_info) &&
                 media_is(actual_media, &actual_info, saved_media, 0U),
             "short media extent is rejected unchanged");
  {
    const uint8_t oversized_media[5] = {'S', 'A', 'V', 'E', '!'};
    CHECK_GOTO(lf_import_media(subject, "synthetic-media-v1", oversized_media,
                               sizeof(oversized_media)) == LF_INVALID_ARGUMENT &&
                   copy_media(subject, actual_media, &actual_info) &&
                   media_is(actual_media, &actual_info, saved_media, 0U),
               "long media extent is rejected unchanged");
  }

  CHECK_GOTO(lf_import_media(reference, "synthetic-media-v1", saved_media,
                             sizeof(saved_media)) == LF_OK &&
                 advance_seed(subject) && advance_seed(reference) &&
                 lf_set_input(subject, &pending) == LF_OK &&
                 lf_set_input(reference, &pending) == LF_OK,
             "matching sessions advance after compatible imports");
  CHECK_GOTO(lf_import_media(subject, "synthetic-media-v1", saved_media,
                             sizeof(saved_media)) == LF_INVALID_ARGUMENT &&
                 copy_media(subject, actual_media, &actual_info) &&
                 media_is(actual_media, &actual_info, advanced_media, 1U) &&
                 compare_followup(subject, reference),
             "late import is rejected without changing media or history");
  succeeded = 1;

cleanup:
  if (subject != NULL) {
    (void)lf_destroy(&subject);
  }
  if (reference != NULL) {
    (void)lf_destroy(&reference);
  }
  return succeeded;
}

static int run_create_failure_preserves_peer(size_t fail_on_call) {
  allocation_tracker failed_tracker = {0};
  allocation_tracker peer_tracker = {0};
  lf_create_options failed_options = tracked_options(&failed_tracker);
  lf_create_options peer_options = tracked_options(&peer_tracker);
  lf_instance *peer = NULL;
  lf_instance *reference = NULL;
  lf_instance *failed_output = NULL;
  int succeeded = 0;

  failed_tracker.fail_on_call = fail_on_call;
  if (lf_create("synthetic-v1", &peer_options, &peer) != LF_OK ||
      lf_create("synthetic-v1", NULL, &reference) != LF_OK ||
      !advance_seed(peer) || !advance_seed(reference)) {
    (void)fprintf(stderr,
                  "synthetic_boundaries: allocator peer setup failed at call %zu\n",
                  fail_on_call);
    goto cleanup;
  }
  {
    lf_input pending = {.struct_size = sizeof(pending), .buttons = 3U};
    if (lf_set_input(peer, &pending) != LF_OK ||
        lf_set_input(reference, &pending) != LF_OK) {
      (void)fprintf(stderr,
                    "synthetic_boundaries: allocator peer input failed at call %zu\n",
                    fail_on_call);
      goto cleanup;
    }
  }

  failed_output = peer;
  if (lf_create("synthetic-v1", &failed_options, &failed_output) !=
          LF_RESOURCE_EXHAUSTED ||
      failed_output != NULL || failed_tracker.calls != fail_on_call ||
      failed_tracker.live != 0U || failed_tracker.duplicate_frees != 0U ||
      peer_tracker.live != 2U || !compare_followup(peer, reference)) {
    (void)fprintf(stderr,
                  "synthetic_boundaries: create allocation failure %zu affected its peer\n",
                  fail_on_call);
    goto cleanup;
  }
  succeeded = 1;

cleanup:
  if (peer != NULL) {
    (void)lf_destroy(&peer);
  }
  if (reference != NULL) {
    (void)lf_destroy(&reference);
  }
  if (peer_tracker.live != 0U || peer_tracker.allocations != peer_tracker.frees ||
      failed_tracker.live != 0U) {
    (void)fprintf(stderr,
                  "synthetic_boundaries: create allocation failure %zu leaked allocations\n",
                  fail_on_call);
    succeeded = 0;
  }
  return succeeded;
}

static int test_create_failure_peer_independence(void) {
  CHECK(run_create_failure_preserves_peer(1U),
        "first create allocation failure preserves independent session");
  CHECK(run_create_failure_preserves_peer(2U),
        "second create allocation failure preserves independent session");
  return 1;
}

static int run_advance_rejection_case(rejected_advance_case which,
                                      const char *label,
                                      lf_status expected_status) {
  lf_instance *subject = NULL;
  lf_instance *reference = NULL;
  lf_input input = {.struct_size = sizeof(input), .buttons = 3U};
  uint8_t video[8];
  int16_t audio[4];
  lf_run_request request = make_request(1U, video, 4U, 2U, audio, 2U);
  lf_run_result result;
  uint8_t before_media[4];
  uint8_t after_media[4];
  uint8_t reference_media[4];
  lf_media_info before_info = {.struct_size = sizeof(before_info)};
  lf_media_info after_info = {.struct_size = sizeof(after_info)};
  lf_media_info reference_info = {.struct_size = sizeof(reference_info)};
  lf_status status = LF_OK;
  uint32_t expected_requested_units = 1U;
  int succeeded = 0;

  memset(video, 0xA5, sizeof(video));
  for (size_t index = 0U; index < 4U; ++index) {
    audio[index] = INT16_C(1234);
  }
  memset(&result, 0x6D, sizeof(result));
  result.struct_size = sizeof(result);
  if (lf_create("synthetic-v1", NULL, &subject) != LF_OK ||
      lf_create("synthetic-v1", NULL, &reference) != LF_OK) {
    (void)fprintf(stderr, "synthetic_boundaries: %s setup failed\n", label);
    goto cleanup;
  }
  if (!advance_seed(subject) || !advance_seed(reference) ||
      lf_set_input(subject, &input) != LF_OK ||
      lf_set_input(reference, &input) != LF_OK ||
      !copy_media(subject, before_media, &before_info) ||
      !copy_media(reference, reference_media, &reference_info) ||
      memcmp(before_media, reference_media, sizeof(before_media)) != 0 ||
      before_info.guest_generation != 1U) {
    (void)fprintf(stderr, "synthetic_boundaries: %s baseline failed\n", label);
    goto cleanup;
  }

  switch (which) {
    case REJECT_NULL_REQUEST:
      status = lf_advance(subject, NULL, &result);
      expected_status = LF_INVALID_ARGUMENT;
      expected_requested_units = 0U;
      break;
    case REJECT_SHORT_REQUEST_RECORD:
      request.struct_size -= 1U;
      status = lf_advance(subject, &request, &result);
      expected_requested_units = 0U;
      break;
    case REJECT_LARGE_REQUEST_RECORD:
      request.struct_size += 1U;
      status = lf_advance(subject, &request, &result);
      expected_requested_units = 0U;
      break;
    case REJECT_OVER_LIMIT_WORK:
      request.work_units = 5U;
      request.audio_capacity_samples = 10U;
      status = lf_advance(subject, &request, &result);
      expected_requested_units = 5U;
      break;
    case REJECT_SHORT_STRIDE:
      request.video_stride_bytes = 1U;
      status = lf_advance(subject, &request, &result);
      break;
    case REJECT_OVERFLOWING_STRIDE:
      request.video_stride_bytes = SIZE_MAX;
      status = lf_advance(subject, &request, &result);
      expected_status = LF_LIMIT_EXCEEDED;
      break;
    case REJECT_ZERO_VIDEO_CAPACITY:
      request.video_capacity_bytes = 0U;
      status = lf_advance(subject, &request, &result);
      expected_status = LF_BUFFER_TOO_SMALL;
      break;
    case REJECT_SHORT_VIDEO_CAPACITY:
      request.video_capacity_bytes = 3U;
      status = lf_advance(subject, &request, &result);
      expected_status = LF_BUFFER_TOO_SMALL;
      break;
    case REJECT_ZERO_AUDIO_CAPACITY:
      request.audio_capacity_samples = 0U;
      status = lf_advance(subject, &request, &result);
      expected_status = LF_BUFFER_TOO_SMALL;
      break;
    case REJECT_SHORT_AUDIO_CAPACITY:
      request.audio_capacity_samples = 1U;
      status = lf_advance(subject, &request, &result);
      expected_status = LF_BUFFER_TOO_SMALL;
      break;
    case REJECT_SHORT_PADDED_VIDEO_CAPACITY:
      request.video_stride_bytes = 3U;
      request.video_capacity_bytes = 4U;
      status = lf_advance(subject, &request, &result);
      expected_status = LF_BUFFER_TOO_SMALL;
      break;
    case REJECT_FOUR_WORK_ONE_STEP_AUDIO:
      request.work_units = 4U;
      request.video_capacity_bytes = 4U;
      request.audio_capacity_samples = 2U;
      status = lf_advance(subject, &request, &result);
      expected_status = LF_BUFFER_TOO_SMALL;
      expected_requested_units = 4U;
      break;
  }

  if (status != expected_status || !result_is_rejected(&result, 1U) ||
      result.requested_units != expected_requested_units) {
    (void)fprintf(stderr,
                  "synthetic_boundaries: %s returned status=%d and progress=%u\n",
                  label, (int)status, result.actual_units);
    goto cleanup;
  }
  for (size_t index = 0U; index < sizeof(video); ++index) {
    if (video[index] != 0xA5U) {
      (void)fprintf(stderr, "synthetic_boundaries: %s changed video canary\n",
                    label);
      goto cleanup;
    }
  }
  for (size_t index = 0U; index < sizeof(audio) / sizeof(audio[0]); ++index) {
    if (audio[index] != INT16_C(1234)) {
      (void)fprintf(stderr, "synthetic_boundaries: %s changed audio canary\n",
                    label);
      goto cleanup;
    }
  }
  if (!copy_media(subject, after_media, &after_info) ||
      memcmp(before_media, after_media, sizeof(before_media)) != 0 ||
      before_info.guest_generation != after_info.guest_generation ||
      before_info.extent_bytes != after_info.extent_bytes ||
      !compare_followup(subject, reference)) {
    (void)fprintf(stderr,
                  "synthetic_boundaries: %s changed hidden state or follow-up\n",
                  label);
    goto cleanup;
  }
  succeeded = 1;

cleanup:
  if (subject != NULL) {
    (void)lf_destroy(&subject);
  }
  if (reference != NULL) {
    (void)lf_destroy(&reference);
  }
  return succeeded;
}

static int run_input_rejection_case(int oversized, int invalid_mask,
                                    const char *label) {
  lf_instance *subject = NULL;
  lf_instance *reference = NULL;
  lf_input valid_input = {.struct_size = sizeof(valid_input), .buttons = 3U};
  lf_input bad_input = {.struct_size = sizeof(bad_input), .buttons = 0U};
  uint8_t before_media[4];
  uint8_t after_media[4];
  lf_media_info before_info = {.struct_size = sizeof(before_info)};
  lf_media_info after_info = {.struct_size = sizeof(after_info)};
  lf_status status = LF_OK;
  int succeeded = 0;

  if (lf_create("synthetic-v1", NULL, &subject) != LF_OK ||
      lf_create("synthetic-v1", NULL, &reference) != LF_OK) {
    (void)fprintf(stderr, "synthetic_boundaries: %s setup failed\n", label);
    goto cleanup;
  }
  if (!advance_seed(subject) || !advance_seed(reference) ||
      lf_set_input(subject, &valid_input) != LF_OK ||
      lf_set_input(reference, &valid_input) != LF_OK ||
      !copy_media(subject, before_media, &before_info)) {
    (void)fprintf(stderr, "synthetic_boundaries: %s baseline failed\n", label);
    goto cleanup;
  }
  if (invalid_mask) {
    bad_input.buttons = 4U;
  } else if (oversized) {
    bad_input.struct_size += 1U;
  } else {
    bad_input.struct_size -= 1U;
  }
  status = lf_set_input(subject, &bad_input);
  if (status != LF_INVALID_ARGUMENT ||
      !copy_media(subject, after_media, &after_info) ||
      memcmp(before_media, after_media, sizeof(before_media)) != 0 ||
      before_info.guest_generation != after_info.guest_generation ||
      !compare_followup(subject, reference)) {
    (void)fprintf(stderr,
                  "synthetic_boundaries: %s did not preserve state/input\n",
                  label);
    goto cleanup;
  }
  succeeded = 1;

cleanup:
  if (subject != NULL) {
    (void)lf_destroy(&subject);
  }
  if (reference != NULL) {
    (void)lf_destroy(&reference);
  }
  return succeeded;
}

static int test_result_record_rejection(void) {
  lf_instance *subject = NULL;
  lf_instance *reference = NULL;
  lf_input input = {.struct_size = sizeof(input), .buttons = 3U};
  uint8_t video[8];
  int16_t audio[4];
  lf_run_request request = make_request(1U, video, 4U, 2U, audio, 2U);
  lf_run_result result;
  lf_run_result before_result;
  uint8_t before_media[4];
  uint8_t after_media[4];
  lf_media_info before_info = {.struct_size = sizeof(before_info)};
  lf_media_info after_info = {.struct_size = sizeof(after_info)};
  int succeeded = 0;

  memset(video, 0xA5, sizeof(video));
  for (size_t index = 0U; index < 4U; ++index) {
    audio[index] = INT16_C(1234);
  }
  CHECK_GOTO(lf_create("synthetic-v1", NULL, &subject) == LF_OK,
             "bad result record subject created");
  CHECK_GOTO(lf_create("synthetic-v1", NULL, &reference) == LF_OK,
             "bad result record reference created");
  CHECK_GOTO(advance_seed(subject) && advance_seed(reference),
             "bad result record baseline seeded");
  CHECK_GOTO(lf_set_input(subject, &input) == LF_OK &&
                 lf_set_input(reference, &input) == LF_OK &&
                 copy_media(subject, before_media, &before_info),
             "bad result record preflight prepared");
  memset(&result, 0xD3, sizeof(result));
  result.struct_size = sizeof(result) - 1U;
  memcpy(&before_result, &result, sizeof(result));
  CHECK_GOTO(lf_advance(subject, &request, &result) == LF_INVALID_ARGUMENT,
             "undersized result record rejected");
  CHECK_GOTO(memcmp(&result, &before_result, sizeof(result)) == 0,
             "undersized result record remains untouched");
  CHECK_GOTO(video[0] == 0xA5U && audio[0] == INT16_C(1234),
             "invalid result record leaves output buffers untouched");

  memset(&result, 0xD3, sizeof(result));
  result.struct_size = sizeof(result) + 1U;
  memcpy(&before_result, &result, sizeof(result));
  CHECK_GOTO(lf_advance(subject, &request, &result) == LF_INVALID_ARGUMENT,
             "oversized result record rejected");
  CHECK_GOTO(memcmp(&result, &before_result, sizeof(result)) == 0,
             "oversized result record remains untouched");
  CHECK_GOTO(copy_media(subject, after_media, &after_info) &&
                 memcmp(before_media, after_media, sizeof(before_media)) == 0 &&
                 before_info.guest_generation == after_info.guest_generation &&
                 compare_followup(subject, reference),
             "invalid result records preserve pending input and hidden state");
  succeeded = 1;

cleanup:
  if (subject != NULL) {
    (void)lf_destroy(&subject);
  }
  if (reference != NULL) {
    (void)lf_destroy(&reference);
  }
  return succeeded;
}

static int test_valid_output_boundaries(void) {
  lf_instance *instance = NULL;
  lf_input input = {.struct_size = sizeof(input), .buttons = 3U};
  uint8_t video[8];
  int16_t audio[10];
  lf_run_request request;
  lf_run_result result = {.struct_size = sizeof(result)};
  const uint8_t expected_video[5] = {4U, 16U, 0xCCU, 3U, 20U};
  const int16_t expected_audio[8] = {
      INT16_C(64),  -INT16_C(64), INT16_C(128),  -INT16_C(128),
      INT16_C(192), -INT16_C(192), INT16_C(256), -INT16_C(256),
  };

  CHECK(lf_create("synthetic-v1", NULL, &instance) == LF_OK,
        "output boundary instance created");
  CHECK(lf_set_input(instance, &input) == LF_OK,
        "maximum input mask accepted");
  memset(video, 0xCC, sizeof(video));
  for (size_t index = 0U; index < sizeof(audio) / sizeof(audio[0]); ++index) {
    audio[index] = INT16_C(1234);
  }
  request = make_request(4U, video, 5U, 3U, audio, 9U);
  CHECK(lf_advance(instance, &request, &result) == LF_OK,
        "work four with exact touched video extent succeeds");
  CHECK(result.actual_units == 4U && result.cumulative_units == 4U &&
            result.video_extent_bytes == 5U && result.video_stride_bytes == 3U &&
            result.audio_produced_samples == 8U && result.sampled_buttons == 3U,
        "work four reports exact integer boundary metadata");
  CHECK(memcmp(video, expected_video, sizeof(expected_video)) == 0 &&
            video[5] == 0xCCU &&
            video[6] == 0xCCU && video[7] == 0xCCU,
        "stride-three row padding and trailing canaries remain unchanged");
  CHECK(memcmp(audio, expected_audio, sizeof(expected_audio)) == 0 &&
            audio[8] == INT16_C(1234) && audio[9] == INT16_C(1234),
        "maximal work produces eight independently specified audio samples");
  CHECK(lf_destroy(&instance) == LF_OK, "output boundary owner destroyed");

  CHECK(lf_create("synthetic-v1", NULL, &instance) == LF_OK,
        "exact capacity instance created");
  CHECK(lf_set_input(instance, &input) == LF_OK,
        "exact capacity input accepted");
  memset(video, 0xA5, sizeof(video));
  audio[0] = INT16_C(1234);
  audio[1] = INT16_C(1234);
  request = make_request(1U, video, 4U, 2U, audio, 2U);
  result = (lf_run_result){.struct_size = sizeof(result)};
  CHECK(lf_advance(instance, &request, &result) == LF_OK &&
            video[0] == 1U && video[1] == 4U && video[2] == 3U &&
            video[3] == 5U && audio[0] == INT16_C(64) &&
            audio[1] == -INT16_C(64),
        "exact video and audio capacities succeed");
  request.video_capacity_bytes = 5U;
  request.audio_capacity_samples = 3U;
  memset(video, 0xA5, sizeof(video));
  audio[0] = INT16_C(1234);
  audio[1] = INT16_C(1234);
  audio[2] = INT16_C(1234);
  result = (lf_run_result){.struct_size = sizeof(result)};
  CHECK(lf_advance(instance, &request, &result) == LF_OK &&
            result.actual_units == 1U && video[4] == 0xA5U &&
            audio[2] == INT16_C(1234),
        "one-byte/sample-over-capacity leaves tails host-owned");
  CHECK(lf_destroy(&instance) == LF_OK,
        "exact capacity owner destroyed");

  CHECK(lf_create("synthetic-v1", NULL, &instance) == LF_OK,
        "stride two instance created");
  CHECK(lf_set_input(instance, &input) == LF_OK,
        "stride two input accepted");
  memset(video, 0xA5, sizeof(video));
  audio[0] = INT16_C(1234);
  audio[1] = INT16_C(1234);
  request = make_request(1U, video, 5U, 2U, audio, 3U);
  result = (lf_run_result){.struct_size = sizeof(result)};
  CHECK(lf_advance(instance, &request, &result) == LF_OK &&
            result.video_extent_bytes == 4U && video[4] == 0xA5U &&
            audio[2] == INT16_C(1234),
        "packed exact extent does not write the adjacent byte or sample");
  CHECK(lf_destroy(&instance) == LF_OK, "stride two owner destroyed");
  return 1;
}

static int test_work_and_lifetime_boundaries(void) {
  lf_instance *instance = NULL;
  lf_input input = {.struct_size = sizeof(input), .buttons = 3U};
  uint8_t video[8];
  int16_t audio[8];
  lf_run_request request;
  lf_run_result result = {.struct_size = sizeof(result)};
  uint8_t before_media[4];
  uint8_t after_media[4];
  lf_media_info before_info = {.struct_size = sizeof(before_info)};
  lf_media_info after_info = {.struct_size = sizeof(after_info)};

  CHECK(lf_create("synthetic-v1", NULL, &instance) == LF_OK,
        "work boundary instance created");
  CHECK(lf_set_input(instance, &input) == LF_OK,
        "pending input set before zero work");
  memset(video, 0xA5, sizeof(video));
  for (size_t index = 0U; index < sizeof(audio) / sizeof(audio[0]); ++index) {
    audio[index] = INT16_C(1234);
  }
  request = make_request(0U, NULL, 0U, 0U, NULL, 0U);
  CHECK(lf_advance(instance, &request, &result) == LF_OK &&
            result.actual_units == 0U && result.cumulative_units == 0U &&
            result.sampled_buttons == 0U &&
            result.video_valid == 0U && result.audio_valid == 0U &&
            result.video_extent_bytes == 0U &&
            result.audio_produced_samples == 0U &&
            result.stop_reason == LF_STOP_BUDGET_REACHED &&
            video[0] == 0xA5U && audio[0] == INT16_C(1234),
        "zero work succeeds without buffers, A/V writes or progress");

  request = make_request(4U, video, 4U, 2U, audio, 8U);
  result = (lf_run_result){.struct_size = sizeof(result)};
  CHECK(lf_advance(instance, &request, &result) == LF_OK &&
            result.actual_units == 4U && result.cumulative_units == 4U &&
            result.sampled_buttons == 3U && video[0] == 4U &&
            video[1] == 16U && audio[0] == INT16_C(64),
        "one-to-four work range accepts its exact maximum");

  CHECK(lf_set_input(instance, &input) == LF_OK,
        "input set before final lifetime block");
  request = make_request(4U, video, 4U, 2U, audio, 8U);
  result = (lf_run_result){.struct_size = sizeof(result)};
  CHECK(lf_advance(instance, &request, &result) == LF_OK &&
            result.actual_units == 4U && result.cumulative_units == 8U,
        "exact eight-step lifetime boundary succeeds");
  CHECK(copy_media(instance, before_media, &before_info) &&
            before_info.guest_generation == 8U,
        "lifetime boundary exposes generation eight");

  memset(video, 0xA5, sizeof(video));
  for (size_t index = 0U; index < sizeof(audio) / sizeof(audio[0]); ++index) {
    audio[index] = INT16_C(1234);
  }
  request = make_request(1U, video, 4U, 2U, audio, 2U);
  result = (lf_run_result){.struct_size = sizeof(result)};
  CHECK(lf_advance(instance, &request, &result) == LF_LIMIT_EXCEEDED &&
            result_is_rejected(&result, 8U) && video[0] == 0xA5U &&
            audio[0] == INT16_C(1234),
        "ninth step is rejected before progress or output writes");
  CHECK(copy_media(instance, after_media, &after_info) &&
            memcmp(before_media, after_media, sizeof(before_media)) == 0 &&
            before_info.guest_generation == after_info.guest_generation,
        "ninth-step rejection preserves media and generation");

  request = make_request(0U, NULL, 0U, 0U, NULL, 0U);
  result = (lf_run_result){.struct_size = sizeof(result)};
  CHECK(lf_advance(instance, &request, &result) == LF_OK &&
            result.actual_units == 0U && result.cumulative_units == 8U &&
            result.sampled_buttons == 0U &&
            result.video_valid == 0U && result.audio_valid == 0U,
        "zero work at the lifetime boundary remains a no-op");
  CHECK(lf_destroy(&instance) == LF_OK, "work boundary owner destroyed");
  return 1;
}

static int test_media_copy_boundaries(void) {
  lf_instance *instance = NULL;
  uint8_t destination[7];
  lf_media_info info;
  lf_media_info before_info;
  const uint8_t expected[4] = {76U, 70U, 0U, 0U};

  CHECK(lf_create("synthetic-v1", NULL, &instance) == LF_OK,
        "media boundary instance created");
  memset(destination, 0xA5, sizeof(destination));
  memset(&info, 0xB6, sizeof(info));
  info.struct_size = sizeof(info);
  CHECK(lf_copy_media(instance, destination, 3U, &info) ==
            LF_BUFFER_TOO_SMALL,
        "three-byte media destination is rejected");
  CHECK(destination[0] == 0xA5U && destination[6] == 0xA5U,
        "short media destination remains untouched");

  memset(destination, 0xA5, sizeof(destination));
  info = (lf_media_info){.struct_size = sizeof(info)};
  CHECK(lf_copy_media(instance, destination, 4U, &info) == LF_OK &&
            memcmp(destination, expected, sizeof(expected)) == 0 &&
            destination[4] == 0xA5U && destination[6] == 0xA5U &&
            info.extent_bytes == 4U && info.guest_generation == 0U,
        "exact four-byte media copy succeeds without adjacent writes");

  memset(destination, 0xA5, sizeof(destination));
  info = (lf_media_info){.struct_size = sizeof(info)};
  CHECK(lf_copy_media(instance, destination, 5U, &info) == LF_OK &&
            memcmp(destination, expected, sizeof(expected)) == 0 &&
            destination[4] == 0xA5U,
        "five-byte media capacity preserves its extra byte");

  before_info = (lf_media_info){.struct_size = sizeof(before_info)};
  memset(destination, 0xA5, sizeof(destination));
  memset(&info, 0xB6, sizeof(info));
  info.struct_size = sizeof(info) - 1U;
  memcpy(&before_info, &info, sizeof(info));
  CHECK(lf_copy_media(instance, destination, 5U, &info) ==
            LF_INVALID_ARGUMENT &&
            memcmp(&before_info, &info, sizeof(info)) == 0 &&
            destination[0] == 0xA5U && destination[6] == 0xA5U,
        "short media-info record rejects without touching record or buffer");
  CHECK(lf_destroy(&instance) == LF_OK, "media boundary owner destroyed");
  return 1;
}

static int test_other_record_boundaries(void) {
  lf_profile profile;
  lf_profile profile_before;
  lf_instance *instance = NULL;
  lf_create_options options;
  allocation_tracker tracker = {0};
  lf_instance *sentinel_owner = NULL;
  uint8_t destination[5];
  lf_media_info media_info;
  lf_media_info media_before;

  memset(&profile, 0xB4, sizeof(profile));
  profile.struct_size = sizeof(profile) - 1U;
  memcpy(&profile_before, &profile, sizeof(profile));
  CHECK(lf_get_profile("synthetic-v1", NULL, &profile) == LF_INVALID_ARGUMENT &&
            memcmp(&profile, &profile_before, sizeof(profile)) == 0,
        "undersized profile record remains untouched");
  profile.struct_size = sizeof(profile) + 1U;
  memcpy(&profile_before, &profile, sizeof(profile));
  CHECK(lf_get_profile("synthetic-v1", NULL, &profile) == LF_INVALID_ARGUMENT &&
            memcmp(&profile, &profile_before, sizeof(profile)) == 0,
        "oversized profile record remains untouched");

  options = tracked_options(&tracker);
  options.struct_size -= 1U;
  CHECK(lf_create("synthetic-v1", NULL, &sentinel_owner) == LF_OK,
        "record boundary sentinel owner created");
  instance = sentinel_owner;
  CHECK(lf_create("synthetic-v1", &options, &instance) ==
            LF_INVALID_ARGUMENT && instance == NULL && tracker.calls == 0U,
        "undersized create-options record rejects before allocation");
  options.struct_size += 2U;
  instance = sentinel_owner;
  CHECK(lf_create("synthetic-v1", &options, &instance) ==
            LF_INVALID_ARGUMENT && instance == NULL && tracker.calls == 0U,
        "oversized create-options record rejects before allocation");

  CHECK(lf_create("synthetic-v1", NULL, &instance) == LF_OK,
        "record boundary instance created");
  memset(destination, 0xA5, sizeof(destination));
  memset(&media_info, 0xB6, sizeof(media_info));
  media_info.struct_size = sizeof(media_info) + 1U;
  memcpy(&media_before, &media_info, sizeof(media_info));
  CHECK(lf_copy_media(instance, destination, sizeof(destination), &media_info) ==
            LF_INVALID_ARGUMENT &&
            memcmp(&media_info, &media_before, sizeof(media_info)) == 0 &&
            destination[0] == 0xA5U && destination[4] == 0xA5U,
        "oversized media-info record rejects untouched");
  CHECK(lf_destroy(&instance) == LF_OK,
        "record boundary owner destroyed");
  CHECK(lf_destroy(&sentinel_owner) == LF_OK && sentinel_owner == NULL,
        "record boundary sentinel owner remains valid");
  return 1;
}

static int test_input_rejections(void) {
  CHECK(run_input_rejection_case(0, 0, "undersized input record"),
        "undersized input record preserves state");
  CHECK(run_input_rejection_case(1, 0, "oversized input record"),
        "oversized input record preserves state");
  CHECK(run_input_rejection_case(0, 1, "unknown input mask"),
        "unknown input mask preserves state");
  return 1;
}

static int test_advance_rejections(void) {
  CHECK(run_advance_rejection_case(REJECT_NULL_REQUEST, "null request",
                                   LF_INVALID_ARGUMENT),
        "null request is failure-atomic");
  CHECK(run_advance_rejection_case(REJECT_SHORT_REQUEST_RECORD,
                                   "undersized request record",
                                   LF_INVALID_ARGUMENT),
        "undersized request is failure-atomic");
  CHECK(run_advance_rejection_case(REJECT_LARGE_REQUEST_RECORD,
                                   "oversized request record",
                                   LF_INVALID_ARGUMENT),
        "oversized request is failure-atomic");
  CHECK(run_advance_rejection_case(REJECT_OVER_LIMIT_WORK,
                                   "work over per-call limit",
                                   LF_LIMIT_EXCEEDED),
        "over-limit work is failure-atomic");
  CHECK(run_advance_rejection_case(REJECT_SHORT_STRIDE, "stride below width",
                                   LF_INVALID_ARGUMENT),
        "short stride is failure-atomic");
  CHECK(run_advance_rejection_case(REJECT_OVERFLOWING_STRIDE,
                                   "overflowing video stride",
                                   LF_LIMIT_EXCEEDED),
        "overflowing stride is failure-atomic");
  CHECK(run_advance_rejection_case(REJECT_ZERO_VIDEO_CAPACITY,
                                   "zero video capacity",
                                   LF_BUFFER_TOO_SMALL),
        "zero video capacity is failure-atomic");
  CHECK(run_advance_rejection_case(REJECT_SHORT_VIDEO_CAPACITY,
                                   "short video capacity",
                                   LF_BUFFER_TOO_SMALL),
        "short video capacity is failure-atomic");
  CHECK(run_advance_rejection_case(REJECT_ZERO_AUDIO_CAPACITY,
                                   "zero audio capacity",
                                   LF_BUFFER_TOO_SMALL),
        "zero audio capacity is failure-atomic");
  CHECK(run_advance_rejection_case(REJECT_SHORT_AUDIO_CAPACITY,
                                   "short audio capacity",
                                   LF_BUFFER_TOO_SMALL),
        "short audio capacity is failure-atomic");
  CHECK(run_advance_rejection_case(REJECT_SHORT_PADDED_VIDEO_CAPACITY,
                                   "one-under padded video extent",
                                   LF_BUFFER_TOO_SMALL),
        "one-under padded video extent is failure-atomic");
  CHECK(run_advance_rejection_case(REJECT_FOUR_WORK_ONE_STEP_AUDIO,
                                   "four work units with one-step audio capacity",
                                   LF_BUFFER_TOO_SMALL),
        "bounded audio pressure is failure-atomic");
  return test_result_record_rejection();
}

static int test_adjacent_output_spans(void) {
  struct {
    int16_t audio[2];
    uint8_t video[4];
    uint8_t guard[2];
  } buffers;
  lf_instance *instance = NULL;
  lf_run_result result = {.struct_size = sizeof(result)};
  lf_run_request request = make_request(1U, buffers.video, 4U, 2U,
                                       buffers.audio, 2U);
  const uint8_t expected_video[4] = {1U, 1U, 0U, 2U};
  int passed = 0;

  memset(&buffers, 0x5a, sizeof(buffers));
  CHECK_GOTO((uint8_t *)buffers.audio + sizeof(buffers.audio) == buffers.video,
             "output spans are exactly adjacent");
  CHECK_GOTO(lf_create("synthetic-v1", NULL, &instance) == LF_OK,
             "adjacent output create");
  CHECK_GOTO(lf_advance(instance, &request, &result) == LF_OK,
             "adjacent disjoint output spans are accepted");
  CHECK_GOTO(result.video_valid && result.audio_valid &&
                 result.video_extent_bytes == 4U &&
                 result.audio_produced_samples == 2U &&
                 buffers.audio[0] == 16 && buffers.audio[1] == -16 &&
                 memcmp(buffers.video, expected_video, 4U) == 0 &&
                 buffers.guard[0] == 0x5a && buffers.guard[1] == 0x5a,
             "adjacent spans retain independent literal audio and video");
  passed = 1;
cleanup:
  (void)lf_destroy(&instance);
  return passed;
}

int main(void) {
  if (!test_allocator_lifecycle()) {
    return 1;
  }
  if (!test_sequential_instance_independence()) {
    return 1;
  }
  if (!test_capability_and_synthetic_load_boundaries()) {
    return 1;
  }
  if (!test_synthetic_media_import_timing()) {
    return 1;
  }
  if (!test_create_failure_peer_independence()) {
    return 1;
  }
  if (!test_input_rejections()) {
    return 1;
  }
  if (!test_advance_rejections()) {
    return 1;
  }
  if (!test_valid_output_boundaries()) {
    return 1;
  }
  if (!test_adjacent_output_spans()) {
    return 1;
  }
  if (!test_work_and_lifetime_boundaries()) {
    return 1;
  }
  if (!test_media_copy_boundaries()) {
    return 1;
  }
  if (!test_other_record_boundaries()) {
    return 1;
  }
  (void)puts("synthetic_boundaries: lifecycle and public boundary cases passed");
  return 0;
}
