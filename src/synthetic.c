#include <libfuturo/libfuturo.h>

#include <stdlib.h>
#include <string.h>

#ifndef LF_BUILD_ID
#define LF_BUILD_ID "unversioned"
#endif

#define LF_SYNTHETIC_MAX_WORK_UNITS 4U
#define LF_SYNTHETIC_MAX_GUEST_UNITS 8U
#define LF_SYNTHETIC_INPUT_MASK 3U
#define LF_SYNTHETIC_VIDEO_WIDTH 2U
#define LF_SYNTHETIC_VIDEO_HEIGHT 2U
#define LF_SYNTHETIC_AUDIO_SAMPLES_PER_STEP 2U
#define LF_SYNTHETIC_AUDIO_RATE_NUMERATOR 8000U
#define LF_SYNTHETIC_AUDIO_RATE_DENOMINATOR 1U
#define LF_SYNTHETIC_MEDIA_EXTENT 4U

static const char k_profile_id[] = "synthetic-v1";
static const char k_core_id[] = "synthetic";
static const char k_media_identity[] = "synthetic-media-v1";

struct lf_instance {
  uint64_t cumulative_units;
  uint32_t accumulator;
  uint32_t pending_buttons;
  uint8_t *media;
  uint64_t media_generation;
  lf_deallocate_fn deallocate;
  void *allocator_context;
};

static void *default_allocate(void *context, size_t bytes) {
  (void)context;
  return malloc(bytes);
}

static void default_deallocate(void *context, void *allocation) {
  (void)context;
  free(allocation);
}

static int is_synthetic_profile(const char *profile_id) {
  return profile_id != NULL && strcmp(profile_id, k_profile_id) == 0;
}

static void fill_profile(lf_profile *out) {
  *out = (lf_profile){
      .struct_size = sizeof(*out),
      .profile_id = k_profile_id,
      .core_id = k_core_id,
      .build_id = LF_BUILD_ID,
      .api_revision = 1U,
      .behavior_revision = 1U,
      .input_mask = LF_SYNTHETIC_INPUT_MASK,
      .max_work_units = LF_SYNTHETIC_MAX_WORK_UNITS,
      .max_guest_units = LF_SYNTHETIC_MAX_GUEST_UNITS,
      .atomic_quantum_units = 1U,
      .max_overshoot_units = 0U,
      .time_unit = LF_TIME_SYNTHETIC_STEP,
      .input_sampling = LF_INPUT_AT_ADVANCE_START,
      .video_format = LF_VIDEO_GRAY8,
      .audio_encoding = LF_AUDIO_S16_NATIVE,
      .audio_layout = LF_AUDIO_INTERLEAVED,
      .video_width = LF_SYNTHETIC_VIDEO_WIDTH,
      .video_height = LF_SYNTHETIC_VIDEO_HEIGHT,
      .video_bytes_per_pixel = 1U,
      .audio_rate_numerator = LF_SYNTHETIC_AUDIO_RATE_NUMERATOR,
      .audio_rate_denominator = LF_SYNTHETIC_AUDIO_RATE_DENOMINATOR,
      .audio_channels = 1U,
      .min_video_stride_bytes = LF_SYNTHETIC_VIDEO_WIDTH,
      .max_audio_samples_per_call =
          LF_SYNTHETIC_MAX_WORK_UNITS * LF_SYNTHETIC_AUDIO_SAMPLES_PER_STEP,
      .media_extent_bytes = LF_SYNTHETIC_MEDIA_EXTENT,
  };
}

static void fill_run_metadata(lf_run_result *out) {
  out->time_unit = LF_TIME_SYNTHETIC_STEP;
  out->video_format = LF_VIDEO_GRAY8;
  out->audio_encoding = LF_AUDIO_S16_NATIVE;
  out->audio_layout = LF_AUDIO_INTERLEAVED;
  out->video_width = LF_SYNTHETIC_VIDEO_WIDTH;
  out->video_height = LF_SYNTHETIC_VIDEO_HEIGHT;
  out->audio_rate_numerator = LF_SYNTHETIC_AUDIO_RATE_NUMERATOR;
  out->audio_rate_denominator = LF_SYNTHETIC_AUDIO_RATE_DENOMINATOR;
  out->audio_channels = 1U;
}

static int checked_video_extent(size_t stride, size_t *extent) {
  const size_t rows_before_last = (size_t)LF_SYNTHETIC_VIDEO_HEIGHT - 1U;
  const size_t width = (size_t)LF_SYNTHETIC_VIDEO_WIDTH;
  size_t row_offset = 0U;

  if (rows_before_last != 0U && stride > SIZE_MAX / rows_before_last) {
    return 0;
  }
  row_offset = rows_before_last * stride;
  if (width > SIZE_MAX - row_offset) {
    return 0;
  }
  *extent = row_offset + width;
  return 1;
}

lf_status lf_get_profile(const char *profile_id, lf_profile *out) {
  if (out == NULL) {
    return LF_INVALID_ARGUMENT;
  }
  if (out->struct_size != sizeof(*out)) {
    return LF_INVALID_ARGUMENT;
  }
  *out = (lf_profile){.struct_size = sizeof(*out)};
  if (!is_synthetic_profile(profile_id)) {
    return LF_INVALID_ARGUMENT;
  }
  fill_profile(out);
  return LF_OK;
}

lf_status lf_get_capability(const char *profile_id, lf_capability capability,
                            uint32_t *supported) {
  if (supported == NULL) {
    return LF_INVALID_ARGUMENT;
  }
  *supported = 0U;
  if (!is_synthetic_profile(profile_id)) {
    return LF_INVALID_ARGUMENT;
  }

  switch (capability) {
    case LF_CAP_LOGICAL_INPUT:
    case LF_CAP_BOUNDED_EXECUTION:
    case LF_CAP_SOFTWARE_VIDEO:
    case LF_CAP_AUDIO:
    case LF_CAP_IN_MEMORY_MEDIA_COPY:
      *supported = 1U;
      return LF_OK;
    case LF_CAP_SNAPSHOT:
    case LF_CAP_HARDWARE_VIDEO:
    case LF_CAP_CONCURRENT_USE:
      return LF_UNSUPPORTED;
  }
  return LF_INVALID_ARGUMENT;
}

lf_status lf_create(const char *profile_id, const lf_create_options *options,
                    lf_instance **out) {
  lf_allocate_fn allocate = default_allocate;
  lf_deallocate_fn deallocate = default_deallocate;
  void *allocator_context = NULL;
  lf_instance *instance = NULL;
  uint8_t *media = NULL;

  if (out == NULL) {
    return LF_INVALID_ARGUMENT;
  }
  *out = NULL;
  if (!is_synthetic_profile(profile_id)) {
    return LF_INVALID_ARGUMENT;
  }
  if (options != NULL) {
    if (options->struct_size != sizeof(*options)) {
      return LF_INVALID_ARGUMENT;
    }
    if ((options->allocate == NULL) != (options->deallocate == NULL)) {
      return LF_INVALID_ARGUMENT;
    }
    if (options->allocate != NULL) {
      allocate = options->allocate;
      deallocate = options->deallocate;
      allocator_context = options->allocator_context;
    }
  }

  instance = allocate(allocator_context, sizeof(*instance));
  if (instance == NULL) {
    return LF_RESOURCE_EXHAUSTED;
  }
  memset(instance, 0, sizeof(*instance));
  instance->deallocate = deallocate;
  instance->allocator_context = allocator_context;

  media = allocate(allocator_context, LF_SYNTHETIC_MEDIA_EXTENT);
  if (media == NULL) {
    deallocate(allocator_context, instance);
    return LF_RESOURCE_EXHAUSTED;
  }
  media[0] = 76U;
  media[1] = 70U;
  media[2] = 0U;
  media[3] = 0U;
  instance->media = media;
  *out = instance;
  return LF_OK;
}

lf_status lf_destroy(lf_instance **owned) {
  lf_instance *instance = NULL;
  lf_deallocate_fn deallocate = NULL;
  void *allocator_context = NULL;

  if (owned == NULL) {
    return LF_INVALID_ARGUMENT;
  }
  instance = *owned;
  if (instance == NULL) {
    return LF_OK;
  }

  *owned = NULL;
  deallocate = instance->deallocate;
  allocator_context = instance->allocator_context;
  deallocate(allocator_context, instance->media);
  deallocate(allocator_context, instance);
  return LF_OK;
}

lf_status lf_set_input(lf_instance *instance, const lf_input *input) {
  if (instance == NULL || input == NULL) {
    return LF_INVALID_ARGUMENT;
  }
  if (input->struct_size != sizeof(*input)) {
    return LF_INVALID_ARGUMENT;
  }
  if ((input->buttons & ~LF_SYNTHETIC_INPUT_MASK) != 0U) {
    return LF_INVALID_ARGUMENT;
  }
  instance->pending_buttons = input->buttons;
  return LF_OK;
}

lf_status lf_advance(lf_instance *instance, const lf_run_request *request,
                     lf_run_result *out) {
  size_t video_extent = 0U;
  size_t audio_samples = 0U;
  uint32_t work_units = 0U;
  uint32_t sampled_buttons = 0U;
  uint32_t step_index = 0U;

  if (out == NULL) {
    return LF_INVALID_ARGUMENT;
  }
  if (out->struct_size != sizeof(*out)) {
    return LF_INVALID_ARGUMENT;
  }
  *out = (lf_run_result){
      .struct_size = sizeof(*out),
      .stop_reason = LF_STOP_REJECTED,
  };
  fill_run_metadata(out);

  if (instance == NULL) {
    return LF_INVALID_ARGUMENT;
  }
  out->cumulative_units = instance->cumulative_units;
  if (request == NULL) {
    return LF_INVALID_ARGUMENT;
  }
  if (request->struct_size != sizeof(*request)) {
    return LF_INVALID_ARGUMENT;
  }

  work_units = request->work_units;
  out->requested_units = work_units;
  out->video_stride_bytes = request->video_stride_bytes;
  if (work_units == 0U) {
    out->stop_reason = LF_STOP_BUDGET_REACHED;
    return LF_OK;
  }

  if (request->video_data == NULL || request->audio_data == NULL ||
      request->video_stride_bytes < LF_SYNTHETIC_VIDEO_WIDTH) {
    return LF_INVALID_ARGUMENT;
  }
  if (!checked_video_extent(request->video_stride_bytes, &video_extent)) {
    return LF_LIMIT_EXCEEDED;
  }
  if ((size_t)work_units > SIZE_MAX / LF_SYNTHETIC_AUDIO_SAMPLES_PER_STEP) {
    return LF_LIMIT_EXCEEDED;
  }
  audio_samples = (size_t)work_units * LF_SYNTHETIC_AUDIO_SAMPLES_PER_STEP;

  if (work_units > LF_SYNTHETIC_MAX_WORK_UNITS ||
      instance->cumulative_units > LF_SYNTHETIC_MAX_GUEST_UNITS ||
      (uint64_t)work_units >
          (uint64_t)LF_SYNTHETIC_MAX_GUEST_UNITS - instance->cumulative_units) {
    return LF_LIMIT_EXCEEDED;
  }
  if (request->video_capacity_bytes < video_extent ||
      request->audio_capacity_samples < audio_samples) {
    return LF_BUFFER_TOO_SMALL;
  }

  sampled_buttons = instance->pending_buttons;
  for (step_index = 0U; step_index < work_units; ++step_index) {
    size_t audio_index = (size_t)step_index * 2U;
    instance->cumulative_units += 1U;
    instance->accumulator += sampled_buttons + 1U;
    request->audio_data[audio_index] = (int16_t)(instance->accumulator * 16U);
    request->audio_data[audio_index + 1U] =
        (int16_t)-(int32_t)(instance->accumulator * 16U);
  }

  {
    const size_t second_row = request->video_stride_bytes;
    const uint8_t final_step = (uint8_t)instance->cumulative_units;
    const uint8_t final_accumulator = (uint8_t)instance->accumulator;
    request->video_data[0] = final_step;
    request->video_data[1] = final_accumulator;
    request->video_data[second_row] = (uint8_t)sampled_buttons;
    request->video_data[second_row + 1U] =
        (uint8_t)(instance->cumulative_units + instance->accumulator);
  }

  instance->media[0] = 76U;
  instance->media[1] = 70U;
  instance->media[2] = (uint8_t)instance->cumulative_units;
  instance->media[3] = (uint8_t)instance->accumulator;
  instance->media_generation = instance->cumulative_units;

  out->requested_units = work_units;
  out->actual_units = work_units;
  out->overshoot_units = 0U;
  out->sampled_buttons = sampled_buttons;
  out->video_valid = 1U;
  out->audio_valid = 1U;
  out->cumulative_units = instance->cumulative_units;
  out->stop_reason = LF_STOP_BUDGET_REACHED;
  out->video_stride_bytes = request->video_stride_bytes;
  out->video_extent_bytes = video_extent;
  out->audio_produced_samples = audio_samples;
  return LF_OK;
}

lf_status lf_copy_media(lf_instance *instance, uint8_t *destination,
                        size_t capacity_bytes, lf_media_info *out) {
  if (out == NULL) {
    return LF_INVALID_ARGUMENT;
  }
  if (out->struct_size != sizeof(*out)) {
    return LF_INVALID_ARGUMENT;
  }
  if (instance == NULL || destination == NULL) {
    return LF_INVALID_ARGUMENT;
  }
  if (capacity_bytes < LF_SYNTHETIC_MEDIA_EXTENT) {
    return LF_BUFFER_TOO_SMALL;
  }

  memcpy(destination, instance->media, LF_SYNTHETIC_MEDIA_EXTENT);
  *out = (lf_media_info){
      .struct_size = sizeof(*out),
      .identity = k_media_identity,
      .extent_bytes = LF_SYNTHETIC_MEDIA_EXTENT,
      .guest_generation = instance->media_generation,
  };
  return LF_OK;
}
