#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <libfuturo/libfuturo.h>

#include "nesturbator_save_fixture.h"
#include "nesturbator_save_oracle.h"

#define SAVE_FIXTURE_RAM_BYTES LF_SAVE_ORACLE_EXTENT_BYTES
#define SAVE_FIXTURE_EXPECTED_BYTE LF_SAVE_ORACLE_COMMITTED_BYTE
#define SAVE_FIXTURE_CONTINUATION_BYTE LF_SAVE_ORACLE_CONTINUATION_BYTE
#define SAVE_CONTENT_IDENTITY LF_SAVE_ORACLE_CONTENT_IDENTITY
#define SAVE_MEDIA_IDENTITY LF_SAVE_ORACLE_MEDIA_IDENTITY
#define SAVE_CONFIGURATION_IDENTITY LF_SAVE_ORACLE_CONFIGURATION_IDENTITY

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

#define NESTURBATOR_REVISION "2338608ab184f040620a30d17756f5e06a42d4e3"
#define FIXTURE_HEADER_BYTES 16U
#define FIXTURE_PRG_BYTES (16U * 1024U)
#define FIXTURE_CHR_BYTES (8U * 1024U)
#define FIXTURE_TOTAL_BYTES \
  (FIXTURE_HEADER_BYTES + FIXTURE_PRG_BYTES + FIXTURE_CHR_BYTES)
#define FIXTURE_VECTOR_OFFSET (FIXTURE_PRG_BYTES - 6U)
#define VIDEO_WIDTH 256U
#define VIDEO_HEIGHT 240U
#define VIDEO_ROW_PADDING_BYTES 5U
#define VIDEO_STRIDE_BYTES (VIDEO_WIDTH * 3U + VIDEO_ROW_PADDING_BYTES)
#define VIDEO_EXTENT_BYTES \
  (VIDEO_STRIDE_BYTES * (VIDEO_HEIGHT - 1U) + VIDEO_WIDTH * 3U)
#define AUDIO_MAX_SAMPLES 799U
#define FIXTURE_MAX_WARMUP_FRAMES 120U

static uint8_t k_save_fixture[LF_NESTURBATOR_SAVE_FIXTURE_TOTAL_BYTES];
static uint8_t k_video[VIDEO_EXTENT_BYTES];
static int16_t k_audio[AUDIO_MAX_SAMPLES];

static const uint8_t k_program[] = {
    0x78U, 0xD8U, 0xA2U, 0x40U, 0x8EU, 0x17U, 0x40U, 0xA9U, 0x00U,
    0x8DU, 0x15U, 0x40U, 0x8DU, 0x00U, 0x20U, 0x8DU, 0x01U, 0x20U,
    0xADU, 0x02U, 0x20U, 0xA9U, 0x3FU, 0x8DU, 0x06U, 0x20U, 0xA9U,
    0x00U, 0x8DU, 0x06U, 0x20U, 0xA9U, 0x0FU, 0x8DU, 0x07U, 0x20U,
    0xA9U, 0x20U, 0x8DU, 0x06U, 0x20U, 0xA9U, 0x00U, 0x8DU, 0x06U,
    0x20U, 0xA9U, 0x00U, 0xA0U, 0x04U, 0xA2U, 0x00U, 0x8DU, 0x07U,
    0x20U, 0xE8U, 0xD0U, 0xFAU, 0x88U, 0xD0U, 0xF5U, 0xADU, 0x02U,
    0x20U, 0x10U, 0xFBU, 0xA9U, 0x01U, 0x8DU, 0x16U, 0x40U, 0xA9U,
    0x00U, 0x8DU, 0x16U, 0x40U, 0xADU, 0x16U, 0x40U, 0x29U, 0x01U,
    0xD0U, 0x0BU, 0xADU, 0x17U, 0x40U, 0x29U, 0x01U, 0xF0U, 0x08U,
    0xA9U, 0x2BU, 0xD0U, 0x06U, 0xA9U, 0x06U, 0xD0U, 0x02U, 0xA9U,
    0x16U, 0x85U, 0x00U, 0xA9U, 0x3FU, 0x8DU, 0x06U, 0x20U, 0xA9U,
    0x00U, 0x8DU, 0x06U, 0x20U, 0xA5U, 0x00U, 0x8DU, 0x07U, 0x20U,
    0xA9U, 0x08U, 0x8DU, 0x01U, 0x20U, 0x4CU, 0x3DU, 0x80U};

static int fail(const char *message) {
  (void)fprintf(stderr, "nesturbator_installed_consumer: %s failed\n",
                message);
  return 1;
}

static size_t build_fixture(uint8_t *destination, size_t capacity) {
  const uint16_t reset_vector = UINT16_C(0x8000);
  const size_t fixture_bytes = (size_t)FIXTURE_TOTAL_BYTES;
  size_t offset = 0U;
  if (destination == NULL || capacity < fixture_bytes) {
    return 0U;
  }
  memset(destination, 0, fixture_bytes);
  destination[0] = (uint8_t)'N';
  destination[1] = (uint8_t)'E';
  destination[2] = (uint8_t)'S';
  destination[3] = 0x1AU;
  destination[4] = 1U;
  destination[5] = 1U;
  memcpy(destination + FIXTURE_HEADER_BYTES, k_program, sizeof(k_program));
  for (offset = 0U; offset < 6U; offset += 2U) {
    const size_t vector = FIXTURE_HEADER_BYTES + FIXTURE_VECTOR_OFFSET + offset;
    destination[vector] = (uint8_t)(reset_vector & UINT16_C(0x00FF));
    destination[vector + 1U] =
        (uint8_t)((reset_vector >> 8U) & UINT16_C(0x00FF));
  }
  return fixture_bytes;
}

static int frame_matches_literal(const uint8_t *video) {
  const uint8_t expected[3] = {0x69U, 0x0AU, 0x00U};
  size_t y = 0U;
  size_t x = 0U;
  for (y = 0U; y < VIDEO_HEIGHT; ++y) {
    const size_t row = y * VIDEO_STRIDE_BYTES;
    for (x = 0U; x < VIDEO_WIDTH; ++x) {
      const size_t pixel = row + x * 3U;
      if (video[pixel] != expected[0] || video[pixel + 1U] != expected[1] ||
          video[pixel + 2U] != expected[2]) {
        return 0;
      }
    }
  }
  return 1;
}

static int frame_matches_rgb(const uint8_t *video, const uint8_t rgb[3]) {
  size_t y = 0U;
  size_t x = 0U;
  if (video == NULL || rgb == NULL) {
    return 0;
  }
  for (y = 0U; y < VIDEO_HEIGHT; ++y) {
    const size_t row = y * VIDEO_STRIDE_BYTES;
    for (x = 0U; x < VIDEO_WIDTH; ++x) {
      const size_t pixel = row + x * 3U;
      if (video[pixel] != rgb[0] || video[pixel + 1U] != rgb[1] ||
          video[pixel + 2U] != rgb[2]) {
        return 0;
      }
    }
  }
  return 1;
}

static int video_padding_is_untouched(const uint8_t *video) {
  size_t y = 0U;
  size_t padding = 0U;
  for (y = 0U; y + 1U < VIDEO_HEIGHT; ++y) {
    const size_t row = y * VIDEO_STRIDE_BYTES;
    for (padding = 0U; padding < VIDEO_ROW_PADDING_BYTES; ++padding) {
      if (video[row + VIDEO_WIDTH * 3U + padding] != 0xA5U) {
        return 0;
      }
    }
  }
  return 1;
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
               "sha256=%s fixture-source=project-authored-generated-test-data "
               "notice=Apache-2.0\n",
               fixture_bytes, digest_hex);
  return 0;
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
      lf_build_nesturbator_save_fixture(k_save_fixture, sizeof(k_save_fixture));
  uint8_t digest[32];
  char digest_hex[65];
  lf_status status = LF_OK;
  if (instance == NULL || load_result == NULL || fixture_bytes == 0U) {
    (void)fprintf(stderr,
                  "nesturbator_session: generated MMC1 fixture has invalid extent\n");
    return 0;
  }
  if (!lf_nesturbator_save_fixture_sha256(k_save_fixture, fixture_bytes, digest) ||
      !lf_save_oracle_sha256_matches(digest, sizeof(digest))) {
    if (lf_nesturbator_save_fixture_sha256(k_save_fixture, fixture_bytes, digest)) {
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
  request.content_data = k_save_fixture;
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
  memset(k_save_fixture, 0xA5, sizeof(k_save_fixture));
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

static int snapshot_advance_one(lf_instance *instance, uint32_t buttons,
                               const uint8_t expected_rgb[3],
                               uint64_t expected_frames,
                               uint64_t expected_ticks,
                               lf_run_result *result_out,
                               uint8_t *video_out, int16_t *audio_out) {
  lf_run_request request = {
      .struct_size = sizeof(request),
      .work_units = 1U,
      .video_data = video_out,
      .video_capacity_bytes = VIDEO_EXTENT_BYTES,
      .video_stride_bytes = VIDEO_STRIDE_BYTES,
      .audio_data = audio_out,
      .audio_capacity_samples = AUDIO_MAX_SAMPLES,
  };
  size_t sample = 0U;
  if (instance == NULL || expected_rgb == NULL || result_out == NULL ||
      video_out == NULL || audio_out == NULL) {
    return 0;
  }
  memset(video_out, 0xA5, VIDEO_EXTENT_BYTES);
  for (sample = 0U; sample < AUDIO_MAX_SAMPLES; ++sample) {
    audio_out[sample] = INT16_C(1234);
  }
  *result_out = (lf_run_result){.struct_size = sizeof(*result_out)};
  if (lf_advance(instance, &request, result_out) != LF_OK ||
      result_out->requested_units != 1U || result_out->actual_units != 1U ||
      result_out->overshoot_units != 0U ||
      result_out->sampled_buttons != buttons ||
      result_out->cumulative_units != expected_frames ||
      result_out->cumulative_core_ticks != expected_ticks ||
      result_out->stop_reason != LF_STOP_BUDGET_REACHED ||
      result_out->video_valid != 1U || result_out->audio_valid != 1U ||
      result_out->time_unit != LF_TIME_FRAME ||
      result_out->core_ticks_valid != 1U ||
      result_out->core_tick_time_unit != LF_TIME_NES_HALF_MASTER_TICK ||
      result_out->video_format != LF_VIDEO_RGB24 ||
      result_out->video_width != VIDEO_WIDTH ||
      result_out->video_height != VIDEO_HEIGHT ||
      result_out->video_stride_bytes != VIDEO_STRIDE_BYTES ||
      result_out->video_extent_bytes != VIDEO_EXTENT_BYTES ||
      result_out->audio_encoding != LF_AUDIO_S16_NATIVE ||
      result_out->audio_layout != LF_AUDIO_INTERLEAVED ||
      result_out->audio_channels != 1U ||
      (result_out->audio_produced_samples != 798U &&
       result_out->audio_produced_samples != 799U) ||
      !frame_matches_rgb(video_out, expected_rgb) ||
      !video_padding_is_untouched(video_out)) {
    return 0;
  }
  for (sample = 0U; sample < result_out->audio_produced_samples; ++sample) {
    if (audio_out[sample] != 0) {
      return 0;
    }
  }
  for (sample = result_out->audio_produced_samples;
       sample < AUDIO_MAX_SAMPLES; ++sample) {
    if (audio_out[sample] != INT16_C(1234)) {
      return 0;
    }
  }
  return 1;
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
    lf_run_result *result_out, uint8_t *video_out, int16_t *audio_out) {
  lf_run_request request = {
      .struct_size = sizeof(request),
      .work_units = 1U,
      .video_data = video_out,
      .video_capacity_bytes = VIDEO_EXTENT_BYTES,
      .video_stride_bytes = VIDEO_STRIDE_BYTES,
      .audio_data = audio_out,
      .audio_capacity_samples = AUDIO_MAX_SAMPLES,
  };
  uint8_t actual_media[SAVE_FIXTURE_RAM_BYTES];
  lf_media_info media_info = {.struct_size = sizeof(media_info)};
  size_t sample = 0U;
  if (instance == NULL || expected == NULL || result_out == NULL ||
      video_out == NULL || audio_out == NULL || expected->media == NULL ||
      expected->media_bytes != sizeof(actual_media)) {
    return BATTERY_SNAPSHOT_ORACLE_SETUP;
  }
  memset(video_out, 0xA5, VIDEO_EXTENT_BYTES);
  for (sample = 0U; sample < AUDIO_MAX_SAMPLES; ++sample) {
    audio_out[sample] = INT16_C(1234);
  }
  *result_out = (lf_run_result){.struct_size = sizeof(*result_out)};
  if (lf_advance(instance, &request, result_out) != LF_OK ||
      result_out->struct_size != sizeof(*result_out) ||
      result_out->requested_units != 1U || result_out->actual_units != 1U ||
      result_out->overshoot_units != 0U ||
      result_out->sampled_buttons != expected->buttons ||
      result_out->stop_reason != LF_STOP_BUDGET_REACHED ||
      result_out->video_valid != 1U || result_out->audio_valid != 1U ||
      result_out->time_unit != LF_TIME_FRAME ||
      result_out->core_ticks_valid != 1U ||
      result_out->core_tick_time_unit != LF_TIME_NES_HALF_MASTER_TICK ||
      result_out->video_format != LF_VIDEO_RGB24 ||
      result_out->video_width != VIDEO_WIDTH ||
      result_out->video_height != VIDEO_HEIGHT ||
      result_out->video_stride_bytes != VIDEO_STRIDE_BYTES ||
      result_out->video_extent_bytes != VIDEO_EXTENT_BYTES ||
      result_out->audio_encoding != LF_AUDIO_S16_NATIVE ||
      result_out->audio_layout != LF_AUDIO_INTERLEAVED ||
      result_out->audio_channels != 1U ||
      (result_out->audio_produced_samples != 798U &&
       result_out->audio_produced_samples != 799U) ||
      !video_padding_is_untouched(video_out)) {
    return BATTERY_SNAPSHOT_ORACLE_SETUP;
  }
  if (result_out->cumulative_units != expected->frames ||
      result_out->cumulative_core_ticks != expected->ticks) {
    return BATTERY_SNAPSHOT_ORACLE_PROGRESS;
  }
  if (!frame_matches_rgb(video_out, expected->rgb)) {
    return BATTERY_SNAPSHOT_ORACLE_VIDEO;
  }
  if (result_out->audio_produced_samples != expected->audio_samples) {
    return BATTERY_SNAPSHOT_ORACLE_AUDIO;
  }
  for (sample = 0U; sample < result_out->audio_produced_samples; ++sample) {
    if (audio_out[sample] != expected->audio_sample) {
      return BATTERY_SNAPSHOT_ORACLE_AUDIO;
    }
  }
  for (sample = result_out->audio_produced_samples;
       sample < AUDIO_MAX_SAMPLES; ++sample) {
    if (audio_out[sample] != INT16_C(1234)) {
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
                                            lf_run_result *result_out,
                                            uint8_t *video_out,
                                            int16_t *audio_out) {
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
             instance, &expected, result_out, video_out, audio_out) ==
         BATTERY_SNAPSHOT_ORACLE_NONE;
}

enum {
  BATTERY_SNAPSHOT_HEADER_BYTES = 212U,
  BATTERY_SNAPSHOT_TOTAL_SIZE_OFFSET = 16U,
  BATTERY_SNAPSHOT_HEADER_SIZE_OFFSET = 12U,
  BATTERY_SNAPSHOT_STATE_FORMAT_OFFSET = 32U,
  BATTERY_SNAPSHOT_CORE_ABI_OFFSET = 36U,
  BATTERY_SNAPSHOT_BEHAVIOR_REVISION_OFFSET = 40U,
  BATTERY_SNAPSHOT_BUILD_ID_OFFSET = 44U,
  BATTERY_SNAPSHOT_PROFILE_ID_OFFSET = 108U,
  BATTERY_SNAPSHOT_CONFIGURATION_ID_OFFSET = 140U,
  BATTERY_SNAPSHOT_LOAD_EPOCH_OFFSET = 172U,
  BATTERY_SNAPSHOT_NATIVE_STATE_ROM_CRC_OFFSET = 24U,
  BATTERY_SNAPSHOT_NATIVE_STATE_HEADER_BYTES = 64U,
};

static void battery_snapshot_put_uint(uint8_t *destination, size_t width,
                                      uint64_t value) {
  size_t index = 0U;
  for (index = 0U; index < width; ++index) {
    destination[index] = (uint8_t)(value >> (unsigned int)(index * 8U));
  }
}

static uint64_t battery_snapshot_get_uint(const uint8_t *source, size_t width) {
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
  uint8_t opened_encoded_header[SAVE_ENVELOPE_HEADER_BYTES];
  uint8_t *opened_payload = NULL;
  size_t before_file_bytes = 0U;
  size_t after_file_bytes = 0U;
  lf_media_info before_info = {.struct_size = sizeof(before_info)};
  lf_media_info after_info = {.struct_size = sizeof(after_info)};
  lf_media_info replay_info = {.struct_size = sizeof(replay_info)};
  lf_media_info reset_info = {.struct_size = sizeof(reset_info)};
  lf_run_result replay_result = {.struct_size = sizeof(replay_result)};
  save_envelope_header opened_header;
  save_acknowledgment acknowledgment_before = {0};
  lf_status status = LF_OK;
  int result = 0;
  size_t candidate_call = 0U;
  (void)reaches_native;

  if (instance == NULL || baseline == NULL ||
      (candidate == NULL && candidate_bytes != 0U) || snapshot_bytes == 0U ||
      candidate_calls == 0U || case_name == NULL ||
      save_path == NULL || selected_file == NULL ||
      selected_file_bytes == 0U || host_acknowledgment == NULL ||
      expected_acknowledgment == NULL ||
      expected_acknowledgment_pointer == NULL || expected_generation >
          UINT64_MAX - 2U) {
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

  for (candidate_call = 0U; candidate_call < candidate_calls;
       ++candidate_call) {
    status = lf_restore_snapshot(instance, candidate, candidate_bytes);
    if (status != expected_status) {
      (void)fprintf(stderr,
                    "battery snapshot refusal %s call=%zu: status=%d expected=%d\n",
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
  }

  if (!battery_snapshot_advance_literal(instance, &replay_result, k_video,
                                        k_audio) ||
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
  size_t extent_bytes;
  int xor_byte;
  lf_status expected_status;
  int reaches_native;
  size_t repetitions;
} battery_snapshot_refusal_case;

static int battery_snapshot_refuses_unqualified_route(
    lf_instance *instance, const uint8_t *qualified_snapshot,
    size_t snapshot_bytes, uint8_t *probe) {
  size_t required_bytes = SIZE_MAX;
  size_t index = 0U;
  if (instance == NULL || qualified_snapshot == NULL || probe == NULL ||
      snapshot_bytes == 0U ||
      lf_get_snapshot_size(instance, &required_bytes) != LF_UNSUPPORTED ||
      required_bytes != SIZE_MAX) {
    return 0;
  }
  memset(probe, 0xA5, snapshot_bytes);
  if (lf_capture_snapshot(instance, probe, snapshot_bytes) != LF_UNSUPPORTED) {
    return 0;
  }
  for (index = 0U; index < snapshot_bytes; ++index) {
    if (probe[index] != 0xA5U) {
      return 0;
    }
  }
  if (lf_restore_snapshot(instance, qualified_snapshot, snapshot_bytes) !=
      LF_UNSUPPORTED) {
    return 0;
  }
  return 1;
}

static int advance_unqualified_pair(lf_instance *subject,
                                    lf_instance *control) {
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
  size_t sample = 0U;
  control_request.video_data = control_video;
  control_request.audio_data = control_audio;
  memset(subject_video, 0xA5, sizeof(subject_video));
  memset(control_video, 0xA5, sizeof(control_video));
  for (sample = 0U; sample < AUDIO_MAX_SAMPLES; ++sample) {
    subject_audio[sample] = INT16_C(1234);
    control_audio[sample] = INT16_C(1234);
  }
  if (lf_advance(subject, &subject_request, &subject_result) != LF_OK ||
      lf_advance(control, &control_request, &control_result) != LF_OK ||
      subject_result.requested_units != control_result.requested_units ||
      subject_result.actual_units != control_result.actual_units ||
      subject_result.overshoot_units != control_result.overshoot_units ||
      subject_result.sampled_buttons != control_result.sampled_buttons ||
      subject_result.cumulative_units != control_result.cumulative_units ||
      subject_result.time_unit != control_result.time_unit ||
      subject_result.cumulative_core_ticks !=
          control_result.cumulative_core_ticks ||
      subject_result.core_ticks_valid != control_result.core_ticks_valid ||
      subject_result.core_tick_time_unit !=
          control_result.core_tick_time_unit ||
      subject_result.stop_reason != control_result.stop_reason ||
      subject_result.video_valid != control_result.video_valid ||
      subject_result.audio_valid != control_result.audio_valid ||
      subject_result.video_extent_bytes !=
          control_result.video_extent_bytes ||
      subject_result.audio_produced_samples !=
          control_result.audio_produced_samples ||
      memcmp(subject_video, control_video, sizeof(subject_video)) != 0 ||
      memcmp(subject_audio, control_audio, sizeof(subject_audio)) != 0) {
    return 0;
  }
  return 1;
}

static int exercise_battery_snapshot_refusal_cases(
    lf_instance *instance, const uint8_t *baseline, size_t snapshot_bytes,
    const char *save_path, const uint8_t *selected_file,
    size_t selected_file_bytes, save_acknowledgment *host_acknowledgment,
    const save_acknowledgment *expected_acknowledgment,
    const uint8_t *expected_acknowledgment_pointer,
    lf_media_info *endpoint_info, uint8_t endpoint_media[SAVE_FIXTURE_RAM_BYTES]) {
  static const battery_snapshot_refusal_case cases[] = {
      {"bad magic", 0U, 0U, 0U, 0U, 1, LF_INVALID_ARGUMENT, 0, 2U},
      {"bad header size", BATTERY_SNAPSHOT_HEADER_SIZE_OFFSET, 4U,
       BATTERY_SNAPSHOT_HEADER_BYTES - 1U, 0U, 0, LF_INVALID_ARGUMENT, 0, 1U},
      {"truncated header", 0U, 0U, 0U,
       BATTERY_SNAPSHOT_HEADER_BYTES - 1U, 0, LF_INVALID_ARGUMENT, 0, 1U},
      {"truncated payload", 0U, 0U, 0U, SIZE_MAX, 0,
       LF_INVALID_ARGUMENT, 0, 1U},
      {"build identity mismatch", BATTERY_SNAPSHOT_BUILD_ID_OFFSET, 0U,
       0U, 0U, 1, LF_INVALID_ARGUMENT, 0, 1U},
      {"profile identity mismatch", BATTERY_SNAPSHOT_PROFILE_ID_OFFSET, 0U,
       0U, 0U, 1, LF_INVALID_ARGUMENT, 0, 1U},
      {"configuration identity mismatch",
       BATTERY_SNAPSHOT_CONFIGURATION_ID_OFFSET, 0U, 0U, 0U, 1,
       LF_INVALID_ARGUMENT, 0, 1U},
      {"successful-load session mismatch",
       BATTERY_SNAPSHOT_LOAD_EPOCH_OFFSET, 8U, 0U, 0U, 0,
       LF_INVALID_ARGUMENT, 0, 1U},
      {"oversized declared envelope", BATTERY_SNAPSHOT_TOTAL_SIZE_OFFSET,
       8U, UINT64_MAX, 0U, 0, LF_LIMIT_EXCEEDED, 0, 1U},
      {"corrupt native payload", SIZE_MAX, 0U, 0U, 0U, 1,
       LF_INVALID_ARGUMENT, 1, 1U},
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
          BATTERY_SNAPSHOT_HEADER_BYTES || save_path == NULL ||
      selected_file == NULL || host_acknowledgment == NULL ||
      expected_acknowledgment == NULL ||
      expected_acknowledgment_pointer == NULL || endpoint_info == NULL ||
      endpoint_media == NULL || endpoint_info->guest_generation >
          UINT64_MAX - 2U * (sizeof(cases) / sizeof(cases[0]) + 2U)) {
    return 0;
  }
  candidate = (uint8_t *)malloc(snapshot_bytes);
  if (candidate == NULL) {
    goto cleanup;
  }
  expected_generation = endpoint_info->guest_generation;
  for (case_index = 0U; case_index < sizeof(cases) / sizeof(cases[0]);
       ++case_index) {
    const battery_snapshot_refusal_case *test_case = &cases[case_index];
    size_t repetition = 0U;
    for (repetition = 0U; repetition < test_case->repetitions; ++repetition) {
      size_t candidate_bytes = snapshot_bytes;
      memcpy(candidate, baseline, snapshot_bytes);
      if (test_case->offset == SIZE_MAX) {
        candidate[snapshot_bytes - 1U] ^= 1U;
      } else if (strcmp(test_case->name,
                        "successful-load session mismatch") == 0) {
        const uint64_t epoch = battery_snapshot_get_uint(
            baseline + BATTERY_SNAPSHOT_LOAD_EPOCH_OFFSET, 8U);
        battery_snapshot_put_uint(candidate + test_case->offset,
                                  test_case->width, epoch + 1U);
      } else if (test_case->width != 0U) {
        battery_snapshot_put_uint(candidate + test_case->offset,
                                  test_case->width, test_case->value);
      } else if (test_case->xor_byte != 0) {
        candidate[test_case->offset] ^= 1U;
      }
      if (test_case->extent_bytes == SIZE_MAX) {
        candidate_bytes = snapshot_bytes - 1U;
      } else if (test_case->extent_bytes != 0U) {
        candidate_bytes = test_case->extent_bytes;
      }
      if (!battery_snapshot_refusal_preserves(
              instance, baseline, snapshot_bytes, candidate, candidate_bytes,
              1U, test_case->expected_status, test_case->reaches_native,
              test_case->name, expected_generation, save_path, selected_file,
              selected_file_bytes, host_acknowledgment,
              expected_acknowledgment, expected_acknowledgment_pointer)) {
        goto cleanup;
      }
      expected_generation += 2U;
    }
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
      foreign == NULL ||
      lf_create("nesturbator-ntsc-v1", NULL, &foreign_control) != LF_OK ||
      foreign_control == NULL) {
    goto cleanup;
  }
  foreign_snapshot = (uint8_t *)malloc(snapshot_bytes);
  if (foreign_snapshot == NULL) {
    goto cleanup;
  }
  foreign_load_request.content_data = alternate_fixture;
  foreign_load_request.content_size_bytes = alternate_fixture_bytes;
  if (lf_load(foreign, &foreign_load_request, &foreign_load_result) != LF_OK ||
      foreign_load_result.struct_size != sizeof(foreign_load_result) ||
      foreign_load_result.loaded != 1U ||
      foreign_load_result.content_size_bytes != positive_fixture_bytes ||
      foreign_load_result.effective_configuration_id == NULL ||
      strcmp(foreign_load_result.effective_configuration_id,
             SAVE_CONFIGURATION_IDENTITY) != 0 ||
      lf_load(foreign_control, &foreign_load_request,
              &foreign_control_load_result) != LF_OK ||
      foreign_control_load_result.struct_size !=
          sizeof(foreign_control_load_result) ||
      foreign_control_load_result.loaded != 1U ||
      foreign_control_load_result.content_size_bytes != positive_fixture_bytes ||
      foreign_control_load_result.effective_configuration_id == NULL ||
      strcmp(foreign_control_load_result.effective_configuration_id,
             SAVE_CONFIGURATION_IDENTITY) != 0 ||
      !advance_unqualified_pair(foreign, foreign_control) ||
      !advance_unqualified_pair(foreign, foreign_control) ||
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
    goto cleanup;
  }
  if (!advance_unqualified_pair(foreign, foreign_control) ||
      lf_copy_media(foreign, foreign_media, sizeof(foreign_media),
                    &foreign_info) != LF_OK ||
      lf_copy_media(foreign_control, foreign_control_media,
                    sizeof(foreign_control_media),
                    &foreign_control_info) != LF_OK ||
      foreign_info.extent_bytes != sizeof(foreign_media) ||
      foreign_control_info.extent_bytes != sizeof(foreign_control_media) ||
      memcmp(foreign_media, foreign_control_media,
             sizeof(foreign_media)) != 0) {
    goto cleanup;
  }

  /* MMC3 exposes battery RAM too, but only the generated MMC1 image is
     qualified for battery-backed snapshots in this profile. */
  alternate_fixture[6] = 0x42U;
  foreign_load_request.content_data = alternate_fixture;
  if (lf_load(foreign, &foreign_load_request, &foreign_load_result) != LF_OK ||
      foreign_load_result.loaded != 1U ||
      lf_load(foreign_control, &foreign_load_request,
              &foreign_control_load_result) != LF_OK ||
      foreign_control_load_result.loaded != 1U ||
      lf_copy_media(foreign, foreign_media, sizeof(foreign_media),
                    &foreign_info) != LF_OK ||
      lf_copy_media(foreign_control, foreign_control_media,
                    sizeof(foreign_control_media),
                    &foreign_control_info) != LF_OK ||
      foreign_info.extent_bytes != sizeof(foreign_media) ||
      foreign_control_info.extent_bytes != sizeof(foreign_control_media) ||
      memcmp(foreign_media, foreign_control_media,
             sizeof(foreign_media)) != 0 ||
      !save_bytes_match_literal(foreign_media, sizeof(foreign_media), 0U) ||
      !battery_snapshot_refuses_unqualified_route(
          foreign, baseline, snapshot_bytes, foreign_snapshot) ||
      !advance_unqualified_pair(foreign, foreign_control) ||
      lf_copy_media(foreign, foreign_media, sizeof(foreign_media),
                    &foreign_info) != LF_OK ||
      lf_copy_media(foreign_control, foreign_control_media,
                    sizeof(foreign_control_media),
                    &foreign_control_info) != LF_OK ||
      foreign_info.extent_bytes != sizeof(foreign_media) ||
      foreign_control_info.extent_bytes != sizeof(foreign_control_media) ||
      memcmp(foreign_media, foreign_control_media,
             sizeof(foreign_media)) != 0) {
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
  uint8_t video[VIDEO_EXTENT_BYTES];
  int16_t audio[AUDIO_MAX_SAMPLES];
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
      snapshot_bytes <= BATTERY_SNAPSHOT_HEADER_BYTES) {
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
        instance, &expected, &run_result, video, audio);
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
                 "route=installed progress,video,audio,media=rejected result=pass\n");
  }
  return result;
}

static int snapshot_run_until_rgb(lf_instance *instance, uint32_t buttons,
                                  const uint8_t expected_rgb[3],
                                  uint64_t initial_frames,
                                  uint64_t initial_ticks,
                                  lf_run_result *last_result) {
  lf_input input = {.struct_size = sizeof(input), .buttons = buttons};
  uint8_t video[VIDEO_EXTENT_BYTES];
  int16_t audio[AUDIO_MAX_SAMPLES];
  uint64_t frames = initial_frames;
  uint64_t ticks = initial_ticks;
  size_t attempt = 0U;
  if (instance == NULL || expected_rgb == NULL || last_result == NULL ||
      lf_set_input(instance, &input) != LF_OK) {
    return 0;
  }
  for (attempt = 0U; attempt < (size_t)FIXTURE_MAX_WARMUP_FRAMES; ++attempt) {
    lf_run_request request = {
        .struct_size = sizeof(request),
        .work_units = 1U,
        .video_data = video,
        .video_capacity_bytes = sizeof(video),
        .video_stride_bytes = VIDEO_STRIDE_BYTES,
        .audio_data = audio,
        .audio_capacity_samples = AUDIO_MAX_SAMPLES,
    };
    lf_run_result result = {.struct_size = sizeof(result)};
    size_t sample = 0U;
    memset(video, 0xA5, sizeof(video));
    for (sample = 0U; sample < AUDIO_MAX_SAMPLES; ++sample) {
      audio[sample] = INT16_C(1234);
    }
    if (lf_advance(instance, &request, &result) != LF_OK ||
        result.requested_units != 1U || result.actual_units != 1U ||
        result.overshoot_units != 0U || result.sampled_buttons != buttons ||
        result.cumulative_units != frames + 1U ||
        result.stop_reason != LF_STOP_BUDGET_REACHED ||
        result.video_valid != 1U || result.audio_valid != 1U ||
        result.time_unit != LF_TIME_FRAME || result.core_ticks_valid != 1U ||
        result.core_tick_time_unit != LF_TIME_NES_HALF_MASTER_TICK ||
        result.cumulative_core_ticks <= ticks ||
        result.video_format != LF_VIDEO_RGB24 ||
        result.video_width != VIDEO_WIDTH || result.video_height != VIDEO_HEIGHT ||
        result.video_stride_bytes != VIDEO_STRIDE_BYTES ||
        result.video_extent_bytes != VIDEO_EXTENT_BYTES ||
        result.audio_encoding != LF_AUDIO_S16_NATIVE ||
        result.audio_layout != LF_AUDIO_INTERLEAVED ||
        result.audio_channels != 1U ||
        (result.audio_produced_samples != 798U &&
         result.audio_produced_samples != 799U) ||
        !video_padding_is_untouched(video)) {
      return 0;
    }
    for (sample = 0U; sample < result.audio_produced_samples; ++sample) {
      if (audio[sample] != 0) {
        return 0;
      }
    }
    for (sample = result.audio_produced_samples;
         sample < AUDIO_MAX_SAMPLES; ++sample) {
      if (audio[sample] != INT16_C(1234)) {
        return 0;
      }
    }
    frames = result.cumulative_units;
    ticks = result.cumulative_core_ticks;
    *last_result = result;
    if (frame_matches_rgb(video, expected_rgb)) {
      return 1;
    }
  }
  return 0;
}

static int snapshot_results_equal(const lf_run_result *left,
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

static int snapshot_buffer_has_byte(const uint8_t *buffer, size_t bytes,
                                    uint8_t expected) {
  size_t index = 0U;
  for (index = 0U; index < bytes; ++index) {
    if (buffer[index] != expected) {
      return 0;
    }
  }
  return 1;
}

static int snapshot_refusal_preserves(lf_instance *subject,
                                      lf_instance *control,
                                      const uint8_t *baseline,
                                      size_t snapshot_bytes,
                                      const uint8_t *candidate,
                                      size_t candidate_bytes,
                                      lf_status expected_status) {
  static const uint8_t expected_rgb[3] = {0x41U, 0xE5U, 0xA1U};
  lf_run_result subject_result = {.struct_size = sizeof(subject_result)};
  lf_run_result control_result = {.struct_size = sizeof(control_result)};
  uint8_t subject_video[VIDEO_EXTENT_BYTES];
  uint8_t control_video[VIDEO_EXTENT_BYTES];
  int16_t subject_audio[AUDIO_MAX_SAMPLES];
  int16_t control_audio[AUDIO_MAX_SAMPLES];
  return lf_restore_snapshot(subject, baseline, snapshot_bytes) == LF_OK &&
         lf_restore_snapshot(control, baseline, snapshot_bytes) == LF_OK &&
         lf_restore_snapshot(subject, candidate, candidate_bytes) ==
             expected_status &&
         snapshot_advance_one(subject, UINT32_C(0x00000100), expected_rgb,
                              UINT64_C(3), UINT64_C(2144304), &subject_result,
                              subject_video, subject_audio) &&
         snapshot_advance_one(control, UINT32_C(0x00000100), expected_rgb,
                              UINT64_C(3), UINT64_C(2144304), &control_result,
                              control_video, control_audio) &&
         snapshot_results_equal(&subject_result, &control_result) &&
         memcmp(subject_video, control_video, sizeof(subject_video)) == 0 &&
         memcmp(subject_audio, control_audio, sizeof(subject_audio)) == 0;
}

static int snapshot_create_loaded(lf_instance **instance,
                                  const uint8_t *fixture,
                                  size_t fixture_bytes) {
  lf_load_request request = {
      .struct_size = sizeof(request),
      .content_data = fixture,
      .content_size_bytes = fixture_bytes,
      .configuration_id = NULL,
  };
  lf_load_result result = {.struct_size = sizeof(result)};
  return lf_create("nesturbator-ntsc-v1", NULL, instance) == LF_OK &&
         *instance != NULL && lf_load(*instance, &request, &result) == LF_OK &&
         result.loaded == 1U && result.content_size_bytes == fixture_bytes &&
         result.effective_configuration_id != NULL &&
         strcmp(result.effective_configuration_id, "nesturbator-default") == 0;
}

static int snapshot_process_load(lf_instance *instance,
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
         result.struct_size == sizeof(result) && result.loaded == 1U &&
         result.content_size_bytes == fixture_bytes &&
         result.effective_configuration_id != NULL &&
         strcmp(result.effective_configuration_id,
                "nesturbator-default") == 0;
}

enum {
  INSTALLED_SNAPSHOT_HEADER_BYTES = 388U,
  INSTALLED_SNAPSHOT_VERSION_OFFSET = 8U,
  INSTALLED_SNAPSHOT_HEADER_SIZE_OFFSET = 12U,
  INSTALLED_SNAPSHOT_TOTAL_SIZE_OFFSET = 16U,
  INSTALLED_SNAPSHOT_NATIVE_SIZE_OFFSET = 24U,
  INSTALLED_SNAPSHOT_STATE_FORMAT_OFFSET = 32U,
  INSTALLED_SNAPSHOT_CORE_ABI_OFFSET = 36U,
  INSTALLED_SNAPSHOT_BEHAVIOR_REVISION_OFFSET = 40U,
  INSTALLED_SNAPSHOT_CORE_BUILD_ID_OFFSET = 44U,
  INSTALLED_SNAPSHOT_LIBFUTURO_BUILD_ID_OFFSET = 108U,
  INSTALLED_SNAPSHOT_PROFILE_ID_OFFSET = 188U,
  INSTALLED_SNAPSHOT_CONFIGURATION_ID_OFFSET = 220U,
  INSTALLED_SNAPSHOT_OPTIONS_ID_OFFSET = 252U,
  INSTALLED_SNAPSHOT_CONTENT_DIGEST_OFFSET = 284U,
  INSTALLED_SNAPSHOT_CONTENT_SIZE_OFFSET = 356U,
  INSTALLED_SNAPSHOT_CUMULATIVE_FRAMES_OFFSET = 364U,
  INSTALLED_SNAPSHOT_PENDING_BUTTONS_OFFSET = 380U,
  INSTALLED_SNAPSHOT_FLAGS_OFFSET = 384U,
  INSTALLED_SNAPSHOT_MAX_BYTES = 128U * 1024U * 1024U
};

typedef enum installed_snapshot_extent_kind {
  INSTALLED_SNAPSHOT_EXTENT_EXACT = 0,
  INSTALLED_SNAPSHOT_EXTENT_EMPTY = 1,
  INSTALLED_SNAPSHOT_EXTENT_HEADER_MINUS_ONE = 2,
  INSTALLED_SNAPSHOT_EXTENT_SNAPSHOT_MINUS_ONE = 3,
  INSTALLED_SNAPSHOT_EXTENT_ABOVE_MAXIMUM = 4,
  INSTALLED_SNAPSHOT_EXTENT_SIZE_MAXIMUM = 5
} installed_snapshot_extent_kind;

typedef struct installed_snapshot_rejection_case {
  const char *name;
  size_t offset;
  size_t width;
  uint64_t value;
  installed_snapshot_extent_kind extent_kind;
  int xor_byte;
  lf_status expected_status;
} installed_snapshot_rejection_case;

typedef enum installed_battery_process_extent_kind {
  INSTALLED_BATTERY_EXTENT_EXACT = 0,
  INSTALLED_BATTERY_EXTENT_EMPTY = 1,
  INSTALLED_BATTERY_EXTENT_HEADER_MINUS_ONE = 2,
  INSTALLED_BATTERY_EXTENT_SNAPSHOT_MINUS_ONE = 3,
  INSTALLED_BATTERY_EXTENT_TRAILING_BYTE = 4
} installed_battery_process_extent_kind;

typedef struct installed_battery_process_refusal_case {
  const char *name;
  size_t offset;
  size_t width;
  uint64_t value;
  installed_battery_process_extent_kind extent_kind;
  int xor_byte;
  int null_candidate;
  size_t repetitions;
} installed_battery_process_refusal_case;

static const char *installed_snapshot_status_name(lf_status status) {
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

static void installed_snapshot_put_uint(uint8_t *destination, size_t width,
                                        uint64_t value) {
  size_t index = 0U;
  for (index = 0U; index < width; ++index) {
    destination[index] = (uint8_t)(value >> (unsigned int)(index * 8U));
  }
}

static uint64_t installed_snapshot_get_uint(const uint8_t *source,
                                            size_t width) {
  uint64_t value = 0U;
  size_t index = 0U;
  for (index = 0U; index < width; ++index) {
    value |= (uint64_t)source[index] << (unsigned int)(index * 8U);
  }
  return value;
}

static int exercise_snapshot_process_refusal_matrix(const uint8_t *fixture,
                                                    size_t fixture_bytes) {
  static const uint8_t warmup_rgb[3] = {0x41U, 0xE5U, 0xA1U};
  static const installed_snapshot_rejection_case cases[] = {
      {.name = "empty_extent",
       .extent_kind = INSTALLED_SNAPSHOT_EXTENT_EMPTY,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "truncated_header",
       .extent_kind = INSTALLED_SNAPSHOT_EXTENT_HEADER_MINUS_ONE,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "truncated_snapshot",
       .extent_kind = INSTALLED_SNAPSHOT_EXTENT_SNAPSHOT_MINUS_ONE,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "oversized_extent",
       .extent_kind = INSTALLED_SNAPSHOT_EXTENT_ABOVE_MAXIMUM,
       .expected_status = LF_LIMIT_EXCEEDED},
      {.name = "extent_overflow",
       .extent_kind = INSTALLED_SNAPSHOT_EXTENT_SIZE_MAXIMUM,
       .expected_status = LF_LIMIT_EXCEEDED},
      {.name = "encoded_total_overflow",
       .offset = INSTALLED_SNAPSHOT_TOTAL_SIZE_OFFSET,
       .width = 8U,
       .value = UINT64_MAX,
       .expected_status = LF_LIMIT_EXCEEDED},
      {.name = "declared_total_mismatch",
       .offset = INSTALLED_SNAPSHOT_TOTAL_SIZE_OFFSET,
       .width = 8U,
       .value = UINT64_C(1),
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "native_extent_mismatch",
       .offset = INSTALLED_SNAPSHOT_NATIVE_SIZE_OFFSET,
       .width = 8U,
       .value = UINT64_MAX,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "bad_magic",
       .offset = 0U,
       .xor_byte = 1,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "bad_header_extent",
       .offset = INSTALLED_SNAPSHOT_HEADER_SIZE_OFFSET,
       .width = 4U,
       .value = INSTALLED_SNAPSHOT_HEADER_BYTES - 1U,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "unsupported_version",
       .offset = INSTALLED_SNAPSHOT_VERSION_OFFSET,
       .width = 4U,
       .value = 3U,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "native_state_format",
       .offset = INSTALLED_SNAPSHOT_STATE_FORMAT_OFFSET,
       .width = 4U,
       .value = 99U,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "core_abi",
       .offset = INSTALLED_SNAPSHOT_CORE_ABI_OFFSET,
       .width = 4U,
       .value = 99U,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "behavior_revision",
       .offset = INSTALLED_SNAPSHOT_BEHAVIOR_REVISION_OFFSET,
       .width = 4U,
       .value = 99U,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "core_build",
       .offset = INSTALLED_SNAPSHOT_CORE_BUILD_ID_OFFSET,
       .xor_byte = 1,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "libfuturo_build",
       .offset = INSTALLED_SNAPSHOT_LIBFUTURO_BUILD_ID_OFFSET,
       .xor_byte = 1,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "profile",
       .offset = INSTALLED_SNAPSHOT_PROFILE_ID_OFFSET,
       .xor_byte = 1,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "configuration",
       .offset = INSTALLED_SNAPSHOT_CONFIGURATION_ID_OFFSET,
       .xor_byte = 1,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "options",
       .offset = INSTALLED_SNAPSHOT_OPTIONS_ID_OFFSET,
       .xor_byte = 1,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "content_extent",
       .offset = INSTALLED_SNAPSHOT_CONTENT_SIZE_OFFSET,
       .width = 8U,
       .value = UINT64_MAX,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "frame_overflow",
       .offset = INSTALLED_SNAPSHOT_CUMULATIVE_FRAMES_OFFSET,
       .width = 8U,
       .value = UINT64_MAX,
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "pending_input",
       .offset = INSTALLED_SNAPSHOT_PENDING_BUTTONS_OFFSET,
       .width = 4U,
       .value = UINT64_C(0x00010000),
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "continuation_flags",
       .offset = INSTALLED_SNAPSHOT_FLAGS_OFFSET,
       .width = 4U,
       .value = UINT64_C(0x80000000),
       .expected_status = LF_INVALID_ARGUMENT},
      {.name = "native_payload_corrupt",
       .offset = SIZE_MAX,
       .xor_byte = 1,
       .expected_status = LF_INVALID_ARGUMENT},
  };
  lf_instance *subject = NULL;
  lf_instance *control = NULL;
  lf_instance *foreign = NULL;
  lf_run_result subject_warmup = {.struct_size = sizeof(subject_warmup)};
  lf_run_result control_warmup = {.struct_size = sizeof(control_warmup)};
  size_t snapshot_bytes = 0U;
  size_t foreign_snapshot_bytes = 0U;
  size_t foreign_fixture_bytes = 0U;
  uint8_t *baseline = NULL;
  uint8_t *candidate = NULL;
  uint8_t *foreign_fixture = NULL;
  uint8_t *foreign_snapshot = NULL;
  uint8_t fixture_digest[32];
  uint8_t foreign_digest[32];
  size_t case_index = 0U;
  int result = 0;

  if (fixture == NULL || fixture_bytes != (size_t)FIXTURE_TOTAL_BYTES ||
      (fixture[6] & 0x02U) != 0U ||
      !snapshot_create_loaded(&subject, fixture, fixture_bytes) ||
      !snapshot_create_loaded(&control, fixture, fixture_bytes) ||
      !snapshot_run_until_rgb(subject, UINT32_C(0x00000100), warmup_rgb, 0U,
                              0U, &subject_warmup) ||
      !snapshot_run_until_rgb(control, UINT32_C(0x00000100), warmup_rgb, 0U,
                              0U, &control_warmup) ||
      !snapshot_results_equal(&subject_warmup, &control_warmup) ||
      lf_get_snapshot_size(subject, &snapshot_bytes) != LF_OK) {
    goto cleanup;
  }
  baseline = (uint8_t *)malloc(snapshot_bytes);
  candidate = (uint8_t *)malloc(snapshot_bytes);
  if (baseline == NULL || candidate == NULL ||
      lf_capture_snapshot(subject, baseline, snapshot_bytes) != LF_OK) {
    goto cleanup;
  }
  for (case_index = 0U; case_index < sizeof(cases) / sizeof(cases[0]);
       ++case_index) {
    const installed_snapshot_rejection_case *test_case = &cases[case_index];
    size_t candidate_bytes = snapshot_bytes;
    memcpy(candidate, baseline, snapshot_bytes);
    if (strcmp(test_case->name, "declared_total_mismatch") == 0) {
      installed_snapshot_put_uint(candidate + test_case->offset,
                                  test_case->width,
                                  (uint64_t)snapshot_bytes - 1U);
    } else if (test_case->offset == SIZE_MAX) {
      candidate[snapshot_bytes - 1U] ^= 1U;
    } else if (test_case->width != 0U) {
      installed_snapshot_put_uint(candidate + test_case->offset,
                                  test_case->width, test_case->value);
    } else if (test_case->xor_byte) {
      candidate[test_case->offset] ^= 1U;
    }
    switch (test_case->extent_kind) {
    case INSTALLED_SNAPSHOT_EXTENT_EMPTY:
      candidate_bytes = 0U;
      break;
    case INSTALLED_SNAPSHOT_EXTENT_HEADER_MINUS_ONE:
      candidate_bytes = INSTALLED_SNAPSHOT_HEADER_BYTES - 1U;
      break;
    case INSTALLED_SNAPSHOT_EXTENT_SNAPSHOT_MINUS_ONE:
      candidate_bytes = snapshot_bytes - 1U;
      break;
    case INSTALLED_SNAPSHOT_EXTENT_ABOVE_MAXIMUM:
      candidate_bytes = (size_t)INSTALLED_SNAPSHOT_MAX_BYTES + 1U;
      break;
    case INSTALLED_SNAPSHOT_EXTENT_SIZE_MAXIMUM:
      candidate_bytes = SIZE_MAX;
      break;
    case INSTALLED_SNAPSHOT_EXTENT_EXACT:
    default:
      break;
    }
    if (!snapshot_refusal_preserves(subject, control, baseline, snapshot_bytes,
                                    candidate, candidate_bytes,
                                    test_case->expected_status)) {
      goto cleanup;
    }
    (void)printf("event=snapshot-case name=%s status=%s result=pass "
                 "continuation=literal route=public-api\n",
                 test_case->name,
                 installed_snapshot_status_name(test_case->expected_status));
  }

  foreign_fixture = (uint8_t *)malloc(fixture_bytes);
  if (foreign_fixture == NULL ||
      !lf_nesturbator_save_fixture_sha256(fixture, fixture_bytes,
                                         fixture_digest)) {
    goto cleanup;
  }
  memcpy(foreign_fixture, fixture, fixture_bytes);
  foreign_fixture[FIXTURE_HEADER_BYTES + FIXTURE_PRG_BYTES] ^= 1U;
  foreign_fixture_bytes = fixture_bytes;
  if (foreign_fixture_bytes != fixture_bytes ||
      (foreign_fixture[6] & 0x02U) != 0U ||
      !lf_nesturbator_save_fixture_sha256(foreign_fixture,
                                         foreign_fixture_bytes,
                                         foreign_digest) ||
      memcmp(fixture_digest, foreign_digest, sizeof(fixture_digest)) == 0 ||
      !snapshot_create_loaded(&foreign, foreign_fixture,
                              foreign_fixture_bytes) ||
      lf_get_snapshot_size(foreign, &foreign_snapshot_bytes) != LF_OK ||
      foreign_snapshot_bytes != snapshot_bytes) {
    goto cleanup;
  }
  foreign_snapshot = (uint8_t *)malloc(snapshot_bytes);
  if (foreign_snapshot == NULL ||
      lf_capture_snapshot(foreign, foreign_snapshot, snapshot_bytes) != LF_OK ||
      !snapshot_refusal_preserves(subject, control, baseline, snapshot_bytes,
                                  foreign_snapshot, snapshot_bytes,
                                  LF_INVALID_ARGUMENT)) {
    goto cleanup;
  }
  (void)printf("event=snapshot-case name=content_digest "
               "status=invalid-argument result=pass "
               "continuation=literal route=public-api\n");
  (void)printf("event=snapshot-content-control bytes=%zu same_length=pass "
               "different_sha256=pass battery_free=pass "
               "profile=nesturbator-ntsc-v1 "
               "configuration=nesturbator-default route_eligible=pass\n",
               foreign_fixture_bytes);
  result = 1;

cleanup:
  free(foreign_snapshot);
  free(foreign_fixture);
  free(candidate);
  free(baseline);
  if (lf_destroy(&foreign) != LF_OK || lf_destroy(&control) != LF_OK ||
      lf_destroy(&subject) != LF_OK) {
    result = 0;
  }
  return result;
}

static int run_snapshot_process_capture(const char *path) {
  static const uint8_t warmup_rgb[3] = {0x41U, 0xE5U, 0xA1U};
  uint8_t fixture[FIXTURE_TOTAL_BYTES];
  uint8_t *snapshot = NULL;
  lf_instance *instance = NULL;
  lf_run_result warmup = {.struct_size = sizeof(warmup)};
  FILE *file = NULL;
  size_t fixture_bytes = build_fixture(fixture, sizeof(fixture));
  size_t snapshot_bytes = 0U;
  int result = 1;
  uint32_t supported = 0U;

  if (lf_get_capability("nesturbator-ntsc-v1", NULL, LF_CAP_SNAPSHOT,
                        &supported) != LF_OK ||
      supported != 1U) {
    goto cleanup;
  }

  if (strcmp(LIBFUTURO_NESTURBATOR_SOURCE_REVISION,
             NESTURBATOR_REVISION) != 0 || path == NULL || path[0] == '\0' ||
      fixture_bytes != sizeof(fixture) ||
      lf_create("nesturbator-ntsc-v1", NULL, &instance) != LF_OK ||
      instance == NULL ||
      !snapshot_process_load(instance, fixture, fixture_bytes) ||
      /* Capture after two successful loads to prove the epoch is local to A. */
      !snapshot_process_load(instance, fixture, fixture_bytes) ||
      !snapshot_run_until_rgb(instance, UINT32_C(0x00000100), warmup_rgb,
                              0U, 0U, &warmup) ||
      lf_get_snapshot_size(instance, &snapshot_bytes) != LF_OK ||
      snapshot_bytes <= 388U) {
    goto cleanup;
  }
  snapshot = (uint8_t *)malloc(snapshot_bytes);
  if (snapshot == NULL ||
      lf_capture_snapshot(instance, snapshot, snapshot_bytes) != LF_OK) {
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
  (void)printf("event=checkpoint-close bytes=%zu\n", snapshot_bytes);
  if (fflush(stdout) != 0 || lf_destroy(&instance) != LF_OK) {
    goto cleanup;
  }
  (void)printf("event=instance-destroyed\n");
  if (fflush(stdout) != 0) {
    goto cleanup;
  }
  (void)printf("nesturbator_snapshot_process_a: loads=2 frames=%" PRIu64
               " ticks=%" PRIu64 " result=pass\n",
               warmup.cumulative_units, warmup.cumulative_core_ticks);
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

static int run_snapshot_process_restore(const char *path, int wrong_oracle) {
  static const uint8_t expected_rgb[3] = {0x41U, 0xE5U, 0xA1U};
  static const uint8_t wrong_rgb[3] = {0x40U, 0xE5U, 0xA1U};
  uint8_t fixture[FIXTURE_TOTAL_BYTES];
  uint8_t video[VIDEO_EXTENT_BYTES];
  int16_t audio[AUDIO_MAX_SAMPLES];
  uint8_t *snapshot = NULL;
  lf_instance *instance = NULL;
  lf_run_result continuation = {.struct_size = sizeof(continuation)};
  const uint8_t *oracle_rgb = wrong_oracle ? wrong_rgb : expected_rgb;
  size_t snapshot_bytes = 0U;
  size_t fixture_bytes = 0U;
  int wrong_oracle_rejected = 0;
  int result = 1;
  uint32_t supported = 0U;

  if (lf_get_capability("nesturbator-ntsc-v1", NULL, LF_CAP_SNAPSHOT,
                        &supported) != LF_OK ||
      supported != 1U) {
    goto cleanup;
  }

  if (strcmp(LIBFUTURO_NESTURBATOR_SOURCE_REVISION,
             NESTURBATOR_REVISION) != 0 ||
      !read_snapshot_process_file(path, &snapshot, &snapshot_bytes)) {
    goto cleanup;
  }
  (void)printf("event=checkpoint-reopened bytes=%zu\n", snapshot_bytes);
  if (fflush(stdout) != 0) {
    goto cleanup;
  }
  fixture_bytes = build_fixture(fixture, sizeof(fixture));
  if (fixture_bytes != sizeof(fixture) ||
      lf_create("nesturbator-ntsc-v1", NULL, &instance) != LF_OK ||
      instance == NULL ||
      !snapshot_process_load(instance, fixture, fixture_bytes) ||
      lf_restore_snapshot(instance, snapshot, snapshot_bytes) != LF_OK) {
    goto cleanup;
  }
  if (!wrong_oracle) {
    (void)printf("event=snapshot-case name=valid_exact_extent status=ok "
                 "result=pass continuation=literal route=public-api\n");
  }
  if (!snapshot_advance_one(instance, UINT32_C(0x00000100), oracle_rgb,
                            UINT64_C(3), UINT64_C(2144304), &continuation,
                            video, audio)) {
    wrong_oracle_rejected = wrong_oracle;
    goto cleanup;
  }
  if (wrong_oracle || continuation.audio_produced_samples != 799U) {
    goto cleanup;
  }
  if (!exercise_snapshot_process_refusal_matrix(fixture, fixture_bytes)) {
    goto cleanup;
  }
  if (lf_destroy(&instance) != LF_OK) {
    goto cleanup;
  }
  (void)printf("nesturbator_snapshot_process_b: frame=3 ticks=2144304 "
               "video=41e5a1 audio=799-silence result=pass\n");
  result = 0;

cleanup:
  if (instance != NULL && lf_destroy(&instance) != LF_OK) {
    wrong_oracle_rejected = 0;
  }
  free(snapshot);
  if (wrong_oracle_rejected) {
    (void)printf("event=wrong-oracle-rejected\n");
    result = 1;
  } else if (result != 0) {
    (void)fprintf(stderr,
                  "nesturbator_snapshot_process_b: restore lifecycle failed\n");
  }
  return result;
}

static int exercise_installed_snapshot(void) {
  static const uint8_t warmup_rgb[3] = {0x41U, 0xE5U, 0xA1U};
  static const uint8_t pressed_rgb[3] = {0x69U, 0x0AU, 0x00U};
  uint8_t fixture[FIXTURE_TOTAL_BYTES];
  uint8_t foreign_fixture[FIXTURE_TOTAL_BYTES];
  lf_instance *subject = NULL;
  lf_instance *control = NULL;
  lf_instance *foreign = NULL;
  lf_run_result subject_warmup = {.struct_size = sizeof(subject_warmup)};
  lf_run_result control_warmup = {.struct_size = sizeof(control_warmup)};
  lf_run_result original_result = {.struct_size = sizeof(original_result)};
  lf_run_result control_result = {.struct_size = sizeof(control_result)};
  lf_run_result replay_result = {.struct_size = sizeof(replay_result)};
  uint8_t subject_video[VIDEO_EXTENT_BYTES];
  uint8_t control_video[VIDEO_EXTENT_BYTES];
  uint8_t replay_video[VIDEO_EXTENT_BYTES];
  int16_t subject_audio[AUDIO_MAX_SAMPLES];
  int16_t control_audio[AUDIO_MAX_SAMPLES];
  int16_t replay_audio[AUDIO_MAX_SAMPLES];
  uint8_t *snapshot = NULL;
  uint8_t *snapshot_copy = NULL;
  uint8_t *short_buffer = NULL;
  uint8_t *candidate = NULL;
  uint8_t *foreign_snapshot = NULL;
  size_t fixture_bytes = build_fixture(fixture, sizeof(fixture));
  size_t snapshot_bytes = 0U;
  size_t repeated_snapshot_bytes = 0U;
  size_t foreign_snapshot_bytes = 0U;
  uint32_t supported = UINT32_MAX;
  size_t refusal_cases = 0U;
  int stage = 1;
  int result = 0;

  if (strcmp(LIBFUTURO_NESTURBATOR_SOURCE_REVISION,
             NESTURBATOR_REVISION) != 0 || fixture_bytes != sizeof(fixture)) {
    goto cleanup;
  }
  if (lf_get_capability("nesturbator-ntsc-v1", NULL, LF_CAP_SNAPSHOT,
                        &supported) != LF_OK || supported != 1U) {
    goto cleanup;
  }
  supported = UINT32_MAX;
  if (lf_get_capability("nesturbator-ntsc-v1", "nesturbator-default",
                        LF_CAP_SNAPSHOT, &supported) != LF_UNSUPPORTED ||
      supported != 0U) {
    goto cleanup;
  }
  stage = 2;
  if (!snapshot_create_loaded(&subject, fixture, fixture_bytes) ||
      !snapshot_create_loaded(&control, fixture, fixture_bytes)) {
    goto cleanup;
  }
  stage = 3;
  if (!snapshot_run_until_rgb(subject, UINT32_C(0x00000100), warmup_rgb,
                              0U, 0U, &subject_warmup)) {
    goto cleanup;
  }
  stage = 4;
  if (!snapshot_run_until_rgb(control, UINT32_C(0x00000100), warmup_rgb,
                              0U, 0U, &control_warmup) ||
      subject_warmup.cumulative_units != control_warmup.cumulative_units ||
      subject_warmup.cumulative_core_ticks !=
          control_warmup.cumulative_core_ticks ||
      subject_warmup.audio_produced_samples !=
          control_warmup.audio_produced_samples ||
      lf_get_snapshot_size(subject, &snapshot_bytes) != LF_OK ||
      snapshot_bytes <= 212U) {
    goto cleanup;
  }
  stage = 5;
  snapshot = (uint8_t *)malloc(snapshot_bytes);
  snapshot_copy = (uint8_t *)malloc(snapshot_bytes);
  short_buffer = (uint8_t *)malloc(snapshot_bytes);
  candidate = (uint8_t *)malloc(snapshot_bytes);
  if (snapshot == NULL || snapshot_copy == NULL || short_buffer == NULL ||
      candidate == NULL ||
      lf_capture_snapshot(subject, snapshot, snapshot_bytes) != LF_OK ||
      lf_get_snapshot_size(subject, &repeated_snapshot_bytes) != LF_OK ||
      repeated_snapshot_bytes != snapshot_bytes) {
    goto cleanup;
  }
  stage = 6;
  memset(short_buffer, 0xA5, snapshot_bytes);
  if (lf_capture_snapshot(subject, short_buffer, snapshot_bytes - 1U) !=
          LF_BUFFER_TOO_SMALL ||
      !snapshot_buffer_has_byte(short_buffer, snapshot_bytes, 0xA5U) ||
      lf_capture_snapshot(subject, snapshot_copy, snapshot_bytes) != LF_OK ||
      memcmp(snapshot, snapshot_copy, snapshot_bytes) != 0 ||
      lf_restore_snapshot(subject, snapshot, snapshot_bytes) != LF_OK ||
      lf_capture_snapshot(subject, snapshot_copy, snapshot_bytes) != LF_OK ||
      memcmp(snapshot, snapshot_copy, snapshot_bytes) != 0) {
    goto cleanup;
  }
  stage = 7;
  if (!snapshot_advance_one(subject, UINT32_C(0x00000100), warmup_rgb,
                            UINT64_C(3), UINT64_C(2144304), &original_result,
                            subject_video, subject_audio) ||
      !snapshot_advance_one(control, UINT32_C(0x00000100), warmup_rgb,
                            UINT64_C(3), UINT64_C(2144304), &control_result,
                            control_video, control_audio) ||
      !snapshot_results_equal(&original_result, &control_result) ||
      memcmp(subject_video, control_video, sizeof(subject_video)) != 0 ||
      memcmp(subject_audio, control_audio, sizeof(subject_audio)) != 0) {
    goto cleanup;
  }
  stage = 8;
  {
    lf_input changed = {.struct_size = sizeof(changed), .buttons = 1U};
    lf_run_result changed_result = {.struct_size = sizeof(changed_result)};
    if (lf_set_input(subject, &changed) != LF_OK) {
      stage = 81;
      goto cleanup;
    }
    if (!snapshot_run_until_rgb(subject, 1U, pressed_rgb,
                                original_result.cumulative_units,
                                original_result.cumulative_core_ticks,
                                &changed_result)) {
      stage = 82;
      goto cleanup;
    }
    if (lf_restore_snapshot(subject, snapshot, snapshot_bytes) != LF_OK) {
      stage = 83;
      goto cleanup;
    }
    if (lf_capture_snapshot(subject, snapshot_copy, snapshot_bytes) != LF_OK ||
        memcmp(snapshot, snapshot_copy, snapshot_bytes) != 0) {
      stage = 84;
      goto cleanup;
    }
    if (!snapshot_advance_one(subject, UINT32_C(0x00000100), warmup_rgb,
                              UINT64_C(3), UINT64_C(2144304), &replay_result,
                              replay_video, replay_audio)) {
      stage = 85;
      goto cleanup;
    }
    if (!snapshot_results_equal(&original_result, &replay_result) ||
        memcmp(subject_video, replay_video, sizeof(subject_video)) != 0 ||
        memcmp(subject_audio, replay_audio, sizeof(subject_audio)) != 0) {
      stage = 86;
      goto cleanup;
    }
  }

  stage = 9;
  memcpy(candidate, snapshot, snapshot_bytes);
  candidate[8U] ^= 1U;
  if (!snapshot_refusal_preserves(subject, control, snapshot, snapshot_bytes,
                                  candidate, snapshot_bytes,
                                  LF_INVALID_ARGUMENT)) {
    goto cleanup;
  }
  ++refusal_cases;
  stage = 10;
  if (!snapshot_refusal_preserves(subject, control, snapshot, snapshot_bytes,
                                  snapshot, snapshot_bytes - 1U,
                                  LF_INVALID_ARGUMENT)) {
    goto cleanup;
  }
  ++refusal_cases;
  stage = 11;
  memcpy(candidate, snapshot, snapshot_bytes);
  candidate[172U] ^= 1U;
  if (!snapshot_refusal_preserves(subject, control, snapshot, snapshot_bytes,
                                  candidate, snapshot_bytes,
                                  LF_INVALID_ARGUMENT)) {
    goto cleanup;
  }
  ++refusal_cases;
  stage = 12;
  memcpy(candidate, snapshot, snapshot_bytes);
  candidate[snapshot_bytes - 1U] ^= 1U;
  if (!snapshot_refusal_preserves(subject, control, snapshot, snapshot_bytes,
                                  candidate, snapshot_bytes,
                                  LF_INVALID_ARGUMENT)) {
    goto cleanup;
  }
  ++refusal_cases;

  stage = 13;
  memcpy(foreign_fixture, fixture, fixture_bytes);
  foreign_fixture[FIXTURE_HEADER_BYTES + FIXTURE_PRG_BYTES] ^= 1U;
  if (!snapshot_create_loaded(&foreign, foreign_fixture, fixture_bytes) ||
      lf_get_snapshot_size(foreign, &foreign_snapshot_bytes) != LF_OK ||
      foreign_snapshot_bytes != snapshot_bytes) {
    goto cleanup;
  }
  foreign_snapshot = (uint8_t *)malloc(snapshot_bytes);
  if (foreign_snapshot == NULL ||
      lf_capture_snapshot(foreign, foreign_snapshot, snapshot_bytes) != LF_OK ||
      !snapshot_refusal_preserves(subject, control, snapshot, snapshot_bytes,
                                  foreign_snapshot, snapshot_bytes,
                                  LF_INVALID_ARGUMENT)) {
    goto cleanup;
  }
  ++refusal_cases;
  result = refusal_cases == 5U;

cleanup:
  if (result == 0) {
    (void)fprintf(stderr, "nesturbator_snapshot_installed_consumer: stage=%d refusals=%zu\n",
                  stage, refusal_cases);
  }
  free(foreign_snapshot);
  free(candidate);
  free(short_buffer);
  free(snapshot_copy);
  free(snapshot);
  if (lf_destroy(&foreign) != LF_OK || lf_destroy(&control) != LF_OK ||
      lf_destroy(&subject) != LF_OK) {
    result = 0;
  }
  if (result != 0) {
    (void)printf("nesturbator_snapshot_installed_consumer: source=%s "
                 "profile=nesturbator-ntsc-v1 configuration=nesturbator-default "
                 "fixture=generated-battery-free-nrom-v1 replay=frame3,ticks2144304,av-literal "
                 "refusals=5,continuation-preserved result=pass\n",
                 NESTURBATOR_REVISION);
  }
  return result;
}

static int exercise_installed_battery_snapshot_recovery(void) {
  char directory_template[] = "/tmp/libfuturo-battery-snapshot-installed-XXXXXX";
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
  uint8_t video[VIDEO_EXTENT_BYTES];
  int16_t audio[AUDIO_MAX_SAMPLES];
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
             NESTURBATOR_REVISION) != 0 ||
      lf_get_profile("nesturbator-ntsc-v1", NULL, &profile) != LF_OK ||
      profile.struct_size != sizeof(profile) || profile.profile_id == NULL ||
      strcmp(profile.profile_id, "nesturbator-ntsc-v1") != 0 ||
      profile.build_id == NULL ||
      strcmp(profile.build_id, "nesturbator-" NESTURBATOR_REVISION) != 0 ||
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
  if (battery_snapshot_get_uint(
          snapshot + BATTERY_SNAPSHOT_STATE_FORMAT_OFFSET, 4U) != 3U ||
      battery_snapshot_get_uint(
          snapshot + BATTERY_SNAPSHOT_CORE_ABI_OFFSET, 4U) !=
          (uint64_t)profile.api_revision ||
      battery_snapshot_get_uint(
          snapshot + BATTERY_SNAPSHOT_BEHAVIOR_REVISION_OFFSET, 4U) !=
          (uint64_t)profile.behavior_revision ||
      strcmp((const char *)(snapshot + BATTERY_SNAPSHOT_BUILD_ID_OFFSET),
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
          &identical_restored_info, identical_restored_media) ||
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
  if (!battery_snapshot_advance_literal(instance, &replay_result, video,
                                        audio) ||
      lf_copy_media(instance, replay_media, sizeof(replay_media),
                    &replay_info) != LF_OK ||
      replay_info.extent_bytes != sizeof(replay_media) ||
      replay_info.guest_generation <= restored_info.guest_generation ||
      !save_bytes_match_literal(
          replay_media, sizeof(replay_media),
          (uint8_t)LF_BATTERY_SNAPSHOT_REPLAY_BYTE)) {
    goto cleanup;
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
    (void)printf("nesturbator_battery_snapshot: route=installed "
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
                 NESTURBATOR_REVISION, NESTURBATOR_REVISION);
  } else {
    (void)fprintf(stderr,
                  "nesturbator_battery_snapshot: route=installed stage=%d "
                  "failure=%s\n",
                  stage, failure);
  }
  return result;
}

static int exercise_installed_battery_process_refusal_matrix(
    lf_instance *instance, const uint8_t *baseline, size_t snapshot_bytes,
    const char *save_path, const uint8_t *selected_file,
    size_t selected_file_bytes, save_acknowledgment *host_acknowledgment,
    const save_acknowledgment *expected_acknowledgment,
    const uint8_t *expected_acknowledgment_pointer,
    uint64_t baseline_generation, uint64_t *final_generation) {
  static const installed_battery_process_refusal_case cases[] = {
      {"zero_extent", 0U, 0U, 0U, INSTALLED_BATTERY_EXTENT_EMPTY, 0, 0, 1U},
      {"null_zero_extent", 0U, 0U, 0U, INSTALLED_BATTERY_EXTENT_EMPTY, 0, 1,
       1U},
      {"truncated_header", 0U, 0U, 0U,
       INSTALLED_BATTERY_EXTENT_HEADER_MINUS_ONE, 0, 0, 1U},
      {"truncated_native_payload", 0U, 0U, 0U,
       INSTALLED_BATTERY_EXTENT_SNAPSHOT_MINUS_ONE, 0, 0, 1U},
      {"trailing_byte", 0U, 0U, 0U,
       INSTALLED_BATTERY_EXTENT_TRAILING_BYTE, 0, 0, 1U},
      {"malformed_magic", 0U, 0U, 0U, INSTALLED_BATTERY_EXTENT_EXACT, 1, 0,
       1U},
      {"malformed_version", INSTALLED_SNAPSHOT_VERSION_OFFSET, 4U,
       UINT32_MAX, INSTALLED_BATTERY_EXTENT_EXACT, 0, 0, 1U},
      {"malformed_header", INSTALLED_SNAPSHOT_HEADER_SIZE_OFFSET, 4U,
       INSTALLED_SNAPSHOT_HEADER_BYTES - 1U,
       INSTALLED_BATTERY_EXTENT_EXACT, 0, 0, 1U},
      {"malformed_total_length", INSTALLED_SNAPSHOT_TOTAL_SIZE_OFFSET, 8U,
       UINT64_C(1), INSTALLED_BATTERY_EXTENT_EXACT, 0, 0, 1U},
      {"malformed_native_length", INSTALLED_SNAPSHOT_NATIVE_SIZE_OFFSET, 8U,
       UINT64_C(1), INSTALLED_BATTERY_EXTENT_EXACT, 0, 0, 1U},
      {"malformed_content_extent", INSTALLED_SNAPSHOT_CONTENT_SIZE_OFFSET,
       8U, UINT64_C(1), INSTALLED_BATTERY_EXTENT_EXACT, 0, 0, 1U},
      {"wrong_core_build", INSTALLED_SNAPSHOT_CORE_BUILD_ID_OFFSET, 0U, 0U,
       INSTALLED_BATTERY_EXTENT_EXACT, 1, 0, 1U},
      {"wrong_libfuturo_build", INSTALLED_SNAPSHOT_LIBFUTURO_BUILD_ID_OFFSET,
       0U, 0U, INSTALLED_BATTERY_EXTENT_EXACT, 1, 0, 1U},
      {"wrong_native_format", INSTALLED_SNAPSHOT_STATE_FORMAT_OFFSET, 4U,
       99U, INSTALLED_BATTERY_EXTENT_EXACT, 0, 0, 1U},
      {"wrong_core_abi", INSTALLED_SNAPSHOT_CORE_ABI_OFFSET, 4U, 99U,
       INSTALLED_BATTERY_EXTENT_EXACT, 0, 0, 1U},
      {"wrong_behavior_revision",
       INSTALLED_SNAPSHOT_BEHAVIOR_REVISION_OFFSET, 4U, 99U,
       INSTALLED_BATTERY_EXTENT_EXACT, 0, 0, 1U},
      {"wrong_profile", INSTALLED_SNAPSHOT_PROFILE_ID_OFFSET, 0U, 0U,
       INSTALLED_BATTERY_EXTENT_EXACT, 1, 0, 1U},
      {"wrong_configuration", INSTALLED_SNAPSHOT_CONFIGURATION_ID_OFFSET,
       0U, 0U, INSTALLED_BATTERY_EXTENT_EXACT, 1, 0, 1U},
      {"wrong_options", INSTALLED_SNAPSHOT_OPTIONS_ID_OFFSET, 0U, 0U,
       INSTALLED_BATTERY_EXTENT_EXACT, 1, 0, 1U},
      {"wrong_content_digest", INSTALLED_SNAPSHOT_CONTENT_DIGEST_OFFSET, 0U,
       0U, INSTALLED_BATTERY_EXTENT_EXACT, 1, 0, 1U},
      {"native_corruption", SIZE_MAX, 0U, 0U,
       INSTALLED_BATTERY_EXTENT_EXACT, 1, 0, 1U},
      {"repeated_invalid_candidate", 0U, 0U, 0U,
       INSTALLED_BATTERY_EXTENT_EXACT, 1, 0, 2U},
  };
  uint8_t *candidate = NULL;
  uint64_t expected_generation = baseline_generation;
  size_t case_index = 0U;
  int result = 0;

  if (instance == NULL || baseline == NULL || snapshot_bytes <
          INSTALLED_SNAPSHOT_HEADER_BYTES || save_path == NULL ||
      selected_file == NULL || host_acknowledgment == NULL ||
      expected_acknowledgment == NULL ||
      expected_acknowledgment_pointer == NULL || final_generation == NULL ||
      baseline_generation > UINT64_MAX -
                                2U * (sizeof(cases) / sizeof(cases[0]))) {
    return 0;
  }
  candidate = (uint8_t *)malloc(snapshot_bytes + 1U);
  if (candidate == NULL) {
    goto cleanup;
  }
  for (case_index = 0U; case_index < sizeof(cases) / sizeof(cases[0]);
       ++case_index) {
    const installed_battery_process_refusal_case *test_case =
        &cases[case_index];
    size_t candidate_bytes = snapshot_bytes;
    size_t repetition = 0U;
    memcpy(candidate, baseline, snapshot_bytes);
    candidate[snapshot_bytes] = 0xA5U;
    if (test_case->offset == SIZE_MAX) {
      candidate[snapshot_bytes - 1U] ^= 1U;
    } else if (test_case->width != 0U) {
      installed_snapshot_put_uint(candidate + test_case->offset,
                                  test_case->width, test_case->value);
    } else if (test_case->xor_byte != 0) {
      candidate[test_case->offset] ^= 1U;
    }
    switch (test_case->extent_kind) {
    case INSTALLED_BATTERY_EXTENT_EMPTY:
      candidate_bytes = 0U;
      break;
    case INSTALLED_BATTERY_EXTENT_HEADER_MINUS_ONE:
      candidate_bytes = INSTALLED_SNAPSHOT_HEADER_BYTES - 1U;
      break;
    case INSTALLED_BATTERY_EXTENT_SNAPSHOT_MINUS_ONE:
      candidate_bytes = snapshot_bytes - 1U;
      break;
    case INSTALLED_BATTERY_EXTENT_TRAILING_BYTE:
      candidate_bytes = snapshot_bytes + 1U;
      break;
    case INSTALLED_BATTERY_EXTENT_EXACT:
    default:
      break;
    }
    if (!battery_snapshot_refusal_preserves(
            instance, baseline, snapshot_bytes,
            test_case->null_candidate != 0 ? NULL : candidate,
            candidate_bytes, test_case->repetitions, LF_INVALID_ARGUMENT, 0,
            test_case->name, expected_generation, save_path, selected_file,
            selected_file_bytes, host_acknowledgment,
            expected_acknowledgment, expected_acknowledgment_pointer)) {
      (void)fprintf(stderr,
                    "installed battery refusal failed: %s\n",
                    test_case->name);
      goto cleanup;
    }
    for (repetition = 0U; repetition < test_case->repetitions; ++repetition) {
      (void)printf("event=battery-b-refusal name=%s status=invalid-argument "
                   "preservation=continuation,full-media,generation,"
                   "selected-save,ack result=pass\n",
                   test_case->name);
    }
    expected_generation += 2U;
  }
  {
    uint8_t media[SAVE_FIXTURE_RAM_BYTES];
    lf_media_info info = {.struct_size = sizeof(info)};
    if (lf_copy_media(instance, media, sizeof(media), &info) != LF_OK ||
        info.struct_size != sizeof(info) ||
        info.extent_bytes != sizeof(media) || info.identity == NULL ||
        strcmp(info.identity, SAVE_MEDIA_IDENTITY) != 0 ||
        info.guest_generation != expected_generation ||
        !save_bytes_match_literal(
            media, sizeof(media),
            (uint8_t)LF_BATTERY_SNAPSHOT_CAPTURE_BYTE)) {
      goto cleanup;
    }
    *final_generation = info.guest_generation;
  }
  result = 1;

cleanup:
  free(candidate);
  return result;
}

static int run_snapshot_battery_process_capture(const char *checkpoint_path,
                                                const char *save_path) {
  uint8_t fixture[LF_NESTURBATOR_SAVE_FIXTURE_TOTAL_BYTES];
  uint8_t capture_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t capture_after_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t newer_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t selected_file[SAVE_ENVELOPE_MAX_BYTES];
  uint8_t expected_header[SAVE_ENVELOPE_HEADER_BYTES];
  uint8_t opened_header_bytes[SAVE_ENVELOPE_HEADER_BYTES];
  uint8_t fixture_digest[32];
  uint8_t *snapshot = NULL;
  uint8_t *opened_payload = NULL;
  size_t fixture_bytes = 0U;
  size_t snapshot_bytes = 0U;
  size_t selected_file_bytes = 0U;
  size_t frame = 0U;
  uint32_t supported = 0U;
  lf_instance *instance = NULL;
  lf_profile profile = {.struct_size = sizeof(profile)};
  lf_media_info capture_info = {.struct_size = sizeof(capture_info)};
  lf_media_info capture_after_info = {.struct_size = sizeof(capture_after_info)};
  lf_media_info newer_info = {.struct_size = sizeof(newer_info)};
  save_envelope_header newer_header;
  save_envelope_header opened_header;
  save_acknowledgment acknowledgment = {0};
  FILE *checkpoint = NULL;
  int result = 1;
  const char *failure = "capability";

  if (checkpoint_path == NULL || checkpoint_path[0] == '\0' ||
      save_path == NULL || save_path[0] == '\0' ||
      lf_get_capability("nesturbator-ntsc-v1", NULL, LF_CAP_SNAPSHOT,
                        &supported) != LF_OK ||
      supported != 1U) {
    goto cleanup;
  }
  failure = "pinned profile and generated battery fixture";
  fixture_bytes = lf_build_nesturbator_save_fixture(fixture, sizeof(fixture));
  if (strcmp(LIBFUTURO_NESTURBATOR_SOURCE_REVISION,
             NESTURBATOR_REVISION) != 0 ||
      lf_get_profile("nesturbator-ntsc-v1", NULL, &profile) != LF_OK ||
      profile.struct_size != sizeof(profile) || profile.profile_id == NULL ||
      strcmp(profile.profile_id, "nesturbator-ntsc-v1") != 0 ||
      profile.build_id == NULL ||
      strcmp(profile.build_id, "nesturbator-" NESTURBATOR_REVISION) != 0 ||
      profile.api_revision != 1U || profile.behavior_revision != 9U ||
      fixture_bytes != sizeof(fixture) ||
      !lf_nesturbator_save_fixture_sha256(fixture, fixture_bytes,
                                          fixture_digest) ||
      !lf_save_oracle_sha256_matches(fixture_digest, sizeof(fixture_digest)) ||
      lf_create("nesturbator-ntsc-v1", NULL, &instance) != LF_OK ||
      instance == NULL || !snapshot_process_load(instance, fixture,
                                                  fixture_bytes) ||
      !snapshot_process_load(instance, fixture, fixture_bytes)) {
    goto cleanup;
  }
  failure = "R2 capture after two successful fixture loads";
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
          (uint8_t)LF_BATTERY_SNAPSHOT_CAPTURE_BYTE) ||
      lf_get_snapshot_size(instance, &snapshot_bytes) != LF_OK ||
      snapshot_bytes <= INSTALLED_SNAPSHOT_HEADER_BYTES) {
    goto cleanup;
  }
  snapshot = (uint8_t *)malloc(snapshot_bytes);
  if (snapshot == NULL ||
      lf_capture_snapshot(instance, snapshot, snapshot_bytes) != LF_OK ||
      lf_copy_media(instance, capture_after_media, sizeof(capture_after_media),
                    &capture_after_info) != LF_OK ||
      capture_after_info.struct_size != sizeof(capture_after_info) ||
      capture_after_info.extent_bytes != capture_info.extent_bytes ||
      capture_after_info.guest_generation != capture_info.guest_generation ||
      capture_after_info.identity == NULL ||
      strcmp(capture_after_info.identity, SAVE_MEDIA_IDENTITY) != 0 ||
      memcmp(capture_after_media, capture_media, sizeof(capture_media)) != 0 ||
      installed_snapshot_get_uint(snapshot + INSTALLED_SNAPSHOT_VERSION_OFFSET,
                                  4U) != 2U ||
      installed_snapshot_get_uint(
          snapshot + INSTALLED_SNAPSHOT_HEADER_SIZE_OFFSET, 4U) !=
          INSTALLED_SNAPSHOT_HEADER_BYTES ||
      installed_snapshot_get_uint(snapshot + INSTALLED_SNAPSHOT_TOTAL_SIZE_OFFSET,
                                  8U) != snapshot_bytes ||
      installed_snapshot_get_uint(snapshot + INSTALLED_SNAPSHOT_CONTENT_SIZE_OFFSET,
                                  8U) != fixture_bytes ||
      strcmp((const char *)(snapshot + INSTALLED_SNAPSHOT_PROFILE_ID_OFFSET),
             "nesturbator-ntsc-v1") != 0 ||
      strcmp((const char *)(snapshot +
                            INSTALLED_SNAPSHOT_CONFIGURATION_ID_OFFSET),
             "nesturbator-default") != 0) {
    goto cleanup;
  }
  failure = "R3 guest write and exact selected-save readback";
  if (!advance_save_guest_frame(instance) ||
      lf_copy_media(instance, newer_media, sizeof(newer_media), &newer_info) !=
          LF_OK ||
      newer_info.struct_size != sizeof(newer_info) ||
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
  if (checkpoint == NULL ||
      fwrite(snapshot, 1U, snapshot_bytes, checkpoint) != snapshot_bytes) {
    goto cleanup;
  }
  if (fclose(checkpoint) != 0) {
    checkpoint = NULL;
    goto cleanup;
  }
  checkpoint = NULL;
  (void)printf("event=checkpoint-close bytes=%zu\n", snapshot_bytes);
  if (fflush(stdout) != 0 || lf_destroy(&instance) != LF_OK) {
    goto cleanup;
  }
  (void)printf("event=instance-destroyed\n");
  if (fflush(stdout) != 0) {
    goto cleanup;
  }
  (void)printf("nesturbator_snapshot_battery_process_a: loads=2 "
               "media=R2->R3 checkpoint=closed result=pass\n");
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
  uint8_t fixture[LF_NESTURBATOR_SAVE_FIXTURE_TOTAL_BYTES];
  uint8_t initial_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t imported_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t restored_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t identical_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t post_refusal_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t replay_media[SAVE_FIXTURE_RAM_BYTES];
  uint8_t selected_file[SAVE_ENVELOPE_MAX_BYTES];
  uint8_t current_file[SAVE_ENVELOPE_MAX_BYTES];
  uint8_t expected_header[SAVE_ENVELOPE_HEADER_BYTES];
  uint8_t opened_header_bytes[SAVE_ENVELOPE_HEADER_BYTES];
  uint8_t fixture_digest[32];
  uint8_t *snapshot = NULL;
  uint8_t *selected_payload = NULL;
  uint8_t *opened_payload = NULL;
  size_t fixture_bytes = 0U;
  size_t snapshot_bytes = 0U;
  size_t selected_file_bytes = 0U;
  size_t current_file_bytes = 0U;
  uint32_t supported = 0U;
  uint64_t final_generation = 0U;
  uint64_t imported_generation = 0U;
  lf_instance *instance = NULL;
  lf_profile profile = {.struct_size = sizeof(profile)};
  lf_media_info initial_info = {.struct_size = sizeof(initial_info)};
  lf_media_info imported_info = {.struct_size = sizeof(imported_info)};
  lf_media_info restored_info = {.struct_size = sizeof(restored_info)};
  lf_media_info identical_info = {.struct_size = sizeof(identical_info)};
  lf_media_info post_refusal_info = {.struct_size = sizeof(post_refusal_info)};
  lf_media_info replay_info = {.struct_size = sizeof(replay_info)};
  lf_run_result replay_result = {.struct_size = sizeof(replay_result)};
  save_envelope_header selected_header;
  save_envelope_header restored_header;
  save_envelope_header opened_header;
  save_acknowledgment host_acknowledgment = {0};
  save_acknowledgment selected_acknowledgment = {0};
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
      snapshot_bytes <= INSTALLED_SNAPSHOT_HEADER_BYTES ||
      snapshot_bytes > (size_t)INSTALLED_SNAPSHOT_MAX_BYTES) {
    goto cleanup;
  }
  (void)printf("event=checkpoint-reopened bytes=%zu\n", snapshot_bytes);
  failure = "pinned profile and generated battery fixture";
  fixture_bytes = lf_build_nesturbator_save_fixture(fixture, sizeof(fixture));
  if (strcmp(LIBFUTURO_NESTURBATOR_SOURCE_REVISION,
             NESTURBATOR_REVISION) != 0 ||
      lf_get_profile("nesturbator-ntsc-v1", NULL, &profile) != LF_OK ||
      profile.struct_size != sizeof(profile) || profile.profile_id == NULL ||
      strcmp(profile.profile_id, "nesturbator-ntsc-v1") != 0 ||
      profile.build_id == NULL ||
      strcmp(profile.build_id, "nesturbator-" NESTURBATOR_REVISION) != 0 ||
      profile.api_revision != 1U || profile.behavior_revision != 9U ||
      fixture_bytes != sizeof(fixture) ||
      !lf_nesturbator_save_fixture_sha256(fixture, fixture_bytes,
                                          fixture_digest) ||
      !lf_save_oracle_sha256_matches(fixture_digest, sizeof(fixture_digest)) ||
      lf_create("nesturbator-ntsc-v1", NULL, &instance) != LF_OK ||
      instance == NULL ||
      !snapshot_process_load(instance, fixture, fixture_bytes)) {
    goto cleanup;
  }
  failure = "selected R3 envelope and exact host readback";
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

  failure = "Process B initial state and R3 import before advance";
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

  failure = "cross-process restore to R2 full media span";
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

  failure = "identical restore and B-local refusal baseline";
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
      !only_committed_save_remains(save_path)) {
    goto cleanup;
  }
  {
    uint8_t *refusal_baseline = (uint8_t *)malloc(snapshot_bytes);
    int refusal_ok =
        refusal_baseline != NULL &&
        lf_capture_snapshot(instance, refusal_baseline, snapshot_bytes) ==
            LF_OK &&
        exercise_installed_battery_process_refusal_matrix(
            instance, refusal_baseline, snapshot_bytes, save_path,
            selected_file, selected_file_bytes, &host_acknowledgment,
            &selected_acknowledgment, selected_payload,
            identical_info.guest_generation, &final_generation);
    free(refusal_baseline);
    if (!refusal_ok ||
        lf_copy_media(instance, post_refusal_media,
                      sizeof(post_refusal_media), &post_refusal_info) != LF_OK ||
        post_refusal_info.struct_size != sizeof(post_refusal_info) ||
        post_refusal_info.extent_bytes != sizeof(post_refusal_media) ||
        post_refusal_info.guest_generation != final_generation ||
        post_refusal_info.identity == NULL ||
        strcmp(post_refusal_info.identity, SAVE_MEDIA_IDENTITY) != 0 ||
        !save_bytes_match_literal(
            post_refusal_media, sizeof(post_refusal_media),
            (uint8_t)LF_BATTERY_SNAPSHOT_CAPTURE_BYTE) ||
        host_acknowledgment.payload != selected_payload ||
        !save_acknowledgments_match(&host_acknowledgment,
                                    &selected_acknowledgment) ||
        !read_save_file_bytes(save_path, current_file, sizeof(current_file),
                              &current_file_bytes) ||
        current_file_bytes != selected_file_bytes ||
        memcmp(current_file, selected_file, selected_file_bytes) != 0 ||
        !only_committed_save_remains(save_path) ||
        !make_save_envelope_header(&restored_header, &post_refusal_info)) {
      goto cleanup;
    }
  }
  (void)printf("event=battery-b-refusal-baseline generation=%" PRIu64
               " media=R2 selected-save=R3 result=pass\n",
               post_refusal_info.guest_generation);

  failure = "pre-rename failure preserves exact R3 and acknowledgment";
  if (commit_save_envelope(save_path, &restored_header, post_refusal_media, 1,
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

  failure = "explicit R2 commit with exact reopen before acknowledgment";
  if (commit_save_envelope(save_path, &restored_header, post_refusal_media, 0,
                           &host_acknowledgment) != SAVE_STAGE_COMMITTED ||
      host_acknowledgment.committed != 1 ||
      host_acknowledgment.payload != post_refusal_media ||
      host_acknowledgment.extent_bytes != sizeof(post_refusal_media) ||
      host_acknowledgment.guest_generation !=
          post_refusal_info.guest_generation ||
      !read_save_envelope(save_path, &opened_header, &opened_payload) ||
      opened_payload == NULL ||
      !encode_save_envelope_header(&restored_header, expected_header) ||
      !encode_save_envelope_header(&opened_header, opened_header_bytes) ||
      memcmp(expected_header, opened_header_bytes, sizeof(expected_header)) !=
          0 ||
      opened_header.extent_bytes != sizeof(post_refusal_media) ||
      !save_bytes_match_literal(
          opened_payload, sizeof(post_refusal_media),
          (uint8_t)LF_BATTERY_SNAPSHOT_CAPTURE_BYTE) ||
      memcmp(opened_payload, post_refusal_media,
             sizeof(post_refusal_media)) != 0 ||
      memcmp(opened_payload, selected_payload, sizeof(post_refusal_media)) ==
          0 ||
      !only_committed_save_remains(save_path) ||
      !read_save_file_bytes(save_path, current_file, sizeof(current_file),
                            &current_file_bytes) ||
      current_file_bytes !=
          (size_t)SAVE_ENVELOPE_HEADER_BYTES + sizeof(post_refusal_media) ||
      memcmp(current_file, expected_header, sizeof(expected_header)) != 0 ||
      memcmp(current_file + SAVE_ENVELOPE_HEADER_BYTES, post_refusal_media,
             sizeof(post_refusal_media)) != 0 ||
      !save_acknowledgments_match(
          &host_acknowledgment,
          &(save_acknowledgment){.payload = post_refusal_media,
                                 .extent_bytes = sizeof(post_refusal_media),
                                 .guest_generation =
                                     post_refusal_info.guest_generation,
                                 .committed = 1})) {
    goto cleanup;
  }
  free(opened_payload);
  opened_payload = NULL;
  (void)printf("event=save-r2-readback-acknowledged bytes=%zu generation=%" PRIu64
               " readback=exact result=pass\n",
               post_refusal_info.extent_bytes,
               post_refusal_info.guest_generation);

  failure = "literal continuation and complete replay media";
  if (!battery_snapshot_advance_literal(instance, &replay_result, k_video,
                                        k_audio) ||
      lf_copy_media(instance, replay_media, sizeof(replay_media),
                    &replay_info) != LF_OK ||
      replay_info.struct_size != sizeof(replay_info) ||
      replay_info.extent_bytes != sizeof(replay_media) ||
      replay_info.identity == NULL ||
      strcmp(replay_info.identity, SAVE_MEDIA_IDENTITY) != 0 ||
      replay_info.guest_generation != post_refusal_info.guest_generation + 1U ||
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
  (void)printf("nesturbator_snapshot_battery_process_b: loads=1 frame=3 "
               "ticks=2144280 video=5a5a5a audio=799-silence media=full-8192 "
               "selected-save=R2-readback result=pass\n");
  result = 0;

cleanup:
  free(opened_payload);
  free(selected_payload);
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
  size_t case_index = 0U;
  uint32_t supported = 0U;
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
      .audio_samples =
          (size_t)LF_BATTERY_SNAPSHOT_REPLAY_AUDIO_SAMPLES,
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
      snapshot_bytes <= INSTALLED_SNAPSHOT_HEADER_BYTES ||
      snapshot_bytes > (size_t)INSTALLED_SNAPSHOT_MAX_BYTES) {
    goto cleanup;
  }
  failure = "pinned profile and generated battery fixture";
  fixture_bytes = lf_build_nesturbator_save_fixture(fixture, sizeof(fixture));
  if (strcmp(LIBFUTURO_NESTURBATOR_SOURCE_REVISION,
             NESTURBATOR_REVISION) != 0 ||
      lf_get_profile("nesturbator-ntsc-v1", NULL, &profile) != LF_OK ||
      profile.struct_size != sizeof(profile) || profile.profile_id == NULL ||
      strcmp(profile.profile_id, "nesturbator-ntsc-v1") != 0 ||
      profile.build_id == NULL ||
      strcmp(profile.build_id, "nesturbator-" NESTURBATOR_REVISION) != 0 ||
      profile.api_revision != 1U || profile.behavior_revision != 9U ||
      fixture_bytes != sizeof(fixture) ||
      !lf_nesturbator_save_fixture_sha256(fixture, fixture_bytes,
                                          fixture_digest) ||
      !lf_save_oracle_sha256_matches(fixture_digest, sizeof(fixture_digest)) ||
      lf_create("nesturbator-ntsc-v1", NULL, &instance) != LF_OK ||
      instance == NULL || !snapshot_process_load(instance, fixture,
                                                  fixture_bytes)) {
    goto cleanup;
  }
  failure = "selected R3 readback and import before positive work";
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
      !only_committed_save_remains(save_path) ||
      lf_copy_media(instance, initial_media, sizeof(initial_media),
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
          (uint8_t)LF_BATTERY_SNAPSHOT_NEWER_BYTE)) {
    goto cleanup;
  }
  selected_acknowledgment = host_acknowledgment;
  failure = "restore R2 and establish passing literal oracle baseline";
  if (lf_restore_snapshot(instance, snapshot, snapshot_bytes) != LF_OK ||
      lf_copy_media(instance, restored_media, sizeof(restored_media),
                    &restored_info) != LF_OK ||
      restored_info.struct_size != sizeof(restored_info) ||
      restored_info.extent_bytes != sizeof(restored_media) ||
      restored_info.identity == NULL ||
      strcmp(restored_info.identity, SAVE_MEDIA_IDENTITY) != 0 ||
      restored_info.guest_generation != imported_info.guest_generation + 1U ||
      !save_bytes_match_literal(
          restored_media, sizeof(restored_media),
          (uint8_t)LF_BATTERY_SNAPSHOT_CAPTURE_BYTE)) {
    goto cleanup;
  }
  memset(expected_media, (uint8_t)LF_SAVE_ORACLE_FILL_BYTE,
         sizeof(expected_media));
  expected_media[0] = (uint8_t)LF_BATTERY_SNAPSHOT_REPLAY_BYTE;
  if (battery_snapshot_advance_expected(
          instance, &expected, &replay_result, k_video, k_audio) !=
          BATTERY_SNAPSHOT_ORACLE_NONE ||
      lf_copy_media(instance, replay_media, sizeof(replay_media),
                    &replay_info) != LF_OK ||
      replay_info.struct_size != sizeof(replay_info) ||
      replay_info.extent_bytes != sizeof(replay_media) ||
      replay_info.identity == NULL ||
      strcmp(replay_info.identity, SAVE_MEDIA_IDENTITY) != 0 ||
      replay_info.guest_generation != restored_info.guest_generation + 1U ||
      memcmp(replay_media, expected_media, sizeof(replay_media)) != 0 ||
      host_acknowledgment.payload != selected_payload ||
      !save_acknowledgments_match(&host_acknowledgment,
                                  &selected_acknowledgment) ||
      !read_save_file_bytes(save_path, current_file, sizeof(current_file),
                            &current_file_bytes) ||
      current_file_bytes != selected_file_bytes ||
      memcmp(current_file, selected_file, selected_file_bytes) != 0) {
    goto cleanup;
  }
  (void)printf("event=battery-oracle-baseline result=pass frame=%" PRIu64
               " ticks=%" PRIu64 " rgb=%02x%02x%02x audio=%zu "
               "full-media=pass\n",
               replay_result.cumulative_units,
               replay_result.cumulative_core_ticks, k_video[0], k_video[1],
               k_video[2], replay_result.audio_produced_samples);

  failure = "each wrong oracle isolates its intended assertion";
  for (case_index = 0U; case_index < sizeof(cases) / sizeof(cases[0]);
       ++case_index) {
    battery_snapshot_oracle_failure actual_failure =
        BATTERY_SNAPSHOT_ORACLE_SETUP;
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
        restored_info.struct_size != sizeof(restored_info) ||
        restored_info.extent_bytes != sizeof(restored_media) ||
        restored_info.identity == NULL ||
        strcmp(restored_info.identity, SAVE_MEDIA_IDENTITY) != 0 ||
        !save_bytes_match_literal(
            restored_media, sizeof(restored_media),
            (uint8_t)LF_BATTERY_SNAPSHOT_CAPTURE_BYTE)) {
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
    if (actual_failure != cases[case_index].expected_failure ||
        !read_save_file_bytes(save_path, current_file, sizeof(current_file),
                              &current_file_bytes) ||
        current_file_bytes != selected_file_bytes ||
        memcmp(current_file, selected_file, selected_file_bytes) != 0 ||
        host_acknowledgment.payload != selected_payload ||
        !save_acknowledgments_match(&host_acknowledgment,
                                    &selected_acknowledgment) ||
        !only_committed_save_remains(save_path)) {
      (void)fprintf(stderr,
                    "installed battery oracle %s expected=%d actual=%d\n",
                    cases[case_index].name,
                    (int)cases[case_index].expected_failure,
                    (int)actual_failure);
      goto cleanup;
    }
    (void)printf("event=battery-oracle-control name=%s expected=%s actual=%s "
                 "result=pass\n",
                 cases[case_index].name, cases[case_index].name,
                 cases[case_index].name);
  }
  if (lf_destroy(&instance) != LF_OK) {
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
  if (argc == 4 &&
      strcmp(argv[1], "--snapshot-battery-process-oracle-controls") == 0) {
    return run_snapshot_battery_process_oracle_controls(argv[2], argv[3]);
  }
  if (argc == 4 && strcmp(argv[1], "--snapshot-battery-process-capture") == 0) {
    return run_snapshot_battery_process_capture(argv[2], argv[3]);
  }
  if (argc == 4 && strcmp(argv[1], "--snapshot-battery-process-restore") == 0) {
    return run_snapshot_battery_process_restore(argv[2], argv[3]);
  }
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
  if (argc == 2 &&
      strcmp(argv[1], "--snapshot-battery-wrong-expected") == 0) {
    return exercise_battery_snapshot_oracle_control()
               ? 0
               : fail("battery snapshot oracle controls");
  }
  if (argc == 2 && strcmp(argv[1], "--snapshot-battery") == 0) {
    return exercise_installed_battery_snapshot_recovery()
               ? 0
               : fail("installed battery snapshot recovery");
  }
  if (argc == 2 && strcmp(argv[1], "--snapshot-proof") == 0) {
    return exercise_installed_snapshot()
               ? 0
               : fail("installed snapshot proof");
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
  if (argc != 1) {
    (void)fprintf(stderr, "nesturbator_installed_consumer: unknown mode\n");
    return 2;
  }
  uint8_t fixture[FIXTURE_TOTAL_BYTES];
  uint8_t video[VIDEO_EXTENT_BYTES];
  int16_t audio[AUDIO_MAX_SAMPLES];
  lf_instance *instance = NULL;
  lf_load_result load_result = {.struct_size = sizeof(load_result)};
  lf_input input = {.struct_size = sizeof(input), .buttons = 1U};
  uint64_t previous_ticks = 0U;
  uint32_t frame = 0U;
  size_t fixture_bytes = 0U;
  int matched = 0;
  int result = 1;

  if (strcmp(LIBFUTURO_NESTURBATOR_SOURCE_REVISION,
             NESTURBATOR_REVISION) != 0) {
    return fail("exact pinned Nesturbator revision");
  }
  fixture_bytes = build_fixture(fixture, sizeof(fixture));
  if (fixture_bytes != sizeof(fixture) ||
      lf_create("nesturbator-ntsc-v1", NULL, &instance) != LF_OK ||
      instance == NULL) {
    return fail("generated fixture and real-core creation");
  }
  if (lf_load(instance,
              &(lf_load_request){.struct_size = sizeof(lf_load_request),
                                 .content_data = fixture,
                                 .content_size_bytes = fixture_bytes},
              &load_result) != LF_OK ||
      load_result.loaded != 1U ||
      load_result.content_size_bytes != fixture_bytes ||
      lf_set_input(instance, &input) != LF_OK) {
    (void)fprintf(stderr, "nesturbator_installed_consumer: load/input failed\n");
    goto cleanup;
  }

  for (frame = 0U; frame < FIXTURE_MAX_WARMUP_FRAMES; ++frame) {
    lf_run_request request = {
        .struct_size = sizeof(request),
        .work_units = 1U,
        .video_data = video,
        .video_capacity_bytes = sizeof(video),
        .video_stride_bytes = VIDEO_STRIDE_BYTES,
        .audio_data = audio,
        .audio_capacity_samples = AUDIO_MAX_SAMPLES,
    };
    lf_run_result run = {.struct_size = sizeof(run)};
    size_t sample = 0U;
    memset(video, 0xA5, sizeof(video));
    for (sample = 0U; sample < AUDIO_MAX_SAMPLES; ++sample) {
      audio[sample] = INT16_C(1234);
    }
    if (lf_advance(instance, &request, &run) != LF_OK ||
        run.requested_units != 1U || run.actual_units != 1U ||
        run.cumulative_units != (uint64_t)frame + 1U ||
        run.sampled_buttons != input.buttons || run.video_valid != 1U ||
        run.audio_valid != 1U || run.video_format != LF_VIDEO_RGB24 ||
        run.video_width != VIDEO_WIDTH || run.video_height != VIDEO_HEIGHT ||
        run.video_stride_bytes != VIDEO_STRIDE_BYTES ||
        run.video_extent_bytes != VIDEO_EXTENT_BYTES ||
        run.audio_encoding != LF_AUDIO_S16_NATIVE ||
        run.audio_layout != LF_AUDIO_INTERLEAVED ||
        run.audio_channels != 1U ||
        (run.audio_produced_samples != 798U &&
         run.audio_produced_samples != 799U) ||
        run.core_ticks_valid != 1U ||
        run.core_tick_time_unit != LF_TIME_NES_HALF_MASTER_TICK ||
        run.cumulative_core_ticks <= previous_ticks ||
        !video_padding_is_untouched(video)) {
      (void)fprintf(stderr,
                    "nesturbator_installed_consumer: frame %" PRIu32
                    " metadata/audio/video failed\n",
                    frame);
      goto cleanup;
    }
    for (sample = 0U; sample < run.audio_produced_samples; ++sample) {
      if (audio[sample] != 0) {
        (void)fprintf(stderr,
                      "nesturbator_installed_consumer: audio sample %zu was nonzero\n",
                      sample);
        goto cleanup;
      }
    }
    for (sample = run.audio_produced_samples; sample < AUDIO_MAX_SAMPLES;
         ++sample) {
      if (audio[sample] != INT16_C(1234)) {
        (void)fprintf(stderr,
                      "nesturbator_installed_consumer: audio tail changed\n");
        goto cleanup;
      }
    }
    previous_ticks = run.cumulative_core_ticks;
    if (frame_matches_literal(video)) {
      matched = 1;
      break;
    }
  }
  if (!matched) {
    (void)fprintf(stderr,
                  "nesturbator_installed_consumer: literal pressed frame absent\n");
    goto cleanup;
  }
  result = 0;

cleanup:
  if (lf_destroy(&instance) != LF_OK || instance != NULL) {
    return fail("instance destruction");
  }
  if (result == 0) {
    (void)printf("nesturbator_installed_consumer: source=%s "
                 "profile=nesturbator-ntsc-v1 fixture=generated-nrom "
                 "load,input,frame,av,close result=pass frames=%" PRIu32 "\n",
                 NESTURBATOR_REVISION, frame + 1U);
  }
  return result;
}
