/* SPDX-License-Identifier: MIT */
#ifndef LF_HOST_AUDIO_METADATA_H
#define LF_HOST_AUDIO_METADATA_H

#include <libfuturo/libfuturo.h>

static inline int lf_host_audio_tuple_is_supported(
    lf_audio_encoding encoding, lf_audio_layout layout,
    uint32_t rateNumerator, uint32_t rateDenominator, uint32_t channels) {
  return encoding == LF_AUDIO_S16_NATIVE &&
         layout == LF_AUDIO_INTERLEAVED && rateNumerator == 48000U &&
         rateDenominator == 1U && channels == 1U;
}

static inline int lf_host_profile_audio_is_supported(const lf_profile *profile) {
  return profile != NULL &&
         lf_host_audio_tuple_is_supported(
             profile->audio_encoding, profile->audio_layout,
             profile->audio_rate_numerator, profile->audio_rate_denominator,
             profile->audio_channels);
}

static inline int lf_host_result_audio_is_supported(
    const lf_run_result *result) {
  return result != NULL &&
         lf_host_audio_tuple_is_supported(
             result->audio_encoding, result->audio_layout,
             result->audio_rate_numerator, result->audio_rate_denominator,
             result->audio_channels);
}

#endif
