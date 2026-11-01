#ifndef LIBFUTURO_LIBFUTURO_H
#define LIBFUTURO_LIBFUTURO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lf_instance lf_instance;

typedef enum lf_status {
  LF_OK = 0,
  LF_INVALID_ARGUMENT = 1,
  LF_UNSUPPORTED = 2,
  LF_LIMIT_EXCEEDED = 3,
  LF_BUFFER_TOO_SMALL = 4,
  LF_RESOURCE_EXHAUSTED = 5
} lf_status;

typedef enum lf_capability {
  LF_CAP_LOGICAL_INPUT = 1,
  LF_CAP_BOUNDED_EXECUTION = 2,
  LF_CAP_SOFTWARE_VIDEO = 3,
  LF_CAP_AUDIO = 4,
  LF_CAP_IN_MEMORY_MEDIA_COPY = 5,
  LF_CAP_SNAPSHOT = 6,
  LF_CAP_HARDWARE_VIDEO = 7,
  LF_CAP_CONCURRENT_USE = 8
} lf_capability;

typedef enum lf_time_unit {
  LF_TIME_SYNTHETIC_STEP = 1
} lf_time_unit;

typedef enum lf_input_sampling {
  LF_INPUT_AT_ADVANCE_START = 1
} lf_input_sampling;

typedef enum lf_video_format {
  LF_VIDEO_GRAY8 = 1
} lf_video_format;

typedef enum lf_audio_encoding {
  LF_AUDIO_S16_NATIVE = 1
} lf_audio_encoding;

typedef enum lf_audio_layout {
  LF_AUDIO_INTERLEAVED = 1
} lf_audio_layout;

typedef enum lf_stop_reason {
  LF_STOP_BUDGET_REACHED = 1,
  LF_STOP_REJECTED = 2
} lf_stop_reason;

typedef void *(*lf_allocate_fn)(void *context, size_t bytes);
typedef void (*lf_deallocate_fn)(void *context, void *allocation);

typedef struct lf_create_options {
  size_t struct_size;
  lf_allocate_fn allocate;
  lf_deallocate_fn deallocate;
  void *allocator_context;
} lf_create_options;

typedef struct lf_input {
  size_t struct_size;
  uint32_t buttons;
} lf_input;

typedef struct lf_run_request {
  size_t struct_size;
  uint32_t work_units;
  uint8_t *video_data;
  size_t video_capacity_bytes;
  size_t video_stride_bytes;
  int16_t *audio_data;
  size_t audio_capacity_samples;
} lf_run_request;

typedef struct lf_run_result {
  size_t struct_size;
  uint32_t requested_units;
  uint32_t actual_units;
  uint32_t overshoot_units;
  uint32_t sampled_buttons;
  uint32_t video_valid;
  uint32_t audio_valid;
  uint64_t cumulative_units;
  lf_time_unit time_unit;
  lf_stop_reason stop_reason;
  lf_video_format video_format;
  lf_audio_encoding audio_encoding;
  lf_audio_layout audio_layout;
  uint32_t video_width;
  uint32_t video_height;
  uint32_t audio_rate_numerator;
  uint32_t audio_rate_denominator;
  uint32_t audio_channels;
  size_t video_stride_bytes;
  size_t video_extent_bytes;
  size_t audio_produced_samples;
} lf_run_result;

typedef struct lf_media_info {
  size_t struct_size;
  const char *identity;
  size_t extent_bytes;
  uint64_t guest_generation;
} lf_media_info;

typedef struct lf_profile {
  size_t struct_size;
  const char *profile_id;
  const char *core_id;
  const char *build_id;
  uint32_t api_revision;
  uint32_t behavior_revision;
  uint32_t input_mask;
  uint32_t max_work_units;
  uint32_t max_guest_units;
  uint32_t atomic_quantum_units;
  uint32_t max_overshoot_units;
  lf_time_unit time_unit;
  lf_input_sampling input_sampling;
  lf_video_format video_format;
  lf_audio_encoding audio_encoding;
  lf_audio_layout audio_layout;
  uint32_t video_width;
  uint32_t video_height;
  uint32_t video_bytes_per_pixel;
  uint32_t audio_rate_numerator;
  uint32_t audio_rate_denominator;
  uint32_t audio_channels;
  size_t min_video_stride_bytes;
  size_t max_audio_samples_per_call;
  size_t media_extent_bytes;
} lf_profile;

lf_status lf_get_profile(const char *profile_id, lf_profile *out);
lf_status lf_get_capability(const char *profile_id, lf_capability capability,
                            uint32_t *supported);
lf_status lf_create(const char *profile_id, const lf_create_options *options,
                    lf_instance **out);
lf_status lf_destroy(lf_instance **owned);
lf_status lf_set_input(lf_instance *instance, const lf_input *input);
lf_status lf_advance(lf_instance *instance, const lf_run_request *request,
                     lf_run_result *out);
lf_status lf_copy_media(lf_instance *instance, uint8_t *destination,
                        size_t capacity_bytes, lf_media_info *out);

#ifdef __cplusplus
}
#endif

#endif
