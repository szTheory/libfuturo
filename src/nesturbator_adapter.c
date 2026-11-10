#define _POSIX_C_SOURCE 200809L

#include "libfuturo_internal.h"
#include "sha256.h"

#include <nesturbator.h>

#include <stdatomic.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#ifndef LF_NESTURBATOR_SOURCE_REVISION
#define LF_NESTURBATOR_SOURCE_REVISION "unverified"
#endif
#ifndef LF_BUILD_ID
#define LF_BUILD_ID "unversioned"
#endif

#define LF_NESTURBATOR_INPUT_MASK UINT32_C(0x0000FFFF)
#define LF_NESTURBATOR_VIDEO_WIDTH 256U
#define LF_NESTURBATOR_VIDEO_HEIGHT 240U
#define LF_NESTURBATOR_VIDEO_BYTES_PER_PIXEL 3U
#define LF_NESTURBATOR_AUDIO_RATE 48000U
#define LF_NESTURBATOR_MAX_AUDIO_SAMPLES 799U
#define LF_NESTURBATOR_MAX_CONTENT_BYTES (64U * 1024U * 1024U)
#define LF_NESTURBATOR_MAX_SNAPSHOT_BYTES (128U * 1024U * 1024U)
#define LF_NESTURBATOR_NATIVE_PALETTE_ENTRIES 512U
#define LF_QUALIFIED_BATTERY_FIXTURE_HEADER_BYTES 16U
#define LF_QUALIFIED_BATTERY_FIXTURE_PRG_BYTES (32U * 1024U)
#define LF_QUALIFIED_BATTERY_FIXTURE_CHR_BYTES (8U * 1024U)
#define LF_QUALIFIED_BATTERY_FIXTURE_TOTAL_BYTES \
  (LF_QUALIFIED_BATTERY_FIXTURE_HEADER_BYTES + \
   LF_QUALIFIED_BATTERY_FIXTURE_PRG_BYTES + \
   LF_QUALIFIED_BATTERY_FIXTURE_CHR_BYTES)

#define LF_NESTURBATOR_SNAPSHOT_HEADER_BYTES 388U
#define LF_NESTURBATOR_SNAPSHOT_BUILD_ID_BYTES 64U
#define LF_NESTURBATOR_SNAPSHOT_LIBFUTURO_BUILD_ID_BYTES 80U
#define LF_NESTURBATOR_SNAPSHOT_PROFILE_ID_BYTES 32U
#define LF_NESTURBATOR_SNAPSHOT_CONFIGURATION_ID_BYTES 32U
#define LF_NESTURBATOR_SNAPSHOT_OPTIONS_ID_BYTES 32U
#define LF_NESTURBATOR_SNAPSHOT_CONTENT_DIGEST_BYTES 32U
#define LF_NESTURBATOR_SNAPSHOT_INSTANCE_ID_BYTES 32U

enum {
  LF_SNAPSHOT_MAGIC_OFFSET = 0U,
  LF_SNAPSHOT_VERSION_OFFSET = 8U,
  LF_SNAPSHOT_HEADER_SIZE_OFFSET = 12U,
  LF_SNAPSHOT_TOTAL_SIZE_OFFSET = 16U,
  LF_SNAPSHOT_NATIVE_SIZE_OFFSET = 24U,
  LF_SNAPSHOT_STATE_FORMAT_OFFSET = 32U,
  LF_SNAPSHOT_CORE_ABI_OFFSET = 36U,
  LF_SNAPSHOT_BEHAVIOR_REVISION_OFFSET = 40U,
  LF_SNAPSHOT_BUILD_ID_OFFSET = 44U,
  LF_SNAPSHOT_LIBFUTURO_BUILD_ID_OFFSET = 108U,
  LF_SNAPSHOT_PROFILE_ID_OFFSET = 188U,
  LF_SNAPSHOT_CONFIGURATION_ID_OFFSET = 220U,
  LF_SNAPSHOT_OPTIONS_ID_OFFSET = 252U,
  LF_SNAPSHOT_CONTENT_DIGEST_OFFSET = 284U,
  LF_SNAPSHOT_INSTANCE_ID_OFFSET = 316U,
  LF_SNAPSHOT_LOAD_EPOCH_OFFSET = 348U,
  LF_SNAPSHOT_CONTENT_SIZE_OFFSET = 356U,
  LF_SNAPSHOT_CUMULATIVE_FRAMES_OFFSET = 364U,
  LF_SNAPSHOT_CUMULATIVE_TICKS_OFFSET = 372U,
  LF_SNAPSHOT_PENDING_BUTTONS_OFFSET = 380U,
  LF_SNAPSHOT_FLAGS_OFFSET = 384U,
  LF_SNAPSHOT_FLAG_POSITIVE_ADVANCE = 1U,
  LF_SNAPSHOT_FLAG_HALTED = 2U,
  LF_SNAPSHOT_FLAG_TICKS_VALID = 4U,
  LF_SNAPSHOT_KNOWN_FLAGS = 7U,
};

static const uint8_t k_snapshot_magic[8] = {'L', 'F', 'S', 'N', 'A', 'P', '2', 0};
static _Atomic uint64_t g_next_instance_sequence = 1U;

static const char k_profile_id[] = "nesturbator-ntsc-v1";
static const char k_media_identity[] = "nesturbator-save-ram-v1";
static const char k_core_id[] = "nesturbator";
static const char k_configuration_id[] = "nesturbator-default";
static const char k_options_id[] = "nesturbator-options-none-v1";
static const char k_build_id[] = "nesturbator-" LF_NESTURBATOR_SOURCE_REVISION;
static const char k_libfuturo_build_id[] = LF_BUILD_ID;
static const char k_qualified_battery_snapshot_build_id[] =
    "nesturbator-2338608ab184f040620a30d17756f5e06a42d4e3";

static void snapshot_put_u64(uint8_t output[8], uint64_t value);

static void initialize_instance_identity(uint8_t identity[
    LF_NESTURBATOR_SNAPSHOT_INSTANCE_ID_BYTES]) {
  struct timespec now = {0, 0};
  const uint64_t process_id = (uint64_t)(unsigned long)getpid();
  const uint64_t sequence = atomic_fetch_add_explicit(
      &g_next_instance_sequence, 1U, memory_order_relaxed);
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
}

/* Snapshot support for battery-backed content is qualified only for this
   complete project-generated MMC1 image. Match every byte rather than only
   trusting a mapper header or save-RAM extent, both of which other boards can
   share. */
static const uint8_t k_qualified_battery_fixture_header[
    LF_QUALIFIED_BATTERY_FIXTURE_HEADER_BYTES] = {
        'N', 'E', 'S', 0x1AU, 2U, 1U, 0x12U, 0U,
        0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U};
static const uint8_t k_qualified_battery_fixture_program[] = {
    0x78U, 0xD8U, 0xA9U, 0x00U, 0x8DU, 0x00U, 0x20U, 0x8DU, 0x01U,
    0x20U, 0xADU, 0x02U, 0x20U, 0x10U, 0xFBU, 0xADU, 0x00U, 0x60U,
    0x18U, 0x69U, 0x01U, 0x8DU, 0x00U, 0x60U, 0x4CU, 0x0AU, 0x80U};

struct lf_nesturbator_state {
  lf_allocate_fn allocate;
  lf_deallocate_fn deallocate;
  void *allocator_context;
  nesturbator *core;
  uint16_t *native_video;
  int16_t *native_audio;
  uint32_t palette[LF_NESTURBATOR_NATIVE_PALETTE_ENTRIES];
  uint64_t cumulative_frames;
  uint64_t cumulative_ticks;
  uint64_t media_generation_base;
  uint64_t successful_load_epoch;
  uint8_t instance_identity[LF_NESTURBATOR_SNAPSHOT_INSTANCE_ID_BYTES];
  int qualified_battery_snapshot_route;
#if defined(LF_NESTURBATOR_TESTING)
  uint64_t snapshot_restore_attempts;
#endif
  uint32_t pending_buttons;
  size_t content_size_bytes;
  uint8_t content_digest[LF_NESTURBATOR_SNAPSHOT_CONTENT_DIGEST_BYTES];
  int loaded;
  int positive_advance_started;
  int halted;
  int ticks_valid;
};

static int checked_video_extent(size_t stride, size_t width, size_t height,
                                size_t *extent) {
  const size_t rows_before_last = height - 1U;
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

static void fill_profile(lf_profile *out) {
  *out = (lf_profile){
      .struct_size = sizeof(*out),
      .profile_id = k_profile_id,
      .core_id = k_core_id,
      .build_id = k_build_id,
      .api_revision = NESTURBATOR_ABI_VERSION,
      .behavior_revision = NESTURBATOR_BEHAVIOUR_REVISION,
      .input_mask = LF_NESTURBATOR_INPUT_MASK,
      .max_work_units = 1U,
      .max_guest_units = UINT32_MAX,
      .atomic_quantum_units = 1U,
      .max_overshoot_units = 0U,
      .time_unit = LF_TIME_FRAME,
      .input_sampling = LF_INPUT_AT_ADVANCE_START,
      .video_format = LF_VIDEO_RGB24,
      .audio_encoding = LF_AUDIO_S16_NATIVE,
      .audio_layout = LF_AUDIO_INTERLEAVED,
      .video_width = LF_NESTURBATOR_VIDEO_WIDTH,
      .video_height = LF_NESTURBATOR_VIDEO_HEIGHT,
      .video_bytes_per_pixel = LF_NESTURBATOR_VIDEO_BYTES_PER_PIXEL,
      .audio_rate_numerator = LF_NESTURBATOR_AUDIO_RATE,
      .audio_rate_denominator = 1U,
      .audio_channels = 1U,
      .min_video_stride_bytes =
          LF_NESTURBATOR_VIDEO_WIDTH * LF_NESTURBATOR_VIDEO_BYTES_PER_PIXEL,
      .max_audio_samples_per_call = LF_NESTURBATOR_MAX_AUDIO_SAMPLES,
      .media_extent_bytes = 0U,
      .max_content_bytes = LF_NESTURBATOR_MAX_CONTENT_BYTES,
      .effective_configuration_id = k_configuration_id,
      .frame_rate_numerator = 0U,
      .frame_rate_denominator = 0U,
  };
}

static void fill_run_metadata(lf_run_result *out) {
  out->time_unit = LF_TIME_FRAME;
  out->core_tick_time_unit = LF_TIME_NES_HALF_MASTER_TICK;
  out->video_format = LF_VIDEO_RGB24;
  out->audio_encoding = LF_AUDIO_S16_NATIVE;
  out->audio_layout = LF_AUDIO_INTERLEAVED;
  out->video_width = LF_NESTURBATOR_VIDEO_WIDTH;
  out->video_height = LF_NESTURBATOR_VIDEO_HEIGHT;
  out->audio_rate_numerator = LF_NESTURBATOR_AUDIO_RATE;
  out->audio_rate_denominator = 1U;
  out->audio_channels = 1U;
}

static void fill_load_result(const lf_nesturbator_state *state,
                             lf_load_result *out) {
  out->loaded = state != NULL && state->loaded ? 1U : 0U;
  out->content_size_bytes = out->loaded != 0U ? state->content_size_bytes : 0U;
  out->effective_configuration_id =
      out->loaded != 0U ? k_configuration_id : NULL;
}

static void *core_allocate(void *user, size_t bytes) {
  lf_nesturbator_state *state = user;
  return state->allocate(state->allocator_context, bytes);
}

static void core_deallocate(void *user, void *allocation, size_t bytes) {
  lf_nesturbator_state *state = user;
  (void)bytes;
  state->deallocate(state->allocator_context, allocation);
}

static lf_status map_core_status(nesturbator_status status) {
  switch (status) {
    case NESTURBATOR_OK:
      return LF_OK;
    case NESTURBATOR_ERR_NO_MEMORY:
      return LF_RESOURCE_EXHAUSTED;
    case NESTURBATOR_ERR_BUFFER_TOO_SMALL:
      return LF_BUFFER_TOO_SMALL;
    case NESTURBATOR_ERR_ARGUMENT:
    case NESTURBATOR_ERR_STRUCT_SIZE:
    case NESTURBATOR_ERR_ABI:
    case NESTURBATOR_STOP_JAM:
    case NESTURBATOR_ERR_CARTRIDGE:
    case NESTURBATOR_ERR_STATE_FORMAT:
    case NESTURBATOR_ERR_STATE_CARTRIDGE:
    case NESTURBATOR_ERR_STATE_SIZE:
    case NESTURBATOR_ERR_STATE_CHECKSUM:
    case NESTURBATOR_ERR_STATE_INVALID:
      return LF_INVALID_ARGUMENT;
  }
  return LF_INVALID_ARGUMENT;
}

static int is_qualified_battery_snapshot_content(const uint8_t *content,
                                                  size_t content_bytes) {
  const size_t prg_offset =
      (size_t)LF_QUALIFIED_BATTERY_FIXTURE_HEADER_BYTES;
  const size_t vectors_offset =
      prg_offset + (size_t)LF_QUALIFIED_BATTERY_FIXTURE_PRG_BYTES - 6U;
  const size_t chr_offset =
      prg_offset + (size_t)LF_QUALIFIED_BATTERY_FIXTURE_PRG_BYTES;
  size_t offset = 0U;
  if (content == NULL ||
      strcmp(k_build_id, k_qualified_battery_snapshot_build_id) != 0 ||
      content_bytes != (size_t)LF_QUALIFIED_BATTERY_FIXTURE_TOTAL_BYTES ||
      memcmp(content, k_qualified_battery_fixture_header,
             sizeof(k_qualified_battery_fixture_header)) != 0) {
    return 0;
  }
  for (offset = prg_offset;
       offset < prg_offset + (size_t)LF_QUALIFIED_BATTERY_FIXTURE_PRG_BYTES;
       ++offset) {
    uint8_t expected = 0xEAU;
    const size_t prg_byte = offset - prg_offset;
    if (prg_byte < sizeof(k_qualified_battery_fixture_program)) {
      expected = k_qualified_battery_fixture_program[prg_byte];
    } else if (offset >= vectors_offset) {
      const size_t vector_byte = (offset - vectors_offset) % 2U;
      expected = vector_byte == 0U ? 0x00U : 0x80U;
    }
    if (content[offset] != expected) {
      return 0;
    }
  }
  for (offset = chr_offset;
       offset < (size_t)LF_QUALIFIED_BATTERY_FIXTURE_TOTAL_BYTES; ++offset) {
    if (content[offset] != 0U) {
      return 0;
    }
  }
  return 1;
}

lf_status lf_nesturbator_query_profile(lf_profile *out) {
  if (out == NULL || out->struct_size != sizeof(*out)) {
    return LF_INVALID_ARGUMENT;
  }
  fill_profile(out);
  return LF_OK;
}

void lf_nesturbator_destroy(lf_nesturbator_state **owned) {
  lf_nesturbator_state *state = NULL;
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
    nesturbator_destroy(state->core);
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

lf_status lf_nesturbator_create(lf_allocate_fn allocate,
                                lf_deallocate_fn deallocate,
                                void *allocator_context,
                                lf_nesturbator_state **out) {
  lf_nesturbator_state *state = NULL;
  nesturbator_status core_status = NESTURBATOR_OK;
  if (out == NULL) {
    return LF_INVALID_ARGUMENT;
  }
  *out = NULL;
  if (allocate == NULL || deallocate == NULL) {
    return LF_INVALID_ARGUMENT;
  }

  state = allocate(allocator_context, sizeof(*state));
  if (state == NULL) {
    return LF_RESOURCE_EXHAUSTED;
  }
  memset(state, 0, sizeof(*state));
  initialize_instance_identity(state->instance_identity);
  state->allocate = allocate;
  state->deallocate = deallocate;
  state->allocator_context = allocator_context;
  state->native_video = allocate(
      allocator_context,
      (size_t)LF_NESTURBATOR_VIDEO_WIDTH * LF_NESTURBATOR_VIDEO_HEIGHT *
          sizeof(state->native_video[0]));
  if (state->native_video == NULL) {
    lf_nesturbator_destroy(&state);
    return LF_RESOURCE_EXHAUSTED;
  }
  state->native_audio = allocate(
      allocator_context,
      (size_t)LF_NESTURBATOR_MAX_AUDIO_SAMPLES *
          sizeof(state->native_audio[0]));
  if (state->native_audio == NULL) {
    lf_nesturbator_destroy(&state);
    return LF_RESOURCE_EXHAUSTED;
  }

  {
    nesturbator_config config;
    const nesturbator_allocator allocator = {
        .alloc = core_allocate,
        .free = core_deallocate,
        .user = state,
    };
    memset(&config, 0, sizeof(config));
    config.size = (uint32_t)sizeof(config);
    config.abi = NESTURBATOR_ABI_VERSION;
    config.allocator = allocator;
    core_status = nesturbator_create(&config, &state->core);
  }
  if (core_status != NESTURBATOR_OK) {
    const lf_status mapped = map_core_status(core_status);
    lf_nesturbator_destroy(&state);
    return mapped;
  }

  nesturbator_get_palette(state->core, state->palette,
                          LF_NESTURBATOR_NATIVE_PALETTE_ENTRIES);
  *out = state;
  return LF_OK;
}

lf_status lf_nesturbator_load(lf_nesturbator_state *state,
                              const lf_load_request *request,
                              lf_load_result *out) {
  nesturbator_status core_status = NESTURBATOR_OK;
  int qualified_battery_snapshot_route = 0;
  uint8_t candidate_content_digest[
      LF_NESTURBATOR_SNAPSHOT_CONTENT_DIGEST_BYTES];
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
  if (request->configuration_id != NULL &&
      strcmp(request->configuration_id, k_configuration_id) != 0) {
    return LF_UNSUPPORTED;
  }
  if (request->content_size_bytes > LF_NESTURBATOR_MAX_CONTENT_BYTES) {
    return LF_LIMIT_EXCEEDED;
  }
  if (state->successful_load_epoch == UINT64_MAX) {
    return LF_LIMIT_EXCEEDED;
  }
  if (!lf_sha256_bytes(request->content_data, request->content_size_bytes,
                       candidate_content_digest)) {
    return LF_LIMIT_EXCEEDED;
  }

  qualified_battery_snapshot_route = is_qualified_battery_snapshot_content(
      request->content_data, request->content_size_bytes);

  core_status = nesturbator_load_cartridge(state->core, request->content_data,
                                            request->content_size_bytes);
  if (core_status != NESTURBATOR_OK) {
    return map_core_status(core_status);
  }
  state->successful_load_epoch += 1U;
  state->qualified_battery_snapshot_route =
      qualified_battery_snapshot_route;
  state->loaded = 1;
  state->positive_advance_started = 0;
  state->halted = 0;
  state->content_size_bytes = request->content_size_bytes;
  state->cumulative_frames = 0U;
  state->cumulative_ticks = 0U;
  state->media_generation_base = nesturbator_save_generation(state->core);
  state->ticks_valid = 0;
  state->pending_buttons = 0U;
  memcpy(state->content_digest, candidate_content_digest,
         sizeof(state->content_digest));
  fill_load_result(state, out);
  return LF_OK;
}

lf_status lf_nesturbator_set_input(lf_nesturbator_state *state,
                                   const lf_input *input) {
  if (state == NULL || input == NULL ||
      input->struct_size != sizeof(*input) ||
      (input->buttons & ~LF_NESTURBATOR_INPUT_MASK) != 0U) {
    return LF_INVALID_ARGUMENT;
  }
  state->pending_buttons = input->buttons;
  return LF_OK;
}

lf_status lf_nesturbator_advance(lf_nesturbator_state *state,
                                 const lf_run_request *request,
                                 lf_run_result *out) {
  const size_t video_width_bytes =
      (size_t)LF_NESTURBATOR_VIDEO_WIDTH *
      (size_t)LF_NESTURBATOR_VIDEO_BYTES_PER_PIXEL;
  size_t video_extent = 0U;
  nesturbator_input core_input;
  nesturbator_frame frame;
  nesturbator_status core_status = NESTURBATOR_OK;
  size_t y = 0U;
  size_t x = 0U;

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
    out->cumulative_core_ticks = state->cumulative_ticks;
    out->core_ticks_valid = (uint32_t)state->ticks_valid;
  }
  if (state == NULL || request == NULL ||
      request->struct_size != sizeof(*request)) {
    return LF_INVALID_ARGUMENT;
  }
  out->requested_units = request->work_units;
  out->video_stride_bytes = request->video_stride_bytes;
  if (!state->loaded) {
    return LF_INVALID_ARGUMENT;
  }
  if (request->work_units == 0U) {
    out->stop_reason = state->halted ? LF_STOP_CORE_HALTED
                                     : LF_STOP_BUDGET_REACHED;
    if (state->halted) {
      out->core_ticks_valid = 0U;
    }
    return LF_OK;
  }
  if (state->halted) {
    out->stop_reason = LF_STOP_CORE_HALTED;
    out->core_ticks_valid = 0U;
    return LF_OK;
  }
  if (request->work_units > 1U ||
      state->cumulative_frames >= (uint64_t)UINT32_MAX) {
    return LF_LIMIT_EXCEEDED;
  }
  if (request->video_data == NULL || request->audio_data == NULL ||
      request->video_stride_bytes < video_width_bytes) {
    return LF_INVALID_ARGUMENT;
  }
  if (!checked_video_extent(request->video_stride_bytes, video_width_bytes,
                            LF_NESTURBATOR_VIDEO_HEIGHT, &video_extent)) {
    return LF_LIMIT_EXCEEDED;
  }
  if (request->video_capacity_bytes < video_extent ||
      request->audio_capacity_samples < LF_NESTURBATOR_MAX_AUDIO_SAMPLES) {
    return LF_BUFFER_TOO_SMALL;
  }

  memset(&core_input, 0, sizeof(core_input));
  core_input.size = (uint32_t)sizeof(core_input);
  core_input.buttons[0] = (uint8_t)(state->pending_buttons & UINT32_C(0xFF));
  core_input.buttons[1] = (uint8_t)((state->pending_buttons >> 8U) &
                                    UINT32_C(0xFF));
  core_status = nesturbator_set_input(state->core, &core_input);
  if (core_status != NESTURBATOR_OK) {
    return map_core_status(core_status);
  }

  memset(&frame, 0, sizeof(frame));
  frame.size = (uint32_t)sizeof(frame);
  frame.video = state->native_video;
  frame.video_pitch = LF_NESTURBATOR_VIDEO_WIDTH;
  frame.audio = state->native_audio;
  frame.audio_capacity = LF_NESTURBATOR_MAX_AUDIO_SAMPLES;
  state->positive_advance_started = 1;
  core_status = nesturbator_run_frame(state->core, &frame);
  if (core_status == NESTURBATOR_STOP_JAM) {
    state->halted = 1;
    out->stop_reason = LF_STOP_CORE_HALTED;
    out->core_ticks_valid = 0U;
    return LF_OK;
  }
  if (core_status != NESTURBATOR_OK) {
    return map_core_status(core_status);
  }
  if (frame.audio_count < 798U ||
      frame.audio_count > LF_NESTURBATOR_MAX_AUDIO_SAMPLES ||
      frame.ticks <= state->cumulative_ticks ||
      state->cumulative_frames == UINT64_MAX) {
    return LF_INVALID_ARGUMENT;
  }

  for (y = 0U; y < LF_NESTURBATOR_VIDEO_HEIGHT; ++y) {
    for (x = 0U; x < LF_NESTURBATOR_VIDEO_WIDTH; ++x) {
      const uint16_t native_pixel =
          state->native_video[y * LF_NESTURBATOR_VIDEO_WIDTH + x];
      if (native_pixel >= LF_NESTURBATOR_NATIVE_PALETTE_ENTRIES) {
        return LF_INVALID_ARGUMENT;
      }
    }
  }

  for (y = 0U; y < LF_NESTURBATOR_VIDEO_HEIGHT; ++y) {
    const size_t row_offset = y * request->video_stride_bytes;
    for (x = 0U; x < LF_NESTURBATOR_VIDEO_WIDTH; ++x) {
      const size_t pixel_offset = row_offset +
                                  x * LF_NESTURBATOR_VIDEO_BYTES_PER_PIXEL;
      const uint32_t rgb = state->palette[
          state->native_video[y * LF_NESTURBATOR_VIDEO_WIDTH + x]];
      request->video_data[pixel_offset] = (uint8_t)((rgb >> 16U) & 0xFFU);
      request->video_data[pixel_offset + 1U] = (uint8_t)((rgb >> 8U) & 0xFFU);
      request->video_data[pixel_offset + 2U] = (uint8_t)(rgb & 0xFFU);
    }
  }
  memcpy(request->audio_data, state->native_audio,
         (size_t)frame.audio_count * sizeof(request->audio_data[0]));

  state->cumulative_frames += 1U;
  state->cumulative_ticks = frame.ticks;
  state->ticks_valid = 1;
  out->actual_units = 1U;
  out->overshoot_units = 0U;
  out->sampled_buttons = state->pending_buttons;
  out->video_valid = 1U;
  out->audio_valid = 1U;
  out->cumulative_units = state->cumulative_frames;
  out->core_ticks_valid = 1U;
  out->cumulative_core_ticks = frame.ticks;
  out->stop_reason = LF_STOP_BUDGET_REACHED;
  out->video_extent_bytes = video_extent;
  out->audio_produced_samples = frame.audio_count;
  return LF_OK;
}

static lf_status get_save_span(lf_nesturbator_state *state, uint8_t **data,
                               size_t *size) {
  nesturbator_status core_status = NESTURBATOR_OK;
  *data = NULL;
  *size = 0U;
  core_status = nesturbator_get_memory(state->core,
                                       NESTURBATOR_MEMORY_SAVE_RAM, data,
                                       size);
  if (core_status != NESTURBATOR_OK) {
    return map_core_status(core_status);
  }
  if (*data == NULL && *size == 0U) {
    return LF_UNSUPPORTED;
  }
  if (*data == NULL || *size == 0U) {
    return LF_INVALID_ARGUMENT;
  }
  if (*size > LF_NESTURBATOR_MAX_CONTENT_BYTES) {
    return LF_LIMIT_EXCEEDED;
  }
  return LF_OK;
}

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

static uint32_t snapshot_continuation_flags(
    const lf_nesturbator_state *state) {
  uint32_t flags = 0U;
  if (state->positive_advance_started) {
    flags |= LF_SNAPSHOT_FLAG_POSITIVE_ADVANCE;
  }
  if (state->halted) {
    flags |= LF_SNAPSHOT_FLAG_HALTED;
  }
  if (state->ticks_valid) {
    flags |= LF_SNAPSHOT_FLAG_TICKS_VALID;
  }
  return flags;
}

static int snapshot_build_header(const lf_nesturbator_state *state,
                                 size_t native_bytes, size_t total_bytes,
                                 uint8_t header[LF_NESTURBATOR_SNAPSHOT_HEADER_BYTES]) {
  uint64_t total_bytes_u64 = 0U;
  uint64_t native_bytes_u64 = 0U;
  uint64_t content_size_u64 = 0U;
  if (state == NULL || header == NULL ||
      !snapshot_size_to_u64(total_bytes, &total_bytes_u64) ||
      !snapshot_size_to_u64(native_bytes, &native_bytes_u64) ||
      !snapshot_size_to_u64(state->content_size_bytes, &content_size_u64)) {
    return 0;
  }
  memset(header, 0, LF_NESTURBATOR_SNAPSHOT_HEADER_BYTES);
  memcpy(header + LF_SNAPSHOT_MAGIC_OFFSET, k_snapshot_magic,
         sizeof(k_snapshot_magic));
  snapshot_put_u32(header + LF_SNAPSHOT_VERSION_OFFSET, 2U);
  snapshot_put_u32(header + LF_SNAPSHOT_HEADER_SIZE_OFFSET,
                   LF_NESTURBATOR_SNAPSHOT_HEADER_BYTES);
  snapshot_put_u64(header + LF_SNAPSHOT_TOTAL_SIZE_OFFSET, total_bytes_u64);
  snapshot_put_u64(header + LF_SNAPSHOT_NATIVE_SIZE_OFFSET, native_bytes_u64);
  snapshot_put_u32(header + LF_SNAPSHOT_STATE_FORMAT_OFFSET,
                   NESTURBATOR_STATE_FORMAT_VERSION);
  snapshot_put_u32(header + LF_SNAPSHOT_CORE_ABI_OFFSET,
                   NESTURBATOR_ABI_VERSION);
  snapshot_put_u32(header + LF_SNAPSHOT_BEHAVIOR_REVISION_OFFSET,
                   NESTURBATOR_BEHAVIOUR_REVISION);
  if (!snapshot_write_identity(
          header + LF_SNAPSHOT_BUILD_ID_OFFSET,
          LF_NESTURBATOR_SNAPSHOT_BUILD_ID_BYTES, k_build_id) ||
      !snapshot_write_identity(
          header + LF_SNAPSHOT_LIBFUTURO_BUILD_ID_OFFSET,
          LF_NESTURBATOR_SNAPSHOT_LIBFUTURO_BUILD_ID_BYTES,
          k_libfuturo_build_id) ||
      !snapshot_write_identity(
          header + LF_SNAPSHOT_PROFILE_ID_OFFSET,
          LF_NESTURBATOR_SNAPSHOT_PROFILE_ID_BYTES, k_profile_id) ||
      !snapshot_write_identity(
          header + LF_SNAPSHOT_CONFIGURATION_ID_OFFSET,
          LF_NESTURBATOR_SNAPSHOT_CONFIGURATION_ID_BYTES,
          k_configuration_id) ||
      !snapshot_write_identity(
          header + LF_SNAPSHOT_OPTIONS_ID_OFFSET,
          LF_NESTURBATOR_SNAPSHOT_OPTIONS_ID_BYTES, k_options_id)) {
    return 0;
  }
  memcpy(header + LF_SNAPSHOT_CONTENT_DIGEST_OFFSET, state->content_digest,
         sizeof(state->content_digest));
  memcpy(header + LF_SNAPSHOT_INSTANCE_ID_OFFSET, state->instance_identity,
         sizeof(state->instance_identity));
  snapshot_put_u64(header + LF_SNAPSHOT_LOAD_EPOCH_OFFSET,
                   state->successful_load_epoch);
  snapshot_put_u64(header + LF_SNAPSHOT_CONTENT_SIZE_OFFSET,
                   content_size_u64);
  snapshot_put_u64(header + LF_SNAPSHOT_CUMULATIVE_FRAMES_OFFSET,
                   state->cumulative_frames);
  snapshot_put_u64(header + LF_SNAPSHOT_CUMULATIVE_TICKS_OFFSET,
                   state->cumulative_ticks);
  snapshot_put_u32(header + LF_SNAPSHOT_PENDING_BUTTONS_OFFSET,
                   state->pending_buttons);
  snapshot_put_u32(header + LF_SNAPSHOT_FLAGS_OFFSET,
                   snapshot_continuation_flags(state));
  return 1;
}

static lf_status get_snapshot_native_size(lf_nesturbator_state *state,
                                          size_t *native_bytes,
                                          size_t *total_bytes) {
  uint8_t *save_data = NULL;
  size_t save_bytes = 0U;
  size_t state_bytes = 0U;
  lf_status status = LF_OK;
  if (state == NULL || native_bytes == NULL || total_bytes == NULL) {
    return LF_INVALID_ARGUMENT;
  }
  if (!state->loaded) {
    return LF_INVALID_ARGUMENT;
  }
  status = get_save_span(state, &save_data, &save_bytes);
  if (status == LF_OK) {
    if (save_data == NULL || save_bytes == 0U) {
      return LF_INVALID_ARGUMENT;
    }
    if (!state->qualified_battery_snapshot_route) {
      return LF_UNSUPPORTED;
    }
  } else if (status != LF_UNSUPPORTED) {
    return status;
  }
  state_bytes = nesturbator_state_size(state->core);
  if (state_bytes == 0U) {
    return LF_INVALID_ARGUMENT;
  }
  if (state_bytes >
          (size_t)LF_NESTURBATOR_MAX_SNAPSHOT_BYTES -
              (size_t)LF_NESTURBATOR_SNAPSHOT_HEADER_BYTES) {
    return LF_LIMIT_EXCEEDED;
  }
  *native_bytes = state_bytes;
  *total_bytes = (size_t)LF_NESTURBATOR_SNAPSHOT_HEADER_BYTES + state_bytes;
  return LF_OK;
}

static int snapshot_continuation_is_valid(uint64_t cumulative_frames,
                                          uint64_t cumulative_ticks,
                                          uint32_t pending_buttons,
                                          uint32_t flags) {
  const int positive_advance_started =
      (flags & LF_SNAPSHOT_FLAG_POSITIVE_ADVANCE) != 0U;
  const int halted = (flags & LF_SNAPSHOT_FLAG_HALTED) != 0U;
  const int ticks_valid = (flags & LF_SNAPSHOT_FLAG_TICKS_VALID) != 0U;
  if ((flags & ~(uint32_t)LF_SNAPSHOT_KNOWN_FLAGS) != 0U ||
      (pending_buttons & ~LF_NESTURBATOR_INPUT_MASK) != 0U ||
      cumulative_frames > (uint64_t)UINT32_MAX ||
      (cumulative_frames > 0U && !ticks_valid) ||
      (ticks_valid && cumulative_ticks == 0U) ||
      (!ticks_valid && cumulative_ticks != 0U) ||
      ((halted || ticks_valid) && !positive_advance_started)) {
    return 0;
  }
  return 1;
}

lf_status lf_nesturbator_get_snapshot_size(lf_nesturbator_state *state,
                                            size_t *required_bytes) {
  size_t native_bytes = 0U;
  size_t total_bytes = 0U;
  const lf_status status =
      get_snapshot_native_size(state, &native_bytes, &total_bytes);
  (void)native_bytes;
  if (status != LF_OK) {
    return status;
  }
  if (required_bytes == NULL) {
    return LF_INVALID_ARGUMENT;
  }
  *required_bytes = total_bytes;
  return LF_OK;
}

lf_status lf_nesturbator_capture_snapshot(lf_nesturbator_state *state,
                                           uint8_t *destination,
                                           size_t capacity_bytes) {
  uint8_t header[LF_NESTURBATOR_SNAPSHOT_HEADER_BYTES];
  size_t native_bytes = 0U;
  size_t total_bytes = 0U;
  nesturbator_status core_status = NESTURBATOR_OK;
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
  core_status = nesturbator_save_state(
      state->core, destination + LF_NESTURBATOR_SNAPSHOT_HEADER_BYTES,
      native_bytes);
  if (core_status != NESTURBATOR_OK) {
    return map_core_status(core_status);
  }
  memcpy(destination, header, sizeof(header));
  return LF_OK;
}

lf_status lf_nesturbator_restore_snapshot(lf_nesturbator_state *state,
                                           const uint8_t *source,
                                           size_t extent_bytes) {
  uint64_t total_bytes_u64 = 0U;
  uint64_t native_bytes_u64 = 0U;
  uint64_t content_size_u64 = 0U;
  uint64_t cumulative_frames = 0U;
  uint64_t cumulative_ticks = 0U;
  uint64_t expected_content_size_u64 = 0U;
  uint32_t pending_buttons = 0U;
  uint32_t flags = 0U;
  size_t encoded_total_bytes = 0U;
  size_t encoded_native_bytes = 0U;
  size_t expected_native_bytes = 0U;
  size_t expected_total_bytes = 0U;
  nesturbator_status core_status = NESTURBATOR_OK;
  lf_status status = LF_OK;
  int same_instance_origin = 0;
  if (state == NULL || source == NULL || extent_bytes == 0U) {
    return LF_INVALID_ARGUMENT;
  }
  if (extent_bytes > (size_t)LF_NESTURBATOR_MAX_SNAPSHOT_BYTES) {
    return LF_LIMIT_EXCEEDED;
  }
  if (extent_bytes < (size_t)LF_NESTURBATOR_SNAPSHOT_HEADER_BYTES) {
    return LF_INVALID_ARGUMENT;
  }
  status = get_snapshot_native_size(state, &expected_native_bytes,
                                    &expected_total_bytes);
  if (status != LF_OK) {
    return status;
  }
  if (memcmp(source + LF_SNAPSHOT_MAGIC_OFFSET, k_snapshot_magic,
             sizeof(k_snapshot_magic)) != 0 ||
      snapshot_get_u32(source + LF_SNAPSHOT_VERSION_OFFSET) != 2U ||
      snapshot_get_u32(source + LF_SNAPSHOT_HEADER_SIZE_OFFSET) !=
          (uint32_t)LF_NESTURBATOR_SNAPSHOT_HEADER_BYTES) {
    return LF_INVALID_ARGUMENT;
  }
  total_bytes_u64 = snapshot_get_u64(source + LF_SNAPSHOT_TOTAL_SIZE_OFFSET);
  native_bytes_u64 = snapshot_get_u64(source + LF_SNAPSHOT_NATIVE_SIZE_OFFSET);
  content_size_u64 = snapshot_get_u64(source + LF_SNAPSHOT_CONTENT_SIZE_OFFSET);
  cumulative_frames =
      snapshot_get_u64(source + LF_SNAPSHOT_CUMULATIVE_FRAMES_OFFSET);
  cumulative_ticks =
      snapshot_get_u64(source + LF_SNAPSHOT_CUMULATIVE_TICKS_OFFSET);
  pending_buttons =
      snapshot_get_u32(source + LF_SNAPSHOT_PENDING_BUTTONS_OFFSET);
  flags = snapshot_get_u32(source + LF_SNAPSHOT_FLAGS_OFFSET);
  same_instance_origin =
      memcmp(source + LF_SNAPSHOT_INSTANCE_ID_OFFSET, state->instance_identity,
             sizeof(state->instance_identity)) == 0;
  if (total_bytes_u64 > (uint64_t)LF_NESTURBATOR_MAX_SNAPSHOT_BYTES ||
      !snapshot_u64_to_size(total_bytes_u64, &encoded_total_bytes) ||
      !snapshot_u64_to_size(native_bytes_u64, &encoded_native_bytes)) {
    return LF_LIMIT_EXCEEDED;
  }
  if (!snapshot_size_to_u64(state->content_size_bytes,
                            &expected_content_size_u64) ||
      encoded_total_bytes != extent_bytes ||
      encoded_total_bytes != expected_total_bytes ||
      encoded_native_bytes != expected_native_bytes ||
      encoded_native_bytes != extent_bytes -
                                  (size_t)LF_NESTURBATOR_SNAPSHOT_HEADER_BYTES ||
      snapshot_get_u32(source + LF_SNAPSHOT_STATE_FORMAT_OFFSET) !=
          NESTURBATOR_STATE_FORMAT_VERSION ||
      snapshot_get_u32(source + LF_SNAPSHOT_CORE_ABI_OFFSET) !=
          NESTURBATOR_ABI_VERSION ||
      snapshot_get_u32(source + LF_SNAPSHOT_BEHAVIOR_REVISION_OFFSET) !=
          NESTURBATOR_BEHAVIOUR_REVISION ||
      !snapshot_identity_matches(
          source + LF_SNAPSHOT_BUILD_ID_OFFSET,
          LF_NESTURBATOR_SNAPSHOT_BUILD_ID_BYTES, k_build_id) ||
      !snapshot_identity_matches(
          source + LF_SNAPSHOT_LIBFUTURO_BUILD_ID_OFFSET,
          LF_NESTURBATOR_SNAPSHOT_LIBFUTURO_BUILD_ID_BYTES,
          k_libfuturo_build_id) ||
      !snapshot_identity_matches(
          source + LF_SNAPSHOT_PROFILE_ID_OFFSET,
          LF_NESTURBATOR_SNAPSHOT_PROFILE_ID_BYTES, k_profile_id) ||
      !snapshot_identity_matches(
          source + LF_SNAPSHOT_CONFIGURATION_ID_OFFSET,
          LF_NESTURBATOR_SNAPSHOT_CONFIGURATION_ID_BYTES,
          k_configuration_id) ||
      !snapshot_identity_matches(
          source + LF_SNAPSHOT_OPTIONS_ID_OFFSET,
          LF_NESTURBATOR_SNAPSHOT_OPTIONS_ID_BYTES, k_options_id) ||
      memcmp(source + LF_SNAPSHOT_CONTENT_DIGEST_OFFSET,
             state->content_digest, sizeof(state->content_digest)) != 0 ||
      (same_instance_origin &&
       snapshot_get_u64(source + LF_SNAPSHOT_LOAD_EPOCH_OFFSET) !=
           state->successful_load_epoch) ||
      content_size_u64 != expected_content_size_u64 ||
      !snapshot_continuation_is_valid(cumulative_frames, cumulative_ticks,
                                      pending_buttons, flags)) {
    return LF_INVALID_ARGUMENT;
  }
#if defined(LF_NESTURBATOR_TESTING)
  state->snapshot_restore_attempts += 1U;
#endif
  core_status = nesturbator_load_state(
      state->core,
      source + LF_NESTURBATOR_SNAPSHOT_HEADER_BYTES,
      encoded_native_bytes);
  if (core_status != NESTURBATOR_OK) {
    return map_core_status(core_status);
  }
  state->cumulative_frames = cumulative_frames;
  state->cumulative_ticks = cumulative_ticks;
  state->pending_buttons = pending_buttons;
  state->positive_advance_started =
      (flags & LF_SNAPSHOT_FLAG_POSITIVE_ADVANCE) != 0U;
  state->halted = (flags & LF_SNAPSHOT_FLAG_HALTED) != 0U;
  state->ticks_valid = (flags & LF_SNAPSHOT_FLAG_TICKS_VALID) != 0U;
  return LF_OK;
}

#if defined(LF_NESTURBATOR_TESTING)
lf_status lf_nesturbator_set_load_epoch_for_testing(
    lf_nesturbator_state *state, uint64_t load_epoch) {
  if (state == NULL) {
    return LF_INVALID_ARGUMENT;
  }
  state->successful_load_epoch = load_epoch;
  return LF_OK;
}

lf_status lf_nesturbator_get_restore_attempts_for_testing(
    const lf_nesturbator_state *state, uint64_t *attempts) {
  if (state == NULL || attempts == NULL) {
    return LF_INVALID_ARGUMENT;
  }
  *attempts = state->snapshot_restore_attempts;
  return LF_OK;
}
#endif

lf_status lf_nesturbator_copy_media(lf_nesturbator_state *state,
                                    uint8_t *destination,
                                    size_t capacity_bytes,
                                    lf_media_info *out) {
  uint8_t *source = NULL;
  size_t extent_bytes = 0U;
  uint64_t guest_generation = 0U;
  lf_status status = LF_OK;
  if (state == NULL || destination == NULL || out == NULL ||
      out->struct_size != sizeof(*out)) {
    return LF_INVALID_ARGUMENT;
  }
  if (!state->loaded) {
    return LF_INVALID_ARGUMENT;
  }
  status = get_save_span(state, &source, &extent_bytes);
  if (status != LF_OK) {
    return status;
  }
  if (capacity_bytes < extent_bytes) {
    return LF_BUFFER_TOO_SMALL;
  }

  guest_generation = nesturbator_save_generation(state->core);
  if (guest_generation < state->media_generation_base) {
    return LF_INVALID_ARGUMENT;
  }
  guest_generation -= state->media_generation_base;
  memcpy(destination, source, extent_bytes);
  *out = (lf_media_info){
      .struct_size = sizeof(*out),
      .identity = k_media_identity,
      .extent_bytes = extent_bytes,
      .guest_generation = guest_generation,
  };
  return LF_OK;
}

lf_status lf_nesturbator_import_media(lf_nesturbator_state *state,
                                      const char *identity,
                                      const uint8_t *source,
                                      size_t extent_bytes) {
  uint8_t *destination = NULL;
  size_t loaded_extent_bytes = 0U;
  lf_status status = LF_OK;
  if (state == NULL || identity == NULL || identity[0] == '\0' ||
      source == NULL || extent_bytes == 0U) {
    return LF_INVALID_ARGUMENT;
  }
  if (!state->loaded || state->positive_advance_started) {
    return LF_INVALID_ARGUMENT;
  }
  if (strcmp(identity, k_media_identity) != 0) {
    return LF_UNSUPPORTED;
  }
  status = get_save_span(state, &destination, &loaded_extent_bytes);
  if (status != LF_OK) {
    return status;
  }
  if (extent_bytes > LF_NESTURBATOR_MAX_CONTENT_BYTES) {
    return LF_LIMIT_EXCEEDED;
  }
  if (extent_bytes != loaded_extent_bytes) {
    return LF_INVALID_ARGUMENT;
  }

  memcpy(destination, source, extent_bytes);
  return LF_OK;
}
