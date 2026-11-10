#include <libfuturo/libfuturo.h>

#include "muhtari_fixture.h"
#include "muhtari_oracle.h"

#include <emscripten/emscripten.h>

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#ifndef EXPECTED_PROFILE_ID
#error "The installed package must provide the expected profile identity"
#endif
#ifndef EXPECTED_CONFIGURATION_ID
#error "The installed package must provide the expected configuration identity"
#endif
#ifndef EXPECTED_CORE_BUILD_ID
#error "The installed package must provide the expected core build identity"
#endif
#ifndef EXPECTED_LIBFUTURO_BUILD_ID
#error "The installed package must provide the expected LibFuturo build identity"
#endif
#ifndef EXPECTED_FIXTURE_SHA256
#error "The installed package must carry fixture digest metadata"
#endif

#define LFWEB_WIDTH 320U
#define LFWEB_HEIGHT 242U
#define LFWEB_VIDEO_BYTES (LFWEB_WIDTH * LFWEB_HEIGHT)
#define LFWEB_MAX_AUDIO_SAMPLES 801U
#define LFWEB_MAX_CONTENT_BYTES 1048704U

static uint8_t g_content[LFWEB_MAX_CONTENT_BYTES];
static uint8_t g_video[LFWEB_VIDEO_BYTES];
static int16_t g_audio[LFWEB_MAX_AUDIO_SAMPLES];
static uint8_t g_fixture[LF_MUHTARI_FIXTURE_TOTAL_BYTES];
static size_t g_audio_samples;
static size_t g_fixture_bytes;
static size_t g_profile_queries;
static size_t g_content_copies;
static size_t g_load_calls;
static size_t g_advance_calls;
static size_t g_instance_creates;
static size_t g_destroy_calls;
static size_t g_input_transition_calls;
static size_t g_progress;
static size_t g_max_content_bytes;
static lf_instance *g_instance;
static lf_status g_last_load_status = LF_INVALID_ARGUMENT;
static lf_status g_last_advance_status = LF_INVALID_ARGUMENT;
static int g_profile_validated;
static int g_content_loaded;
static int g_output_valid;
static int g_audio_oracle_valid;
static uint32_t g_last_sampled_buttons;

static int positive_identity(void) {
  lf_profile profile = {.struct_size = sizeof(lf_profile)};
  lf_instance *instance = NULL;
  const lf_status status =
      lf_get_profile(EXPECTED_PROFILE_ID, EXPECTED_CONFIGURATION_ID, &profile);
  if (status != LF_OK || profile.profile_id == NULL || profile.core_id == NULL ||
      profile.build_id == NULL || profile.effective_configuration_id == NULL ||
      strcmp(profile.profile_id, EXPECTED_PROFILE_ID) != 0 ||
      strcmp(profile.core_id, "muhtari") != 0 ||
      strcmp(profile.build_id, EXPECTED_CORE_BUILD_ID) != 0 ||
      profile.api_revision != 8U || profile.behavior_revision != 6U ||
      strcmp(profile.effective_configuration_id,
             EXPECTED_CONFIGURATION_ID) != 0) {
    return 0;
  }

  if (lf_create(EXPECTED_PROFILE_ID, NULL, &instance) != LF_OK ||
      instance == NULL) {
    return 0;
  }
  if (lf_destroy(&instance) != LF_OK || instance != NULL) {
    return 0;
  }

  printf("LFWEB_RESULT {\"scenario\":\"positive\",\"result\":\"pass\",\"profile\":\"%s\",\"core\":\"%s\",\"core_build\":\"%s\",\"api\":%u,\"abi\":1,\"behavior\":%u,\"configuration\":\"%s\",\"libfuturo_build\":\"%s\",\"instance_created\":true,\"instance_destroyed\":true,\"load_called\":false}\n",
         profile.profile_id, profile.core_id, profile.build_id,
         profile.api_revision, profile.behavior_revision,
         profile.effective_configuration_id, EXPECTED_LIBFUTURO_BUILD_ID);
  return fflush(stdout) == 0;
}

static int mismatch_refused_before_content(void) {
  lf_profile profile = {.struct_size = sizeof(lf_profile)};
  const lf_status status = lf_get_profile(
      EXPECTED_PROFILE_ID, "muhtari-ntsc-battery-diagnostic-mismatch", &profile);
  if (status != LF_UNSUPPORTED) {
    return 0;
  }

  printf("LFWEB_RESULT {\"scenario\":\"mismatch\",\"result\":\"pass\",\"status\":%u,\"load_called\":false,\"content_accessed\":false}\n",
         (unsigned int)status);
  return fflush(stdout) == 0;
}

EMSCRIPTEN_KEEPALIVE int lfweb_profile_matches(void) {
  lf_profile profile = {.struct_size = sizeof(lf_profile)};
  const lf_status status =
      lf_get_profile(EXPECTED_PROFILE_ID, EXPECTED_CONFIGURATION_ID, &profile);
  g_profile_queries += 1U;
  g_profile_validated =
      status == LF_OK && profile.profile_id != NULL && profile.core_id != NULL &&
      profile.build_id != NULL && profile.effective_configuration_id != NULL &&
      strcmp(profile.profile_id, EXPECTED_PROFILE_ID) == 0 &&
      strcmp(profile.core_id, "muhtari") == 0 &&
      strcmp(profile.build_id, EXPECTED_CORE_BUILD_ID) == 0 &&
      profile.api_revision == 8U && profile.behavior_revision == 6U &&
      profile.video_format == LF_VIDEO_INDEX8 &&
      profile.video_width == LFWEB_WIDTH && profile.video_height == LFWEB_HEIGHT &&
      profile.audio_encoding == LF_AUDIO_S16_NATIVE &&
      profile.audio_layout == LF_AUDIO_INTERLEAVED &&
      profile.audio_rate_numerator == 48000U &&
      profile.audio_rate_denominator == 1U && profile.audio_channels == 1U &&
      profile.max_audio_samples_per_call == LFWEB_MAX_AUDIO_SAMPLES &&
      profile.max_content_bytes == LFWEB_MAX_CONTENT_BYTES &&
      profile.input_mask == UINT32_C(0xF1) &&
      strcmp(profile.effective_configuration_id, EXPECTED_CONFIGURATION_ID) == 0;
  if (g_profile_validated != 0) {
    g_max_content_bytes = profile.max_content_bytes;
  }
  return g_profile_validated;
}

EMSCRIPTEN_KEEPALIVE size_t lfweb_max_content_bytes(void) {
  return g_profile_validated != 0 ? g_max_content_bytes : 0U;
}

EMSCRIPTEN_KEEPALIVE uintptr_t lfweb_content_buffer(void) {
  return (uintptr_t)g_content;
}

EMSCRIPTEN_KEEPALIVE uintptr_t lfweb_fixture_buffer(void) {
  if (g_fixture_bytes == 0U) {
    g_fixture_bytes =
        lf_build_muhtari_fixture(g_fixture, sizeof(g_fixture));
  }
  return (uintptr_t)g_fixture;
}

EMSCRIPTEN_KEEPALIVE size_t lfweb_fixture_size(void) {
  if (g_fixture_bytes == 0U) {
    (void)lfweb_fixture_buffer();
  }
  return g_fixture_bytes;
}

EMSCRIPTEN_KEEPALIVE int lfweb_load_buffer(size_t content_bytes) {
  lf_load_result result = {.struct_size = sizeof(result)};
  lf_load_request request = {
      .struct_size = sizeof(request),
      .content_data = g_content,
      .content_size_bytes = content_bytes,
      .configuration_id = EXPECTED_CONFIGURATION_ID,
  };
  if (g_profile_validated == 0) {
    g_last_load_status = LF_UNSUPPORTED;
    return (int)g_last_load_status;
  }
  g_content_loaded = 0;
  g_progress = 0U;
  g_output_valid = 0;
  g_audio_samples = 0U;
  if (content_bytes == 0U) {
    g_last_load_status = LF_INVALID_ARGUMENT;
    return (int)g_last_load_status;
  }
  if (content_bytes > g_max_content_bytes || content_bytes > sizeof(g_content)) {
    g_last_load_status = LF_LIMIT_EXCEEDED;
    return (int)g_last_load_status;
  }
  g_content_copies += 1U;
  if (g_instance == NULL) {
    if (lf_create(EXPECTED_PROFILE_ID, NULL, &g_instance) != LF_OK ||
        g_instance == NULL) {
      g_last_load_status = LF_RESOURCE_EXHAUSTED;
      return (int)g_last_load_status;
    }
    g_instance_creates += 1U;
  }
  g_load_calls += 1U;
  g_last_load_status = lf_load(g_instance, &request, &result);
  if (g_last_load_status == LF_OK && result.loaded == 1U &&
      result.content_size_bytes == content_bytes &&
      result.effective_configuration_id != NULL &&
      strcmp(result.effective_configuration_id, EXPECTED_CONFIGURATION_ID) == 0) {
    g_content_loaded = 1;
    g_progress = 0U;
    g_output_valid = 0;
  } else {
    g_content_loaded = 0;
  }
  return (int)g_last_load_status;
}

EMSCRIPTEN_KEEPALIVE int lfweb_advance_once(uint32_t buttons) {
  lf_input input = {.struct_size = sizeof(input), .buttons = buttons};
  lf_run_request request = {
      .struct_size = sizeof(request),
      .work_units = 1U,
      .video_data = g_video,
      .video_capacity_bytes = sizeof(g_video),
      .video_stride_bytes = LFWEB_WIDTH,
      .audio_data = g_audio,
      .audio_capacity_samples = LFWEB_MAX_AUDIO_SAMPLES,
  };
  lf_run_result result = {.struct_size = sizeof(result)};
  g_advance_calls += 1U;
  g_output_valid = 0;
  g_audio_oracle_valid = 0;
  g_audio_samples = 0U;
  g_last_sampled_buttons = 0U;
  if (g_instance == NULL || g_content_loaded == 0) {
    g_last_advance_status = LF_INVALID_ARGUMENT;
    return (int)g_last_advance_status;
  }
  g_last_advance_status = lf_set_input(g_instance, &input);
  if (g_last_advance_status == LF_OK) {
    g_last_advance_status = lf_advance(g_instance, &request, &result);
  }
  if (g_last_advance_status != LF_OK ||
      result.struct_size != sizeof(result) || result.requested_units != 1U ||
      result.actual_units != 1U || result.overshoot_units != 0U ||
      result.sampled_buttons != buttons || result.video_valid != 1U ||
      result.audio_valid != 1U || result.cumulative_units != g_progress + 1U ||
      result.video_format != LF_VIDEO_INDEX8 ||
      result.video_width != LFWEB_WIDTH || result.video_height != LFWEB_HEIGHT ||
      result.video_stride_bytes != LFWEB_WIDTH ||
      result.video_extent_bytes != sizeof(g_video) ||
      result.audio_encoding != LF_AUDIO_S16_NATIVE ||
      result.audio_layout != LF_AUDIO_INTERLEAVED ||
      result.audio_rate_numerator != 48000U ||
      result.audio_rate_denominator != 1U || result.audio_channels != 1U ||
      result.audio_produced_samples == 0U ||
      result.audio_produced_samples > LFWEB_MAX_AUDIO_SAMPLES) {
    if (g_last_advance_status == LF_OK) {
      g_last_advance_status = LF_INVALID_ARGUMENT;
    }
    return (int)g_last_advance_status;
  }
  if (g_progress < LF_MUHTARI_ORACLE_FRAME_COUNT) {
    char digest[65];
    if (!lf_muhtari_oracle_pcm_matches(
            g_audio, result.audio_produced_samples, g_progress, digest)) {
      g_last_advance_status = LF_INVALID_ARGUMENT;
      return (int)g_last_advance_status;
    }
  } else if (result.audio_produced_samples != 800U &&
             result.audio_produced_samples != 801U) {
    g_last_advance_status = LF_INVALID_ARGUMENT;
    return (int)g_last_advance_status;
  }
  g_audio_oracle_valid = 1;
  g_last_sampled_buttons = result.sampled_buttons;
  g_audio_samples = result.audio_produced_samples;
  g_progress = (size_t)result.cumulative_units;
  g_output_valid = 1;
  return (int)g_last_advance_status;
}

EMSCRIPTEN_KEEPALIVE int lfweb_set_input(uint32_t buttons) {
  lf_input input = {.struct_size = sizeof(input), .buttons = buttons};
  if (g_instance == NULL || g_content_loaded == 0 ||
      (buttons & ~UINT32_C(0xF1)) != 0U) {
    return (int)LF_INVALID_ARGUMENT;
  }
  const lf_status status = lf_set_input(g_instance, &input);
  if (status == LF_OK) {
    g_input_transition_calls += 1U;
  }
  return (int)status;
}

EMSCRIPTEN_KEEPALIVE int lfweb_output_valid(void) { return g_output_valid; }
EMSCRIPTEN_KEEPALIVE int lfweb_audio_oracle_valid(void) {
  return g_audio_oracle_valid;
}
EMSCRIPTEN_KEEPALIVE int lfweb_content_loaded(void) { return g_content_loaded; }
EMSCRIPTEN_KEEPALIVE int lfweb_last_load_status(void) { return (int)g_last_load_status; }
EMSCRIPTEN_KEEPALIVE int lfweb_last_advance_status(void) { return (int)g_last_advance_status; }
EMSCRIPTEN_KEEPALIVE size_t lfweb_audio_sample_count(void) { return g_audio_samples; }
EMSCRIPTEN_KEEPALIVE size_t lfweb_progress(void) { return g_progress; }
EMSCRIPTEN_KEEPALIVE size_t lfweb_profile_query_count(void) { return g_profile_queries; }
EMSCRIPTEN_KEEPALIVE size_t lfweb_content_copy_count(void) { return g_content_copies; }
EMSCRIPTEN_KEEPALIVE size_t lfweb_load_call_count(void) { return g_load_calls; }
EMSCRIPTEN_KEEPALIVE size_t lfweb_advance_call_count(void) { return g_advance_calls; }
EMSCRIPTEN_KEEPALIVE size_t lfweb_instance_create_count(void) { return g_instance_creates; }
EMSCRIPTEN_KEEPALIVE size_t lfweb_destroy_call_count(void) { return g_destroy_calls; }
EMSCRIPTEN_KEEPALIVE size_t lfweb_input_transition_count(void) {
  return g_input_transition_calls;
}
EMSCRIPTEN_KEEPALIVE uint32_t lfweb_last_sampled_buttons(void) {
  return g_last_sampled_buttons;
}
EMSCRIPTEN_KEEPALIVE uintptr_t lfweb_video_buffer(void) { return (uintptr_t)g_video; }
EMSCRIPTEN_KEEPALIVE uintptr_t lfweb_audio_buffer(void) { return (uintptr_t)g_audio; }

EMSCRIPTEN_KEEPALIVE int lfweb_destroy(void) {
  if (g_instance != NULL) {
    g_destroy_calls += 1U;
    if (lf_destroy(&g_instance) != LF_OK || g_instance != NULL) {
      return 0;
    }
  }
  g_content_loaded = 0;
  g_progress = 0U;
  g_output_valid = 0;
  g_audio_samples = 0U;
  g_audio_oracle_valid = 0;
  g_last_sampled_buttons = 0U;
  memset(g_content, 0, sizeof(g_content));
  memset(g_video, 0, sizeof(g_video));
  memset(g_audio, 0, sizeof(g_audio));
  return 1;
}

int main(void) {
  return positive_identity() && mismatch_refused_before_content() ? 0 : 1;
}
