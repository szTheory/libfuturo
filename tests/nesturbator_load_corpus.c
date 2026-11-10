#include <libfuturo/libfuturo.h>

#include "nesturbator_load_cases.h"
#include "nesturbator_load_support.h"
#include "nesturbator_save_fixture.h"
#include "nesturbator_save_oracle.h"

#include <inttypes.h>
#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifndef LIBFUTURO_NESTURBATOR_SOURCE_REVISION
#error "The selected Nesturbator source revision must be compiled into the consumer"
#endif

#define LOAD_GUARD_BYTES 32U
#define LOAD_VIDEO_WIDTH 256U
#define LOAD_VIDEO_HEIGHT 240U
#define LOAD_VIDEO_STRIDE 772U
#define LOAD_VIDEO_CAPACITY ((size_t)LOAD_VIDEO_STRIDE * LOAD_VIDEO_HEIGHT)
#define LOAD_VIDEO_EXTENT ((size_t)(LOAD_VIDEO_HEIGHT - 1U) * LOAD_VIDEO_STRIDE + (size_t)LOAD_VIDEO_WIDTH * 3U)
#define LOAD_AUDIO_CAPACITY 799U
#define LOAD_AUDIO_STORAGE_BYTES ((size_t)LOAD_AUDIO_CAPACITY * sizeof(int16_t))
#define LOAD_PROFILE_ID "nesturbator-ntsc-v1"
#define LOAD_MAX_REQUEST_BYTES ((size_t)67108864U)
#define LOAD_MAX_ACCESSIBLE_BYTES LF_LOAD_CORPUS_MAX_ACCESSIBLE_SPAN
#define LOAD_CONFIG_STORAGE_BYTES (LOAD_GUARD_BYTES + LF_SAVE_ORACLE_CONFIGURATION_IDENTITY_CAPACITY + LOAD_GUARD_BYTES)
#define LOAD_MANIFEST_ENTRY_BYTES 1024U

#define LF_LOAD_CLASSIFICATION_CASE_COUNT                                  \
  (LF_LOAD_ADMISSION_CASE_COUNT + LF_LOAD_LAYOUT_CASE_COUNT +              \
   LF_LOAD_BOARD_RAM_CASE_COUNT)

typedef struct guarded_request {
  uint8_t before[LOAD_GUARD_BYTES];
  lf_load_request value;
  uint8_t after[LOAD_GUARD_BYTES];
} guarded_request;

typedef struct guarded_result {
  uint8_t before[LOAD_GUARD_BYTES];
  lf_load_result value;
  uint8_t after[LOAD_GUARD_BYTES];
} guarded_result;

typedef struct media_observation {
  uint8_t bytes[LF_SAVE_ORACLE_EXTENT_BYTES];
  char identity[LF_SAVE_ORACLE_MEDIA_IDENTITY_CAPACITY];
  size_t extent_bytes;
  uint64_t generation;
} media_observation;

static const char *load_status_name(lf_status status) {
  switch (status) {
    case LF_OK:
      return "LF_OK";
    case LF_INVALID_ARGUMENT:
      return "LF_INVALID_ARGUMENT";
    case LF_UNSUPPORTED:
      return "LF_UNSUPPORTED";
    case LF_LIMIT_EXCEEDED:
      return "LF_LIMIT_EXCEEDED";
    case LF_BUFFER_TOO_SMALL:
      return "LF_BUFFER_TOO_SMALL";
    case LF_RESOURCE_EXHAUSTED:
      return "LF_RESOURCE_EXHAUSTED";
  }
  return "LF_UNKNOWN";
}

static int check_case_status(const lf_load_case *load_case,
                             lf_status expected_status,
                             lf_status actual_status) {
  if (load_case == NULL) {
    return 0;
  }
  if (actual_status == expected_status) {
    return 1;
  }
  (void)fprintf(stderr,
                "load_corpus: status_mismatch case=%s expected=%d actual=%d\n",
                load_case->id, (int)expected_status, (int)actual_status);
  return 0;
}

static int load_matrix_size_bytes(lf_matrix_size_mode mode, uint16_t value,
                                  size_t unit, size_t *size_bytes) {
  if (size_bytes == NULL) {
    return 0;
  }
  if (mode == LF_MATRIX_SIZE_LINEAR) {
    return load_size_multiply_checked((size_t)value, unit, size_bytes);
  }
  if (mode == LF_MATRIX_SIZE_EXPONENT && value <= UINT8_MAX) {
    const uint8_t encoded = (uint8_t)value;
    const unsigned int exponent = (unsigned int)(encoded >> 2);
    const size_t multiplier =
        (size_t)((unsigned int)(encoded & 3U) * 2U + 1U);
    size_t base = 0U;
    if (exponent >= sizeof(size_t) * CHAR_BIT) {
      return 0;
    }
    base = (size_t)1U << exponent;
    return load_size_multiply_checked(base, multiplier, size_bytes);
  }
  return 0;
}

static int load_matrix_declared_extent(const lf_load_matrix_case *matrix_case,
                                       size_t *extent_bytes) {
  size_t prg_bytes = 0U;
  size_t chr_bytes = 0U;
  size_t total = 0U;
  if (matrix_case == NULL || extent_bytes == NULL ||
      !load_matrix_size_bytes(matrix_case->prg_mode,
                              matrix_case->prg_value, (size_t)16U * 1024U,
                              &prg_bytes) ||
      !load_matrix_size_bytes(matrix_case->chr_mode,
                              matrix_case->chr_value, (size_t)8U * 1024U,
                              &chr_bytes) ||
      !load_size_add_checked(16U, matrix_case->trainer != 0U ? 512U : 0U,
                             &total) ||
      !load_size_add_checked(total, prg_bytes, &total) ||
      !load_size_add_checked(total, chr_bytes, &total)) {
    return 0;
  }
  *extent_bytes = total;
  return 1;
}

static int load_matrix_case_build(const lf_load_matrix_case *matrix_case,
                                  lf_load_case *load_case,
                                  int *declared_size_representable) {
  size_t declared_extent = 0U;
  size_t actual_extent = 0U;
  int representable = 0;
  if (matrix_case == NULL || load_case == NULL ||
      matrix_case->id == NULL || matrix_case->id[0] == '\0' ||
      matrix_case->mapper > 4095U || matrix_case->submapper > 15U ||
      matrix_case->battery > 1U || matrix_case->trainer > 1U ||
      matrix_case->prg_ram_shift > 15U ||
      matrix_case->prg_nvram_shift > 15U ||
      matrix_case->chr_ram_shift > 15U ||
      matrix_case->chr_nvram_shift > 15U) {
    return 0;
  }
  memset(load_case, 0, sizeof(*load_case));
  load_case->id = matrix_case->id;
  load_case->expected_status = matrix_case->expected_status;
  load_case->configuration_id = matrix_case->configuration_id;
  load_case->request_variant = LF_LOAD_REQUEST_VALID;
  load_case->request_size_variant = LF_LOAD_SIZE_EXACT;
  load_case->result_variant = LF_LOAD_RESULT_VALID;
  load_case->result_size_variant = LF_LOAD_SIZE_EXACT;

  load_case->header[0] = UINT8_C(0x4e);
  load_case->header[1] = UINT8_C(0x45);
  load_case->header[2] = UINT8_C(0x53);
  load_case->header[3] = UINT8_C(0x1a);
  if (matrix_case->format == LF_MATRIX_FORMAT_INES) {
    if (matrix_case->mapper > 15U ||
        matrix_case->prg_mode != LF_MATRIX_SIZE_LINEAR ||
        matrix_case->chr_mode != LF_MATRIX_SIZE_LINEAR ||
        matrix_case->prg_value > UINT8_MAX ||
        matrix_case->chr_value > UINT8_MAX || matrix_case->submapper != 0U ||
        matrix_case->prg_ram_shift != 0U ||
        matrix_case->prg_nvram_shift != 0U ||
        matrix_case->chr_ram_shift != 0U ||
        matrix_case->chr_nvram_shift != 0U) {
      return 0;
    }
    load_case->header[4] = (uint8_t)matrix_case->prg_value;
    load_case->header[5] = (uint8_t)matrix_case->chr_value;
    load_case->header[6] = (uint8_t)((matrix_case->mapper << 4) |
                                     (matrix_case->battery << 1) |
                                     (matrix_case->trainer << 2));
  } else if (matrix_case->format == LF_MATRIX_FORMAT_NES2) {
    if ((matrix_case->prg_mode == LF_MATRIX_SIZE_LINEAR &&
         matrix_case->prg_value > 0x0fffU) ||
        (matrix_case->chr_mode == LF_MATRIX_SIZE_LINEAR &&
         matrix_case->chr_value > 0x0fffU) ||
        (matrix_case->prg_mode == LF_MATRIX_SIZE_EXPONENT &&
         matrix_case->prg_value > UINT8_MAX) ||
        (matrix_case->chr_mode == LF_MATRIX_SIZE_EXPONENT &&
         matrix_case->chr_value > UINT8_MAX)) {
      return 0;
    }
    load_case->header[6] = (uint8_t)(((matrix_case->mapper & 0x0fU) << 4) |
                                     ((unsigned int)matrix_case->battery << 1) |
                                     ((unsigned int)matrix_case->trainer << 2));
    load_case->header[7] = (uint8_t)(0x08U | (matrix_case->mapper & 0xf0U));
    load_case->header[8] = (uint8_t)(((unsigned int)matrix_case->submapper << 4) |
                                     ((matrix_case->mapper >> 8) & 0x0fU));
    if (matrix_case->prg_mode == LF_MATRIX_SIZE_LINEAR) {
      load_case->header[4] = (uint8_t)(matrix_case->prg_value & 0xffU);
    } else {
      load_case->header[4] = (uint8_t)matrix_case->prg_value;
    }
    if (matrix_case->chr_mode == LF_MATRIX_SIZE_LINEAR) {
      load_case->header[5] = (uint8_t)(matrix_case->chr_value & 0xffU);
    } else {
      load_case->header[5] = (uint8_t)matrix_case->chr_value;
    }
    if (matrix_case->prg_mode == LF_MATRIX_SIZE_EXPONENT) {
      load_case->header[9] |= UINT8_C(0x0f);
    } else {
      load_case->header[9] |=
          (uint8_t)((matrix_case->prg_value >> 8) & 0x0fU);
    }
    if (matrix_case->chr_mode == LF_MATRIX_SIZE_EXPONENT) {
      load_case->header[9] |= UINT8_C(0xf0);
    } else {
      load_case->header[9] |=
          (uint8_t)(((matrix_case->chr_value >> 8) & 0x0fU) << 4);
    }
    load_case->header[10] =
        (uint8_t)((matrix_case->prg_nvram_shift << 4) |
                  matrix_case->prg_ram_shift);
    load_case->header[11] =
        (uint8_t)((matrix_case->chr_nvram_shift << 4) |
                  matrix_case->chr_ram_shift);
  } else {
    return 0;
  }
  if (matrix_case->magic_corrupt_index != UINT8_MAX) {
    if (matrix_case->magic_corrupt_index >= 4U ||
        matrix_case->magic_corrupt_mask == 0U) {
      return 0;
    }
    load_case->header[matrix_case->magic_corrupt_index] ^=
        matrix_case->magic_corrupt_mask;
  }

  representable =
      load_matrix_declared_extent(matrix_case, &declared_extent);
  if (matrix_case->extent_mode == LF_MATRIX_EXTENT_EXACT) {
    if (!representable) {
      return 0;
    }
    actual_extent = declared_extent;
  } else if (matrix_case->extent_mode == LF_MATRIX_EXTENT_EXPLICIT) {
    actual_extent = matrix_case->extent_bytes;
  } else if (matrix_case->extent_mode == LF_MATRIX_EXTENT_DELTA) {
    int64_t adjusted = 0;
    if (!representable) {
      return 0;
    }
    adjusted = (int64_t)declared_extent + (int64_t)matrix_case->extent_delta;
    if (adjusted < 0 || (uint64_t)adjusted > SIZE_MAX) {
      return 0;
    }
    actual_extent = (size_t)adjusted;
  } else {
    return 0;
  }
  if (actual_extent > LOAD_MAX_ACCESSIBLE_BYTES ||
      actual_extent > LF_LOAD_CORPUS_MAX_LIVE_BYTES) {
    return 0;
  }
  load_case->actual_extent = actual_extent;
  if (declared_size_representable != NULL) {
    *declared_size_representable = representable;
  }
  return 1;
}

static int load_same_profile(const lf_profile *left,
                             const lf_profile *right) {
  return left != NULL && right != NULL &&
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

static int load_snapshot_profile(lf_profile *profile) {
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

static int load_copy_media_with_zero_generation(
    lf_instance *instance, media_observation *observation,
    int allow_zero_generation) {
  lf_media_info information = {.struct_size = sizeof(information)};
  lf_status status = LF_INVALID_ARGUMENT;

  if (instance == NULL || observation == NULL) {
    return 0;
  }
  memset(observation, 0, sizeof(*observation));
  status = lf_copy_media(instance, observation->bytes,
                         sizeof(observation->bytes), &information);
  if (status != LF_OK || information.identity == NULL ||
      information.extent_bytes != sizeof(observation->bytes) ||
      (allow_zero_generation == 0 && information.guest_generation == 0U) ||
      strlen(information.identity) >= sizeof(observation->identity)) {
    return 0;
  }
  memcpy(observation->identity, information.identity,
         strlen(information.identity) + 1U);
  observation->extent_bytes = information.extent_bytes;
  observation->generation = information.guest_generation;
  return 1;
}

static int load_copy_media(lf_instance *instance,
                           media_observation *observation) {
  return load_copy_media_with_zero_generation(instance, observation, 0);
}

static int load_media_equal(const media_observation *left,
                            const media_observation *right) {
  return left != NULL && right != NULL &&
         left->extent_bytes == right->extent_bytes &&
         left->generation == right->generation &&
         strcmp(left->identity, right->identity) == 0 &&
         memcmp(left->bytes, right->bytes, sizeof(left->bytes)) == 0;
}

static int compare_refused_observation(
    const char *case_id, const media_observation *expected,
    const media_observation *actual) {
  size_t index = 0U;
  size_t compare_extent = 0U;
  if (case_id == NULL || expected == NULL || actual == NULL ||
      expected->extent_bytes > sizeof(expected->bytes) ||
      actual->extent_bytes > sizeof(actual->bytes)) {
    return 0;
  }
  compare_extent = expected->extent_bytes < actual->extent_bytes
                       ? expected->extent_bytes
                       : actual->extent_bytes;
  for (index = 0U; index < compare_extent; ++index) {
    if (expected->bytes[index] != actual->bytes[index]) {
      (void)fprintf(stderr,
                    "load_corpus: preservation_mismatch case=%s field=media_bytes offset=%zu expected=0x%02x actual=0x%02x\n",
                    case_id, index, (unsigned int)expected->bytes[index],
                    (unsigned int)actual->bytes[index]);
      return 0;
    }
  }
  if (expected->extent_bytes != actual->extent_bytes) {
    (void)fprintf(stderr,
                  "load_corpus: preservation_mismatch case=%s field=media_extent expected=%zu actual=%zu\n",
                  case_id, expected->extent_bytes, actual->extent_bytes);
    return 0;
  }
  if (strcmp(expected->identity, actual->identity) != 0) {
    (void)fprintf(stderr,
                  "load_corpus: preservation_mismatch case=%s field=media_identity expected=%s actual=%s\n",
                  case_id, expected->identity, actual->identity);
    return 0;
  }
  if (expected->generation != actual->generation) {
    (void)fprintf(stderr,
                  "load_corpus: preservation_mismatch case=%s field=media_generation expected=%" PRIu64 " actual=%" PRIu64 "\n",
                  case_id, expected->generation, actual->generation);
    return 0;
  }
  return 1;
}

static int load_result_is_active(const lf_load_result *result,
                                 size_t fixture_extent) {
  return result != NULL && result->struct_size == sizeof(*result) &&
         result->loaded == 1U &&
         result->content_size_bytes == fixture_extent &&
         result->effective_configuration_id != NULL &&
         strcmp(result->effective_configuration_id,
                LF_SAVE_ORACLE_CONFIGURATION_IDENTITY) == 0;
}

static int load_result_is_unloaded(const lf_load_result *result) {
  return result != NULL && result->struct_size == sizeof(*result) &&
         result->loaded == 0U && result->content_size_bytes == 0U &&
         result->effective_configuration_id == NULL;
}

static uint64_t load_hash_bytes(const uint8_t *bytes, size_t extent) {
  uint64_t hash = UINT64_C(14695981039346656037);
  size_t index = 0U;
  for (index = 0U; index < extent; ++index) {
    hash ^= bytes[index];
    hash *= UINT64_C(1099511628211);
  }
  return hash;
}

static int load_tracker_create(load_allocation_tracker *tracker,
                               lf_instance **instance) {
  const lf_create_options options = {
      .struct_size = sizeof(options),
      .allocate = load_tracked_allocate,
      .deallocate = load_tracked_deallocate,
      .allocator_context = tracker,
  };
  if (tracker == NULL || instance == NULL) {
    return 0;
  }
  *instance = NULL;
  return lf_create(LOAD_PROFILE_ID, &options, instance) == LF_OK &&
         *instance != NULL;
}

static int load_instance_fixture_configuration(
    lf_instance *instance, const uint8_t *fixture, size_t fixture_extent,
    const char *configuration_id, lf_load_result *result);

static int load_instance_fixture(lf_instance *instance,
                                 const uint8_t *fixture,
                                 size_t fixture_extent,
                                 lf_load_result *result) {
  return load_instance_fixture_configuration(instance, fixture,
                                             fixture_extent, NULL, result);
}

static int load_instance_fixture_configuration(
    lf_instance *instance, const uint8_t *fixture, size_t fixture_extent,
    const char *configuration_id, lf_load_result *result) {
  const lf_load_request request = {
      .struct_size = sizeof(request),
      .content_data = fixture,
      .content_size_bytes = fixture_extent,
      .configuration_id = configuration_id,
  };
  if (result == NULL) {
    return 0;
  }
  memset(result, 0, sizeof(*result));
  result->struct_size = sizeof(*result);
  return lf_load(instance, &request, result) == LF_OK &&
         load_result_is_active(result, fixture_extent);
}

static int load_run_result_equal(const lf_run_result *left,
                                 const lf_run_result *right) {
  return left != NULL && right != NULL &&
         left->struct_size == right->struct_size &&
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

static int load_has_byte_guard(const uint8_t *storage, size_t payload_bytes,
                               uint8_t expected) {
  size_t index = 0U;
  if (storage == NULL) {
    return 0;
  }
  for (index = 0U; index < LOAD_GUARD_BYTES; ++index) {
    if (storage[index] != expected ||
        storage[LOAD_GUARD_BYTES + payload_bytes + index] != expected) {
      return 0;
    }
  }
  return 1;
}

static int load_advance_pair_frame(lf_instance *subject,
                                   lf_instance *control,
                                   uint32_t buttons,
                                   int set_pending_input,
                                   uint32_t expected_buttons,
                                   unsigned int continuation_index,
                                   const char *case_id,
                                   lf_run_result *subject_result_out) {
  _Alignas(max_align_t)
      uint8_t subject_video[LOAD_GUARD_BYTES + LOAD_VIDEO_CAPACITY +
                            LOAD_GUARD_BYTES];
  _Alignas(max_align_t)
      uint8_t control_video[LOAD_GUARD_BYTES + LOAD_VIDEO_CAPACITY +
                            LOAD_GUARD_BYTES];
  _Alignas(max_align_t)
      uint8_t subject_audio[LOAD_GUARD_BYTES + LOAD_AUDIO_STORAGE_BYTES +
                            LOAD_GUARD_BYTES];
  _Alignas(max_align_t)
      uint8_t control_audio[LOAD_GUARD_BYTES + LOAD_AUDIO_STORAGE_BYTES +
                            LOAD_GUARD_BYTES];
  lf_run_request subject_request = {
      .struct_size = sizeof(subject_request),
      .work_units = 1U,
      .video_data = subject_video + LOAD_GUARD_BYTES,
      .video_capacity_bytes = LOAD_VIDEO_CAPACITY,
      .video_stride_bytes = LOAD_VIDEO_STRIDE,
      .audio_data = (int16_t *)(void *)(subject_audio + LOAD_GUARD_BYTES),
      .audio_capacity_samples = LOAD_AUDIO_CAPACITY,
  };
  lf_run_request control_request = subject_request;
  lf_run_result subject_result = {.struct_size = sizeof(subject_result)};
  lf_run_result control_result = {.struct_size = sizeof(control_result)};
  media_observation subject_media;
  media_observation control_media;
  const lf_input input = {.struct_size = sizeof(input), .buttons = buttons};
  lf_status subject_status = LF_INVALID_ARGUMENT;
  lf_status control_status = LF_INVALID_ARGUMENT;
  int ok = 0;

  control_request.video_data = control_video + LOAD_GUARD_BYTES;
  control_request.audio_data =
      (int16_t *)(void *)(control_audio + LOAD_GUARD_BYTES);
  memset(subject_video, 0xa5, sizeof(subject_video));
  memset(control_video, 0xa5, sizeof(control_video));
  memset(subject_audio, 0xa5, sizeof(subject_audio));
  memset(control_audio, 0xa5, sizeof(control_audio));

  if (set_pending_input != 0 &&
      (lf_set_input(subject, &input) != LF_OK ||
       lf_set_input(control, &input) != LF_OK)) {
    (void)fprintf(stderr,
                  "load_corpus: input_setup case=%s frame=%u\n",
                  case_id, continuation_index);
    return 0;
  }
  subject_status = lf_advance(subject, &subject_request, &subject_result);
  control_status = lf_advance(control, &control_request, &control_result);
  if (subject_status != LF_OK || control_status != LF_OK ||
      subject_result.actual_units != 1U ||
      subject_result.overshoot_units != 0U ||
      subject_result.core_ticks_valid != 1U ||
      subject_result.video_valid != 1U ||
      subject_result.audio_valid != 1U ||
      subject_result.video_extent_bytes != LOAD_VIDEO_EXTENT ||
      subject_result.audio_produced_samples < 798U ||
      subject_result.audio_produced_samples > LOAD_AUDIO_CAPACITY ||
      subject_result.sampled_buttons != expected_buttons ||
      !load_run_result_equal(&subject_result, &control_result) ||
      memcmp(subject_video, control_video, sizeof(subject_video)) != 0 ||
      memcmp(subject_audio, control_audio, sizeof(subject_audio)) != 0 ||
      !load_has_byte_guard(subject_video, LOAD_VIDEO_CAPACITY, 0xa5U) ||
      !load_has_byte_guard(control_video, LOAD_VIDEO_CAPACITY, 0xa5U) ||
      !load_has_byte_guard(subject_audio, LOAD_AUDIO_STORAGE_BYTES, 0xa5U) ||
      !load_has_byte_guard(control_audio, LOAD_AUDIO_STORAGE_BYTES, 0xa5U) ||
      !load_copy_media(subject, &subject_media) ||
      !load_copy_media(control, &control_media) ||
      !load_media_equal(&subject_media, &control_media)) {
    (void)fprintf(stderr,
                  "load_corpus: continuation_mismatch case=%s frame=%u\n",
                  case_id, continuation_index);
    return 0;
  }
  if (continuation_index >= 1U &&
      !lf_save_oracle_matches(subject_media.bytes,
                              subject_media.extent_bytes,
                              (uint8_t)(LF_SAVE_ORACLE_COMMITTED_BYTE +
                                        continuation_index))) {
    (void)fprintf(stderr,
                  "load_corpus: save_oracle_mismatch case=%s frame=%u\n",
                  case_id, continuation_index);
    return 0;
  }
  if (subject_result_out != NULL) {
    *subject_result_out = subject_result;
  }
  ok = 1;
  return ok;
}

static int load_advance_single_frame(lf_instance *instance,
                                     const char *case_id) {
  _Alignas(max_align_t)
      uint8_t video[LOAD_GUARD_BYTES + LOAD_VIDEO_CAPACITY + LOAD_GUARD_BYTES];
  _Alignas(max_align_t)
      uint8_t audio[LOAD_GUARD_BYTES + LOAD_AUDIO_STORAGE_BYTES +
                    LOAD_GUARD_BYTES];
  lf_run_request request = {
      .struct_size = sizeof(request),
      .work_units = 1U,
      .video_data = video + LOAD_GUARD_BYTES,
      .video_capacity_bytes = LOAD_VIDEO_CAPACITY,
      .video_stride_bytes = LOAD_VIDEO_STRIDE,
      .audio_data = (int16_t *)(void *)(audio + LOAD_GUARD_BYTES),
      .audio_capacity_samples = LOAD_AUDIO_CAPACITY,
  };
  lf_run_result result = {.struct_size = sizeof(result)};
  if (instance == NULL) {
    return 0;
  }
  memset(video, 0xa5, sizeof(video));
  memset(audio, 0xa5, sizeof(audio));
  if (lf_advance(instance, &request, &result) != LF_OK ||
      result.actual_units != 1U || result.video_valid != 1U ||
      result.audio_valid != 1U || result.core_ticks_valid != 1U ||
      !load_has_byte_guard(video, LOAD_VIDEO_CAPACITY, 0xa5U) ||
      !load_has_byte_guard(audio, LOAD_AUDIO_STORAGE_BYTES, 0xa5U)) {
    (void)fprintf(stderr,
                  "load_corpus: diverge_state_advance_failed case=%s\n",
                  case_id);
    return 0;
  }
  return 1;
}

static int load_check_unloaded_refusal(
    const uint8_t *fixture, size_t fixture_extent,
    const lf_load_case *load_case) {
  load_allocation_tracker tracker = {0};
  lf_instance *instance = NULL;
  _Alignas(max_align_t)
      uint8_t content[LOAD_GUARD_BYTES +
                      LF_NESTURBATOR_SAVE_FIXTURE_TOTAL_BYTES +
                      LOAD_GUARD_BYTES];
  guarded_result result;
  uint8_t video[LOAD_VIDEO_EXTENT];
  int16_t audio[LOAD_AUDIO_CAPACITY];
  lf_run_request run_request = {
      .struct_size = sizeof(run_request),
      .work_units = 1U,
      .video_data = video,
      .video_capacity_bytes = sizeof(video),
      .video_stride_bytes = LOAD_VIDEO_STRIDE,
      .audio_data = audio,
      .audio_capacity_samples = LOAD_AUDIO_CAPACITY,
  };
  lf_run_result run_result = {.struct_size = sizeof(run_result)};
  lf_load_request request = {
      .struct_size = sizeof(request),
      .content_data = content + LOAD_GUARD_BYTES,
      .content_size_bytes = fixture_extent,
      .configuration_id = load_case->configuration_id,
  };
  lf_status status = LF_INVALID_ARGUMENT;
  int ok = 0;

  if (fixture == NULL || load_case == NULL ||
      fixture_extent > LF_NESTURBATOR_SAVE_FIXTURE_TOTAL_BYTES ||
      !load_tracker_create(&tracker, &instance)) {
    (void)fprintf(stderr, "load_corpus: unloaded_setup_failed case=%s\n",
                  load_case == NULL ? "<null>" : load_case->id);
    goto cleanup;
  }
  memset(content, 0xa5, sizeof(content));
  memcpy(content + LOAD_GUARD_BYTES, fixture, fixture_extent);
  memcpy(content + LOAD_GUARD_BYTES, load_case->header,
         sizeof(load_case->header));
  memset(&result, 0xa5, sizeof(result));
  result.value.struct_size = sizeof(result.value);
  memset(video, 0x5a, sizeof(video));
  memset(audio, 0x5a, sizeof(audio));
  status = lf_load(instance, &request, &result.value);
  if (!check_case_status(load_case, load_case->expected_status, status)) {
    goto cleanup;
  }
  if (!load_result_is_unloaded(&result.value) ||
      !load_has_byte_guard(content, fixture_extent, 0xa5U)) {
    (void)fprintf(stderr,
                  "load_corpus: unloaded_refusal_postcondition case=%s\n",
                  load_case->id);
    goto cleanup;
  }
  {
    uint8_t video_before[sizeof(video)];
    int16_t audio_before[LOAD_AUDIO_CAPACITY];
    memcpy(video_before, video, sizeof(video));
    memcpy(audio_before, audio, sizeof(audio));
    if (lf_advance(instance, &run_request, &run_result) !=
            LF_INVALID_ARGUMENT ||
        memcmp(video, video_before, sizeof(video)) != 0 ||
        memcmp(audio, audio_before, sizeof(audio)) != 0) {
      (void)fprintf(stderr,
                    "load_corpus: unloaded_advance_changed_output case=%s\n",
                    load_case->id);
      goto cleanup;
    }
  }
  ok = 1;

cleanup:
  if (instance != NULL && lf_destroy(&instance) != LF_OK) {
    ok = 0;
  }
  if (!load_tracker_balanced(&tracker)) {
    (void)fprintf(stderr,
                  "load_corpus: unloaded_cleanup case=%s live=%zu bytes=%zu\n",
                  load_case == NULL ? "<null>" : load_case->id,
                  tracker.live, tracker.live_bytes);
    ok = 0;
  }
  return ok;
}

static int load_check_loaded_refusal(const uint8_t *fixture,
                                     size_t fixture_extent,
                                     const lf_load_case *load_case) {
  load_allocation_tracker subject_tracker = {0};
  load_allocation_tracker control_tracker = {0};
  load_allocation_tracker subject_before;
  lf_instance *subject = NULL;
  lf_instance *control = NULL;
  _Alignas(max_align_t)
      uint8_t candidate[LOAD_GUARD_BYTES +
                        LF_NESTURBATOR_SAVE_FIXTURE_TOTAL_BYTES +
                        LOAD_GUARD_BYTES];
  uint8_t configuration[LOAD_GUARD_BYTES +
                        LF_SAVE_ORACLE_CONFIGURATION_IDENTITY_CAPACITY +
                        LOAD_GUARD_BYTES];
  guarded_request request;
  guarded_request request_before;
  guarded_result result;
  guarded_result result_before;
  lf_load_result initial_subject = {.struct_size = sizeof(initial_subject)};
  lf_load_result initial_control = {.struct_size = sizeof(initial_control)};
  lf_profile profile_before;
  lf_profile profile_after;
  media_observation media_before;
  media_observation subject_media;
  media_observation control_media;
  lf_status status = LF_INVALID_ARGUMENT;
  size_t index = 0U;
  uint64_t candidate_hash_before = 0U;
  char configuration_before[sizeof(configuration)];
  int ok = 0;

  if (fixture == NULL || load_case == NULL ||
      fixture_extent != LF_NESTURBATOR_SAVE_FIXTURE_TOTAL_BYTES ||
      !lf_nesturbator_save_fixture_sha256(fixture, fixture_extent,
                                          (uint8_t[32]){0}) ||
      !load_tracker_create(&subject_tracker, &subject) ||
      !load_tracker_create(&control_tracker, &control) ||
      !load_instance_fixture(subject, fixture, fixture_extent,
                             &initial_subject) ||
      !load_instance_fixture(control, fixture, fixture_extent,
                             &initial_control)) {
    (void)fprintf(stderr, "load_corpus: loaded_setup_failed case=%s\n",
                  load_case == NULL ? "<null>" : load_case->id);
    goto cleanup;
  }
  for (index = 0U; index < 3U; ++index) {
    const uint32_t buttons = index == 1U ? 1U : 0U;
    if (!load_advance_pair_frame(subject, control, buttons, 1,
                                 buttons, 0U,
                                 load_case->id, NULL)) {
      goto cleanup;
    }
  }
  if (!load_copy_media(subject, &media_before) ||
      !load_copy_media(control, &control_media) ||
      !load_media_equal(&media_before, &control_media) ||
      !lf_save_oracle_matches(media_before.bytes, media_before.extent_bytes,
                              LF_SAVE_ORACLE_COMMITTED_BYTE) ||
      !load_snapshot_profile(&profile_before) ||
      media_before.generation == 0U) {
    (void)fprintf(stderr, "load_corpus: loaded_baseline_failed case=%s\n",
                  load_case->id);
    goto cleanup;
  }
  if (lf_set_input(subject, &(lf_input){
                       .struct_size = sizeof(lf_input),
                       .buttons = UINT32_C(0x0001),
                   }) != LF_OK ||
      lf_set_input(control, &(lf_input){
                       .struct_size = sizeof(lf_input),
                       .buttons = UINT32_C(0x0001),
                   }) != LF_OK) {
    goto cleanup;
  }
  memset(candidate, 0xa5, sizeof(candidate));
  memcpy(candidate + LOAD_GUARD_BYTES, fixture, fixture_extent);
  memcpy(candidate + LOAD_GUARD_BYTES, load_case->header,
         sizeof(load_case->header));
  memset(configuration, 0xa5, sizeof(configuration));
  memcpy(configuration + LOAD_GUARD_BYTES,
         LF_SAVE_ORACLE_CONFIGURATION_IDENTITY,
         sizeof(LF_SAVE_ORACLE_CONFIGURATION_IDENTITY));
  memset(&request, 0xa5, sizeof(request));
  request.value.struct_size = sizeof(request.value);
  request.value.content_data = candidate + LOAD_GUARD_BYTES;
  request.value.content_size_bytes = load_case->actual_extent;
  request.value.configuration_id =
      (const char *)(const void *)(configuration + LOAD_GUARD_BYTES);
  memcpy(&request_before, &request, sizeof(request));
  memcpy(configuration_before, configuration, sizeof(configuration));
  candidate_hash_before =
      load_hash_bytes(candidate + LOAD_GUARD_BYTES, fixture_extent);
  memset(&result, 0xa5, sizeof(result));
  result.value.struct_size = sizeof(result.value);
  result.value.loaded = UINT32_MAX;
  result.value.content_size_bytes = SIZE_MAX;
  result.value.effective_configuration_id = "sentinel";
  memcpy(&result_before, &result, sizeof(result));
  subject_before = subject_tracker;
  status = lf_load(subject, &request.value, &result.value);
  if (!check_case_status(load_case, load_case->expected_status, status)) {
    goto cleanup;
  }
  if (!load_result_is_active(&result.value, fixture_extent)) {
    (void)fprintf(stderr,
                  "load_corpus: loaded_refusal case=%s expected=%s actual=%s\n",
                  load_case->id, load_status_name(load_case->expected_status),
                  load_status_name(status));
    goto cleanup;
  }
  for (index = 0U; index < LOAD_GUARD_BYTES; ++index) {
    if (request.before[index] != 0xa5U || request.after[index] != 0xa5U ||
        result.before[index] != 0xa5U || result.after[index] != 0xa5U ||
        configuration[index] != 0xa5U ||
        configuration[sizeof(configuration) - LOAD_GUARD_BYTES + index] !=
            0xa5U) {
      (void)fprintf(stderr, "load_corpus: record_canary case=%s\n",
                    load_case->id);
      goto cleanup;
    }
  }
  if (memcmp(configuration, configuration_before,
             sizeof(configuration)) != 0 ||
      memcmp(&request, &request_before, sizeof(request)) != 0 ||
      load_hash_bytes(candidate + LOAD_GUARD_BYTES, fixture_extent) !=
          candidate_hash_before ||
      !load_has_byte_guard(candidate, fixture_extent, 0xa5U) ||
      !load_snapshot_profile(&profile_after) ||
      !load_same_profile(&profile_before, &profile_after) ||
      !load_copy_media(subject, &subject_media) ||
      !load_copy_media(control, &control_media) ||
      !compare_refused_observation(load_case->id, &media_before,
                                   &subject_media) ||
      !compare_refused_observation(load_case->id, &media_before,
                                   &control_media) ||
      !load_tracker_same_live_set(&subject_before, &subject_tracker) ||
      subject_tracker.invalid_frees != subject_before.invalid_frees ||
      subject_tracker.bound_exceeded != subject_before.bound_exceeded) {
    (void)fprintf(stderr,
                  "load_corpus: immediate_preservation_mismatch case=%s field=media_metadata_records_or_ownership\n",
                  load_case->id);
    goto cleanup;
  }
  if (memcmp(result.before, result_before.before, LOAD_GUARD_BYTES) != 0 ||
      memcmp(result.after, result_before.after, LOAD_GUARD_BYTES) != 0) {
    (void)fprintf(stderr, "load_corpus: result_canary case=%s\n",
                  load_case->id);
    goto cleanup;
  }
  if (!load_advance_pair_frame(subject, control, 0U, 0,
                               UINT32_C(0x0001), 1U, load_case->id, NULL) ||
      !load_advance_pair_frame(subject, control, UINT32_C(0x0100), 1,
                               UINT32_C(0x0100), 2U, load_case->id, NULL) ||
      !load_advance_pair_frame(subject, control, 0U, 1, 0U, 3U,
                               load_case->id, NULL)) {
    goto cleanup;
  }
  ok = 1;

cleanup:
  if (subject != NULL && lf_destroy(&subject) != LF_OK) {
    ok = 0;
  }
  if (control != NULL && lf_destroy(&control) != LF_OK) {
    ok = 0;
  }
  if (!load_tracker_balanced(&subject_tracker) ||
      !load_tracker_balanced(&control_tracker)) {
    (void)fprintf(stderr,
                  "load_corpus: loaded_cleanup case=%s subject_live=%zu control_live=%zu\n",
                  load_case == NULL ? "<null>" : load_case->id,
                  subject_tracker.live, control_tracker.live);
    ok = 0;
  }
  return ok;
}

static size_t load_struct_size_value(size_t exact,
                                     lf_load_size_variant variant) {
  switch (variant) {
    case LF_LOAD_SIZE_EXACT:
      return exact;
    case LF_LOAD_SIZE_ZERO:
      return 0U;
    case LF_LOAD_SIZE_SHORT:
      return exact - 1U;
    case LF_LOAD_SIZE_LONG:
      return exact + 1U;
  }
  return SIZE_MAX;
}

static int load_case_is_preflight(const lf_load_case *load_case) {
  return load_case != NULL &&
         (load_case->request_variant != LF_LOAD_REQUEST_VALID ||
          load_case->result_variant != LF_LOAD_RESULT_VALID ||
          load_case->content_pointer_null != 0U ||
          load_case->actual_extent == 0U ||
          load_case->actual_extent > LOAD_MAX_REQUEST_BYTES ||
          (load_case->configuration_id != NULL &&
           strcmp(load_case->configuration_id,
                  LF_SAVE_ORACLE_CONFIGURATION_IDENTITY) != 0));
}

static int load_build_case_records(
    const lf_load_case *load_case, load_content_span *span,
    guarded_request *request, guarded_result *result,
    uint8_t configuration[LOAD_CONFIG_STORAGE_BYTES],
    guarded_request *request_before, guarded_result *result_before,
    uint8_t configuration_before[LOAD_CONFIG_STORAGE_BYTES],
    const lf_load_request **request_pointer,
    lf_load_result **result_pointer) {
  const size_t config_capacity = (size_t)LF_SAVE_ORACLE_CONFIGURATION_IDENTITY_CAPACITY;
  size_t config_bytes = 0U;
  if (load_case == NULL || span == NULL || request == NULL || result == NULL ||
      configuration == NULL || request_before == NULL || result_before == NULL ||
      configuration_before == NULL || request_pointer == NULL ||
      result_pointer == NULL) {
    return 0;
  }
  memset(configuration, 0xa5, LOAD_CONFIG_STORAGE_BYTES);
  if (load_case->configuration_id != NULL) {
    config_bytes = strlen(load_case->configuration_id) + 1U;
    if (config_bytes > config_capacity) {
      return 0;
    }
    memcpy(configuration + LOAD_GUARD_BYTES, load_case->configuration_id,
           config_bytes);
  }
  memset(request, 0xa5, sizeof(*request));
  request->value.struct_size =
      load_struct_size_value(sizeof(request->value),
                             load_case->request_size_variant);
  request->value.content_data =
      load_case->content_pointer_null != 0U ? NULL : span->bytes;
  request->value.content_size_bytes = load_case->actual_extent;
  request->value.configuration_id =
      load_case->configuration_id == NULL
          ? NULL
          : (const char *)(const void *)(configuration + LOAD_GUARD_BYTES);
  *request_pointer =
      load_case->request_variant == LF_LOAD_REQUEST_NULL ? NULL : &request->value;

  memset(result, 0xa5, sizeof(*result));
  result->value.struct_size =
      load_struct_size_value(sizeof(result->value),
                             load_case->result_size_variant);
  result->value.loaded = UINT32_MAX;
  result->value.content_size_bytes = SIZE_MAX;
  result->value.effective_configuration_id = "sentinel";
  *result_pointer =
      load_case->result_variant == LF_LOAD_RESULT_NULL ? NULL : &result->value;
  memcpy(request_before, request, sizeof(*request));
  memcpy(result_before, result, sizeof(*result));
  memcpy(configuration_before, configuration, LOAD_CONFIG_STORAGE_BYTES);
  return 1;
}

static int load_case_io_unchanged(
    const lf_load_case *load_case, const load_content_span *span,
    const guarded_request *request, const guarded_result *result,
    const uint8_t configuration[LOAD_CONFIG_STORAGE_BYTES],
    const guarded_request *request_before,
    const guarded_result *result_before,
    const uint8_t configuration_before[LOAD_CONFIG_STORAGE_BYTES]) {
  if (load_case == NULL || span == NULL || request == NULL || result == NULL ||
      configuration == NULL || request_before == NULL || result_before == NULL ||
      configuration_before == NULL ||
      memcmp(request, request_before, sizeof(*request)) != 0 ||
      memcmp(configuration, configuration_before, LOAD_CONFIG_STORAGE_BYTES) !=
          0 ||
      !load_content_span_unchanged(span, load_case->header,
                                   load_case->actual_extent) ||
      !load_has_byte_guard((const uint8_t *)(const void *)request,
                           sizeof(request->value), UINT8_C(0xa5))) {
    return 0;
  }
  if (load_case->result_variant == LF_LOAD_RESULT_NULL ||
      load_case->result_variant == LF_LOAD_RESULT_BAD_SIZE) {
    return memcmp(result, result_before, sizeof(*result)) == 0;
  }
  return load_has_byte_guard((const uint8_t *)(const void *)result,
                             sizeof(result->value), UINT8_C(0xa5));
}

static int load_case_result_matches(const lf_load_case *load_case,
                                    const lf_load_result *result,
                                    uint32_t loaded,
                                    size_t content_extent) {
  if (load_case == NULL || load_case->result_variant != LF_LOAD_RESULT_VALID) {
    return 1;
  }
  return loaded == 0U ? load_result_is_unloaded(result)
                      : load_result_is_active(result, content_extent);
}

static int load_unloaded_advance_rejected(lf_instance *instance,
                                          const char *case_id) {
  _Alignas(max_align_t)
      uint8_t video[LOAD_GUARD_BYTES + LOAD_VIDEO_EXTENT + LOAD_GUARD_BYTES];
  _Alignas(max_align_t)
      uint8_t audio[LOAD_GUARD_BYTES + LOAD_AUDIO_STORAGE_BYTES +
                    LOAD_GUARD_BYTES];
  uint8_t video_before[sizeof(video)];
  uint8_t audio_before[sizeof(audio)];
  lf_run_request request = {
      .struct_size = sizeof(request), .work_units = 1U,
      .video_data = video + LOAD_GUARD_BYTES,
      .video_capacity_bytes = LOAD_VIDEO_EXTENT,
      .video_stride_bytes = LOAD_VIDEO_STRIDE,
      .audio_data = (int16_t *)(void *)(audio + LOAD_GUARD_BYTES),
      .audio_capacity_samples = LOAD_AUDIO_CAPACITY,
  };
  lf_run_result result = {.struct_size = sizeof(result)};
  lf_status status = LF_INVALID_ARGUMENT;
  if (instance == NULL) {
    return 0;
  }
  memset(video, 0x5a, sizeof(video));
  memset(audio, 0x5a, sizeof(audio));
  memcpy(video_before, video, sizeof(video));
  memcpy(audio_before, audio, sizeof(audio));
  status = lf_advance(instance, &request, &result);
  if (status != LF_INVALID_ARGUMENT ||
      memcmp(video, video_before, sizeof(video)) != 0 ||
      memcmp(audio, audio_before, sizeof(audio)) != 0) {
    (void)fprintf(stderr,
                  "load_corpus: unloaded_advance_changed_output case=%s\n",
                  case_id);
    return 0;
  }
  return 1;
}

static int load_run_unloaded_case(const lf_load_case *load_case,
                                  load_content_span *span,
                                  lf_status *actual_status) {
  load_allocation_tracker tracker = {0};
  load_allocation_tracker tracker_before;
  lf_instance *instance = NULL;
  guarded_request request;
  guarded_request request_before;
  guarded_result result;
  guarded_result result_before;
  uint8_t configuration[LOAD_CONFIG_STORAGE_BYTES];
  uint8_t configuration_before[LOAD_CONFIG_STORAGE_BYTES];
  const lf_load_request *request_pointer = NULL;
  lf_load_result *result_pointer = NULL;
  size_t calls_before = 0U;
  lf_status status = LF_INVALID_ARGUMENT;
  int ok = 0;

  if (load_case == NULL || span == NULL ||
      !load_content_span_unchanged(span, load_case->header,
                                   load_case->actual_extent)) {
    return 0;
  }
  if (load_case->instance_null == 0U &&
      !load_tracker_create(&tracker, &instance)) {
    (void)fprintf(stderr, "load_corpus: unloaded_instance_failed case=%s\n",
                  load_case->id);
    goto cleanup;
  }
  if (!load_build_case_records(load_case, span, &request, &result,
                              configuration, &request_before, &result_before,
                              configuration_before, &request_pointer,
                              &result_pointer)) {
    goto cleanup;
  }
  tracker_before = tracker;
  calls_before = tracker.calls;
  status = lf_load(instance, request_pointer, result_pointer);
  if (actual_status != NULL) {
    *actual_status = status;
  }
  if (!check_case_status(load_case, load_case->expected_status, status)) {
    goto cleanup;
  }
  if (!load_case_result_matches(load_case, result_pointer, 0U, 0U) ||
      !load_case_io_unchanged(load_case, span, &request, &result,
                              configuration, &request_before, &result_before,
                              configuration_before) ||
      (instance != NULL &&
       (!load_tracker_same_live_set(&tracker_before, &tracker) ||
        tracker.invalid_frees != tracker_before.invalid_frees ||
        tracker.bound_exceeded != tracker_before.bound_exceeded ||
        (load_case_is_preflight(load_case) && tracker.calls != calls_before)))) {
    (void)fprintf(stderr,
                  "load_corpus: unloaded_case_postcondition_mismatch case=%s\n",
                  load_case->id);
    goto cleanup;
  }
  if (instance != NULL &&
      !load_unloaded_advance_rejected(instance, load_case->id)) {
    goto cleanup;
  }
  ok = 1;

cleanup:
  if (instance != NULL && lf_destroy(&instance) != LF_OK) {
    ok = 0;
  }
  if (load_case != NULL && load_case->instance_null == 0U &&
      !load_tracker_balanced(&tracker)) {
    (void)fprintf(stderr, "load_corpus: unloaded_case_cleanup case=%s\n",
                  load_case->id);
    ok = 0;
  }
  return ok;
}

static int load_candidate_calls_match(
    const load_allocation_tracker *tracker, size_t fail_ordinal,
    size_t expected_count, const size_t *expected_sizes) {
  size_t index = 0U;
  if (tracker == NULL || expected_sizes == NULL || fail_ordinal == 0U ||
      fail_ordinal > expected_count ||
      tracker->candidate_failure_reached != 1U ||
      tracker->candidate_call_count < fail_ordinal ||
      tracker->candidate_call_count > LF_LOAD_CORPUS_MAX_CANDIDATE_CALLS) {
    return 0;
  }
  for (index = 0U; index < fail_ordinal; ++index) {
    if (tracker->candidate_call_sizes[index] != expected_sizes[index] ||
        tracker->candidate_call_sizes[index] == 0U ||
        tracker->candidate_call_sizes[index] >
            LF_LOAD_CORPUS_MAX_SINGLE_ALLOCATION) {
      return 0;
    }
  }
  return 1;
}

typedef struct allocation_refusal_observation {
  size_t live_before;
  size_t live_after;
  int destroy_balanced;
} allocation_refusal_observation;

static int load_run_candidate_unloaded_failure(
    const lf_load_case *load_case, load_content_span *span,
    const char *layout_id, size_t fail_ordinal, size_t expected_count,
    const size_t *expected_sizes) {
  load_allocation_tracker tracker = {0};
  load_allocation_tracker tracker_before;
  lf_instance *instance = NULL;
  guarded_request request;
  guarded_request request_before;
  guarded_result result;
  guarded_result result_before;
  uint8_t configuration[LOAD_CONFIG_STORAGE_BYTES];
  uint8_t configuration_before[LOAD_CONFIG_STORAGE_BYTES];
  const lf_load_request *request_pointer = NULL;
  lf_load_result *result_pointer = NULL;
  allocation_refusal_observation observation = {0};
  lf_status status = LF_INVALID_ARGUMENT;
  int ok = 0;

  if (load_case == NULL || span == NULL || layout_id == NULL ||
      fail_ordinal == 0U || expected_sizes == NULL ||
      !load_content_span_unchanged(span, load_case->header,
                                   load_case->actual_extent) ||
      !load_tracker_create(&tracker, &instance) ||
      !load_build_case_records(load_case, span, &request, &result,
                               configuration, &request_before, &result_before,
                               configuration_before, &request_pointer,
                               &result_pointer)) {
    (void)fprintf(stderr,
                  "load_corpus: allocation_unloaded_setup_failed layout=%s case=%s\n",
                  layout_id, load_case == NULL ? "<null>" : load_case->id);
    goto cleanup;
  }
  tracker_before = tracker;
  observation.live_before = tracker.live;
  load_tracker_begin_candidate(&tracker, fail_ordinal);
  status = lf_load(instance, request_pointer, result_pointer);
  load_tracker_end_candidate(&tracker);
  observation.live_after = tracker.live;
  if (!check_case_status(load_case, LF_RESOURCE_EXHAUSTED, status) ||
      !load_result_is_unloaded(result_pointer) ||
      !load_case_io_unchanged(load_case, span, &request, &result,
                              configuration, &request_before, &result_before,
                              configuration_before) ||
      !load_tracker_same_live_set(&tracker_before, &tracker) ||
      tracker.invalid_frees != tracker_before.invalid_frees ||
      tracker.bound_exceeded != tracker_before.bound_exceeded ||
      !load_candidate_calls_match(&tracker, fail_ordinal, expected_count,
                                  expected_sizes)) {
    if (status == LF_RESOURCE_EXHAUSTED) {
      (void)fprintf(stderr,
                    "load_corpus: allocation_unloaded_mismatch layout=%s case=%s ordinal=%zu calls=%zu reached=%u\n",
                    layout_id, load_case->id, fail_ordinal,
                    tracker.candidate_call_count,
                    (unsigned int)tracker.candidate_failure_reached);
    }
    goto cleanup;
  }
  if (!load_unloaded_advance_rejected(instance, load_case->id)) {
    goto cleanup;
  }
  ok = 1;

cleanup:
  if (instance != NULL && lf_destroy(&instance) != LF_OK) {
    ok = 0;
  }
  observation.destroy_balanced = load_tracker_balanced(&tracker);
  if (!observation.destroy_balanced) {
    ok = 0;
  }
  if (ok != 0) {
    (void)printf(
        "allocation_observation: layout_id=%s case=%s observed_count=%zu "
        "failure_ordinal=%zu requested_bytes=%zu history=unloaded "
        "live_before=%zu live_after=%zu destroy_balance=complete\n",
        layout_id, load_case->id, expected_count, fail_ordinal,
        expected_sizes[fail_ordinal - 1U], observation.live_before,
        observation.live_after);
  }
  return ok;
}

static int load_run_accepted_case(const lf_load_case *load_case,
                                  load_content_span *span,
                                  lf_status *actual_status) {
  load_allocation_tracker tracker = {0};
  lf_instance *instance = NULL;
  guarded_request request;
  guarded_request request_before;
  guarded_result result;
  guarded_result result_before;
  uint8_t configuration[LOAD_CONFIG_STORAGE_BYTES];
  uint8_t configuration_before[LOAD_CONFIG_STORAGE_BYTES];
  const lf_load_request *request_pointer = NULL;
  lf_load_result *result_pointer = NULL;
  lf_status status = LF_INVALID_ARGUMENT;
  int ok = 0;

  if (load_case == NULL || span == NULL ||
      load_case->expected_status != LF_OK || load_case->executable != 0U ||
      !load_tracker_create(&tracker, &instance) ||
      !load_build_case_records(load_case, span, &request, &result,
                               configuration, &request_before, &result_before,
                               configuration_before, &request_pointer,
                               &result_pointer)) {
    (void)fprintf(stderr, "load_corpus: accepted_case_setup_failed\n");
    goto cleanup;
  }
  status = lf_load(instance, request_pointer, result_pointer);
  if (actual_status != NULL) {
    *actual_status = status;
  }
  if (!check_case_status(load_case, LF_OK, status) ||
      !load_case_result_matches(load_case, result_pointer, 1U,
                                load_case->actual_extent) ||
      !load_case_io_unchanged(load_case, span, &request, &result,
                              configuration, &request_before, &result_before,
                              configuration_before)) {
    (void)fprintf(stderr,
                  "load_corpus: accepted_case_mismatch case=%s expected=LF_OK actual=%s\n",
                  load_case->id, load_status_name(status));
    goto cleanup;
  }
  ok = 1;

cleanup:
  if (instance != NULL && lf_destroy(&instance) != LF_OK) {
    ok = 0;
  }
  if (!load_tracker_balanced(&tracker)) {
    (void)fprintf(stderr, "load_corpus: accepted_case_cleanup case=%s\n",
                  load_case == NULL ? "<null>" : load_case->id);
    ok = 0;
  }
  return ok;
}

static int load_run_loaded_refusal_case(const lf_load_case *load_case,
                                        load_content_span *span,
                                        lf_status *actual_status,
                                        const char *layout_id,
                                        size_t fail_ordinal,
                                        size_t expected_count,
                                        const size_t *expected_sizes,
                                        int diverge_state) {
  load_allocation_tracker subject_tracker = {0};
  load_allocation_tracker control_tracker = {0};
  load_allocation_tracker subject_before;
  lf_instance *subject = NULL;
  lf_instance *control = NULL;
  uint8_t fixture[LF_NESTURBATOR_SAVE_FIXTURE_TOTAL_BYTES];
  uint8_t fixture_digest[32];
  size_t fixture_extent = 0U;
  guarded_request request;
  guarded_request request_before;
  guarded_result result;
  guarded_result result_before;
  uint8_t configuration[LOAD_CONFIG_STORAGE_BYTES];
  uint8_t configuration_before[LOAD_CONFIG_STORAGE_BYTES];
  const lf_load_request *request_pointer = NULL;
  lf_load_result *result_pointer = NULL;
  lf_load_result initial_subject = {.struct_size = sizeof(initial_subject)};
  lf_load_result initial_control = {.struct_size = sizeof(initial_control)};
  lf_profile profile_before;
  lf_profile profile_after;
  media_observation media_before;
  media_observation subject_media;
  media_observation control_media;
  lf_status status = LF_INVALID_ARGUMENT;
  const lf_status expected_status =
      fail_ordinal == 0U ? load_case == NULL ? LF_INVALID_ARGUMENT
                                            : load_case->expected_status
                         : LF_RESOURCE_EXHAUSTED;
  size_t index = 0U;
  size_t calls_before = 0U;
  size_t live_after_refusal = 0U;
  int ok = 0;

  if (load_case == NULL || span == NULL ||
      (load_case->expected_status == LF_OK && fail_ordinal == 0U) ||
      load_case->instance_null != 0U ||
      (fail_ordinal != 0U && expected_sizes == NULL) ||
      !load_content_span_unchanged(span, load_case->header,
                                   load_case->actual_extent)) {
    return 0;
  }
  fixture_extent =
      lf_build_nesturbator_save_fixture(fixture, sizeof(fixture));
  if (fixture_extent != sizeof(fixture) ||
      !lf_nesturbator_save_fixture_sha256(fixture, fixture_extent,
                                          fixture_digest) ||
      !lf_save_oracle_sha256_matches(fixture_digest, sizeof(fixture_digest)) ||
      !load_tracker_create(&subject_tracker, &subject) ||
      !load_tracker_create(&control_tracker, &control) ||
      !load_instance_fixture(subject, fixture, fixture_extent,
                             &initial_subject) ||
      !load_instance_fixture(control, fixture, fixture_extent,
                             &initial_control)) {
    (void)fprintf(stderr, "load_corpus: loaded_setup_failed case=%s\n",
                  load_case->id);
    goto cleanup;
  }
  for (index = 0U; index < 3U; ++index) {
    const uint32_t buttons = index == 1U ? UINT32_C(0x0001) : 0U;
    if (!load_advance_pair_frame(subject, control, buttons, 1, buttons, 0U,
                                 load_case->id, NULL)) {
      goto cleanup;
    }
  }
  if (!load_copy_media(subject, &media_before) ||
      !load_copy_media(control, &control_media) ||
      !load_media_equal(&media_before, &control_media) ||
      strcmp(media_before.identity, LF_SAVE_ORACLE_MEDIA_IDENTITY) != 0 ||
      media_before.extent_bytes != LF_SAVE_ORACLE_EXTENT_BYTES ||
      media_before.generation == 0U ||
      !lf_save_oracle_matches(media_before.bytes, media_before.extent_bytes,
                              LF_SAVE_ORACLE_COMMITTED_BYTE) ||
      !load_snapshot_profile(&profile_before)) {
    (void)fprintf(stderr, "load_corpus: loaded_baseline_failed case=%s\n",
                  load_case->id);
    goto cleanup;
  }
  if (lf_set_input(subject, &(lf_input){
                       .struct_size = sizeof(lf_input),
                       .buttons = UINT32_C(0x0001),
                   }) != LF_OK ||
      lf_set_input(control, &(lf_input){
                       .struct_size = sizeof(lf_input),
                       .buttons = UINT32_C(0x0001),
                   }) != LF_OK ||
      !load_build_case_records(load_case, span, &request, &result,
                               configuration, &request_before, &result_before,
                               configuration_before, &request_pointer,
                               &result_pointer)) {
    (void)fprintf(stderr, "load_corpus: loaded_request_setup_failed case=%s\n",
                  load_case->id);
    goto cleanup;
  }
  subject_before = subject_tracker;
  calls_before = subject_tracker.calls;
  if (fail_ordinal != 0U) {
    load_tracker_begin_candidate(&subject_tracker, fail_ordinal);
  }
  status = lf_load(subject, request_pointer, result_pointer);
  live_after_refusal = subject_tracker.live;
  if (fail_ordinal != 0U) {
    load_tracker_end_candidate(&subject_tracker);
  }
  if (actual_status != NULL) {
    *actual_status = status;
  }
  if (!check_case_status(load_case, expected_status, status)) {
    goto cleanup;
  }
  if (!load_case_result_matches(load_case, result_pointer, 1U,
                                fixture_extent) ||
      !load_case_io_unchanged(load_case, span, &request, &result,
                              configuration, &request_before, &result_before,
                              configuration_before)) {
    (void)fprintf(stderr,
                  "load_corpus: loaded_case_postcondition_mismatch case=%s\n",
                  load_case->id);
    goto cleanup;
  }
  if (diverge_state != 0 &&
      !load_advance_single_frame(subject, load_case->id)) {
    goto cleanup;
  }
  if (!load_snapshot_profile(&profile_after) ||
      !load_same_profile(&profile_before, &profile_after) ||
      !load_copy_media(subject, &subject_media) ||
      !load_copy_media(control, &control_media) ||
      !compare_refused_observation(load_case->id, &media_before,
                                   &subject_media) ||
      !compare_refused_observation(load_case->id, &media_before,
                                   &control_media) ||
      !load_tracker_same_live_set(&subject_before, &subject_tracker) ||
      subject_tracker.invalid_frees != subject_before.invalid_frees ||
      subject_tracker.bound_exceeded != subject_before.bound_exceeded ||
      (fail_ordinal != 0U &&
       !load_candidate_calls_match(&subject_tracker, fail_ordinal,
                                   expected_count, expected_sizes)) ||
      (load_case_is_preflight(load_case) &&
       subject_tracker.calls != calls_before)) {
    (void)fprintf(stderr,
                  "load_corpus: loaded_case_mismatch case=%s expected=%s actual=%s\n",
                  load_case->id, load_status_name(expected_status),
                  load_status_name(status));
    goto cleanup;
  }
  if (!load_advance_pair_frame(subject, control, 0U, 0,
                               UINT32_C(0x0001), 1U, load_case->id, NULL) ||
      !load_advance_pair_frame(subject, control, UINT32_C(0x0100), 1,
                               UINT32_C(0x0100), 2U, load_case->id, NULL) ||
      !load_advance_pair_frame(subject, control, 0U, 1, 0U, 3U,
                               load_case->id, NULL)) {
    goto cleanup;
  }
  ok = 1;

cleanup:
  if (subject != NULL && lf_destroy(&subject) != LF_OK) {
    ok = 0;
  }
  if (control != NULL && lf_destroy(&control) != LF_OK) {
    ok = 0;
  }
  if (!load_tracker_balanced(&subject_tracker) ||
      !load_tracker_balanced(&control_tracker)) {
    (void)fprintf(stderr,
                  "load_corpus: loaded_case_cleanup case=%s subject_live=%zu control_live=%zu\n",
                  load_case == NULL ? "<null>" : load_case->id,
                  subject_tracker.live, control_tracker.live);
    ok = 0;
  }
  if (ok != 0 && fail_ordinal != 0U) {
    (void)printf(
        "allocation_observation: layout_id=%s case=%s observed_count=%zu "
        "failure_ordinal=%zu requested_bytes=%zu history=loaded "
        "live_before=%zu live_after=%zu destroy_balance=complete\n",
        layout_id == NULL ? load_case->id : layout_id, load_case->id,
        expected_count, fail_ordinal,
        expected_sizes[fail_ordinal - 1U], subject_before.live,
        live_after_refusal);
  }
  return ok;
}

static int load_expected_status_is_known(lf_status status) {
  return status == LF_OK || status == LF_INVALID_ARGUMENT ||
         status == LF_UNSUPPORTED || status == LF_LIMIT_EXCEEDED ||
         status == LF_BUFFER_TOO_SMALL || status == LF_RESOURCE_EXHAUSTED;
}

typedef struct load_expected_row {
  const char *prefix;
  uint8_t expected_count;
} load_expected_row;

static const load_expected_row load_expected_rows[] = {
    {"A01", 4U}, {"A02", 4U}, {"A03", 3U}, {"A04", 4U},
    {"A05", 3U}, {"A06", 5U}, {"H01", 4U}, {"H02", 3U},
    {"H03", 3U}, {"H04", 3U}, {"H05", 6U}, {"H06", 4U},
    {"H07", 8U}, {"H08", 10U}, {"H09", 2U}, {"S01", 4U},
    {"S02", 3U}, {"S03", 3U}, {"S04", 2U}, {"S05", 6U},
    {"S06", 5U}, {"S07", 1U}, {"S08", 4U}, {"S09", 2U},
    {"E01", 9U}, {"E02", 8U}, {"E03", 2U}, {"E04", 3U},
    {"E05", 1U}, {"X01", 2U}, {"X02", 2U}, {"X03", 2U},
    {"X04", 3U}, {"B00", 4U}, {"B01", 7U}, {"B20", 6U},
    {"B21", 6U}, {"B30", 6U}, {"B31", 7U}, {"B70", 3U},
    {"B71", 7U}, {"B10", 11U}, {"B11", 9U}, {"B12", 9U},
    {"B13", 10U}, {"B40", 8U}, {"B41", 4U}, {"B42", 9U},
    {"B43", 8U}, {"B50", 4U}, {"R01", 8U}, {"R02", 8U},
    {"R03", 8U}, {"R04", 8U}, {"R05", 5U}, {"R06", 4U},
    {"R07", 2U}, {"R08", 8U}, {"I01", 4U}, {"I02", 2U},
    {"I03", 4U},
};

static int validate_case_inventory(void) {
  const size_t admission_count = sizeof(lf_load_admission_cases) /
                                 sizeof(lf_load_admission_cases[0]);
  const size_t layout_count = sizeof(lf_load_layout_cases) /
                              sizeof(lf_load_layout_cases[0]);
  const size_t board_ram_count = sizeof(lf_load_board_ram_cases) /
                                 sizeof(lf_load_board_ram_cases[0]);
  const size_t count = admission_count + layout_count + board_ram_count;
  const size_t expected_row_count =
      sizeof(load_expected_rows) / sizeof(load_expected_rows[0]);
  uint16_t observed_ids[sizeof(load_expected_rows) /
                        sizeof(load_expected_rows[0])] = {0U};
  size_t expected_total = 0U;
  size_t left = 0U;
  size_t row = 0U;
  if (admission_count != LF_LOAD_ADMISSION_CASE_COUNT ||
      layout_count != LF_LOAD_LAYOUT_CASE_COUNT ||
      board_ram_count != LF_LOAD_BOARD_RAM_CASE_COUNT ||
      count != LF_LOAD_CLASSIFICATION_CASE_COUNT ||
      count > LF_LOAD_CORPUS_MAX_DESCRIPTORS) {
    (void)fprintf(stderr,
                  "load_corpus: inventory_count=%zu expected=%u ceiling=%u\n",
                  count, (unsigned int)LF_LOAD_CLASSIFICATION_CASE_COUNT,
                  (unsigned int)LF_LOAD_CORPUS_MAX_DESCRIPTORS);
    return 0;
  }
  for (row = 0U; row < expected_row_count; ++row) {
    expected_total += load_expected_rows[row].expected_count;
  }
  if (expected_total != count) {
    (void)fprintf(stderr,
                  "load_corpus: row_inventory_count=%zu expected=%zu\n",
                  expected_total, count);
    return 0;
  }
  for (left = 0U; left < count; ++left) {
    const char *left_id = NULL;
    lf_status left_status = LF_INVALID_ARGUMENT;
    size_t row_index = 0U;
    unsigned int ordinal = 0U;
    uint16_t id_bit = 0U;
    if (left < admission_count) {
      left_id = lf_load_admission_cases[left].id;
      left_status = lf_load_admission_cases[left].expected_status;
    } else if (left < admission_count + layout_count) {
      const size_t layout_index = left - admission_count;
      left_id = lf_load_layout_cases[layout_index].id;
      left_status = lf_load_layout_cases[layout_index].expected_status;
    } else {
      const size_t board_ram_index = left - admission_count - layout_count;
      left_id = lf_load_board_ram_cases[board_ram_index].id;
      left_status = lf_load_board_ram_cases[board_ram_index].expected_status;
    }
    if (left_id == NULL || left_id[0] == '\0' ||
        !load_expected_status_is_known(left_status)) {
      (void)fprintf(stderr, "load_corpus: invalid_inventory_record index=%zu\n",
                    left);
      return 0;
    }
    if (strlen(left_id) != 6U || left_id[3] != '-' ||
        left_id[4] < '0' || left_id[4] > '9' ||
        left_id[5] < '0' || left_id[5] > '9') {
      (void)fprintf(stderr, "load_corpus: malformed_case_id id=%s\n", left_id);
      return 0;
    }
    ordinal = (unsigned int)(left_id[4] - '0') * 10U +
              (unsigned int)(left_id[5] - '0');
    for (row_index = 0U; row_index < expected_row_count; ++row_index) {
      if (strncmp(left_id, load_expected_rows[row_index].prefix, 3U) == 0) {
        break;
      }
    }
    if (row_index == expected_row_count ||
        ordinal == 0U ||
        ordinal > load_expected_rows[row_index].expected_count) {
      (void)fprintf(stderr, "load_corpus: unexpected_case_id id=%s\n", left_id);
      return 0;
    }
    id_bit = (uint16_t)(UINT16_C(1) << (ordinal - 1U));
    if ((observed_ids[row_index] & id_bit) != 0U) {
      (void)fprintf(stderr, "load_corpus: duplicate_case id=%s\n", left_id);
      return 0;
    }
    observed_ids[row_index] |= id_bit;
  }
  for (row = 0U; row < expected_row_count; ++row) {
    const uint16_t complete_mask =
        (uint16_t)((UINT16_C(1) << load_expected_rows[row].expected_count) -
                   UINT16_C(1));
    if (observed_ids[row] != complete_mask) {
      (void)fprintf(stderr,
                    "load_corpus: incomplete_case_row row=%s observed=%u "
                    "expected=%u\n",
                    load_expected_rows[row].prefix,
                    (unsigned int)observed_ids[row],
                    (unsigned int)complete_mask);
      return 0;
    }
  }
  return 1;
}

static int load_matrix_case_digest(const lf_load_case *load_case,
                                   load_content_span *span,
                                   char digest_hex[65]) {
  uint8_t digest[32];
  size_t index = 0U;
  if (load_case == NULL || span == NULL || digest_hex == NULL ||
      !load_content_span_prepare(span, load_case->header,
                                 load_case->actual_extent) ||
      !lf_nesturbator_save_fixture_sha256(span->bytes,
                                          load_case->actual_extent, digest)) {
    return 0;
  }
  for (index = 0U; index < sizeof(digest); ++index) {
    const int written = snprintf(digest_hex + index * 2U,
                                 65U - index * 2U, "%02x", digest[index]);
    if (written != 2) {
      return 0;
    }
  }
  return 1;
}

static int run_matrix_batch(const lf_load_matrix_case *matrix_cases,
                            size_t first, size_t end,
                            load_content_span *span, size_t *executed) {
  size_t index = 0U;
  if (matrix_cases == NULL || span == NULL || executed == NULL || first > end) {
    return 0;
  }
  for (index = first; index < end; ++index) {
    const lf_load_matrix_case *matrix_case = &matrix_cases[index];
    lf_load_case load_case;
    lf_status actual_status = LF_INVALID_ARGUMENT;
    char content_digest[65];
    const char *history = NULL;
    clock_t started = clock();
    clock_t finished = (clock_t)0;
    double elapsed_seconds = 0.0;
    int declared_size_representable = 0;
    int case_ok = 0;
    if (!load_matrix_case_build(matrix_case, &load_case,
                                &declared_size_representable) ||
        !load_content_span_prepare(span, load_case.header,
                                   load_case.actual_extent) ||
        !load_matrix_case_digest(&load_case, span, content_digest)) {
      (void)fprintf(stderr,
                    "load_corpus: classification_case_setup_failed case=%s\n",
                    matrix_case->id);
      return 0;
    }
    (void)declared_size_representable;
    if (load_case.expected_status == LF_OK) {
      history = "classification-only-load-destroy";
      case_ok = load_run_accepted_case(&load_case, span, &actual_status);
    } else {
      history = "unloaded+loaded-refusal";
      case_ok = load_run_unloaded_case(&load_case, span, &actual_status);
      if (case_ok != 0) {
        case_ok = load_run_loaded_refusal_case(&load_case, span,
                                               &actual_status, NULL, 0U, 0U,
                                               NULL, 0);
      }
    }
    if (case_ok == 0 || actual_status != load_case.expected_status ||
        !load_content_span_unchanged(span, load_case.header,
                                     load_case.actual_extent)) {
      (void)fprintf(stderr,
                    "load_corpus: classification_case_failed case=%s "
                    "expected=%s actual=%s\n",
                    load_case.id, load_status_name(load_case.expected_status),
                    load_status_name(actual_status));
      return 0;
    }
    finished = clock();
    if (started != (clock_t)-1 && finished != (clock_t)-1 &&
        finished >= started && CLOCKS_PER_SEC > 0) {
      elapsed_seconds = (double)(finished - started) /
                        (double)CLOCKS_PER_SEC;
    } else {
      elapsed_seconds = -1.0;
    }
    (void)printf(
        "load_corpus: case_id=%s expected_status=%s actual_status=%s "
        "history=%s content_digest=%s observation_result=pass "
        "elapsed_seconds=%.6f\n",
        load_case.id, load_status_name(load_case.expected_status),
        load_status_name(actual_status), history, content_digest,
        elapsed_seconds);
    ++(*executed);
  }
  return 1;
}

static int run_classification_matrix(void) {
  load_content_span span = {0};
  size_t executed = 0U;
  int ok = 0;
  if (!validate_case_inventory() ||
      !load_content_span_create(&span, LOAD_MAX_ACCESSIBLE_BYTES)) {
    (void)fprintf(stderr, "load_corpus: layout_matrix_setup_failed\n");
    return 0;
  }
  ok = run_matrix_batch(lf_load_layout_cases, 0U,
                        LF_LOAD_LAYOUT_CASE_COUNT, &span, &executed);
  load_content_span_destroy(&span);
  if (ok != 0 && executed == LF_LOAD_LAYOUT_CASE_COUNT) {
    (void)printf(
        "nesturbator_load_corpus: source=%s profile=%s "
        "recipe=lf-load-matrix-1 mode=layouts executed=%zu/expected=%u "
        "immediate-media=full continuation-frames=3 "
        "unreachable=ram-shift>15,exponent-width>=64,size-add-after-board-bounds "
        "assertion-complete=true result=pass\n",
        LIBFUTURO_NESTURBATOR_SOURCE_REVISION, LOAD_PROFILE_ID, executed,
        (unsigned int)LF_LOAD_LAYOUT_CASE_COUNT);
  } else {
    ok = 0;
  }
  return ok;
}

static int load_format_case_manifest(const lf_load_case *load_case,
                                     load_content_span *span,
                                     char entry[LOAD_MANIFEST_ENTRY_BYTES]) {
  uint8_t digest[32];
  char digest_hex[sizeof(digest) * 2U + 1U];
  char header_hex[sizeof(load_case->header) * 2U + 1U];
  size_t index = 0U;
  int written = 0;
  const char *history = NULL;
  if (load_case == NULL || span == NULL ||
      entry == NULL ||
      !load_content_span_prepare(span, load_case->header,
                                 load_case->actual_extent) ||
      !lf_nesturbator_save_fixture_sha256(span->bytes,
                                          load_case->actual_extent, digest)) {
    return 0;
  }
  history = load_case->expected_status == LF_OK
                ? "classification-only"
                : (load_case->instance_null != 0U
                       ? "unloaded-null-instance"
                       : "unloaded+loaded-refusal");
  for (index = 0U; index < sizeof(load_case->header); ++index) {
    const int byte_written =
        snprintf(header_hex + index * 2U, sizeof(header_hex) - index * 2U,
                 "%02x", load_case->header[index]);
    if (byte_written != 2) {
      return 0;
    }
  }
  for (index = 0U; index < sizeof(digest); ++index) {
    const int byte_written =
        snprintf(digest_hex + index * 2U, sizeof(digest_hex) - index * 2U,
                 "%02x", digest[index]);
    if (byte_written != 2) {
      return 0;
    }
  }
  written = snprintf(
      entry, LOAD_MANIFEST_ENTRY_BYTES,
      "recipe=lf-load-matrix-1;case_id=%s;expected_status=%s;"
      "actual_status=not-run;header=%s;extent=%zu;"
      "configuration=%s;request=%u/%u;result=%u/%u;content_null=%u;"
      "instance_null=%u;history=%s;classification_only=%u;"
      "observation_result=not-run;elapsed_seconds=not-run;"
      "generator=(17*i+3)%%256;content_digest=%s\n",
      load_case->id, load_status_name(load_case->expected_status), header_hex,
      load_case->actual_extent,
      load_case->configuration_id == NULL ? "default"
                                          : load_case->configuration_id,
      (unsigned int)load_case->request_variant,
      (unsigned int)load_case->request_size_variant,
      (unsigned int)load_case->result_variant,
      (unsigned int)load_case->result_size_variant,
      (unsigned int)load_case->content_pointer_null,
      (unsigned int)load_case->instance_null, history,
      load_case->expected_status == LF_OK ? 1U : 0U, digest_hex);
  return written > 0 && (size_t)written < LOAD_MANIFEST_ENTRY_BYTES;
}

static int load_format_layout_manifest(const lf_load_matrix_case *matrix_case,
                                      load_content_span *span,
                                      char entry[LOAD_MANIFEST_ENTRY_BYTES]) {
  lf_load_case load_case;
  uint8_t digest[32];
  char digest_hex[sizeof(digest) * 2U + 1U];
  char header_hex[sizeof(load_case.header) * 2U + 1U];
  char declared_extent_text[32];
  size_t declared_extent = 0U;
  size_t index = 0U;
  int declared_size_representable = 0;
  int written = 0;
  const char *format_name = NULL;
  const char *prg_mode_name = NULL;
  const char *chr_mode_name = NULL;
  const char *history = NULL;
  if (matrix_case == NULL || span == NULL || entry == NULL ||
      !load_matrix_case_build(matrix_case, &load_case,
                              &declared_size_representable) ||
      !load_content_span_prepare(span, load_case.header,
                                 load_case.actual_extent) ||
      !lf_nesturbator_save_fixture_sha256(span->bytes,
                                          load_case.actual_extent, digest)) {
    return 0;
  }
  if (declared_size_representable != 0) {
    if (!load_matrix_declared_extent(matrix_case, &declared_extent)) {
      return 0;
    }
    written = snprintf(declared_extent_text, sizeof(declared_extent_text),
                       "%zu", declared_extent);
  } else {
    written = snprintf(declared_extent_text, sizeof(declared_extent_text),
                       "size_t-overflow");
  }
  if (written <= 0 || (size_t)written >= sizeof(declared_extent_text)) {
    return 0;
  }
  format_name = matrix_case->format == LF_MATRIX_FORMAT_NES2 ? "NES2" : "iNES";
  prg_mode_name = matrix_case->prg_mode == LF_MATRIX_SIZE_EXPONENT
                      ? "exponent-byte"
                      : "linear-units";
  chr_mode_name = matrix_case->chr_mode == LF_MATRIX_SIZE_EXPONENT
                      ? "exponent-byte"
                      : "linear-units";
  history = load_case.expected_status == LF_OK
                ? "classification-only-load-destroy"
                : "unloaded+loaded-refusal";
  for (index = 0U; index < sizeof(load_case.header); ++index) {
    const int byte_written =
        snprintf(header_hex + index * 2U, sizeof(header_hex) - index * 2U,
                 "%02x", load_case.header[index]);
    if (byte_written != 2) {
      return 0;
    }
  }
  for (index = 0U; index < sizeof(digest); ++index) {
    const int byte_written =
        snprintf(digest_hex + index * 2U, sizeof(digest_hex) - index * 2U,
                 "%02x", digest[index]);
    if (byte_written != 2) {
      return 0;
    }
  }
  written = snprintf(
      entry, LOAD_MANIFEST_ENTRY_BYTES,
      "recipe=lf-load-matrix-1;case_id=%s;expected_status=%s;"
      "actual_status=not-run;format=%s;mapper=%u;submapper=%u;"
      "prg_mode=%s;prg_value=%u;chr_mode=%s;chr_value=%u;"
      "ram_shifts=%u,%u,%u,%u;battery=%u;trainer=%u;configuration=%s;"
      "extent_mode=%u;declared_extent=%s;actual_extent=%zu;header=%s;"
      "history=%s;classification_only=%u;observation_result=not-run;"
      "elapsed_seconds=not-run;generator=(17*i+3)%%256;content_digest=%s\n",
      matrix_case->id, load_status_name(load_case.expected_status),
      format_name, (unsigned int)matrix_case->mapper,
      (unsigned int)matrix_case->submapper, prg_mode_name,
      (unsigned int)matrix_case->prg_value, chr_mode_name,
      (unsigned int)matrix_case->chr_value,
      (unsigned int)matrix_case->prg_ram_shift,
      (unsigned int)matrix_case->prg_nvram_shift,
      (unsigned int)matrix_case->chr_ram_shift,
      (unsigned int)matrix_case->chr_nvram_shift,
      (unsigned int)matrix_case->battery, (unsigned int)matrix_case->trainer,
      matrix_case->configuration_id == NULL ? "default"
                                            : matrix_case->configuration_id,
      (unsigned int)matrix_case->extent_mode, declared_extent_text,
      load_case.actual_extent, header_hex, history,
      load_case.expected_status == LF_OK ? 1U : 0U, digest_hex);
  return written > 0 && (size_t)written < LOAD_MANIFEST_ENTRY_BYTES;
}

static int load_manifest_append_matrix_range(
    uint8_t *manifest, size_t capacity, size_t *manifest_size,
    size_t *manifest_rows, const lf_load_matrix_case *matrix_cases,
    size_t first, size_t end, load_content_span *span) {
  size_t index = 0U;
  if (manifest == NULL || manifest_size == NULL || manifest_rows == NULL ||
      matrix_cases == NULL || span == NULL || first > end ||
      *manifest_size > capacity) {
    return 0;
  }
  for (index = first; index < end; ++index) {
    char entry[LOAD_MANIFEST_ENTRY_BYTES];
    size_t measured_entry_size = 0U;
    if (!load_format_layout_manifest(&matrix_cases[index], span, entry)) {
      return 0;
    }
    measured_entry_size = strlen(entry);
    if (measured_entry_size == 0U ||
        measured_entry_size > capacity - *manifest_size) {
      return 0;
    }
    memcpy(manifest + *manifest_size, entry, measured_entry_size);
    *manifest_size += measured_entry_size;
    ++(*manifest_rows);
    (void)fputs(entry, stdout);
  }
  return 1;
}

static int run_manifest(void) {
  load_content_span span = {0};
  uint8_t manifest[LF_LOAD_CLASSIFICATION_CASE_COUNT *
                   LOAD_MANIFEST_ENTRY_BYTES];
  uint8_t manifest_digest[32];
  char manifest_digest_hex[sizeof(manifest_digest) * 2U + 1U];
  size_t index = 0U;
  size_t manifest_size = 0U;
  size_t manifest_rows = 0U;
  int ok = 0;
  if (!validate_case_inventory() ||
      !load_content_span_create(&span, LOAD_MAX_ACCESSIBLE_BYTES)) {
    return 0;
  }
  (void)printf("nesturbator_load_corpus: source=%s recipe=lf-load-matrix-1 "
               "mode=manifest count=%u expected=%u\n",
               LIBFUTURO_NESTURBATOR_SOURCE_REVISION,
               (unsigned int)LF_LOAD_CLASSIFICATION_CASE_COUNT,
               (unsigned int)LF_LOAD_CLASSIFICATION_CASE_COUNT);
  for (index = 0U; index < LF_LOAD_ADMISSION_CASE_COUNT; ++index) {
    char entry[LOAD_MANIFEST_ENTRY_BYTES];
    size_t measured_entry_size = 0U;
    if (!load_format_case_manifest(&lf_load_admission_cases[index], &span,
                                   entry)) {
      goto cleanup;
    }
    measured_entry_size = strlen(entry);
    if (measured_entry_size == 0U ||
        measured_entry_size > sizeof(manifest) - manifest_size) {
      goto cleanup;
    }
    memcpy(manifest + manifest_size, entry, measured_entry_size);
    manifest_size += measured_entry_size;
    ++manifest_rows;
    (void)fputs(entry, stdout);
  }
  if (!load_manifest_append_matrix_range(
          manifest, sizeof(manifest), &manifest_size, &manifest_rows,
          lf_load_layout_cases, 0U, 30U, &span) ||
      !load_manifest_append_matrix_range(
          manifest, sizeof(manifest), &manifest_size, &manifest_rows,
          lf_load_board_ram_cases, 0U, LF_LOAD_BOARD_RAM_CASE_COUNT, &span) ||
      !load_manifest_append_matrix_range(
          manifest, sizeof(manifest), &manifest_size, &manifest_rows,
          lf_load_layout_cases, 30U, LF_LOAD_LAYOUT_CASE_COUNT, &span)) {
    goto cleanup;
  }
  if (manifest_size == 0U ||
      manifest_rows != LF_LOAD_CLASSIFICATION_CASE_COUNT ||
      LF_LOAD_CLASSIFICATION_CASE_COUNT > LF_LOAD_CORPUS_MAX_DESCRIPTORS) {
    goto cleanup;
  }
  if (!lf_nesturbator_save_fixture_sha256(manifest, manifest_size,
                                          manifest_digest)) {
    goto cleanup;
  }
  for (index = 0U; index < sizeof(manifest_digest); ++index) {
    const int byte_written =
        snprintf(manifest_digest_hex + index * 2U,
                 sizeof(manifest_digest_hex) - index * 2U, "%02x",
                 manifest_digest[index]);
    if (byte_written != 2) {
      goto cleanup;
    }
  }
  (void)printf("manifest_sha256=%s rows=%u\n", manifest_digest_hex,
               (unsigned int)LF_LOAD_CLASSIFICATION_CASE_COUNT);
  (void)puts("partition_exclusions=ram-shift>15-not-representable;"
             "exponent-width>=64-not-representable-on-64-bit;"
             "size-add-overflow-after-profile-board-bounds-unreachable");
  ok = 1;
cleanup:
  load_content_span_destroy(&span);
  return ok;
}

static int run_admission(size_t *executed_out, int print_summary) {
  load_content_span span = {0};
  size_t index = 0U;
  size_t executed = 0U;
  int ok = 0;
  if (!validate_case_inventory() ||
      !load_content_span_create(&span, LOAD_MAX_ACCESSIBLE_BYTES)) {
    (void)fprintf(stderr, "load_corpus: admission_setup_failed\n");
    return 0;
  }
  for (index = 0U; index < LF_LOAD_ADMISSION_CASE_COUNT; ++index) {
    const lf_load_case *load_case = &lf_load_admission_cases[index];
    int case_ok = 0;
    if (!load_content_span_prepare(&span, load_case->header,
                                   load_case->actual_extent)) {
      (void)fprintf(stderr, "load_corpus: generator_overrun case=%s\n",
                    load_case->id);
      goto cleanup;
    }
    if (load_case->expected_status == LF_OK) {
      case_ok = load_run_accepted_case(load_case, &span, NULL);
    } else {
      case_ok = load_run_unloaded_case(load_case, &span, NULL);
      if (case_ok != 0 && load_case->instance_null == 0U) {
        case_ok = load_run_loaded_refusal_case(load_case, &span, NULL, NULL,
                                               0U, 0U, NULL, 0);
      }
    }
    if (case_ok == 0 ||
        !load_content_span_unchanged(&span, load_case->header,
                                     load_case->actual_extent)) {
      (void)fprintf(stderr,
                    "load_corpus: admission_case_failed case=%s expected=%s\n",
                    load_case->id,
                    load_status_name(load_case->expected_status));
      goto cleanup;
    }
    (void)printf("load_corpus: case=%s expected=%s result=pass\n",
                 load_case->id, load_status_name(load_case->expected_status));
    ++executed;
  }
  if (executed != LF_LOAD_ADMISSION_CASE_COUNT) {
    (void)fprintf(stderr, "load_corpus: admission_count=%zu expected=%u\n",
                  executed, LF_LOAD_ADMISSION_CASE_COUNT);
    goto cleanup;
  }
  ok = 1;
cleanup:
  load_content_span_destroy(&span);
  if (executed_out != NULL) {
    *executed_out = executed;
  }
  if (ok != 0 && print_summary != 0) {
    (void)printf(
        "nesturbator_load_corpus: source=%s profile=nesturbator-ntsc-v1 "
        "recipe=lf-load-matrix-1 mode=admission executed=%zu/expected=%u "
        "full-media,three-frame result=pass\n",
        LIBFUTURO_NESTURBATOR_SOURCE_REVISION, executed,
        LF_LOAD_ADMISSION_CASE_COUNT);
  }
  return ok;
}

static int run_all(void) {
  load_content_span span = {0};
  size_t admission_executed = 0U;
  size_t matrix_executed = 0U;
  size_t executed = 0U;
  int ok = 0;
  if (!run_admission(&admission_executed, 0) ||
      admission_executed != LF_LOAD_ADMISSION_CASE_COUNT) {
    return 0;
  }
  if (!load_content_span_create(&span, LOAD_MAX_ACCESSIBLE_BYTES)) {
    (void)fprintf(stderr, "load_corpus: all_matrix_setup_failed\n");
    return 0;
  }
  ok = run_matrix_batch(lf_load_layout_cases, 0U, 30U, &span,
                        &matrix_executed);
  if (ok != 0) {
    ok = run_matrix_batch(lf_load_board_ram_cases, 0U,
                          LF_LOAD_BOARD_RAM_CASE_COUNT, &span,
                          &matrix_executed);
  }
  if (ok != 0) {
    ok = run_matrix_batch(lf_load_layout_cases, 30U,
                          LF_LOAD_LAYOUT_CASE_COUNT, &span,
                          &matrix_executed);
  }
  executed = admission_executed + matrix_executed;
  load_content_span_destroy(&span);
  if (ok == 0 || executed != LF_LOAD_CLASSIFICATION_CASE_COUNT) {
    (void)fprintf(stderr,
                  "load_corpus: all_executed=%zu expected=%u\n", executed,
                  (unsigned int)LF_LOAD_CLASSIFICATION_CASE_COUNT);
    return 0;
  }
  (void)printf(
      "nesturbator_load_corpus: source=%s profile=%s "
      "recipe=lf-load-matrix-1 mode=all executed=%zu/expected=%u "
      "immediate-media=full continuation-frames=3 assertion-complete=true "
      "result=pass\n",
      LIBFUTURO_NESTURBATOR_SOURCE_REVISION, LOAD_PROFILE_ID, executed,
      (unsigned int)LF_LOAD_CLASSIFICATION_CASE_COUNT);
  return 1;
}

static int run_tracer(void) {
  uint8_t fixture[LF_NESTURBATOR_SAVE_FIXTURE_TOTAL_BYTES];
  uint8_t digest[32];
  size_t fixture_extent = 0U;
  int ok = 0;

  fixture_extent =
      lf_build_nesturbator_save_fixture(fixture, sizeof(fixture));
  if (fixture_extent != sizeof(fixture) ||
      !lf_nesturbator_save_fixture_sha256(fixture, fixture_extent, digest) ||
      !lf_save_oracle_sha256_matches(digest, sizeof(digest))) {
    (void)fprintf(stderr, "load_corpus: fixture_identity_mismatch\n");
    return 0;
  }
  if (lf_load_tracer_h01_01.expected_status != LF_INVALID_ARGUMENT ||
      lf_load_tracer_h01_01.executable != 1U ||
      lf_load_tracer_h01_01.actual_extent != fixture_extent ||
      !load_check_unloaded_refusal(fixture, fixture_extent,
                                   &lf_load_tracer_h01_01) ||
      !load_check_loaded_refusal(fixture, fixture_extent,
                                 &lf_load_tracer_h01_01)) {
    return 0;
  }
  ok = 1;
  return ok;
}

static const lf_load_matrix_case *load_find_allocation_matrix_case(
    const char *case_id) {
  size_t index = 0U;
  if (case_id == NULL) {
    return NULL;
  }
  for (index = 0U; index < LF_LOAD_LAYOUT_CASE_COUNT; ++index) {
    if (strcmp(lf_load_layout_cases[index].id, case_id) == 0) {
      return &lf_load_layout_cases[index];
    }
  }
  for (index = 0U; index < LF_LOAD_BOARD_RAM_CASE_COUNT; ++index) {
    if (strcmp(lf_load_board_ram_cases[index].id, case_id) == 0) {
      return &lf_load_board_ram_cases[index];
    }
  }
  return NULL;
}

static int load_candidate_baseline(const lf_load_case *load_case,
                                   load_content_span *span,
                                   const char *layout_id,
                                   size_t observed_sizes[
                                       LF_LOAD_CORPUS_MAX_CANDIDATE_CALLS],
                                   size_t *observed_count) {
  load_allocation_tracker tracker = {0};
  lf_instance *instance = NULL;
  guarded_request request;
  guarded_request request_before;
  guarded_result result;
  guarded_result result_before;
  uint8_t configuration[LOAD_CONFIG_STORAGE_BYTES];
  uint8_t configuration_before[LOAD_CONFIG_STORAGE_BYTES];
  const lf_load_request *request_pointer = NULL;
  lf_load_result *result_pointer = NULL;
  size_t index = 0U;
  lf_status status = LF_INVALID_ARGUMENT;
  int ok = 0;

  if (load_case == NULL || span == NULL || layout_id == NULL ||
      observed_sizes == NULL || observed_count == NULL ||
      load_case->expected_status != LF_OK || load_case->executable != 0U ||
      !load_tracker_create(&tracker, &instance) ||
      !load_build_case_records(load_case, span, &request, &result,
                               configuration, &request_before, &result_before,
                               configuration_before, &request_pointer,
                               &result_pointer)) {
    (void)fprintf(stderr,
                  "load_corpus: allocation_baseline_setup_failed layout=%s case=%s\n",
                  layout_id == NULL ? "<null>" : layout_id,
                  load_case == NULL ? "<null>" : load_case->id);
    goto cleanup;
  }
  load_tracker_begin_candidate(&tracker, 0U);
  status = lf_load(instance, request_pointer, result_pointer);
  load_tracker_end_candidate(&tracker);
  if (status != LF_OK ||
      !load_case_result_matches(load_case, result_pointer, 1U,
                                load_case->actual_extent) ||
      !load_case_io_unchanged(load_case, span, &request, &result,
                              configuration, &request_before, &result_before,
                              configuration_before) ||
      tracker.candidate_failure_reached != 0U || tracker.bound_exceeded != 0U ||
      tracker.candidate_call_count == 0U ||
      tracker.candidate_call_count > LF_LOAD_CORPUS_MAX_CANDIDATE_CALLS) {
    (void)fprintf(stderr,
                  "load_corpus: allocation_baseline_mismatch layout=%s case=%s status=%s observed_count=%zu\n",
                  layout_id, load_case->id, load_status_name(status),
                  tracker.candidate_call_count);
    goto cleanup;
  }
  *observed_count = tracker.candidate_call_count;
  for (index = 0U; index < *observed_count; ++index) {
    const size_t bytes = tracker.candidate_call_sizes[index];
    if (bytes == 0U || bytes > LF_LOAD_CORPUS_MAX_SINGLE_ALLOCATION) {
      (void)fprintf(stderr,
                    "load_corpus: allocation_baseline_bound layout=%s case=%s ordinal=%zu bytes=%zu\n",
                    layout_id, load_case->id, index + 1U, bytes);
      goto cleanup;
    }
    observed_sizes[index] = bytes;
  }
  ok = 1;

cleanup:
  if (instance != NULL && lf_destroy(&instance) != LF_OK) {
    ok = 0;
  }
  if (!load_tracker_balanced(&tracker)) {
    (void)fprintf(stderr,
                  "load_corpus: allocation_baseline_cleanup layout=%s live=%zu bytes=%zu\n",
                  layout_id == NULL ? "<null>" : layout_id,
                  tracker.live, tracker.live_bytes);
    ok = 0;
  }
  if (ok != 0) {
    (void)printf("allocation_baseline: layout_id=%s case=%s observed_count=%zu requested_bytes=",
                 layout_id, load_case->id, *observed_count);
    for (index = 0U; index < *observed_count; ++index) {
      (void)printf("%s%zu", index == 0U ? "" : ",",
                   observed_sizes[index]);
    }
    (void)puts(" destroy_balance=complete");
  }
  return ok;
}

static int run_candidate_allocation_classes(void) {
  load_content_span span = {0};
  size_t layout_index = 0U;
  size_t observed_ordinals = 0U;
  int ok = 0;

  if (!validate_case_inventory() ||
      !load_content_span_create(&span, LOAD_MAX_ACCESSIBLE_BYTES)) {
    (void)fprintf(stderr, "load_corpus: allocation_sweep_setup_failed\n");
    return 0;
  }
  for (layout_index = 0U;
       layout_index < LF_LOAD_ALLOCATION_CLASS_COUNT; ++layout_index) {
    const lf_load_allocation_class *allocation_class =
        &lf_load_allocation_classes[layout_index];
    const lf_load_matrix_case *matrix_case =
        allocation_class->custom_case != NULL
            ? allocation_class->custom_case
            : load_find_allocation_matrix_case(
                  allocation_class->matrix_case_id);
    lf_load_case load_case;
    size_t observed_sizes[LF_LOAD_CORPUS_MAX_CANDIDATE_CALLS] = {0};
    size_t observed_count = 0U;
    size_t ordinal = 0U;

    if (matrix_case == NULL ||
        strcmp(matrix_case->id, allocation_class->matrix_case_id) != 0 ||
        !load_matrix_case_build(matrix_case, &load_case, NULL) ||
        load_case.expected_status != LF_OK || load_case.executable != 0U ||
        !load_content_span_prepare(&span, load_case.header,
                                   load_case.actual_extent) ||
        !load_candidate_baseline(&load_case, &span, allocation_class->id,
                                 observed_sizes, &observed_count)) {
      (void)fprintf(stderr,
                    "load_corpus: allocation_layout_failed layout=%s source_case=%s\n",
                    allocation_class->id, allocation_class->matrix_case_id);
      goto cleanup;
    }
    for (ordinal = 1U; ordinal <= observed_count; ++ordinal) {
      lf_load_case refusal_case = load_case;
      refusal_case.expected_status = LF_RESOURCE_EXHAUSTED;
      if (!load_content_span_prepare(&span, refusal_case.header,
                                     refusal_case.actual_extent) ||
          !load_run_candidate_unloaded_failure(
              &refusal_case, &span, allocation_class->id, ordinal,
              observed_count, observed_sizes) ||
          !load_content_span_prepare(&span, refusal_case.header,
                                     refusal_case.actual_extent) ||
          !load_run_loaded_refusal_case(
              &refusal_case, &span, NULL, allocation_class->id, ordinal,
              observed_count, observed_sizes, 0)) {
        (void)fprintf(stderr,
                      "load_corpus: allocation_ordinal_failed layout=%s source_case=%s ordinal=%zu observed_count=%zu\n",
                      allocation_class->id, allocation_class->matrix_case_id,
                      ordinal, observed_count);
        goto cleanup;
      }
      ++observed_ordinals;
    }
  }
  ok = observed_ordinals > 0U;

cleanup:
  load_content_span_destroy(&span);
  if (ok != 0 && layout_index == LF_LOAD_ALLOCATION_CLASS_COUNT) {
    (void)printf(
        "nesturbator_load_corpus: source=%s profile=%s "
        "recipe=lf-load-matrix-1 mode=allocations layout_count=%u "
        "observed_ordinals=complete histories=unloaded,loaded "
        "ownership-balanced=true assertion-complete=true result=pass\n",
        LIBFUTURO_NESTURBATOR_SOURCE_REVISION, LOAD_PROFILE_ID,
        (unsigned int)LF_LOAD_ALLOCATION_CLASS_COUNT);
  } else {
    ok = 0;
  }
  return ok;
}

static int load_media_zeroed(const media_observation *observation) {
  size_t index = 0U;
  if (observation == NULL ||
      observation->extent_bytes != LF_SAVE_ORACLE_EXTENT_BYTES) {
    return 0;
  }
  for (index = 0U; index < observation->extent_bytes; ++index) {
    if (observation->bytes[index] != 0U) {
      return 0;
    }
  }
  return 1;
}

static int load_positive_default_media(const media_observation *observation,
                                       uint8_t first_byte,
                                       uint64_t previous_generation) {
  return observation != NULL &&
         strcmp(observation->identity, LF_SAVE_ORACLE_MEDIA_IDENTITY) == 0 &&
         observation->generation > previous_generation &&
         lf_save_oracle_matches(observation->bytes,
                                observation->extent_bytes, first_byte);
}

static int load_positive_trainer_media(const media_observation *observation,
                                       uint8_t first_byte,
                                       uint64_t previous_generation) {
  size_t index = 0U;
  if (observation == NULL ||
      strcmp(observation->identity, LF_SAVE_ORACLE_MEDIA_IDENTITY) != 0 ||
      observation->extent_bytes != LF_SAVE_ORACLE_EXTENT_BYTES ||
      observation->generation <= previous_generation) {
    return 0;
  }
  for (index = 0U; index < observation->extent_bytes; ++index) {
    uint8_t expected = 0U;
    if (index == 0U) {
      expected = first_byte;
    } else if (index >= 4096U && index < 4608U) {
      const size_t trainer_index = index - 4096U;
      expected =
          (uint8_t)((trainer_index * (size_t)17U + (size_t)3U) & 0xffU);
    }
    if (observation->bytes[index] != expected) {
      return 0;
    }
  }
  return 1;
}

static int load_trainer_seed_matches(const media_observation *observation) {
  size_t index = 0U;
  if (observation == NULL ||
      strcmp(observation->identity, LF_SAVE_ORACLE_MEDIA_IDENTITY) != 0 ||
      observation->extent_bytes != LF_SAVE_ORACLE_EXTENT_BYTES ||
      observation->generation != 0U) {
    return 0;
  }
  for (index = 0U; index < observation->extent_bytes; ++index) {
    const uint8_t expected =
        index >= 4096U && index < 4608U
            ? (uint8_t)(((index - 4096U) * (size_t)17U + (size_t)3U) & 0xffU)
            : 0U;
    if (observation->bytes[index] != expected) {
      return 0;
    }
  }
  return 1;
}

static int load_positive_run_result(const lf_run_result *result,
                                    uint64_t expected_frames,
                                    uint32_t expected_buttons,
                                    uint64_t previous_ticks) {
  return result != NULL && result->struct_size == sizeof(*result) &&
         result->actual_units == 1U && result->overshoot_units == 0U &&
         result->cumulative_units == expected_frames &&
         result->core_ticks_valid == 1U &&
         result->cumulative_core_ticks > previous_ticks &&
         result->sampled_buttons == expected_buttons &&
         result->video_valid == 1U && result->audio_valid == 1U &&
         result->stop_reason == LF_STOP_BUDGET_REACHED;
}

static int run_positive_default_and_explicit(void) {
  load_allocation_tracker subject_tracker = {0};
  load_allocation_tracker control_tracker = {0};
  lf_instance *subject = NULL;
  lf_instance *control = NULL;
  uint8_t fixture[LF_NESTURBATOR_SAVE_FIXTURE_TOTAL_BYTES];
  uint8_t fixture_digest[32];
  size_t fixture_extent = 0U;
  lf_load_result subject_load = {.struct_size = sizeof(subject_load)};
  lf_load_result control_load = {.struct_size = sizeof(control_load)};
  media_observation subject_media;
  media_observation control_media;
  lf_run_result frame_result = {.struct_size = sizeof(frame_result)};
  uint64_t previous_generation = 0U;
  uint64_t previous_ticks = 0U;
  size_t frame = 0U;
  int ok = 0;

  fixture_extent =
      lf_build_nesturbator_save_fixture(fixture, sizeof(fixture));
  if (fixture_extent != sizeof(fixture) ||
      !lf_nesturbator_save_fixture_sha256(fixture, fixture_extent,
                                          fixture_digest) ||
      !lf_save_oracle_sha256_matches(fixture_digest, sizeof(fixture_digest)) ||
      !load_tracker_create(&subject_tracker, &subject) ||
      !load_tracker_create(&control_tracker, &control) ||
      !load_instance_fixture_configuration(subject, fixture, fixture_extent,
                                           NULL, &subject_load) ||
      !load_instance_fixture_configuration(
          control, fixture, fixture_extent,
          LF_SAVE_ORACLE_CONFIGURATION_IDENTITY, &control_load) ||
      !load_result_is_active(&subject_load, fixture_extent) ||
      !load_result_is_active(&control_load, fixture_extent) ||
      !load_copy_media_with_zero_generation(subject, &subject_media, 1) ||
      !load_copy_media_with_zero_generation(control, &control_media, 1) ||
      !load_media_equal(&subject_media, &control_media) ||
      subject_media.generation != 0U || !load_media_zeroed(&subject_media)) {
    (void)fprintf(stderr, "load_corpus: positive_default_setup_failed\n");
    goto cleanup;
  }
  memset(fixture, 0xa5, sizeof(fixture));
  for (frame = 1U; frame <= 3U; ++frame) {
    const uint32_t buttons = frame == 2U ? UINT32_C(0x0001) : 0U;
    if (!load_advance_pair_frame(subject, control, buttons, 1, buttons, 0U,
                                 "P01", &frame_result) ||
        !load_positive_run_result(&frame_result, frame, buttons,
                                  previous_ticks) ||
        !load_copy_media(subject, &subject_media) ||
        !load_copy_media(control, &control_media) ||
        !load_media_equal(&subject_media, &control_media) ||
        !load_positive_default_media(&subject_media, (uint8_t)frame,
                                     previous_generation)) {
      (void)fprintf(stderr,
                    "load_corpus: positive_default_frame_failed frame=%zu\n",
                    frame);
      goto cleanup;
    }
    previous_generation = subject_media.generation;
    previous_ticks = frame_result.cumulative_core_ticks;
  }
  ok = 1;

cleanup:
  if (subject != NULL && lf_destroy(&subject) != LF_OK) {
    ok = 0;
  }
  if (control != NULL && lf_destroy(&control) != LF_OK) {
    ok = 0;
  }
  if (!load_tracker_balanced(&subject_tracker) ||
      !load_tracker_balanced(&control_tracker)) {
    ok = 0;
  }
  if (ok != 0) {
    (void)puts("positive_case: P01 default-and-explicit configuration, three literal frames, copied content=pass");
  }
  return ok;
}

static int run_positive_replacement_reset(void) {
  load_allocation_tracker subject_tracker = {0};
  load_allocation_tracker control_tracker = {0};
  lf_instance *subject = NULL;
  lf_instance *control = NULL;
  uint8_t fixture[LF_NESTURBATOR_SAVE_FIXTURE_TOTAL_BYTES];
  uint8_t fixture_digest[32];
  size_t fixture_extent = 0U;
  lf_load_result initial_subject = {.struct_size = sizeof(initial_subject)};
  lf_load_result initial_control = {.struct_size = sizeof(initial_control)};
  lf_load_result replacement_subject = {
      .struct_size = sizeof(replacement_subject)};
  lf_load_result replacement_control = {
      .struct_size = sizeof(replacement_control)};
  lf_profile profile_before;
  lf_profile profile_after;
  media_observation media_before;
  media_observation control_media;
  lf_run_result old_result = {.struct_size = sizeof(old_result)};
  lf_run_result new_result = {.struct_size = sizeof(new_result)};
  uint64_t previous_generation = 0U;
  uint64_t previous_ticks = 0U;
  size_t frame = 0U;
  int ok = 0;

  fixture_extent =
      lf_build_nesturbator_save_fixture(fixture, sizeof(fixture));
  if (fixture_extent != sizeof(fixture) ||
      !lf_nesturbator_save_fixture_sha256(fixture, fixture_extent,
                                          fixture_digest) ||
      !lf_save_oracle_sha256_matches(fixture_digest, sizeof(fixture_digest)) ||
      !load_tracker_create(&subject_tracker, &subject) ||
      !load_tracker_create(&control_tracker, &control) ||
      !load_instance_fixture(subject, fixture, fixture_extent,
                             &initial_subject) ||
      !load_instance_fixture(control, fixture, fixture_extent,
                             &initial_control)) {
    (void)fprintf(stderr, "load_corpus: positive_replacement_setup_failed\n");
    goto cleanup;
  }
  for (frame = 1U; frame <= 3U; ++frame) {
    const uint32_t buttons = frame == 2U ? UINT32_C(0x0001) : 0U;
    if (!load_advance_pair_frame(subject, control, buttons, 1, buttons, 0U,
                                 "P03-old", &old_result) ||
        !load_positive_run_result(&old_result, frame, buttons,
                                  previous_ticks) ||
        !load_copy_media(subject, &media_before) ||
        !lf_save_oracle_matches(media_before.bytes, media_before.extent_bytes,
                                (uint8_t)frame)) {
      (void)fprintf(stderr,
                    "load_corpus: positive_replacement_old_frame_failed frame=%zu\n",
                    frame);
      goto cleanup;
    }
    previous_generation = media_before.generation;
    previous_ticks = old_result.cumulative_core_ticks;
  }
  if (old_result.cumulative_units != 3U ||
      old_result.core_ticks_valid != 1U ||
      lf_set_input(subject, &(lf_input){
                       .struct_size = sizeof(lf_input),
                       .buttons = UINT32_C(0x0001),
                   }) != LF_OK ||
      lf_set_input(control, &(lf_input){
                       .struct_size = sizeof(lf_input),
                       .buttons = UINT32_C(0x0001),
                   }) != LF_OK ||
      !load_snapshot_profile(&profile_before)) {
    (void)fprintf(stderr,
                  "load_corpus: positive_replacement_old_state_failed\n");
    goto cleanup;
  }
  {
    const int subject_replacement_ok =
        load_instance_fixture_configuration(subject, fixture, fixture_extent,
                                            NULL, &replacement_subject);
    const int control_replacement_ok = load_instance_fixture_configuration(
        control, fixture, fixture_extent,
        LF_SAVE_ORACLE_CONFIGURATION_IDENTITY, &replacement_control);
    const int subject_media_ok =
        load_copy_media_with_zero_generation(subject, &media_before, 1);
    const int control_media_ok =
        load_copy_media_with_zero_generation(control, &control_media, 1);
    const int profile_ok = load_snapshot_profile(&profile_after);
    const int profile_equal =
        profile_ok && load_same_profile(&profile_before, &profile_after);
    if (!subject_replacement_ok || !control_replacement_ok ||
        !load_result_is_active(&replacement_subject, fixture_extent) ||
        !load_result_is_active(&replacement_control, fixture_extent) ||
        !profile_equal || !subject_media_ok || !control_media_ok ||
        !load_media_equal(&media_before, &control_media) ||
        media_before.generation != 0U || !load_media_zeroed(&media_before)) {
    (void)fprintf(stderr,
                    "load_corpus: positive_replacement_reset_state_failed subject_load=%d control_load=%d subject_result=%u/%zu control_result=%u/%zu profile_equal=%d media_copy=%d,%d identity=%s extent=%zu generation=%" PRIu64 " zero=%d\n",
                    subject_replacement_ok, control_replacement_ok,
                    (unsigned int)replacement_subject.loaded,
                    replacement_subject.content_size_bytes,
                    (unsigned int)replacement_control.loaded,
                    replacement_control.content_size_bytes, profile_equal,
                    subject_media_ok, control_media_ok, media_before.identity,
                    media_before.extent_bytes, media_before.generation,
                    load_media_zeroed(&media_before));
      goto cleanup;
    }
  }
  memset(fixture, 0xa5, sizeof(fixture));
  previous_generation = 0U;
  previous_ticks = 0U;
  for (frame = 1U; frame <= 3U; ++frame) {
    const uint32_t buttons = frame == 1U ? 0U
                             : frame == 2U ? UINT32_C(0x0100)
                                           : 0U;
    if (!load_advance_pair_frame(subject, control, buttons, frame == 1U ? 0 : 1,
                                 buttons, 0U, "P03-new", &new_result) ||
        !load_positive_run_result(&new_result, frame, buttons,
                                  previous_ticks) ||
        !load_copy_media(subject, &media_before) ||
        !load_copy_media(control, &control_media) ||
        !load_media_equal(&media_before, &control_media) ||
        !load_positive_default_media(&media_before, (uint8_t)frame,
                                     previous_generation)) {
      (void)fprintf(stderr,
                    "load_corpus: positive_replacement_new_frame_failed frame=%zu\n",
                    frame);
      goto cleanup;
    }
    if (frame == 1U &&
        (old_result.cumulative_core_ticks <= new_result.cumulative_core_ticks ||
         new_result.cumulative_units != 1U ||
         new_result.sampled_buttons != 0U)) {
      (void)fprintf(stderr,
                    "load_corpus: positive_replacement_history_not_reset\n");
      goto cleanup;
    }
    previous_generation = media_before.generation;
    previous_ticks = new_result.cumulative_core_ticks;
  }
  ok = 1;

cleanup:
  if (subject != NULL && lf_destroy(&subject) != LF_OK) {
    ok = 0;
  }
  if (control != NULL && lf_destroy(&control) != LF_OK) {
    ok = 0;
  }
  if (!load_tracker_balanced(&subject_tracker) ||
      !load_tracker_balanced(&control_tracker)) {
    ok = 0;
  }
  if (ok != 0) {
    (void)puts("positive_case: P03 replacement reset frame/tick/input/media state and copied content=pass");
  }
  return ok;
}

static int run_positive_trainer(void) {
  load_allocation_tracker subject_tracker = {0};
  load_allocation_tracker control_tracker = {0};
  lf_instance *subject = NULL;
  lf_instance *control = NULL;
  uint8_t fixture[LF_NESTURBATOR_SAVE_FIXTURE_TOTAL_BYTES];
  uint8_t trainer_fixture[LF_NESTURBATOR_SAVE_FIXTURE_TOTAL_BYTES + 512U];
  uint8_t fixture_digest[32];
  size_t fixture_extent = 0U;
  size_t trainer_index = 0U;
  size_t frame = 0U;
  lf_load_result subject_load = {.struct_size = sizeof(subject_load)};
  lf_load_result control_load = {.struct_size = sizeof(control_load)};
  media_observation subject_media;
  media_observation control_media;
  lf_run_result frame_result = {.struct_size = sizeof(frame_result)};
  uint64_t previous_generation = 0U;
  uint64_t previous_ticks = 0U;
  int ok = 0;

  fixture_extent =
      lf_build_nesturbator_save_fixture(fixture, sizeof(fixture));
  if (fixture_extent != sizeof(fixture) ||
      !lf_nesturbator_save_fixture_sha256(fixture, fixture_extent,
                                          fixture_digest) ||
      !lf_save_oracle_sha256_matches(fixture_digest, sizeof(fixture_digest))) {
    (void)fprintf(stderr, "load_corpus: positive_trainer_fixture_failed\n");
    goto cleanup;
  }
  memcpy(trainer_fixture, fixture, LF_NESTURBATOR_SAVE_FIXTURE_HEADER_BYTES);
  trainer_fixture[6] = (uint8_t)(trainer_fixture[6] | UINT8_C(0x04));
  for (trainer_index = 0U; trainer_index < 512U; ++trainer_index) {
    trainer_fixture[LF_NESTURBATOR_SAVE_FIXTURE_HEADER_BYTES + trainer_index] =
        (uint8_t)((trainer_index * (size_t)17U + (size_t)3U) & 0xffU);
  }
  memcpy(trainer_fixture + LF_NESTURBATOR_SAVE_FIXTURE_HEADER_BYTES + 512U,
         fixture + LF_NESTURBATOR_SAVE_FIXTURE_HEADER_BYTES,
         fixture_extent - LF_NESTURBATOR_SAVE_FIXTURE_HEADER_BYTES);
  for (trainer_index = 0U;
       trainer_index < LF_NESTURBATOR_SAVE_FIXTURE_HEADER_BYTES;
       ++trainer_index) {
    const uint8_t expected = trainer_index == 6U
                                 ? (uint8_t)(fixture[trainer_index] |
                                             UINT8_C(0x04))
                                 : fixture[trainer_index];
    if (trainer_fixture[trainer_index] != expected) {
      (void)fprintf(stderr,
                    "load_corpus: positive_trainer_header_mismatch offset=%zu\n",
                    trainer_index);
      goto cleanup;
    }
  }
  if (memcmp(trainer_fixture + LF_NESTURBATOR_SAVE_FIXTURE_HEADER_BYTES +
                 512U,
             fixture + LF_NESTURBATOR_SAVE_FIXTURE_HEADER_BYTES,
             fixture_extent - LF_NESTURBATOR_SAVE_FIXTURE_HEADER_BYTES) != 0 ||
      !load_tracker_create(&subject_tracker, &subject) ||
      !load_tracker_create(&control_tracker, &control) ||
      !load_instance_fixture_configuration(
          subject, trainer_fixture, sizeof(trainer_fixture), NULL,
          &subject_load) ||
      !load_instance_fixture_configuration(
          control, trainer_fixture, sizeof(trainer_fixture),
          LF_SAVE_ORACLE_CONFIGURATION_IDENTITY, &control_load) ||
      !load_result_is_active(&subject_load, sizeof(trainer_fixture)) ||
      !load_result_is_active(&control_load, sizeof(trainer_fixture)) ||
      !load_copy_media_with_zero_generation(subject, &subject_media, 1) ||
      !load_copy_media_with_zero_generation(control, &control_media, 1) ||
      !load_media_equal(&subject_media, &control_media) ||
      !load_trainer_seed_matches(&subject_media)) {
    (void)fprintf(stderr,
                  "load_corpus: positive_trainer_load_or_seed_failed\n");
    goto cleanup;
  }
  memset(trainer_fixture, 0xa5, sizeof(trainer_fixture));
  for (frame = 1U; frame <= 3U; ++frame) {
    const uint32_t buttons = frame == 2U ? UINT32_C(0x0001) : 0U;
    if (!load_advance_pair_frame(subject, control, buttons, 1, buttons, 0U,
                                 "P05", &frame_result) ||
        !load_positive_run_result(&frame_result, frame, buttons,
                                  previous_ticks) ||
        !load_copy_media(subject, &subject_media) ||
        !load_copy_media(control, &control_media) ||
        !load_media_equal(&subject_media, &control_media) ||
        !load_positive_trainer_media(&subject_media, (uint8_t)frame,
                                     previous_generation)) {
      (void)fprintf(stderr,
                    "load_corpus: positive_trainer_frame_failed frame=%zu\n",
                    frame);
      goto cleanup;
    }
    previous_generation = subject_media.generation;
    previous_ticks = frame_result.cumulative_core_ticks;
  }
  ok = 1;

cleanup:
  if (subject != NULL && lf_destroy(&subject) != LF_OK) {
    ok = 0;
  }
  if (control != NULL && lf_destroy(&control) != LF_OK) {
    ok = 0;
  }
  if (!load_tracker_balanced(&subject_tracker) ||
      !load_tracker_balanced(&control_tracker)) {
    ok = 0;
  }
  if (ok != 0) {
    (void)puts("positive_case: P05 trainer seed offsets 4096..4607 and three frames=pass");
  }
  return ok;
}

static int run_ines_implicit_chr_ram_positive(void) {
  enum {
    LEGACY_CHR_RAM_CONTENT_BYTES =
        LF_NESTURBATOR_SAVE_FIXTURE_HEADER_BYTES +
        LF_NESTURBATOR_SAVE_FIXTURE_PRG_BYTES,
    LEGACY_CHR_RAM_GUARD_BYTES = 32U
  };
  load_allocation_tracker subject_tracker = {0};
  load_allocation_tracker control_tracker = {0};
  lf_instance *subject = NULL;
  lf_instance *control = NULL;
  uint8_t original_fixture[LF_NESTURBATOR_SAVE_FIXTURE_TOTAL_BYTES];
  uint8_t subject_storage[LEGACY_CHR_RAM_GUARD_BYTES +
                          LEGACY_CHR_RAM_CONTENT_BYTES +
                          LEGACY_CHR_RAM_GUARD_BYTES];
  uint8_t control_storage[LEGACY_CHR_RAM_GUARD_BYTES +
                          LEGACY_CHR_RAM_CONTENT_BYTES +
                          LEGACY_CHR_RAM_GUARD_BYTES];
  uint8_t *subject_fixture = subject_storage + LEGACY_CHR_RAM_GUARD_BYTES;
  uint8_t *control_fixture = control_storage + LEGACY_CHR_RAM_GUARD_BYTES;
  uint8_t fixture_digest[32];
  size_t original_extent = 0U;
  size_t frame = 0U;
  lf_load_result subject_load = {.struct_size = sizeof(subject_load)};
  lf_load_result control_load = {.struct_size = sizeof(control_load)};
  media_observation subject_media;
  media_observation control_media;
  lf_run_result frame_result = {.struct_size = sizeof(frame_result)};
  uint64_t previous_generation = 0U;
  uint64_t previous_ticks = 0U;
  int ok = 0;

  memset(subject_storage, 0xa5, sizeof(subject_storage));
  memset(control_storage, 0xa5, sizeof(control_storage));
  original_extent = lf_build_nesturbator_save_fixture(
      original_fixture, sizeof(original_fixture));
  if (original_extent != sizeof(original_fixture) ||
      !lf_nesturbator_save_fixture_sha256(original_fixture, original_extent,
                                          fixture_digest) ||
      !lf_save_oracle_sha256_matches(fixture_digest, sizeof(fixture_digest)) ||
      original_fixture[5] != LF_NESTURBATOR_SAVE_FIXTURE_CHR_BANKS ||
      original_extent != (size_t)LEGACY_CHR_RAM_CONTENT_BYTES +
                             LF_NESTURBATOR_SAVE_FIXTURE_CHR_BYTES) {
    (void)fprintf(stderr,
                  "load_corpus: ines_chr_ram_original_fixture_failed\n");
    goto cleanup;
  }

  /* Keep the known executable header and PRG intact, select iNES v1 implicit
     CHR RAM with a zero CHR-ROM count, and omit the original CHR-ROM bank. */
  memcpy(subject_fixture, original_fixture,
         (size_t)LEGACY_CHR_RAM_CONTENT_BYTES);
  memcpy(control_fixture, original_fixture,
         (size_t)LEGACY_CHR_RAM_CONTENT_BYTES);
  subject_fixture[5] = 0U;
  control_fixture[5] = 0U;
  if (memcmp(subject_fixture, control_fixture,
             (size_t)LEGACY_CHR_RAM_CONTENT_BYTES) != 0 ||
      subject_fixture[5] != 0U || control_fixture[5] != 0U ||
      memcmp(subject_fixture + LF_NESTURBATOR_SAVE_FIXTURE_HEADER_BYTES,
             original_fixture + LF_NESTURBATOR_SAVE_FIXTURE_HEADER_BYTES,
             LF_NESTURBATOR_SAVE_FIXTURE_PRG_BYTES) != 0 ||
      !load_tracker_create(&subject_tracker, &subject) ||
      !load_tracker_create(&control_tracker, &control)) {
    (void)fprintf(stderr,
                  "load_corpus: ines_chr_ram_fixture_setup_failed\n");
    goto cleanup;
  }

  {
    const lf_load_request subject_request = {
        .struct_size = sizeof(subject_request),
        .content_data = subject_fixture,
        .content_size_bytes = (size_t)LEGACY_CHR_RAM_CONTENT_BYTES,
        .configuration_id = NULL,
    };
    const lf_load_request control_request = {
        .struct_size = sizeof(control_request),
        .content_data = control_fixture,
        .content_size_bytes = (size_t)LEGACY_CHR_RAM_CONTENT_BYTES,
        .configuration_id = LF_SAVE_ORACLE_CONFIGURATION_IDENTITY,
    };
    const lf_status subject_status =
        lf_load(subject, &subject_request, &subject_load);
    const lf_status control_status =
        lf_load(control, &control_request, &control_load);
    if (subject_status != LF_OK || control_status != LF_OK ||
        !load_result_is_active(&subject_load,
                               (size_t)LEGACY_CHR_RAM_CONTENT_BYTES) ||
        !load_result_is_active(&control_load,
                               (size_t)LEGACY_CHR_RAM_CONTENT_BYTES)) {
      (void)fprintf(stderr,
                    "load_corpus: ines_chr_ram_status_mismatch case=I04-01 expected=LF_OK actual_subject=%s actual_control=%s\n",
                    load_status_name(subject_status),
                    load_status_name(control_status));
      goto cleanup;
    }
  }

  if (!load_copy_media_with_zero_generation(subject, &subject_media, 1) ||
      !load_copy_media_with_zero_generation(control, &control_media, 1) ||
      !load_media_equal(&subject_media, &control_media) ||
      !load_media_zeroed(&subject_media) || subject_media.generation != 0U ||
      !load_has_byte_guard(subject_storage, LEGACY_CHR_RAM_CONTENT_BYTES,
                           UINT8_C(0xa5)) ||
      !load_has_byte_guard(control_storage, LEGACY_CHR_RAM_CONTENT_BYTES,
                           UINT8_C(0xa5))) {
    (void)fprintf(stderr,
                  "load_corpus: ines_chr_ram_initial_state_failed case=I04-01\n");
    goto cleanup;
  }

  /* A successful load owns its content. Change each caller span before guest
     work, then require both copies to continue the known literal save oracle. */
  memset(subject_fixture, 0xa5, (size_t)LEGACY_CHR_RAM_CONTENT_BYTES);
  memset(control_fixture, 0x5a, (size_t)LEGACY_CHR_RAM_CONTENT_BYTES);
  for (frame = 1U; frame <= 3U; ++frame) {
    const uint32_t buttons = frame == 2U ? UINT32_C(0x0001) : 0U;
    if (!load_advance_pair_frame(subject, control, buttons, 1, buttons,
                                 0U, "I04-01", &frame_result) ||
        !load_positive_run_result(&frame_result, frame, buttons,
                                  previous_ticks) ||
        !load_copy_media(subject, &subject_media) ||
        !load_copy_media(control, &control_media) ||
        !load_media_equal(&subject_media, &control_media) ||
        !load_positive_default_media(&subject_media, (uint8_t)frame,
                                     previous_generation)) {
      (void)fprintf(stderr,
                    "load_corpus: ines_chr_ram_continuation_failed case=I04-01 frame=%zu\n",
                    frame);
      goto cleanup;
    }
    previous_generation = subject_media.generation;
    previous_ticks = frame_result.cumulative_core_ticks;
  }
  ok = 1;

cleanup:
  if (subject != NULL && lf_destroy(&subject) != LF_OK) {
    ok = 0;
  }
  if (control != NULL && lf_destroy(&control) != LF_OK) {
    ok = 0;
  }
  if (!load_tracker_balanced(&subject_tracker) ||
      !load_tracker_balanced(&control_tracker) ||
      !load_has_byte_guard(subject_storage, LEGACY_CHR_RAM_CONTENT_BYTES,
                           UINT8_C(0xa5)) ||
      !load_has_byte_guard(control_storage, LEGACY_CHR_RAM_CONTENT_BYTES,
                           UINT8_C(0xa5))) {
    ok = 0;
  }
  if (ok != 0) {
    (void)printf(
        "nesturbator_load_corpus: source=%s profile=%s "
        "mode=ines-v1-implicit-chr-ram case=I04-01 status=LF_OK "
        "continuation-frames=3 result=pass\n",
        LIBFUTURO_NESTURBATOR_SOURCE_REVISION, LOAD_PROFILE_ID);
  }
  return ok;
}

static int run_known_positive_replacement(void) {
  if (!run_positive_default_and_explicit() ||
      !run_positive_replacement_reset() || !run_positive_trainer()) {
    return 0;
  }
  (void)printf(
      "nesturbator_load_corpus: source=%s profile=%s "
      "recipe=lf-load-matrix-1 mode=positives cases=default-explicit,replacement-reset,trainer-p05 "
      "assertion-complete=true result=pass\n",
      LIBFUTURO_NESTURBATOR_SOURCE_REVISION, LOAD_PROFILE_ID);
  return 1;
}

static int run_wrong_status_control(void) {
  load_content_span span = {0};
  lf_load_case wrong_status = lf_load_tracer_h01_01;
  int result = 0;
  if (!load_content_span_create(&span, LOAD_MAX_ACCESSIBLE_BYTES)) {
    (void)fprintf(stderr, "load_corpus: wrong_status_setup_failed\n");
    return 1;
  }
  wrong_status.expected_status = LF_OK;
  if (!load_content_span_prepare(&span, wrong_status.header,
                                wrong_status.actual_extent)) {
    load_content_span_destroy(&span);
    (void)fprintf(stderr, "load_corpus: wrong_status_setup_failed\n");
    return 1;
  }
  result = load_run_unloaded_case(&wrong_status, &span, NULL);
  load_content_span_destroy(&span);
  return result == 0 ? 1 : 0;
}

static int run_diverge_state_control(void) {
  load_content_span span = {0};
  int result = 0;
  if (!load_content_span_create(&span, LOAD_MAX_ACCESSIBLE_BYTES) ||
      !load_content_span_prepare(&span, lf_load_tracer_h01_01.header,
                                lf_load_tracer_h01_01.actual_extent)) {
    load_content_span_destroy(&span);
    (void)fprintf(stderr, "load_corpus: diverge_state_setup_failed\n");
    return 1;
  }
  result = load_run_loaded_refusal_case(
      &lf_load_tracer_h01_01, &span, NULL, NULL, 0U, 0U, NULL, 1);
  load_content_span_destroy(&span);
  return result == 0 ? 1 : 0;
}

int main(int argc, char **argv) {
  int ok = 0;
  if (argc != 2 || argv == NULL) {
    (void)fprintf(stderr,
                  "usage: nesturbator_load_corpus --tracer|--admission|--layouts|--all|--manifest|--allocations|--positives|--wrong-status|--diverge-state|--ines-legacy-chr-ram\n");
    return 2;
  }
  if (strcmp(argv[1], "--tracer") == 0) {
    ok = run_tracer();
    if (ok == 0) {
      return 1;
    }
    (void)printf(
        "nesturbator_load_corpus: source=%s profile=nesturbator-ntsc-v1 "
        "recipe=lf-load-matrix-1 mode=tracer assertions=complete "
        "cleanup=complete result=pass\n",
        LIBFUTURO_NESTURBATOR_SOURCE_REVISION);
    return 0;
  }
  if (strcmp(argv[1], "--admission") == 0) {
    return run_admission(NULL, 1) == 0 ? 1 : 0;
  }
  if (strcmp(argv[1], "--layouts") == 0) {
    return run_classification_matrix() == 0 ? 1 : 0;
  }
  if (strcmp(argv[1], "--all") == 0) {
    return run_all() == 0 ? 1 : 0;
  }
  if (strcmp(argv[1], "--manifest") == 0) {
    return run_manifest() == 0 ? 1 : 0;
  }
  if (strcmp(argv[1], "--allocations") == 0) {
    return run_candidate_allocation_classes() == 0 ? 1 : 0;
  }
  if (strcmp(argv[1], "--positives") == 0) {
    return run_known_positive_replacement() == 0 ? 1 : 0;
  }
  if (strcmp(argv[1], "--wrong-status") == 0) {
    return run_wrong_status_control();
  }
  if (strcmp(argv[1], "--diverge-state") == 0) {
    return run_diverge_state_control();
  }
  if (strcmp(argv[1], "--ines-legacy-chr-ram") == 0) {
    return run_ines_implicit_chr_ram_positive() == 0 ? 1 : 0;
  }
  (void)fprintf(stderr,
                "usage: nesturbator_load_corpus --tracer|--admission|--layouts|--all|--manifest|--allocations|--positives|--wrong-status|--diverge-state|--ines-legacy-chr-ram\n");
  return 2;
}
