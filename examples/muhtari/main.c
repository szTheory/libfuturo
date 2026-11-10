#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libfuturo/libfuturo.h>

#define VIDEO_SENTINEL UINT8_C(0xA5)
#define AUDIO_SENTINEL INT16_C(0x5A5A)

static int fail(const char *operation, lf_status status) {
  (void)fprintf(stderr, "muhtari_host: %s failed with status %d\n", operation,
                (int)status);
  return 0;
}

static int require_capability(const char *name, lf_capability capability,
                              lf_status expected_status,
                              uint32_t expected_supported) {
  uint32_t supported = UINT32_MAX;
  const lf_status status =
      lf_get_capability("muhtari-ntsc-v1", NULL, capability, &supported);
  if (status != expected_status || supported != expected_supported) {
    (void)fprintf(stderr,
                  "muhtari_host: capability %s expected status=%d supported=%u, "
                  "got status=%d supported=%u\n",
                  name, (int)expected_status, expected_supported, (int)status,
                  supported);
    return 0;
  }
  return 1;
}

static int read_content(const char *path, size_t maximum_bytes,
                        uint8_t **content_out, size_t *size_out) {
  FILE *input = NULL;
  long file_size = 0L;
  uint8_t *content = NULL;
  size_t content_size = 0U;
  int close_failed = 0;

  if (path == NULL || path[0] == '\0' || content_out == NULL ||
      size_out == NULL) {
    (void)fprintf(stderr, "muhtari_host: invalid content path or output\n");
    return 0;
  }
  input = fopen(path, "rb");
  if (input == NULL) {
    (void)fprintf(stderr, "muhtari_host: could not open content file\n");
    return 0;
  }
  if (fseek(input, 0L, SEEK_END) != 0 || (file_size = ftell(input)) <= 0L ||
      (uintmax_t)file_size > (uintmax_t)maximum_bytes ||
      (uintmax_t)file_size > (uintmax_t)SIZE_MAX ||
      fseek(input, 0L, SEEK_SET) != 0) {
    (void)fprintf(stderr, "muhtari_host: content size is invalid or exceeds profile bound\n");
    (void)fclose(input);
    return 0;
  }

  content_size = (size_t)file_size;
  content = (uint8_t *)malloc(content_size);
  if (content == NULL) {
    (void)fprintf(stderr, "muhtari_host: content allocation failed\n");
    (void)fclose(input);
    return 0;
  }
  if (fread(content, 1U, content_size, input) != content_size ||
      fgetc(input) != EOF || ferror(input) != 0) {
    (void)fprintf(stderr, "muhtari_host: content read was incomplete\n");
    free(content);
    (void)fclose(input);
    return 0;
  }
  close_failed = fclose(input) != 0;
  if (close_failed != 0) {
    (void)fprintf(stderr, "muhtari_host: content close failed\n");
    free(content);
    return 0;
  }
  *content_out = content;
  *size_out = content_size;
  return 1;
}

static int interval_matches(const lf_profile *profile, lf_instance *instance,
                            size_t index, uint32_t buttons,
                            uint8_t *video, size_t video_capacity,
                            size_t video_stride, size_t video_extent,
                            int16_t *audio, size_t audio_capacity) {
  static const size_t expected_samples[2] = {54U, 801U};
  lf_input input = {.struct_size = sizeof(input), .buttons = buttons};
  lf_run_request request = {
      .struct_size = sizeof(request),
      .work_units = 1U,
      .video_data = video,
      .video_capacity_bytes = video_capacity,
      .video_stride_bytes = video_stride,
      .audio_data = audio,
      .audio_capacity_samples = audio_capacity,
  };
  lf_run_result result = {.struct_size = sizeof(result)};
  int non_silent_audio = 0;
  int visible_pixel_written = 0;

  if (lf_set_input(instance, &input) != LF_OK) {
    (void)fprintf(stderr, "muhtari_host: logical input update failed\n");
    return 0;
  }
  memset(video, VIDEO_SENTINEL, video_capacity);
  for (size_t sample = 0U; sample < audio_capacity; ++sample) {
    audio[sample] = AUDIO_SENTINEL;
  }
  {
    const lf_status status = lf_advance(instance, &request, &result);
    if (status != LF_OK) {
      return fail("bounded frame advance", status);
    }
  }

  if (result.requested_units != 1U || result.actual_units != 1U ||
      result.overshoot_units != 0U || result.sampled_buttons != buttons ||
      result.cumulative_units != (uint64_t)(index + 1U) ||
      result.time_unit != LF_TIME_FRAME ||
      result.core_ticks_valid != 0U || result.cumulative_core_ticks != 0U ||
      result.stop_reason != LF_STOP_BUDGET_REACHED || result.video_valid != 1U ||
      result.audio_valid != 1U || result.video_format != LF_VIDEO_INDEX8 ||
      result.video_width != profile->video_width ||
      result.video_height != profile->video_height ||
      result.video_stride_bytes != video_stride ||
      result.video_extent_bytes != video_extent ||
      result.audio_encoding != LF_AUDIO_S16_NATIVE ||
      result.audio_layout != LF_AUDIO_INTERLEAVED ||
      result.audio_rate_numerator != 48000U ||
      result.audio_rate_denominator != 1U || result.audio_channels != 1U ||
      result.audio_produced_samples != expected_samples[index]) {
    (void)fprintf(stderr, "muhtari_host: interval %zu result metadata mismatch\n",
                  index + 1U);
    return 0;
  }

  for (size_t row = 0U; row < (size_t)profile->video_height; ++row) {
    const size_t row_start = row * video_stride;
    for (size_t column = 0U; column < (size_t)profile->video_width; ++column) {
      if (video[row_start + column] != VIDEO_SENTINEL) {
        visible_pixel_written = 1;
      }
    }
    for (size_t padding = (size_t)profile->video_width;
         padding < video_stride; ++padding) {
      if (video[row_start + padding] != VIDEO_SENTINEL) {
        (void)fprintf(stderr, "muhtari_host: video row padding was modified\n");
        return 0;
      }
    }
  }
  for (size_t byte = video_extent; byte < video_capacity; ++byte) {
    if (video[byte] != VIDEO_SENTINEL) {
      (void)fprintf(stderr, "muhtari_host: video trailing guard was modified\n");
      return 0;
    }
  }
  for (size_t sample = 0U; sample < result.audio_produced_samples; ++sample) {
    if (audio[sample] != 0) {
      non_silent_audio = 1;
    }
  }
  for (size_t sample = result.audio_produced_samples;
       sample < audio_capacity; ++sample) {
    if (audio[sample] != AUDIO_SENTINEL) {
      (void)fprintf(stderr, "muhtari_host: audio tail was modified\n");
      return 0;
    }
  }
  if (visible_pixel_written == 0 || non_silent_audio == 0) {
    (void)fprintf(stderr, "muhtari_host: expected indexed video/audio output\n");
    return 0;
  }

  (void)printf("muhtari_host: interval=%zu input=0x%04" PRIx32
               " samples=%zu video=INDEX8 raw-first-byte=0x%02x\n",
               index + 1U, buttons, result.audio_produced_samples,
               (unsigned int)video[0]);
  return 1;
}

int main(int argc, char **argv) {
  lf_profile profile = {.struct_size = sizeof(profile)};
  lf_instance *instance = NULL;
  lf_load_request load_request = {.struct_size = sizeof(load_request)};
  lf_load_result load_result = {.struct_size = sizeof(load_result)};
  uint8_t *content = NULL;
  size_t content_size = 0U;
  uint8_t *video = NULL;
  int16_t *audio = NULL;
  size_t video_stride = 0U;
  size_t video_extent = 0U;
  size_t video_capacity = 0U;
  size_t audio_capacity = 0U;
  int exit_code = 1;

  if (argc != 2) {
    (void)fprintf(stderr, "usage: muhtari_host <owned-diagnostic-file>\n");
    goto cleanup;
  }
  {
    const lf_status status =
        lf_get_profile("muhtari-ntsc-v1", NULL, &profile);
    if (status != LF_OK) {
      (void)fail("profile query", status);
      goto cleanup;
    }
  }
  if (profile.profile_id == NULL ||
      strcmp(profile.profile_id, "muhtari-ntsc-v1") != 0 ||
      profile.core_id == NULL || strcmp(profile.core_id, "muhtari") != 0 ||
      profile.input_mask != UINT32_C(0xF1F1) || profile.max_work_units != 1U ||
      profile.max_guest_units != UINT32_MAX ||
      profile.atomic_quantum_units != 1U || profile.max_overshoot_units != 0U ||
      profile.time_unit != LF_TIME_FRAME ||
      profile.input_sampling != LF_INPUT_AT_ADVANCE_START ||
      profile.video_format != LF_VIDEO_INDEX8 || profile.video_width != 320U ||
      profile.video_height != 242U || profile.video_bytes_per_pixel != 1U ||
      profile.frame_rate_numerator != 39375000U ||
      profile.frame_rate_denominator != 656711U ||
      profile.audio_encoding != LF_AUDIO_S16_NATIVE ||
      profile.audio_layout != LF_AUDIO_INTERLEAVED ||
      profile.audio_rate_numerator != 48000U ||
      profile.audio_rate_denominator != 1U || profile.audio_channels != 1U ||
      profile.max_audio_samples_per_call != 801U ||
      profile.max_content_bytes != 1048704U ||
      profile.effective_configuration_id == NULL ||
      strcmp(profile.effective_configuration_id,
             "muhtari-ntsc-joystick-default") != 0) {
    (void)fprintf(stderr, "muhtari_host: profile metadata mismatch\n");
    goto cleanup;
  }

  if (!require_capability("logical-input", LF_CAP_LOGICAL_INPUT, LF_OK, 1U) ||
      !require_capability("bounded-execution", LF_CAP_BOUNDED_EXECUTION,
                          LF_OK, 1U) ||
      !require_capability("software-video", LF_CAP_SOFTWARE_VIDEO, LF_OK,
                          1U) ||
      !require_capability("audio", LF_CAP_AUDIO, LF_OK, 1U) ||
      !require_capability("media-copy", LF_CAP_IN_MEMORY_MEDIA_COPY,
                          LF_UNSUPPORTED, 0U) ||
      !require_capability("snapshot", LF_CAP_SNAPSHOT, LF_UNSUPPORTED, 0U) ||
      !require_capability("hardware-video", LF_CAP_HARDWARE_VIDEO,
                          LF_UNSUPPORTED, 0U) ||
      !require_capability("concurrent-use", LF_CAP_CONCURRENT_USE,
                          LF_UNSUPPORTED, 0U)) {
    goto cleanup;
  }
  if (!read_content(argv[1], profile.max_content_bytes, &content,
                    &content_size)) {
    goto cleanup;
  }

  {
    const lf_status status = lf_create("muhtari-ntsc-v1", NULL, &instance);
    if (status != LF_OK || instance == NULL) {
      (void)fail("instance creation", status);
      goto cleanup;
    }
  }
  load_request.content_data = content;
  load_request.content_size_bytes = content_size;
  {
    const lf_status status = lf_load(instance, &load_request, &load_result);
    if (status != LF_OK || load_result.loaded != 1U ||
        load_result.content_size_bytes != content_size ||
        load_result.effective_configuration_id == NULL ||
        strcmp(load_result.effective_configuration_id,
               "muhtari-ntsc-joystick-default") != 0) {
      (void)fail("content load", status);
      goto cleanup;
    }
  }
  free(content);
  content = NULL;

  if ((size_t)profile.video_width >
      SIZE_MAX / (size_t)profile.video_bytes_per_pixel) {
    (void)fprintf(stderr, "muhtari_host: video row size overflow\n");
    goto cleanup;
  }
  video_stride = profile.min_video_stride_bytes;
  if (video_stride <
      (size_t)profile.video_width * (size_t)profile.video_bytes_per_pixel ||
      profile.video_height == 0U ||
      (size_t)(profile.video_height - 1U) >
          (SIZE_MAX - (size_t)profile.video_width) / video_stride) {
    (void)fprintf(stderr, "muhtari_host: invalid profile video geometry\n");
    goto cleanup;
  }
  video_extent = (size_t)(profile.video_height - 1U) * video_stride +
                 (size_t)profile.video_width;
  if (video_extent > SIZE_MAX - 8U ||
      profile.max_audio_samples_per_call > (size_t)(SIZE_MAX / sizeof(*audio)) - 1U) {
    (void)fprintf(stderr, "muhtari_host: profile output bound overflow\n");
    goto cleanup;
  }
  video_capacity = video_extent + 8U;
  audio_capacity = profile.max_audio_samples_per_call + 1U;
  video = (uint8_t *)malloc(video_capacity);
  audio = (int16_t *)malloc(audio_capacity * sizeof(*audio));
  if (video == NULL || audio == NULL) {
    (void)fprintf(stderr, "muhtari_host: output allocation failed\n");
    goto cleanup;
  }

  if (!interval_matches(&profile, instance, 0U, UINT32_C(1), video,
                        video_capacity, video_stride, video_extent, audio,
                        audio_capacity) ||
      !interval_matches(&profile, instance, 1U, UINT32_C(1) << 8U, video,
                        video_capacity, video_stride, video_extent, audio,
                        audio_capacity)) {
    goto cleanup;
  }
  exit_code = 0;

cleanup:
  free(content);
  free(video);
  free(audio);
  {
    const lf_status status = lf_destroy(&instance);
    if (status != LF_OK || instance != NULL) {
      (void)fail("instance destruction", status);
      exit_code = 1;
    }
  }
  if (exit_code == 0) {
    (void)puts("muhtari_host: profile=muhtari-ntsc-v1 fixture=owned-a78-linear-16k "
               "intervals=partial-54,steady-801 video=INDEX8 raw=yes "
               "ownership=host result=pass");
  }
  return exit_code;
}
