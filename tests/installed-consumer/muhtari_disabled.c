#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <libfuturo/libfuturo.h>

static int fail(const char *message, lf_status status) {
  (void)fprintf(stderr, "muhtari_disabled: %s status=%d\n", message,
                (int)status);
  return 1;
}

int main(void) {
  static const char muhtari_profile_id[] = "muhtari-ntsc-v1";
  lf_profile disabled_profile = {.struct_size = sizeof(disabled_profile)};
  lf_profile base_profile = {.struct_size = sizeof(base_profile)};
  lf_instance *disabled_instance = NULL;
  lf_instance *base_instance = NULL;
  uint32_t supported = UINT32_MAX;
  lf_status status =
      lf_get_profile(muhtari_profile_id, NULL, &disabled_profile);
  if (status != LF_INVALID_ARGUMENT || disabled_profile.profile_id != NULL ||
      disabled_profile.frame_rate_numerator != 0U ||
      disabled_profile.frame_rate_denominator != 0U) {
    return fail("disabled Muhtari profile must be unknown", status);
  }

  status = lf_get_capability(muhtari_profile_id, NULL,
                             LF_CAP_LOGICAL_INPUT, &supported);
  if (status != LF_INVALID_ARGUMENT || supported != 0U) {
    return fail("disabled Muhtari capability must be unknown and unsupported",
                status);
  }

  status = lf_create(muhtari_profile_id, NULL, &disabled_instance);
  if (status != LF_INVALID_ARGUMENT || disabled_instance != NULL) {
    return fail("disabled Muhtari create must transfer no ownership", status);
  }

  status = lf_get_profile("nesturbator-ntsc-v1", NULL, &base_profile);
  if (status != LF_OK || base_profile.profile_id == NULL ||
      strcmp(base_profile.profile_id, "nesturbator-ntsc-v1") != 0 ||
      base_profile.video_format != LF_VIDEO_RGB24) {
    return fail("base installed profile remains usable", status);
  }
  status = lf_get_capability("nesturbator-ntsc-v1", NULL,
                             LF_CAP_LOGICAL_INPUT, &supported);
  if (status != LF_OK || supported != 1U) {
    return fail("base installed capability remains usable", status);
  }
  status = lf_create("nesturbator-ntsc-v1", NULL, &base_instance);
  if (status != LF_OK || base_instance == NULL) {
    return fail("base installed create remains usable", status);
  }
  status = lf_destroy(&base_instance);
  if (status != LF_OK || base_instance != NULL) {
    return fail("base installed owner cleanup", status);
  }

  (void)puts("muhtari_disabled: unknown-profile=explicit base-profile=usable result=pass");
  return 0;
}
