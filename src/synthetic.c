#include <libfuturo/libfuturo.h>

#include "libfuturo_internal.h"

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

static const uint8_t k_synthetic_import_test_content[] = {'L', 'F', 'T', '1'};
static const char k_synthetic_profile_id[] = "synthetic-v1";
static const char k_synthetic_core_id[] = "synthetic";
static const char k_synthetic_media_identity[] = "synthetic-media-v1";
static const char k_synthetic_configuration_id[] = "synthetic-default";
#if !defined(LF_WEB_BUILD)
static const char k_nesturbator_profile_id[] = "nesturbator-ntsc-v1";
#endif
#if defined(LF_HAS_MUHTARI)
#if LF_MUHTARI_API_REVISION == 8
static const char k_muhtari_profile_id[] = "muhtari-ntsc-v2";
#else
static const char k_muhtari_profile_id[] = "muhtari-ntsc-v1";
#endif
#endif

typedef enum lf_owner_kind {
  LF_OWNER_SYNTHETIC = 1,
#if !defined(LF_WEB_BUILD)
  LF_OWNER_NESTURBATOR = 2,
#endif
  LF_OWNER_MUHTARI = 3
} lf_owner_kind;

struct lf_instance {
  lf_owner_kind owner_kind;
  uint64_t cumulative_units;
  uint32_t accumulator;
  uint32_t pending_buttons;
  uint8_t *media;
  uint64_t media_generation;
  int synthetic_content_loaded;
  int synthetic_positive_advance_started;
  lf_allocate_fn allocate;
  lf_deallocate_fn deallocate;
  void *allocator_context;
#if !defined(LF_WEB_BUILD)
  lf_nesturbator_state *nesturbator;
#endif
  lf_muhtari_state *muhtari;
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
  return profile_id != NULL &&
         strcmp(profile_id, k_synthetic_profile_id) == 0;
}

static int is_nesturbator_profile(const char *profile_id) {
#if defined(LF_WEB_BUILD)
  (void)profile_id;
  return 0;
#else
  return profile_id != NULL &&
         strcmp(profile_id, k_nesturbator_profile_id) == 0;
#endif
}

static int is_muhtari_profile(const char *profile_id) {
#if defined(LF_HAS_MUHTARI)
  return profile_id != NULL && strcmp(profile_id, k_muhtari_profile_id) == 0;
#else
  (void)profile_id;
  return 0;
#endif
}

static int checked_synthetic_video_extent(size_t stride, size_t *extent) {
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

static void fill_synthetic_profile(lf_profile *out) {
  *out = (lf_profile){
      .struct_size = sizeof(*out),
      .profile_id = k_synthetic_profile_id,
      .core_id = k_synthetic_core_id,
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
      .max_content_bytes = 0U,
      .effective_configuration_id = k_synthetic_configuration_id,
      .frame_rate_numerator = 0U,
      .frame_rate_denominator = 0U,
  };
}

static void fill_synthetic_run_metadata(lf_run_result *out) {
  out->time_unit = LF_TIME_SYNTHETIC_STEP;
  out->core_tick_time_unit = LF_TIME_SYNTHETIC_STEP;
  out->video_format = LF_VIDEO_GRAY8;
  out->audio_encoding = LF_AUDIO_S16_NATIVE;
  out->audio_layout = LF_AUDIO_INTERLEAVED;
  out->video_width = LF_SYNTHETIC_VIDEO_WIDTH;
  out->video_height = LF_SYNTHETIC_VIDEO_HEIGHT;
  out->audio_rate_numerator = LF_SYNTHETIC_AUDIO_RATE_NUMERATOR;
  out->audio_rate_denominator = LF_SYNTHETIC_AUDIO_RATE_DENOMINATOR;
  out->audio_channels = 1U;
}

static void release_instance_payload(lf_instance *instance) {
  if (instance->owner_kind == LF_OWNER_SYNTHETIC) {
    if (instance->media != NULL) {
      instance->deallocate(instance->allocator_context, instance->media);
      instance->media = NULL;
    }
    return;
  }
#if !defined(LF_WEB_BUILD)
  if (instance->owner_kind == LF_OWNER_NESTURBATOR) {
    lf_nesturbator_destroy(&instance->nesturbator);
  } else
#endif
  {
#if defined(LF_HAS_MUHTARI)
    lf_muhtari_destroy(&instance->muhtari);
#endif
  }
}

static lf_status advance_synthetic(lf_instance *instance,
                                   const lf_run_request *request,
                                   lf_run_result *out) {
  size_t video_extent = 0U;
  size_t audio_samples = 0U;
  uint32_t step_index = 0U;
  const uint32_t work_units = request->work_units;
  out->requested_units = work_units;
  out->video_stride_bytes = request->video_stride_bytes;
  out->cumulative_units = instance->cumulative_units;
  if (work_units == 0U) {
    out->stop_reason = LF_STOP_BUDGET_REACHED;
    return LF_OK;
  }
  if (request->video_data == NULL || request->audio_data == NULL ||
      request->video_stride_bytes < LF_SYNTHETIC_VIDEO_WIDTH) {
    return LF_INVALID_ARGUMENT;
  }
  if (!checked_synthetic_video_extent(request->video_stride_bytes,
                                      &video_extent)) {
    return LF_LIMIT_EXCEEDED;
  }
  if ((size_t)work_units >
      SIZE_MAX / LF_SYNTHETIC_AUDIO_SAMPLES_PER_STEP) {
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

  instance->synthetic_positive_advance_started = 1;
  for (step_index = 0U; step_index < work_units; ++step_index) {
    const size_t audio_index = (size_t)step_index * 2U;
#if defined(LF_CONFORMANCE_VARIANT_DOUBLE_GUEST_UNITS)
    instance->cumulative_units += 2U;
#else
    instance->cumulative_units += 1U;
#endif
    instance->accumulator += instance->pending_buttons + 1U;
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
    request->video_data[second_row] = (uint8_t)instance->pending_buttons;
    request->video_data[second_row + 1U] =
        (uint8_t)(instance->cumulative_units + instance->accumulator);
  }
  instance->media[0] = 76U;
  instance->media[1] = 70U;
  instance->media[2] = (uint8_t)instance->cumulative_units;
  instance->media[3] = (uint8_t)instance->accumulator;
  instance->media_generation = instance->cumulative_units;

  out->actual_units = work_units;
  out->overshoot_units = 0U;
  out->sampled_buttons = instance->pending_buttons;
  out->video_valid = 1U;
  out->audio_valid = 1U;
  out->cumulative_units = instance->cumulative_units;
  out->stop_reason = LF_STOP_BUDGET_REACHED;
  out->video_extent_bytes = video_extent;
  out->audio_produced_samples = audio_samples;
  return LF_OK;
}

lf_status lf_get_profile(const char *profile_id, const char *configuration_id,
                         lf_profile *out) {
  if (out == NULL || out->struct_size != sizeof(*out)) {
    return LF_INVALID_ARGUMENT;
  }
  *out = (lf_profile){.struct_size = sizeof(*out)};
  if (is_synthetic_profile(profile_id)) {
    if (configuration_id != NULL) {
      return LF_UNSUPPORTED;
    }
    fill_synthetic_profile(out);
    return LF_OK;
  }
#if !defined(LF_WEB_BUILD)
  if (is_nesturbator_profile(profile_id)) {
    if (configuration_id != NULL) {
      return LF_UNSUPPORTED;
    }
    return lf_nesturbator_query_profile(out);
  }
#endif
#if defined(LF_HAS_MUHTARI)
  if (is_muhtari_profile(profile_id)) {
    return lf_muhtari_query_profile(configuration_id, out);
  }
#endif
  return LF_INVALID_ARGUMENT;
}

lf_status lf_get_capability(const char *profile_id,
                            const char *configuration_id,
                            lf_capability capability, uint32_t *supported) {
  lf_muhtari_configuration muhtari_configuration =
      LF_MUHTARI_CONFIGURATION_JOYSTICK_DEFAULT;
  if (supported == NULL) {
    return LF_INVALID_ARGUMENT;
  }
  *supported = 0U;
  if (!is_synthetic_profile(profile_id) && !is_nesturbator_profile(profile_id) &&
      !is_muhtari_profile(profile_id)) {
    return LF_INVALID_ARGUMENT;
  }
#if defined(LF_HAS_MUHTARI)
  if (is_muhtari_profile(profile_id)) {
    const lf_status status = lf_muhtari_resolve_configuration(
        configuration_id, &muhtari_configuration);
    if (status != LF_OK) {
      return status;
    }
    switch (capability) {
      case LF_CAP_LOGICAL_INPUT:
      case LF_CAP_BOUNDED_EXECUTION:
      case LF_CAP_SOFTWARE_VIDEO:
      case LF_CAP_AUDIO:
        break;
      case LF_CAP_IN_MEMORY_MEDIA_COPY:
        if (muhtari_configuration ==
            LF_MUHTARI_CONFIGURATION_BATTERY_DIAGNOSTIC) {
          *supported = 1U;
          return LF_OK;
        }
        return LF_UNSUPPORTED;
      case LF_CAP_SNAPSHOT:
#if LF_MUHTARI_API_REVISION == 8
        if (muhtari_configuration ==
            LF_MUHTARI_CONFIGURATION_BATTERY_DIAGNOSTIC) {
          *supported = 1U;
          return LF_OK;
        }
#endif
        return LF_UNSUPPORTED;
      case LF_CAP_HARDWARE_VIDEO:
      case LF_CAP_CONCURRENT_USE:
        return LF_UNSUPPORTED;
      default:
        return LF_INVALID_ARGUMENT;
    }
  }
#else
  (void)muhtari_configuration;
#endif
  if (configuration_id != NULL) {
    return LF_UNSUPPORTED;
  }
  switch (capability) {
    case LF_CAP_LOGICAL_INPUT:
    case LF_CAP_BOUNDED_EXECUTION:
    case LF_CAP_SOFTWARE_VIDEO:
    case LF_CAP_AUDIO:
      *supported = 1U;
      return LF_OK;
    case LF_CAP_IN_MEMORY_MEDIA_COPY:
      *supported = 1U;
      return LF_OK;
    case LF_CAP_SNAPSHOT:
      if (is_nesturbator_profile(profile_id)) {
        *supported = 1U;
        return LF_OK;
      }
      return LF_UNSUPPORTED;
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

  if (out == NULL) {
    return LF_INVALID_ARGUMENT;
  }
  *out = NULL;
  if (!is_synthetic_profile(profile_id) && !is_nesturbator_profile(profile_id) &&
      !is_muhtari_profile(profile_id)) {
    return LF_INVALID_ARGUMENT;
  }
  if (options != NULL) {
    if (options->struct_size != sizeof(*options) ||
        ((options->allocate == NULL) != (options->deallocate == NULL))) {
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
  instance->allocate = allocate;
  instance->deallocate = deallocate;
  instance->allocator_context = allocator_context;
  if (is_synthetic_profile(profile_id)) {
    instance->owner_kind = LF_OWNER_SYNTHETIC;
    instance->media = allocate(allocator_context, LF_SYNTHETIC_MEDIA_EXTENT);
    if (instance->media == NULL) {
      deallocate(allocator_context, instance);
      return LF_RESOURCE_EXHAUSTED;
    }
    instance->media[0] = 76U;
    instance->media[1] = 70U;
    instance->media[2] = 0U;
    instance->media[3] = 0U;
    *out = instance;
    return LF_OK;
  }

#if defined(LF_HAS_MUHTARI)
  if (is_muhtari_profile(profile_id)) {
    instance->owner_kind = LF_OWNER_MUHTARI;
    {
      const lf_status status = lf_muhtari_create(
          allocate, deallocate, allocator_context, &instance->muhtari);
      if (status != LF_OK) {
        deallocate(allocator_context, instance);
        return status;
      }
    }
    *out = instance;
    return LF_OK;
  }
#endif

#if !defined(LF_WEB_BUILD)
  instance->owner_kind = LF_OWNER_NESTURBATOR;
  {
    const lf_status status = lf_nesturbator_create(
        allocate, deallocate, allocator_context, &instance->nesturbator);
    if (status != LF_OK) {
      deallocate(allocator_context, instance);
      return status;
    }
  }
  *out = instance;
  return LF_OK;
#else
  deallocate(allocator_context, instance);
  return LF_INVALID_ARGUMENT;
#endif
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
  release_instance_payload(instance);
  deallocate(allocator_context, instance);
  return LF_OK;
}

lf_status lf_set_input(lf_instance *instance, const lf_input *input) {
  if (instance == NULL || input == NULL) {
    return LF_INVALID_ARGUMENT;
  }
#if !defined(LF_WEB_BUILD)
  if (instance->owner_kind == LF_OWNER_NESTURBATOR) {
    return lf_nesturbator_set_input(instance->nesturbator, input);
  }
#endif
#if defined(LF_HAS_MUHTARI)
  if (instance->owner_kind == LF_OWNER_MUHTARI) {
    return lf_muhtari_set_input(instance->muhtari, input);
  }
#endif
  if (input->struct_size != sizeof(*input) ||
      (input->buttons & ~LF_SYNTHETIC_INPUT_MASK) != 0U) {
    return LF_INVALID_ARGUMENT;
  }
  instance->pending_buttons = input->buttons;
  return LF_OK;
}

lf_status lf_load(lf_instance *instance, const lf_load_request *request,
                  lf_load_result *out) {
  if (out == NULL || out->struct_size != sizeof(*out)) {
    return LF_INVALID_ARGUMENT;
  }
  if (instance == NULL) {
    *out = (lf_load_result){.struct_size = sizeof(*out)};
    return LF_INVALID_ARGUMENT;
  }
#if !defined(LF_WEB_BUILD)
  if (instance->owner_kind == LF_OWNER_NESTURBATOR) {
    return lf_nesturbator_load(instance->nesturbator, request, out);
  }
#endif
#if defined(LF_HAS_MUHTARI)
  if (instance->owner_kind == LF_OWNER_MUHTARI) {
    return lf_muhtari_load(instance->muhtari, request, out);
  }
#endif
  *out = (lf_load_result){.struct_size = sizeof(*out)};
  if (request == NULL || request->struct_size != sizeof(*request) ||
      request->content_data == NULL || request->content_size_bytes == 0U) {
    return LF_INVALID_ARGUMENT;
  }

  if (request->content_size_bytes != sizeof(k_synthetic_import_test_content) ||
      memcmp(request->content_data, k_synthetic_import_test_content,
             sizeof(k_synthetic_import_test_content)) != 0 ||
      (request->configuration_id != NULL &&
       strcmp(request->configuration_id, k_synthetic_configuration_id) != 0)) {
#if defined(LF_CONFORMANCE_VARIANT_CLEAR_ON_UNSUPPORTED_LOAD)
    instance->synthetic_content_loaded = 0;
#endif
    return LF_UNSUPPORTED;
  }

  instance->cumulative_units = 0U;
  instance->accumulator = 0U;
  instance->pending_buttons = 0U;
  instance->media[0] = 76U;
  instance->media[1] = 70U;
  instance->media[2] = 0U;
  instance->media[3] = 0U;
  instance->media_generation = 0U;
  instance->synthetic_content_loaded = 1;
  instance->synthetic_positive_advance_started = 0;
  *out = (lf_load_result){
      .struct_size = sizeof(*out),
      .loaded = 1U,
      .content_size_bytes = sizeof(k_synthetic_import_test_content),
      .effective_configuration_id = k_synthetic_configuration_id,
  };
  return LF_OK;
}

lf_status lf_advance(lf_instance *instance, const lf_run_request *request,
                     lf_run_result *out) {
  if (out == NULL || out->struct_size != sizeof(*out)) {
    return LF_INVALID_ARGUMENT;
  }
#if !defined(LF_WEB_BUILD)
  if (instance != NULL && instance->owner_kind == LF_OWNER_NESTURBATOR) {
    return lf_nesturbator_advance(instance->nesturbator, request, out);
  }
#endif
#if defined(LF_HAS_MUHTARI)
  if (instance != NULL && instance->owner_kind == LF_OWNER_MUHTARI) {
    return lf_muhtari_advance(instance->muhtari, request, out);
  }
#endif
  *out = (lf_run_result){
      .struct_size = sizeof(*out),
      .stop_reason = LF_STOP_REJECTED,
  };
  fill_synthetic_run_metadata(out);
  if (instance != NULL) {
    out->cumulative_units = instance->cumulative_units;
  }
  if (instance == NULL || request == NULL ||
      request->struct_size != sizeof(*request)) {
    return LF_INVALID_ARGUMENT;
  }
  return advance_synthetic(instance, request, out);
}

lf_status lf_copy_media(lf_instance *instance, uint8_t *destination,
                        size_t capacity_bytes, lf_media_info *out) {
  if (out == NULL || out->struct_size != sizeof(*out) || instance == NULL ||
      destination == NULL) {
    return LF_INVALID_ARGUMENT;
  }
#if !defined(LF_WEB_BUILD)
  if (instance->owner_kind == LF_OWNER_NESTURBATOR) {
    return lf_nesturbator_copy_media(instance->nesturbator, destination,
                                     capacity_bytes, out);
  }
#endif
#if defined(LF_HAS_MUHTARI)
  if (instance->owner_kind == LF_OWNER_MUHTARI) {
    return lf_muhtari_copy_media(instance->muhtari, destination,
                                 capacity_bytes, out);
  }
#endif
  if (capacity_bytes < LF_SYNTHETIC_MEDIA_EXTENT) {
    return LF_BUFFER_TOO_SMALL;
  }
  memcpy(destination, instance->media, LF_SYNTHETIC_MEDIA_EXTENT);
  *out = (lf_media_info){
      .struct_size = sizeof(*out),
      .identity = k_synthetic_media_identity,
      .extent_bytes = LF_SYNTHETIC_MEDIA_EXTENT,
      .guest_generation = instance->media_generation,
  };
  return LF_OK;
}

lf_status lf_import_media(lf_instance *instance, const char *identity,
                          const uint8_t *source, size_t extent_bytes) {
  if (instance == NULL || identity == NULL || identity[0] == '\0' ||
      source == NULL || extent_bytes == 0U) {
    return LF_INVALID_ARGUMENT;
  }
#if !defined(LF_WEB_BUILD)
  if (instance->owner_kind == LF_OWNER_NESTURBATOR) {
    return lf_nesturbator_import_media(instance->nesturbator, identity,
                                       source, extent_bytes);
  }
#endif
#if defined(LF_HAS_MUHTARI)
  if (instance->owner_kind == LF_OWNER_MUHTARI) {
    return lf_muhtari_import_media(instance->muhtari, identity, source,
                                   extent_bytes);
  }
#endif
  if (!instance->synthetic_content_loaded ||
      instance->synthetic_positive_advance_started) {
    return LF_INVALID_ARGUMENT;
  }
  if (strcmp(identity, k_synthetic_media_identity) != 0) {
    return LF_UNSUPPORTED;
  }
  if (extent_bytes != LF_SYNTHETIC_MEDIA_EXTENT) {
    return LF_INVALID_ARGUMENT;
  }
  memcpy(instance->media, source, LF_SYNTHETIC_MEDIA_EXTENT);
  return LF_OK;
}

lf_status lf_get_snapshot_size(lf_instance *instance,
                               size_t *required_bytes) {
  if (instance == NULL || required_bytes == NULL) {
    return LF_INVALID_ARGUMENT;
  }
#if !defined(LF_WEB_BUILD)
  if (instance->owner_kind == LF_OWNER_NESTURBATOR) {
    return lf_nesturbator_get_snapshot_size(instance->nesturbator,
                                             required_bytes);
  }
#endif
#if defined(LF_HAS_MUHTARI) && LF_MUHTARI_API_REVISION == 8
  if (instance->owner_kind == LF_OWNER_MUHTARI) {
    return lf_muhtari_get_snapshot_size(instance->muhtari, required_bytes);
  }
#endif
  return LF_UNSUPPORTED;
}

lf_status lf_capture_snapshot(lf_instance *instance, uint8_t *destination,
                              size_t capacity_bytes) {
  if (instance == NULL || destination == NULL) {
    return LF_INVALID_ARGUMENT;
  }
#if !defined(LF_WEB_BUILD)
  if (instance->owner_kind == LF_OWNER_NESTURBATOR) {
    return lf_nesturbator_capture_snapshot(instance->nesturbator,
                                            destination, capacity_bytes);
  }
#endif
#if defined(LF_HAS_MUHTARI) && LF_MUHTARI_API_REVISION == 8
  if (instance->owner_kind == LF_OWNER_MUHTARI) {
    return lf_muhtari_capture_snapshot(instance->muhtari, destination,
                                       capacity_bytes);
  }
#endif
  return LF_UNSUPPORTED;
}

lf_status lf_restore_snapshot(lf_instance *instance, const uint8_t *source,
                              size_t extent_bytes) {
  if (instance == NULL || source == NULL || extent_bytes == 0U) {
    return LF_INVALID_ARGUMENT;
  }
#if !defined(LF_WEB_BUILD)
  if (instance->owner_kind == LF_OWNER_NESTURBATOR) {
    return lf_nesturbator_restore_snapshot(instance->nesturbator, source,
                                            extent_bytes);
  }
#endif
#if defined(LF_HAS_MUHTARI) && LF_MUHTARI_API_REVISION == 8
  if (instance->owner_kind == LF_OWNER_MUHTARI) {
    return lf_muhtari_restore_snapshot(instance->muhtari, source,
                                        extent_bytes);
  }
#endif
  return LF_UNSUPPORTED;
}

#if defined(LF_NESTURBATOR_TESTING)
lf_status lf_test_set_nesturbator_load_epoch(lf_instance *instance,
                                              uint64_t load_epoch) {
  if (instance == NULL) {
    return LF_INVALID_ARGUMENT;
  }
  if (instance->owner_kind != LF_OWNER_NESTURBATOR) {
    return LF_UNSUPPORTED;
  }
  return lf_nesturbator_set_load_epoch_for_testing(instance->nesturbator,
                                                    load_epoch);
}

lf_status lf_test_get_nesturbator_restore_attempts(
    const lf_instance *instance, uint64_t *attempts) {
  if (instance == NULL || attempts == NULL) {
    return LF_INVALID_ARGUMENT;
  }
  if (instance->owner_kind != LF_OWNER_NESTURBATOR) {
    return LF_UNSUPPORTED;
  }
  return lf_nesturbator_get_restore_attempts_for_testing(
      instance->nesturbator, attempts);
}
#endif
