#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE 1

#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <libfuturo/libfuturo.h>

#include "libfuturo_internal.h"
#include "sha256.h"
#include "nesturbator_save_fixture.h"
#include "nesturbator_save_oracle.h"

#define SAVE_FIXTURE_RAM_BYTES LF_SAVE_ORACLE_EXTENT_BYTES
#define SAVE_FIXTURE_EXPECTED_BYTE LF_SAVE_ORACLE_COMMITTED_BYTE
#define SAVE_FIXTURE_CONTINUATION_BYTE LF_SAVE_ORACLE_CONTINUATION_BYTE
#define SAVE_CONTENT_IDENTITY LF_SAVE_ORACLE_CONTENT_IDENTITY
#define SAVE_MEDIA_IDENTITY LF_SAVE_ORACLE_MEDIA_IDENTITY
#define SAVE_CONFIGURATION_IDENTITY LF_SAVE_ORACLE_CONFIGURATION_IDENTITY

#ifndef LIBFUTURO_NESTURBATOR_SOURCE_REVISION
#define LIBFUTURO_NESTURBATOR_SOURCE_REVISION "unverified"
#endif

#define NESTURBATOR_EXPECTED_SOURCE_REVISION \
  "2338608ab184f040620a30d17756f5e06a42d4e3"
#define FIXTURE_PRG_BANKS 1U
#define FIXTURE_CHR_BANKS 1U
#define FIXTURE_PRG_BYTES (16U * 1024U)
#define FIXTURE_CHR_BYTES (8U * 1024U)
#define FIXTURE_HEADER_BYTES 16U
#define FIXTURE_TOTAL_BYTES \
  (FIXTURE_HEADER_BYTES + FIXTURE_PRG_BYTES + FIXTURE_CHR_BYTES)
#define FIXTURE_PRG_OFFSET FIXTURE_HEADER_BYTES
#define FIXTURE_VECTOR_OFFSET (FIXTURE_PRG_BYTES - 6U)
#define VIDEO_WIDTH 256U
#define VIDEO_HEIGHT 240U
#define VIDEO_ROW_PADDING_BYTES 5U
#define VIDEO_STRIDE_BYTES (VIDEO_WIDTH * 3U + VIDEO_ROW_PADDING_BYTES)
#define VIDEO_EXTENT_BYTES \
  (VIDEO_STRIDE_BYTES * (VIDEO_HEIGHT - 1U) + VIDEO_WIDTH * 3U)
#define AUDIO_MAX_SAMPLES 799U
#define FIXTURE_MAX_WARMUP_FRAMES 120U

static const uint8_t k_save_magic[8] = {'L', 'F', 'S', 'A', 'V', 'E', '1', 0};

typedef struct save_envelope_header {
  uint8_t magic[8];
  uint32_t version;
  uint32_t header_bytes;
  uint64_t extent_bytes;
  uint64_t guest_generation;
  char content_identity[LF_SAVE_ORACLE_CONTENT_IDENTITY_CAPACITY];
  char configuration_identity[LF_SAVE_ORACLE_CONFIGURATION_IDENTITY_CAPACITY];
  char media_identity[LF_SAVE_ORACLE_MEDIA_IDENTITY_CAPACITY];
} save_envelope_header;

#define SAVE_ENVELOPE_HEADER_BYTES \
  (8U + 4U + 4U + 8U + 8U + \
   LF_SAVE_ORACLE_CONTENT_IDENTITY_CAPACITY + \
   LF_SAVE_ORACLE_CONFIGURATION_IDENTITY_CAPACITY + \
   LF_SAVE_ORACLE_MEDIA_IDENTITY_CAPACITY)
#define SAVE_ENVELOPE_MAX_BYTES \
  (SAVE_ENVELOPE_HEADER_BYTES + SAVE_FIXTURE_RAM_BYTES)

typedef enum save_stage_result {
  SAVE_STAGE_FAILED = 0,
  SAVE_STAGE_COMMITTED = 1,
  SAVE_STAGE_INJECTED_PREFIX_FAILURE = 2
} save_stage_result;

typedef struct save_acknowledgment {
  const uint8_t *payload;
  size_t extent_bytes;
  uint64_t guest_generation;
  int committed;
} save_acknowledgment;

/* The original 6502 program clears the first nametable, disables APU output,
   then reads controller A at each vblank. Port 0 A selects palette entry $06,
   port 1 A selects $2B, and neither selects $16. CHR tile zero is all zeroes,
   so every visible background pixel uses that universal color. The exact pin's
   public XRGB8888 palette values are $06=0x00690A00, $2B=0x0041E5A1, and
   $16=0x00BA3100. These RGB literals were fixed before running the generated
   cartridge; this test does not derive them from the adapter conversion or
   observed frame bytes. */
static const uint8_t k_pressed_rgb[3] = {0x69U, 0x0AU, 0x00U};
static const uint8_t k_wrong_expected_rgb[3] = {0x68U, 0x0AU, 0x00U};
static const uint8_t k_port1_rgb[3] = {0x41U, 0xE5U, 0xA1U};
static const uint8_t k_released_rgb[3] = {0xBAU, 0x31U, 0x00U};

typedef struct rgb_mismatch {
  size_t row;
  size_t pixel;
  char channel;
  uint8_t expected;
  uint8_t actual;
} rgb_mismatch;

/* Offsets are relative to $8000. The final JMP returns to the vblank wait at
   $803D. Each short branch is hand-calculated from its following instruction. */
static const uint8_t k_fixture_program[] = {
    0x78U,                   /* SEI */
    0xD8U,                   /* CLD */
    0xA2U, 0x40U,             /* LDX #$40 */
    0x8EU, 0x17U, 0x40U,      /* STX $4017: inhibit APU frame IRQ */
    0xA9U, 0x00U,             /* LDA #$00 */
    0x8DU, 0x15U, 0x40U,      /* STA $4015: disable every APU channel */
    0x8DU, 0x00U, 0x20U,      /* STA $2000: disable NMI */
    0x8DU, 0x01U, 0x20U,      /* STA $2001: disable rendering while setup runs */
    0xADU, 0x02U, 0x20U,      /* LDA $2002: reset PPU address toggle */
    0xA9U, 0x3FU,             /* LDA #$3F */
    0x8DU, 0x06U, 0x20U,      /* STA $2006: palette address high */
    0xA9U, 0x00U,             /* LDA #$00 */
    0x8DU, 0x06U, 0x20U,      /* STA $2006: universal backdrop address */
    0xA9U, 0x0FU,             /* LDA #$0F */
    0x8DU, 0x07U, 0x20U,      /* STA $2007: initial backdrop */
    0xA9U, 0x20U,             /* LDA #$20 */
    0x8DU, 0x06U, 0x20U,      /* STA $2006: nametable address high */
    0xA9U, 0x00U,             /* LDA #$00 */
    0x8DU, 0x06U, 0x20U,      /* STA $2006: nametable address low */
    0xA9U, 0x00U,             /* LDA #$00, tile zero */
    0xA0U, 0x04U,             /* LDY #$04, clear four pages */
    0xA2U, 0x00U,             /* LDX #$00 */
    0x8DU, 0x07U, 0x20U,      /* clear_page: STA $2007 */
    0xE8U,                   /* INX */
    0xD0U, 0xFAU,             /* BNE clear_page */
    0x88U,                   /* DEY */
    0xD0U, 0xF5U,             /* BNE clear_page_setup */
    0xADU, 0x02U, 0x20U,      /* vblank_wait: LDA $2002 */
    0x10U, 0xFBU,             /* BPL vblank_wait */
    0xA9U, 0x01U,             /* LDA #$01 */
    0x8DU, 0x16U, 0x40U,      /* STA $4016: strobe controller */
    0xA9U, 0x00U,             /* LDA #$00 */
    0x8DU, 0x16U, 0x40U,      /* STA $4016: latch controller */
    0xADU, 0x16U, 0x40U,      /* LDA $4016: port 0 serial A bit */
    0x29U, 0x01U,             /* AND #$01 */
    0xD0U, 0x0BU,             /* BNE port0_pressed */
    0xADU, 0x17U, 0x40U,      /* LDA $4017: port 1 serial A bit */
    0x29U, 0x01U,             /* AND #$01 */
    0xF0U, 0x08U,             /* BEQ color_released */
    0xA9U, 0x2BU,             /* LDA #$2B, port 1 backdrop */
    0xD0U, 0x06U,             /* BNE color_selected */
    0xA9U, 0x06U,             /* port0_pressed: LDA #$06 */
    0xD0U, 0x02U,             /* BNE color_selected */
    0xA9U, 0x16U,             /* color_released: LDA #$16 */
    0x85U, 0x00U,             /* color_selected: STA $00 */
    0xA9U, 0x3FU,             /* LDA #$3F */
    0x8DU, 0x06U, 0x20U,      /* STA $2006: palette high */
    0xA9U, 0x00U,             /* LDA #$00 */
    0x8DU, 0x06U, 0x20U,      /* STA $2006: universal backdrop */
    0xA5U, 0x00U,             /* LDA $00 */
    0x8DU, 0x07U, 0x20U,      /* STA $2007: select the visible color */
    0xA9U, 0x08U,             /* LDA #$08: background rendering only */
    0x8DU, 0x01U, 0x20U,      /* STA $2001 */
    0x4CU, 0x3DU, 0x80U       /* JMP vblank_wait */
};

typedef struct allocation_tracker {
  size_t calls;
  size_t fail_on_call;
  size_t allocations;
  size_t frees;
  size_t live;
  size_t invalid_frees;
  void *live_allocations[2048];
} allocation_tracker;

static uint8_t k_fixture[LF_NESTURBATOR_SAVE_FIXTURE_TOTAL_BYTES];
static uint8_t k_video[VIDEO_EXTENT_BYTES];
static uint8_t k_retained_video[VIDEO_EXTENT_BYTES];
static int16_t k_audio[AUDIO_MAX_SAMPLES];
static int16_t k_retained_audio[AUDIO_MAX_SAMPLES];
static uint8_t k_interleaved_video[2][VIDEO_EXTENT_BYTES];
static int16_t k_interleaved_audio[2][AUDIO_MAX_SAMPLES];
static uint8_t k_frame_subject_video[VIDEO_EXTENT_BYTES + 1U];
static uint8_t k_frame_control_video[VIDEO_EXTENT_BYTES + 1U];
static uint8_t k_frame_subject_video_before[VIDEO_EXTENT_BYTES + 1U];
static uint8_t k_frame_control_video_before[VIDEO_EXTENT_BYTES + 1U];
static int16_t k_frame_subject_audio[AUDIO_MAX_SAMPLES + 1U];
static int16_t k_frame_control_audio[AUDIO_MAX_SAMPLES + 1U];
static int16_t k_frame_subject_audio_before[AUDIO_MAX_SAMPLES + 1U];
static int16_t k_frame_control_audio_before[AUDIO_MAX_SAMPLES + 1U];
static lf_run_result k_last_pair_result;

#define REQUIRE(condition, label)                                            \
  do {                                                                        \
    if (!(condition)) {                                                       \
      (void)fprintf(stderr, "nesturbator_session: %s failed\n", (label));   \
      exit_code = 1;                                                          \
      goto cleanup;                                                           \
    }                                                                         \
  } while (0)

static void *tracked_allocate(void *context, size_t bytes) {
  allocation_tracker *tracker = context;
  size_t slot = 0U;
  tracker->calls += 1U;
  if (tracker->fail_on_call != 0U &&
      tracker->fail_on_call == tracker->calls) {
    return NULL;
  }
  void *allocation = malloc(bytes);
  if (allocation == NULL) {
    return NULL;
  }
  for (slot = 0U; slot < sizeof(tracker->live_allocations) /
                              sizeof(tracker->live_allocations[0]);
       ++slot) {
    if (tracker->live_allocations[slot] == NULL) {
      tracker->live_allocations[slot] = allocation;
      tracker->allocations += 1U;
      tracker->live += 1U;
      return allocation;
    }
  }
  free(allocation);
  return NULL;
}

static void tracked_deallocate(void *context, void *allocation) {
  allocation_tracker *tracker = context;
  size_t slot = 0U;
  if (allocation == NULL) {
    return;
  }
  for (slot = 0U; slot < sizeof(tracker->live_allocations) /
                              sizeof(tracker->live_allocations[0]);
       ++slot) {
    if (tracker->live_allocations[slot] == allocation) {
      tracker->live_allocations[slot] = NULL;
      tracker->frees += 1U;
      tracker->live -= 1U;
      free(allocation);
      return;
    }
  }
  tracker->invalid_frees += 1U;
}

static size_t build_fixture(uint8_t *destination, size_t capacity) {
  static const uint16_t reset_vector = UINT16_C(0x8000);
  const size_t total_bytes = (size_t)FIXTURE_TOTAL_BYTES;
  size_t vector_offset = 0U;

  if (destination == NULL || capacity < total_bytes) {
    return 0U;
  }
  memset(destination, 0, total_bytes);
  destination[0] = (uint8_t)'N';
  destination[1] = (uint8_t)'E';
  destination[2] = (uint8_t)'S';
  destination[3] = 0x1AU;
  destination[4] = (uint8_t)FIXTURE_PRG_BANKS;
  destination[5] = (uint8_t)FIXTURE_CHR_BANKS;
  memcpy(destination + FIXTURE_PRG_OFFSET, k_fixture_program,
         sizeof(k_fixture_program));
  for (vector_offset = 0U; vector_offset < 6U; vector_offset += 2U) {
    const size_t offset = (size_t)FIXTURE_PRG_OFFSET +
                          (size_t)FIXTURE_VECTOR_OFFSET + vector_offset;
    destination[offset] = (uint8_t)(reset_vector & UINT16_C(0x00FF));
    destination[offset + 1U] =
        (uint8_t)((reset_vector >> 8U) & UINT16_C(0x00FF));
  }
  return total_bytes;
}

static size_t build_jam_fixture(uint8_t *destination, size_t capacity) {
  static const uint8_t controller_a_test[] = {0x29U, 0x01U, 0xD0U, 0x0BU};
  const size_t total_bytes = build_fixture(destination, capacity);
  uint8_t *program = NULL;
  size_t index = 0U;
  const size_t program_size = sizeof(k_fixture_program);

  if (total_bytes == 0U) {
    return 0U;
  }
  program = destination + FIXTURE_PRG_OFFSET;
  for (index = 0U;
       index + sizeof(controller_a_test) <= program_size; ++index) {
    if (memcmp(program + index, controller_a_test,
                sizeof(controller_a_test)) == 0) {
      const size_t insert_at = index + sizeof(controller_a_test);
      const size_t jam_offset = program_size + 7U;
      const size_t branch_after = insert_at + 7U;
      const size_t branch_distance = jam_offset - branch_after;
      if (branch_distance > (size_t)INT8_MAX) {
        return 0U;
      }
      memmove(program + insert_at + 7U, program + insert_at,
              program_size - insert_at);
      program[index + 3U] = 0x12U;
      program[insert_at] = 0xADU;
      program[insert_at + 1U] = 0x16U;
      program[insert_at + 2U] = 0x40U;
      program[insert_at + 3U] = 0x29U;
      program[insert_at + 4U] = 0x01U;
      program[insert_at + 5U] = 0xD0U;
      program[insert_at + 6U] = (uint8_t)branch_distance;
      program[jam_offset] = 0x02U;
      return total_bytes;
    }
  }
  return 0U;
}

static int frame_matches_literal_rgb(const uint8_t *video,
                                     const uint8_t expected_rgb[3],
                                     rgb_mismatch *mismatch) {
  static const char channels[] = {'R', 'G', 'B'};
  size_t y = 0U;
  size_t x = 0U;
  size_t channel = 0U;
  for (y = 0U; y < VIDEO_HEIGHT; ++y) {
    const size_t row_offset = y * VIDEO_STRIDE_BYTES;
    for (x = 0U; x < VIDEO_WIDTH; ++x) {
      const size_t pixel_offset = row_offset + x * 3U;
      for (channel = 0U; channel < 3U; ++channel) {
        if (video[pixel_offset + channel] != expected_rgb[channel]) {
          if (mismatch != NULL) {
            *mismatch = (rgb_mismatch){
                .row = y,
                .pixel = x,
                .channel = channels[channel],
                .expected = expected_rgb[channel],
                .actual = video[pixel_offset + channel],
            };
          }
          return 0;
        }
      }
    }
  }
  return 1;
}

static int frame_is_literal_rgb(const uint8_t *video,
                                const uint8_t expected_rgb[3]) {
  return frame_matches_literal_rgb(video, expected_rgb, NULL);
}

static int video_padding_is_untouched(const uint8_t *video) {
  size_t y = 0U;
  size_t padding = 0U;
  for (y = 0U; y + 1U < VIDEO_HEIGHT; ++y) {
    const size_t row_offset = y * VIDEO_STRIDE_BYTES;
    for (padding = 0U; padding < VIDEO_ROW_PADDING_BYTES; ++padding) {
      if (video[row_offset + VIDEO_WIDTH * 3U + padding] != 0xA5U) {
        return 0;
      }
    }
  }
  return 1;
}

static int bytes_equal_value(const uint8_t *bytes, size_t count,
                            uint8_t expected) {
  size_t index = 0U;
  for (index = 0U; index < count; ++index) {
    if (bytes[index] != expected) {
      return 0;
    }
  }
  return 1;
}

static int run_color_case(lf_instance *instance, uint32_t buttons,
                          const uint8_t expected_rgb[3], uint64_t *frames,
                          uint64_t *last_ticks, size_t *last_audio_count) {
  lf_input input = {.struct_size = sizeof(input), .buttons = buttons};
  rgb_mismatch last_mismatch = {0};
  size_t attempt = 0U;

  if (lf_set_input(instance, &input) != LF_OK) {
    (void)fprintf(stderr, "nesturbator_session: set input failed\n");
    return 0;
  }
  for (attempt = 0U; attempt < FIXTURE_MAX_WARMUP_FRAMES; ++attempt) {
    lf_run_request request = {
        .struct_size = sizeof(request),
        .work_units = 1U,
        .video_data = k_video,
        .video_capacity_bytes = sizeof(k_video),
        .video_stride_bytes = VIDEO_STRIDE_BYTES,
        .audio_data = k_audio,
        .audio_capacity_samples = AUDIO_MAX_SAMPLES,
    };
    lf_run_result result = {.struct_size = sizeof(result)};
    lf_status status = LF_INVALID_ARGUMENT;
    size_t sample = 0U;
    memset(k_video, 0xA5, sizeof(k_video));
    for (sample = 0U; sample < AUDIO_MAX_SAMPLES; ++sample) {
      k_audio[sample] = INT16_C(1234);
    }

    status = lf_advance(instance, &request, &result);
    if (status != LF_OK || result.requested_units != 1U ||
        result.actual_units != 1U || result.overshoot_units != 0U ||
        result.sampled_buttons != buttons ||
        result.cumulative_units != *frames + 1U ||
        result.stop_reason != LF_STOP_BUDGET_REACHED ||
        result.video_valid != 1U || result.audio_valid != 1U ||
        result.time_unit != LF_TIME_FRAME || result.core_ticks_valid != 1U ||
        result.core_tick_time_unit != LF_TIME_NES_HALF_MASTER_TICK ||
        result.cumulative_core_ticks <= *last_ticks ||
        result.video_format != LF_VIDEO_RGB24 ||
        result.video_width != VIDEO_WIDTH || result.video_height != VIDEO_HEIGHT ||
        result.video_stride_bytes != VIDEO_STRIDE_BYTES ||
        result.video_extent_bytes != VIDEO_EXTENT_BYTES ||
        result.audio_encoding != LF_AUDIO_S16_NATIVE ||
        result.audio_layout != LF_AUDIO_INTERLEAVED ||
        result.audio_rate_numerator != 48000U ||
        result.audio_rate_denominator != 1U || result.audio_channels != 1U ||
        (result.audio_produced_samples != 798U &&
         result.audio_produced_samples != 799U)) {
      (void)fprintf(stderr,
                    "nesturbator_session: frame metadata failed at attempt %zu "
                    "status=%d actual=%u cumulative=%" PRIu64 " ticks=%" PRIu64 "\n",
                    attempt, (int)status, result.actual_units,
                    result.cumulative_units, result.cumulative_core_ticks);
      return 0;
    }
    if (!video_padding_is_untouched(k_video)) {
      (void)fprintf(stderr,
                    "nesturbator_session: video row padding changed at attempt %zu\n",
                    attempt);
      return 0;
    }
    for (sample = 0U; sample < result.audio_produced_samples; ++sample) {
      if (k_audio[sample] != 0) {
        (void)fprintf(stderr,
                      "nesturbator_session: disabled APU PCM sample %zu was %d\n",
                      sample, (int)k_audio[sample]);
        return 0;
      }
    }
    for (sample = result.audio_produced_samples;
         sample < AUDIO_MAX_SAMPLES; ++sample) {
      if (k_audio[sample] != INT16_C(1234)) {
        (void)fprintf(stderr,
                      "nesturbator_session: audio tail changed at sample %zu\n",
                      sample);
        return 0;
      }
    }
    *frames = result.cumulative_units;
    *last_ticks = result.cumulative_core_ticks;
    *last_audio_count = result.audio_produced_samples;
    if (frame_matches_literal_rgb(k_video, expected_rgb, &last_mismatch)) {
      return 1;
    }
  }

  (void)fprintf(stderr,
                "nesturbator_session: video mismatch row=%zu pixel=%zu "
                "channel=%c expected=0x%02X actual=0x%02X\n",
                last_mismatch.row, last_mismatch.pixel,
                last_mismatch.channel, (unsigned int)last_mismatch.expected,
                (unsigned int)last_mismatch.actual);
  return 0;
}

static int emit_fixture(const char *destination) {
  uint8_t fixture[FIXTURE_TOTAL_BYTES];
  const size_t fixture_bytes = build_fixture(fixture, sizeof(fixture));
  FILE *output = NULL;
  size_t written = 0U;
  int write_failed = 0;
  int close_failed = 0;

  if (destination == NULL || destination[0] == '\0' ||
      fixture_bytes != (size_t)FIXTURE_TOTAL_BYTES) {
    (void)fprintf(stderr,
                  "nesturbator_session: fixture destination or generated extent is invalid\n");
    return 1;
  }
  output = fopen(destination, "wb");
  if (output == NULL) {
    (void)fprintf(stderr,
                  "nesturbator_session: could not open fixture destination '%s'\n",
                  destination);
    return 1;
  }
  written = fwrite(fixture, 1U, fixture_bytes, output);
  write_failed = written != fixture_bytes || ferror(output) != 0;
  close_failed = fclose(output) != 0;
  if (write_failed || close_failed) {
    (void)fprintf(stderr,
                  "nesturbator_session: fixture write/close failed for '%s'\n",
                  destination);
    return 1;
  }
  (void)printf("nesturbator_session: emitted generated-nrom bytes=%zu\n",
               fixture_bytes);
  return 0;
}

static void save_fixture_digest_hex(const uint8_t digest[32], char hex[65]) {
  static const char digits[] = "0123456789abcdef";
  size_t index = 0U;
  for (index = 0U; index < 32U; ++index) {
    hex[index * 2U] = digits[(size_t)(digest[index] >> 4U)];
    hex[index * 2U + 1U] = digits[(size_t)(digest[index] & 0x0FU)];
  }
  hex[64] = '\0';
}

static int emit_save_fixture(const char *destination) {
  uint8_t fixture[LF_NESTURBATOR_SAVE_FIXTURE_TOTAL_BYTES];
  uint8_t digest[32];
  char digest_hex[65];
  const size_t fixture_bytes =
      lf_build_nesturbator_save_fixture(fixture, sizeof(fixture));
  FILE *output = NULL;
  size_t written = 0U;
  int write_failed = 0;
  int close_failed = 0;
  if (destination == NULL || destination[0] == '\0' || fixture_bytes == 0U ||
      !lf_nesturbator_save_fixture_sha256(fixture, fixture_bytes, digest)) {
    return 1;
  }
  output = fopen(destination, "wb");
  if (output == NULL) {
    return 1;
  }
  written = fwrite(fixture, 1U, fixture_bytes, output);
  write_failed = written != fixture_bytes || ferror(output) != 0;
  close_failed = fclose(output) != 0;
  if (write_failed || close_failed) {
    return 1;
  }
  save_fixture_digest_hex(digest, digest_hex);
  (void)printf("nesturbator_session: emitted generated-mmc1-battery bytes=%zu "
               "sha256=%s\n",
               fixture_bytes, digest_hex);
  return 0;
}

static int advance_interleaved_frame(lf_instance *instance, uint32_t buttons,
                                     const uint8_t expected_rgb[3],
                                     uint8_t *video, int16_t *audio,
                                     uint64_t *frames, uint64_t *last_ticks,
                                     int *literal_seen) {
  lf_run_request request = {
      .struct_size = sizeof(request),
      .work_units = 1U,
      .video_data = video,
      .video_capacity_bytes = VIDEO_EXTENT_BYTES,
      .video_stride_bytes = VIDEO_STRIDE_BYTES,
      .audio_data = audio,
      .audio_capacity_samples = AUDIO_MAX_SAMPLES,
  };
  lf_run_result result = {.struct_size = sizeof(result)};
  lf_status status = LF_INVALID_ARGUMENT;
  size_t sample = 0U;
  memset(video, 0xA5, VIDEO_EXTENT_BYTES);
  for (sample = 0U; sample < AUDIO_MAX_SAMPLES; ++sample) {
    audio[sample] = INT16_C(1234);
  }

  status = lf_advance(instance, &request, &result);
  if (status != LF_OK || result.requested_units != 1U ||
      result.actual_units != 1U || result.sampled_buttons != buttons ||
      result.cumulative_units != *frames + 1U ||
      result.stop_reason != LF_STOP_BUDGET_REACHED ||
      result.video_valid != 1U || result.audio_valid != 1U ||
      result.time_unit != LF_TIME_FRAME || result.core_ticks_valid != 1U ||
      result.core_tick_time_unit != LF_TIME_NES_HALF_MASTER_TICK ||
      result.cumulative_core_ticks <= *last_ticks ||
      result.video_format != LF_VIDEO_RGB24 ||
      result.video_stride_bytes != VIDEO_STRIDE_BYTES ||
      result.video_extent_bytes != VIDEO_EXTENT_BYTES ||
      (result.audio_produced_samples != 798U &&
       result.audio_produced_samples != 799U) ||
      !video_padding_is_untouched(video)) {
    (void)fprintf(stderr,
                  "nesturbator_session: interleaved frame failed status=%d "
                  "buttons=%u frames=%" PRIu64 " ticks=%" PRIu64 "\n",
                  (int)status, result.sampled_buttons, result.cumulative_units,
                  result.cumulative_core_ticks);
    return 0;
  }
  for (sample = 0U; sample < result.audio_produced_samples; ++sample) {
    if (audio[sample] != 0) {
      (void)fprintf(stderr,
                    "nesturbator_session: interleaved PCM sample %zu was %d\n",
                    sample, (int)audio[sample]);
      return 0;
    }
  }
  for (sample = result.audio_produced_samples; sample < AUDIO_MAX_SAMPLES;
       ++sample) {
    if (audio[sample] != INT16_C(1234)) {
      (void)fprintf(stderr,
                    "nesturbator_session: interleaved audio tail changed\n");
      return 0;
    }
  }
  *frames = result.cumulative_units;
  *last_ticks = result.cumulative_core_ticks;
  if (frame_is_literal_rgb(video, expected_rgb)) {
    *literal_seen = 1;
  }
  return 1;
}

static int check_capability(lf_capability capability, lf_status expected_status,
                            uint32_t expected_supported) {
  uint32_t supported = UINT32_MAX;
  const lf_status status =
      lf_get_capability("nesturbator-ntsc-v1", NULL, capability, &supported);
  if (status != expected_status || supported != expected_supported) {
    (void)fprintf(stderr,
                  "nesturbator_session: capability %d expected status=%d "
                  "supported=%u, got status=%d supported=%u\n",
                  (int)capability, (int)expected_status, expected_supported,
                  (int)status, supported);
    return 0;
  }
  return 1;
}

static uint64_t hash_content(const uint8_t *bytes, size_t count) {
  uint64_t hash = UINT64_C(14695981039346656037);
  size_t index = 0U;
  for (index = 0U; index < count; ++index) {
    hash ^= bytes[index];
    hash *= UINT64_C(1099511628211);
  }
  return hash;
}

static int load_result_preserves_active(const lf_load_result *result,
                                        size_t content_size) {
  return result->struct_size == sizeof(*result) && result->loaded == 1U &&
         result->content_size_bytes == content_size &&
         result->effective_configuration_id != NULL &&
         strcmp(result->effective_configuration_id,
                "nesturbator-default") == 0;
}

static int create_test_instance(allocation_tracker *tracker,
                                lf_instance **instance) {
  lf_create_options options = {
      .struct_size = sizeof(options),
      .allocate = tracked_allocate,
      .deallocate = tracked_deallocate,
      .allocator_context = tracker,
  };
  return lf_create("nesturbator-ntsc-v1", &options, instance) == LF_OK &&
         *instance != NULL;
}

static int create_loaded_test_instance(allocation_tracker *tracker,
                                       lf_instance **instance,
                                       const uint8_t *fixture,
                                       size_t fixture_size) {
  lf_load_request request = {
      .struct_size = sizeof(request),
      .content_data = fixture,
      .content_size_bytes = fixture_size,
      .configuration_id = NULL,
  };
  lf_load_result result = {.struct_size = sizeof(result)};
  return create_test_instance(tracker, instance) &&
         lf_load(*instance, &request, &result) == LF_OK &&
         load_result_preserves_active(&result, fixture_size);
}

static int advance_pair_without_setting_input(lf_instance *subject,
                                              lf_instance *control,
                                              uint32_t expected_buttons) {
  uint8_t subject_video[VIDEO_EXTENT_BYTES];
  uint8_t control_video[VIDEO_EXTENT_BYTES];
  int16_t subject_audio[AUDIO_MAX_SAMPLES];
  int16_t control_audio[AUDIO_MAX_SAMPLES];
  lf_run_request subject_request = {
      .struct_size = sizeof(subject_request),
      .work_units = 1U,
      .video_data = subject_video,
      .video_capacity_bytes = sizeof(subject_video),
      .video_stride_bytes = VIDEO_STRIDE_BYTES,
      .audio_data = subject_audio,
      .audio_capacity_samples = AUDIO_MAX_SAMPLES,
  };
  lf_run_request control_request = subject_request;
  lf_run_result subject_result = {.struct_size = sizeof(subject_result)};
  lf_run_result control_result = {.struct_size = sizeof(control_result)};
  lf_status subject_status = LF_INVALID_ARGUMENT;
  lf_status control_status = LF_INVALID_ARGUMENT;

  control_request.video_data = control_video;
  control_request.audio_data = control_audio;
  memset(subject_video, 0xA5, sizeof(subject_video));
  memset(control_video, 0xA5, sizeof(control_video));
  for (size_t index = 0U; index < AUDIO_MAX_SAMPLES; ++index) {
    subject_audio[index] = INT16_C(1234);
    control_audio[index] = INT16_C(1234);
  }
  subject_status = lf_advance(subject, &subject_request, &subject_result);
  control_status = lf_advance(control, &control_request, &control_result);
  if (subject_status != LF_OK || control_status != LF_OK ||
      subject_result.actual_units != 1U || control_result.actual_units != 1U ||
      subject_result.overshoot_units != control_result.overshoot_units ||
      subject_result.sampled_buttons != expected_buttons ||
      control_result.sampled_buttons != expected_buttons ||
      subject_result.cumulative_units != control_result.cumulative_units ||
      subject_result.cumulative_core_ticks != control_result.cumulative_core_ticks ||
      subject_result.core_ticks_valid != control_result.core_ticks_valid ||
      subject_result.video_valid != 1U || control_result.video_valid != 1U ||
      subject_result.audio_valid != 1U || control_result.audio_valid != 1U ||
      subject_result.video_extent_bytes != control_result.video_extent_bytes ||
      subject_result.audio_produced_samples != control_result.audio_produced_samples ||
      memcmp(subject_video, control_video, sizeof(subject_video)) != 0 ||
      memcmp(subject_audio, control_audio, sizeof(subject_audio)) != 0) {
    return 0;
  }
  k_last_pair_result = subject_result;
  return 1;
}

static int frame_result_is_rejected(const lf_run_result *result,
                                    uint64_t expected_frames,
                                    uint64_t expected_ticks,
                                    uint32_t expected_ticks_valid) {
  return result->struct_size == sizeof(*result) &&
         result->actual_units == 0U && result->overshoot_units == 0U &&
         result->sampled_buttons == 0U && result->video_valid == 0U &&
         result->audio_valid == 0U && result->video_extent_bytes == 0U &&
         result->audio_produced_samples == 0U &&
         result->cumulative_units == expected_frames &&
         result->cumulative_core_ticks == expected_ticks &&
         result->core_ticks_valid == expected_ticks_valid &&
         result->stop_reason == LF_STOP_REJECTED;
}

static lf_run_request make_frame_request(uint32_t work_units,
                                         size_t video_capacity,
                                         size_t video_stride,
                                         size_t audio_capacity) {
  return (lf_run_request){
      .struct_size = sizeof(lf_run_request),
      .work_units = work_units,
      .video_data = k_frame_subject_video,
      .video_capacity_bytes = video_capacity,
      .video_stride_bytes = video_stride,
      .audio_data = k_frame_subject_audio,
      .audio_capacity_samples = audio_capacity,
  };
}

static void reset_frame_canaries(void) {
  memset(k_frame_subject_video, 0xA5, sizeof(k_frame_subject_video));
  memset(k_frame_control_video, 0xA5, sizeof(k_frame_control_video));
  for (size_t index = 0U; index < AUDIO_MAX_SAMPLES + 1U; ++index) {
    k_frame_subject_audio[index] = INT16_C(1234);
    k_frame_control_audio[index] = INT16_C(1234);
  }
}

static int reject_frame_and_compare(lf_instance *subject,
                                    lf_instance *control,
                                    allocation_tracker *subject_tracker,
                                    allocation_tracker *control_tracker,
                                    lf_run_request request,
                                    lf_status expected_status,
                                    uint32_t pending_buttons,
                                    const char *label) {
  const uint64_t expected_frames = k_last_pair_result.cumulative_units;
  const uint64_t expected_ticks = k_last_pair_result.cumulative_core_ticks;
  const uint32_t expected_ticks_valid =
      k_last_pair_result.core_ticks_valid;
  const size_t subject_calls_before = subject_tracker->calls;
  const size_t control_calls_before = control_tracker->calls;
  lf_run_result result = {.struct_size = sizeof(result)};
  lf_status status = LF_INVALID_ARGUMENT;

  reset_frame_canaries();
  memcpy(k_frame_subject_video_before, k_frame_subject_video,
         sizeof(k_frame_subject_video));
  memcpy(k_frame_control_video_before, k_frame_control_video,
         sizeof(k_frame_control_video));
  memcpy(k_frame_subject_audio_before, k_frame_subject_audio,
         sizeof(k_frame_subject_audio));
  memcpy(k_frame_control_audio_before, k_frame_control_audio,
         sizeof(k_frame_control_audio));
  request.video_data = k_frame_subject_video;
  request.audio_data = k_frame_subject_audio;
  if (lf_set_input(subject, &(lf_input){
                       .struct_size = sizeof(lf_input),
                       .buttons = pending_buttons,
                   }) != LF_OK ||
      lf_set_input(control, &(lf_input){
                       .struct_size = sizeof(lf_input),
                       .buttons = pending_buttons,
                   }) != LF_OK) {
    (void)fprintf(stderr, "nesturbator_session: %s input setup failed\n", label);
    return 0;
  }
  status = lf_advance(subject, &request, &result);
  if (status != expected_status ||
      !frame_result_is_rejected(&result, expected_frames, expected_ticks,
                                expected_ticks_valid) ||
      subject_tracker->calls != subject_calls_before ||
      control_tracker->calls != control_calls_before ||
      memcmp(k_frame_subject_video, k_frame_subject_video_before,
             sizeof(k_frame_subject_video)) != 0 ||
      memcmp(k_frame_control_video, k_frame_control_video_before,
             sizeof(k_frame_control_video)) != 0 ||
      memcmp(k_frame_subject_audio, k_frame_subject_audio_before,
             sizeof(k_frame_subject_audio)) != 0 ||
      memcmp(k_frame_control_audio, k_frame_control_audio_before,
             sizeof(k_frame_control_audio)) != 0) {
    (void)fprintf(stderr,
                  "nesturbator_session: %s rejection changed result, state, or buffers\n",
                  label);
    return 0;
  }
  if (!advance_pair_without_setting_input(subject, control, pending_buttons)) {
    (void)fprintf(stderr,
                  "nesturbator_session: %s did not preserve next-frame continuation\n",
                  label);
    return 0;
  }
  return 1;
}

static int advance_pair_with_capacities(lf_instance *subject,
                                        lf_instance *control,
                                        allocation_tracker *subject_tracker,
                                        allocation_tracker *control_tracker,
                                        size_t video_capacity,
                                        size_t video_stride,
                                        size_t audio_capacity,
                                        uint32_t pending_buttons,
                                        const char *label) {
  const uint64_t prior_frames = k_last_pair_result.cumulative_units;
  const uint64_t prior_ticks = k_last_pair_result.cumulative_core_ticks;
  const size_t subject_calls_before = subject_tracker->calls;
  const size_t control_calls_before = control_tracker->calls;
  lf_run_request subject_request = make_frame_request(
      1U, video_capacity, video_stride, audio_capacity);
  lf_run_request control_request = subject_request;
  lf_run_result subject_result = {.struct_size = sizeof(subject_result)};
  lf_run_result control_result = {.struct_size = sizeof(control_result)};
  lf_status subject_status = LF_INVALID_ARGUMENT;
  lf_status control_status = LF_INVALID_ARGUMENT;
  size_t index = 0U;

  reset_frame_canaries();
  control_request.video_data = k_frame_control_video;
  control_request.audio_data = k_frame_control_audio;
  if (lf_set_input(subject, &(lf_input){
                       .struct_size = sizeof(lf_input),
                       .buttons = pending_buttons,
                   }) != LF_OK ||
      lf_set_input(control, &(lf_input){
                       .struct_size = sizeof(lf_input),
                       .buttons = pending_buttons,
                   }) != LF_OK) {
    (void)fprintf(stderr, "nesturbator_session: %s input setup failed\n", label);
    return 0;
  }
  subject_status = lf_advance(subject, &subject_request, &subject_result);
  control_status = lf_advance(control, &control_request, &control_result);
  if (subject_status != LF_OK || control_status != LF_OK ||
      subject_result.actual_units != 1U || control_result.actual_units != 1U ||
      subject_result.cumulative_units != prior_frames + 1U ||
      control_result.cumulative_units != prior_frames + 1U ||
      subject_result.core_ticks_valid != 1U ||
      control_result.core_ticks_valid != 1U ||
      subject_result.cumulative_core_ticks <= prior_ticks ||
      control_result.cumulative_core_ticks <= prior_ticks ||
      subject_result.cumulative_core_ticks != control_result.cumulative_core_ticks ||
      subject_result.video_valid != 1U || control_result.video_valid != 1U ||
      subject_result.audio_valid != 1U || control_result.audio_valid != 1U ||
      subject_result.video_extent_bytes !=
          (VIDEO_HEIGHT - 1U) * video_stride + VIDEO_WIDTH * 3U ||
      control_result.video_extent_bytes != subject_result.video_extent_bytes ||
      subject_result.audio_produced_samples < 798U ||
      subject_result.audio_produced_samples > AUDIO_MAX_SAMPLES ||
      control_result.audio_produced_samples !=
          subject_result.audio_produced_samples ||
      subject_result.sampled_buttons != pending_buttons ||
      control_result.sampled_buttons != pending_buttons ||
      subject_tracker->calls != subject_calls_before ||
      control_tracker->calls != control_calls_before ||
      memcmp(k_frame_subject_video, k_frame_control_video,
             sizeof(k_frame_subject_video)) != 0 ||
      memcmp(k_frame_subject_audio, k_frame_control_audio,
             sizeof(k_frame_subject_audio)) != 0) {
    (void)fprintf(stderr,
                  "nesturbator_session: %s successful bounded frame diverged\n",
                  label);
    return 0;
  }
  for (index = 0U; index < subject_result.audio_produced_samples; ++index) {
    if (index >= audio_capacity) {
      (void)fprintf(stderr,
                    "nesturbator_session: %s wrote beyond audio capacity\n",
                    label);
      return 0;
    }
  }
  for (index = subject_result.audio_produced_samples;
       index < AUDIO_MAX_SAMPLES + 1U; ++index) {
    if (k_frame_subject_audio[index] != INT16_C(1234) ||
        k_frame_control_audio[index] != INT16_C(1234)) {
      (void)fprintf(stderr,
                    "nesturbator_session: %s changed audio tail canary\n",
                    label);
      return 0;
    }
  }
  if (video_stride == VIDEO_STRIDE_BYTES) {
    size_t row = 0U;
    for (row = 0U; row + 1U < VIDEO_HEIGHT; ++row) {
      for (index = 0U; index < VIDEO_ROW_PADDING_BYTES; ++index) {
        const size_t offset = row * video_stride + VIDEO_WIDTH * 3U + index;
        if (k_frame_subject_video[offset] != 0xA5U ||
            k_frame_control_video[offset] != 0xA5U) {
          (void)fprintf(stderr,
                        "nesturbator_session: %s changed row padding\n", label);
          return 0;
        }
      }
    }
  }
  if (video_capacity == subject_result.video_extent_bytes + 1U &&
      (k_frame_subject_video[subject_result.video_extent_bytes] != 0xA5U ||
       k_frame_control_video[subject_result.video_extent_bytes] != 0xA5U)) {
    (void)fprintf(stderr,
                  "nesturbator_session: %s changed video trailing canary\n",
                  label);
    return 0;
  }
  k_last_pair_result = subject_result;
  return 1;
}

static int exercise_jam_terminal_case(void) {
  allocation_tracker subject_tracker = {0};
  allocation_tracker control_tracker = {0};
  lf_instance *subject = NULL;
  lf_instance *control = NULL;
  uint8_t jam_fixture[FIXTURE_TOTAL_BYTES];
  uint8_t malformed[FIXTURE_TOTAL_BYTES];
  uint8_t replacement[FIXTURE_TOTAL_BYTES];
  size_t fixture_size = 0U;
  uint64_t last_valid_frames = 0U;
  uint64_t last_valid_ticks = 0U;
  size_t subject_calls_before = 0U;
  int exit_code = 1;

  fixture_size = build_fixture(k_fixture, sizeof(k_fixture));
  if (fixture_size != FIXTURE_TOTAL_BYTES ||
      !create_loaded_test_instance(&subject_tracker, &subject, k_fixture,
                                   fixture_size) ||
      !create_loaded_test_instance(&control_tracker, &control, k_fixture,
                                   fixture_size)) {
    (void)fprintf(stderr, "nesturbator_session: JAM pair setup failed\n");
    goto cleanup;
  }
  for (size_t frame = 0U; frame < 3U; ++frame) {
    const uint32_t buttons = frame == 1U ? 1U : 0U;
    if (lf_set_input(subject, &(lf_input){
                         .struct_size = sizeof(lf_input),
                         .buttons = buttons,
                     }) != LF_OK ||
        lf_set_input(control, &(lf_input){
                         .struct_size = sizeof(lf_input),
                         .buttons = buttons,
                     }) != LF_OK ||
        !advance_pair_without_setting_input(subject, control, buttons)) {
      (void)fprintf(stderr,
                    "nesturbator_session: JAM prior-history setup failed\n");
      goto cleanup;
    }
  }
  fixture_size = build_jam_fixture(jam_fixture, sizeof(jam_fixture));
  if (fixture_size != FIXTURE_TOTAL_BYTES) {
    (void)fprintf(stderr,
                  "nesturbator_session: could not build generated JAM fixture\n");
    goto cleanup;
  }
  {
    lf_load_request request = {
        .struct_size = sizeof(request),
        .content_data = jam_fixture,
        .content_size_bytes = fixture_size,
        .configuration_id = NULL,
    };
    lf_load_result subject_result = {.struct_size = sizeof(subject_result)};
    lf_load_result control_result = {.struct_size = sizeof(control_result)};
    if (lf_load(subject, &request, &subject_result) != LF_OK ||
        lf_load(control, &request, &control_result) != LF_OK ||
        !load_result_preserves_active(&subject_result, fixture_size) ||
        !load_result_preserves_active(&control_result, fixture_size) ||
        !advance_pair_without_setting_input(subject, control, 0U)) {
      (void)fprintf(stderr,
                    "nesturbator_session: generated JAM fixture did not complete a normal frame\n");
      goto cleanup;
    }
  }
  last_valid_frames = k_last_pair_result.cumulative_units;
  last_valid_ticks = k_last_pair_result.cumulative_core_ticks;
  if (last_valid_frames != 1U || k_last_pair_result.core_ticks_valid != 1U ||
      lf_set_input(subject, &(lf_input){
                       .struct_size = sizeof(lf_input),
                       .buttons = 2U,
                   }) != LF_OK) {
    (void)fprintf(stderr,
                  "nesturbator_session: JAM input setup did not follow a full frame\n");
    goto cleanup;
  }
  reset_frame_canaries();
  memcpy(k_frame_subject_video_before, k_frame_subject_video,
         sizeof(k_frame_subject_video));
  memcpy(k_frame_subject_audio_before, k_frame_subject_audio,
         sizeof(k_frame_subject_audio));
  {
    lf_run_request request = make_frame_request(
        1U, sizeof(k_frame_subject_video), VIDEO_STRIDE_BYTES,
        AUDIO_MAX_SAMPLES);
    lf_run_result result = {.struct_size = sizeof(result)};
    lf_status status = LF_INVALID_ARGUMENT;
    subject_calls_before = subject_tracker.calls;
    status = lf_advance(subject, &request, &result);
    if (status != LF_OK ||
        result.stop_reason != LF_STOP_CORE_HALTED ||
        result.actual_units != 0U || result.overshoot_units != 0U ||
        result.cumulative_units != last_valid_frames ||
        result.core_ticks_valid != 0U ||
        result.cumulative_core_ticks != last_valid_ticks ||
        result.video_valid != 0U || result.audio_valid != 0U ||
        result.video_extent_bytes != 0U ||
        result.audio_produced_samples != 0U ||
        subject_tracker.calls != subject_calls_before ||
        memcmp(k_frame_subject_video, k_frame_subject_video_before,
               sizeof(k_frame_subject_video)) != 0 ||
        memcmp(k_frame_subject_audio, k_frame_subject_audio_before,
               sizeof(k_frame_subject_audio)) != 0) {
      (void)fprintf(stderr,
                    "nesturbator_session: JAM outcome status=%d stop=%d actual=%u "
                    "overshoot=%u frames=%" PRIu64 " ticks=%" PRIu64 " valid=%u/%u/%u "
                    "extent=%zu samples=%zu expected_frames=%" PRIu64 " "
                    "expected_ticks=%" PRIu64 " calls=%zu/%zu\n",
                    (int)status, (int)result.stop_reason, result.actual_units,
                    result.overshoot_units, result.cumulative_units,
                    result.cumulative_core_ticks, result.core_ticks_valid,
                    result.video_valid, result.audio_valid,
                    result.video_extent_bytes, result.audio_produced_samples,
                    last_valid_frames, last_valid_ticks, subject_tracker.calls,
                    subject_calls_before);
      goto cleanup;
    }
  }
  {
    lf_run_request request = make_frame_request(0U, 0U, 0U, 0U);
    lf_run_result result = {.struct_size = sizeof(result)};
    request.video_data = NULL;
    request.audio_data = NULL;
    reset_frame_canaries();
    subject_calls_before = subject_tracker.calls;
    if (lf_advance(subject, &request, &result) != LF_OK ||
        result.stop_reason != LF_STOP_CORE_HALTED ||
        result.actual_units != 0U || result.overshoot_units != 0U ||
        result.cumulative_units != last_valid_frames ||
        result.core_ticks_valid != 0U ||
        result.cumulative_core_ticks != last_valid_ticks ||
        result.video_valid != 0U || result.audio_valid != 0U ||
        result.video_extent_bytes != 0U ||
        result.audio_produced_samples != 0U ||
        subject_tracker.calls != subject_calls_before ||
        !bytes_equal_value(k_frame_subject_video,
                           sizeof(k_frame_subject_video), 0xA5U)) {
      (void)fprintf(stderr,
                    "nesturbator_session: zero-work call hid terminal JAM state\n");
      goto cleanup;
    }
    for (size_t sample = 0U; sample < AUDIO_MAX_SAMPLES + 1U; ++sample) {
      if (k_frame_subject_audio[sample] != INT16_C(1234)) {
        (void)fprintf(stderr,
                      "nesturbator_session: halted zero-work call changed PCM storage\n");
        goto cleanup;
      }
    }
  }
  for (size_t repeat = 0U; repeat < 2U; ++repeat) {
    lf_run_request request = make_frame_request(
        1U, sizeof(k_frame_subject_video), VIDEO_STRIDE_BYTES,
        AUDIO_MAX_SAMPLES);
    lf_run_result result = {.struct_size = sizeof(result)};
    reset_frame_canaries();
    subject_calls_before = subject_tracker.calls;
    if (lf_advance(subject, &request, &result) != LF_OK ||
        result.stop_reason != LF_STOP_CORE_HALTED ||
        result.actual_units != 0U || result.overshoot_units != 0U ||
        result.cumulative_units != last_valid_frames ||
        result.core_ticks_valid != 0U ||
        result.cumulative_core_ticks != last_valid_ticks ||
        result.video_valid != 0U || result.audio_valid != 0U ||
        result.video_extent_bytes != 0U ||
        result.audio_produced_samples != 0U ||
        subject_tracker.calls != subject_calls_before ||
        !bytes_equal_value(k_frame_subject_video,
                           sizeof(k_frame_subject_video), 0xA5U)) {
      (void)fprintf(stderr,
                    "nesturbator_session: JAM terminal latch did not persist\n");
      goto cleanup;
    }
    for (size_t sample = 0U; sample < AUDIO_MAX_SAMPLES + 1U; ++sample) {
      if (k_frame_subject_audio[sample] != INT16_C(1234)) {
        (void)fprintf(stderr,
                      "nesturbator_session: halted call changed PCM storage\n");
        goto cleanup;
      }
    }
  }
  (void)build_fixture(malformed, sizeof(malformed));
  malformed[0] = (uint8_t)'X';
  {
    lf_load_request request = {
        .struct_size = sizeof(request),
        .content_data = malformed,
        .content_size_bytes = sizeof(malformed),
        .configuration_id = NULL,
    };
    lf_load_result result = {.struct_size = sizeof(result)};
    if (lf_load(subject, &request, &result) != LF_INVALID_ARGUMENT ||
        !load_result_preserves_active(&result, fixture_size)) {
      (void)fprintf(stderr,
                    "nesturbator_session: refused reload changed halted metadata\n");
      goto cleanup;
    }
  }
  {
    lf_run_request request = make_frame_request(
        1U, sizeof(k_frame_subject_video), VIDEO_STRIDE_BYTES,
        AUDIO_MAX_SAMPLES);
    lf_run_result result = {.struct_size = sizeof(result)};
    reset_frame_canaries();
    if (lf_advance(subject, &request, &result) != LF_OK ||
        result.stop_reason != LF_STOP_CORE_HALTED ||
        result.actual_units != 0U || result.cumulative_units != last_valid_frames ||
        result.core_ticks_valid != 0U ||
        result.cumulative_core_ticks != last_valid_ticks ||
        result.video_valid != 0U || result.audio_valid != 0U ||
        !bytes_equal_value(k_frame_subject_video,
                           sizeof(k_frame_subject_video), 0xA5U)) {
      (void)fprintf(stderr,
                    "nesturbator_session: refused reload cleared JAM latch\n");
      goto cleanup;
    }
  }
  fixture_size = build_fixture(replacement, sizeof(replacement));
  {
    lf_load_request request = {
        .struct_size = sizeof(request),
        .content_data = replacement,
        .content_size_bytes = fixture_size,
        .configuration_id = NULL,
    };
    lf_load_result result = {.struct_size = sizeof(result)};
    lf_run_request run_request = make_frame_request(
        1U, sizeof(k_frame_subject_video), VIDEO_STRIDE_BYTES,
        AUDIO_MAX_SAMPLES);
    lf_run_result run_result = {.struct_size = sizeof(run_result)};
    if (lf_set_input(subject, &(lf_input){
                         .struct_size = sizeof(lf_input),
                         .buttons = 1U,
                     }) != LF_OK ||
        lf_load(subject, &request, &result) != LF_OK ||
        !load_result_preserves_active(&result, fixture_size)) {
      (void)fprintf(stderr,
                    "nesturbator_session: successful load did not recover halted core\n");
      goto cleanup;
    }
    memset(replacement, 0xA5, sizeof(replacement));
    reset_frame_canaries();
    if (lf_advance(subject, &run_request, &run_result) != LF_OK ||
        run_result.stop_reason != LF_STOP_BUDGET_REACHED ||
        run_result.actual_units != 1U || run_result.cumulative_units != 1U ||
        run_result.sampled_buttons != 0U || run_result.core_ticks_valid != 1U ||
        run_result.video_valid != 1U || run_result.audio_valid != 1U ||
        run_result.audio_produced_samples < 798U ||
        run_result.audio_produced_samples > AUDIO_MAX_SAMPLES) {
      (void)fprintf(stderr,
                    "nesturbator_session: recovered core did not complete a new frame\n");
      goto cleanup;
    }
  }
  if (lf_destroy(&subject) != LF_OK || subject != NULL ||
      lf_destroy(&control) != LF_OK || control != NULL ||
      subject_tracker.invalid_frees != 0U || control_tracker.invalid_frees != 0U ||
      subject_tracker.live != 0U || control_tracker.live != 0U ||
      subject_tracker.allocations != subject_tracker.frees ||
      control_tracker.allocations != control_tracker.frees) {
    (void)fprintf(stderr, "nesturbator_session: JAM test cleanup failed\n");
    goto cleanup;
  }
  (void)printf("nesturbator_session: jam-terminal latch-and-reload result=pass\n");
  exit_code = 0;

cleanup:
  (void)lf_destroy(&subject);
  (void)lf_destroy(&control);
  return exit_code;
}

static int exercise_frame_failures(void) {
  allocation_tracker subject_tracker = {0};
  allocation_tracker control_tracker = {0};
  lf_instance *subject = NULL;
  lf_instance *control = NULL;
  uint8_t fixture[FIXTURE_TOTAL_BYTES];
  size_t fixture_size = 0U;
  int exit_code = 1;

  fixture_size = build_fixture(fixture, sizeof(fixture));
  if (fixture_size != FIXTURE_TOTAL_BYTES ||
      !create_test_instance(&subject_tracker, &subject) ||
      !create_test_instance(&control_tracker, &control)) {
    (void)fprintf(stderr, "nesturbator_session: frame-failure pair creation failed\n");
    goto cleanup;
  }
  {
    lf_run_request request = make_frame_request(
        1U, sizeof(k_frame_subject_video), VIDEO_STRIDE_BYTES,
        AUDIO_MAX_SAMPLES);
    lf_run_result result = {.struct_size = sizeof(result)};
    reset_frame_canaries();
    memcpy(k_frame_subject_video_before, k_frame_subject_video,
           sizeof(k_frame_subject_video));
    memcpy(k_frame_subject_audio_before, k_frame_subject_audio,
           sizeof(k_frame_subject_audio));
    if (lf_advance(subject, &request, &result) != LF_INVALID_ARGUMENT ||
        !frame_result_is_rejected(&result, 0U, 0U, 0U) ||
        memcmp(k_frame_subject_video, k_frame_subject_video_before,
               sizeof(k_frame_subject_video)) != 0 ||
        memcmp(k_frame_subject_audio, k_frame_subject_audio_before,
               sizeof(k_frame_subject_audio)) != 0) {
      (void)fprintf(stderr,
                    "nesturbator_session: advance before load was not rejected atomically\n");
      goto cleanup;
    }
  }
  {
    lf_load_request request = {
        .struct_size = sizeof(request),
        .content_data = fixture,
        .content_size_bytes = fixture_size,
        .configuration_id = NULL,
    };
    lf_load_result subject_result = {.struct_size = sizeof(subject_result)};
    lf_load_result control_result = {.struct_size = sizeof(control_result)};
    if (lf_load(subject, &request, &subject_result) != LF_OK ||
        lf_load(control, &request, &control_result) != LF_OK ||
        !load_result_preserves_active(&subject_result, fixture_size) ||
        !load_result_preserves_active(&control_result, fixture_size)) {
      (void)fprintf(stderr,
                    "nesturbator_session: frame-failure pair load failed\n");
      goto cleanup;
    }
  }
  k_last_pair_result = (lf_run_result){.struct_size = sizeof(lf_run_result)};
  for (size_t frame = 0U; frame < 3U; ++frame) {
    const uint32_t buttons = frame == 1U ? 1U : 0U;
    if (lf_set_input(subject, &(lf_input){
                         .struct_size = sizeof(lf_input),
                         .buttons = buttons,
                     }) != LF_OK ||
        lf_set_input(control, &(lf_input){
                         .struct_size = sizeof(lf_input),
                         .buttons = buttons,
                     }) != LF_OK ||
        !advance_pair_without_setting_input(subject, control, buttons)) {
      (void)fprintf(stderr,
                    "nesturbator_session: frame-failure history setup failed\n");
      goto cleanup;
    }
  }

  {
    lf_run_request request = make_frame_request(
        1U, VIDEO_EXTENT_BYTES, VIDEO_STRIDE_BYTES, AUDIO_MAX_SAMPLES);
    lf_run_request saved_request = request;
    request.struct_size -= 1U;
    if (!reject_frame_and_compare(subject, control, &subject_tracker,
                                  &control_tracker, request, LF_INVALID_ARGUMENT,
                                  UINT32_C(0x0100), "undersized request record")) {
      goto cleanup;
    }
    request = saved_request;
    request.struct_size = sizeof(request) + 1U;
    if (!reject_frame_and_compare(subject, control, &subject_tracker,
                                  &control_tracker, request, LF_INVALID_ARGUMENT,
                                  1U, "oversized request record")) {
      goto cleanup;
    }
    request = saved_request;
    reset_frame_canaries();
    memcpy(k_frame_subject_video_before, k_frame_subject_video,
           sizeof(k_frame_subject_video));
    memcpy(k_frame_subject_audio_before, k_frame_subject_audio,
           sizeof(k_frame_subject_audio));
    {
      lf_run_result short_result = {
          .struct_size = sizeof(lf_run_result) - 1U,
          .actual_units = UINT32_C(0x12345678),
          .cumulative_units = UINT64_MAX,
      };
      lf_run_result short_result_before = short_result;
      if (lf_set_input(subject, &(lf_input){
                           .struct_size = sizeof(lf_input),
                           .buttons = 2U,
                       }) != LF_OK ||
          lf_set_input(control, &(lf_input){
                           .struct_size = sizeof(lf_input),
                           .buttons = 2U,
                       }) != LF_OK ||
          lf_advance(subject, &request, &short_result) != LF_INVALID_ARGUMENT ||
          memcmp(&short_result, &short_result_before, sizeof(short_result)) != 0 ||
          memcmp(k_frame_subject_video, k_frame_subject_video_before,
                 sizeof(k_frame_subject_video)) != 0 ||
          memcmp(k_frame_subject_audio, k_frame_subject_audio_before,
                 sizeof(k_frame_subject_audio)) != 0 ||
          !advance_pair_without_setting_input(subject, control, 2U)) {
        (void)fprintf(stderr,
                      "nesturbator_session: short result record changed frame state\n");
        goto cleanup;
      }
    }
    reset_frame_canaries();
    memcpy(k_frame_subject_video_before, k_frame_subject_video,
           sizeof(k_frame_subject_video));
    memcpy(k_frame_subject_audio_before, k_frame_subject_audio,
           sizeof(k_frame_subject_audio));
    if (lf_set_input(subject, &(lf_input){
                         .struct_size = sizeof(lf_input),
                         .buttons = 1U,
                     }) != LF_OK ||
        lf_set_input(control, &(lf_input){
                         .struct_size = sizeof(lf_input),
                         .buttons = 1U,
                     }) != LF_OK ||
        lf_advance(subject, &request, NULL) != LF_INVALID_ARGUMENT ||
        memcmp(k_frame_subject_video, k_frame_subject_video_before,
               sizeof(k_frame_subject_video)) != 0 ||
        memcmp(k_frame_subject_audio, k_frame_subject_audio_before,
               sizeof(k_frame_subject_audio)) != 0 ||
        !advance_pair_without_setting_input(subject, control, 1U)) {
      (void)fprintf(stderr,
                    "nesturbator_session: null result record changed frame state\n");
      goto cleanup;
    }
  }

  for (size_t invalid_case = 0U; invalid_case < 2U; ++invalid_case) {
    const uint32_t pending = invalid_case == 0U ? 1U : UINT32_C(0x0100);
    const lf_input invalid_input = {
        .struct_size = sizeof(lf_input),
        .buttons = invalid_case == 0U ? pending : UINT32_C(0x00010000),
    };
    if (lf_set_input(subject, &(lf_input){
                         .struct_size = sizeof(lf_input),
                         .buttons = pending,
                     }) != LF_OK ||
        lf_set_input(control, &(lf_input){
                         .struct_size = sizeof(lf_input),
                         .buttons = pending,
                     }) != LF_OK) {
      goto cleanup;
    }
    {
      lf_input malformed_input = invalid_input;
      if (invalid_case == 0U) {
        malformed_input.struct_size -= 1U;
      }
      if (lf_set_input(subject, &malformed_input) != LF_INVALID_ARGUMENT ||
          !advance_pair_without_setting_input(subject, control, pending)) {
        (void)fprintf(stderr,
                      "nesturbator_session: invalid input changed pending state\n");
        goto cleanup;
      }
    }
  }

  {
    lf_run_request request = make_frame_request(
        0U, 0U, 0U, 0U);
    lf_run_result subject_result = {.struct_size = sizeof(subject_result)};
    lf_run_result control_result = {.struct_size = sizeof(control_result)};
    const uint64_t prior_frames = k_last_pair_result.cumulative_units;
    const uint64_t prior_ticks = k_last_pair_result.cumulative_core_ticks;
    const uint32_t prior_ticks_valid = k_last_pair_result.core_ticks_valid;
    const size_t subject_calls_before = subject_tracker.calls;
    const size_t control_calls_before = control_tracker.calls;
    request.video_data = NULL;
    request.audio_data = NULL;
    if (lf_set_input(subject, &(lf_input){
                         .struct_size = sizeof(lf_input),
                         .buttons = 2U,
                     }) != LF_OK ||
        lf_set_input(control, &(lf_input){
                         .struct_size = sizeof(lf_input),
                         .buttons = 2U,
                     }) != LF_OK ||
        lf_advance(subject, &request, &subject_result) != LF_OK ||
        lf_advance(control, &request, &control_result) != LF_OK ||
        subject_result.actual_units != 0U || control_result.actual_units != 0U ||
        subject_result.stop_reason != LF_STOP_BUDGET_REACHED ||
        control_result.stop_reason != LF_STOP_BUDGET_REACHED ||
        subject_result.video_valid != 0U || subject_result.audio_valid != 0U ||
        subject_result.video_extent_bytes != 0U ||
        subject_result.audio_produced_samples != 0U ||
        subject_result.cumulative_units != prior_frames ||
        control_result.cumulative_units != prior_frames ||
        subject_result.cumulative_core_ticks != prior_ticks ||
        control_result.cumulative_core_ticks != prior_ticks ||
        subject_result.core_ticks_valid != prior_ticks_valid ||
        control_result.core_ticks_valid != prior_ticks_valid ||
        subject_tracker.calls != subject_calls_before ||
        control_tracker.calls != control_calls_before ||
        !advance_pair_without_setting_input(subject, control, 2U)) {
      (void)fprintf(stderr,
                    "nesturbator_session: zero-work call was not a no-op\n");
      goto cleanup;
    }
  }

  {
    const size_t padded_extent =
        (VIDEO_HEIGHT - 1U) * VIDEO_STRIDE_BYTES + VIDEO_WIDTH * 3U;
    lf_run_request request = make_frame_request(
        2U, padded_extent, VIDEO_STRIDE_BYTES, AUDIO_MAX_SAMPLES);
    if (!reject_frame_and_compare(subject, control, &subject_tracker,
                                  &control_tracker, request, LF_LIMIT_EXCEEDED,
                                  UINT32_C(0x0100), "two requested frames") ||
        !reject_frame_and_compare(subject, control, &subject_tracker,
                                  &control_tracker,
                                  make_frame_request(1U, padded_extent,
                                                     VIDEO_WIDTH * 3U - 1U,
                                                     AUDIO_MAX_SAMPLES),
                                  LF_INVALID_ARGUMENT, 1U,
                                  "stride below minimum") ||
        !reject_frame_and_compare(subject, control, &subject_tracker,
                                  &control_tracker,
                                  make_frame_request(1U, padded_extent - 1U,
                                                     VIDEO_STRIDE_BYTES,
                                                     AUDIO_MAX_SAMPLES),
                                  LF_BUFFER_TOO_SMALL, 2U,
                                  "video one under exact extent") ||
        !reject_frame_and_compare(subject, control, &subject_tracker,
                                  &control_tracker,
                                  make_frame_request(1U, padded_extent,
                                                     VIDEO_STRIDE_BYTES, 0U),
                                  LF_BUFFER_TOO_SMALL, 1U,
                                  "audio capacity zero") ||
        !reject_frame_and_compare(subject, control, &subject_tracker,
                                  &control_tracker,
                                  make_frame_request(1U, padded_extent,
                                                     VIDEO_STRIDE_BYTES, 798U),
                                  LF_BUFFER_TOO_SMALL, 2U,
                                  "audio capacity 798") ||
        !reject_frame_and_compare(subject, control, &subject_tracker,
                                  &control_tracker,
                                  make_frame_request(1U, sizeof(k_frame_subject_video),
                                                     SIZE_MAX,
                                                     AUDIO_MAX_SAMPLES),
                                  LF_LIMIT_EXCEEDED, 1U,
                                  "SIZE_MAX stride multiplication") ||
        !reject_frame_and_compare(subject, control, &subject_tracker,
                                  &control_tracker,
                                  make_frame_request(
                                      1U, sizeof(k_frame_subject_video),
                                      SIZE_MAX / (VIDEO_HEIGHT - 1U),
                                      AUDIO_MAX_SAMPLES),
                                  LF_LIMIT_EXCEEDED, 2U,
                                  "SIZE_MAX stride addition")) {
      goto cleanup;
    }
  }

  {
    const size_t padded_extent =
        (VIDEO_HEIGHT - 1U) * VIDEO_STRIDE_BYTES + VIDEO_WIDTH * 3U;
    const size_t minimum_stride = VIDEO_WIDTH * 3U;
    const size_t minimum_extent =
        (VIDEO_HEIGHT - 1U) * minimum_stride + VIDEO_WIDTH * 3U;
    if (!advance_pair_with_capacities(subject, control, &subject_tracker,
                                      &control_tracker, padded_extent,
                                      VIDEO_STRIDE_BYTES, AUDIO_MAX_SAMPLES,
                                      1U, "padded exact video extent") ||
        !advance_pair_with_capacities(subject, control, &subject_tracker,
                                      &control_tracker, padded_extent + 1U,
                                      VIDEO_STRIDE_BYTES, AUDIO_MAX_SAMPLES,
                                      UINT32_C(0x0100),
                                      "padded video extent plus one") ||
        !advance_pair_with_capacities(subject, control, &subject_tracker,
                                      &control_tracker, minimum_extent,
                                      minimum_stride, AUDIO_MAX_SAMPLES, 2U,
                                      "minimum stride exact video extent") ||
        !advance_pair_with_capacities(subject, control, &subject_tracker,
                                      &control_tracker, minimum_extent,
                                      minimum_stride, 799U, 1U,
                                      "audio exact capacity 799") ||
        !advance_pair_with_capacities(subject, control, &subject_tracker,
                                      &control_tracker, minimum_extent,
                                      minimum_stride, 800U,
                                      UINT32_C(0x0100),
                                      "audio capacity 800 plus tail")) {
      goto cleanup;
    }
  }

  if (lf_destroy(&subject) != LF_OK || subject != NULL ||
      lf_destroy(&control) != LF_OK || control != NULL ||
      subject_tracker.invalid_frees != 0U || control_tracker.invalid_frees != 0U ||
      subject_tracker.live != 0U || control_tracker.live != 0U ||
      subject_tracker.allocations != subject_tracker.frees ||
      control_tracker.allocations != control_tracker.frees ||
      exercise_jam_terminal_case() != 0) {
    (void)fprintf(stderr,
                  "nesturbator_session: frame-failure cleanup/JAM checks failed\n");
    goto cleanup;
  }
  (void)printf("nesturbator_session: frame-failures capacities=checked jam=latched,reload-recovers result=pass\n");
  exit_code = 0;

cleanup:
  (void)lf_destroy(&subject);
  (void)lf_destroy(&control);
  return exit_code;
}

static int reject_load_and_compare(lf_instance *subject, lf_instance *control,
                                   allocation_tracker *subject_tracker,
                                   const lf_load_request *request,
                                   lf_status expected_status,
                                   const uint8_t *caller_bytes,
                                   size_t caller_size,
                                   uint32_t pending_buttons,
                                   const char *label) {
  lf_load_result result = {
      .struct_size = sizeof(result),
      .loaded = UINT32_MAX,
      .content_size_bytes = SIZE_MAX,
      .effective_configuration_id = "sentinel",
  };
  const size_t calls_before = subject_tracker->calls;
  const uint64_t content_before = caller_bytes == NULL
                                      ? 0U
                                      : hash_content(caller_bytes, caller_size);
  lf_status status = LF_INVALID_ARGUMENT;

  if (lf_set_input(subject, &(lf_input){
                       .struct_size = sizeof(lf_input),
                       .buttons = pending_buttons,
                   }) != LF_OK ||
      lf_set_input(control, &(lf_input){
                       .struct_size = sizeof(lf_input),
                       .buttons = pending_buttons,
                   }) != LF_OK) {
    (void)fprintf(stderr, "nesturbator_session: %s input setup failed\n", label);
    return 0;
  }
  status = lf_load(subject, request, &result);
  if (status != expected_status ||
      !load_result_preserves_active(&result, FIXTURE_TOTAL_BYTES) ||
      subject_tracker->calls != calls_before ||
      (caller_bytes != NULL &&
       content_before != hash_content(caller_bytes, caller_size))) {
    (void)fprintf(stderr,
                  "nesturbator_session: %s refusal status/result/storage failed\n",
                  label);
    return 0;
  }
  if (!advance_pair_without_setting_input(subject, control, pending_buttons)) {
    (void)fprintf(stderr,
                  "nesturbator_session: %s did not preserve same-history continuation\n",
                  label);
    return 0;
  }
  return 1;
}

static int exercise_load_failure_cases(void) {
  static const size_t max_content_bytes = (size_t)64U * 1024U * 1024U;
  allocation_tracker subject_tracker = {0};
  allocation_tracker control_tracker = {0};
  lf_instance *subject = NULL;
  lf_instance *control = NULL;
  uint8_t malformed[FIXTURE_TOTAL_BYTES];
  uint8_t unsupported_mapper[FIXTURE_TOTAL_BYTES];
  uint8_t *extent_storage = NULL;
  uint8_t replacement[FIXTURE_TOTAL_BYTES];
  size_t fixture_size = 0U;
  size_t observed_load_allocations = 0U;
  int exit_code = 1;

  fixture_size = build_fixture(k_fixture, sizeof(k_fixture));
  if (fixture_size != FIXTURE_TOTAL_BYTES ||
      !create_loaded_test_instance(&subject_tracker, &subject, k_fixture,
                                   fixture_size) ||
      !create_loaded_test_instance(&control_tracker, &control, k_fixture,
                                   fixture_size)) {
    (void)fprintf(stderr, "nesturbator_session: load-failure pair setup failed\n");
    goto cleanup;
  }
  for (size_t frame = 0U; frame < 3U; ++frame) {
    const uint32_t buttons = frame == 1U ? 1U : 0U;
    if (lf_set_input(subject, &(lf_input){
                         .struct_size = sizeof(lf_input),
                         .buttons = buttons,
                     }) != LF_OK ||
        lf_set_input(control, &(lf_input){
                         .struct_size = sizeof(lf_input),
                         .buttons = buttons,
                     }) != LF_OK ||
        !advance_pair_without_setting_input(subject, control, buttons)) {
      (void)fprintf(stderr,
                    "nesturbator_session: load-failure history setup failed\n");
      goto cleanup;
    }
  }

  {
    lf_load_request request = {
        .struct_size = sizeof(request),
        .content_data = k_fixture,
        .content_size_bytes = fixture_size,
        .configuration_id = NULL,
    };
    lf_load_result short_result = {
        .struct_size = sizeof(lf_load_result) - 1U,
        .loaded = UINT32_C(0x12345678),
        .content_size_bytes = SIZE_MAX - 1U,
        .effective_configuration_id = "unchanged",
    };
    lf_load_result short_result_before = short_result;
    const uint32_t pending_buttons = UINT32_C(0x0100);
    if (lf_set_input(subject, &(lf_input){
                         .struct_size = sizeof(lf_input),
                         .buttons = pending_buttons,
                     }) != LF_OK ||
        lf_set_input(control, &(lf_input){
                         .struct_size = sizeof(lf_input),
                         .buttons = pending_buttons,
                     }) != LF_OK ||
        lf_load(subject, &request, &short_result) != LF_INVALID_ARGUMENT ||
        memcmp(&short_result, &short_result_before, sizeof(short_result)) != 0 ||
        lf_load(subject, &request, NULL) != LF_INVALID_ARGUMENT ||
        !advance_pair_without_setting_input(subject, control, pending_buttons)) {
      (void)fprintf(stderr,
                    "nesturbator_session: malformed result record changed state\n");
      goto cleanup;
    }
    request.struct_size -= 1U;
    if (!reject_load_and_compare(subject, control, &subject_tracker, &request,
                                 LF_INVALID_ARGUMENT, k_fixture, fixture_size,
                                 1U, "short request record")) {
      goto cleanup;
    }
  }

  memset(malformed, 0, sizeof(malformed));
  fixture_size = build_fixture(malformed, sizeof(malformed));
  if (fixture_size != FIXTURE_TOTAL_BYTES) {
    goto cleanup;
  }
  malformed[0] = (uint8_t)'X';
  {
    lf_load_request request = {
        .struct_size = sizeof(request),
        .content_data = NULL,
        .content_size_bytes = fixture_size,
        .configuration_id = NULL,
    };
    if (!reject_load_and_compare(subject, control, &subject_tracker, NULL,
                                 LF_INVALID_ARGUMENT, NULL, 0U, 2U,
                                 "null request")) {
      goto cleanup;
    }
    if (!reject_load_and_compare(subject, control, &subject_tracker, &request,
                                 LF_INVALID_ARGUMENT, NULL, 0U, 1U,
                                 "null content pointer")) {
      goto cleanup;
    }
    request.content_data = malformed;
    request.content_size_bytes = 0U;
    if (!reject_load_and_compare(subject, control, &subject_tracker, &request,
                                 LF_INVALID_ARGUMENT, malformed,
                                 sizeof(malformed), 2U, "empty content")) {
      goto cleanup;
    }
    request.content_size_bytes = 1U;
    if (!reject_load_and_compare(subject, control, &subject_tracker, &request,
                                 LF_INVALID_ARGUMENT, malformed, 1U, 1U,
                                 "one-byte header")) {
      goto cleanup;
    }
    request.content_data = k_fixture;
    request.content_size_bytes = FIXTURE_HEADER_BYTES + FIXTURE_PRG_BYTES - 1U;
    if (!reject_load_and_compare(subject, control, &subject_tracker, &request,
                                 LF_INVALID_ARGUMENT, k_fixture,
                                 request.content_size_bytes, 2U,
                                 "truncated PRG")) {
      goto cleanup;
    }
    request.content_size_bytes = FIXTURE_TOTAL_BYTES - 1U;
    if (!reject_load_and_compare(subject, control, &subject_tracker, &request,
                                 LF_INVALID_ARGUMENT, k_fixture,
                                 request.content_size_bytes, 1U,
                                 "truncated CHR")) {
      goto cleanup;
    }
    request.content_data = malformed;
    request.content_size_bytes = sizeof(malformed);
    if (!reject_load_and_compare(subject, control, &subject_tracker, &request,
                                 LF_INVALID_ARGUMENT, malformed,
                                 sizeof(malformed), 2U,
                                 "malformed header")) {
      goto cleanup;
    }
  }

  fixture_size = build_fixture(unsupported_mapper, sizeof(unsupported_mapper));
  if (fixture_size != FIXTURE_TOTAL_BYTES) {
    goto cleanup;
  }
  unsupported_mapper[6] = 0x50U;
  {
    lf_load_request request = {
        .struct_size = sizeof(request),
        .content_data = unsupported_mapper,
        .content_size_bytes = sizeof(unsupported_mapper),
        .configuration_id = NULL,
    };
    if (!reject_load_and_compare(subject, control, &subject_tracker, &request,
                                 LF_INVALID_ARGUMENT, unsupported_mapper,
                                 sizeof(unsupported_mapper), 1U,
                                 "unsupported mapper")) {
      goto cleanup;
    }
    request.content_data = k_fixture;
    request.content_size_bytes = fixture_size;
    request.configuration_id = "nesturbator-unknown";
    if (!reject_load_and_compare(subject, control, &subject_tracker, &request,
                                 LF_UNSUPPORTED, k_fixture, fixture_size, 2U,
                                 "unsupported configuration")) {
      goto cleanup;
    }
    request.configuration_id = NULL;
  }

  extent_storage = malloc(max_content_bytes + 1U);
  if (extent_storage == NULL) {
    (void)fprintf(stderr, "nesturbator_session: content extent allocation failed\n");
    goto cleanup;
  }
  memset(extent_storage, 0xA5, max_content_bytes + 1U);
  (void)build_fixture(extent_storage, max_content_bytes + 1U);
  {
    lf_load_request request = {
        .struct_size = sizeof(request),
        .content_data = extent_storage,
        .content_size_bytes = max_content_bytes - 1U,
        .configuration_id = NULL,
    };
    if (!reject_load_and_compare(subject, control, &subject_tracker, &request,
                                 LF_INVALID_ARGUMENT, extent_storage,
                                 request.content_size_bytes, 1U,
                                 "64 MiB minus one passes admission")) {
      goto cleanup;
    }
    request.content_size_bytes = max_content_bytes;
    if (!reject_load_and_compare(subject, control, &subject_tracker, &request,
                                 LF_INVALID_ARGUMENT, extent_storage,
                                 request.content_size_bytes, 2U,
                                 "exact 64 MiB passes admission")) {
      goto cleanup;
    }
    request.content_size_bytes = max_content_bytes + 1U;
    if (!reject_load_and_compare(subject, control, &subject_tracker, &request,
                                 LF_LIMIT_EXCEEDED, extent_storage,
                                 request.content_size_bytes, 1U,
                                 "one over 64 MiB rejected before core")) {
      goto cleanup;
    }
  }

  {
    allocation_tracker baseline_tracker = {0};
    lf_instance *baseline = NULL;
    size_t calls_before_load = 0U;
    lf_load_request request = {
        .struct_size = sizeof(request),
        .content_data = k_fixture,
        .content_size_bytes = FIXTURE_TOTAL_BYTES,
        .configuration_id = NULL,
    };
    lf_load_result result = {.struct_size = sizeof(result)};
    if (!create_loaded_test_instance(&baseline_tracker, &baseline, k_fixture,
                                     FIXTURE_TOTAL_BYTES)) {
      (void)fprintf(stderr,
                    "nesturbator_session: valid load allocation baseline failed\n");
      (void)lf_destroy(&baseline);
      goto cleanup;
    }
    /* The public allocator hook sees every adapter and forwarded core allocation. */
    calls_before_load = baseline_tracker.calls;
    if (lf_load(baseline, &request, &result) != LF_OK ||
        !load_result_preserves_active(&result, FIXTURE_TOTAL_BYTES) ||
        baseline_tracker.calls <= calls_before_load ||
        lf_destroy(&baseline) != LF_OK || baseline != NULL ||
        baseline_tracker.invalid_frees != 0U || baseline_tracker.live != 0U ||
        baseline_tracker.allocations != baseline_tracker.frees) {
      (void)fprintf(stderr,
                    "nesturbator_session: valid load allocation baseline cleanup failed\n");
      goto cleanup;
    }
    observed_load_allocations = baseline_tracker.calls - calls_before_load;
    if (observed_load_allocations == 0U) {
      (void)fprintf(stderr,
                    "nesturbator_session: valid load used no caller allocation hooks\n");
      goto cleanup;
    }
  }

  for (size_t failure_position = 1U;
       failure_position <= observed_load_allocations; ++failure_position) {
    allocation_tracker failed_tracker = {0};
    allocation_tracker failed_control_tracker = {0};
    lf_instance *failed_subject = NULL;
    lf_instance *failed_control = NULL;
    lf_load_request request = {
        .struct_size = sizeof(request),
        .content_data = k_fixture,
        .content_size_bytes = FIXTURE_TOTAL_BYTES,
        .configuration_id = NULL,
    };
    lf_load_result result = {.struct_size = sizeof(result)};
    size_t live_before = 0U;
    size_t calls_before = 0U;

    if (!create_loaded_test_instance(&failed_tracker, &failed_subject,
                                     k_fixture, FIXTURE_TOTAL_BYTES) ||
        !create_loaded_test_instance(&failed_control_tracker, &failed_control,
                                     k_fixture, FIXTURE_TOTAL_BYTES)) {
      (void)fprintf(stderr,
                    "nesturbator_session: injected-allocation pair setup failed\n");
      (void)lf_destroy(&failed_subject);
      (void)lf_destroy(&failed_control);
      goto cleanup;
    }
    for (size_t frame = 0U; frame < 3U; ++frame) {
      const uint32_t buttons = frame == 1U ? 1U : 0U;
      if (lf_set_input(failed_subject, &(lf_input){
                           .struct_size = sizeof(lf_input),
                           .buttons = buttons,
                       }) != LF_OK ||
          lf_set_input(failed_control, &(lf_input){
                           .struct_size = sizeof(lf_input),
                           .buttons = buttons,
                       }) != LF_OK ||
          !advance_pair_without_setting_input(failed_subject, failed_control,
                                               buttons)) {
        (void)fprintf(stderr,
                      "nesturbator_session: injected-allocation history setup failed\n");
        (void)lf_destroy(&failed_subject);
        (void)lf_destroy(&failed_control);
        goto cleanup;
      }
    }
    live_before = failed_tracker.live;
    calls_before = failed_tracker.calls;
    failed_tracker.fail_on_call = calls_before + failure_position;
    if (lf_set_input(failed_subject, &(lf_input){
                         .struct_size = sizeof(lf_input),
                         .buttons = 1U,
                     }) != LF_OK ||
        lf_set_input(failed_control, &(lf_input){
                         .struct_size = sizeof(lf_input),
                         .buttons = 1U,
                     }) != LF_OK ||
        lf_load(failed_subject, &request, &result) != LF_RESOURCE_EXHAUSTED ||
        !load_result_preserves_active(&result, FIXTURE_TOTAL_BYTES) ||
        failed_tracker.live != live_before ||
        failed_tracker.calls != calls_before + failure_position ||
        !advance_pair_without_setting_input(failed_subject, failed_control, 1U) ||
        lf_destroy(&failed_subject) != LF_OK || failed_subject != NULL ||
        lf_destroy(&failed_control) != LF_OK || failed_control != NULL ||
        failed_tracker.invalid_frees != 0U ||
        failed_control_tracker.invalid_frees != 0U ||
        failed_tracker.live != 0U || failed_control_tracker.live != 0U ||
        failed_tracker.allocations != failed_tracker.frees ||
        failed_control_tracker.allocations != failed_control_tracker.frees) {
      (void)fprintf(stderr,
                    "nesturbator_session: forwarded load allocation failure was not atomic\n");
      (void)lf_destroy(&failed_subject);
      (void)lf_destroy(&failed_control);
      goto cleanup;
    }
  }

  fixture_size = build_fixture(replacement, sizeof(replacement));
  {
    lf_load_request request = {
        .struct_size = sizeof(request),
        .content_data = replacement,
        .content_size_bytes = fixture_size,
        .configuration_id = NULL,
    };
    lf_load_result result = {.struct_size = sizeof(result)};
    lf_run_request run_request = {
        .struct_size = sizeof(run_request),
        .work_units = 1U,
        .video_data = k_video,
        .video_capacity_bytes = sizeof(k_video),
        .video_stride_bytes = VIDEO_STRIDE_BYTES,
        .audio_data = k_audio,
        .audio_capacity_samples = AUDIO_MAX_SAMPLES,
    };
    lf_run_result run_result = {.struct_size = sizeof(run_result)};
    if (lf_set_input(subject, &(lf_input){
                         .struct_size = sizeof(lf_input),
                         .buttons = 1U,
                     }) != LF_OK ||
        lf_load(subject, &request, &result) != LF_OK ||
        !load_result_preserves_active(&result, fixture_size)) {
      (void)fprintf(stderr,
                    "nesturbator_session: successful replacement failed\n");
      goto cleanup;
    }
    memset(replacement, 0xA5, sizeof(replacement));
    memset(k_video, 0xA5, sizeof(k_video));
    for (size_t index = 0U; index < AUDIO_MAX_SAMPLES; ++index) {
      k_audio[index] = INT16_C(1234);
    }
    if (lf_advance(subject, &run_request, &run_result) != LF_OK ||
        run_result.actual_units != 1U || run_result.cumulative_units != 1U ||
        run_result.sampled_buttons != 0U || run_result.video_valid != 1U ||
        run_result.audio_valid != 1U ||
        !run_color_case(subject, 0U, k_released_rgb, &(uint64_t){1U},
                        &(uint64_t){run_result.cumulative_core_ticks},
                        &(size_t){run_result.audio_produced_samples})) {
      (void)fprintf(stderr,
                    "nesturbator_session: replacement lost input reset or owned content copy\n");
      goto cleanup;
    }
  }

  if (lf_destroy(&subject) != LF_OK || subject != NULL ||
      lf_destroy(&control) != LF_OK || control != NULL ||
      subject_tracker.invalid_frees != 0U || control_tracker.invalid_frees != 0U ||
      subject_tracker.live != 0U || control_tracker.live != 0U ||
      subject_tracker.allocations != subject_tracker.frees ||
      control_tracker.allocations != control_tracker.frees) {
    (void)fprintf(stderr,
                  "nesturbator_session: load-failure cleanup was not exact\n");
    goto cleanup;
  }
  (void)printf("nesturbator_session: load-failures refused-loads=%u allocations=%zu result=pass\n",
               13U, observed_load_allocations);
  exit_code = 0;

cleanup:
  (void)lf_destroy(&subject);
  (void)lf_destroy(&control);
  free(extent_storage);
  return exit_code;
}

static int write_all_fd(int fd, const void *bytes, size_t extent_bytes) {
  const uint8_t *cursor = (const uint8_t *)bytes;
  size_t written = 0U;
  while (written < extent_bytes) {
    const ssize_t amount = write(fd, cursor + written, extent_bytes - written);
    if (amount < 0 && errno == EINTR) {
      continue;
    }
    if (amount <= 0) {
      return 0;
    }
    written += (size_t)amount;
  }
  return 1;
}

static int read_all_fd(int fd, void *bytes, size_t extent_bytes) {
  uint8_t *cursor = (uint8_t *)bytes;
  size_t received = 0U;
  while (received < extent_bytes) {
    const ssize_t amount = read(fd, cursor + received, extent_bytes - received);
    if (amount < 0 && errno == EINTR) {
      continue;
    }
    if (amount <= 0) {
      return 0;
    }
    received += (size_t)amount;
  }
  return 1;
}

static void encode_u32_le(uint8_t output[4], uint32_t value) {
  size_t index = 0U;
  for (index = 0U; index < 4U; ++index) {
    output[index] = (uint8_t)(value >> (unsigned int)(index * 8U));
  }
}

static uint32_t decode_u32_le(const uint8_t input[4]) {
  uint32_t value = 0U;
  size_t index = 0U;
  for (index = 0U; index < 4U; ++index) {
    value |= (uint32_t)input[index] << (unsigned int)(index * 8U);
  }
  return value;
}

static void encode_u64_le(uint8_t output[8], uint64_t value) {
  size_t index = 0U;
  for (index = 0U; index < 8U; ++index) {
    output[index] = (uint8_t)(value >> (unsigned int)(index * 8U));
  }
}

static uint64_t decode_u64_le(const uint8_t input[8]) {
  uint64_t value = 0U;
  size_t index = 0U;
  for (index = 0U; index < 8U; ++index) {
    value |= (uint64_t)input[index] << (unsigned int)(index * 8U);
  }
  return value;
}

static int encode_save_envelope_header(
    const save_envelope_header *header,
    uint8_t encoded[SAVE_ENVELOPE_HEADER_BYTES]) {
  size_t offset = 0U;
  if (header == NULL || encoded == NULL) {
    return 0;
  }
  memcpy(encoded + offset, header->magic, sizeof(header->magic));
  offset += sizeof(header->magic);
  encode_u32_le(encoded + offset, header->version);
  offset += 4U;
  encode_u32_le(encoded + offset, header->header_bytes);
  offset += 4U;
  encode_u64_le(encoded + offset, header->extent_bytes);
  offset += 8U;
  encode_u64_le(encoded + offset, header->guest_generation);
  offset += 8U;
  memcpy(encoded + offset, header->content_identity,
         sizeof(header->content_identity));
  offset += sizeof(header->content_identity);
  memcpy(encoded + offset, header->configuration_identity,
         sizeof(header->configuration_identity));
  offset += sizeof(header->configuration_identity);
  memcpy(encoded + offset, header->media_identity,
         sizeof(header->media_identity));
  offset += sizeof(header->media_identity);
  return offset == (size_t)SAVE_ENVELOPE_HEADER_BYTES;
}

static int decode_save_envelope_header(
    const uint8_t encoded[SAVE_ENVELOPE_HEADER_BYTES],
    save_envelope_header *header) {
  size_t offset = 0U;
  if (encoded == NULL || header == NULL) {
    return 0;
  }
  memset(header, 0, sizeof(*header));
  memcpy(header->magic, encoded + offset, sizeof(header->magic));
  offset += sizeof(header->magic);
  header->version = decode_u32_le(encoded + offset);
  offset += 4U;
  header->header_bytes = decode_u32_le(encoded + offset);
  offset += 4U;
  header->extent_bytes = decode_u64_le(encoded + offset);
  offset += 8U;
  header->guest_generation = decode_u64_le(encoded + offset);
  offset += 8U;
  memcpy(header->content_identity, encoded + offset,
         sizeof(header->content_identity));
  offset += sizeof(header->content_identity);
  memcpy(header->configuration_identity, encoded + offset,
         sizeof(header->configuration_identity));
  offset += sizeof(header->configuration_identity);
  memcpy(header->media_identity, encoded + offset,
         sizeof(header->media_identity));
  offset += sizeof(header->media_identity);
  return offset == (size_t)SAVE_ENVELOPE_HEADER_BYTES;
}

static int read_save_file_bytes(const char *path, uint8_t *buffer,
                                size_t capacity_bytes, size_t *actual_bytes) {
  struct stat file_status;
  uint8_t trailing = 0U;
  size_t file_bytes = 0U;
  ssize_t trailing_count = 0;
  int fd = -1;
  int success = 0;
  if (path == NULL || buffer == NULL || actual_bytes == NULL) {
    return 0;
  }
  fd = open(path, O_RDONLY);
  if (fd < 0 || fstat(fd, &file_status) != 0 ||
      !S_ISREG(file_status.st_mode) || file_status.st_size < 0 ||
      (uintmax_t)file_status.st_size > (uintmax_t)capacity_bytes) {
    goto cleanup;
  }
  file_bytes = (size_t)file_status.st_size;
  if (!read_all_fd(fd, buffer, file_bytes)) {
    goto cleanup;
  }
  trailing_count = read(fd, &trailing, sizeof(trailing));
  if (trailing_count != 0) {
    goto cleanup;
  }
  if (close(fd) != 0) {
    fd = -1;
    goto cleanup;
  }
  fd = -1;
  *actual_bytes = file_bytes;
  success = 1;

cleanup:
  if (fd >= 0) {
    (void)close(fd);
  }
  return success;
}

static int save_bytes_match_literal(const uint8_t *bytes, size_t extent_bytes,
                                    uint8_t first_byte) {
  return lf_save_oracle_matches(bytes, extent_bytes, first_byte);
}

static int advance_save_guest_frame(lf_instance *instance) {
  lf_run_request request = {
      .struct_size = sizeof(request),
      .work_units = 1U,
      .video_data = k_video,
      .video_capacity_bytes = sizeof(k_video),
      .video_stride_bytes = VIDEO_STRIDE_BYTES,
      .audio_data = k_audio,
      .audio_capacity_samples = AUDIO_MAX_SAMPLES,
  };
  lf_run_result result = {.struct_size = sizeof(result)};
  memset(k_video, 0xA5, sizeof(k_video));
  memset(k_audio, 0, sizeof(k_audio));
  return lf_advance(instance, &request, &result) == LF_OK &&
         result.requested_units == 1U && result.actual_units == 1U &&
         result.cumulative_units > 0U && result.video_valid == 1U &&
         result.audio_valid == 1U && result.core_ticks_valid == 1U;
}

static int make_save_envelope_header(save_envelope_header *header,
                                     const lf_media_info *media_info) {
  int content_length = 0;
  int configuration_length = 0;
  int media_length = 0;
  if (header == NULL || media_info == NULL || media_info->identity == NULL ||
      media_info->extent_bytes == 0U) {
    return 0;
  }
  memset(header, 0, sizeof(*header));
  memcpy(header->magic, k_save_magic, sizeof(header->magic));
  header->version = 1U;
  header->header_bytes = (uint32_t)SAVE_ENVELOPE_HEADER_BYTES;
  header->extent_bytes = (uint64_t)media_info->extent_bytes;
  header->guest_generation = media_info->guest_generation;
  content_length = snprintf(header->content_identity,
                           sizeof(header->content_identity), "%s",
                           SAVE_CONTENT_IDENTITY);
  configuration_length = snprintf(
      header->configuration_identity, sizeof(header->configuration_identity),
      "%s", SAVE_CONFIGURATION_IDENTITY);
  media_length = snprintf(header->media_identity, sizeof(header->media_identity),
                          "%s", media_info->identity);
  return content_length >= 0 &&
         (size_t)content_length < sizeof(header->content_identity) &&
         configuration_length >= 0 &&
         (size_t)configuration_length <
             sizeof(header->configuration_identity) &&
         media_length >= 0 &&
         (size_t)media_length < sizeof(header->media_identity);
}

static save_stage_result stage_save_envelope(
    const char *destination, const save_envelope_header *header,
    const uint8_t *payload, int inject_partial_write_failure) {
  char temporary_path[4096];
  uint8_t encoded_header[SAVE_ENVELOPE_HEADER_BYTES];
  size_t injected_payload_bytes = 0U;
  int fd = -1;
  int close_result = 0;
  int temporary_created = 0;
  int path_length = 0;
  save_stage_result result = SAVE_STAGE_FAILED;
  if (destination == NULL || destination[0] == '\0' || header == NULL ||
      payload == NULL || inject_partial_write_failure < 0 ||
      inject_partial_write_failure > 1 || header->version != 1U ||
      header->header_bytes != (uint32_t)SAVE_ENVELOPE_HEADER_BYTES ||
      header->extent_bytes == 0U ||
      header->extent_bytes > (uint64_t)SAVE_FIXTURE_RAM_BYTES ||
      !encode_save_envelope_header(header, encoded_header)) {
    return SAVE_STAGE_FAILED;
  }
  path_length = snprintf(temporary_path, sizeof(temporary_path),
                        "%s.tmp.XXXXXX", destination);
  if (path_length < 0 || (size_t)path_length >= sizeof(temporary_path)) {
    return SAVE_STAGE_FAILED;
  }
  fd = mkstemp(temporary_path);
  if (fd < 0) {
    return SAVE_STAGE_FAILED;
  }
  temporary_created = 1;
  if (fchmod(fd, S_IRUSR | S_IWUSR) != 0) {
    goto cleanup;
  }
  if (inject_partial_write_failure != 0) {
    injected_payload_bytes = (size_t)header->extent_bytes / 2U;
    if (injected_payload_bytes == 0U ||
        !write_all_fd(fd, encoded_header, sizeof(encoded_header)) ||
        !write_all_fd(fd, payload, injected_payload_bytes)) {
      goto cleanup;
    }
    result = SAVE_STAGE_INJECTED_PREFIX_FAILURE;
    goto cleanup;
  }
  if (!write_all_fd(fd, encoded_header, sizeof(encoded_header)) ||
      !write_all_fd(fd, payload, (size_t)header->extent_bytes)) {
    goto cleanup;
  }
  close_result = close(fd);
  fd = -1;
  if (close_result == 0 && rename(temporary_path, destination) == 0) {
    result = SAVE_STAGE_COMMITTED;
  }

cleanup:
  if (fd >= 0) {
    (void)close(fd);
  }
  if (temporary_created != 0 && result != SAVE_STAGE_COMMITTED &&
      unlink(temporary_path) != 0 && errno != ENOENT) {
    result = SAVE_STAGE_FAILED;
  }
  return result;
}

static int acknowledge_committed_save(const char *path,
                                      const save_envelope_header *expected,
                                      const uint8_t *payload,
                                      save_acknowledgment *acknowledgment) {
  struct stat file_status;
  uint8_t buffer[1024];
  uint8_t actual_header[SAVE_ENVELOPE_HEADER_BYTES];
  uint8_t expected_header[SAVE_ENVELOPE_HEADER_BYTES];
  size_t expected_file_bytes = 0U;
  size_t remaining = 0U;
  int fd = -1;
  int success = 0;
  if (path == NULL || expected == NULL || payload == NULL ||
      acknowledgment == NULL || expected->version != 1U ||
      expected->header_bytes != (uint32_t)SAVE_ENVELOPE_HEADER_BYTES ||
      expected->extent_bytes == 0U ||
      expected->extent_bytes > (uint64_t)SAVE_FIXTURE_RAM_BYTES ||
      expected->extent_bytes > (uint64_t)(SIZE_MAX -
                                           (size_t)SAVE_ENVELOPE_HEADER_BYTES) ||
      !encode_save_envelope_header(expected, expected_header)) {
    return 0;
  }
  expected_file_bytes = (size_t)SAVE_ENVELOPE_HEADER_BYTES +
                        (size_t)expected->extent_bytes;
  fd = open(path, O_RDONLY);
  if (fd < 0 || fstat(fd, &file_status) != 0 ||
      !S_ISREG(file_status.st_mode) || file_status.st_size < 0 ||
      (uintmax_t)file_status.st_size != (uintmax_t)expected_file_bytes ||
      !read_all_fd(fd, actual_header, sizeof(actual_header)) ||
      memcmp(actual_header, expected_header, sizeof(actual_header)) != 0) {
    goto cleanup;
  }
  remaining = (size_t)expected->extent_bytes;
  while (remaining > 0U) {
    const size_t offset = (size_t)expected->extent_bytes - remaining;
    const size_t amount = remaining < sizeof(buffer) ? remaining : sizeof(buffer);
    if (!read_all_fd(fd, buffer, amount) ||
        memcmp(buffer, payload + offset, amount) != 0) {
      goto cleanup;
    }
    remaining -= amount;
  }
  {
    uint8_t trailing = 0U;
    const ssize_t amount = read(fd, &trailing, sizeof(trailing));
    if (amount != 0) {
      goto cleanup;
    }
  }
  if (fd >= 0 && close(fd) != 0) {
    fd = -1;
    goto cleanup;
  }
  fd = -1;
  acknowledgment->payload = payload;
  acknowledgment->extent_bytes = (size_t)expected->extent_bytes;
  acknowledgment->guest_generation = expected->guest_generation;
  acknowledgment->committed = 1;
  success = 1;

cleanup:
  if (fd >= 0) {
    (void)close(fd);
  }
  return success;
}

static int save_acknowledgments_match(
    const save_acknowledgment *left, const save_acknowledgment *right) {
  if (left == NULL || right == NULL || left->committed != right->committed ||
      left->extent_bytes != right->extent_bytes ||
      left->guest_generation != right->guest_generation) {
    return 0;
  }
  if (left->committed == 0) {
    return left->payload == NULL && right->payload == NULL &&
           left->extent_bytes == 0U && left->guest_generation == 0U;
  }
  return left->committed == 1 && left->payload != NULL &&
         right->payload != NULL && left->extent_bytes > 0U &&
         memcmp(left->payload, right->payload, left->extent_bytes) == 0;
}

static save_stage_result commit_save_envelope(
    const char *path, const save_envelope_header *header,
    const uint8_t *payload, int inject_partial_write_failure,
    save_acknowledgment *host_acknowledgment) {
  save_acknowledgment committed_acknowledgment = {0};
  save_stage_result stage_result = SAVE_STAGE_FAILED;
  if (host_acknowledgment == NULL) {
    return SAVE_STAGE_FAILED;
  }
  stage_result = stage_save_envelope(path, header, payload,
                                     inject_partial_write_failure);
  if (stage_result != SAVE_STAGE_COMMITTED) {
    return stage_result;
  }
  if (!acknowledge_committed_save(path, header, payload,
                                  &committed_acknowledgment)) {
    return SAVE_STAGE_FAILED;
  }
  *host_acknowledgment = committed_acknowledgment;
  return SAVE_STAGE_COMMITTED;
}

static int read_save_envelope(const char *path, save_envelope_header *header,
                              uint8_t **payload_out) {
  struct stat file_status;
  uint8_t encoded_header[SAVE_ENVELOPE_HEADER_BYTES];
  int fd = -1;
  uint8_t *payload = NULL;
  uint8_t trailing = 0U;
  size_t expected_file_bytes = 0U;
  ssize_t trailing_count = 0;
  if (path == NULL || header == NULL || payload_out == NULL) {
    return 0;
  }
  *payload_out = NULL;
  fd = open(path, O_RDONLY);
  if (fd < 0 || fstat(fd, &file_status) != 0 ||
      !S_ISREG(file_status.st_mode) || file_status.st_size < 0 ||
      (uintmax_t)file_status.st_size < (uintmax_t)sizeof(encoded_header) ||
      !read_all_fd(fd, encoded_header, sizeof(encoded_header)) ||
      !decode_save_envelope_header(encoded_header, header) ||
      memcmp(header->magic, k_save_magic, sizeof(k_save_magic)) != 0 ||
      header->version != 1U ||
      header->header_bytes != (uint32_t)SAVE_ENVELOPE_HEADER_BYTES ||
      header->extent_bytes == 0U ||
      header->extent_bytes > (uint64_t)SAVE_FIXTURE_RAM_BYTES ||
      header->extent_bytes >
          (uint64_t)(SIZE_MAX - (size_t)SAVE_ENVELOPE_HEADER_BYTES) ||
      memchr(header->content_identity, '\0',
             sizeof(header->content_identity)) == NULL ||
      memchr(header->configuration_identity, '\0',
             sizeof(header->configuration_identity)) == NULL ||
      memchr(header->media_identity, '\0', sizeof(header->media_identity)) ==
          NULL) {
    goto cleanup;
  }
  expected_file_bytes = (size_t)SAVE_ENVELOPE_HEADER_BYTES +
                        (size_t)header->extent_bytes;
  if ((uintmax_t)file_status.st_size != (uintmax_t)expected_file_bytes) {
    goto cleanup;
  }
  payload = (uint8_t *)malloc((size_t)header->extent_bytes);
  if (payload == NULL ||
      !read_all_fd(fd, payload, (size_t)header->extent_bytes)) {
    goto cleanup;
  }
  trailing_count = read(fd, &trailing, sizeof(trailing));
  if (trailing_count != 0) {
    goto cleanup;
  }
  if (fd >= 0 && close(fd) != 0) {
    fd = -1;
    goto cleanup;
  }
  fd = -1;
  *payload_out = payload;
  payload = NULL;
  return 1;

cleanup:
  free(payload);
  if (fd >= 0) {
    (void)close(fd);
  }
  return 0;
}

static int load_save_fixture(lf_instance **instance,
                             lf_load_result *load_result) {
  lf_load_request request = {.struct_size = sizeof(request)};
  const size_t fixture_bytes =
      lf_build_nesturbator_save_fixture(k_fixture, sizeof(k_fixture));
  uint8_t digest[32];
  char digest_hex[65];
  lf_status status = LF_OK;
  if (instance == NULL || load_result == NULL || fixture_bytes == 0U) {
    (void)fprintf(stderr,
                  "nesturbator_session: generated MMC1 fixture has invalid extent\n");
    return 0;
  }
  if (!lf_nesturbator_save_fixture_sha256(k_fixture, fixture_bytes, digest) ||
      !lf_save_oracle_sha256_matches(digest, sizeof(digest))) {
    if (lf_nesturbator_save_fixture_sha256(k_fixture, fixture_bytes, digest)) {
      save_fixture_digest_hex(digest, digest_hex);
      (void)fprintf(stderr,
                    "nesturbator_session: generated MMC1 fixture digest mismatch: %s\n",
                    digest_hex);
    } else {
      (void)fprintf(stderr,
                    "nesturbator_session: could not calculate generated fixture digest\n");
    }
    return 0;
  }
  if (*instance == NULL &&
      (lf_create("nesturbator-ntsc-v1", NULL, instance) != LF_OK ||
       *instance == NULL)) {
    (void)fprintf(stderr,
                  "nesturbator_session: could not create save fixture instance\n");
    return 0;
  }
  request.content_data = k_fixture;
  request.content_size_bytes = fixture_bytes;
  load_result->struct_size = sizeof(*load_result);
  status = lf_load(*instance, &request, load_result);
  if (status != LF_OK ||
      load_result->loaded != 1U ||
      load_result->content_size_bytes != fixture_bytes ||
      load_result->effective_configuration_id == NULL ||
      strcmp(load_result->effective_configuration_id,
             SAVE_CONFIGURATION_IDENTITY) != 0) {
    (void)fprintf(stderr,
                  "nesturbator_session: MMC1 load status=%d loaded=%u bytes=%zu config=%s\n",
                  (int)status, load_result->loaded,
                  load_result->content_size_bytes,
                  load_result->effective_configuration_id == NULL
                      ? "<null>"
                      : load_result->effective_configuration_id);
    (void)lf_destroy(instance);
    return 0;
  }
  memset(k_fixture, 0xA5, sizeof(k_fixture));
  return 1;
}

static int run_save_writer(const char *directory) {
  char save_path[4096] = {0};
  uint8_t media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t repeated[SAVE_FIXTURE_RAM_BYTES];
  uint8_t later[SAVE_FIXTURE_RAM_BYTES];
  uint8_t first_envelope[SAVE_ENVELOPE_MAX_BYTES];
  uint8_t repeated_envelope[SAVE_ENVELOPE_MAX_BYTES];
  uint8_t *snapshot = NULL;
  lf_media_info media_info = {.struct_size = sizeof(media_info)};
  lf_media_info repeated_info = {.struct_size = sizeof(repeated_info)};
  lf_media_info later_info = {.struct_size = sizeof(later_info)};
  lf_load_result load_result = {.struct_size = sizeof(load_result)};
  save_envelope_header header;
  save_acknowledgment first_acknowledgment = {0};
  save_acknowledgment repeated_acknowledgment = {0};
  lf_instance *instance = NULL;
  size_t frame = 0U;
  size_t first_envelope_bytes = 0U;
  size_t repeated_envelope_bytes = 0U;
  int result = 1;
  const char *failure = "path";
  const int path_length = snprintf(save_path, sizeof(save_path), "%s/save.bin",
                                  directory);
  if (path_length < 0 || (size_t)path_length >= sizeof(save_path)) {
    goto cleanup;
  }
  failure = "MMC1 fixture load";
  if (!load_save_fixture(&instance, &load_result)) {
    goto cleanup;
  }
  failure = "battery guest advance or span capture";
  for (frame = 0U; frame < (size_t)FIXTURE_MAX_WARMUP_FRAMES; ++frame) {
    memset(media, 0xA5, sizeof(media));
    if (!advance_save_guest_frame(instance) ||
        lf_copy_media(instance, media, sizeof(media), &media_info) != LF_OK ||
        media_info.extent_bytes != sizeof(media) ||
        media_info.identity == NULL ||
        strcmp(media_info.identity, SAVE_MEDIA_IDENTITY) != 0) {
      goto cleanup;
    }
    if (media[0] == (uint8_t)SAVE_FIXTURE_EXPECTED_BYTE) {
      break;
    }
  }
  if (frame == (size_t)FIXTURE_MAX_WARMUP_FRAMES ||
      media_info.guest_generation == 0U ||
      !save_bytes_match_literal(media, sizeof(media),
                                (uint8_t)SAVE_FIXTURE_EXPECTED_BYTE)) {
    (void)fprintf(stderr,
                  "nesturbator_session: save guest did not reach literal byte "
                  "%u (last=%u extent=%zu generation=%" PRIu64 ")\n",
                  (unsigned int)SAVE_FIXTURE_EXPECTED_BYTE,
                  (unsigned int)media[0], media_info.extent_bytes,
                  media_info.guest_generation);
    goto cleanup;
  }
  failure = "stable copy and generation after a later guest write";
  snapshot = (uint8_t *)malloc(sizeof(media));
  if (snapshot == NULL) {
    goto cleanup;
  }
  memcpy(snapshot, media, sizeof(media));
  memset(repeated, 0xA5, sizeof(repeated));
  if (lf_copy_media(instance, repeated, sizeof(repeated), &repeated_info) !=
          LF_OK ||
      repeated_info.extent_bytes != media_info.extent_bytes ||
      repeated_info.guest_generation != media_info.guest_generation ||
      repeated_info.identity == NULL || media_info.identity == NULL ||
      strcmp(repeated_info.identity, media_info.identity) != 0 ||
      memcmp(repeated, snapshot, sizeof(repeated)) != 0 ||
      !advance_save_guest_frame(instance) ||
      lf_copy_media(instance, later, sizeof(later), &later_info) != LF_OK ||
      later_info.guest_generation <= media_info.guest_generation ||
      !save_bytes_match_literal(later, sizeof(later),
                                (uint8_t)SAVE_FIXTURE_CONTINUATION_BYTE) ||
      !save_bytes_match_literal(snapshot, sizeof(media),
                                (uint8_t)SAVE_FIXTURE_EXPECTED_BYTE) ||
      !make_save_envelope_header(&header, &media_info)) {
    goto cleanup;
  }
  failure = "same-directory envelope stage/rename";
  if (commit_save_envelope(save_path, &header, snapshot, 0,
                           &first_acknowledgment) != SAVE_STAGE_COMMITTED ||
      first_acknowledgment.committed != 1 ||
      first_acknowledgment.payload != snapshot ||
      first_acknowledgment.extent_bytes != sizeof(media) ||
      first_acknowledgment.guest_generation != media_info.guest_generation ||
      !read_save_file_bytes(save_path, first_envelope,
                            sizeof(first_envelope), &first_envelope_bytes)) {
    goto cleanup;
  }
  failure = "byte-identical repeated commit and exact acknowledgment";
  if (commit_save_envelope(save_path, &header, snapshot, 0,
                           &repeated_acknowledgment) != SAVE_STAGE_COMMITTED ||
      repeated_acknowledgment.committed != 1 ||
      repeated_acknowledgment.payload != snapshot ||
      repeated_acknowledgment.extent_bytes != sizeof(media) ||
      repeated_acknowledgment.guest_generation != media_info.guest_generation ||
      first_acknowledgment.guest_generation !=
          repeated_acknowledgment.guest_generation ||
      !read_save_file_bytes(save_path, repeated_envelope,
                            sizeof(repeated_envelope),
                            &repeated_envelope_bytes) ||
      repeated_envelope_bytes != first_envelope_bytes ||
      memcmp(first_envelope, repeated_envelope, first_envelope_bytes) != 0) {
    goto cleanup;
  }
  result = 0;

cleanup:
  (void)lf_destroy(&instance);
  free(snapshot);
  if (result != 0) {
    (void)fprintf(stderr,
                  "nesturbator_session: save writer failed at %s\n", failure);
  } else {
    (void)printf("nesturbator_save_writer: guest-byte=3 generation=%" PRIu64
                 " committed-payload=exact idempotent-commit=byte-identical "
                 "result=pass\n",
                 media_info.guest_generation);
  }
  return result;
}

static int verify_live_media(lf_instance *instance, const uint8_t *expected,
                             size_t extent_bytes, uint64_t generation) {
  uint8_t actual[SAVE_FIXTURE_RAM_BYTES];
  lf_media_info info = {.struct_size = sizeof(info)};
  if (extent_bytes > sizeof(actual)) {
    return 0;
  }
  memset(actual, 0xA5, sizeof(actual));
  return lf_copy_media(instance, actual, sizeof(actual), &info) == LF_OK &&
         info.extent_bytes == extent_bytes &&
         info.guest_generation == generation && info.identity != NULL &&
         strcmp(info.identity, SAVE_MEDIA_IDENTITY) == 0 &&
         memcmp(actual, expected, extent_bytes) == 0;
}

static int only_committed_save_remains(const char *path) {
  char directory_path[4096] = {0};
  const char *separator = NULL;
  const char *basename = NULL;
  DIR *directory = NULL;
  struct dirent *entry = NULL;
  size_t directory_bytes = 0U;
  size_t matching_files = 0U;
  int success = 0;
  if (path == NULL || path[0] == '\0') {
    return 0;
  }
  separator = strrchr(path, '/');
  basename = separator == NULL ? path : separator + 1;
  if (separator == NULL) {
    memcpy(directory_path, ".", 2U);
  } else if (separator == path) {
    memcpy(directory_path, "/", 2U);
  } else {
    directory_bytes = (size_t)(separator - path);
    if (directory_bytes >= sizeof(directory_path)) {
      return 0;
    }
    memcpy(directory_path, path, directory_bytes);
    directory_path[directory_bytes] = '\0';
  }
  directory = opendir(directory_path);
  if (directory == NULL) {
    return 0;
  }
  errno = 0;
  while ((entry = readdir(directory)) != NULL) {
    if (strcmp(entry->d_name, ".") == 0 ||
        strcmp(entry->d_name, "..") == 0) {
      continue;
    }
    if (strcmp(entry->d_name, basename) != 0) {
      goto cleanup;
    }
    matching_files += 1U;
  }
  success = errno == 0 && matching_files == 1U;

cleanup:
  if (closedir(directory) != 0) {
    success = 0;
  }
  return success;
}

static int run_save_failed_writer(const char *path) {
  save_envelope_header previous_header;
  save_envelope_header attempted_header;
  save_envelope_header recovered_header;
  uint8_t initial[SAVE_FIXTURE_RAM_BYTES];
  uint8_t imported[SAVE_FIXTURE_RAM_BYTES];
  uint8_t advanced[SAVE_FIXTURE_RAM_BYTES];
  uint8_t *previous_payload = NULL;
  uint8_t *recovered_payload = NULL;
  lf_media_info initial_info = {.struct_size = sizeof(initial_info)};
  lf_media_info imported_info = {.struct_size = sizeof(imported_info)};
  lf_media_info advanced_info = {.struct_size = sizeof(advanced_info)};
  lf_load_result load_result = {.struct_size = sizeof(load_result)};
  save_acknowledgment previous_acknowledgment = {0};
  save_acknowledgment host_acknowledgment = {0};
  save_acknowledgment recovered_acknowledgment = {0};
  save_stage_result failed_stage_result = SAVE_STAGE_FAILED;
  lf_instance *instance = NULL;
  int result = 1;
  if (!read_save_envelope(path, &previous_header, &previous_payload) ||
      strcmp(previous_header.content_identity, SAVE_CONTENT_IDENTITY) != 0 ||
      strcmp(previous_header.configuration_identity,
             SAVE_CONFIGURATION_IDENTITY) != 0 ||
      strcmp(previous_header.media_identity, SAVE_MEDIA_IDENTITY) != 0 ||
      previous_header.guest_generation == 0U ||
      !save_bytes_match_literal(previous_payload,
                                (size_t)previous_header.extent_bytes,
                                (uint8_t)SAVE_FIXTURE_EXPECTED_BYTE) ||
      !acknowledge_committed_save(path, &previous_header, previous_payload,
                                  &previous_acknowledgment) ||
      previous_acknowledgment.committed != 1 ||
      previous_acknowledgment.payload != previous_payload ||
      previous_acknowledgment.guest_generation !=
          previous_header.guest_generation ||
      !load_save_fixture(&instance, &load_result) ||
      strcmp(load_result.effective_configuration_id,
             previous_header.configuration_identity) != 0 ||
      lf_copy_media(instance, initial, sizeof(initial), &initial_info) !=
          LF_OK ||
      initial_info.guest_generation != 0U ||
      initial_info.extent_bytes != (size_t)previous_header.extent_bytes ||
      !save_bytes_match_literal(initial, sizeof(initial), 0U) ||
      lf_import_media(instance, previous_header.media_identity,
                      previous_payload,
                      (size_t)previous_header.extent_bytes) != LF_OK ||
      lf_copy_media(instance, imported, sizeof(imported), &imported_info) !=
          LF_OK ||
      imported_info.guest_generation != initial_info.guest_generation ||
      memcmp(imported, previous_payload,
             (size_t)previous_header.extent_bytes) != 0 ||
      !advance_save_guest_frame(instance) ||
      lf_copy_media(instance, advanced, sizeof(advanced), &advanced_info) !=
          LF_OK ||
      advanced_info.guest_generation == 0U ||
      !save_bytes_match_literal(advanced, sizeof(advanced),
                                (uint8_t)SAVE_FIXTURE_CONTINUATION_BYTE) ||
      !make_save_envelope_header(&attempted_header, &advanced_info)) {
    goto cleanup;
  }
  host_acknowledgment = previous_acknowledgment;
  failed_stage_result = commit_save_envelope(
      path, &attempted_header, advanced, 1, &host_acknowledgment);
  if (failed_stage_result != SAVE_STAGE_INJECTED_PREFIX_FAILURE ||
      !save_acknowledgments_match(&host_acknowledgment,
                                  &previous_acknowledgment) ||
      !only_committed_save_remains(path) ||
      !read_save_envelope(path, &recovered_header, &recovered_payload) ||
      memcmp(&recovered_header, &previous_header,
             sizeof(previous_header)) != 0 ||
      memcmp(recovered_payload, previous_payload,
             (size_t)previous_header.extent_bytes) != 0 ||
      !acknowledge_committed_save(path, &recovered_header, recovered_payload,
                                  &recovered_acknowledgment) ||
      !save_acknowledgments_match(&recovered_acknowledgment,
                                  &host_acknowledgment) ||
      previous_acknowledgment.guest_generation !=
          previous_header.guest_generation) {
    goto cleanup;
  }
  result = 0;

cleanup:
  (void)lf_destroy(&instance);
  free(previous_payload);
  free(recovered_payload);
  if (result != 0) {
    (void)fprintf(stderr,
                  "nesturbator_session: injected save failure did not preserve the prior commit and acknowledgment\n");
  } else {
    (void)printf("nesturbator_save_failure_writer: prefix-write=failed-before-rename "
                 "host-ack=previous-exact previous-payload=exact previous-generation=%" PRIu64
                 " attempted-generation=%" PRIu64 " stage-cleanup=pass "
                 "result=pass\n",
                 previous_acknowledgment.guest_generation,
                 advanced_info.guest_generation);
  }
  return result;
}

static int run_save_restorer(const char *path) {
  save_envelope_header header;
  uint8_t *payload = NULL;
  uint8_t initial[SAVE_FIXTURE_RAM_BYTES];
  uint8_t after_import[SAVE_FIXTURE_RAM_BYTES];
  uint8_t continued[SAVE_FIXTURE_RAM_BYTES];
  uint8_t wrong_payload[SAVE_FIXTURE_RAM_BYTES];
  lf_media_info initial_info = {.struct_size = sizeof(initial_info)};
  lf_media_info imported_info = {.struct_size = sizeof(imported_info)};
  lf_media_info continued_info = {.struct_size = sizeof(continued_info)};
  lf_load_result load_result = {.struct_size = sizeof(load_result)};
  lf_instance *instance = NULL;
  int result = 1;
  if (!read_save_envelope(path, &header, &payload) ||
      strcmp(header.content_identity, SAVE_CONTENT_IDENTITY) != 0 ||
      strcmp(header.media_identity, SAVE_MEDIA_IDENTITY) != 0 ||
      lf_create("nesturbator-ntsc-v1", NULL, &instance) != LF_OK ||
      instance == NULL ||
      lf_import_media(instance, SAVE_MEDIA_IDENTITY, payload,
                      (size_t)header.extent_bytes) != LF_INVALID_ARGUMENT ||
      !load_save_fixture(&instance, &load_result)) {
    goto cleanup;
  }
  if (strcmp(header.configuration_identity,
             load_result.effective_configuration_id) != 0 ||
      header.extent_bytes != (uint64_t)SAVE_FIXTURE_RAM_BYTES ||
      header.guest_generation == 0U ||
      lf_copy_media(instance, initial, sizeof(initial), &initial_info) !=
          LF_OK ||
      initial_info.extent_bytes != (size_t)header.extent_bytes ||
      initial_info.guest_generation != 0U ||
      !save_bytes_match_literal(initial, sizeof(initial), 0U) ||
      lf_import_media(instance, "wrong-save-kind", payload,
                      (size_t)header.extent_bytes) != LF_UNSUPPORTED ||
      lf_import_media(instance, SAVE_MEDIA_IDENTITY, payload,
                      (size_t)header.extent_bytes - 1U) != LF_INVALID_ARGUMENT ||
      !verify_live_media(instance, initial, sizeof(initial),
                         initial_info.guest_generation)) {
    goto cleanup;
  }
  if (!save_bytes_match_literal(payload, (size_t)header.extent_bytes,
                                (uint8_t)SAVE_FIXTURE_EXPECTED_BYTE) ||
      lf_import_media(instance, SAVE_MEDIA_IDENTITY, payload,
                      (size_t)header.extent_bytes) != LF_OK ||
      lf_import_media(instance, SAVE_MEDIA_IDENTITY, payload,
                      (size_t)header.extent_bytes) != LF_OK ||
      lf_copy_media(instance, after_import, sizeof(after_import),
                    &imported_info) != LF_OK ||
      imported_info.guest_generation != initial_info.guest_generation ||
      imported_info.extent_bytes != initial_info.extent_bytes ||
      imported_info.identity == NULL || initial_info.identity == NULL ||
      strcmp(imported_info.identity, initial_info.identity) != 0 ||
      memcmp(after_import, payload, (size_t)header.extent_bytes) != 0 ||
      !advance_save_guest_frame(instance) ||
      lf_copy_media(instance, continued, sizeof(continued), &continued_info) !=
          LF_OK ||
      continued_info.guest_generation <= imported_info.guest_generation ||
      !save_bytes_match_literal(continued, sizeof(continued),
                                (uint8_t)SAVE_FIXTURE_CONTINUATION_BYTE)) {
    goto cleanup;
  }
  memcpy(wrong_payload, continued, sizeof(wrong_payload));
  wrong_payload[0] = 0x7FU;
  if (lf_import_media(instance, SAVE_MEDIA_IDENTITY, wrong_payload,
                      (size_t)header.extent_bytes) != LF_INVALID_ARGUMENT ||
      !verify_live_media(instance, continued, sizeof(continued),
                         continued_info.guest_generation)) {
    goto cleanup;
  }
  result = 0;

cleanup:
  (void)lf_destroy(&instance);
  free(payload);
  if (result != 0) {
    (void)fprintf(stderr,
                  "nesturbator_session: fresh save restorer failed validation or literal continuation\n");
  } else {
    (void)printf("nesturbator_save_restorer: imported-byte=3 continuation=4 "
                 "generation=%" PRIu64 " result=pass\n",
                 continued_info.guest_generation);
  }
  return result;
}

static int snapshot_run_results_match(const lf_run_result *left,
                                      const lf_run_result *right) {
  return left->struct_size == right->struct_size &&
         left->requested_units == right->requested_units &&
         left->actual_units == right->actual_units &&
         left->overshoot_units == right->overshoot_units &&
         left->sampled_buttons == right->sampled_buttons &&
         left->cumulative_units == right->cumulative_units &&
         left->time_unit == right->time_unit &&
         left->core_ticks_valid == right->core_ticks_valid &&
         left->cumulative_core_ticks == right->cumulative_core_ticks &&
         left->core_tick_time_unit == right->core_tick_time_unit &&
         left->stop_reason == right->stop_reason &&
         left->video_valid == right->video_valid &&
         left->audio_valid == right->audio_valid &&
         left->video_extent_bytes == right->video_extent_bytes &&
         left->audio_produced_samples == right->audio_produced_samples;
}

static int sha256_matches_hex(const uint8_t *data, size_t extent_bytes,
                              const char *expected_hex) {
  static const char hex_digits[] = "0123456789abcdef";
  uint8_t digest[32];
  size_t index = 0U;
  if (expected_hex == NULL || strlen(expected_hex) != 64U ||
      !lf_sha256_bytes(data, extent_bytes, digest)) {
    return 0;
  }
  for (index = 0U; index < sizeof(digest); ++index) {
    if (hex_digits[(size_t)(digest[index] >> 4U)] != expected_hex[index * 2U] ||
        hex_digits[(size_t)(digest[index] & 0x0FU)] !=
            expected_hex[index * 2U + 1U]) {
      return 0;
    }
  }
  return 1;
}

static int exercise_sha256_known_answers(void) {
  static const char long_message[] =
      "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
  if (!sha256_matches_hex(NULL, 0U,
                          "e3b0c44298fc1c149afbf4c8996fb924"
                          "27ae41e4649b934ca495991b7852b855") ||
      !sha256_matches_hex((const uint8_t *)"abc", 3U,
                          "ba7816bf8f01cfea414140de5dae2223"
                          "b00361a396177a9cb410ff61f20015ad") ||
      !sha256_matches_hex((const uint8_t *)long_message,
                          sizeof(long_message) - 1U,
                          "248d6a61d20638b8e5c026930c3e6039"
                          "a33ce45964ff2167f6ecedd419db06c1") ||
      lf_sha256_bytes(NULL, 1U, (uint8_t[32]){0U}) ||
      lf_sha256_bytes((const uint8_t *)"abc", 3U, NULL)) {
    return 0;
  }
  return 1;
}

static int snapshot_advance_one(lf_instance *instance,
                                uint32_t expected_buttons,
                                const uint8_t expected_rgb[3],
                                lf_run_result *out) {
  lf_run_request request = {
      .struct_size = sizeof(request),
      .work_units = 1U,
      .video_data = k_video,
      .video_capacity_bytes = sizeof(k_video),
      .video_stride_bytes = VIDEO_STRIDE_BYTES,
      .audio_data = k_audio,
      .audio_capacity_samples = AUDIO_MAX_SAMPLES,
  };
  size_t sample = 0U;
  if (instance == NULL || out == NULL) {
    return 0;
  }
  memset(k_video, 0xA5, sizeof(k_video));
  for (sample = 0U; sample < AUDIO_MAX_SAMPLES; ++sample) {
    k_audio[sample] = INT16_C(1234);
  }
  *out = (lf_run_result){.struct_size = sizeof(*out)};
  if (lf_advance(instance, &request, out) != LF_OK ||
      out->requested_units != 1U || out->actual_units != 1U ||
      out->overshoot_units != 0U ||
      out->sampled_buttons != expected_buttons ||
      out->stop_reason != LF_STOP_BUDGET_REACHED || out->video_valid != 1U ||
      out->audio_valid != 1U || out->time_unit != LF_TIME_FRAME ||
      out->core_ticks_valid != 1U ||
      out->core_tick_time_unit != LF_TIME_NES_HALF_MASTER_TICK ||
      !frame_is_literal_rgb(k_video, expected_rgb) ||
      !video_padding_is_untouched(k_video) ||
      (out->audio_produced_samples != 798U &&
       out->audio_produced_samples != 799U)) {
    return 0;
  }
  for (sample = 0U; sample < out->audio_produced_samples; ++sample) {
    if (k_audio[sample] != 0) {
      return 0;
    }
  }
  for (sample = out->audio_produced_samples; sample < AUDIO_MAX_SAMPLES;
       ++sample) {
    if (k_audio[sample] != INT16_C(1234)) {
      return 0;
    }
  }
  return 1;
}

static int snapshot_digest_hex(const uint8_t *bytes, size_t count,
                               char output[65]) {
  static const char digits[] = "0123456789abcdef";
  uint8_t digest[32];
  size_t index = 0U;
  if (output == NULL || !lf_sha256_bytes(bytes, count, digest)) {
    return 0;
  }
  for (index = 0U; index < sizeof(digest); ++index) {
    output[index * 2U] = digits[(size_t)(digest[index] >> 4U)];
    output[index * 2U + 1U] = digits[(size_t)(digest[index] & 0x0FU)];
  }
  output[64] = '\0';
  return 1;
}

static int load_snapshot_process_content(lf_instance *instance,
                                         const uint8_t *fixture,
                                         size_t fixture_bytes) {
  lf_load_request request = {
      .struct_size = sizeof(request),
      .content_data = fixture,
      .content_size_bytes = fixture_bytes,
      .configuration_id = "nesturbator-default",
  };
  lf_load_result result = {.struct_size = sizeof(result)};
  return lf_load(instance, &request, &result) == LF_OK &&
         load_result_preserves_active(&result, fixture_bytes);
}

static int run_snapshot_process_capture(const char *path) {
  allocation_tracker tracker = {0};
  lf_instance *instance = NULL;
  uint8_t *snapshot = NULL;
  FILE *file = NULL;
  size_t fixture_bytes = 0U;
  size_t snapshot_bytes = 0U;
  size_t audio_samples = 0U;
  uint64_t frames = 0U;
  uint64_t ticks = 0U;
  char digest[65];
  int result = 1;
  uint32_t supported = 0U;
  if (lf_get_capability("nesturbator-ntsc-v1", NULL, LF_CAP_SNAPSHOT,
                        &supported) != LF_OK ||
      supported != 1U) {
    goto cleanup;
  }
  if (path == NULL || path[0] == '\0' || !exercise_sha256_known_answers()) {
    goto cleanup;
  }
  fixture_bytes = build_fixture(k_fixture, sizeof(k_fixture));
  if (fixture_bytes != FIXTURE_TOTAL_BYTES ||
      !create_test_instance(&tracker, &instance) ||
      !load_snapshot_process_content(instance, k_fixture, fixture_bytes) ||
      /* Process A deliberately captures after a second successful load. The
         receiving process loads once, proving the epoch is instance-local. */
      !load_snapshot_process_content(instance, k_fixture, fixture_bytes) ||
      !run_color_case(instance, UINT32_C(0x00000100), k_port1_rgb, &frames,
                      &ticks, &audio_samples) ||
      lf_get_snapshot_size(instance, &snapshot_bytes) != LF_OK ||
      snapshot_bytes <= 388U) {
    goto cleanup;
  }
  snapshot = (uint8_t *)malloc(snapshot_bytes);
  if (snapshot == NULL ||
      lf_capture_snapshot(instance, snapshot, snapshot_bytes) != LF_OK ||
      !snapshot_digest_hex(snapshot, snapshot_bytes, digest)) {
    goto cleanup;
  }
  file = fopen(path, "wb");
  if (file == NULL ||
      fwrite(snapshot, 1U, snapshot_bytes, file) != snapshot_bytes) {
    goto cleanup;
  }
  if (fclose(file) != 0) {
    file = NULL;
    goto cleanup;
  }
  file = NULL;
  (void)printf("event=checkpoint-close bytes=%zu sha256=%s\n", snapshot_bytes,
               digest);
  if (fflush(stdout) != 0 || lf_destroy(&instance) != LF_OK) {
    goto cleanup;
  }
  (void)printf("event=instance-destroyed\n");
  if (fflush(stdout) != 0 || tracker.invalid_frees != 0U ||
      tracker.live != 0U || tracker.allocations != tracker.frees) {
    goto cleanup;
  }
  (void)printf("nesturbator_snapshot_process_a: loads=2 frames=%" PRIu64
               " ticks=%" PRIu64 " result=pass\n",
               frames, ticks);
  result = 0;

cleanup:
  if (file != NULL) {
    (void)fclose(file);
  }
  if (instance != NULL) {
    (void)lf_destroy(&instance);
  }
  free(snapshot);
  if (result != 0) {
    (void)fprintf(stderr,
                  "nesturbator_snapshot_process_a: capture lifecycle failed\n");
  }
  return result;
}

static int read_snapshot_process_file(const char *path, uint8_t **out_bytes,
                                      size_t *out_count) {
  FILE *file = NULL;
  long file_end = 0L;
  uint8_t *bytes = NULL;
  size_t count = 0U;
  int result = 0;
  if (path == NULL || out_bytes == NULL || out_count == NULL) {
    return 0;
  }
  *out_bytes = NULL;
  *out_count = 0U;
  file = fopen(path, "rb");
  if (file == NULL || fseek(file, 0L, SEEK_END) != 0 ||
      (file_end = ftell(file)) < 388L ||
      file_end > (long)(128U * 1024U * 1024U) ||
      fseek(file, 0L, SEEK_SET) != 0) {
    goto cleanup;
  }
  count = (size_t)file_end;
  bytes = (uint8_t *)malloc(count);
  if (bytes == NULL || fread(bytes, 1U, count, file) != count ||
      fgetc(file) != EOF || ferror(file)) {
    goto cleanup;
  }
  if (fclose(file) != 0) {
    file = NULL;
    goto cleanup;
  }
  file = NULL;
  *out_bytes = bytes;
  *out_count = count;
  bytes = NULL;
  result = 1;

cleanup:
  if (file != NULL) {
    (void)fclose(file);
  }
  free(bytes);
  return result;
}

static int exercise_snapshot_rejections(const uint8_t *fixture,
                                        size_t fixture_bytes);

static int run_snapshot_process_restore(const char *path, int wrong_oracle) {
  allocation_tracker tracker = {0};
  lf_instance *instance = NULL;
  uint8_t *snapshot = NULL;
  size_t snapshot_bytes = 0U;
  size_t fixture_bytes = 0U;
  char digest[65];
  lf_run_result continuation = {.struct_size = sizeof(continuation)};
  const uint8_t *expected_rgb =
      wrong_oracle ? k_wrong_expected_rgb : k_port1_rgb;
  int result = 1;
  uint32_t supported = 0U;
  if (lf_get_capability("nesturbator-ntsc-v1", NULL, LF_CAP_SNAPSHOT,
                        &supported) != LF_OK ||
      supported != 1U) {
    goto cleanup;
  }
  if (!exercise_sha256_known_answers() ||
      !read_snapshot_process_file(path, &snapshot, &snapshot_bytes) ||
      !snapshot_digest_hex(snapshot, snapshot_bytes, digest)) {
    goto cleanup;
  }
  (void)printf("event=checkpoint-reopened bytes=%zu sha256=%s\n",
               snapshot_bytes, digest);
  if (fflush(stdout) != 0) {
    goto cleanup;
  }
  fixture_bytes = build_fixture(k_fixture, sizeof(k_fixture));
  if (fixture_bytes != FIXTURE_TOTAL_BYTES ||
      !create_test_instance(&tracker, &instance) ||
      !load_snapshot_process_content(instance, k_fixture, fixture_bytes) ||
      lf_restore_snapshot(instance, snapshot, snapshot_bytes) != LF_OK) {
    goto cleanup;
  }
  if (!wrong_oracle) {
    (void)printf("event=snapshot-case name=valid_exact_extent status=ok "
                 "result=pass continuation=literal native_attempt_delta=1\n");
  }
  if (!snapshot_advance_one(instance, UINT32_C(0x00000100), expected_rgb,
                            &continuation)) {
    if (wrong_oracle) {
      (void)printf("event=wrong-oracle-rejected\n");
      result = 3;
    }
    goto cleanup;
  }
  if (wrong_oracle || continuation.cumulative_units != UINT64_C(3) ||
      continuation.cumulative_core_ticks != UINT64_C(2144304) ||
      continuation.audio_produced_samples != 799U) {
    goto cleanup;
  }
  if (!exercise_snapshot_rejections(k_fixture, fixture_bytes)) {
    goto cleanup;
  }
  if (lf_destroy(&instance) != LF_OK) {
    goto cleanup;
  }
  if (tracker.invalid_frees != 0U || tracker.live != 0U ||
      tracker.allocations != tracker.frees) {
    goto cleanup;
  }
  (void)printf("nesturbator_snapshot_process_b: frame=3 ticks=2144304 "
               "video=41e5a1 audio=799-silence result=pass\n");
  result = 0;

cleanup:
  if (instance != NULL) {
    (void)lf_destroy(&instance);
  }
  free(snapshot);
  if (result == 1) {
    (void)fprintf(stderr,
                  "nesturbator_snapshot_process_b: restore lifecycle failed\n");
  }
  return result == 3 ? 1 : result;
}

typedef enum battery_snapshot_oracle_failure {
  BATTERY_SNAPSHOT_ORACLE_NONE = 0,
  BATTERY_SNAPSHOT_ORACLE_SETUP = 1,
  BATTERY_SNAPSHOT_ORACLE_PROGRESS = 2,
  BATTERY_SNAPSHOT_ORACLE_VIDEO = 3,
  BATTERY_SNAPSHOT_ORACLE_AUDIO = 4,
  BATTERY_SNAPSHOT_ORACLE_MEDIA = 5
} battery_snapshot_oracle_failure;

typedef struct battery_snapshot_oracle {
  uint32_t buttons;
  uint64_t frames;
  uint64_t ticks;
  uint8_t rgb[3];
  size_t audio_samples;
  int16_t audio_sample;
  const uint8_t *media;
  size_t media_bytes;
} battery_snapshot_oracle;

static battery_snapshot_oracle_failure battery_snapshot_advance_expected(
    lf_instance *instance, const battery_snapshot_oracle *expected,
    lf_run_result *out, uint8_t *video, int16_t *audio) {
  lf_run_request request = {
      .struct_size = sizeof(request),
      .work_units = 1U,
      .video_data = video,
      .video_capacity_bytes = VIDEO_EXTENT_BYTES,
      .video_stride_bytes = VIDEO_STRIDE_BYTES,
      .audio_data = audio,
      .audio_capacity_samples = AUDIO_MAX_SAMPLES,
  };
  uint8_t actual_media[SAVE_FIXTURE_RAM_BYTES];
  lf_media_info media_info = {.struct_size = sizeof(media_info)};
  size_t sample = 0U;
  if (instance == NULL || expected == NULL || out == NULL || video == NULL ||
      audio == NULL || expected->media == NULL ||
      expected->media_bytes != sizeof(actual_media)) {
    return BATTERY_SNAPSHOT_ORACLE_SETUP;
  }
  memset(video, 0xA5, VIDEO_EXTENT_BYTES);
  for (sample = 0U; sample < AUDIO_MAX_SAMPLES; ++sample) {
    audio[sample] = INT16_C(1234);
  }
  *out = (lf_run_result){.struct_size = sizeof(*out)};
  if (lf_advance(instance, &request, out) != LF_OK ||
      out->struct_size != sizeof(*out) || out->requested_units != 1U ||
      out->actual_units != 1U || out->overshoot_units != 0U ||
      out->sampled_buttons != expected->buttons ||
      out->stop_reason != LF_STOP_BUDGET_REACHED || out->video_valid != 1U ||
      out->audio_valid != 1U || out->time_unit != LF_TIME_FRAME ||
      out->core_ticks_valid != 1U ||
      out->core_tick_time_unit != LF_TIME_NES_HALF_MASTER_TICK ||
      out->video_format != LF_VIDEO_RGB24 || out->video_width != VIDEO_WIDTH ||
      out->video_height != VIDEO_HEIGHT ||
      out->video_stride_bytes != VIDEO_STRIDE_BYTES ||
      out->video_extent_bytes != VIDEO_EXTENT_BYTES ||
      out->audio_encoding != LF_AUDIO_S16_NATIVE ||
      out->audio_layout != LF_AUDIO_INTERLEAVED ||
      out->audio_channels != 1U || out->audio_rate_numerator != 48000U ||
      out->audio_rate_denominator != 1U ||
      (out->audio_produced_samples != 798U &&
       out->audio_produced_samples != 799U) ||
      !video_padding_is_untouched(video)) {
    return BATTERY_SNAPSHOT_ORACLE_SETUP;
  }
  if (out->cumulative_units != expected->frames ||
      out->cumulative_core_ticks != expected->ticks) {
    return BATTERY_SNAPSHOT_ORACLE_PROGRESS;
  }
  if (!frame_is_literal_rgb(video, expected->rgb)) {
    return BATTERY_SNAPSHOT_ORACLE_VIDEO;
  }
  if (out->audio_produced_samples != expected->audio_samples) {
    return BATTERY_SNAPSHOT_ORACLE_AUDIO;
  }
  for (sample = 0U; sample < out->audio_produced_samples; ++sample) {
    if (audio[sample] != expected->audio_sample) {
      return BATTERY_SNAPSHOT_ORACLE_AUDIO;
    }
  }
  for (sample = out->audio_produced_samples; sample < AUDIO_MAX_SAMPLES;
       ++sample) {
    if (audio[sample] != INT16_C(1234)) {
      return BATTERY_SNAPSHOT_ORACLE_SETUP;
    }
  }
  if (lf_copy_media(instance, actual_media, sizeof(actual_media),
                    &media_info) != LF_OK ||
      media_info.struct_size != sizeof(media_info) ||
      media_info.extent_bytes != sizeof(actual_media) ||
      media_info.identity == NULL ||
      strcmp(media_info.identity, SAVE_MEDIA_IDENTITY) != 0) {
    return BATTERY_SNAPSHOT_ORACLE_SETUP;
  }
  if (memcmp(actual_media, expected->media, sizeof(actual_media)) != 0) {
    return BATTERY_SNAPSHOT_ORACLE_MEDIA;
  }
  return BATTERY_SNAPSHOT_ORACLE_NONE;
}

static int battery_snapshot_advance_literal(lf_instance *instance,
                                            lf_run_result *out) {
  battery_snapshot_oracle expected = {
      .buttons = 0U,
      .frames = (uint64_t)LF_BATTERY_SNAPSHOT_REPLAY_FRAMES,
      .ticks = (uint64_t)LF_BATTERY_SNAPSHOT_REPLAY_TICKS,
      .rgb = {(uint8_t)LF_BATTERY_SNAPSHOT_REPLAY_RGB_RED,
              (uint8_t)LF_BATTERY_SNAPSHOT_REPLAY_RGB_GREEN,
              (uint8_t)LF_BATTERY_SNAPSHOT_REPLAY_RGB_BLUE},
      .audio_samples =
          (size_t)LF_BATTERY_SNAPSHOT_REPLAY_AUDIO_SAMPLES,
      .audio_sample = (int16_t)LF_BATTERY_SNAPSHOT_REPLAY_AUDIO_SAMPLE,
      .media = NULL,
      .media_bytes = SAVE_FIXTURE_RAM_BYTES,
  };
  uint8_t expected_media[SAVE_FIXTURE_RAM_BYTES];
  memset(expected_media, (uint8_t)LF_SAVE_ORACLE_FILL_BYTE,
         sizeof(expected_media));
  expected_media[0] = (uint8_t)LF_BATTERY_SNAPSHOT_REPLAY_BYTE;
  expected.media = expected_media;
  return battery_snapshot_advance_expected(
             instance, &expected, out, k_video, k_audio) ==
         BATTERY_SNAPSHOT_ORACLE_NONE;
}

enum {
  SNAPSHOT_TEST_HEADER_BYTES = 388U,
  SNAPSHOT_TEST_VERSION_OFFSET = 8U,
  SNAPSHOT_TEST_HEADER_SIZE_OFFSET = 12U,
  SNAPSHOT_TEST_TOTAL_SIZE_OFFSET = 16U,
  SNAPSHOT_TEST_NATIVE_SIZE_OFFSET = 24U,
  SNAPSHOT_TEST_STATE_FORMAT_OFFSET = 32U,
  SNAPSHOT_TEST_CORE_ABI_OFFSET = 36U,
  SNAPSHOT_TEST_BEHAVIOR_REVISION_OFFSET = 40U,
  SNAPSHOT_TEST_BUILD_ID_OFFSET = 44U,
  SNAPSHOT_TEST_LIBFUTURO_BUILD_ID_OFFSET = 108U,
  SNAPSHOT_TEST_PROFILE_ID_OFFSET = 188U,
  SNAPSHOT_TEST_CONFIGURATION_ID_OFFSET = 220U,
  SNAPSHOT_TEST_OPTIONS_ID_OFFSET = 252U,
  SNAPSHOT_TEST_CONTENT_DIGEST_OFFSET = 284U,
  SNAPSHOT_TEST_INSTANCE_ID_OFFSET = 316U,
  SNAPSHOT_TEST_LOAD_EPOCH_OFFSET = 348U,
  SNAPSHOT_TEST_NATIVE_STATE_ROM_CRC_OFFSET = 24U,
  SNAPSHOT_TEST_NATIVE_STATE_HEADER_BYTES = 64U,
  SNAPSHOT_TEST_CONTENT_SIZE_OFFSET = 356U,
  SNAPSHOT_TEST_CUMULATIVE_FRAMES_OFFSET = 364U,
  SNAPSHOT_TEST_CUMULATIVE_TICKS_OFFSET = 372U,
  SNAPSHOT_TEST_PENDING_BUTTONS_OFFSET = 380U,
  SNAPSHOT_TEST_FLAGS_OFFSET = 384U,
};

typedef struct snapshot_rejection_case {
  const char *name;
  size_t offset;
  size_t width;
  uint64_t value;
  enum {
    SNAPSHOT_EXTENT_EXACT = 0,
    SNAPSHOT_EXTENT_EMPTY = 1,
    SNAPSHOT_EXTENT_HEADER_MINUS_ONE = 2,
    SNAPSHOT_EXTENT_SNAPSHOT_MINUS_ONE = 3,
    SNAPSHOT_EXTENT_ABOVE_MAXIMUM = 4,
    SNAPSHOT_EXTENT_SIZE_MAXIMUM = 5
  } extent_kind;
  int xor_byte;
  lf_status expected_status;
  int reaches_native;
} snapshot_rejection_case;

static const char *snapshot_status_name(lf_status status) {
  switch (status) {
  case LF_OK:
    return "ok";
  case LF_INVALID_ARGUMENT:
    return "invalid-argument";
  case LF_LIMIT_EXCEEDED:
    return "limit-exceeded";
  default:
    return "unexpected";
  }
}

static void snapshot_test_put_uint(uint8_t *destination, size_t width,
                                   uint64_t value) {
  size_t index = 0U;
  for (index = 0U; index < width; ++index) {
    destination[index] = (uint8_t)(value >> (unsigned int)(index * 8U));
  }
}

static uint64_t snapshot_test_get_uint(const uint8_t *source, size_t width) {
  uint64_t value = 0U;
  size_t index = 0U;
  for (index = 0U; index < width; ++index) {
    value |= (uint64_t)source[index] << (unsigned int)(index * 8U);
  }
  return value;
}

static int battery_snapshot_refusal_preserves(
    lf_instance *instance, const uint8_t *baseline, size_t snapshot_bytes,
    const uint8_t *candidate, size_t candidate_bytes, size_t candidate_calls,
    lf_status expected_status, int reaches_native, const char *case_name,
    uint64_t expected_generation, const char *save_path,
    const uint8_t *selected_file, size_t selected_file_bytes,
    save_acknowledgment *host_acknowledgment,
    const save_acknowledgment *expected_acknowledgment,
    const uint8_t *expected_acknowledgment_pointer) {
  uint8_t *before_snapshot = NULL;
  uint8_t *after_snapshot = NULL;
  uint8_t before_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t after_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t replay_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t before_file[SAVE_ENVELOPE_MAX_BYTES];
  uint8_t after_file[SAVE_ENVELOPE_MAX_BYTES];
  uint8_t *opened_payload = NULL;
  size_t before_file_bytes = 0U;
  size_t after_file_bytes = 0U;
  uint64_t attempts_before = 0U;
  uint64_t attempts_after = 0U;
  lf_media_info before_info = {.struct_size = sizeof(before_info)};
  lf_media_info after_info = {.struct_size = sizeof(after_info)};
  lf_media_info replay_info = {.struct_size = sizeof(replay_info)};
  lf_media_info reset_info = {.struct_size = sizeof(reset_info)};
  lf_run_result replay_result = {.struct_size = sizeof(replay_result)};
  save_envelope_header opened_header;
  uint8_t opened_encoded_header[SAVE_ENVELOPE_HEADER_BYTES];
  save_acknowledgment acknowledgment_before = {0};
  lf_status status = LF_OK;
  size_t candidate_call = 0U;
  int result = 0;

  if (instance == NULL || baseline == NULL ||
      (candidate == NULL && candidate_bytes != 0U) || snapshot_bytes == 0U ||
      candidate_calls == 0U || case_name == NULL ||
      save_path == NULL || selected_file == NULL ||
      selected_file_bytes == 0U || host_acknowledgment == NULL ||
      expected_acknowledgment == NULL ||
      expected_acknowledgment_pointer == NULL ||
      expected_generation > UINT64_MAX - 2U) {
    goto cleanup;
  }

  /* This restore is setup. Record the public pre-call vector only afterwards. */
  if (lf_restore_snapshot(instance, baseline, snapshot_bytes) != LF_OK) {
    goto cleanup;
  }
  before_snapshot = (uint8_t *)malloc(snapshot_bytes);
  after_snapshot = (uint8_t *)malloc(snapshot_bytes);
  if (before_snapshot == NULL || after_snapshot == NULL ||
      lf_capture_snapshot(instance, before_snapshot, snapshot_bytes) != LF_OK ||
      memcmp(before_snapshot, baseline, snapshot_bytes) != 0 ||
      lf_copy_media(instance, before_media, sizeof(before_media),
                    &before_info) != LF_OK ||
      before_info.struct_size != sizeof(before_info) ||
      before_info.extent_bytes != sizeof(before_media) ||
      before_info.guest_generation != expected_generation ||
      before_info.identity == NULL ||
      strcmp(before_info.identity, SAVE_MEDIA_IDENTITY) != 0 ||
      !save_bytes_match_literal(
          before_media, sizeof(before_media),
          (uint8_t)LF_BATTERY_SNAPSHOT_CAPTURE_BYTE) ||
      !read_save_file_bytes(save_path, before_file, sizeof(before_file),
                            &before_file_bytes) ||
      before_file_bytes != selected_file_bytes ||
      memcmp(before_file, selected_file, selected_file_bytes) != 0 ||
      !only_committed_save_remains(save_path)) {
    goto cleanup;
  }
  acknowledgment_before = *host_acknowledgment;
  if (acknowledgment_before.payload != expected_acknowledgment_pointer ||
      !save_acknowledgments_match(&acknowledgment_before,
                                  expected_acknowledgment)) {
    goto cleanup;
  }
  if (lf_test_get_nesturbator_restore_attempts(instance, &attempts_before) !=
      LF_OK) {
    goto cleanup;
  }

  for (candidate_call = 0U; candidate_call < candidate_calls;
       ++candidate_call) {
    status = lf_restore_snapshot(instance, candidate, candidate_bytes);
    if (status != expected_status) {
      (void)fprintf(stderr,
                    "battery snapshot refusal %s call=%zu: status=%d "
                    "expected=%d\n",
                    case_name, candidate_call + 1U, (int)status,
                    (int)expected_status);
      goto cleanup;
    }
    if (lf_capture_snapshot(instance, after_snapshot, snapshot_bytes) !=
            LF_OK ||
        memcmp(before_snapshot, after_snapshot, snapshot_bytes) != 0 ||
        lf_copy_media(instance, after_media, sizeof(after_media),
                      &after_info) != LF_OK ||
        after_info.struct_size != before_info.struct_size ||
        after_info.extent_bytes != before_info.extent_bytes ||
        after_info.guest_generation != before_info.guest_generation ||
        after_info.identity == NULL ||
        strcmp(after_info.identity, before_info.identity) != 0 ||
        memcmp(after_media, before_media, sizeof(before_media)) != 0 ||
        !save_bytes_match_literal(
            after_media, sizeof(after_media),
            (uint8_t)LF_BATTERY_SNAPSHOT_CAPTURE_BYTE) ||
        host_acknowledgment->payload != expected_acknowledgment_pointer ||
        !save_acknowledgments_match(host_acknowledgment,
                                    expected_acknowledgment) ||
        !read_save_file_bytes(save_path, after_file, sizeof(after_file),
                              &after_file_bytes) ||
        after_file_bytes != selected_file_bytes ||
        memcmp(after_file, selected_file, selected_file_bytes) != 0 ||
        !read_save_envelope(save_path, &opened_header, &opened_payload) ||
        opened_payload == NULL ||
        !encode_save_envelope_header(&opened_header,
                                     opened_encoded_header) ||
        memcmp(opened_encoded_header, selected_file,
               SAVE_ENVELOPE_HEADER_BYTES) != 0 ||
        opened_header.extent_bytes != expected_acknowledgment->extent_bytes ||
        memcmp(opened_payload, expected_acknowledgment->payload,
               expected_acknowledgment->extent_bytes) != 0 ||
        !only_committed_save_remains(save_path)) {
      (void)fprintf(stderr,
                    "battery snapshot refusal %s call=%zu changed "
                    "continuation, media, selected save, or acknowledgment\n",
                    case_name, candidate_call + 1U);
      goto cleanup;
    }
    free(opened_payload);
    opened_payload = NULL;
    if (lf_test_get_nesturbator_restore_attempts(instance, &attempts_after) !=
            LF_OK ||
        attempts_after != attempts_before +
                             (reaches_native
                                  ? (uint64_t)candidate_call + 1U
                                  : 0U)) {
      (void)fprintf(stderr,
                    "battery snapshot refusal %s call=%zu: native-attempts="
                    "%" PRIu64 "->%" PRIu64 "\n",
                    case_name, candidate_call + 1U, attempts_before,
                    attempts_after);
      goto cleanup;
    }
  }

  if (!battery_snapshot_advance_literal(instance, &replay_result) ||
      lf_copy_media(instance, replay_media, sizeof(replay_media),
                    &replay_info) != LF_OK ||
      replay_info.struct_size != sizeof(replay_info) ||
      replay_info.extent_bytes != sizeof(replay_media) ||
      replay_info.guest_generation != expected_generation + 1U ||
      replay_info.identity == NULL ||
      strcmp(replay_info.identity, SAVE_MEDIA_IDENTITY) != 0 ||
      !save_bytes_match_literal(
          replay_media, sizeof(replay_media),
          (uint8_t)LF_BATTERY_SNAPSHOT_REPLAY_BYTE) ||
      host_acknowledgment->payload != expected_acknowledgment_pointer ||
      !save_acknowledgments_match(host_acknowledgment,
                                  expected_acknowledgment)) {
    (void)fprintf(stderr,
                  "battery snapshot refusal %s changed literal continuation\n",
                  case_name);
    goto cleanup;
  }

  /* Return to the declared capture endpoint for the next refusal case. */
  if (lf_restore_snapshot(instance, baseline, snapshot_bytes) != LF_OK ||
      lf_copy_media(instance, after_media, sizeof(after_media), &reset_info) !=
          LF_OK ||
      reset_info.extent_bytes != sizeof(after_media) ||
      reset_info.guest_generation != expected_generation + 2U ||
      reset_info.identity == NULL ||
      strcmp(reset_info.identity, SAVE_MEDIA_IDENTITY) != 0 ||
      !save_bytes_match_literal(
          after_media, sizeof(after_media),
          (uint8_t)LF_BATTERY_SNAPSHOT_CAPTURE_BYTE) ||
      host_acknowledgment->payload != expected_acknowledgment_pointer ||
      !save_acknowledgments_match(host_acknowledgment,
                                  expected_acknowledgment)) {
    goto cleanup;
  }
  result = 1;

cleanup:
  free(opened_payload);
  free(after_snapshot);
  free(before_snapshot);
  return result;
}

typedef struct battery_snapshot_refusal_case {
  const char *name;
  size_t offset;
  size_t width;
  uint64_t value;
  enum {
    BATTERY_SNAPSHOT_EXTENT_EXACT = 0,
    BATTERY_SNAPSHOT_EXTENT_EMPTY = 1,
    BATTERY_SNAPSHOT_EXTENT_HEADER_MINUS_ONE = 2,
    BATTERY_SNAPSHOT_EXTENT_NATIVE_MINUS_ONE = 3,
    BATTERY_SNAPSHOT_EXTENT_TRAILING_BYTE = 4
  } extent_kind;
  int xor_byte;
  lf_status expected_status;
  int reaches_native;
  size_t repetitions;
  int null_candidate;
} battery_snapshot_refusal_case;

static int battery_snapshot_refuses_unqualified_route(
    lf_instance *instance, const uint8_t *qualified_snapshot,
    size_t snapshot_bytes, uint8_t *probe) {
  size_t required_bytes = SIZE_MAX;
  if (instance == NULL || qualified_snapshot == NULL || probe == NULL ||
      snapshot_bytes == 0U ||
      lf_get_snapshot_size(instance, &required_bytes) != LF_UNSUPPORTED ||
      required_bytes != SIZE_MAX) {
    return 0;
  }
  memset(probe, 0xA5, snapshot_bytes);
  return lf_capture_snapshot(instance, probe, snapshot_bytes) ==
             LF_UNSUPPORTED &&
         bytes_equal_value(probe, snapshot_bytes, 0xA5U) &&
         lf_restore_snapshot(instance, qualified_snapshot, snapshot_bytes) ==
             LF_UNSUPPORTED;
}

static int exercise_battery_snapshot_refusal_cases(
    lf_instance *instance, const uint8_t *baseline, size_t snapshot_bytes,
    const char *save_path, const uint8_t *selected_file,
    size_t selected_file_bytes, save_acknowledgment *host_acknowledgment,
    const save_acknowledgment *expected_acknowledgment,
    const uint8_t *expected_acknowledgment_pointer,
    lf_media_info *endpoint_info, uint8_t endpoint_media[SAVE_FIXTURE_RAM_BYTES],
    int emit_process_events) {
  static const battery_snapshot_refusal_case cases[] = {
      {"zero_extent", 0U, 0U, 0U, BATTERY_SNAPSHOT_EXTENT_EMPTY, 0,
       LF_INVALID_ARGUMENT, 0, 1U, 0},
      {"null_zero_extent", 0U, 0U, 0U, BATTERY_SNAPSHOT_EXTENT_EMPTY, 0,
       LF_INVALID_ARGUMENT, 0, 1U, 1},
      {"truncated_header", 0U, 0U, 0U,
       BATTERY_SNAPSHOT_EXTENT_HEADER_MINUS_ONE, 0, LF_INVALID_ARGUMENT, 0,
       1U, 0},
      {"truncated_native_payload", 0U, 0U, 0U,
       BATTERY_SNAPSHOT_EXTENT_NATIVE_MINUS_ONE, 0, LF_INVALID_ARGUMENT, 0,
       1U, 0},
      {"trailing_byte", 0U, 0U, 0U,
       BATTERY_SNAPSHOT_EXTENT_TRAILING_BYTE, 0, LF_INVALID_ARGUMENT, 0, 1U,
       0},
      {"malformed_magic", 0U, 0U, 0U, BATTERY_SNAPSHOT_EXTENT_EXACT, 1,
       LF_INVALID_ARGUMENT, 0, 1U, 0},
      {"malformed_version", SNAPSHOT_TEST_VERSION_OFFSET, 4U, UINT32_MAX,
       BATTERY_SNAPSHOT_EXTENT_EXACT, 0, LF_INVALID_ARGUMENT, 0, 1U, 0},
      {"malformed_header", SNAPSHOT_TEST_HEADER_SIZE_OFFSET, 4U,
       SNAPSHOT_TEST_HEADER_BYTES - 1U, BATTERY_SNAPSHOT_EXTENT_EXACT, 0,
       LF_INVALID_ARGUMENT, 0, 1U, 0},
      {"malformed_total_length", SNAPSHOT_TEST_TOTAL_SIZE_OFFSET, 8U,
       1U, BATTERY_SNAPSHOT_EXTENT_EXACT, 0, LF_INVALID_ARGUMENT, 0,
       1U, 0},
      {"malformed_native_length", SNAPSHOT_TEST_NATIVE_SIZE_OFFSET, 8U,
       1U, BATTERY_SNAPSHOT_EXTENT_EXACT, 0, LF_INVALID_ARGUMENT, 0,
       1U, 0},
      {"malformed_content_extent", SNAPSHOT_TEST_CONTENT_SIZE_OFFSET, 8U,
       1U, BATTERY_SNAPSHOT_EXTENT_EXACT, 0, LF_INVALID_ARGUMENT, 0, 1U, 0},
      {"wrong_core_build", SNAPSHOT_TEST_BUILD_ID_OFFSET, 0U, 0U,
       BATTERY_SNAPSHOT_EXTENT_EXACT, 1, LF_INVALID_ARGUMENT, 0, 1U, 0},
      {"wrong_libfuturo_build", SNAPSHOT_TEST_LIBFUTURO_BUILD_ID_OFFSET, 0U,
       0U, BATTERY_SNAPSHOT_EXTENT_EXACT, 1, LF_INVALID_ARGUMENT, 0, 1U, 0},
      {"wrong_native_format", SNAPSHOT_TEST_STATE_FORMAT_OFFSET, 4U, 99U,
       BATTERY_SNAPSHOT_EXTENT_EXACT, 0, LF_INVALID_ARGUMENT, 0, 1U, 0},
      {"wrong_core_abi", SNAPSHOT_TEST_CORE_ABI_OFFSET, 4U, 99U,
       BATTERY_SNAPSHOT_EXTENT_EXACT, 0, LF_INVALID_ARGUMENT, 0, 1U, 0},
      {"wrong_behavior_revision", SNAPSHOT_TEST_BEHAVIOR_REVISION_OFFSET, 4U,
       99U, BATTERY_SNAPSHOT_EXTENT_EXACT, 0, LF_INVALID_ARGUMENT, 0, 1U, 0},
      {"wrong_profile", SNAPSHOT_TEST_PROFILE_ID_OFFSET, 0U, 0U,
       BATTERY_SNAPSHOT_EXTENT_EXACT, 1, LF_INVALID_ARGUMENT, 0, 1U, 0},
      {"wrong_configuration", SNAPSHOT_TEST_CONFIGURATION_ID_OFFSET, 0U, 0U,
       BATTERY_SNAPSHOT_EXTENT_EXACT, 1, LF_INVALID_ARGUMENT, 0, 1U, 0},
      {"wrong_options", SNAPSHOT_TEST_OPTIONS_ID_OFFSET, 0U, 0U,
       BATTERY_SNAPSHOT_EXTENT_EXACT, 1, LF_INVALID_ARGUMENT, 0, 1U, 0},
      {"wrong_content_digest", SNAPSHOT_TEST_CONTENT_DIGEST_OFFSET, 0U, 0U,
       BATTERY_SNAPSHOT_EXTENT_EXACT, 1, LF_INVALID_ARGUMENT, 0, 1U, 0},
      {"native_corruption", SIZE_MAX, 0U, 0U,
       BATTERY_SNAPSHOT_EXTENT_EXACT, 1, LF_INVALID_ARGUMENT, 1, 1U, 0},
      {"repeated_invalid_candidate", 0U, 0U, 0U,
       BATTERY_SNAPSHOT_EXTENT_EXACT, 1, LF_INVALID_ARGUMENT, 0, 2U, 0},
  };
  uint8_t positive_fixture[LF_NESTURBATOR_SAVE_FIXTURE_TOTAL_BYTES];
  uint8_t alternate_fixture[LF_NESTURBATOR_SAVE_FIXTURE_TOTAL_BYTES];
  uint8_t positive_digest[32];
  uint8_t alternate_digest[32];
  uint8_t foreign_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t foreign_control_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t *candidate = NULL;
  uint8_t *foreign_snapshot = NULL;
  uint64_t expected_generation = 0U;
  size_t positive_fixture_bytes = 0U;
  size_t alternate_fixture_bytes = 0U;
  size_t fixture_offset = 0U;
  size_t changed_fixture_bytes = 0U;
  allocation_tracker foreign_control_tracker = {0};
  lf_instance *foreign = NULL;
  lf_instance *foreign_control = NULL;
  lf_load_request foreign_load_request = {
      .struct_size = sizeof(foreign_load_request)};
  lf_load_result foreign_load_result = {
      .struct_size = sizeof(foreign_load_result)};
  lf_load_result foreign_control_load_result = {
      .struct_size = sizeof(foreign_control_load_result)};
  lf_media_info foreign_info = {.struct_size = sizeof(foreign_info)};
  lf_media_info foreign_control_info = {
      .struct_size = sizeof(foreign_control_info)};
  size_t case_index = 0U;
  int result = 0;

  if (instance == NULL || baseline == NULL || snapshot_bytes <=
          SNAPSHOT_TEST_HEADER_BYTES || save_path == NULL ||
      selected_file == NULL || host_acknowledgment == NULL ||
      expected_acknowledgment == NULL ||
      expected_acknowledgment_pointer == NULL || endpoint_info == NULL ||
      endpoint_media == NULL || endpoint_info->guest_generation >
          UINT64_MAX - 2U * (sizeof(cases) / sizeof(cases[0]) + 2U)) {
    return 0;
  }
  candidate = (uint8_t *)malloc(snapshot_bytes + 1U);
  if (candidate == NULL) {
    goto cleanup;
  }
  expected_generation = endpoint_info->guest_generation;
  for (case_index = 0U; case_index < sizeof(cases) / sizeof(cases[0]);
       ++case_index) {
    const battery_snapshot_refusal_case *test_case = &cases[case_index];
    size_t repetition = 0U;
    size_t candidate_bytes = snapshot_bytes;
    memcpy(candidate, baseline, snapshot_bytes);
    if (test_case->offset == SIZE_MAX) {
      candidate[snapshot_bytes - 1U] ^= 1U;
    } else if (test_case->width != 0U) {
      snapshot_test_put_uint(candidate + test_case->offset,
                             test_case->width, test_case->value);
    } else if (test_case->xor_byte != 0) {
      candidate[test_case->offset] ^= 1U;
    }
    switch (test_case->extent_kind) {
    case BATTERY_SNAPSHOT_EXTENT_EXACT:
      candidate_bytes = snapshot_bytes;
      break;
    case BATTERY_SNAPSHOT_EXTENT_EMPTY:
      candidate_bytes = 0U;
      break;
    case BATTERY_SNAPSHOT_EXTENT_HEADER_MINUS_ONE:
      candidate_bytes = SNAPSHOT_TEST_HEADER_BYTES - 1U;
      break;
    case BATTERY_SNAPSHOT_EXTENT_NATIVE_MINUS_ONE:
      candidate_bytes = snapshot_bytes - 1U;
      break;
    case BATTERY_SNAPSHOT_EXTENT_TRAILING_BYTE:
      candidate[snapshot_bytes] = 0xA5U;
      candidate_bytes = snapshot_bytes + 1U;
      break;
    default:
      goto cleanup;
    }
    if (test_case->null_candidate != 0) {
      candidate_bytes = 0U;
    }
    if (!battery_snapshot_refusal_preserves(
            instance, baseline, snapshot_bytes,
            test_case->null_candidate != 0 ? NULL : candidate,
            candidate_bytes, test_case->repetitions,
            test_case->expected_status, test_case->reaches_native,
            test_case->name, expected_generation, save_path, selected_file,
            selected_file_bytes, host_acknowledgment,
            expected_acknowledgment, expected_acknowledgment_pointer)) {
      (void)fprintf(stderr,
                    "battery snapshot refusal vector failed: %s\n",
                    test_case->name);
      goto cleanup;
    }
    if (emit_process_events != 0) {
      for (repetition = 0U; repetition < test_case->repetitions;
           ++repetition) {
        (void)printf("event=battery-b-refusal name=%s status=%s "
                     "preservation=continuation,full-media,generation,"
                     "selected-save,ack result=pass\n",
                     test_case->name,
                     snapshot_status_name(test_case->expected_status));
      }
    }
    expected_generation += 2U;
  }
  positive_fixture_bytes = lf_build_nesturbator_save_fixture(
      positive_fixture, sizeof(positive_fixture));
  alternate_fixture_bytes = lf_build_nesturbator_alternate_save_fixture(
      alternate_fixture, sizeof(alternate_fixture));
  if (positive_fixture_bytes != alternate_fixture_bytes ||
      positive_fixture_bytes != LF_NESTURBATOR_SAVE_FIXTURE_TOTAL_BYTES ||
      !lf_nesturbator_save_fixture_sha256(positive_fixture,
                                          positive_fixture_bytes,
                                          positive_digest) ||
      !lf_nesturbator_save_fixture_sha256(alternate_fixture,
                                          alternate_fixture_bytes,
                                          alternate_digest) ||
      !lf_save_oracle_sha256_matches(positive_digest,
                                     sizeof(positive_digest)) ||
      memcmp(positive_digest, alternate_digest,
             sizeof(positive_digest)) == 0) {
    goto cleanup;
  }
  for (fixture_offset = 0U; fixture_offset < positive_fixture_bytes;
       ++fixture_offset) {
    const uint8_t positive_byte = positive_fixture[fixture_offset];
    const uint8_t alternate_byte = alternate_fixture[fixture_offset];
    if (fixture_offset ==
        (size_t)LF_NESTURBATOR_SAVE_FIXTURE_HEADER_BYTES +
            (size_t)LF_NESTURBATOR_SAVE_FIXTURE_ADC_OPERAND_OFFSET) {
      if (positive_byte != 0x01U || alternate_byte != 0x02U) {
        goto cleanup;
      }
      ++changed_fixture_bytes;
    } else if (positive_byte != alternate_byte) {
      goto cleanup;
    }
  }
  if (changed_fixture_bytes != 1U ||
      lf_create("nesturbator-ntsc-v1", NULL, &foreign) != LF_OK ||
      foreign == NULL) {
    goto cleanup;
  }
  foreign_snapshot = (uint8_t *)malloc(snapshot_bytes);
  if (foreign_snapshot == NULL) {
    goto cleanup;
  }
  foreign_load_request.content_data = alternate_fixture;
  foreign_load_request.content_size_bytes = alternate_fixture_bytes;
  if (lf_load(foreign, &foreign_load_request, &foreign_load_result) != LF_OK ||
      !load_result_preserves_active(&foreign_load_result,
                                    positive_fixture_bytes) ||
      !create_loaded_test_instance(&foreign_control_tracker, &foreign_control,
                                   alternate_fixture,
                                   alternate_fixture_bytes) ||
      !advance_pair_without_setting_input(foreign, foreign_control, 0U) ||
      !advance_pair_without_setting_input(foreign, foreign_control, 0U) ||
      lf_copy_media(foreign, foreign_media, sizeof(foreign_media),
                    &foreign_info) != LF_OK ||
      foreign_info.extent_bytes != sizeof(foreign_media) ||
      foreign_info.identity == NULL ||
      strcmp(foreign_info.identity, SAVE_MEDIA_IDENTITY) != 0 ||
      !save_bytes_match_literal(
          foreign_media, sizeof(foreign_media),
          (uint8_t)LF_SAVE_ORACLE_CONTINUATION_BYTE) ||
      !battery_snapshot_refuses_unqualified_route(
          foreign, baseline, snapshot_bytes, foreign_snapshot)) {
    (void)fprintf(stderr,
                  "battery snapshot refusal: changed MMC1 route was accepted\n");
    goto cleanup;
  }
  if (!advance_pair_without_setting_input(foreign, foreign_control, 0U) ||
      lf_copy_media(foreign, foreign_media, sizeof(foreign_media),
                    &foreign_info) != LF_OK ||
      lf_copy_media(foreign_control, foreign_control_media,
                    sizeof(foreign_control_media), &foreign_control_info) !=
          LF_OK ||
      foreign_info.extent_bytes != sizeof(foreign_media) ||
      foreign_control_info.extent_bytes != sizeof(foreign_control_media) ||
      memcmp(foreign_media, foreign_control_media,
             sizeof(foreign_media)) != 0 ||
      !save_bytes_match_literal(
          foreign_media, sizeof(foreign_media),
          (uint8_t)(LF_SAVE_ORACLE_CONTINUATION_BYTE + 2U))) {
    (void)fprintf(stderr,
                  "battery snapshot refusal: changed MMC1 state changed\n");
    goto cleanup;
  }

  /* MMC3 also exposes battery RAM, but this phase qualifies only the exact
     generated MMC1 route. Its snapshot entry points must fail closed. */
  alternate_fixture[6] = 0x42U;
  foreign_load_request.content_data = alternate_fixture;
  foreign_load_request.content_size_bytes = alternate_fixture_bytes;
  foreign_load_result = (lf_load_result){
      .struct_size = sizeof(foreign_load_result)};
  if (lf_load(foreign, &foreign_load_request, &foreign_load_result) != LF_OK ||
      !load_result_preserves_active(&foreign_load_result,
                                    alternate_fixture_bytes) ||
      lf_load(foreign_control, &foreign_load_request,
              &foreign_control_load_result) !=
          LF_OK ||
      !load_result_preserves_active(&foreign_control_load_result,
                                    alternate_fixture_bytes)) {
    (void)fprintf(stderr,
                  "battery snapshot refusal: MMC3 battery load failed\n");
    goto cleanup;
  }
  if (lf_copy_media(foreign, foreign_media, sizeof(foreign_media),
                    &foreign_info) != LF_OK ||
      lf_copy_media(foreign_control, foreign_control_media,
                    sizeof(foreign_control_media), &foreign_control_info) !=
          LF_OK ||
      foreign_info.extent_bytes != sizeof(foreign_media) ||
      foreign_control_info.extent_bytes != sizeof(foreign_control_media) ||
      memcmp(foreign_media, foreign_control_media,
             sizeof(foreign_media)) != 0 ||
      !save_bytes_match_literal(foreign_media, sizeof(foreign_media), 0U)) {
    (void)fprintf(stderr,
                  "battery snapshot refusal: MMC3 battery media setup failed\n");
    goto cleanup;
  }
  if (!battery_snapshot_refuses_unqualified_route(
          foreign, baseline, snapshot_bytes, foreign_snapshot)) {
    (void)fprintf(stderr, "battery snapshot refusal: MMC3 API gate failed\n");
    goto cleanup;
  }
  if (!advance_pair_without_setting_input(foreign, foreign_control, 0U)) {
    (void)fprintf(stderr, "battery snapshot refusal: MMC3 state diverged\n");
    goto cleanup;
  }
  if (lf_copy_media(foreign, foreign_media, sizeof(foreign_media),
                    &foreign_info) != LF_OK ||
      lf_copy_media(foreign_control, foreign_control_media,
                    sizeof(foreign_control_media), &foreign_control_info) !=
          LF_OK ||
      foreign_info.extent_bytes != sizeof(foreign_media) ||
      foreign_control_info.extent_bytes != sizeof(foreign_control_media) ||
      memcmp(foreign_media, foreign_control_media,
             sizeof(foreign_media)) != 0) {
    (void)fprintf(stderr,
                  "battery snapshot refusal: MMC3 media differs or did not advance\n");
    goto cleanup;
  }
  if (lf_copy_media(instance, endpoint_media, SAVE_FIXTURE_RAM_BYTES,
                    endpoint_info) != LF_OK ||
      endpoint_info->struct_size != sizeof(*endpoint_info) ||
      endpoint_info->extent_bytes != SAVE_FIXTURE_RAM_BYTES ||
      endpoint_info->guest_generation != expected_generation ||
      endpoint_info->identity == NULL ||
      strcmp(endpoint_info->identity, SAVE_MEDIA_IDENTITY) != 0 ||
      !save_bytes_match_literal(
          endpoint_media, SAVE_FIXTURE_RAM_BYTES,
          (uint8_t)LF_BATTERY_SNAPSHOT_CAPTURE_BYTE) ||
      host_acknowledgment->payload != expected_acknowledgment_pointer ||
      !save_acknowledgments_match(host_acknowledgment,
                                  expected_acknowledgment) ||
      !only_committed_save_remains(save_path)) {
    goto cleanup;
  }
  result = 1;

cleanup:
  free(foreign_snapshot);
  free(candidate);
  if (lf_destroy(&foreign) != LF_OK) {
    result = 0;
  }
  if (lf_destroy(&foreign_control) != LF_OK) {
    result = 0;
  }
  return result;
}

static int exercise_battery_snapshot_oracle_control(void) {
  static const struct {
    const char *name;
    battery_snapshot_oracle_failure expected_failure;
  } cases[] = {
      {"progress", BATTERY_SNAPSHOT_ORACLE_PROGRESS},
      {"video", BATTERY_SNAPSHOT_ORACLE_VIDEO},
      {"audio", BATTERY_SNAPSHOT_ORACLE_AUDIO},
      {"media", BATTERY_SNAPSHOT_ORACLE_MEDIA},
  };
  lf_instance *instance = NULL;
  lf_load_result load_result = {.struct_size = sizeof(load_result)};
  lf_run_result run_result = {.struct_size = sizeof(run_result)};
  size_t snapshot_bytes = 0U;
  uint8_t *baseline = NULL;
  uint8_t expected_media[SAVE_FIXTURE_RAM_BYTES];
  battery_snapshot_oracle expected = {
      .buttons = 0U,
      .frames = (uint64_t)LF_BATTERY_SNAPSHOT_REPLAY_FRAMES,
      .ticks = (uint64_t)LF_BATTERY_SNAPSHOT_REPLAY_TICKS,
      .rgb = {(uint8_t)LF_BATTERY_SNAPSHOT_REPLAY_RGB_RED,
              (uint8_t)LF_BATTERY_SNAPSHOT_REPLAY_RGB_GREEN,
              (uint8_t)LF_BATTERY_SNAPSHOT_REPLAY_RGB_BLUE},
      .audio_samples =
          (size_t)LF_BATTERY_SNAPSHOT_REPLAY_AUDIO_SAMPLES,
      .audio_sample = (int16_t)LF_BATTERY_SNAPSHOT_REPLAY_AUDIO_SAMPLE,
      .media = expected_media,
      .media_bytes = sizeof(expected_media),
  };
  size_t case_index = 0U;
  int result = 0;

  if (!load_save_fixture(&instance, &load_result) ||
      !advance_save_guest_frame(instance) ||
      !advance_save_guest_frame(instance) ||
      lf_get_snapshot_size(instance, &snapshot_bytes) != LF_OK ||
      snapshot_bytes <= SNAPSHOT_TEST_HEADER_BYTES) {
    goto cleanup;
  }
  baseline = (uint8_t *)malloc(snapshot_bytes);
  if (baseline == NULL ||
      lf_capture_snapshot(instance, baseline, snapshot_bytes) != LF_OK) {
    goto cleanup;
  }

  for (case_index = 0U; case_index < sizeof(cases) / sizeof(cases[0]);
       ++case_index) {
    battery_snapshot_oracle_failure failure = BATTERY_SNAPSHOT_ORACLE_SETUP;
    memset(expected_media, (uint8_t)LF_SAVE_ORACLE_FILL_BYTE,
           sizeof(expected_media));
    expected_media[0] = (uint8_t)LF_BATTERY_SNAPSHOT_REPLAY_BYTE;
    expected.frames = (uint64_t)LF_BATTERY_SNAPSHOT_REPLAY_FRAMES;
    expected.ticks = (uint64_t)LF_BATTERY_SNAPSHOT_REPLAY_TICKS;
    expected.rgb[0] = (uint8_t)LF_BATTERY_SNAPSHOT_REPLAY_RGB_RED;
    expected.rgb[1] = (uint8_t)LF_BATTERY_SNAPSHOT_REPLAY_RGB_GREEN;
    expected.rgb[2] = (uint8_t)LF_BATTERY_SNAPSHOT_REPLAY_RGB_BLUE;
    expected.audio_samples =
        (size_t)LF_BATTERY_SNAPSHOT_REPLAY_AUDIO_SAMPLES;
    expected.audio_sample =
        (int16_t)LF_BATTERY_SNAPSHOT_REPLAY_AUDIO_SAMPLE;
    if (lf_restore_snapshot(instance, baseline, snapshot_bytes) != LF_OK) {
      goto cleanup;
    }
    if (strcmp(cases[case_index].name, "progress") == 0) {
      expected.frames += 1U;
    } else if (strcmp(cases[case_index].name, "video") == 0) {
      expected.rgb[0] ^= 1U;
    } else if (strcmp(cases[case_index].name, "audio") == 0) {
      expected.audio_samples -= 1U;
    } else if (strcmp(cases[case_index].name, "media") == 0) {
      expected_media[sizeof(expected_media) - 1U] ^= 1U;
    } else {
      goto cleanup;
    }
    failure = battery_snapshot_advance_expected(
        instance, &expected, &run_result, k_video, k_audio);
    if (failure != cases[case_index].expected_failure) {
      (void)fprintf(stderr,
                    "nesturbator_battery_snapshot_oracle_control: "
                    "dimension=%s expected-failure=%d actual=%d\n",
                    cases[case_index].name,
                    (int)cases[case_index].expected_failure, (int)failure);
      goto cleanup;
    }
    (void)fprintf(stderr,
                  "nesturbator_battery_snapshot_oracle_assertion: "
                  "dimension=%s result=rejected\n",
                  cases[case_index].name);
  }
  result = 1;

cleanup:
  free(baseline);
  if (lf_destroy(&instance) != LF_OK) {
    result = 0;
  }
  if (result != 0) {
    (void)printf("nesturbator_battery_snapshot_oracle_control: "
                 "route=source progress,video,audio,media=rejected result=pass\n");
  }
  return result;
}

static int snapshot_rejection_preserves_continuation(
    lf_instance *subject, lf_instance *control, const uint8_t *baseline,
    size_t snapshot_bytes, const uint8_t *candidate, size_t extent_bytes,
    lf_status expected_status, int reaches_native, const char *case_name) {
  uint64_t attempts_before = 0U;
  uint64_t attempts_after = 0U;
  uint8_t *subject_video = malloc(sizeof(k_video));
  int16_t *subject_audio = malloc(sizeof(k_audio));
  lf_run_result subject_result = {.struct_size = sizeof(subject_result)};
  lf_run_result control_result = {.struct_size = sizeof(control_result)};
  lf_status status = LF_OK;
  int result = 0;
  if (subject_video == NULL || subject_audio == NULL || baseline == NULL ||
      candidate == NULL || case_name == NULL || snapshot_bytes == 0U) {
    goto cleanup;
  }
  if (lf_restore_snapshot(subject, baseline, snapshot_bytes) != LF_OK ||
      lf_restore_snapshot(control, baseline, snapshot_bytes) != LF_OK ||
      lf_test_get_nesturbator_restore_attempts(subject, &attempts_before) !=
          LF_OK) {
    goto cleanup;
  }
  status = lf_restore_snapshot(subject, candidate, extent_bytes);
  if (status != expected_status ||
      lf_test_get_nesturbator_restore_attempts(subject, &attempts_after) !=
          LF_OK ||
      attempts_after != attempts_before + (reaches_native ? 1U : 0U)) {
    (void)fprintf(stderr,
                  "snapshot refusal %s status=%d expected=%d native=%" PRIu64
                  "->%" PRIu64 "\n",
                  case_name, (int)status, (int)expected_status,
                  attempts_before, attempts_after);
    goto cleanup;
  }
  if (!snapshot_advance_one(subject, UINT32_C(0x00000100), k_port1_rgb,
                            &subject_result)) {
    (void)fprintf(stderr,
                  "snapshot refusal %s changed literal subject continuation\n",
                  case_name);
    goto cleanup;
  }
  memcpy(subject_video, k_video, sizeof(k_video));
  memcpy(subject_audio, k_audio, sizeof(k_audio));
  if (!snapshot_advance_one(control, UINT32_C(0x00000100), k_port1_rgb,
                            &control_result) ||
      !snapshot_run_results_match(&subject_result, &control_result) ||
      subject_result.cumulative_units != UINT64_C(3) ||
      subject_result.cumulative_core_ticks != UINT64_C(2144304) ||
      memcmp(subject_video, k_video, sizeof(k_video)) != 0 ||
      memcmp(subject_audio, k_audio, sizeof(k_audio)) != 0) {
    (void)fprintf(stderr,
                  "snapshot refusal %s did not preserve the independent literal continuation\n",
                  case_name);
    goto cleanup;
  }
  if (lf_restore_snapshot(subject, baseline, snapshot_bytes) != LF_OK ||
      lf_restore_snapshot(control, baseline, snapshot_bytes) != LF_OK) {
    goto cleanup;
  }
  (void)printf("event=snapshot-case name=%s status=%s result=pass "
               "continuation=literal native_attempt_delta=%d\n",
               case_name, snapshot_status_name(expected_status),
               reaches_native ? 1 : 0);
  result = 1;

cleanup:
  free(subject_audio);
  free(subject_video);
  return result;
}

static int exercise_snapshot_rejections(const uint8_t *fixture,
                                        size_t fixture_bytes) {
  allocation_tracker subject_tracker = {0};
  allocation_tracker control_tracker = {0};
  allocation_tracker foreign_tracker = {0};
  lf_instance *subject = NULL;
  lf_instance *control = NULL;
  lf_instance *foreign = NULL;
  lf_input input = {
      .struct_size = sizeof(input),
      .buttons = UINT32_C(0x00000100),
  };
  uint64_t subject_frames = 0U;
  uint64_t subject_ticks = 0U;
  uint64_t control_frames = 0U;
  uint64_t control_ticks = 0U;
  size_t subject_audio_samples = 0U;
  size_t control_audio_samples = 0U;
  size_t snapshot_bytes = 0U;
  uint8_t *baseline = NULL;
  uint8_t *candidate = NULL;
  uint8_t *foreign_fixture = NULL;
  uint8_t *foreign_snapshot = NULL;
  uint8_t fixture_digest[32];
  uint8_t foreign_digest[32];
  int result = 0;
  static const snapshot_rejection_case cases[] = {
      {.name = "empty_extent",
       .extent_kind = SNAPSHOT_EXTENT_EMPTY,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "truncated_header",
       .extent_kind = SNAPSHOT_EXTENT_HEADER_MINUS_ONE,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "truncated_snapshot",
       .extent_kind = SNAPSHOT_EXTENT_SNAPSHOT_MINUS_ONE,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "oversized_extent",
       .extent_kind = SNAPSHOT_EXTENT_ABOVE_MAXIMUM,
       .expected_status = LF_LIMIT_EXCEEDED},
      {.name = "extent_overflow",
       .extent_kind = SNAPSHOT_EXTENT_SIZE_MAXIMUM,
       .expected_status = LF_LIMIT_EXCEEDED},
      {.name = "encoded_total_overflow",
       .offset = SNAPSHOT_TEST_TOTAL_SIZE_OFFSET,
       .width = 8U,
       .value = UINT64_MAX,
       .expected_status = LF_LIMIT_EXCEEDED},
      {.name = "declared_total_mismatch",
       .offset = SNAPSHOT_TEST_TOTAL_SIZE_OFFSET,
       .width = 8U,
       .value = UINT64_C(1),
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "native_extent_mismatch",
       .offset = SNAPSHOT_TEST_NATIVE_SIZE_OFFSET,
       .width = 8U,
       .value = UINT64_MAX,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "bad_magic",
       .offset = 0U,
       .xor_byte = 1,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "bad_header_extent",
       .offset = SNAPSHOT_TEST_HEADER_SIZE_OFFSET,
       .width = 4U,
       .value = SNAPSHOT_TEST_HEADER_BYTES - 1U,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "unsupported_version",
       .offset = SNAPSHOT_TEST_VERSION_OFFSET,
       .width = 4U,
       .value = 3U,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "native_state_format",
       .offset = SNAPSHOT_TEST_STATE_FORMAT_OFFSET,
       .width = 4U,
       .value = 99U,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "core_abi",
       .offset = SNAPSHOT_TEST_CORE_ABI_OFFSET,
       .width = 4U,
       .value = 99U,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "behavior_revision",
       .offset = SNAPSHOT_TEST_BEHAVIOR_REVISION_OFFSET,
       .width = 4U,
       .value = 99U,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "core_build",
       .offset = SNAPSHOT_TEST_BUILD_ID_OFFSET,
       .xor_byte = 1,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "libfuturo_build",
       .offset = SNAPSHOT_TEST_LIBFUTURO_BUILD_ID_OFFSET,
       .xor_byte = 1,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "profile",
       .offset = SNAPSHOT_TEST_PROFILE_ID_OFFSET,
       .xor_byte = 1,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "configuration",
       .offset = SNAPSHOT_TEST_CONFIGURATION_ID_OFFSET,
       .xor_byte = 1,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "options",
       .offset = SNAPSHOT_TEST_OPTIONS_ID_OFFSET,
       .xor_byte = 1,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "content_extent",
       .offset = SNAPSHOT_TEST_CONTENT_SIZE_OFFSET,
       .width = 8U,
       .value = UINT64_MAX,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "frame_overflow",
       .offset = SNAPSHOT_TEST_CUMULATIVE_FRAMES_OFFSET,
       .width = 8U,
       .value = UINT64_MAX,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "pending_input",
       .offset = SNAPSHOT_TEST_PENDING_BUTTONS_OFFSET,
       .width = 4U,
       .value = UINT64_C(0x00010000),
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "continuation_flags",
       .offset = SNAPSHOT_TEST_FLAGS_OFFSET,
       .width = 4U,
       .value = UINT64_C(0x80000000),
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "native_payload_corrupt",
       .offset = SIZE_MAX,
       .xor_byte = 1,
       .expected_status = LF_INVALID_ARGUMENT,
       .reaches_native = 1},
  };
  size_t case_index = 0U;

  if (!create_loaded_test_instance(&subject_tracker, &subject, fixture,
                                   fixture_bytes) ||
      !create_loaded_test_instance(&control_tracker, &control, fixture,
                                   fixture_bytes) ||
      lf_set_input(subject, &input) != LF_OK ||
      lf_set_input(control, &input) != LF_OK ||
      !run_color_case(subject, input.buttons, k_port1_rgb, &subject_frames,
                      &subject_ticks, &subject_audio_samples) ||
      !run_color_case(control, input.buttons, k_port1_rgb, &control_frames,
                      &control_ticks, &control_audio_samples) ||
      subject_frames != control_frames || subject_ticks != control_ticks ||
      subject_audio_samples != control_audio_samples ||
      lf_get_snapshot_size(subject, &snapshot_bytes) != LF_OK) {
    goto cleanup;
  }
  baseline = malloc(snapshot_bytes);
  candidate = malloc(snapshot_bytes);
  if (baseline == NULL || candidate == NULL ||
      lf_capture_snapshot(subject, baseline, snapshot_bytes) != LF_OK) {
    goto cleanup;
  }
  for (case_index = 0U; case_index < sizeof(cases) / sizeof(cases[0]);
       ++case_index) {
    const snapshot_rejection_case *test_case = &cases[case_index];
    size_t extent_bytes = snapshot_bytes;
    memcpy(candidate, baseline, snapshot_bytes);
    if (strcmp(test_case->name, "content_extent") == 0) {
      snapshot_test_put_uint(candidate + test_case->offset, test_case->width,
                             UINT64_MAX);
    } else if (strcmp(test_case->name, "declared_total_mismatch") == 0) {
      snapshot_test_put_uint(candidate + test_case->offset, test_case->width,
                             (uint64_t)snapshot_bytes - 1U);
    } else if (test_case->offset == SIZE_MAX) {
      candidate[snapshot_bytes - 1U] ^= 1U;
    } else if (test_case->width != 0U) {
      snapshot_test_put_uint(candidate + test_case->offset, test_case->width,
                             test_case->value);
    } else if (test_case->xor_byte) {
      candidate[test_case->offset] ^= 1U;
    }
    switch (test_case->extent_kind) {
    case SNAPSHOT_EXTENT_EMPTY:
      extent_bytes = 0U;
      break;
    case SNAPSHOT_EXTENT_HEADER_MINUS_ONE:
      extent_bytes = SNAPSHOT_TEST_HEADER_BYTES - 1U;
      break;
    case SNAPSHOT_EXTENT_SNAPSHOT_MINUS_ONE:
      extent_bytes = snapshot_bytes - 1U;
      break;
    case SNAPSHOT_EXTENT_ABOVE_MAXIMUM:
      extent_bytes = (size_t)(128U * 1024U * 1024U) + 1U;
      break;
    case SNAPSHOT_EXTENT_SIZE_MAXIMUM:
      extent_bytes = SIZE_MAX;
      break;
    case SNAPSHOT_EXTENT_EXACT:
    default:
      break;
    }
    if (!snapshot_rejection_preserves_continuation(
            subject, control, baseline, snapshot_bytes, candidate,
            extent_bytes, test_case->expected_status,
            test_case->reaches_native, test_case->name)) {
      goto cleanup;
    }
  }
  foreign_fixture = malloc(fixture_bytes);
  if (foreign_fixture == NULL || (fixture[6] & 0x02U) != 0U ||
      !lf_sha256_bytes(fixture, fixture_bytes, fixture_digest)) {
    goto cleanup;
  }
  memcpy(foreign_fixture, fixture, fixture_bytes);
  foreign_fixture[FIXTURE_PRG_OFFSET + FIXTURE_PRG_BYTES] ^= 1U;
  if ((foreign_fixture[6] & 0x02U) != 0U ||
      !lf_sha256_bytes(foreign_fixture, fixture_bytes, foreign_digest) ||
      memcmp(fixture_digest, foreign_digest, sizeof(fixture_digest)) == 0 ||
      !create_loaded_test_instance(&foreign_tracker, &foreign,
                                   foreign_fixture, fixture_bytes)) {
    goto cleanup;
  }
  {
    size_t foreign_snapshot_bytes = 0U;
    if (lf_get_snapshot_size(foreign, &foreign_snapshot_bytes) != LF_OK ||
        foreign_snapshot_bytes != snapshot_bytes) {
      goto cleanup;
    }
  }
  foreign_snapshot = malloc(snapshot_bytes);
  if (foreign_snapshot == NULL ||
      lf_capture_snapshot(foreign, foreign_snapshot, snapshot_bytes) != LF_OK ||
      !snapshot_rejection_preserves_continuation(
          subject, control, baseline, snapshot_bytes, foreign_snapshot,
          snapshot_bytes, LF_INVALID_ARGUMENT, 0,
          "content_digest")) {
    goto cleanup;
  }
  (void)printf("event=snapshot-content-control bytes=%zu same_length=pass "
               "different_sha256=pass battery_free=pass "
               "profile=nesturbator-ntsc-v1 "
               "configuration=nesturbator-default route_eligible=pass\n",
               fixture_bytes);
  result = 1;

cleanup:
  free(foreign_snapshot);
  free(foreign_fixture);
  free(candidate);
  free(baseline);
  if (lf_destroy(&subject) != LF_OK) {
    result = 0;
  }
  if (lf_destroy(&control) != LF_OK) {
    result = 0;
  }
  if (lf_destroy(&foreign) != LF_OK) {
    result = 0;
  }
  if (subject_tracker.invalid_frees != 0U || subject_tracker.live != 0U ||
      subject_tracker.allocations != subject_tracker.frees ||
      control_tracker.invalid_frees != 0U || control_tracker.live != 0U ||
      control_tracker.allocations != control_tracker.frees ||
      foreign_tracker.invalid_frees != 0U || foreign_tracker.live != 0U ||
      foreign_tracker.allocations != foreign_tracker.frees) {
    result = 0;
  }
  return result;
}

static int exercise_snapshot_reload_capacity(const uint8_t *fixture,
                                             size_t fixture_bytes) {
  allocation_tracker subject_tracker = {0};
  allocation_tracker control_tracker = {0};
  lf_instance *subject = NULL;
  lf_instance *control = NULL;
  uint8_t chr_ram_fixture[FIXTURE_HEADER_BYTES + FIXTURE_PRG_BYTES];
  lf_load_request reload_request = {.struct_size = sizeof(reload_request)};
  lf_load_result reload_result = {.struct_size = sizeof(reload_result)};
  uint8_t *short_buffer = NULL;
  size_t old_extent = 0U;
  size_t new_extent = 0U;
  const size_t chr_ram_fixture_bytes = sizeof(chr_ram_fixture);
  const uint32_t pending_buttons = UINT32_C(0x00000100);
  lf_input input = {.struct_size = sizeof(input), .buttons = pending_buttons};
  int result = 0;

  if (fixture == NULL || fixture_bytes != FIXTURE_TOTAL_BYTES ||
      !create_loaded_test_instance(&subject_tracker, &subject, fixture,
                                   fixture_bytes) ||
      lf_get_snapshot_size(subject, &old_extent) != LF_OK ||
      old_extent <= SNAPSHOT_TEST_HEADER_BYTES) {
    goto cleanup;
  }
  memcpy(chr_ram_fixture, fixture, sizeof(chr_ram_fixture));
  chr_ram_fixture[5] = 0U;
  reload_request.content_data = chr_ram_fixture;
  reload_request.content_size_bytes = chr_ram_fixture_bytes;
  reload_request.configuration_id = NULL;
  if (lf_load(subject, &reload_request, &reload_result) != LF_OK ||
      !load_result_preserves_active(&reload_result, chr_ram_fixture_bytes) ||
      lf_get_snapshot_size(subject, &new_extent) != LF_OK ||
      new_extent <= old_extent ||
      !create_loaded_test_instance(&control_tracker, &control, chr_ram_fixture,
                                   chr_ram_fixture_bytes)) {
    goto cleanup;
  }
  short_buffer = malloc(old_extent);
  if (short_buffer == NULL) {
    goto cleanup;
  }
  memset(short_buffer, 0xA5, old_extent);
  if (lf_capture_snapshot(subject, short_buffer, old_extent) !=
          LF_BUFFER_TOO_SMALL ||
      !bytes_equal_value(short_buffer, old_extent, 0xA5U) ||
      lf_set_input(subject, &input) != LF_OK ||
      lf_set_input(control, &input) != LF_OK ||
      !advance_pair_without_setting_input(subject, control, pending_buttons)) {
    goto cleanup;
  }
  result = 1;

cleanup:
  free(short_buffer);
  if (lf_destroy(&subject) != LF_OK) {
    result = 0;
  }
  if (lf_destroy(&control) != LF_OK) {
    result = 0;
  }
  if (subject_tracker.invalid_frees != 0U || subject_tracker.live != 0U ||
      subject_tracker.allocations != subject_tracker.frees ||
      control_tracker.invalid_frees != 0U || control_tracker.live != 0U ||
      control_tracker.allocations != control_tracker.frees) {
    result = 0;
  }
  return result;
}

static int exercise_snapshot_unloaded_and_routes(void) {
  static const size_t k_probe_bytes = 256U;
  uint8_t probe[k_probe_bytes];
  uint8_t before[k_probe_bytes];
  allocation_tracker tracker = {0};
  lf_instance *nesturbator = NULL;
  lf_instance *synthetic = NULL;
  size_t required_bytes = (size_t)0x5A5AA5A5U;
  uint32_t supported = UINT32_MAX;
  lf_status status = LF_OK;
  int result = 0;

  if (lf_get_capability("nesturbator-ntsc-v1", NULL, LF_CAP_SNAPSHOT,
                        &supported) != LF_OK ||
      supported != 1U) {
    goto cleanup;
  }
  supported = UINT32_MAX;
  if (lf_get_capability("nesturbator-ntsc-v1", "nesturbator-default",
                        LF_CAP_SNAPSHOT, &supported) != LF_UNSUPPORTED ||
      supported != 0U) {
    goto cleanup;
  }
  supported = UINT32_MAX;
  if (lf_get_capability("synthetic-v1", NULL, LF_CAP_SNAPSHOT,
                        &supported) != LF_UNSUPPORTED ||
      supported != 0U) {
    goto cleanup;
  }
  if (!create_test_instance(&tracker, &nesturbator) ||
      lf_create("synthetic-v1", NULL, &synthetic) != LF_OK ||
      synthetic == NULL) {
    goto cleanup;
  }
  memset(probe, 0xA5, sizeof(probe));
  memcpy(before, probe, sizeof(probe));
  if (lf_get_snapshot_size(nesturbator, &required_bytes) !=
          LF_INVALID_ARGUMENT ||
      required_bytes != (size_t)0x5A5AA5A5U ||
      lf_capture_snapshot(nesturbator, probe, sizeof(probe)) !=
          LF_INVALID_ARGUMENT ||
      memcmp(probe, before, sizeof(probe)) != 0 ||
      lf_restore_snapshot(nesturbator, probe, sizeof(probe)) !=
          LF_INVALID_ARGUMENT ||
      memcmp(probe, before, sizeof(probe)) != 0) {
    goto cleanup;
  }
  required_bytes = (size_t)0x5A5AA5A5U;
  if (lf_get_snapshot_size(synthetic, &required_bytes) != LF_UNSUPPORTED ||
      required_bytes != (size_t)0x5A5AA5A5U ||
      lf_capture_snapshot(synthetic, probe, sizeof(probe)) != LF_UNSUPPORTED ||
      lf_restore_snapshot(synthetic, probe, sizeof(probe)) != LF_UNSUPPORTED ||
      memcmp(probe, before, sizeof(probe)) != 0) {
    goto cleanup;
  }
  result = 1;

cleanup:
  status = lf_destroy(&nesturbator);
  if (!result || status != LF_OK) {
    result = 0;
  }
  status = lf_destroy(&synthetic);
  if (status != LF_OK) {
    result = 0;
  }
  if (tracker.invalid_frees != 0U || tracker.live != 0U ||
      tracker.allocations != tracker.frees) {
    result = 0;
  }
  return result;
}

static int exercise_snapshot_battery_support(void) {
  allocation_tracker subject_tracker = {0};
  allocation_tracker control_tracker = {0};
  lf_instance *subject = NULL;
  lf_instance *control = NULL;
  uint8_t battery_fixture[LF_NESTURBATOR_SAVE_FIXTURE_TOTAL_BYTES];
  uint8_t probe[256];
  uint8_t before[sizeof(probe)];
  uint8_t *snapshot = NULL;
  size_t fixture_bytes = 0U;
  size_t required_bytes = (size_t)0x5A5AA5A5U;
  const uint32_t pending_buttons = UINT32_C(0x00000100);
  lf_input input = {.struct_size = sizeof(input), .buttons = pending_buttons};
  int result = 0;

  fixture_bytes = lf_build_nesturbator_save_fixture(battery_fixture,
                                                     sizeof(battery_fixture));
  if (fixture_bytes == 0U ||
      !create_loaded_test_instance(&subject_tracker, &subject,
                                   battery_fixture, fixture_bytes) ||
      !create_loaded_test_instance(&control_tracker, &control,
                                   battery_fixture, fixture_bytes)) {
    goto cleanup;
  }
  memset(probe, 0xA5, sizeof(probe));
  memcpy(before, probe, sizeof(probe));
  if (lf_get_snapshot_size(subject, &required_bytes) != LF_OK ||
      required_bytes <= sizeof(probe) ||
      lf_capture_snapshot(subject, probe, sizeof(probe)) !=
          LF_BUFFER_TOO_SMALL ||
      memcmp(probe, before, sizeof(probe)) != 0 ||
      (snapshot = (uint8_t *)malloc(required_bytes)) == NULL ||
      lf_capture_snapshot(subject, snapshot, required_bytes) != LF_OK ||
      lf_restore_snapshot(subject, snapshot, required_bytes) != LF_OK ||
      lf_set_input(subject, &input) != LF_OK ||
      lf_set_input(control, &input) != LF_OK ||
      !advance_pair_without_setting_input(subject, control, pending_buttons)) {
    goto cleanup;
  }
  result = 1;

cleanup:
  free(snapshot);
  if (lf_destroy(&subject) != LF_OK) {
    result = 0;
  }
  if (lf_destroy(&control) != LF_OK) {
    result = 0;
  }
  if (subject_tracker.invalid_frees != 0U || subject_tracker.live != 0U ||
      subject_tracker.allocations != subject_tracker.frees ||
      control_tracker.invalid_frees != 0U || control_tracker.live != 0U ||
      control_tracker.allocations != control_tracker.frees) {
    result = 0;
  }
  return result;
}

static int exercise_snapshot_load_epoch_exhaustion(const uint8_t *fixture,
                                                    size_t fixture_bytes) {
  allocation_tracker subject_tracker = {0};
  allocation_tracker control_tracker = {0};
  lf_instance *subject = NULL;
  lf_instance *control = NULL;
  lf_load_request request = {
      .struct_size = sizeof(request),
      .content_data = fixture,
      .content_size_bytes = fixture_bytes,
      .configuration_id = NULL,
  };
  lf_load_result load_result = {.struct_size = sizeof(load_result)};
  size_t calls_before = 0U;
  const uint32_t pending_buttons = UINT32_C(0x00000100);
  lf_input input = {.struct_size = sizeof(input), .buttons = pending_buttons};
  int result = 0;

  if (!create_loaded_test_instance(&subject_tracker, &subject, fixture,
                                   fixture_bytes) ||
      !create_loaded_test_instance(&control_tracker, &control, fixture,
                                   fixture_bytes) ||
      lf_set_input(subject, &input) != LF_OK ||
      lf_set_input(control, &input) != LF_OK ||
      !advance_pair_without_setting_input(subject, control, pending_buttons) ||
      lf_test_set_nesturbator_load_epoch(subject, UINT64_MAX) != LF_OK) {
    goto cleanup;
  }
  calls_before = subject_tracker.calls;
  if (lf_load(subject, &request, &load_result) != LF_LIMIT_EXCEEDED ||
      !load_result_preserves_active(&load_result, fixture_bytes) ||
      subject_tracker.calls != calls_before ||
      !advance_pair_without_setting_input(subject, control, pending_buttons)) {
    goto cleanup;
  }
  result = 1;

cleanup:
  if (lf_destroy(&subject) != LF_OK) {
    result = 0;
  }
  if (lf_destroy(&control) != LF_OK) {
    result = 0;
  }
  if (subject_tracker.invalid_frees != 0U || subject_tracker.live != 0U ||
      subject_tracker.allocations != subject_tracker.frees ||
      control_tracker.invalid_frees != 0U || control_tracker.live != 0U ||
      control_tracker.allocations != control_tracker.frees) {
    result = 0;
  }
  return result;
}

static int exercise_snapshot_replay(const uint8_t *fixture,
                                    size_t fixture_bytes,
                                    const uint8_t replay_oracle_rgb[3]) {
  allocation_tracker subject_tracker = {0};
  allocation_tracker control_tracker = {0};
  lf_instance *subject = NULL;
  lf_instance *control = NULL;
  lf_run_result original_result = {.struct_size = sizeof(original_result)};
  lf_run_result control_result = {.struct_size = sizeof(control_result)};
  lf_run_result replay_result = {.struct_size = sizeof(replay_result)};
  lf_input port1_input = {
      .struct_size = sizeof(port1_input),
      .buttons = UINT32_C(0x00000100),
  };
  lf_input port0_input = {.struct_size = sizeof(port0_input), .buttons = 1U};
  uint64_t subject_frames = 0U;
  uint64_t subject_ticks = 0U;
  uint64_t control_frames = 0U;
  uint64_t control_ticks = 0U;
  uint64_t mutated_frames = 0U;
  uint64_t mutated_ticks = 0U;
  size_t subject_audio_samples = 0U;
  size_t control_audio_samples = 0U;
  size_t mutated_audio_samples = 0U;
  size_t control_mutated_audio_samples = 0U;
  size_t snapshot_bytes = 0U;
  uint8_t *snapshot = NULL;
  uint8_t *snapshot_copy = NULL;
  uint8_t *restored_copy = NULL;
  uint8_t *short_buffer = NULL;
  uint8_t *original_video = NULL;
  uint8_t *mutated_video = NULL;
  int16_t *original_audio = NULL;
  int16_t *mutated_audio = NULL;
  lf_status snapshot_status = LF_OK;
  int stage = 1;
  int result = 0;

  if (!create_loaded_test_instance(&subject_tracker, &subject, fixture,
                                   fixture_bytes) ||
      !create_loaded_test_instance(&control_tracker, &control, fixture,
                                   fixture_bytes) ||
      !run_color_case(subject, port1_input.buttons, k_port1_rgb,
                      &subject_frames, &subject_ticks,
                      &subject_audio_samples) ||
      !run_color_case(control, port1_input.buttons, k_port1_rgb,
                      &control_frames, &control_ticks,
                      &control_audio_samples) ||
      subject_frames != control_frames || subject_ticks != control_ticks ||
      subject_audio_samples != control_audio_samples) {
    goto cleanup;
  }
  if (lf_get_snapshot_size(subject, &snapshot_bytes) != LF_OK ||
      snapshot_bytes <= 256U) {
    goto cleanup;
  }
  stage = 2;
  {
    size_t control_snapshot_bytes = 0U;
    if (lf_get_snapshot_size(control, &control_snapshot_bytes) != LF_OK ||
        control_snapshot_bytes != snapshot_bytes) {
      goto cleanup;
    }
  }
  snapshot = malloc(snapshot_bytes);
  snapshot_copy = malloc(snapshot_bytes);
  restored_copy = malloc(snapshot_bytes);
  short_buffer = malloc(snapshot_bytes);
  original_video = malloc(sizeof(k_video));
  mutated_video = malloc(sizeof(k_video));
  original_audio = malloc(sizeof(k_audio));
  mutated_audio = malloc(sizeof(k_audio));
  if (snapshot == NULL || snapshot_copy == NULL || restored_copy == NULL ||
      short_buffer == NULL || original_video == NULL || mutated_video == NULL ||
      original_audio == NULL || mutated_audio == NULL) {
    goto cleanup;
  }
  stage = 3;
  memset(short_buffer, 0xA5, snapshot_bytes);
  snapshot_status = lf_capture_snapshot(subject, short_buffer,
                                       snapshot_bytes - 1U);
  if (snapshot_status != LF_BUFFER_TOO_SMALL ||
      !bytes_equal_value(short_buffer, snapshot_bytes, 0xA5U)) {
    (void)fprintf(stderr, "snapshot short buffer status=%d extent=%zu\n",
                  (int)snapshot_status, snapshot_bytes);
    goto cleanup;
  }
  snapshot_status = lf_capture_snapshot(subject, snapshot, snapshot_bytes);
  if (snapshot_status != LF_OK) {
    (void)fprintf(stderr, "snapshot capture status=%d extent=%zu\n",
                  (int)snapshot_status, snapshot_bytes);
    goto cleanup;
  }
  snapshot_status = lf_capture_snapshot(subject, snapshot_copy, snapshot_bytes);
  if (snapshot_status != LF_OK ||
      memcmp(snapshot, snapshot_copy, snapshot_bytes) != 0) {
    (void)fprintf(stderr, "snapshot repeated capture status=%d equal=%d\n",
                  (int)snapshot_status,
                  memcmp(snapshot, snapshot_copy, snapshot_bytes) == 0);
    goto cleanup;
  }
  if (!snapshot_advance_one(subject, port1_input.buttons, k_port1_rgb,
                            &original_result)) {
    (void)fprintf(stderr, "snapshot source continuation failed\n");
    goto cleanup;
  }
  stage = 4;
  memcpy(original_video, k_video, sizeof(k_video));
  memcpy(original_audio, k_audio, sizeof(k_audio));
  if (original_result.cumulative_units != UINT64_C(3) ||
      original_result.cumulative_core_ticks != UINT64_C(2144304)) {
    (void)fprintf(stderr,
                  "snapshot literal progress mismatch: frames=%" PRIu64
                  " ticks=%" PRIu64 "\n",
                  original_result.cumulative_units,
                  original_result.cumulative_core_ticks);
    goto cleanup;
  }
  if (!snapshot_advance_one(control, port1_input.buttons, k_port1_rgb,
                            &control_result)) {
    (void)fprintf(stderr, "snapshot control continuation failed\n");
    goto cleanup;
  }
  if (!snapshot_run_results_match(&original_result, &control_result) ||
      memcmp(original_video, k_video, sizeof(k_video)) != 0 ||
      memcmp(original_audio, k_audio, sizeof(k_audio)) != 0) {
    (void)fprintf(stderr,
                  "snapshot control diverged frames=%" PRIu64 "/%" PRIu64
                  " ticks=%" PRIu64 "/%" PRIu64 "\n",
                  original_result.cumulative_units,
                  control_result.cumulative_units,
                  original_result.cumulative_core_ticks,
                  control_result.cumulative_core_ticks);
    goto cleanup;
  }
  if (lf_set_input(subject, &port0_input) != LF_OK ||
      lf_set_input(control, &port0_input) != LF_OK) {
    (void)fprintf(stderr, "snapshot input mutation setup failed\n");
    goto cleanup;
  }
  mutated_frames = original_result.cumulative_units;
  mutated_ticks = original_result.cumulative_core_ticks;
  if (!run_color_case(subject, port0_input.buttons, k_pressed_rgb,
                      &mutated_frames, &mutated_ticks,
                      &mutated_audio_samples)) {
    (void)fprintf(stderr, "snapshot mutated source did not reach literal\n");
    goto cleanup;
  }
  stage = 5;
  memcpy(mutated_video, k_video, sizeof(k_video));
  memcpy(mutated_audio, k_audio, sizeof(k_audio));
  control_frames = original_result.cumulative_units;
  control_ticks = original_result.cumulative_core_ticks;
  if (!run_color_case(control, port0_input.buttons, k_pressed_rgb,
                      &control_frames, &control_ticks,
                      &control_mutated_audio_samples) ||
      mutated_frames != control_frames || mutated_ticks != control_ticks ||
      mutated_audio_samples != control_mutated_audio_samples ||
      memcmp(mutated_video, k_video, sizeof(k_video)) != 0 ||
      memcmp(mutated_audio, k_audio, sizeof(k_audio)) != 0 ||
      lf_restore_snapshot(subject, snapshot, snapshot_bytes) != LF_OK ||
      lf_capture_snapshot(subject, restored_copy, snapshot_bytes) != LF_OK ||
      memcmp(snapshot, restored_copy, snapshot_bytes) != 0 ||
      !snapshot_advance_one(subject, port1_input.buttons, replay_oracle_rgb,
                            &replay_result) ||
      !snapshot_run_results_match(&original_result, &replay_result) ||
      memcmp(original_video, k_video, sizeof(k_video)) != 0 ||
      memcmp(original_audio, k_audio, sizeof(k_audio)) != 0) {
    goto cleanup;
  }
  stage = 6;
  result = 1;

cleanup:
  if (!result) {
    (void)fprintf(stderr, "snapshot replay failed at stage %d\n", stage);
  }
  free(mutated_audio);
  free(original_audio);
  free(mutated_video);
  free(original_video);
  free(short_buffer);
  free(restored_copy);
  free(snapshot_copy);
  free(snapshot);
  if (lf_destroy(&subject) != LF_OK) {
    result = 0;
  }
  if (lf_destroy(&control) != LF_OK) {
    result = 0;
  }
  if (subject_tracker.invalid_frees != 0U || subject_tracker.live != 0U ||
      subject_tracker.allocations != subject_tracker.frees ||
      control_tracker.invalid_frees != 0U || control_tracker.live != 0U ||
      control_tracker.allocations != control_tracker.frees) {
    result = 0;
  }
  return result;
}

static int exercise_battery_snapshot_recovery(void) {
  char directory_template[] = "/tmp/libfuturo-battery-snapshot-XXXXXX";
  char save_path[4096] = {0};
  uint8_t capture_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t capture_after_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t newer_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t restored_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t identical_restored_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t replay_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t previous_file[SAVE_ENVELOPE_MAX_BYTES];
  uint8_t restored_file[SAVE_ENVELOPE_MAX_BYTES];
  uint8_t previous_encoded_header[SAVE_ENVELOPE_HEADER_BYTES];
  uint8_t opened_encoded_header[SAVE_ENVELOPE_HEADER_BYTES];
  uint8_t *snapshot = NULL;
  uint8_t *previous_payload = NULL;
  uint8_t *opened_payload = NULL;
  size_t snapshot_bytes = 0U;
  size_t previous_file_bytes = 0U;
  size_t restored_file_bytes = 0U;
  uint32_t supported = 0U;
  lf_instance *instance = NULL;
  lf_profile profile = {.struct_size = sizeof(profile)};
  lf_load_result load_result = {.struct_size = sizeof(load_result)};
  lf_media_info capture_info = {.struct_size = sizeof(capture_info)};
  lf_media_info capture_after_info = {.struct_size = sizeof(capture_after_info)};
  lf_media_info newer_info = {.struct_size = sizeof(newer_info)};
  lf_media_info restored_info = {.struct_size = sizeof(restored_info)};
  lf_media_info identical_restored_info = {
      .struct_size = sizeof(identical_restored_info)};
  lf_media_info replay_info = {.struct_size = sizeof(replay_info)};
  lf_run_result replay_result = {.struct_size = sizeof(replay_result)};
  save_envelope_header newer_header;
  save_envelope_header previous_header;
  save_envelope_header restored_header;
  save_envelope_header opened_header;
  save_acknowledgment host_acknowledgment = {0};
  save_acknowledgment previous_acknowledgment = {0};
  const uint8_t *previous_acknowledgment_payload = NULL;
  size_t frame = 0U;
  int stage = 1;
  int result = 0;
  const char *failure = "temporary directory";
  char *directory = mkdtemp(directory_template);

  if (directory == NULL) {
    goto cleanup;
  }
  stage = 2;
  failure = "selected-save path";
  {
    const int path_length =
        snprintf(save_path, sizeof(save_path), "%s/save.bin", directory);
    if (path_length < 0 || (size_t)path_length >= sizeof(save_path)) {
      goto cleanup;
    }
  }
  stage = 3;
  failure = "generated battery fixture load";
  if (!load_save_fixture(&instance, &load_result) ||
      strcmp(LIBFUTURO_NESTURBATOR_SOURCE_REVISION,
             NESTURBATOR_EXPECTED_SOURCE_REVISION) != 0 ||
      lf_get_profile("nesturbator-ntsc-v1", NULL, &profile) != LF_OK ||
      profile.struct_size != sizeof(profile) || profile.profile_id == NULL ||
      strcmp(profile.profile_id, "nesturbator-ntsc-v1") != 0 ||
      profile.build_id == NULL ||
      strcmp(profile.build_id,
             "nesturbator-" NESTURBATOR_EXPECTED_SOURCE_REVISION) != 0 ||
      profile.api_revision != 1U || profile.behavior_revision != 9U ||
      lf_get_capability("nesturbator-ntsc-v1", NULL, LF_CAP_SNAPSHOT,
                        &supported) != LF_OK ||
      supported != 1U) {
    goto cleanup;
  }
  stage = 4;
  failure = "two-write capture literal";
  for (frame = 0U; frame < 2U; ++frame) {
    if (!advance_save_guest_frame(instance)) {
      goto cleanup;
    }
  }
  if (lf_copy_media(instance, capture_media, sizeof(capture_media),
                     &capture_info) != LF_OK ||
      capture_info.extent_bytes != sizeof(capture_media) ||
      capture_info.identity == NULL ||
      strcmp(capture_info.identity, SAVE_MEDIA_IDENTITY) != 0 ||
      capture_info.guest_generation < 2U ||
      !save_bytes_match_literal(
          capture_media, sizeof(capture_media),
          (uint8_t)LF_BATTERY_SNAPSHOT_CAPTURE_BYTE)) {
    goto cleanup;
  }
  stage = 5;
  failure = "battery snapshot capture";
  if (lf_get_snapshot_size(instance, &snapshot_bytes) != LF_OK ||
      snapshot_bytes <= 212U) {
    goto cleanup;
  }
  snapshot = (uint8_t *)malloc(snapshot_bytes);
  if (snapshot == NULL ||
      lf_capture_snapshot(instance, snapshot, snapshot_bytes) != LF_OK) {
    goto cleanup;
  }
  if (snapshot_test_get_uint(
          snapshot + SNAPSHOT_TEST_STATE_FORMAT_OFFSET, 4U) != 3U ||
      snapshot_test_get_uint(snapshot + SNAPSHOT_TEST_CORE_ABI_OFFSET, 4U) !=
          (uint64_t)profile.api_revision ||
      snapshot_test_get_uint(
          snapshot + SNAPSHOT_TEST_BEHAVIOR_REVISION_OFFSET, 4U) !=
          (uint64_t)profile.behavior_revision ||
      strcmp((const char *)(snapshot + SNAPSHOT_TEST_BUILD_ID_OFFSET),
             profile.build_id) != 0) {
    goto cleanup;
  }
  if (lf_copy_media(instance, capture_after_media, sizeof(capture_after_media),
                    &capture_after_info) != LF_OK ||
      capture_after_info.extent_bytes != capture_info.extent_bytes ||
      capture_after_info.guest_generation != capture_info.guest_generation ||
      capture_after_info.identity == NULL ||
      strcmp(capture_after_info.identity, SAVE_MEDIA_IDENTITY) != 0 ||
      memcmp(capture_after_media, capture_media, sizeof(capture_media)) != 0) {
    goto cleanup;
  }
  stage = 6;
  failure = "three-write selected newer payload";
  if (!advance_save_guest_frame(instance) ||
      lf_copy_media(instance, newer_media, sizeof(newer_media), &newer_info) !=
          LF_OK ||
      newer_info.extent_bytes != sizeof(newer_media) ||
      newer_info.identity == NULL ||
      strcmp(newer_info.identity, SAVE_MEDIA_IDENTITY) != 0 ||
      newer_info.guest_generation <= capture_info.guest_generation ||
      !save_bytes_match_literal(
          newer_media, sizeof(newer_media),
          (uint8_t)LF_BATTERY_SNAPSHOT_NEWER_BYTE) ||
      !make_save_envelope_header(&newer_header, &newer_info)) {
    goto cleanup;
  }
  failure = "newer save readback and acknowledgment";
  if (commit_save_envelope(save_path, &newer_header, newer_media, 0,
                           &host_acknowledgment) != SAVE_STAGE_COMMITTED ||
      host_acknowledgment.committed != 1 ||
      host_acknowledgment.payload != newer_media ||
      host_acknowledgment.extent_bytes != sizeof(newer_media) ||
      host_acknowledgment.guest_generation != newer_info.guest_generation ||
      !read_save_file_bytes(save_path, previous_file, sizeof(previous_file),
                            &previous_file_bytes) ||
      previous_file_bytes != sizeof(previous_file) ||
      !read_save_envelope(save_path, &previous_header, &opened_payload) ||
      opened_payload == NULL ||
      !save_bytes_match_literal(opened_payload, sizeof(newer_media),
                                (uint8_t)LF_BATTERY_SNAPSHOT_NEWER_BYTE) ||
      !encode_save_envelope_header(&newer_header, previous_encoded_header) ||
      !encode_save_envelope_header(&previous_header,
                                   opened_encoded_header) ||
      memcmp(previous_encoded_header, opened_encoded_header,
             sizeof(previous_encoded_header)) != 0 ||
      memcmp(opened_payload, newer_media, sizeof(newer_media)) != 0) {
    goto cleanup;
  }
  free(opened_payload);
  opened_payload = NULL;
  previous_payload = (uint8_t *)malloc(sizeof(newer_media));
  if (previous_payload == NULL) {
    goto cleanup;
  }
  memcpy(previous_payload, newer_media, sizeof(newer_media));
  previous_acknowledgment = host_acknowledgment;
  previous_acknowledgment_payload = host_acknowledgment.payload;
  previous_acknowledgment.payload = previous_payload;

  stage = 7;
  failure = "same-session battery restore";
  if (lf_restore_snapshot(instance, snapshot, snapshot_bytes) != LF_OK ||
      lf_copy_media(instance, restored_media, sizeof(restored_media),
                    &restored_info) != LF_OK ||
      restored_info.extent_bytes != sizeof(restored_media) ||
      restored_info.identity == NULL ||
      strcmp(restored_info.identity, SAVE_MEDIA_IDENTITY) != 0 ||
      restored_info.guest_generation != newer_info.guest_generation + 1U ||
      !save_bytes_match_literal(
          restored_media, sizeof(restored_media),
          (uint8_t)LF_BATTERY_SNAPSHOT_CAPTURE_BYTE) ||
      host_acknowledgment.payload != previous_acknowledgment_payload ||
      !save_acknowledgments_match(&host_acknowledgment,
                                  &previous_acknowledgment) ||
      !read_save_file_bytes(save_path, restored_file, sizeof(restored_file),
                            &restored_file_bytes) ||
      restored_file_bytes != previous_file_bytes ||
      memcmp(previous_file, restored_file, previous_file_bytes) != 0 ||
      !make_save_envelope_header(&restored_header, &restored_info)) {
    goto cleanup;
  }

  stage = 8;
  failure = "identical snapshot restore and unchanged generation";
  if (lf_restore_snapshot(instance, snapshot, snapshot_bytes) != LF_OK ||
      lf_copy_media(instance, identical_restored_media,
                    sizeof(identical_restored_media),
                    &identical_restored_info) != LF_OK ||
      identical_restored_info.extent_bytes != sizeof(identical_restored_media) ||
      identical_restored_info.identity == NULL ||
      strcmp(identical_restored_info.identity, SAVE_MEDIA_IDENTITY) != 0 ||
      identical_restored_info.guest_generation !=
          restored_info.guest_generation ||
      memcmp(identical_restored_media, restored_media,
             sizeof(restored_media)) != 0 ||
      !save_bytes_match_literal(
          identical_restored_media, sizeof(identical_restored_media),
          (uint8_t)LF_BATTERY_SNAPSHOT_CAPTURE_BYTE) ||
      host_acknowledgment.payload != previous_acknowledgment_payload ||
      !save_acknowledgments_match(&host_acknowledgment,
                                  &previous_acknowledgment) ||
      !read_save_file_bytes(save_path, restored_file, sizeof(restored_file),
                            &restored_file_bytes) ||
      restored_file_bytes != previous_file_bytes ||
      memcmp(previous_file, restored_file, previous_file_bytes) != 0 ||
      !only_committed_save_remains(save_path) ||
      !make_save_envelope_header(&restored_header,
                                 &identical_restored_info)) {
    goto cleanup;
  }

  stage = 9;
  failure = "battery refusal preservation vector";
  if (!exercise_battery_snapshot_refusal_cases(
          instance, snapshot, snapshot_bytes, save_path, previous_file,
          previous_file_bytes, &host_acknowledgment,
          &previous_acknowledgment, previous_acknowledgment_payload,
          &identical_restored_info, identical_restored_media, 0) ||
      !make_save_envelope_header(&restored_header,
                                 &identical_restored_info)) {
    goto cleanup;
  }

  stage = 10;
  failure = "partial prefix failure preserves newer save and acknowledgment";
  if (commit_save_envelope(save_path, &restored_header,
                           identical_restored_media, 1,
                           &host_acknowledgment) !=
          SAVE_STAGE_INJECTED_PREFIX_FAILURE ||
      host_acknowledgment.payload != previous_acknowledgment_payload ||
      !save_acknowledgments_match(&host_acknowledgment,
                                  &previous_acknowledgment) ||
      !read_save_file_bytes(save_path, restored_file, sizeof(restored_file),
                            &restored_file_bytes) ||
      restored_file_bytes != previous_file_bytes ||
      memcmp(previous_file, restored_file, previous_file_bytes) != 0 ||
      !read_save_envelope(save_path, &opened_header, &opened_payload) ||
      opened_payload == NULL ||
      !encode_save_envelope_header(&previous_header,
                                   previous_encoded_header) ||
      !encode_save_envelope_header(&opened_header, opened_encoded_header) ||
      memcmp(previous_encoded_header, opened_encoded_header,
             sizeof(previous_encoded_header)) != 0 ||
      opened_header.extent_bytes != (uint64_t)sizeof(newer_media) ||
      !save_bytes_match_literal(opened_payload, sizeof(newer_media),
                                (uint8_t)LF_BATTERY_SNAPSHOT_NEWER_BYTE) ||
      memcmp(opened_payload, newer_media, sizeof(newer_media)) != 0 ||
      memcmp(opened_payload, previous_payload, sizeof(newer_media)) != 0 ||
      !only_committed_save_remains(save_path)) {
    goto cleanup;
  }
  free(opened_payload);
  opened_payload = NULL;

  stage = 11;
  failure = "restored selected-save replacement and reopen";
  if (commit_save_envelope(save_path, &restored_header,
                           identical_restored_media, 0,
                           &host_acknowledgment) != SAVE_STAGE_COMMITTED ||
      host_acknowledgment.committed != 1 ||
      host_acknowledgment.payload != identical_restored_media ||
      host_acknowledgment.extent_bytes != sizeof(identical_restored_media) ||
      host_acknowledgment.guest_generation !=
          identical_restored_info.guest_generation ||
      !read_save_envelope(save_path, &opened_header, &opened_payload) ||
      opened_payload == NULL ||
      !encode_save_envelope_header(&restored_header,
                                   previous_encoded_header) ||
      !encode_save_envelope_header(&opened_header, opened_encoded_header) ||
      memcmp(previous_encoded_header, opened_encoded_header,
             sizeof(previous_encoded_header)) != 0 ||
      opened_header.extent_bytes != (uint64_t)sizeof(identical_restored_media) ||
      !save_bytes_match_literal(opened_payload,
                                sizeof(identical_restored_media),
                                (uint8_t)LF_BATTERY_SNAPSHOT_CAPTURE_BYTE) ||
      memcmp(opened_payload, identical_restored_media,
             sizeof(identical_restored_media)) != 0 ||
      memcmp(opened_payload, previous_payload,
             sizeof(identical_restored_media)) == 0) {
    goto cleanup;
  }
  free(opened_payload);
  opened_payload = NULL;

  stage = 12;
  failure = "independent literal replay";
  if (!battery_snapshot_advance_literal(instance, &replay_result)) {
    (void)fprintf(stderr,
                  "battery replay frame=%" PRIu64 " ticks=%" PRIu64
                  " samples=%zu rgb=%02x%02x%02x audio0=%d\n",
                  replay_result.cumulative_units,
                  replay_result.cumulative_core_ticks,
                  replay_result.audio_produced_samples, k_video[0],
                  k_video[1], k_video[2], (int)k_audio[0]);
    goto cleanup;
  }
  memset(replay_media, 0, sizeof(replay_media));
  {
    const lf_status media_status =
        lf_copy_media(instance, replay_media, sizeof(replay_media),
                      &replay_info);
    if (media_status != LF_OK ||
        replay_info.extent_bytes != sizeof(replay_media) ||
        replay_info.guest_generation <= restored_info.guest_generation ||
        !save_bytes_match_literal(
            replay_media, sizeof(replay_media),
            (uint8_t)LF_BATTERY_SNAPSHOT_REPLAY_BYTE)) {
      (void)fprintf(stderr,
                    "battery replay postcondition frame=%" PRIu64
                    " ticks=%" PRIu64 " samples=%zu media=%u generation=%" PRIu64
                    "/%" PRIu64 "\n",
                    replay_result.cumulative_units,
                    replay_result.cumulative_core_ticks,
                    replay_result.audio_produced_samples,
                    (unsigned int)replay_media[0], replay_info.guest_generation,
                    restored_info.guest_generation);
      goto cleanup;
    }
  }
  result = 1;

cleanup:
  free(opened_payload);
  free(previous_payload);
  free(snapshot);
  if (lf_destroy(&instance) != LF_OK) {
    result = 0;
  }
  if (save_path[0] != '\0' && unlink(save_path) != 0 && errno != ENOENT) {
    result = 0;
  }
  if (directory != NULL && rmdir(directory) != 0) {
    result = 0;
  }
  if (result != 0) {
    (void)printf("nesturbator_battery_snapshot: route=source "
                 "source=%s release=v0.1.12 build=nesturbator-%s "
                 "profile=nesturbator-ntsc-v1 api=1 behavior=9 state-format=3 "
                 "configuration=nesturbator-default "
                 "fixture=generated-battery-mmc1-v1 bytes=40976 "
                 "sha256=2282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9 media=full-span-8192,restored-literal "
                 "capture=2 newer=3 restored=2 replay=frame3,ticks2144280,"
                 "rgb5a5a5a,audio799 generation=changed-once,identical-unchanged "
                 "refusal-vector=continuation,media,generation,selected-save,ack "
                 "foreign=altered-mmc1,mmc3-refused "
                 "failed-replacement=prior-commit-and-ack-preserved "
                 "recovery=prior-exact,restored-selected,reopened-exact result=pass\n",
                 LIBFUTURO_NESTURBATOR_SOURCE_REVISION,
                 LIBFUTURO_NESTURBATOR_SOURCE_REVISION);
  } else {
    (void)fprintf(stderr,
                  "nesturbator_battery_snapshot: route=source stage=%d "
                  "failure=%s\n",
                  stage, failure);
  }
  return result;
}

static int run_snapshot_battery_process_capture(const char *checkpoint_path,
                                                const char *save_path) {
  allocation_tracker tracker = {0};
  uint8_t fixture[LF_NESTURBATOR_SAVE_FIXTURE_TOTAL_BYTES];
  uint8_t capture_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t capture_after_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t newer_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t selected_file[SAVE_ENVELOPE_MAX_BYTES];
  uint8_t expected_header[SAVE_ENVELOPE_HEADER_BYTES];
  uint8_t opened_header_bytes[SAVE_ENVELOPE_HEADER_BYTES];
  uint8_t *snapshot = NULL;
  uint8_t *opened_payload = NULL;
  size_t fixture_bytes = 0U;
  size_t snapshot_bytes = 0U;
  size_t selected_file_bytes = 0U;
  uint32_t supported = 0U;
  lf_instance *instance = NULL;
  lf_profile profile = {.struct_size = sizeof(profile)};
  lf_media_info capture_info = {.struct_size = sizeof(capture_info)};
  lf_media_info capture_after_info = {.struct_size = sizeof(capture_after_info)};
  lf_media_info newer_info = {.struct_size = sizeof(newer_info)};
  save_envelope_header newer_header;
  save_envelope_header opened_header;
  save_acknowledgment acknowledgment = {0};
  lf_load_result load_result = {.struct_size = sizeof(load_result)};
  FILE *checkpoint = NULL;
  char digest[65];
  uint8_t fixture_digest[32];
  size_t frame = 0U;
  int result = 1;
  const char *failure = "capability";

  if (checkpoint_path == NULL || checkpoint_path[0] == '\0' ||
      save_path == NULL || save_path[0] == '\0' ||
      lf_get_capability("nesturbator-ntsc-v1", NULL, LF_CAP_SNAPSHOT,
                        &supported) != LF_OK ||
      supported != 1U) {
    goto cleanup;
  }
  failure = "exact profile and pinned source";
  if (strcmp(LIBFUTURO_NESTURBATOR_SOURCE_REVISION,
             NESTURBATOR_EXPECTED_SOURCE_REVISION) != 0 ||
      lf_get_profile("nesturbator-ntsc-v1", NULL, &profile) != LF_OK ||
      profile.struct_size != sizeof(profile) || profile.profile_id == NULL ||
      strcmp(profile.profile_id, "nesturbator-ntsc-v1") != 0 ||
      profile.build_id == NULL ||
      strcmp(profile.build_id,
             "nesturbator-" NESTURBATOR_EXPECTED_SOURCE_REVISION) != 0 ||
      profile.api_revision != 1U || profile.behavior_revision != 9U) {
    goto cleanup;
  }
  failure = "generated MMC1 fixture identity";
  fixture_bytes = lf_build_nesturbator_save_fixture(fixture, sizeof(fixture));
  if (fixture_bytes != sizeof(fixture) ||
      !lf_nesturbator_save_fixture_sha256(fixture, fixture_bytes,
                                          fixture_digest) ||
      !lf_save_oracle_sha256_matches(fixture_digest, sizeof(fixture_digest))) {
    goto cleanup;
  }
  failure = "two successful loads in Process A";
  if (!create_test_instance(&tracker, &instance) ||
      !load_snapshot_process_content(instance, fixture, fixture_bytes) ||
      !load_snapshot_process_content(instance, fixture, fixture_bytes)) {
    goto cleanup;
  }
  failure = "R2 capture after two battery writes";
  for (frame = 0U; frame < 2U; ++frame) {
    if (!advance_save_guest_frame(instance)) {
      goto cleanup;
    }
  }
  if (lf_copy_media(instance, capture_media, sizeof(capture_media),
                    &capture_info) != LF_OK ||
      capture_info.struct_size != sizeof(capture_info) ||
      capture_info.extent_bytes != sizeof(capture_media) ||
      capture_info.identity == NULL ||
      strcmp(capture_info.identity, SAVE_MEDIA_IDENTITY) != 0 ||
      capture_info.guest_generation < 2U ||
      !save_bytes_match_literal(
          capture_media, sizeof(capture_media),
          (uint8_t)LF_BATTERY_SNAPSHOT_CAPTURE_BYTE)) {
    goto cleanup;
  }
  failure = "S2 snapshot capture";
  if (lf_get_snapshot_size(instance, &snapshot_bytes) != LF_OK ||
      snapshot_bytes <= SNAPSHOT_TEST_HEADER_BYTES) {
    goto cleanup;
  }
  snapshot = (uint8_t *)malloc(snapshot_bytes);
  if (snapshot == NULL ||
      lf_capture_snapshot(instance, snapshot, snapshot_bytes) != LF_OK ||
      !snapshot_digest_hex(snapshot, snapshot_bytes, digest) ||
      lf_copy_media(instance, capture_after_media, sizeof(capture_after_media),
                    &capture_after_info) != LF_OK ||
      capture_after_info.extent_bytes != capture_info.extent_bytes ||
      capture_after_info.guest_generation != capture_info.guest_generation ||
      capture_after_info.identity == NULL ||
      strcmp(capture_after_info.identity, SAVE_MEDIA_IDENTITY) != 0 ||
      memcmp(capture_after_media, capture_media, sizeof(capture_media)) != 0) {
    goto cleanup;
  }
  failure = "R3 guest write and host selection";
  if (!advance_save_guest_frame(instance) ||
      lf_copy_media(instance, newer_media, sizeof(newer_media), &newer_info) !=
          LF_OK ||
      newer_info.extent_bytes != sizeof(newer_media) ||
      newer_info.identity == NULL ||
      strcmp(newer_info.identity, SAVE_MEDIA_IDENTITY) != 0 ||
      newer_info.guest_generation <= capture_info.guest_generation ||
      !save_bytes_match_literal(
          newer_media, sizeof(newer_media),
          (uint8_t)LF_BATTERY_SNAPSHOT_NEWER_BYTE) ||
      !make_save_envelope_header(&newer_header, &newer_info) ||
      commit_save_envelope(save_path, &newer_header, newer_media, 0,
                           &acknowledgment) != SAVE_STAGE_COMMITTED ||
      acknowledgment.committed != 1 ||
      acknowledgment.payload != newer_media ||
      acknowledgment.extent_bytes != sizeof(newer_media) ||
      acknowledgment.guest_generation != newer_info.guest_generation ||
      !read_save_file_bytes(save_path, selected_file, sizeof(selected_file),
                            &selected_file_bytes) ||
      selected_file_bytes !=
          (size_t)SAVE_ENVELOPE_HEADER_BYTES + sizeof(newer_media) ||
      !read_save_envelope(save_path, &opened_header, &opened_payload) ||
      opened_payload == NULL ||
      !encode_save_envelope_header(&newer_header, expected_header) ||
      !encode_save_envelope_header(&opened_header, opened_header_bytes) ||
      memcmp(expected_header, opened_header_bytes, sizeof(expected_header)) !=
          0 ||
      opened_header.extent_bytes != sizeof(newer_media) ||
      !save_bytes_match_literal(opened_payload, sizeof(newer_media),
                                (uint8_t)LF_BATTERY_SNAPSHOT_NEWER_BYTE) ||
      memcmp(opened_payload, newer_media, sizeof(newer_media)) != 0 ||
      !only_committed_save_remains(save_path)) {
    goto cleanup;
  }
  free(opened_payload);
  opened_payload = NULL;
  (void)printf("event=selected-save-r3 bytes=%zu generation=%" PRIu64
               " payload=exact readback=exact result=pass\n",
               newer_info.extent_bytes, newer_info.guest_generation);
  failure = "checkpoint write and successful close";
  checkpoint = fopen(checkpoint_path, "wb");
  if (checkpoint == NULL) {
    goto cleanup;
  }
  if (fwrite(snapshot, 1U, snapshot_bytes, checkpoint) != snapshot_bytes) {
    (void)fclose(checkpoint);
    checkpoint = NULL;
    goto cleanup;
  }
  if (fclose(checkpoint) != 0) {
    checkpoint = NULL;
    goto cleanup;
  }
  checkpoint = NULL;
  (void)printf("event=checkpoint-close bytes=%zu sha256=%s\n",
               snapshot_bytes, digest);
  if (fflush(stdout) != 0 || lf_destroy(&instance) != LF_OK) {
    goto cleanup;
  }
  (void)printf("event=instance-destroyed\n");
  if (fflush(stdout) != 0 || tracker.invalid_frees != 0U ||
      tracker.live != 0U || tracker.allocations != tracker.frees) {
    goto cleanup;
  }
  (void)printf("nesturbator_snapshot_battery_process_a: loads=2 media=R2->R3 "
               "checkpoint=closed result=pass\n");
  result = 0;

cleanup:
  free(opened_payload);
  if (checkpoint != NULL) {
    (void)fclose(checkpoint);
  }
  free(snapshot);
  if (instance != NULL) {
    (void)lf_destroy(&instance);
  }
  if (result != 0) {
    (void)fprintf(stderr,
                  "nesturbator_snapshot_battery_process_a: failure=%s\n",
                  failure);
  }
  return result;
}

static int run_snapshot_battery_process_restore(const char *checkpoint_path,
                                                const char *save_path) {
  allocation_tracker tracker = {0};
  uint8_t fixture[LF_NESTURBATOR_SAVE_FIXTURE_TOTAL_BYTES];
  uint8_t initial_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t imported_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t restored_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t identical_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t replay_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t selected_file[SAVE_ENVELOPE_MAX_BYTES];
  uint8_t current_file[SAVE_ENVELOPE_MAX_BYTES];
  uint8_t expected_header[SAVE_ENVELOPE_HEADER_BYTES];
  uint8_t opened_header_bytes[SAVE_ENVELOPE_HEADER_BYTES];
  uint8_t *snapshot = NULL;
  uint8_t *selected_payload = NULL;
  uint8_t *opened_payload = NULL;
  uint8_t *b_refusal_baseline = NULL;
  size_t fixture_bytes = 0U;
  size_t snapshot_bytes = 0U;
  size_t selected_file_bytes = 0U;
  size_t current_file_bytes = 0U;
  uint32_t supported = 0U;
  lf_instance *instance = NULL;
  lf_profile profile = {.struct_size = sizeof(profile)};
  lf_load_result load_result = {.struct_size = sizeof(load_result)};
  lf_media_info initial_info = {.struct_size = sizeof(initial_info)};
  lf_media_info imported_info = {.struct_size = sizeof(imported_info)};
  lf_media_info restored_info = {.struct_size = sizeof(restored_info)};
  lf_media_info identical_info = {.struct_size = sizeof(identical_info)};
  lf_media_info replay_info = {.struct_size = sizeof(replay_info)};
  lf_run_result replay_result = {.struct_size = sizeof(replay_result)};
  save_envelope_header selected_header;
  save_envelope_header restored_header;
  save_envelope_header opened_header;
  save_acknowledgment host_acknowledgment = {0};
  save_acknowledgment selected_acknowledgment = {0};
  uint8_t fixture_digest[32];
  uint64_t imported_generation = 0U;
  char digest[65];
  int result = 1;
  const char *failure = "capability";

  if (checkpoint_path == NULL || checkpoint_path[0] == '\0' ||
      save_path == NULL || save_path[0] == '\0' ||
      lf_get_capability("nesturbator-ntsc-v1", NULL, LF_CAP_SNAPSHOT,
                        &supported) != LF_OK ||
      supported != 1U) {
    goto cleanup;
  }
  failure = "checkpoint reopen and bounded read";
  if (!exercise_sha256_known_answers() ||
      !read_snapshot_process_file(checkpoint_path, &snapshot,
                                  &snapshot_bytes) ||
      !snapshot_digest_hex(snapshot, snapshot_bytes, digest)) {
    goto cleanup;
  }
  (void)printf("event=checkpoint-reopened bytes=%zu sha256=%s\n",
               snapshot_bytes, digest);
  failure = "pinned profile and generated fixture";
  fixture_bytes = lf_build_nesturbator_save_fixture(fixture, sizeof(fixture));
  if (strcmp(LIBFUTURO_NESTURBATOR_SOURCE_REVISION,
             NESTURBATOR_EXPECTED_SOURCE_REVISION) != 0 ||
      lf_get_profile("nesturbator-ntsc-v1", NULL, &profile) != LF_OK ||
      profile.struct_size != sizeof(profile) || profile.profile_id == NULL ||
      strcmp(profile.profile_id, "nesturbator-ntsc-v1") != 0 ||
      profile.build_id == NULL ||
      strcmp(profile.build_id,
             "nesturbator-" NESTURBATOR_EXPECTED_SOURCE_REVISION) != 0 ||
      profile.api_revision != 1U || profile.behavior_revision != 9U ||
      fixture_bytes != sizeof(fixture) ||
      !lf_nesturbator_save_fixture_sha256(fixture, fixture_bytes,
                                          fixture_digest) ||
      !lf_save_oracle_sha256_matches(fixture_digest, sizeof(fixture_digest)) ||
      !create_test_instance(&tracker, &instance) ||
      !load_snapshot_process_content(instance, fixture, fixture_bytes)) {
    goto cleanup;
  }
  failure = "selected R3 readback and envelope validation";
  if (!read_save_envelope(save_path, &selected_header, &selected_payload) ||
      selected_payload == NULL ||
      strcmp(selected_header.content_identity, SAVE_CONTENT_IDENTITY) != 0 ||
      strcmp(selected_header.configuration_identity,
             SAVE_CONFIGURATION_IDENTITY) != 0 ||
      strcmp(selected_header.media_identity, SAVE_MEDIA_IDENTITY) != 0 ||
      selected_header.extent_bytes != SAVE_FIXTURE_RAM_BYTES ||
      selected_header.guest_generation == 0U ||
      !save_bytes_match_literal(selected_payload, SAVE_FIXTURE_RAM_BYTES,
                                (uint8_t)LF_BATTERY_SNAPSHOT_NEWER_BYTE) ||
      !acknowledge_committed_save(save_path, &selected_header,
                                  selected_payload, &host_acknowledgment) ||
      host_acknowledgment.committed != 1 ||
      host_acknowledgment.payload != selected_payload ||
      host_acknowledgment.extent_bytes != SAVE_FIXTURE_RAM_BYTES ||
      host_acknowledgment.guest_generation !=
          selected_header.guest_generation ||
      !read_save_file_bytes(save_path, selected_file, sizeof(selected_file),
                            &selected_file_bytes) ||
      selected_file_bytes !=
          (size_t)SAVE_ENVELOPE_HEADER_BYTES + SAVE_FIXTURE_RAM_BYTES ||
      !encode_save_envelope_header(&selected_header, expected_header) ||
      memcmp(selected_file, expected_header, sizeof(expected_header)) != 0 ||
      memcmp(selected_file + SAVE_ENVELOPE_HEADER_BYTES, selected_payload,
             SAVE_FIXTURE_RAM_BYTES) != 0 ||
      !only_committed_save_remains(save_path)) {
    goto cleanup;
  }
  selected_acknowledgment = host_acknowledgment;
  failure = "Process B initial media and import R3 before advance";
  if (lf_copy_media(instance, initial_media, sizeof(initial_media),
                    &initial_info) != LF_OK ||
      initial_info.struct_size != sizeof(initial_info) ||
      initial_info.extent_bytes != sizeof(initial_media) ||
      initial_info.guest_generation != 0U || initial_info.identity == NULL ||
      strcmp(initial_info.identity, SAVE_MEDIA_IDENTITY) != 0 ||
      !save_bytes_match_literal(initial_media, sizeof(initial_media), 0U) ||
      lf_import_media(instance, selected_header.media_identity,
                      selected_payload,
                      (size_t)selected_header.extent_bytes) != LF_OK ||
      lf_copy_media(instance, imported_media, sizeof(imported_media),
                    &imported_info) != LF_OK ||
      imported_info.struct_size != sizeof(imported_info) ||
      imported_info.extent_bytes != sizeof(imported_media) ||
      imported_info.identity == NULL ||
      strcmp(imported_info.identity, SAVE_MEDIA_IDENTITY) != 0 ||
      imported_info.guest_generation != initial_info.guest_generation ||
      memcmp(imported_media, selected_payload, sizeof(imported_media)) != 0 ||
      !save_bytes_match_literal(
          imported_media, sizeof(imported_media),
          (uint8_t)LF_BATTERY_SNAPSHOT_NEWER_BYTE) ||
      host_acknowledgment.payload != selected_payload ||
      !save_acknowledgments_match(&host_acknowledgment,
                                  &selected_acknowledgment)) {
    goto cleanup;
  }
  imported_generation = imported_info.guest_generation;
  (void)printf("event=selected-save-imported-r3 bytes=%zu generation=%" PRIu64
               " before-positive-advance=pass result=pass\n",
               imported_info.extent_bytes, imported_generation);
  failure = "cross-process restore to complete R2 span";
  if (lf_restore_snapshot(instance, snapshot, snapshot_bytes) != LF_OK ||
      lf_copy_media(instance, restored_media, sizeof(restored_media),
                    &restored_info) != LF_OK ||
      restored_info.struct_size != sizeof(restored_info) ||
      restored_info.extent_bytes != sizeof(restored_media) ||
      restored_info.identity == NULL ||
      strcmp(restored_info.identity, SAVE_MEDIA_IDENTITY) != 0 ||
      restored_info.guest_generation != imported_generation + 1U ||
      !save_bytes_match_literal(
          restored_media, sizeof(restored_media),
          (uint8_t)LF_BATTERY_SNAPSHOT_CAPTURE_BYTE) ||
      host_acknowledgment.payload != selected_payload ||
      !save_acknowledgments_match(&host_acknowledgment,
                                  &selected_acknowledgment) ||
      !read_save_file_bytes(save_path, current_file, sizeof(current_file),
                            &current_file_bytes) ||
      current_file_bytes != selected_file_bytes ||
      memcmp(current_file, selected_file, selected_file_bytes) != 0) {
    goto cleanup;
  }
  (void)printf("event=battery-restore-r2 bytes=%zu generation=%" PRIu64
               " selected-r3-preserved=pass result=pass\n",
               restored_info.extent_bytes, restored_info.guest_generation);
  failure = "identical R2 restore leaves B generation unchanged";
  if (lf_restore_snapshot(instance, snapshot, snapshot_bytes) != LF_OK ||
      lf_copy_media(instance, identical_media, sizeof(identical_media),
                    &identical_info) != LF_OK ||
      identical_info.struct_size != sizeof(identical_info) ||
      identical_info.extent_bytes != sizeof(identical_media) ||
      identical_info.identity == NULL ||
      strcmp(identical_info.identity, SAVE_MEDIA_IDENTITY) != 0 ||
      identical_info.guest_generation != restored_info.guest_generation ||
      memcmp(identical_media, restored_media, sizeof(restored_media)) != 0 ||
      !save_bytes_match_literal(
          identical_media, sizeof(identical_media),
          (uint8_t)LF_BATTERY_SNAPSHOT_CAPTURE_BYTE) ||
      host_acknowledgment.payload != selected_payload ||
      !save_acknowledgments_match(&host_acknowledgment,
                                  &selected_acknowledgment) ||
      !read_save_file_bytes(save_path, current_file, sizeof(current_file),
                            &current_file_bytes) ||
      current_file_bytes != selected_file_bytes ||
      memcmp(current_file, selected_file, selected_file_bytes) != 0 ||
      !only_committed_save_remains(save_path) ||
      !make_save_envelope_header(&restored_header, &identical_info)) {
    goto cleanup;
  }
  failure = "B-local refusal baseline and complete preservation vector";
  b_refusal_baseline = (uint8_t *)malloc(snapshot_bytes);
  if (b_refusal_baseline == NULL ||
      lf_capture_snapshot(instance, b_refusal_baseline, snapshot_bytes) !=
          LF_OK ||
      !exercise_battery_snapshot_refusal_cases(
          instance, b_refusal_baseline, snapshot_bytes, save_path,
          selected_file, selected_file_bytes, &host_acknowledgment,
          &selected_acknowledgment, selected_payload, &identical_info,
          identical_media, 1) ||
      lf_copy_media(instance, identical_media, sizeof(identical_media),
                    &identical_info) != LF_OK ||
      identical_info.struct_size != sizeof(identical_info) ||
      identical_info.extent_bytes != sizeof(identical_media) ||
      identical_info.identity == NULL ||
      strcmp(identical_info.identity, SAVE_MEDIA_IDENTITY) != 0 ||
      !save_bytes_match_literal(
          identical_media, sizeof(identical_media),
          (uint8_t)LF_BATTERY_SNAPSHOT_CAPTURE_BYTE) ||
      host_acknowledgment.payload != selected_payload ||
      !save_acknowledgments_match(&host_acknowledgment,
                                  &selected_acknowledgment) ||
      !read_save_file_bytes(save_path, current_file, sizeof(current_file),
                            &current_file_bytes) ||
      current_file_bytes != selected_file_bytes ||
      memcmp(current_file, selected_file, selected_file_bytes) != 0 ||
      !only_committed_save_remains(save_path) ||
      !make_save_envelope_header(&restored_header, &identical_info)) {
    goto cleanup;
  }
  (void)printf("event=battery-b-refusal-baseline generation=%" PRIu64
               " media=R2 selected-save=R3 result=pass\n",
               identical_info.guest_generation);
  failure = "pre-rename staging failure preserves R3 and acknowledgment";
  if (commit_save_envelope(save_path, &restored_header, identical_media, 1,
                           &host_acknowledgment) !=
          SAVE_STAGE_INJECTED_PREFIX_FAILURE ||
      host_acknowledgment.payload != selected_payload ||
      !save_acknowledgments_match(&host_acknowledgment,
                                  &selected_acknowledgment) ||
      !read_save_file_bytes(save_path, current_file, sizeof(current_file),
                            &current_file_bytes) ||
      current_file_bytes != selected_file_bytes ||
      memcmp(current_file, selected_file, selected_file_bytes) != 0 ||
      !read_save_envelope(save_path, &opened_header, &opened_payload) ||
      opened_payload == NULL ||
      !encode_save_envelope_header(&selected_header, opened_header_bytes) ||
      !encode_save_envelope_header(&opened_header, expected_header) ||
      memcmp(opened_header_bytes, expected_header,
             sizeof(opened_header_bytes)) != 0 ||
      opened_header.extent_bytes != SAVE_FIXTURE_RAM_BYTES ||
      memcmp(opened_payload, selected_payload, SAVE_FIXTURE_RAM_BYTES) != 0 ||
      !only_committed_save_remains(save_path)) {
    goto cleanup;
  }
  free(opened_payload);
  opened_payload = NULL;
  (void)printf("event=pre-rename-failure-preserved-r3 bytes=%zu ack=exact "
               "stage-cleanup=pass result=pass\n",
               selected_file_bytes);
  failure = "explicit R2 commit and exact readback before acknowledgment";
  if (commit_save_envelope(save_path, &restored_header, identical_media, 0,
                           &host_acknowledgment) != SAVE_STAGE_COMMITTED ||
      host_acknowledgment.committed != 1 ||
      host_acknowledgment.payload != identical_media ||
      host_acknowledgment.extent_bytes != sizeof(identical_media) ||
      host_acknowledgment.guest_generation !=
          identical_info.guest_generation ||
      !read_save_envelope(save_path, &opened_header, &opened_payload) ||
      opened_payload == NULL ||
      !encode_save_envelope_header(&restored_header, expected_header) ||
      !encode_save_envelope_header(&opened_header, opened_header_bytes) ||
      memcmp(expected_header, opened_header_bytes, sizeof(expected_header)) !=
          0 ||
      opened_header.extent_bytes != sizeof(identical_media) ||
      !save_bytes_match_literal(opened_payload, sizeof(identical_media),
                                (uint8_t)LF_BATTERY_SNAPSHOT_CAPTURE_BYTE) ||
      memcmp(opened_payload, identical_media, sizeof(identical_media)) != 0 ||
      memcmp(opened_payload, selected_payload, sizeof(identical_media)) == 0 ||
      !only_committed_save_remains(save_path) ||
      !read_save_file_bytes(save_path, current_file, sizeof(current_file),
                            &current_file_bytes) ||
      current_file_bytes !=
          (size_t)SAVE_ENVELOPE_HEADER_BYTES + sizeof(identical_media) ||
      memcmp(current_file, expected_header, sizeof(expected_header)) != 0 ||
      memcmp(current_file + SAVE_ENVELOPE_HEADER_BYTES, identical_media,
             sizeof(identical_media)) != 0 ||
      !save_acknowledgments_match(
          &host_acknowledgment,
          &(save_acknowledgment){.payload = identical_media,
                                 .extent_bytes = sizeof(identical_media),
                                 .guest_generation =
                                     identical_info.guest_generation,
                                 .committed = 1})) {
    goto cleanup;
  }
  free(opened_payload);
  opened_payload = NULL;
  (void)printf("event=save-r2-readback-acknowledged bytes=%zu generation=%" PRIu64
               " readback=exact result=pass\n",
               identical_info.extent_bytes,
               identical_info.guest_generation);
  failure = "independent literal continuation and full replay span";
  if (!battery_snapshot_advance_literal(instance, &replay_result) ||
      lf_copy_media(instance, replay_media, sizeof(replay_media),
                    &replay_info) != LF_OK ||
      replay_info.struct_size != sizeof(replay_info) ||
      replay_info.extent_bytes != sizeof(replay_media) ||
      replay_info.identity == NULL ||
      strcmp(replay_info.identity, SAVE_MEDIA_IDENTITY) != 0 ||
      replay_info.guest_generation != identical_info.guest_generation + 1U ||
      !save_bytes_match_literal(
          replay_media, sizeof(replay_media),
          (uint8_t)LF_BATTERY_SNAPSHOT_REPLAY_BYTE) ||
      replay_result.cumulative_units !=
          (uint64_t)LF_BATTERY_SNAPSHOT_REPLAY_FRAMES ||
      replay_result.cumulative_core_ticks !=
          (uint64_t)LF_BATTERY_SNAPSHOT_REPLAY_TICKS ||
      replay_result.audio_produced_samples !=
          (size_t)LF_BATTERY_SNAPSHOT_REPLAY_AUDIO_SAMPLES) {
    goto cleanup;
  }
  if (lf_destroy(&instance) != LF_OK) {
    goto cleanup;
  }
  if (tracker.invalid_frees != 0U || tracker.live != 0U ||
      tracker.allocations != tracker.frees) {
    goto cleanup;
  }
  (void)printf("nesturbator_snapshot_battery_process_b: loads=1 frame=3 "
               "ticks=2144280 video=5a5a5a audio=799-silence media=full-8192 "
               "selected-save=R2-readback result=pass\n");
  result = 0;

cleanup:
  free(opened_payload);
  free(selected_payload);
  free(b_refusal_baseline);
  free(snapshot);
  if (instance != NULL) {
    (void)lf_destroy(&instance);
  }
  if (result != 0) {
    (void)fprintf(stderr,
                  "nesturbator_snapshot_battery_process_b: failure=%s\n",
                  failure);
  }
  return result;
}

static int run_snapshot_battery_process_oracle_controls(
    const char *checkpoint_path, const char *save_path) {
  static const struct {
    const char *name;
    battery_snapshot_oracle_failure expected_failure;
  } cases[] = {
      {"progress", BATTERY_SNAPSHOT_ORACLE_PROGRESS},
      {"video", BATTERY_SNAPSHOT_ORACLE_VIDEO},
      {"audio", BATTERY_SNAPSHOT_ORACLE_AUDIO},
      {"media", BATTERY_SNAPSHOT_ORACLE_MEDIA},
  };
  allocation_tracker tracker = {0};
  uint8_t fixture[LF_NESTURBATOR_SAVE_FIXTURE_TOTAL_BYTES];
  uint8_t initial_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t imported_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t restored_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t replay_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t expected_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t selected_file[SAVE_ENVELOPE_MAX_BYTES];
  uint8_t current_file[SAVE_ENVELOPE_MAX_BYTES];
  uint8_t expected_header[SAVE_ENVELOPE_HEADER_BYTES];
  uint8_t fixture_digest[32];
  uint8_t *snapshot = NULL;
  uint8_t *selected_payload = NULL;
  size_t fixture_bytes = 0U;
  size_t snapshot_bytes = 0U;
  size_t selected_file_bytes = 0U;
  size_t current_file_bytes = 0U;
  uint32_t supported = 0U;
  size_t case_index = 0U;
  lf_instance *instance = NULL;
  lf_profile profile = {.struct_size = sizeof(profile)};
  lf_media_info initial_info = {.struct_size = sizeof(initial_info)};
  lf_media_info imported_info = {.struct_size = sizeof(imported_info)};
  lf_media_info restored_info = {.struct_size = sizeof(restored_info)};
  lf_media_info replay_info = {.struct_size = sizeof(replay_info)};
  lf_run_result replay_result = {.struct_size = sizeof(replay_result)};
  save_envelope_header selected_header;
  save_acknowledgment host_acknowledgment = {0};
  save_acknowledgment selected_acknowledgment = {0};
  battery_snapshot_oracle expected = {
      .buttons = 0U,
      .frames = (uint64_t)LF_BATTERY_SNAPSHOT_REPLAY_FRAMES,
      .ticks = (uint64_t)LF_BATTERY_SNAPSHOT_REPLAY_TICKS,
      .rgb = {(uint8_t)LF_BATTERY_SNAPSHOT_REPLAY_RGB_RED,
              (uint8_t)LF_BATTERY_SNAPSHOT_REPLAY_RGB_GREEN,
              (uint8_t)LF_BATTERY_SNAPSHOT_REPLAY_RGB_BLUE},
      .audio_samples = (size_t)LF_BATTERY_SNAPSHOT_REPLAY_AUDIO_SAMPLES,
      .audio_sample = (int16_t)LF_BATTERY_SNAPSHOT_REPLAY_AUDIO_SAMPLE,
      .media = expected_media,
      .media_bytes = sizeof(expected_media),
  };
  int result = 1;
  const char *failure = "capability";

  if (checkpoint_path == NULL || checkpoint_path[0] == '\0' ||
      save_path == NULL || save_path[0] == '\0' ||
      lf_get_capability("nesturbator-ntsc-v1", NULL, LF_CAP_SNAPSHOT,
                        &supported) != LF_OK ||
      supported != 1U) {
    goto cleanup;
  }
  failure = "checkpoint reopen and bounded read";
  if (!read_snapshot_process_file(checkpoint_path, &snapshot,
                                  &snapshot_bytes) ||
      snapshot_bytes <= SNAPSHOT_TEST_HEADER_BYTES) {
    goto cleanup;
  }
  failure = "exact generated fixture and one B load";
  fixture_bytes = lf_build_nesturbator_save_fixture(fixture, sizeof(fixture));
  if (strcmp(LIBFUTURO_NESTURBATOR_SOURCE_REVISION,
             NESTURBATOR_EXPECTED_SOURCE_REVISION) != 0 ||
      lf_get_profile("nesturbator-ntsc-v1", NULL, &profile) != LF_OK ||
      profile.struct_size != sizeof(profile) || profile.profile_id == NULL ||
      strcmp(profile.profile_id, "nesturbator-ntsc-v1") != 0 ||
      profile.build_id == NULL ||
      strcmp(profile.build_id,
             "nesturbator-" NESTURBATOR_EXPECTED_SOURCE_REVISION) != 0 ||
      profile.api_revision != 1U || profile.behavior_revision != 9U ||
      fixture_bytes != sizeof(fixture) ||
      !lf_nesturbator_save_fixture_sha256(fixture, fixture_bytes,
                                          fixture_digest) ||
      !lf_save_oracle_sha256_matches(fixture_digest, sizeof(fixture_digest)) ||
      !create_test_instance(&tracker, &instance) ||
      !load_snapshot_process_content(instance, fixture, fixture_bytes)) {
    goto cleanup;
  }
  failure = "read and import selected R3 before positive guest work";
  if (!read_save_envelope(save_path, &selected_header, &selected_payload) ||
      selected_payload == NULL ||
      strcmp(selected_header.content_identity, SAVE_CONTENT_IDENTITY) != 0 ||
      strcmp(selected_header.configuration_identity,
             SAVE_CONFIGURATION_IDENTITY) != 0 ||
      strcmp(selected_header.media_identity, SAVE_MEDIA_IDENTITY) != 0 ||
      selected_header.extent_bytes != SAVE_FIXTURE_RAM_BYTES ||
      selected_header.guest_generation == 0U ||
      !save_bytes_match_literal(selected_payload, SAVE_FIXTURE_RAM_BYTES,
                                (uint8_t)LF_BATTERY_SNAPSHOT_NEWER_BYTE) ||
      !acknowledge_committed_save(save_path, &selected_header,
                                  selected_payload, &host_acknowledgment) ||
      host_acknowledgment.payload != selected_payload ||
      host_acknowledgment.extent_bytes != SAVE_FIXTURE_RAM_BYTES ||
      host_acknowledgment.guest_generation !=
          selected_header.guest_generation ||
      !read_save_file_bytes(save_path, selected_file, sizeof(selected_file),
                            &selected_file_bytes) ||
      selected_file_bytes !=
          (size_t)SAVE_ENVELOPE_HEADER_BYTES + SAVE_FIXTURE_RAM_BYTES ||
      !encode_save_envelope_header(&selected_header, expected_header) ||
      memcmp(selected_file, expected_header, sizeof(expected_header)) != 0 ||
      memcmp(selected_file + SAVE_ENVELOPE_HEADER_BYTES, selected_payload,
             SAVE_FIXTURE_RAM_BYTES) != 0 ||
      lf_copy_media(instance, initial_media, sizeof(initial_media),
                    &initial_info) != LF_OK ||
      initial_info.extent_bytes != sizeof(initial_media) ||
      !save_bytes_match_literal(initial_media, sizeof(initial_media), 0U) ||
      lf_import_media(instance, selected_header.media_identity,
                      selected_payload,
                      (size_t)selected_header.extent_bytes) != LF_OK ||
      lf_copy_media(instance, imported_media, sizeof(imported_media),
                    &imported_info) != LF_OK ||
      imported_info.extent_bytes != sizeof(imported_media) ||
      imported_info.guest_generation != initial_info.guest_generation ||
      memcmp(imported_media, selected_payload, sizeof(imported_media)) != 0) {
    goto cleanup;
  }
  selected_acknowledgment = host_acknowledgment;
  failure = "exact cross-process R2 restore";
  if (lf_restore_snapshot(instance, snapshot, snapshot_bytes) != LF_OK ||
      lf_copy_media(instance, restored_media, sizeof(restored_media),
                    &restored_info) != LF_OK ||
      restored_info.extent_bytes != sizeof(restored_media) ||
      restored_info.guest_generation != imported_info.guest_generation + 1U ||
      !save_bytes_match_literal(
          restored_media, sizeof(restored_media),
          (uint8_t)LF_BATTERY_SNAPSHOT_CAPTURE_BYTE) ||
      host_acknowledgment.payload != selected_payload ||
      !save_acknowledgments_match(&host_acknowledgment,
                                  &selected_acknowledgment)) {
    goto cleanup;
  }
  failure = "successful battery oracle baseline";
  memset(expected_media, (uint8_t)LF_SAVE_ORACLE_FILL_BYTE,
         sizeof(expected_media));
  expected_media[0] = (uint8_t)LF_BATTERY_SNAPSHOT_REPLAY_BYTE;
  if (battery_snapshot_advance_expected(
          instance, &expected, &replay_result, k_video, k_audio) !=
          BATTERY_SNAPSHOT_ORACLE_NONE ||
      lf_copy_media(instance, replay_media, sizeof(replay_media),
                    &replay_info) != LF_OK ||
      replay_info.extent_bytes != sizeof(replay_media) ||
      replay_info.guest_generation != restored_info.guest_generation + 1U ||
      memcmp(replay_media, expected_media, sizeof(replay_media)) != 0 ||
      host_acknowledgment.payload != selected_payload ||
      !save_acknowledgments_match(&host_acknowledgment,
                                  &selected_acknowledgment)) {
    goto cleanup;
  }
  (void)printf("event=battery-oracle-baseline result=pass frame=%" PRIu64
               " ticks=%" PRIu64 " rgb=%02x%02x%02x audio=%zu "
               "full-media=pass\n",
               replay_result.cumulative_units,
               replay_result.cumulative_core_ticks, k_video[0], k_video[1],
               k_video[2], replay_result.audio_produced_samples);

  for (case_index = 0U; case_index < sizeof(cases) / sizeof(cases[0]);
       ++case_index) {
    battery_snapshot_oracle_failure actual_failure =
        BATTERY_SNAPSHOT_ORACLE_SETUP;
    battery_snapshot_oracle_failure expected_failure =
        cases[case_index].expected_failure;
    memset(expected_media, (uint8_t)LF_SAVE_ORACLE_FILL_BYTE,
           sizeof(expected_media));
    expected_media[0] = (uint8_t)LF_BATTERY_SNAPSHOT_REPLAY_BYTE;
    expected.frames = (uint64_t)LF_BATTERY_SNAPSHOT_REPLAY_FRAMES;
    expected.ticks = (uint64_t)LF_BATTERY_SNAPSHOT_REPLAY_TICKS;
    expected.rgb[0] = (uint8_t)LF_BATTERY_SNAPSHOT_REPLAY_RGB_RED;
    expected.rgb[1] = (uint8_t)LF_BATTERY_SNAPSHOT_REPLAY_RGB_GREEN;
    expected.rgb[2] = (uint8_t)LF_BATTERY_SNAPSHOT_REPLAY_RGB_BLUE;
    expected.audio_samples =
        (size_t)LF_BATTERY_SNAPSHOT_REPLAY_AUDIO_SAMPLES;
    expected.audio_sample =
        (int16_t)LF_BATTERY_SNAPSHOT_REPLAY_AUDIO_SAMPLE;
    if (lf_restore_snapshot(instance, snapshot, snapshot_bytes) != LF_OK ||
        lf_copy_media(instance, restored_media, sizeof(restored_media),
                      &restored_info) != LF_OK ||
        restored_info.extent_bytes != sizeof(restored_media) ||
        !save_bytes_match_literal(
            restored_media, sizeof(restored_media),
            (uint8_t)LF_BATTERY_SNAPSHOT_CAPTURE_BYTE) ||
        memcmp(restored_media, expected_media, sizeof(restored_media)) == 0) {
      goto cleanup;
    }
    if (strcmp(cases[case_index].name, "progress") == 0) {
      expected.frames += 1U;
    } else if (strcmp(cases[case_index].name, "video") == 0) {
      expected.rgb[0] ^= 1U;
    } else if (strcmp(cases[case_index].name, "audio") == 0) {
      expected.audio_samples -= 1U;
    } else if (strcmp(cases[case_index].name, "media") == 0) {
      expected_media[sizeof(expected_media) - 1U] ^= 1U;
    } else {
      goto cleanup;
    }
    actual_failure = battery_snapshot_advance_expected(
        instance, &expected, &replay_result, k_video, k_audio);
    if (actual_failure != expected_failure ||
        !read_save_file_bytes(save_path, current_file, sizeof(current_file),
                              &current_file_bytes) ||
        current_file_bytes != selected_file_bytes ||
        memcmp(current_file, selected_file, selected_file_bytes) != 0 ||
        host_acknowledgment.payload != selected_payload ||
        !save_acknowledgments_match(&host_acknowledgment,
                                    &selected_acknowledgment)) {
      (void)fprintf(stderr,
                    "battery oracle control %s expected=%d actual=%d\n",
                    cases[case_index].name, (int)expected_failure,
                    (int)actual_failure);
      goto cleanup;
    }
    (void)printf("event=battery-oracle-control name=%s expected=%s actual=%s "
                 "result=pass\n",
                 cases[case_index].name,
                 cases[case_index].name, cases[case_index].name);
  }
  if (lf_destroy(&instance) != LF_OK) {
    goto cleanup;
  }
  if (tracker.invalid_frees != 0U || tracker.live != 0U ||
      tracker.allocations != tracker.frees) {
    goto cleanup;
  }
  (void)printf("nesturbator_snapshot_battery_oracle_control: "
               "route=fresh-process progress,video,audio,full-media=rejected "
               "result=pass\n");
  result = 0;

cleanup:
  free(selected_payload);
  free(snapshot);
  if (instance != NULL) {
    (void)lf_destroy(&instance);
  }
  if (result != 0) {
    (void)fprintf(stderr,
                  "nesturbator_snapshot_battery_oracle_control: "
                  "failure=%s\n",
                  failure);
  }
  return result;
}

int main(int argc, char **argv) {
  const uint8_t *pressed_expected_rgb = k_pressed_rgb;
  if (argc == 3 && strcmp(argv[1], "--snapshot-process-capture") == 0) {
    return run_snapshot_process_capture(argv[2]);
  }
  if (argc == 3 && strcmp(argv[1], "--snapshot-process-restore") == 0) {
    return run_snapshot_process_restore(argv[2], 0);
  }
  if (argc == 4 && strcmp(argv[1], "--snapshot-process-restore") == 0 &&
      strcmp(argv[3], "--wrong-oracle") == 0) {
    return run_snapshot_process_restore(argv[2], 1);
  }
  if (argc == 4 &&
      strcmp(argv[1], "--snapshot-battery-process-capture") == 0) {
    return run_snapshot_battery_process_capture(argv[2], argv[3]);
  }
  if (argc == 4 &&
      strcmp(argv[1], "--snapshot-battery-process-restore") == 0) {
    return run_snapshot_battery_process_restore(argv[2], argv[3]);
  }
  if (argc == 4 && strcmp(argv[1],
                          "--snapshot-battery-process-oracle-controls") == 0) {
    return run_snapshot_battery_process_oracle_controls(argv[2], argv[3]);
  }
  if (argc == 3 && strcmp(argv[1], "--emit-save-fixture") == 0) {
    return emit_save_fixture(argv[2]);
  }
  if (argc == 3 && strcmp(argv[1], "--save-writer") == 0) {
    return run_save_writer(argv[2]);
  }
  if (argc == 3 && strcmp(argv[1], "--save-failed-writer") == 0) {
    return run_save_failed_writer(argv[2]);
  }
  if (argc == 3 && strcmp(argv[1], "--save-restorer") == 0) {
    return run_save_restorer(argv[2]);
  }
  if (argc == 3 && strcmp(argv[1], "--emit-fixture") == 0) {
    return emit_fixture(argv[2]);
  }
  if (argc == 2 && strcmp(argv[1], "--load-failures") == 0) {
    return exercise_load_failure_cases();
  }
  if (argc == 2 && strcmp(argv[1], "--frame-failures") == 0) {
    return exercise_frame_failures();
  }
  if (argc == 2 && strcmp(argv[1], "--snapshot-battery") == 0) {
    return exercise_battery_snapshot_recovery() ? 0 : 1;
  }
  if (argc == 2 &&
      strcmp(argv[1], "--snapshot-battery-wrong-expected") == 0) {
    return exercise_battery_snapshot_oracle_control() ? 0 : 1;
  }
  if (argc == 2 && strcmp(argv[1], "--snapshot-replay") == 0) {
    const size_t fixture_bytes = build_fixture(k_fixture, sizeof(k_fixture));
    if (fixture_bytes != FIXTURE_TOTAL_BYTES ||
        !exercise_snapshot_unloaded_and_routes() ||
        !exercise_snapshot_replay(k_fixture, fixture_bytes, k_port1_rgb)) {
      return 1;
    }
    (void)printf("nesturbator_snapshot_replay: source=%s "
                 "profile=nesturbator-ntsc-v1 fixture=generated-nrom "
                 "capability,capture,replay=frame3,ticks2144304,av-literal result=pass\n",
                 LIBFUTURO_NESTURBATOR_SOURCE_REVISION);
    return 0;
  }
  if (argc == 2 && strcmp(argv[1], "--snapshot-refusals") == 0) {
    const size_t fixture_bytes = build_fixture(k_fixture, sizeof(k_fixture));
    if (fixture_bytes != FIXTURE_TOTAL_BYTES ||
        !exercise_snapshot_battery_support() ||
        !exercise_snapshot_load_epoch_exhaustion(k_fixture, fixture_bytes) ||
        !exercise_snapshot_rejections(k_fixture, fixture_bytes) ||
        !exercise_snapshot_reload_capacity(k_fixture, fixture_bytes)) {
      return 1;
    }
    (void)printf("nesturbator_snapshot_refusals: source=%s "
                 "profile=nesturbator-ntsc-v1 fixture=generated-nrom "
                 "cases=envelope,native,foreign-content,battery,session-overflow,reloaded-capacity "
                 "continuation=literal result=pass\n",
                 LIBFUTURO_NESTURBATOR_SOURCE_REVISION);
    return 0;
  }
  if (argc == 2 && strcmp(argv[1], "--snapshot-wrong-expected") == 0) {
    const size_t fixture_bytes = build_fixture(k_fixture, sizeof(k_fixture));
    if (fixture_bytes != FIXTURE_TOTAL_BYTES) {
      return 2;
    }
    (void)fprintf(stderr, "snapshot wrong continuation oracle\n");
    if (exercise_snapshot_replay(k_fixture, fixture_bytes,
                                 k_wrong_expected_rgb)) {
      (void)fprintf(stderr,
                    "snapshot wrong continuation oracle was accepted\n");
      return 1;
    }
    return 0;
  }
  if (argc == 2 && strcmp(argv[1], "--wrong-expected-video") == 0) {
    pressed_expected_rgb = k_wrong_expected_rgb;
  } else if (argc != 1) {
    (void)fprintf(stderr, "nesturbator_session: unknown mode\n");
    return 2;
  }
  allocation_tracker tracker = {0};
  lf_create_options options = {
      .struct_size = sizeof(options),
      .allocate = tracked_allocate,
      .deallocate = tracked_deallocate,
      .allocator_context = &tracker,
  };
  lf_profile profile = {.struct_size = sizeof(profile)};
  lf_instance *instance = NULL;
  lf_instance *interleaved_instance = NULL;
  lf_instance *synthetic_instance = NULL;
  lf_load_request load_request = {0};
  lf_load_request synthetic_load_request = {
      .struct_size = sizeof(synthetic_load_request),
      .content_data = k_fixture_program,
      .content_size_bytes = sizeof(k_fixture_program),
  };
  lf_load_result load_result = {.struct_size = sizeof(load_result)};
  lf_run_request pre_load_request = {
      .struct_size = sizeof(pre_load_request),
      .work_units = 0U,
  };
  lf_run_result pre_load_result = {.struct_size = sizeof(pre_load_result)};
  uint64_t completed_frames = 0U;
  uint64_t last_ticks = 0U;
  uint64_t interleaved_frames = 0U;
  uint64_t interleaved_ticks = 0U;
  size_t last_audio_count = 0U;
  size_t retained_audio_count = 0U;
  size_t fixture_bytes = 0U;
  uint32_t supported = UINT32_MAX;
  int exit_code = 0;

  REQUIRE(strcmp(LIBFUTURO_NESTURBATOR_SOURCE_REVISION,
                 NESTURBATOR_EXPECTED_SOURCE_REVISION) == 0,
          "exact pinned source revision");
  REQUIRE(lf_get_profile("nesturbator-ntsc-v1", NULL, &profile) == LF_OK,
          "real profile query");
  REQUIRE(profile.struct_size == sizeof(profile) &&
              strcmp(profile.profile_id, "nesturbator-ntsc-v1") == 0 &&
              strcmp(profile.core_id, "nesturbator") == 0 &&
              strcmp(profile.build_id, "nesturbator-" NESTURBATOR_EXPECTED_SOURCE_REVISION) == 0 &&
              profile.api_revision == 1U && profile.behavior_revision == 9U,
          "real profile identity and exact core revisions");
  REQUIRE(profile.input_mask == UINT32_C(0x0000FFFF) &&
              profile.max_work_units == 1U &&
              profile.max_guest_units == UINT32_MAX &&
              profile.time_unit == LF_TIME_FRAME &&
              profile.input_sampling == LF_INPUT_AT_ADVANCE_START,
          "real input and frame limits");
  REQUIRE(profile.video_format == LF_VIDEO_RGB24 &&
              profile.video_width == VIDEO_WIDTH &&
              profile.video_height == VIDEO_HEIGHT &&
              profile.video_bytes_per_pixel == 3U &&
              profile.min_video_stride_bytes == VIDEO_WIDTH * 3U,
          "real RGB24 video profile");
  REQUIRE(profile.audio_encoding == LF_AUDIO_S16_NATIVE &&
              profile.audio_layout == LF_AUDIO_INTERLEAVED &&
              profile.audio_rate_numerator == 48000U &&
              profile.audio_rate_denominator == 1U &&
              profile.audio_channels == 1U &&
              profile.max_audio_samples_per_call == AUDIO_MAX_SAMPLES,
          "real audio profile");
  REQUIRE(profile.max_content_bytes == 64U * 1024U * 1024U &&
              profile.effective_configuration_id != NULL &&
              strcmp(profile.effective_configuration_id,
                     "nesturbator-default") == 0 &&
              profile.media_extent_bytes == 0U,
          "real content configuration and dynamic loaded media extent");
  REQUIRE(lf_get_capability("nesturbator-ntsc-v1", NULL,
                            LF_CAP_LOGICAL_INPUT, &supported) == LF_OK &&
              supported == 1U,
          "logical input capability");
  REQUIRE(lf_get_capability("nesturbator-ntsc-v1", NULL,
                            LF_CAP_IN_MEMORY_MEDIA_COPY, &supported) ==
              LF_OK && supported == 1U,
          "real media copy capability is supported");
  REQUIRE(check_capability(LF_CAP_SNAPSHOT, LF_OK, 1U) &&
              check_capability(LF_CAP_HARDWARE_VIDEO, LF_UNSUPPORTED, 0U) &&
              check_capability(LF_CAP_CONCURRENT_USE, LF_UNSUPPORTED, 0U),
          "qualified snapshot, hardware video, and concurrency capabilities");
  REQUIRE(exercise_snapshot_unloaded_and_routes(),
          "unloaded snapshot refusals and unsupported routes");
  REQUIRE(lf_create("synthetic-v1", &options, &synthetic_instance) == LF_OK &&
              synthetic_instance != NULL,
          "synthetic instance remains available");
  REQUIRE(lf_load(synthetic_instance, &synthetic_load_request, &load_result) ==
                  LF_UNSUPPORTED &&
              load_result.struct_size == sizeof(load_result) &&
              load_result.loaded == 0U &&
              load_result.content_size_bytes == 0U &&
              load_result.effective_configuration_id == NULL,
          "synthetic profile rejects a valid load request as unsupported");
  REQUIRE(lf_destroy(&synthetic_instance) == LF_OK &&
              synthetic_instance == NULL,
          "synthetic instance destruction after unsupported load");

  REQUIRE(lf_create("nesturbator-ntsc-v1", &options, &instance) == LF_OK &&
              instance != NULL,
          "real instance creation with caller allocator");
  REQUIRE(lf_advance(instance, &pre_load_request, &pre_load_result) ==
              LF_INVALID_ARGUMENT &&
              pre_load_result.actual_units == 0U &&
              pre_load_result.video_valid == 0U &&
              pre_load_result.audio_valid == 0U,
          "advance before successful load is rejected");

  fixture_bytes = build_fixture(k_fixture, sizeof(k_fixture));
  REQUIRE(fixture_bytes == FIXTURE_TOTAL_BYTES,
          "owned generated NROM fixture");
  REQUIRE(exercise_snapshot_battery_support(),
          "battery-backed snapshot capture and restore are supported");
  REQUIRE(exercise_snapshot_load_epoch_exhaustion(k_fixture, fixture_bytes),
          "load epoch exhaustion preserves the active machine");
  REQUIRE(exercise_snapshot_replay(k_fixture, fixture_bytes, k_port1_rgb),
          "caller-owned same-instance snapshot replay matches literal output");
  REQUIRE(exercise_snapshot_rejections(k_fixture, fixture_bytes),
          "snapshot envelope rejection preserves literal continuation");
  REQUIRE(exercise_snapshot_reload_capacity(k_fixture, fixture_bytes),
          "snapshot short capacity after reload preserves canaries and progress");
  load_request = (lf_load_request){
      .struct_size = sizeof(load_request),
      .content_data = k_fixture,
      .content_size_bytes = fixture_bytes,
      .configuration_id = NULL,
  };
  REQUIRE(lf_load(instance, &load_request, &load_result) == LF_OK &&
              load_result.struct_size == sizeof(load_result) &&
              load_result.loaded == 1U &&
              load_result.content_size_bytes == fixture_bytes &&
              load_result.effective_configuration_id != NULL &&
              strcmp(load_result.effective_configuration_id,
                     "nesturbator-default") == 0,
          "generated NROM load and effective configuration");
  memset(k_fixture, 0xA5, sizeof(k_fixture));

  {
    lf_run_request zero_request = {
        .struct_size = sizeof(zero_request),
        .work_units = 0U,
    };
    lf_run_result zero_result = {.struct_size = sizeof(zero_result)};
    REQUIRE(lf_advance(instance, &zero_request, &zero_result) == LF_OK &&
                zero_result.actual_units == 0U &&
                zero_result.cumulative_units == 0U &&
                zero_result.video_valid == 0U && zero_result.audio_valid == 0U &&
                zero_result.core_ticks_valid == 0U &&
                zero_result.video_extent_bytes == 0U &&
                zero_result.audio_produced_samples == 0U,
            "zero work succeeds without A/V buffers or guest progress");
  }

  {
    lf_run_request excess_request = {
        .struct_size = sizeof(excess_request),
        .work_units = 2U,
        .video_data = k_video,
        .video_capacity_bytes = sizeof(k_video),
        .video_stride_bytes = VIDEO_STRIDE_BYTES,
        .audio_data = k_audio,
        .audio_capacity_samples = AUDIO_MAX_SAMPLES,
    };
    lf_run_result excess_result = {.struct_size = sizeof(excess_result)};
    memset(k_video, 0xA5, sizeof(k_video));
    for (size_t sample = 0U; sample < AUDIO_MAX_SAMPLES; ++sample) {
      k_audio[sample] = INT16_C(1234);
    }
    REQUIRE(lf_advance(instance, &excess_request, &excess_result) ==
                LF_LIMIT_EXCEEDED &&
                excess_result.requested_units == 2U &&
                excess_result.actual_units == 0U &&
                excess_result.cumulative_units == 0U &&
                excess_result.core_ticks_valid == 0U &&
                excess_result.video_valid == 0U && excess_result.audio_valid == 0U,
            "two-frame request is rejected before guest execution");
    REQUIRE(bytes_equal_value(k_video, sizeof(k_video), 0xA5U) &&
                video_padding_is_untouched(k_video),
            "over-budget request leaves video canaries untouched");
    for (size_t sample = 0U; sample < AUDIO_MAX_SAMPLES; ++sample) {
      REQUIRE(k_audio[sample] == INT16_C(1234),
              "over-budget request leaves audio canaries untouched");
    }
  }

  {
    lf_input invalid_input = {
        .struct_size = sizeof(invalid_input),
        .buttons = UINT32_C(0x00010000),
    };
    REQUIRE(lf_set_input(instance, &invalid_input) == LF_INVALID_ARGUMENT,
            "real input rejects bits above both controller masks");
  }

  {
    uint8_t media_byte = 0xA5U;
    lf_media_info media_info = {.struct_size = sizeof(media_info)};
    REQUIRE(lf_copy_media(instance, &media_byte, sizeof(media_byte),
                          &media_info) == LF_UNSUPPORTED &&
                media_byte == 0xA5U && media_info.identity == NULL,
            "non-battery NROM has no media span and leaves output unchanged");
  }

  {
    lf_load_request refused_request = {
        .struct_size = sizeof(refused_request),
        .content_data = NULL,
        .content_size_bytes = fixture_bytes,
        .configuration_id = NULL,
    };
    lf_load_result refused_result = {.struct_size = sizeof(refused_result)};
    REQUIRE(lf_load(instance, &refused_request, &refused_result) ==
                LF_INVALID_ARGUMENT &&
                refused_result.loaded == 1U &&
                refused_result.content_size_bytes == fixture_bytes &&
                refused_result.effective_configuration_id != NULL &&
                strcmp(refused_result.effective_configuration_id,
                       "nesturbator-default") == 0,
            "valid refusal result preserves active load metadata");
  }

  REQUIRE(run_color_case(instance, 1U, pressed_expected_rgb, &completed_frames,
                        &last_ticks, &last_audio_count),
          "controller A selects literal pressed color");
  memcpy(k_retained_video, k_video, sizeof(k_retained_video));
  memcpy(k_retained_audio, k_audio, sizeof(k_retained_audio));
  retained_audio_count = last_audio_count;
  REQUIRE(run_color_case(instance, 0U, k_released_rgb, &completed_frames,
                        &last_ticks, &last_audio_count),
          "released controller selects literal released color");
  REQUIRE(run_color_case(instance, UINT32_C(0x00000100), k_port1_rgb,
                        &completed_frames, &last_ticks, &last_audio_count),
          "port 1 controller A selects its distinct literal color");
  REQUIRE(last_audio_count == 798U || last_audio_count == 799U,
          "final frame reports exact bounded sample count");

  {
    lf_load_request interleaved_load = {
        .struct_size = sizeof(interleaved_load),
        .content_data = k_fixture,
        .content_size_bytes = fixture_bytes,
        .configuration_id = NULL,
    };
    lf_load_result interleaved_load_result = {
        .struct_size = sizeof(interleaved_load_result),
    };
    lf_input primary_input = {
        .struct_size = sizeof(primary_input),
        .buttons = 1U,
    };
    lf_input secondary_input = {
        .struct_size = sizeof(secondary_input),
        .buttons = UINT32_C(0x00000100),
    };
    int primary_literal_seen = 0;
    int secondary_literal_seen = 0;

    fixture_bytes = build_fixture(k_fixture, sizeof(k_fixture));
    REQUIRE(fixture_bytes == FIXTURE_TOTAL_BYTES &&
                lf_create("nesturbator-ntsc-v1", &options,
                          &interleaved_instance) == LF_OK &&
                interleaved_instance != NULL,
            "independent real instance creation");
    interleaved_load.content_size_bytes = fixture_bytes;
    REQUIRE(lf_load(interleaved_instance, &interleaved_load,
                    &interleaved_load_result) == LF_OK &&
                interleaved_load_result.loaded == 1U,
            "second instance loads its own generated NROM");
    memset(k_fixture, 0xA5, sizeof(k_fixture));
    REQUIRE(lf_set_input(instance, &primary_input) == LF_OK &&
                lf_set_input(interleaved_instance, &secondary_input) == LF_OK,
            "interleaved instances receive different pending inputs");
    for (size_t attempt = 0U;
         attempt < FIXTURE_MAX_WARMUP_FRAMES &&
         (!primary_literal_seen || !secondary_literal_seen);
         ++attempt) {
      REQUIRE(advance_interleaved_frame(
                  instance, primary_input.buttons, k_pressed_rgb,
                  k_interleaved_video[0], k_interleaved_audio[0],
                  &completed_frames, &last_ticks, &primary_literal_seen),
              "first instance advances with independent input and scratch");
      REQUIRE(advance_interleaved_frame(
                  interleaved_instance, secondary_input.buttons, k_port1_rgb,
                  k_interleaved_video[1], k_interleaved_audio[1],
                  &interleaved_frames, &interleaved_ticks,
                  &secondary_literal_seen),
              "second instance advances with independent input and scratch");
    }
    REQUIRE(primary_literal_seen && secondary_literal_seen,
            "sequential instance interleaving preserves both histories");
  }

  REQUIRE(lf_destroy(&instance) == LF_OK && instance == NULL,
          "real instance destruction clears owner");
  REQUIRE(lf_destroy(&interleaved_instance) == LF_OK &&
              interleaved_instance == NULL,
          "interleaved instance destruction clears owner");
  REQUIRE(tracker.invalid_frees == 0U && tracker.live == 0U &&
              tracker.allocations == tracker.frees,
          "caller allocator reclaims core, scratch, and owner allocations");
  REQUIRE(frame_is_literal_rgb(k_retained_video, k_pressed_rgb),
          "host-owned video copy survives destruction");
  REQUIRE(retained_audio_count > 0U && k_retained_audio[0] == 0 &&
              k_retained_audio[retained_audio_count - 1U] == 0,
          "host-owned audio copy survives destruction");
  (void)printf(
      "nesturbator_session: source=%s profile=nesturbator-ntsc-v1 "
      "fixture=generated-nrom load,input,frame,av,close result=pass "
      "frames=%" PRIu64 " ticks=%" PRIu64 " audio_samples=%zu\n",
      LIBFUTURO_NESTURBATOR_SOURCE_REVISION, completed_frames, last_ticks,
      last_audio_count);
  return 0;

cleanup:
  (void)lf_destroy(&instance);
  (void)lf_destroy(&interleaved_instance);
  return exit_code;
}
