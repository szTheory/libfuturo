#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <libfuturo/libfuturo.h>

static const uint8_t k_supported_content[4] = {'L', 'F', 'T', '1'};
static const uint8_t k_unsupported_content[4] = {'N', 'O', 'P', 'E'};
static const char k_media_identity[] = "synthetic-media-v1";

static const char *status_name(lf_status status);

static int check_common_profile_declarations(void) {
  static const struct {
    const char *profile_id;
    lf_video_format video_format;
    uint32_t bytes_per_pixel;
    lf_time_unit time_unit;
  } expected[] = {
      {"synthetic-v1", LF_VIDEO_GRAY8, 1U, LF_TIME_SYNTHETIC_STEP},
      {"nesturbator-ntsc-v1", LF_VIDEO_RGB24, 3U, LF_TIME_FRAME},
  };

  for (size_t index = 0U; index < sizeof(expected) / sizeof(expected[0]);
       ++index) {
    lf_profile profile = {.struct_size = sizeof(profile)};
    const lf_status status =
        lf_get_profile(expected[index].profile_id, NULL, &profile);
    if (status != LF_OK ||
        profile.video_format != expected[index].video_format ||
        profile.video_bytes_per_pixel != expected[index].bytes_per_pixel ||
        profile.time_unit != expected[index].time_unit ||
        profile.frame_rate_numerator != 0U ||
        profile.frame_rate_denominator != 0U) {
      (void)fprintf(stderr,
                    "conformance: common profile format/cadence mismatch for %s "
                    "status=%s format=%d bpp=%u unit=%d cadence=%u/%u\n",
                    expected[index].profile_id, status_name(status),
                    (int)profile.video_format, profile.video_bytes_per_pixel,
                    (int)profile.time_unit, profile.frame_rate_numerator,
                    profile.frame_rate_denominator);
      return 1;
    }
  }
  return 0;
}

static const char *status_name(lf_status status) {
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
  return "UNKNOWN";
}

static int check_load_state(void) {
  static const uint8_t first_media[4] = {'S', 'A', 'V', 'E'};
  static const uint8_t replacement_media[4] = {'N', 'E', 'W', '!'};
  uint8_t copied_media[4] = {0U};
  lf_instance *instance = NULL;
  lf_load_result load_result = {.struct_size = sizeof(load_result)};
  lf_media_info media_info = {.struct_size = sizeof(media_info)};
  const lf_load_request supported_request = {
      .struct_size = sizeof(supported_request),
      .content_data = k_supported_content,
      .content_size_bytes = sizeof(k_supported_content),
  };
  const lf_load_request unsupported_request = {
      .struct_size = sizeof(unsupported_request),
      .content_data = k_unsupported_content,
      .content_size_bytes = sizeof(k_unsupported_content),
  };
  lf_status status = lf_create("synthetic-v1", NULL, &instance);
  if (status != LF_OK || instance == NULL) {
    (void)fprintf(stderr,
                  "conformance: LC-LOAD-01 failed setup expected=LF_OK observed=%s\n",
                  status_name(status));
    return 1;
  }

  status = lf_load(instance, &supported_request, &load_result);
  if (status != LF_OK || load_result.loaded != 1U) {
    (void)fprintf(stderr,
                  "conformance: LC-LOAD-01 failed setup-load expected=LF_OK/loaded:1 observed=%s/loaded:%u\n",
                  status_name(status), load_result.loaded);
    (void)lf_destroy(&instance);
    return 1;
  }
  status = lf_import_media(instance, k_media_identity, first_media,
                           sizeof(first_media));
  if (status != LF_OK) {
    (void)fprintf(stderr,
                  "conformance: LC-LOAD-01 failed setup-import expected=LF_OK observed=%s\n",
                  status_name(status));
    (void)lf_destroy(&instance);
    return 1;
  }

  status = lf_load(instance, &unsupported_request, &load_result);
  if (status != LF_UNSUPPORTED) {
    (void)fprintf(stderr,
                  "conformance: LC-LOAD-01 failed refusal-status expected=LF_UNSUPPORTED observed=%s\n",
                  status_name(status));
    (void)lf_destroy(&instance);
    return 1;
  }
  status = lf_copy_media(instance, copied_media, sizeof(copied_media),
                         &media_info);
  if (status != LF_OK || memcmp(copied_media, first_media, sizeof(first_media)) != 0 ||
      media_info.guest_generation != 0U) {
    (void)fprintf(stderr,
                  "conformance: LC-LOAD-01 failed retained-media expected=LF_OK/SAVE/generation:0 observed=%s/%c%c%c%c/generation:%llu\n",
                  status_name(status), copied_media[0], copied_media[1],
                  copied_media[2], copied_media[3],
                  (unsigned long long)media_info.guest_generation);
    (void)lf_destroy(&instance);
    return 1;
  }

  status = lf_import_media(instance, k_media_identity, replacement_media,
                           sizeof(replacement_media));
  if (status != LF_OK) {
    (void)fprintf(stderr,
                  "conformance: LC-LOAD-01 failed unsupported-load-preservation expected=LF_OK observed=%s\n",
                  status_name(status));
    (void)lf_destroy(&instance);
    return 1;
  }
  status = lf_copy_media(instance, copied_media, sizeof(copied_media),
                         &media_info);
  if (status != LF_OK ||
      memcmp(copied_media, replacement_media, sizeof(replacement_media)) != 0 ||
      media_info.guest_generation != 0U) {
    (void)fprintf(stderr,
                  "conformance: LC-LOAD-01 failed post-import-state expected=LF_OK/NEW!/generation:0 observed=%s/%c%c%c%c/generation:%llu\n",
                  status_name(status), copied_media[0], copied_media[1],
                  copied_media[2], copied_media[3],
                  (unsigned long long)media_info.guest_generation);
    (void)lf_destroy(&instance);
    return 1;
  }

  status = lf_destroy(&instance);
  if (status != LF_OK || instance != NULL) {
    (void)fprintf(stderr,
                  "conformance: LC-LOAD-01 failed cleanup expected=LF_OK/null-owner observed=%s/%s\n",
                  status_name(status), instance == NULL ? "null" : "owned");
    return 1;
  }
  return 0;
}

static int check_guest_units(void) {
  uint8_t video[4] = {0xA5U, 0xA5U, 0xA5U, 0xA5U};
  int16_t audio[2] = {INT16_C(1234), INT16_C(1234)};
  lf_instance *instance = NULL;
  lf_load_result load_result = {.struct_size = sizeof(load_result)};
  lf_input input = {.struct_size = sizeof(input), .buttons = 1U};
  lf_run_request request = {
      .struct_size = sizeof(request),
      .work_units = 1U,
      .video_data = video,
      .video_capacity_bytes = sizeof(video),
      .video_stride_bytes = 2U,
      .audio_data = audio,
      .audio_capacity_samples = sizeof(audio) / sizeof(audio[0]),
  };
  lf_run_result result = {.struct_size = sizeof(result)};
  const lf_load_request load_request = {
      .struct_size = sizeof(load_request),
      .content_data = k_supported_content,
      .content_size_bytes = sizeof(k_supported_content),
  };
  lf_status status = lf_create("synthetic-v1", NULL, &instance);
  if (status != LF_OK || instance == NULL) {
    (void)fprintf(stderr,
                  "conformance: LC-TIME-01 failed setup expected=LF_OK observed=%s\n",
                  status_name(status));
    return 1;
  }
  status = lf_load(instance, &load_request, &load_result);
  if (status != LF_OK || load_result.loaded != 1U) {
    (void)fprintf(stderr,
                  "conformance: LC-TIME-01 failed setup-load expected=LF_OK/loaded:1 observed=%s/loaded:%u\n",
                  status_name(status), load_result.loaded);
    (void)lf_destroy(&instance);
    return 1;
  }
  status = lf_set_input(instance, &input);
  if (status != LF_OK) {
    (void)fprintf(stderr,
                  "conformance: LC-TIME-01 failed setup-input expected=LF_OK observed=%s\n",
                  status_name(status));
    (void)lf_destroy(&instance);
    return 1;
  }
  status = lf_advance(instance, &request, &result);
  if (status != LF_OK) {
    (void)fprintf(stderr,
                  "conformance: LC-TIME-01 failed advance expected=LF_OK observed=%s\n",
                  status_name(status));
    (void)lf_destroy(&instance);
    return 1;
  }
  if (result.requested_units != 1U || result.actual_units != 1U ||
      result.cumulative_units != 1U ||
      result.time_unit != LF_TIME_SYNTHETIC_STEP) {
    (void)fprintf(stderr,
                  "conformance: LC-TIME-01 failed guest-unit-accounting expected=requested:1,actual:1,cumulative:1,unit:LF_TIME_SYNTHETIC_STEP observed=requested:%u,actual:%u,cumulative:%llu,unit:%d\n",
                  result.requested_units, result.actual_units,
                  (unsigned long long)result.cumulative_units,
                  (int)result.time_unit);
    (void)lf_destroy(&instance);
    return 1;
  }
  if (result.sampled_buttons != 1U || result.video_valid != 1U ||
      result.audio_valid != 1U || video[0] != 1U || video[1] != 2U ||
      video[2] != 1U || video[3] != 3U || audio[0] != 32 || audio[1] != -32) {
    (void)fprintf(stderr,
                  "conformance: LC-TIME-01 failed independent-output expected=buttons:1,video:1/2/1/3,audio:32/-32 observed=buttons:%u,video:%u/%u/%u/%u,audio:%d/%d\n",
                  result.sampled_buttons, video[0], video[1], video[2],
                  video[3], (int)audio[0], (int)audio[1]);
    (void)lf_destroy(&instance);
    return 1;
  }
  status = lf_destroy(&instance);
  if (status != LF_OK || instance != NULL) {
    (void)fprintf(stderr,
                  "conformance: LC-TIME-01 failed cleanup expected=LF_OK/null-owner observed=%s/%s\n",
                  status_name(status), instance == NULL ? "null" : "owned");
    return 1;
  }
  return 0;
}

int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "--check-load-state") == 0) {
    return check_load_state();
  }
  if (argc == 2 && strcmp(argv[1], "--check-guest-units") == 0) {
    return check_guest_units();
  }
  if (argc != 1) {
    (void)fprintf(stderr, "conformance: unknown mode\n");
    return 2;
  }
  if (check_common_profile_declarations() != 0 || check_load_state() != 0 ||
      check_guest_units() != 0) {
    return 1;
  }
  (void)printf("conformance: profile-format-cadence=synthetic:GRAY8:0/0,"
               "nesturbator:RGB24:0/0 result=pass\n");
  (void)printf("conformance: LC-LOAD-01,LC-TIME-01 result=pass\n");
  return 0;
}
