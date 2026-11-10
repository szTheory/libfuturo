#include "libfuturo_internal.h"

#include "installed-consumer/muhtari_fixture.h"
#include "installed-consumer/muhtari_oracle.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void lf_muhtari_test_seed_progress(lf_muhtari_state *state, uint64_t frames);

#define VIDEO_WIDTH 320U
#define VIDEO_HEIGHT 242U
#define VIDEO_STRIDE 323U
#define VIDEO_BYTES (VIDEO_STRIDE * VIDEO_HEIGHT + 7U)
#define AUDIO_SAMPLES 805U
#define VIDEO_SENTINEL UINT8_C(0xA5)
#define AUDIO_SENTINEL INT16_C(0x5A5A)
#define ALLOCATION_SLOTS 256U

typedef struct allocation_tracker {
  size_t calls;
  size_t fail_at;
  size_t successful;
  size_t failed;
  size_t frees;
  size_t live_count;
  size_t invalid_frees;
  void *live[ALLOCATION_SLOTS];
} allocation_tracker;

static void *tracked_allocate(void *context, size_t bytes) {
  allocation_tracker *tracker = (allocation_tracker *)context;
  void *allocation = NULL;
  if (tracker == NULL) {
    return NULL;
  }
  tracker->calls += 1U;
  if (tracker->fail_at == tracker->calls) {
    tracker->failed += 1U;
    return NULL;
  }
  allocation = malloc(bytes);
  if (allocation == NULL) {
    return NULL;
  }
  for (size_t index = 0U; index < ALLOCATION_SLOTS; ++index) {
    if (tracker->live[index] == NULL) {
      tracker->live[index] = allocation;
      tracker->live_count += 1U;
      tracker->successful += 1U;
      return allocation;
    }
  }
  free(allocation);
  return NULL;
}

static void tracked_deallocate(void *context, void *allocation) {
  allocation_tracker *tracker = (allocation_tracker *)context;
  if (tracker == NULL || allocation == NULL) {
    return;
  }
  for (size_t index = 0U; index < ALLOCATION_SLOTS; ++index) {
    if (tracker->live[index] == allocation) {
      tracker->live[index] = NULL;
      tracker->live_count -= 1U;
      tracker->frees += 1U;
      free(allocation);
      return;
    }
  }
  tracker->invalid_frees += 1U;
}

static int tracker_is_balanced(const allocation_tracker *tracker) {
  return tracker != NULL && tracker->live_count == 0U &&
         tracker->successful == tracker->frees &&
         tracker->invalid_frees == 0U;
}

static lf_run_request make_request(uint32_t work_units, uint8_t *video,
                                   int16_t *audio) {
  return (lf_run_request){
      .struct_size = sizeof(lf_run_request),
      .work_units = work_units,
      .video_data = video,
      .video_capacity_bytes = sizeof(uint8_t) * VIDEO_BYTES,
      .video_stride_bytes = VIDEO_STRIDE,
      .audio_data = audio,
      .audio_capacity_samples = AUDIO_SAMPLES,
  };
}

static int image_padding_is_untouched(const uint8_t *video) {
  for (size_t row = 0U; row < (size_t)VIDEO_HEIGHT; ++row) {
    for (size_t column = (size_t)VIDEO_WIDTH; column < (size_t)VIDEO_STRIDE;
         ++column) {
      if (video[row * (size_t)VIDEO_STRIDE + column] != VIDEO_SENTINEL) {
        return 0;
      }
    }
  }
  for (size_t index = (size_t)VIDEO_STRIDE * (size_t)VIDEO_HEIGHT;
       index < (size_t)VIDEO_BYTES; ++index) {
    if (video[index] != VIDEO_SENTINEL) {
      return 0;
    }
  }
  return 1;
}

static int audio_tail_is_untouched(const int16_t *audio, size_t produced) {
  for (size_t index = produced; index < (size_t)AUDIO_SAMPLES; ++index) {
    if (audio[index] != AUDIO_SENTINEL) {
      return 0;
    }
  }
  return 1;
}

static void reset_outputs(uint8_t *video, int16_t *audio) {
  memset(video, VIDEO_SENTINEL, (size_t)VIDEO_BYTES);
  for (size_t index = 0U; index < (size_t)AUDIO_SAMPLES; ++index) {
    audio[index] = AUDIO_SENTINEL;
  }
}

static int create_failure_ordinals(size_t *out_count) {
  allocation_tracker baseline = {0};
  lf_muhtari_state *state = NULL;
  size_t allocation_count = 0U;
  if (out_count == NULL ||
      lf_muhtari_create(tracked_allocate, tracked_deallocate, &baseline,
                        &state) != LF_OK ||
      state == NULL) {
    return 0;
  }
  allocation_count = baseline.calls;
  lf_muhtari_destroy(&state);
  if (state != NULL || !tracker_is_balanced(&baseline) ||
      allocation_count == 0U || allocation_count >= ALLOCATION_SLOTS) {
    return 0;
  }

  for (size_t ordinal = 1U; ordinal <= allocation_count; ++ordinal) {
    allocation_tracker tracker = {0};
    lf_muhtari_state *failed_state = NULL;
    tracker.fail_at = ordinal;
    if (lf_muhtari_create(tracked_allocate, tracked_deallocate, &tracker,
                          &failed_state) != LF_RESOURCE_EXHAUSTED ||
        failed_state != NULL || tracker.calls != ordinal ||
        tracker.failed != 1U || !tracker_is_balanced(&tracker)) {
      (void)fprintf(stderr,
                    "muhtari_guest_limit: creation allocation ordinal=%zu did not clean up\n",
                    ordinal);
      return 0;
    }
  }
  *out_count = allocation_count;
  return 1;
}

static int loaded_state_create(allocation_tracker *tracker,
                               lf_muhtari_state **state,
                               uint8_t content[LF_MUHTARI_FIXTURE_TOTAL_BYTES]) {
  const size_t content_bytes =
      lf_build_muhtari_fixture(content, LF_MUHTARI_FIXTURE_TOTAL_BYTES);
  lf_load_result loaded = {.struct_size = sizeof(loaded)};
  const lf_load_request request = {
      .struct_size = sizeof(request),
      .content_data = content,
      .content_size_bytes = content_bytes,
  };
  return content_bytes == LF_MUHTARI_FIXTURE_TOTAL_BYTES &&
         lf_muhtari_create(tracked_allocate, tracked_deallocate, tracker,
                           state) == LF_OK &&
         *state != NULL && lf_muhtari_load(*state, &request, &loaded) == LF_OK &&
         loaded.loaded == 1U && loaded.content_size_bytes == content_bytes &&
         loaded.effective_configuration_id != NULL &&
         strcmp(loaded.effective_configuration_id,
                "muhtari-ntsc-joystick-default") == 0;
}

static int verify_first_interval(const uint8_t *video, const int16_t *audio,
                                 const lf_run_result *result) {
  char actual_pcm[65];
  return result->struct_size == sizeof(*result) &&
         result->actual_units == 1U &&
         result->sampled_buttons == UINT32_C(0x0100) &&
         result->cumulative_units == (uint64_t)UINT32_MAX &&
         result->video_valid == 1U && result->audio_valid == 1U &&
         result->audio_produced_samples ==
             LF_MUHTARI_ORACLE_FIRST_FRAME_SAMPLES &&
         lf_muhtari_oracle_first_image(
             video, (size_t)VIDEO_STRIDE,
             LF_MUHTARI_ORACLE_PORT1_FIRE_COLOR) &&
         lf_muhtari_oracle_pcm_matches(
             audio, LF_MUHTARI_ORACLE_FIRST_FRAME_SAMPLES, 0U, actual_pcm) &&
         image_padding_is_untouched(video) &&
         audio_tail_is_untouched(audio,
                                 LF_MUHTARI_ORACLE_FIRST_FRAME_SAMPLES);
}

static int verify_continuation_interval(const uint8_t *video,
                                        const int16_t *audio,
                                        const lf_run_result *result) {
  char actual_pcm[65];
  return result->struct_size == sizeof(*result) &&
         result->actual_units == 1U &&
         result->sampled_buttons == UINT32_C(0x0101) &&
         result->cumulative_units == 2U && result->video_valid == 1U &&
         result->audio_valid == 1U &&
         result->audio_produced_samples ==
             LF_MUHTARI_ORACLE_STEADY_FRAME_SAMPLES &&
         lf_muhtari_oracle_steady_image(
             video, (size_t)VIDEO_STRIDE,
             LF_MUHTARI_ORACLE_BOTH_FIRE_COLOR) &&
         lf_muhtari_oracle_pcm_matches(
             audio, LF_MUHTARI_ORACLE_STEADY_FRAME_SAMPLES, 1U, actual_pcm) &&
         image_padding_is_untouched(video) &&
         audio_tail_is_untouched(audio,
                                 LF_MUHTARI_ORACLE_STEADY_FRAME_SAMPLES);
}

static int test_cumulative_limit(size_t *out_create_allocations) {
  allocation_tracker tracker = {0};
  lf_muhtari_state *state = NULL;
  uint8_t content[LF_MUHTARI_FIXTURE_TOTAL_BYTES];
  uint8_t video[VIDEO_BYTES];
  uint8_t video_before[VIDEO_BYTES];
  int16_t audio[AUDIO_SAMPLES];
  int16_t audio_before[AUDIO_SAMPLES];
  lf_run_result result = {.struct_size = sizeof(result)};
  lf_run_request request;
  lf_input input = {.struct_size = sizeof(input), .buttons = UINT32_C(0x0100)};
  size_t calls_before_advance = 0U;
  int ok = 0;

  if (!loaded_state_create(&tracker, &state, content)) {
    goto cleanup;
  }
  if (lf_muhtari_set_input(state, &input) != LF_OK) {
    goto cleanup;
  }
  lf_muhtari_test_seed_progress(state, (uint64_t)UINT32_MAX - 1U);
  reset_outputs(video, audio);
  request = make_request(1U, video, audio);
  calls_before_advance = tracker.calls;
  if (lf_muhtari_advance(state, &request, &result) != LF_OK ||
      tracker.calls != calls_before_advance ||
      !verify_first_interval(video, audio, &result)) {
    (void)fprintf(stderr,
                  "muhtari_guest_limit: final allowed native interval did not reach UINT32_MAX\n");
    goto cleanup;
  }

  input.buttons = UINT32_C(0x0101);
  if (lf_muhtari_set_input(state, &input) != LF_OK) {
    goto cleanup;
  }
  reset_outputs(video, audio);
  memcpy(video_before, video, sizeof(video));
  memcpy(audio_before, audio, sizeof(audio));
  result = (lf_run_result){.struct_size = sizeof(result)};
  calls_before_advance = tracker.calls;
  if (lf_muhtari_advance(state, &request, &result) != LF_LIMIT_EXCEEDED ||
      tracker.calls != calls_before_advance ||
      result.cumulative_units != (uint64_t)UINT32_MAX ||
      result.actual_units != 0U || result.video_valid != 0U ||
      result.audio_valid != 0U || result.video_extent_bytes != 0U ||
      result.audio_produced_samples != 0U ||
      result.stop_reason != LF_STOP_REJECTED ||
      memcmp(video, video_before, sizeof(video)) != 0 ||
      memcmp(audio, audio_before, sizeof(audio)) != 0) {
    (void)fprintf(stderr,
                  "muhtari_guest_limit: one-over request changed state/output\n");
    goto cleanup;
  }

  request = make_request(0U, NULL, NULL);
  result = (lf_run_result){.struct_size = sizeof(result)};
  calls_before_advance = tracker.calls;
  if (lf_muhtari_advance(state, &request, &result) != LF_OK ||
      tracker.calls != calls_before_advance ||
      result.cumulative_units != (uint64_t)UINT32_MAX ||
      result.actual_units != 0U || result.video_valid != 0U ||
      result.audio_valid != 0U ||
      result.stop_reason != LF_STOP_BUDGET_REACHED) {
    (void)fprintf(stderr,
                  "muhtari_guest_limit: zero-work request changed limit state\n");
    goto cleanup;
  }

  /* Rewind only the private reported counter to the one interval the pinned
     native core actually executed; then compare its next interval to the
     separately recorded oracle. */
  lf_muhtari_test_seed_progress(state, 1U);
  reset_outputs(video, audio);
  request = make_request(1U, video, audio);
  result = (lf_run_result){.struct_size = sizeof(result)};
  calls_before_advance = tracker.calls;
  if (lf_muhtari_advance(state, &request, &result) != LF_OK ||
      tracker.calls != calls_before_advance ||
      !verify_continuation_interval(video, audio, &result)) {
    (void)fprintf(stderr,
                  "muhtari_guest_limit: native continuation after refusal diverged\n");
    goto cleanup;
  }
  *out_create_allocations = tracker.calls;
  ok = 1;
cleanup:
  lf_muhtari_destroy(&state);
  if (state != NULL || !tracker_is_balanced(&tracker)) {
    ok = 0;
  }
  return ok;
}

int main(void) {
  size_t allocation_count = 0U;
  size_t create_failure_count = 0U;
  if (!create_failure_ordinals(&create_failure_count) ||
      !test_cumulative_limit(&allocation_count)) {
    return 1;
  }
  (void)printf("muhtari_guest_limit: cumulative=UINT32_MAX exact one-over=rejected "
               "zero-work=noop next-native-interval=oracle-match "
               "allocation-free-advances=4 create-failure-ordinals=complete "
               "setup-allocations=measured result=pass "
               "(creation-ordinals=%zu setup=%zu)\n",
               create_failure_count, allocation_count);
  return 0;
}
