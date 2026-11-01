#ifndef LIBFUTURO_TESTS_SYNTHETIC_ORACLE_H
#define LIBFUTURO_TESTS_SYNTHETIC_ORACLE_H

#include <stddef.h>
#include <stdint.h>

typedef struct synthetic_oracle_row {
  uint32_t input_buttons;
  uint32_t requested_units;
  uint64_t cumulative_units;
  uint8_t video_bytes[4];
  int16_t audio_samples[4];
  size_t audio_sample_count;
  uint8_t media_bytes[4];
  uint64_t media_generation;
} synthetic_oracle_row;

static const synthetic_oracle_row synthetic_oracle_rows[3] = {
    {0U, 1U, 1U, {1U, 1U, 0U, 2U}, {16, -16, 0, 0}, 2U,
     {76U, 70U, 1U, 1U}, 1U},
    {1U, 2U, 3U, {3U, 5U, 1U, 8U}, {48, -48, 80, -80}, 4U,
     {76U, 70U, 3U, 5U}, 3U},
    {2U, 1U, 4U, {4U, 8U, 2U, 12U}, {128, -128, 0, 0}, 2U,
     {76U, 70U, 4U, 8U}, 4U},
};

#endif
