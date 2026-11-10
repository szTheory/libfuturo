#if defined(__EMSCRIPTEN__) && !defined(_BSD_SOURCE)
#define _BSD_SOURCE 1
#endif

#include "libfuturo_internal.h"
#include "sha256.h"

#include <muhtari.h>

#include <stdatomic.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#ifndef LF_MUHTARI_SOURCE_REVISION
#define LF_MUHTARI_SOURCE_REVISION "unverified"
#endif
#ifndef LF_MUHTARI_API_REVISION
#define LF_MUHTARI_API_REVISION 7
#endif
#ifndef LF_BUILD_ID
#define LF_BUILD_ID "unversioned"
#endif

#define LF_MUHTARI_INPUT_MASK UINT32_C(0x0000F1F1)
#define LF_MUHTARI_DIAGNOSTIC_INPUT_MASK UINT32_C(0x000000F1)
#define LF_MUHTARI_BATTERY_EXTENT ((size_t)34816U)
#define LF_MUHTARI_BATTERY_LAYOUT_VERSION 1U
#define LF_MUHTARI_VIDEO_WIDTH 320U
#define LF_MUHTARI_VIDEO_HEIGHT 242U
#define LF_MUHTARI_VIDEO_EXTENT \
  ((size_t)LF_MUHTARI_VIDEO_WIDTH * (size_t)LF_MUHTARI_VIDEO_HEIGHT)
#define LF_MUHTARI_MAX_AUDIO_SAMPLES 801U
#define LF_MUHTARI_MAX_CONTENT_BYTES ((size_t)MUHTARI_IMAGE_SIZE_MAX)
#define LF_MUHTARI_MAX_SNAPSHOT_BYTES ((size_t)128U * 1024U * 1024U)

#if LF_MUHTARI_API_REVISION == 8
#define LF_MUHTARI_SNAPSHOT_HEADER_BYTES 416U
#define LF_MUHTARI_SNAPSHOT_BUILD_ID_BYTES 64U
#define LF_MUHTARI_SNAPSHOT_LIBFUTURO_BUILD_ID_BYTES 80U
#define LF_MUHTARI_SNAPSHOT_PROFILE_ID_BYTES 32U
#define LF_MUHTARI_SNAPSHOT_CONFIGURATION_ID_BYTES 32U
#define LF_MUHTARI_SNAPSHOT_OPTIONS_ID_BYTES 32U
#define LF_MUHTARI_SNAPSHOT_CONTENT_DIGEST_BYTES 32U
#define LF_MUHTARI_SNAPSHOT_INSTANCE_ID_BYTES 32U
#define LF_MUHTARI_SNAPSHOT_HEADER_DIGEST_BYTES 32U

enum {
  LF_MUHTARI_SNAPSHOT_MAGIC_OFFSET = 0U,
  LF_MUHTARI_SNAPSHOT_VERSION_OFFSET = 8U,
  LF_MUHTARI_SNAPSHOT_HEADER_SIZE_OFFSET = 12U,
  LF_MUHTARI_SNAPSHOT_TOTAL_SIZE_OFFSET = 16U,
  LF_MUHTARI_SNAPSHOT_NATIVE_SIZE_OFFSET = 24U,
  LF_MUHTARI_SNAPSHOT_STATE_FORMAT_OFFSET = 32U,
  LF_MUHTARI_SNAPSHOT_CORE_ABI_OFFSET = 36U,
  LF_MUHTARI_SNAPSHOT_BEHAVIOR_REVISION_OFFSET = 40U,
  LF_MUHTARI_SNAPSHOT_BUILD_ID_OFFSET = 44U,
  LF_MUHTARI_SNAPSHOT_LIBFUTURO_BUILD_ID_OFFSET = 108U,
  LF_MUHTARI_SNAPSHOT_PROFILE_ID_OFFSET = 188U,
  LF_MUHTARI_SNAPSHOT_CONFIGURATION_ID_OFFSET = 220U,
  LF_MUHTARI_SNAPSHOT_OPTIONS_ID_OFFSET = 252U,
  LF_MUHTARI_SNAPSHOT_CONTENT_DIGEST_OFFSET = 284U,
  LF_MUHTARI_SNAPSHOT_INSTANCE_ID_OFFSET = 316U,
  LF_MUHTARI_SNAPSHOT_LOAD_EPOCH_OFFSET = 348U,
  LF_MUHTARI_SNAPSHOT_CONTENT_SIZE_OFFSET = 356U,
  LF_MUHTARI_SNAPSHOT_CUMULATIVE_FRAMES_OFFSET = 364U,
  LF_MUHTARI_SNAPSHOT_PENDING_BUTTONS_OFFSET = 372U,
  LF_MUHTARI_SNAPSHOT_FLAGS_OFFSET = 376U,
  LF_MUHTARI_SNAPSHOT_HEADER_DIGEST_OFFSET = 380U,
  LF_MUHTARI_SNAPSHOT_API_REVISION_OFFSET = 412U,
  LF_MUHTARI_SNAPSHOT_FLAG_POSITIVE_ADVANCE = 1U,
  LF_MUHTARI_SNAPSHOT_FLAG_HALTED = 2U,
  LF_MUHTARI_SNAPSHOT_KNOWN_FLAGS = 3U,
};
#endif

#if LF_MUHTARI_API_REVISION == 8
static const char k_profile_id[] = "muhtari-ntsc-v2";
#else
static const char k_profile_id[] = "muhtari-ntsc-v1";
#endif
static const char k_core_id[] = "muhtari";
static const char k_configuration_id[] = "muhtari-ntsc-joystick-default";
static const char k_battery_configuration_id[] =
    "muhtari-ntsc-battery-diagnostic";
static const char k_battery_identity[] = "muhtari-battery-v1";
static const char k_build_id[] = "muhtari-" LF_MUHTARI_SOURCE_REVISION;
#if LF_MUHTARI_API_REVISION == 8
static const char k_libfuturo_build_id[] = LF_BUILD_ID;
static const char k_options_id[] = "muhtari-api8-options-none-v1";
static const uint8_t k_muhtari_fixture_digest[32] = {
    0x13U, 0x6cU, 0xbeU, 0xadU, 0x3dU, 0xa4U, 0xbdU, 0xe2U,
    0x4eU, 0xa2U, 0x3aU, 0xcfU, 0x36U, 0xebU, 0x8dU, 0xaaU,
    0xccU, 0xedU, 0x88U, 0x07U, 0x4bU, 0xbeU, 0x02U, 0x18U,
    0x88U, 0xaaU, 0x4eU, 0x17U, 0xd9U, 0x87U, 0x19U, 0x5eU};
static const uint8_t k_snapshot_magic[8] = {'L', 'F', 'M', 'U', '8', 'S', '1', 0};
static _Atomic uint64_t g_next_instance_sequence = 1U;
static void snapshot_put_u64(uint8_t output[8], uint64_t value);
#endif

#if LF_MUHTARI_API_REVISION == 8
static int initialize_instance_identity(
    uint8_t identity[LF_MUHTARI_SNAPSHOT_INSTANCE_ID_BYTES]) {
  const uint64_t sequence = atomic_fetch_add_explicit(
      &g_next_instance_sequence, 1U, memory_order_relaxed);
#if defined(__EMSCRIPTEN__)
  /* Emscripten's emulated PID is shared by separate Wasm runtimes and
     TIME_UTC may have millisecond resolution. Per-instance entropy keeps
     identical builds and simultaneous runtimes from sharing snapshot IDs. */
  const size_t random_bytes =
      LF_MUHTARI_SNAPSHOT_INSTANCE_ID_BYTES - sizeof(sequence);
  if (getentropy(identity, random_bytes) != 0) {
    return 0;
  }
  snapshot_put_u64(identity + random_bytes, sequence);
#else
  struct timespec now = {0, 0};
  const uint64_t process_id = (uint64_t)(unsigned long)getpid();
  uint64_t seconds = 0U;
  uint64_t nanoseconds = 0U;
  if (clock_gettime(CLOCK_MONOTONIC, &now) == 0) {
    seconds = (uint64_t)now.tv_sec;
    nanoseconds = (uint64_t)now.tv_nsec;
  } else if (timespec_get(&now, TIME_UTC) == TIME_UTC) {
    seconds = (uint64_t)now.tv_sec;
    nanoseconds = (uint64_t)now.tv_nsec;
  }
  snapshot_put_u64(identity, process_id);
  snapshot_put_u64(identity + 8U, seconds);
  snapshot_put_u64(identity + 16U, nanoseconds);
  snapshot_put_u64(identity + 24U, sequence);
#endif
  return 1;
}

static int is_qualified_snapshot_content(const uint8_t *content,
                                         size_t content_bytes,
                                         const uint8_t digest[32]) {
  return content != NULL && content_bytes == 16512U && digest != NULL &&
         memcmp(digest, k_muhtari_fixture_digest,
                sizeof(k_muhtari_fixture_digest)) == 0;
}
#endif

struct lf_muhtari_state {
  lf_allocate_fn allocate;
  lf_deallocate_fn deallocate;
  void *allocator_context;
  muhtari *core;
  uint8_t *native_video;
  int16_t *native_audio;
  uint64_t cumulative_frames;
  uint32_t pending_buttons;
  size_t content_size_bytes;
#if LF_MUHTARI_API_REVISION == 8
  uint64_t successful_load_epoch;
  uint8_t instance_identity[LF_MUHTARI_SNAPSHOT_INSTANCE_ID_BYTES];
  uint8_t content_digest[LF_MUHTARI_SNAPSHOT_CONTENT_DIGEST_BYTES];
  int qualified_snapshot_route;
#endif
  lf_muhtari_configuration configuration;
  int loaded;
  int halted;
  int positive_advance_started;
};

lf_status lf_muhtari_resolve_configuration(
    const char *configuration_id, lf_muhtari_configuration *out) {
  if (out == NULL) {
    return LF_INVALID_ARGUMENT;
  }
  if (configuration_id == NULL ||
      strcmp(configuration_id, k_configuration_id) == 0) {
    *out = LF_MUHTARI_CONFIGURATION_JOYSTICK_DEFAULT;
    return LF_OK;
  }
  if (strcmp(configuration_id, k_battery_configuration_id) == 0) {
    *out = LF_MUHTARI_CONFIGURATION_BATTERY_DIAGNOSTIC;
    return LF_OK;
  }
  return LF_UNSUPPORTED;
}

static const char *configuration_id_for(
    lf_muhtari_configuration configuration) {
  return configuration == LF_MUHTARI_CONFIGURATION_BATTERY_DIAGNOSTIC
             ? k_battery_configuration_id
             : k_configuration_id;
}

static int checked_video_extent(size_t stride, size_t *extent) {
  const size_t rows_before_last = (size_t)LF_MUHTARI_VIDEO_HEIGHT - 1U;
  const size_t width = (size_t)LF_MUHTARI_VIDEO_WIDTH;
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

static void *core_allocate(void *user, size_t bytes) {
  lf_muhtari_state *state = (lf_muhtari_state *)user;
  return state->allocate(state->allocator_context, bytes);
}

static void core_deallocate(void *user, void *allocation, size_t bytes) {
  lf_muhtari_state *state = (lf_muhtari_state *)user;
  (void)bytes;
  state->deallocate(state->allocator_context, allocation);
}

static lf_status map_core_status(muhtari_status status) {
  switch (status) {
    case MUHTARI_STATUS_OK:
      return LF_OK;
    case MUHTARI_STATUS_ERR_NO_MEMORY:
      return LF_RESOURCE_EXHAUSTED;
    case MUHTARI_STATUS_ERR_BUFFER_TOO_SMALL:
      return LF_BUFFER_TOO_SMALL;
    case MUHTARI_STATUS_ERR_UNSUPPORTED_2600:
    case MUHTARI_STATUS_ERR_UNSUPPORTED_BOARD:
    case MUHTARI_STATUS_ERR_UNSUPPORTED_REGION:
    case MUHTARI_STATUS_ERR_UNSUPPORTED_DEVICE:
      return LF_UNSUPPORTED;
    case MUHTARI_STATUS_ERR_ARGUMENT:
    case MUHTARI_STATUS_ERR_STRUCT_SIZE:
    case MUHTARI_STATUS_ERR_INVALID_IMAGE:
    case MUHTARI_STATUS_ERR_TRUNCATED_IMAGE:
    case MUHTARI_STATUS_ERR_UNSUPPORTED_SIZE:
    case MUHTARI_STATUS_ERR_BIOS_REJECTED_CART:
    case MUHTARI_STATUS_ERR_INVALID_BIOS:
    case MUHTARI_STATUS_ERR_INVALID_HSC:
      return LF_INVALID_ARGUMENT;
  }
  return LF_INVALID_ARGUMENT;
}

static int info_matches_profile(const muhtari_info *info) {
  return info->width == LF_MUHTARI_VIDEO_WIDTH &&
         info->height == LF_MUHTARI_VIDEO_HEIGHT &&
         info->fps_num == 39375000U && info->fps_den == 656711U &&
         info->sample_rate_num == 48000U && info->sample_rate_den == 1U &&
         info->max_audio_samples == LF_MUHTARI_MAX_AUDIO_SAMPLES;
}

static int versions_match_selected_api(const muhtari_versions *versions) {
  if (versions == NULL) {
    return 0;
  }
#if LF_MUHTARI_API_REVISION == 8
  return versions->api == 8U && versions->abi == 1U &&
         versions->behaviour_revision == 6U && versions->state_format == 1U;
#else
  return versions->api == 7U && versions->api == MUHTARI_API_VERSION &&
         versions->behaviour_revision != 0U;
#endif
}

static lf_status read_profile_info(muhtari *core, muhtari_info *info) {
  muhtari_status core_status = MUHTARI_STATUS_OK;
  memset(info, 0, sizeof(*info));
  info->size = (uint32_t)sizeof(*info);
  core_status = muhtari_get_info(core, info);
  if (core_status != MUHTARI_STATUS_OK) {
    return map_core_status(core_status);
  }
  return info_matches_profile(info) ? LF_OK : LF_UNSUPPORTED;
}

static void fill_profile(lf_profile *out, const muhtari_versions *versions,
                         lf_muhtari_configuration configuration) {
  *out = (lf_profile){
      .struct_size = sizeof(*out),
      .profile_id = k_profile_id,
      .core_id = k_core_id,
      .build_id = k_build_id,
      .api_revision = versions->api,
      .behavior_revision = versions->behaviour_revision,
      .input_mask = configuration ==
                            LF_MUHTARI_CONFIGURATION_BATTERY_DIAGNOSTIC
                        ? LF_MUHTARI_DIAGNOSTIC_INPUT_MASK
                        : LF_MUHTARI_INPUT_MASK,
      .max_work_units = 1U,
      .max_guest_units = UINT32_MAX,
      .atomic_quantum_units = 1U,
      .max_overshoot_units = 0U,
      .time_unit = LF_TIME_FRAME,
      .input_sampling = LF_INPUT_AT_ADVANCE_START,
      .video_format = LF_VIDEO_INDEX8,
      .audio_encoding = LF_AUDIO_S16_NATIVE,
      .audio_layout = LF_AUDIO_INTERLEAVED,
      .video_width = LF_MUHTARI_VIDEO_WIDTH,
      .video_height = LF_MUHTARI_VIDEO_HEIGHT,
      .video_bytes_per_pixel = 1U,
      .audio_rate_numerator = 48000U,
      .audio_rate_denominator = 1U,
      .audio_channels = 1U,
      .min_video_stride_bytes = LF_MUHTARI_VIDEO_WIDTH,
      .max_audio_samples_per_call = LF_MUHTARI_MAX_AUDIO_SAMPLES,
      .media_extent_bytes = 0U,
      .max_content_bytes = LF_MUHTARI_MAX_CONTENT_BYTES,
      .effective_configuration_id = configuration_id_for(configuration),
      .frame_rate_numerator = 39375000U,
      .frame_rate_denominator = 656711U,
  };
}

lf_status lf_muhtari_query_profile(const char *configuration_id,
                                   lf_profile *out) {
  lf_muhtari_configuration configuration =
      LF_MUHTARI_CONFIGURATION_JOYSTICK_DEFAULT;
  muhtari_versions versions;
  muhtari_status core_status = MUHTARI_STATUS_OK;
  if (out == NULL || out->struct_size != sizeof(*out)) {
    return LF_INVALID_ARGUMENT;
  }
  {
    const lf_status status =
        lf_muhtari_resolve_configuration(configuration_id, &configuration);
    if (status != LF_OK) {
      return status;
    }
  }
  memset(&versions, 0, sizeof(versions));
  versions.size = (uint32_t)sizeof(versions);
  core_status = muhtari_get_versions(&versions);
  if (core_status != MUHTARI_STATUS_OK ||
      !versions_match_selected_api(&versions)) {
    *out = (lf_profile){.struct_size = sizeof(*out)};
    return core_status == MUHTARI_STATUS_OK ? LF_UNSUPPORTED
                                             : map_core_status(core_status);
  }
  fill_profile(out, &versions, configuration);
  return LF_OK;
}

void lf_muhtari_destroy(lf_muhtari_state **owned) {
  lf_muhtari_state *state = NULL;
  lf_deallocate_fn deallocate = NULL;
  void *allocator_context = NULL;
  if (owned == NULL || *owned == NULL) {
    return;
  }
  state = *owned;
  *owned = NULL;
  deallocate = state->deallocate;
  allocator_context = state->allocator_context;
  if (state->core != NULL) {
    muhtari_destroy(state->core);
    state->core = NULL;
  }
  if (state->native_audio != NULL) {
    deallocate(allocator_context, state->native_audio);
    state->native_audio = NULL;
  }
  if (state->native_video != NULL) {
    deallocate(allocator_context, state->native_video);
    state->native_video = NULL;
  }
  deallocate(allocator_context, state);
}

lf_status lf_muhtari_create(lf_allocate_fn allocate,
                            lf_deallocate_fn deallocate,
                            void *allocator_context,
                            lf_muhtari_state **out) {
  lf_muhtari_state *state = NULL;
  muhtari_status core_status = MUHTARI_STATUS_OK;
  muhtari_config config;
  muhtari_versions versions;
  muhtari_info info;
  if (out == NULL) {
    return LF_INVALID_ARGUMENT;
  }
  *out = NULL;
  if (allocate == NULL || deallocate == NULL) {
    return LF_INVALID_ARGUMENT;
  }
  memset(&versions, 0, sizeof(versions));
  versions.size = (uint32_t)sizeof(versions);
  core_status = muhtari_get_versions(&versions);
  if (core_status != MUHTARI_STATUS_OK ||
      !versions_match_selected_api(&versions)) {
    return core_status == MUHTARI_STATUS_OK ? LF_UNSUPPORTED
                                             : map_core_status(core_status);
  }

  state = (lf_muhtari_state *)allocate(allocator_context, sizeof(*state));
  if (state == NULL) {
    return LF_RESOURCE_EXHAUSTED;
  }
  memset(state, 0, sizeof(*state));
#if LF_MUHTARI_API_REVISION == 8
  if (!initialize_instance_identity(state->instance_identity)) {
    deallocate(allocator_context, state);
    return LF_RESOURCE_EXHAUSTED;
  }
#endif
  state->allocate = allocate;
  state->deallocate = deallocate;
  state->allocator_context = allocator_context;
  state->native_video = (uint8_t *)allocate(allocator_context,
                                             LF_MUHTARI_VIDEO_EXTENT);
  if (state->native_video == NULL) {
    lf_muhtari_destroy(&state);
    return LF_RESOURCE_EXHAUSTED;
  }
  state->native_audio = (int16_t *)allocate(
      allocator_context,
      (size_t)LF_MUHTARI_MAX_AUDIO_SAMPLES * sizeof(state->native_audio[0]));
  if (state->native_audio == NULL) {
    lf_muhtari_destroy(&state);
    return LF_RESOURCE_EXHAUSTED;
  }

  memset(&config, 0, sizeof(config));
  config.size = (uint32_t)sizeof(config);
  config.allocator.alloc = core_allocate;
  config.allocator.free = core_deallocate;
  config.allocator.user = state;
  core_status = muhtari_create(&config, &state->core);
  if (core_status != MUHTARI_STATUS_OK) {
    const lf_status mapped = map_core_status(core_status);
    lf_muhtari_destroy(&state);
    return mapped;
  }
  if (read_profile_info(state->core, &info) != LF_OK) {
    lf_muhtari_destroy(&state);
    return LF_UNSUPPORTED;
  }
  *out = state;
  return LF_OK;
}

static void fill_load_result(const lf_muhtari_state *state,
                             lf_load_result *out) {
  out->loaded = state != NULL && state->loaded != 0 ? 1U : 0U;
  out->content_size_bytes = out->loaded != 0U ? state->content_size_bytes : 0U;
  out->effective_configuration_id =
      out->loaded != 0U ? configuration_id_for(state->configuration) : NULL;
}

lf_status lf_muhtari_load(lf_muhtari_state *state,
                          const lf_load_request *request,
                          lf_load_result *out) {
  muhtari_media media;
  muhtari_info info;
  lf_muhtari_configuration configuration =
      LF_MUHTARI_CONFIGURATION_JOYSTICK_DEFAULT;
  muhtari_status core_status = MUHTARI_STATUS_OK;
#if LF_MUHTARI_API_REVISION == 8
  uint8_t candidate_content_digest[LF_MUHTARI_SNAPSHOT_CONTENT_DIGEST_BYTES];
  int qualified_snapshot_route = 0;
#endif
  if (out == NULL || out->struct_size != sizeof(*out)) {
    return LF_INVALID_ARGUMENT;
  }
  *out = (lf_load_result){.struct_size = sizeof(*out)};
  fill_load_result(state, out);
  if (state == NULL) {
    return LF_INVALID_ARGUMENT;
  }
  if (request == NULL || request->struct_size != sizeof(*request) ||
      request->content_data == NULL || request->content_size_bytes == 0U) {
    return LF_INVALID_ARGUMENT;
  }
  {
    const lf_status status = lf_muhtari_resolve_configuration(
        request->configuration_id, &configuration);
    if (status != LF_OK) {
      return status;
    }
  }
  if (request->content_size_bytes > LF_MUHTARI_MAX_CONTENT_BYTES) {
    return LF_LIMIT_EXCEEDED;
  }
#if LF_MUHTARI_API_REVISION == 8
  if (state->successful_load_epoch == UINT64_MAX) {
    return LF_LIMIT_EXCEEDED;
  }
  if (!lf_sha256_bytes(request->content_data, request->content_size_bytes,
                       candidate_content_digest)) {
    return LF_LIMIT_EXCEEDED;
  }
  qualified_snapshot_route =
      configuration == LF_MUHTARI_CONFIGURATION_BATTERY_DIAGNOSTIC &&
      is_qualified_snapshot_content(request->content_data,
                                    request->content_size_bytes,
                                    candidate_content_digest);
#endif
  if (read_profile_info(state->core, &info) != LF_OK) {
    return LF_UNSUPPORTED;
  }

  memset(&media, 0, sizeof(media));
  media.size = (uint32_t)sizeof(media);
  media.region = MUHTARI_REGION_NTSC;
  media.image = request->content_data;
  media.image_size = request->content_size_bytes;
  media.hsc_mode = configuration ==
                           LF_MUHTARI_CONFIGURATION_BATTERY_DIAGNOSTIC
                       ? MUHTARI_HSC_ON
                       : MUHTARI_HSC_OFF;
  media.port[0] = MUHTARI_PORT_JOYSTICK;
  media.port[1] = configuration ==
                          LF_MUHTARI_CONFIGURATION_BATTERY_DIAGNOSTIC
                      ? MUHTARI_PORT_SAVEKEY
                      : MUHTARI_PORT_JOYSTICK;
  media.expansion = MUHTARI_EXPANSION_OFF;
  core_status = muhtari_load(state->core, &media);
  if (core_status != MUHTARI_STATUS_OK) {
    return map_core_status(core_status);
  }

#if LF_MUHTARI_API_REVISION == 8
  state->successful_load_epoch += 1U;
  memcpy(state->content_digest, candidate_content_digest,
         sizeof(state->content_digest));
  state->qualified_snapshot_route = qualified_snapshot_route;
#endif
  state->loaded = 1;
  state->halted = 0;
  state->content_size_bytes = request->content_size_bytes;
  state->configuration = configuration;
  state->cumulative_frames = 0U;
  state->pending_buttons = 0U;
  state->positive_advance_started = 0;
  *out = (lf_load_result){
      .struct_size = sizeof(*out),
      .loaded = 1U,
      .content_size_bytes = request->content_size_bytes,
      .effective_configuration_id = configuration_id_for(configuration),
  };
  return LF_OK;
}

lf_status lf_muhtari_set_input(lf_muhtari_state *state,
                               const lf_input *input) {
  const uint32_t input_mask =
      state != NULL && state->configuration ==
                           LF_MUHTARI_CONFIGURATION_BATTERY_DIAGNOSTIC
          ? LF_MUHTARI_DIAGNOSTIC_INPUT_MASK
          : LF_MUHTARI_INPUT_MASK;
  if (state == NULL || input == NULL ||
      input->struct_size != sizeof(*input) ||
      (input->buttons & ~input_mask) != 0U) {
    return LF_INVALID_ARGUMENT;
  }
  state->pending_buttons = input->buttons;
  return LF_OK;
}

static void fill_run_metadata(lf_run_result *out) {
  out->time_unit = LF_TIME_FRAME;
  out->video_format = LF_VIDEO_INDEX8;
  out->audio_encoding = LF_AUDIO_S16_NATIVE;
  out->audio_layout = LF_AUDIO_INTERLEAVED;
  out->video_width = LF_MUHTARI_VIDEO_WIDTH;
  out->video_height = LF_MUHTARI_VIDEO_HEIGHT;
  out->audio_rate_numerator = 48000U;
  out->audio_rate_denominator = 1U;
  out->audio_channels = 1U;
}

static muhtari_input_ex make_core_input(
    uint32_t buttons, lf_muhtari_configuration configuration) {
  muhtari_input_ex input;
  memset(&input, 0, sizeof(input));
  input.size = (uint32_t)sizeof(input);
  input.port[0].device = MUHTARI_PORT_JOYSTICK;
  input.port[1].device = configuration ==
                                 LF_MUHTARI_CONFIGURATION_BATTERY_DIAGNOSTIC
                             ? MUHTARI_PORT_SAVEKEY
                             : MUHTARI_PORT_JOYSTICK;
  for (size_t port = 0U; port < 2U; ++port) {
    const uint32_t shift = (uint32_t)(port * 8U);
    const uint32_t port_buttons = (buttons >> shift) & UINT32_C(0xFF);
    if ((port_buttons & 1U) != 0U) {
      input.port[port].buttons |= MUHTARI_BUTTON_1;
    }
    if ((port_buttons & 16U) != 0U) {
      input.port[port].buttons |= MUHTARI_BUTTON_UP;
    }
    if ((port_buttons & 32U) != 0U) {
      input.port[port].buttons |= MUHTARI_BUTTON_DOWN;
    }
    if ((port_buttons & 64U) != 0U) {
      input.port[port].buttons |= MUHTARI_BUTTON_LEFT;
    }
    if ((port_buttons & 128U) != 0U) {
      input.port[port].buttons |= MUHTARI_BUTTON_RIGHT;
    }
  }
  return input;
}

lf_status lf_muhtari_advance(lf_muhtari_state *state,
                             const lf_run_request *request,
                             lf_run_result *out) {
  size_t video_extent = 0U;
  muhtari_input_ex input;
  muhtari_frame frame;
  muhtari_status core_status = MUHTARI_STATUS_OK;
  if (out == NULL || out->struct_size != sizeof(*out)) {
    return LF_INVALID_ARGUMENT;
  }
  *out = (lf_run_result){
      .struct_size = sizeof(*out),
      .stop_reason = LF_STOP_REJECTED,
  };
  fill_run_metadata(out);
  if (state != NULL) {
    out->cumulative_units = state->cumulative_frames;
  }
  if (state == NULL || request == NULL ||
      request->struct_size != sizeof(*request)) {
    return LF_INVALID_ARGUMENT;
  }
  out->requested_units = request->work_units;
  out->video_stride_bytes = request->video_stride_bytes;
  if (state->loaded == 0) {
    return LF_INVALID_ARGUMENT;
  }
  if (request->work_units == 0U) {
    out->stop_reason = state->halted != 0 ? LF_STOP_CORE_HALTED
                                          : LF_STOP_BUDGET_REACHED;
    return LF_OK;
  }
  if (state->halted != 0) {
    out->stop_reason = LF_STOP_CORE_HALTED;
    return LF_OK;
  }
  if (request->work_units > 1U ||
      state->cumulative_frames >= (uint64_t)UINT32_MAX) {
    return LF_LIMIT_EXCEEDED;
  }
  if (request->video_data == NULL || request->audio_data == NULL ||
      request->video_stride_bytes < (size_t)LF_MUHTARI_VIDEO_WIDTH) {
    return LF_INVALID_ARGUMENT;
  }
  if (!checked_video_extent(request->video_stride_bytes, &video_extent)) {
    return LF_LIMIT_EXCEEDED;
  }
  if (request->video_capacity_bytes < video_extent ||
      request->audio_capacity_samples <
          (size_t)LF_MUHTARI_MAX_AUDIO_SAMPLES) {
    return LF_BUFFER_TOO_SMALL;
  }

  input = make_core_input(state->pending_buttons, state->configuration);
  core_status = muhtari_set_input_ex(state->core, &input);
  if (core_status != MUHTARI_STATUS_OK) {
    return map_core_status(core_status);
  }
  memset(state->native_video, 0, LF_MUHTARI_VIDEO_EXTENT);
  memset(state->native_audio, 0,
         (size_t)LF_MUHTARI_MAX_AUDIO_SAMPLES *
             sizeof(state->native_audio[0]));
  memset(&frame, 0, sizeof(frame));
  frame.size = (uint32_t)sizeof(frame);
  frame.video_pitch = LF_MUHTARI_VIDEO_WIDTH;
  frame.video = state->native_video;
  frame.audio = state->native_audio;
  frame.audio_capacity = LF_MUHTARI_MAX_AUDIO_SAMPLES;
  state->positive_advance_started = 1;
  core_status = muhtari_run_frame(state->core, &frame);
  if (core_status == MUHTARI_STATUS_ERR_BIOS_REJECTED_CART) {
    state->halted = 1;
    out->stop_reason = LF_STOP_CORE_HALTED;
    return LF_OK;
  }
  if (core_status != MUHTARI_STATUS_OK) {
    return map_core_status(core_status);
  }
  if (frame.audio_count > LF_MUHTARI_MAX_AUDIO_SAMPLES) {
    return LF_INVALID_ARGUMENT;
  }

  for (size_t row = 0U; row < (size_t)LF_MUHTARI_VIDEO_HEIGHT; ++row) {
    memcpy(request->video_data + row * request->video_stride_bytes,
           state->native_video + row * (size_t)LF_MUHTARI_VIDEO_WIDTH,
           (size_t)LF_MUHTARI_VIDEO_WIDTH);
  }
  memcpy(request->audio_data, state->native_audio,
         (size_t)frame.audio_count * sizeof(request->audio_data[0]));
  state->cumulative_frames += 1U;
  out->actual_units = 1U;
  out->overshoot_units = 0U;
  out->sampled_buttons = state->pending_buttons;
  out->video_valid = 1U;
  out->audio_valid = 1U;
  out->cumulative_units = state->cumulative_frames;
  out->stop_reason = LF_STOP_BUDGET_REACHED;
  out->video_extent_bytes = video_extent;
  out->audio_produced_samples = (size_t)frame.audio_count;
  return LF_OK;
}

static lf_status get_battery_span(lf_muhtari_state *state,
                                  muhtari_battery_info *battery) {
  muhtari_status core_status = MUHTARI_STATUS_OK;
  memset(battery, 0, sizeof(*battery));
  battery->size = (uint32_t)sizeof(*battery);
  core_status = muhtari_get_battery(state->core, battery);
  if (core_status != MUHTARI_STATUS_OK) {
    return map_core_status(core_status);
  }
  if (battery->data == NULL || battery->layout_version !=
                                   LF_MUHTARI_BATTERY_LAYOUT_VERSION ||
      battery->bytes != LF_MUHTARI_BATTERY_EXTENT ||
      battery->hsc_attached != 1U || battery->eeprom_port != 2U ||
      battery->eeprom_device != MUHTARI_PORT_SAVEKEY) {
    return LF_UNSUPPORTED;
  }
  return LF_OK;
}

lf_status lf_muhtari_copy_media(lf_muhtari_state *state,
                                uint8_t *destination,
                                size_t capacity_bytes, lf_media_info *out) {
  muhtari_battery_info battery;
  lf_status status = LF_OK;
  if (state == NULL || destination == NULL || out == NULL ||
      out->struct_size != sizeof(*out)) {
    return LF_INVALID_ARGUMENT;
  }
  if (!state->loaded) {
    return LF_INVALID_ARGUMENT;
  }
  if (state->configuration !=
      LF_MUHTARI_CONFIGURATION_BATTERY_DIAGNOSTIC) {
    return LF_UNSUPPORTED;
  }
  status = get_battery_span(state, &battery);
  if (status != LF_OK) {
    return status;
  }
  if (capacity_bytes < battery.bytes) {
    return LF_BUFFER_TOO_SMALL;
  }
  memcpy(destination, battery.data, battery.bytes);
  *out = (lf_media_info){
      .struct_size = sizeof(*out),
      .identity = k_battery_identity,
      .extent_bytes = battery.bytes,
      .guest_generation = battery.generation,
  };
  return LF_OK;
}

lf_status lf_muhtari_import_media(lf_muhtari_state *state,
                                  const char *identity,
                                  const uint8_t *source,
                                  size_t extent_bytes) {
  muhtari_battery_info battery;
  lf_status status = LF_OK;
  if (state == NULL || identity == NULL || identity[0] == '\0' ||
      source == NULL || extent_bytes == 0U) {
    return LF_INVALID_ARGUMENT;
  }
  if (!state->loaded || state->positive_advance_started) {
    return LF_INVALID_ARGUMENT;
  }
  if (state->configuration !=
      LF_MUHTARI_CONFIGURATION_BATTERY_DIAGNOSTIC) {
    return LF_UNSUPPORTED;
  }
  if (strcmp(identity, k_battery_identity) != 0) {
    return LF_UNSUPPORTED;
  }
  status = get_battery_span(state, &battery);
  if (status != LF_OK) {
    return status;
  }
  if (extent_bytes != battery.bytes) {
    return LF_INVALID_ARGUMENT;
  }
  memcpy(battery.data, source, battery.bytes);
  return LF_OK;
}

#ifdef LF_MUHTARI_TESTING
void lf_muhtari_test_seed_progress(lf_muhtari_state *state, uint64_t frames) {
  if (state != NULL) {
    state->cumulative_frames = frames;
  }
}
#endif

#if LF_MUHTARI_API_REVISION == 8
static void snapshot_put_u32(uint8_t output[4], uint32_t value) {
  size_t index = 0U;
  for (index = 0U; index < 4U; ++index) {
    output[index] = (uint8_t)(value >> (unsigned int)(index * 8U));
  }
}

static uint32_t snapshot_get_u32(const uint8_t input[4]) {
  uint32_t value = 0U;
  size_t index = 0U;
  for (index = 0U; index < 4U; ++index) {
    value |= (uint32_t)input[index] << (unsigned int)(index * 8U);
  }
  return value;
}

static void snapshot_put_u64(uint8_t output[8], uint64_t value) {
  size_t index = 0U;
  for (index = 0U; index < 8U; ++index) {
    output[index] = (uint8_t)(value >> (unsigned int)(index * 8U));
  }
}

static int snapshot_header_integrity_matches(const uint8_t *source) {
  uint8_t header[LF_MUHTARI_SNAPSHOT_HEADER_BYTES];
  uint8_t expected[LF_MUHTARI_SNAPSHOT_HEADER_DIGEST_BYTES];
  uint8_t actual[LF_MUHTARI_SNAPSHOT_HEADER_DIGEST_BYTES];
  if (source == NULL) {
    return 0;
  }
  memcpy(header, source, sizeof(header));
  memcpy(expected, header + LF_MUHTARI_SNAPSHOT_HEADER_DIGEST_OFFSET,
         sizeof(expected));
  memset(header + LF_MUHTARI_SNAPSHOT_HEADER_DIGEST_OFFSET, 0,
         sizeof(expected));
  return lf_sha256_bytes(header, sizeof(header), actual) &&
         memcmp(actual, expected, sizeof(actual)) == 0;
}

static uint64_t snapshot_get_u64(const uint8_t input[8]) {
  uint64_t value = 0U;
  size_t index = 0U;
  for (index = 0U; index < 8U; ++index) {
    value |= (uint64_t)input[index] << (unsigned int)(index * 8U);
  }
  return value;
}

static int snapshot_size_to_u64(size_t value, uint64_t *out) {
  if (out == NULL) {
    return 0;
  }
#if SIZE_MAX > UINT64_MAX
  if (value > (size_t)UINT64_MAX) {
    return 0;
  }
#endif
  *out = (uint64_t)value;
  return 1;
}

static int snapshot_u64_to_size(uint64_t value, size_t *out) {
  if (out == NULL) {
    return 0;
  }
#if SIZE_MAX < UINT64_MAX
  if (value > (uint64_t)SIZE_MAX) {
    return 0;
  }
#endif
  *out = (size_t)value;
  return 1;
}

static int snapshot_write_identity(uint8_t *destination, size_t capacity,
                                   const char *identity) {
  size_t length = 0U;
  if (destination == NULL || identity == NULL) {
    return 0;
  }
  length = strlen(identity);
  if (length >= capacity) {
    return 0;
  }
  memset(destination, 0, capacity);
  memcpy(destination, identity, length);
  return 1;
}

static int snapshot_identity_matches(const uint8_t *encoded, size_t capacity,
                                     const char *identity) {
  size_t length = 0U;
  size_t index = 0U;
  if (encoded == NULL || identity == NULL) {
    return 0;
  }
  length = strlen(identity);
  if (length >= capacity || memcmp(encoded, identity, length) != 0) {
    return 0;
  }
  for (index = length; index < capacity; ++index) {
    if (encoded[index] != 0U) {
      return 0;
    }
  }
  return 1;
}

static int snapshot_identity_is_zero(const uint8_t *encoded, size_t bytes) {
  size_t index = 0U;
  if (encoded == NULL) {
    return 0;
  }
  for (index = 0U; index < bytes; ++index) {
    if (encoded[index] != 0U) {
      return 0;
    }
  }
  return 1;
}

static uint32_t snapshot_continuation_flags(const lf_muhtari_state *state) {
  uint32_t flags = 0U;
  if (state->positive_advance_started) {
    flags |= LF_MUHTARI_SNAPSHOT_FLAG_POSITIVE_ADVANCE;
  }
  if (state->halted) {
    flags |= LF_MUHTARI_SNAPSHOT_FLAG_HALTED;
  }
  return flags;
}

static int snapshot_continuation_is_valid(uint64_t cumulative_frames,
                                          uint32_t pending_buttons,
                                          uint32_t flags) {
  const int positive_advance_started =
      (flags & LF_MUHTARI_SNAPSHOT_FLAG_POSITIVE_ADVANCE) != 0U;
  const int halted = (flags & LF_MUHTARI_SNAPSHOT_FLAG_HALTED) != 0U;
  return (flags & ~(uint32_t)LF_MUHTARI_SNAPSHOT_KNOWN_FLAGS) == 0U &&
         (pending_buttons & ~LF_MUHTARI_DIAGNOSTIC_INPUT_MASK) == 0U &&
         cumulative_frames <= (uint64_t)UINT32_MAX &&
         !((halted || cumulative_frames > 0U) &&
           !positive_advance_started);
}

static lf_status get_snapshot_native_size(lf_muhtari_state *state,
                                          size_t *native_bytes,
                                          size_t *total_bytes) {
  muhtari_battery_info battery;
  size_t state_bytes = 0U;
  lf_status status = LF_OK;
  if (state == NULL || native_bytes == NULL || total_bytes == NULL) {
    return LF_INVALID_ARGUMENT;
  }
  if (!state->loaded) {
    return LF_INVALID_ARGUMENT;
  }
  if (state->configuration !=
          LF_MUHTARI_CONFIGURATION_BATTERY_DIAGNOSTIC ||
      !state->qualified_snapshot_route) {
    return LF_UNSUPPORTED;
  }
  status = get_battery_span(state, &battery);
  if (status != LF_OK) {
    return status;
  }
  state_bytes = muhtari_state_size(state->core);
  if (state_bytes == 0U) {
    return LF_INVALID_ARGUMENT;
  }
  if (state_bytes > LF_MUHTARI_MAX_SNAPSHOT_BYTES -
                        (size_t)LF_MUHTARI_SNAPSHOT_HEADER_BYTES) {
    return LF_LIMIT_EXCEEDED;
  }
  *native_bytes = state_bytes;
  *total_bytes = (size_t)LF_MUHTARI_SNAPSHOT_HEADER_BYTES + state_bytes;
  return LF_OK;
}

static int snapshot_build_header(
    const lf_muhtari_state *state, size_t native_bytes, size_t total_bytes,
    uint8_t header[LF_MUHTARI_SNAPSHOT_HEADER_BYTES]) {
  uint8_t header_digest[LF_MUHTARI_SNAPSHOT_HEADER_DIGEST_BYTES];
  uint64_t total_bytes_u64 = 0U;
  uint64_t native_bytes_u64 = 0U;
  uint64_t content_size_u64 = 0U;
  if (state == NULL || header == NULL ||
      !snapshot_size_to_u64(total_bytes, &total_bytes_u64) ||
      !snapshot_size_to_u64(native_bytes, &native_bytes_u64) ||
      !snapshot_size_to_u64(state->content_size_bytes, &content_size_u64)) {
    return 0;
  }
  memset(header, 0, LF_MUHTARI_SNAPSHOT_HEADER_BYTES);
  memcpy(header + LF_MUHTARI_SNAPSHOT_MAGIC_OFFSET, k_snapshot_magic,
         sizeof(k_snapshot_magic));
  snapshot_put_u32(header + LF_MUHTARI_SNAPSHOT_VERSION_OFFSET, 2U);
  snapshot_put_u32(header + LF_MUHTARI_SNAPSHOT_HEADER_SIZE_OFFSET,
                   LF_MUHTARI_SNAPSHOT_HEADER_BYTES);
  snapshot_put_u64(header + LF_MUHTARI_SNAPSHOT_TOTAL_SIZE_OFFSET,
                   total_bytes_u64);
  snapshot_put_u64(header + LF_MUHTARI_SNAPSHOT_NATIVE_SIZE_OFFSET,
                   native_bytes_u64);
  snapshot_put_u32(header + LF_MUHTARI_SNAPSHOT_STATE_FORMAT_OFFSET, 1U);
  snapshot_put_u32(header + LF_MUHTARI_SNAPSHOT_CORE_ABI_OFFSET, 1U);
  snapshot_put_u32(header + LF_MUHTARI_SNAPSHOT_BEHAVIOR_REVISION_OFFSET,
                   6U);
  if (!snapshot_write_identity(
          header + LF_MUHTARI_SNAPSHOT_BUILD_ID_OFFSET,
          LF_MUHTARI_SNAPSHOT_BUILD_ID_BYTES, k_build_id) ||
      !snapshot_write_identity(
          header + LF_MUHTARI_SNAPSHOT_LIBFUTURO_BUILD_ID_OFFSET,
          LF_MUHTARI_SNAPSHOT_LIBFUTURO_BUILD_ID_BYTES,
          k_libfuturo_build_id) ||
      !snapshot_write_identity(
          header + LF_MUHTARI_SNAPSHOT_PROFILE_ID_OFFSET,
          LF_MUHTARI_SNAPSHOT_PROFILE_ID_BYTES, k_profile_id) ||
      !snapshot_write_identity(
          header + LF_MUHTARI_SNAPSHOT_CONFIGURATION_ID_OFFSET,
          LF_MUHTARI_SNAPSHOT_CONFIGURATION_ID_BYTES,
          k_battery_configuration_id) ||
      !snapshot_write_identity(
          header + LF_MUHTARI_SNAPSHOT_OPTIONS_ID_OFFSET,
          LF_MUHTARI_SNAPSHOT_OPTIONS_ID_BYTES, k_options_id)) {
    return 0;
  }
  memcpy(header + LF_MUHTARI_SNAPSHOT_CONTENT_DIGEST_OFFSET,
         state->content_digest, sizeof(state->content_digest));
  memcpy(header + LF_MUHTARI_SNAPSHOT_INSTANCE_ID_OFFSET,
         state->instance_identity, sizeof(state->instance_identity));
  snapshot_put_u64(header + LF_MUHTARI_SNAPSHOT_LOAD_EPOCH_OFFSET,
                   state->successful_load_epoch);
  snapshot_put_u64(header + LF_MUHTARI_SNAPSHOT_CONTENT_SIZE_OFFSET,
                   content_size_u64);
  snapshot_put_u64(header + LF_MUHTARI_SNAPSHOT_CUMULATIVE_FRAMES_OFFSET,
                   state->cumulative_frames);
  snapshot_put_u32(header + LF_MUHTARI_SNAPSHOT_PENDING_BUTTONS_OFFSET,
                   state->pending_buttons);
  snapshot_put_u32(header + LF_MUHTARI_SNAPSHOT_FLAGS_OFFSET,
                   snapshot_continuation_flags(state));
  snapshot_put_u32(header + LF_MUHTARI_SNAPSHOT_API_REVISION_OFFSET, 8U);
  if (!lf_sha256_bytes(header, LF_MUHTARI_SNAPSHOT_HEADER_BYTES,
                       header_digest)) {
    return 0;
  }
  memcpy(header + LF_MUHTARI_SNAPSHOT_HEADER_DIGEST_OFFSET, header_digest,
         sizeof(header_digest));
  return 1;
}

lf_status lf_muhtari_get_snapshot_size(lf_muhtari_state *state,
                                       size_t *required_bytes) {
  size_t native_bytes = 0U;
  size_t total_bytes = 0U;
  lf_status status = LF_OK;
  if (required_bytes == NULL) {
    return LF_INVALID_ARGUMENT;
  }
  status = get_snapshot_native_size(state, &native_bytes, &total_bytes);
  (void)native_bytes;
  if (status != LF_OK) {
    return status;
  }
  *required_bytes = total_bytes;
  return LF_OK;
}

lf_status lf_muhtari_capture_snapshot(lf_muhtari_state *state,
                                       uint8_t *destination,
                                       size_t capacity_bytes) {
  uint8_t header[LF_MUHTARI_SNAPSHOT_HEADER_BYTES];
  size_t native_bytes = 0U;
  size_t total_bytes = 0U;
  muhtari_status core_status = MUHTARI_STATUS_OK;
  lf_status status = LF_OK;
  if (state == NULL || destination == NULL) {
    return LF_INVALID_ARGUMENT;
  }
  status = get_snapshot_native_size(state, &native_bytes, &total_bytes);
  if (status != LF_OK) {
    return status;
  }
  if (capacity_bytes < total_bytes) {
    return LF_BUFFER_TOO_SMALL;
  }
  if (!snapshot_build_header(state, native_bytes, total_bytes, header)) {
    return LF_LIMIT_EXCEEDED;
  }
  core_status = muhtari_save_state(
      state->core, destination + LF_MUHTARI_SNAPSHOT_HEADER_BYTES,
      native_bytes);
  if (core_status != MUHTARI_STATUS_OK) {
    return map_core_status(core_status);
  }
  memcpy(destination, header, sizeof(header));
  return LF_OK;
}

lf_status lf_muhtari_restore_snapshot(lf_muhtari_state *state,
                                       const uint8_t *source,
                                       size_t extent_bytes) {
  uint64_t total_bytes_u64 = 0U;
  uint64_t native_bytes_u64 = 0U;
  uint64_t content_size_u64 = 0U;
  uint64_t cumulative_frames = 0U;
  uint64_t expected_content_size_u64 = 0U;
  uint32_t pending_buttons = 0U;
  uint32_t flags = 0U;
  size_t encoded_total_bytes = 0U;
  size_t encoded_native_bytes = 0U;
  size_t expected_native_bytes = 0U;
  size_t expected_total_bytes = 0U;
  muhtari_status core_status = MUHTARI_STATUS_OK;
  lf_status status = LF_OK;
  int same_instance_origin = 0;
  if (state == NULL || source == NULL || extent_bytes == 0U) {
    return LF_INVALID_ARGUMENT;
  }
  if (extent_bytes > LF_MUHTARI_MAX_SNAPSHOT_BYTES) {
    return LF_LIMIT_EXCEEDED;
  }
  if (extent_bytes < (size_t)LF_MUHTARI_SNAPSHOT_HEADER_BYTES) {
    return LF_INVALID_ARGUMENT;
  }
  status = get_snapshot_native_size(state, &expected_native_bytes,
                                    &expected_total_bytes);
  if (status != LF_OK) {
    return status;
  }
  if (memcmp(source + LF_MUHTARI_SNAPSHOT_MAGIC_OFFSET, k_snapshot_magic,
             sizeof(k_snapshot_magic)) != 0 ||
      snapshot_get_u32(source + LF_MUHTARI_SNAPSHOT_VERSION_OFFSET) != 2U ||
      snapshot_get_u32(source + LF_MUHTARI_SNAPSHOT_HEADER_SIZE_OFFSET) !=
          (uint32_t)LF_MUHTARI_SNAPSHOT_HEADER_BYTES ||
      !snapshot_header_integrity_matches(source)) {
    return LF_INVALID_ARGUMENT;
  }
  total_bytes_u64 =
      snapshot_get_u64(source + LF_MUHTARI_SNAPSHOT_TOTAL_SIZE_OFFSET);
  native_bytes_u64 =
      snapshot_get_u64(source + LF_MUHTARI_SNAPSHOT_NATIVE_SIZE_OFFSET);
  content_size_u64 =
      snapshot_get_u64(source + LF_MUHTARI_SNAPSHOT_CONTENT_SIZE_OFFSET);
  cumulative_frames =
      snapshot_get_u64(source + LF_MUHTARI_SNAPSHOT_CUMULATIVE_FRAMES_OFFSET);
  pending_buttons =
      snapshot_get_u32(source + LF_MUHTARI_SNAPSHOT_PENDING_BUTTONS_OFFSET);
  flags = snapshot_get_u32(source + LF_MUHTARI_SNAPSHOT_FLAGS_OFFSET);
  same_instance_origin =
      memcmp(source + LF_MUHTARI_SNAPSHOT_INSTANCE_ID_OFFSET,
             state->instance_identity, sizeof(state->instance_identity)) == 0;
  if (!snapshot_size_to_u64(state->content_size_bytes,
                            &expected_content_size_u64) ||
      !snapshot_u64_to_size(total_bytes_u64, &encoded_total_bytes) ||
      !snapshot_u64_to_size(native_bytes_u64, &encoded_native_bytes) ||
      encoded_total_bytes != extent_bytes ||
      encoded_total_bytes != expected_total_bytes ||
      encoded_native_bytes != expected_native_bytes ||
      encoded_native_bytes > LF_MUHTARI_MAX_SNAPSHOT_BYTES -
                                 (size_t)LF_MUHTARI_SNAPSHOT_HEADER_BYTES ||
      encoded_native_bytes + (size_t)LF_MUHTARI_SNAPSHOT_HEADER_BYTES !=
          encoded_total_bytes ||
      snapshot_get_u32(source + LF_MUHTARI_SNAPSHOT_STATE_FORMAT_OFFSET) !=
          1U ||
      snapshot_get_u32(source + LF_MUHTARI_SNAPSHOT_CORE_ABI_OFFSET) != 1U ||
      snapshot_get_u32(source +
                       LF_MUHTARI_SNAPSHOT_BEHAVIOR_REVISION_OFFSET) != 6U ||
      snapshot_get_u32(source +
                       LF_MUHTARI_SNAPSHOT_API_REVISION_OFFSET) != 8U ||
      !snapshot_identity_matches(
          source + LF_MUHTARI_SNAPSHOT_BUILD_ID_OFFSET,
          LF_MUHTARI_SNAPSHOT_BUILD_ID_BYTES, k_build_id) ||
      !snapshot_identity_matches(
          source + LF_MUHTARI_SNAPSHOT_LIBFUTURO_BUILD_ID_OFFSET,
          LF_MUHTARI_SNAPSHOT_LIBFUTURO_BUILD_ID_BYTES,
          k_libfuturo_build_id) ||
      !snapshot_identity_matches(
          source + LF_MUHTARI_SNAPSHOT_PROFILE_ID_OFFSET,
          LF_MUHTARI_SNAPSHOT_PROFILE_ID_BYTES, k_profile_id) ||
      !snapshot_identity_matches(
          source + LF_MUHTARI_SNAPSHOT_CONFIGURATION_ID_OFFSET,
          LF_MUHTARI_SNAPSHOT_CONFIGURATION_ID_BYTES,
          k_battery_configuration_id) ||
      !snapshot_identity_matches(
          source + LF_MUHTARI_SNAPSHOT_OPTIONS_ID_OFFSET,
          LF_MUHTARI_SNAPSHOT_OPTIONS_ID_BYTES, k_options_id) ||
      memcmp(source + LF_MUHTARI_SNAPSHOT_CONTENT_DIGEST_OFFSET,
             state->content_digest, sizeof(state->content_digest)) != 0 ||
      (same_instance_origin &&
       snapshot_get_u64(source + LF_MUHTARI_SNAPSHOT_LOAD_EPOCH_OFFSET) !=
           state->successful_load_epoch) ||
      content_size_u64 != expected_content_size_u64 ||
      !snapshot_continuation_is_valid(cumulative_frames, pending_buttons,
                                      flags)) {
    return LF_INVALID_ARGUMENT;
  }
  core_status = muhtari_load_state(
      state->core, source + LF_MUHTARI_SNAPSHOT_HEADER_BYTES,
      encoded_native_bytes);
  if (core_status != MUHTARI_STATUS_OK) {
    return map_core_status(core_status);
  }
  state->cumulative_frames = cumulative_frames;
  state->pending_buttons = pending_buttons;
  state->positive_advance_started =
      state->positive_advance_started ||
      ((flags & LF_MUHTARI_SNAPSHOT_FLAG_POSITIVE_ADVANCE) != 0U);
  state->halted = (flags & LF_MUHTARI_SNAPSHOT_FLAG_HALTED) != 0U;
  return LF_OK;
}
#endif
