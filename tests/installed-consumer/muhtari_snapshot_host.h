#ifndef LIBFUTURO_TESTS_MUHTARI_SNAPSHOT_HOST_H
#define LIBFUTURO_TESTS_MUHTARI_SNAPSHOT_HOST_H

#include "muhtari_snapshot_fixture.h"
#include "muhtari_snapshot_oracle.h"

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define LF_MUHTARI_HOST_SNAPSHOT_HEADER_BYTES 416U
#define LF_MUHTARI_HOST_SNAPSHOT_MAX_BYTES (128U * 1024U * 1024U)
#define LF_MUHTARI_HOST_SAVE_HEADER_BYTES 360U
#define LF_MUHTARI_HOST_SAVE_TOTAL_BYTES                                      \
  (LF_MUHTARI_HOST_SAVE_HEADER_BYTES +                                       \
   LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES)

enum lf_muhtari_host_save_offset {
  LF_MUHTARI_HOST_SAVE_VERSION = 8U,
  LF_MUHTARI_HOST_SAVE_HEADER = 12U,
  LF_MUHTARI_HOST_SAVE_TOTAL = 16U,
  LF_MUHTARI_HOST_SAVE_MEDIA = 24U,
  LF_MUHTARI_HOST_SAVE_GENERATION = 32U,
  LF_MUHTARI_HOST_SAVE_CORE_BUILD = 40U,
  LF_MUHTARI_HOST_SAVE_LIBFUTURO_BUILD = 104U,
  LF_MUHTARI_HOST_SAVE_PROFILE = 184U,
  LF_MUHTARI_HOST_SAVE_CONFIGURATION = 216U,
  LF_MUHTARI_HOST_SAVE_OPTIONS = 248U,
  LF_MUHTARI_HOST_SAVE_CONTENT_DIGEST = 280U,
  LF_MUHTARI_HOST_SAVE_CONTENT_BYTES = 312U,
  LF_MUHTARI_HOST_SAVE_PAYLOAD_DIGEST = 320U,
  LF_MUHTARI_HOST_SAVE_API_REVISION = 352U,
  LF_MUHTARI_HOST_SAVE_RESERVED = 356U
};

static const uint8_t lf_muhtari_host_save_magic[8] = {
    'L', 'F', 'M', 'U', 'S', 'A', 'V', '8'};

static void lf_muhtari_host_put_u32(uint8_t *destination, uint32_t value) {
  for (size_t index = 0U; index < 4U; ++index) {
    destination[index] = (uint8_t)(value >> (unsigned int)(index * 8U));
  }
}

static void lf_muhtari_host_put_u64(uint8_t *destination, uint64_t value) {
  for (size_t index = 0U; index < 8U; ++index) {
    destination[index] = (uint8_t)(value >> (unsigned int)(index * 8U));
  }
}

static uint32_t lf_muhtari_host_get_u32(const uint8_t *source) {
  uint32_t value = 0U;
  for (size_t index = 0U; index < 4U; ++index) {
    value |= (uint32_t)source[index] << (unsigned int)(index * 8U);
  }
  return value;
}

static uint64_t lf_muhtari_host_get_u64(const uint8_t *source) {
  uint64_t value = 0U;
  for (size_t index = 0U; index < 8U; ++index) {
    value |= (uint64_t)source[index] << (unsigned int)(index * 8U);
  }
  return value;
}

static void lf_muhtari_host_digest(const uint8_t *bytes, size_t extent,
                                   uint8_t digest[32]) {
  lf_muhtari_oracle_sha256 context;
  lf_muhtari_oracle_sha256_init(&context);
  lf_muhtari_oracle_sha256_update(&context, bytes, extent);
  lf_muhtari_oracle_sha256_finish(&context, digest);
}

static int lf_muhtari_host_snapshot_integrity_matches(
    const uint8_t *snapshot, size_t extent) {
  uint8_t header[LF_MUHTARI_HOST_SNAPSHOT_HEADER_BYTES];
  uint8_t expected[32];
  uint8_t actual[32];
  if (snapshot == NULL || extent < sizeof(header)) {
    return 0;
  }
  memcpy(header, snapshot, sizeof(header));
  memcpy(expected, header + 380U, sizeof(expected));
  memset(header + 380U, 0, sizeof(expected));
  lf_muhtari_host_digest(header, sizeof(header), actual);
  return memcmp(actual, expected, sizeof(actual)) == 0;
}

static void lf_muhtari_host_hex(const uint8_t digest[32], char hex[65]) {
  lf_muhtari_oracle_hex_digest(digest, hex);
}

static int lf_muhtari_host_write_all(int descriptor, const uint8_t *bytes,
                                     size_t extent) {
  size_t written = 0U;
  while (written < extent) {
    const ssize_t result = write(descriptor, bytes + written, extent - written);
    if (result < 0) {
      if (errno == EINTR) {
        continue;
      }
      return 0;
    }
    if (result == 0) {
      return 0;
    }
    written += (size_t)result;
  }
  return 1;
}

static int lf_muhtari_host_read_all(int descriptor, uint8_t *bytes,
                                    size_t extent) {
  size_t read_bytes = 0U;
  while (read_bytes < extent) {
    const ssize_t result = read(descriptor, bytes + read_bytes,
                                extent - read_bytes);
    if (result < 0) {
      if (errno == EINTR) {
        continue;
      }
      return 0;
    }
    if (result == 0) {
      return 0;
    }
    read_bytes += (size_t)result;
  }
  return 1;
}

static int lf_muhtari_host_read_exact_file(const char *path, size_t expected,
                                          size_t maximum, uint8_t **bytes_out) {
  int descriptor = -1;
  struct stat info;
  uint8_t *bytes = NULL;
  uint8_t extra = 0U;
  int ok = 0;
  if (path == NULL || bytes_out == NULL || expected == 0U ||
      expected > maximum) {
    return 0;
  }
  *bytes_out = NULL;
  descriptor = open(path, O_RDONLY);
  if (descriptor < 0 || fstat(descriptor, &info) != 0 ||
      !S_ISREG(info.st_mode) || info.st_size < 0 ||
      (uintmax_t)info.st_size != (uintmax_t)expected) {
    goto cleanup;
  }
  bytes = (uint8_t *)malloc(expected);
  if (bytes == NULL || !lf_muhtari_host_read_all(descriptor, bytes, expected)) {
    goto cleanup;
  }
  for (;;) {
    const ssize_t result = read(descriptor, &extra, 1U);
    if (result < 0 && errno == EINTR) {
      continue;
    }
    if (result != 0) {
      goto cleanup;
    }
    break;
  }
  ok = 1;

cleanup:
  if (descriptor >= 0 && close(descriptor) != 0) {
    ok = 0;
  }
  if (ok == 0) {
    free(bytes);
    return 0;
  }
  *bytes_out = bytes;
  return 1;
}

static int lf_muhtari_host_make_temp(const char *path, char temp_path[PATH_MAX]) {
  const int length = snprintf(temp_path, PATH_MAX, "%s.stage.XXXXXX", path);
  return length > 0 && (size_t)length < (size_t)PATH_MAX;
}

static int lf_muhtari_host_snapshot_identity_matches(
    const uint8_t *candidate, const uint8_t *current, size_t extent) {
  static const size_t regions[][2] = {{0U, 44U},   {44U, 272U},
                                      {356U, 8U},  {412U, 4U}};
  if (candidate == NULL || current == NULL ||
      extent < LF_MUHTARI_HOST_SNAPSHOT_HEADER_BYTES ||
      lf_muhtari_host_get_u32(candidate + 12U) !=
          LF_MUHTARI_HOST_SNAPSHOT_HEADER_BYTES ||
      lf_muhtari_host_get_u32(current + 12U) !=
          LF_MUHTARI_HOST_SNAPSHOT_HEADER_BYTES) {
    return 0;
  }
  for (size_t index = 0U; index < sizeof(regions) / sizeof(regions[0]);
       ++index) {
    const size_t start = regions[index][0];
    const size_t count = regions[index][1];
    if (memcmp(candidate + start, current + start, count) != 0) {
      return 0;
    }
  }
  return 1;
}

static int lf_muhtari_host_save_encode(const uint8_t *snapshot,
                                      size_t snapshot_extent,
                                      const uint8_t *media,
                                      uint64_t generation,
                                      uint8_t output[LF_MUHTARI_HOST_SAVE_TOTAL_BYTES]) {
  if (snapshot == NULL || media == NULL || output == NULL ||
      snapshot_extent < LF_MUHTARI_HOST_SNAPSHOT_HEADER_BYTES ||
      !lf_muhtari_host_snapshot_integrity_matches(snapshot,
                                                  snapshot_extent) ||
      memcmp(snapshot, "LFMU8S1", 7U) != 0 || snapshot[7U] != 0U ||
      lf_muhtari_host_get_u32(snapshot + 8U) != 2U ||
      lf_muhtari_host_get_u32(snapshot + 12U) !=
          LF_MUHTARI_HOST_SNAPSHOT_HEADER_BYTES ||
      lf_muhtari_host_get_u64(snapshot + 16U) != (uint64_t)snapshot_extent ||
      lf_muhtari_host_get_u64(snapshot + 24U) !=
          (uint64_t)(snapshot_extent - LF_MUHTARI_HOST_SNAPSHOT_HEADER_BYTES) ||
      lf_muhtari_host_get_u32(snapshot + 32U) != 1U ||
      lf_muhtari_host_get_u32(snapshot + 36U) != 1U ||
      lf_muhtari_host_get_u32(snapshot + 40U) != 6U ||
      lf_muhtari_host_get_u32(snapshot + 412U) != 8U ||
      lf_muhtari_host_get_u64(snapshot + 356U) !=
          (uint64_t)LF_MUHTARI_FIXTURE_TOTAL_BYTES ||
      memcmp(snapshot + 188U, "muhtari-ntsc-v2", 15U) != 0 ||
      memcmp(snapshot + 220U, "muhtari-ntsc-battery-diagnostic", 31U) != 0) {
    return 0;
  }
  memset(output, 0, LF_MUHTARI_HOST_SAVE_TOTAL_BYTES);
  memcpy(output, lf_muhtari_host_save_magic,
         sizeof(lf_muhtari_host_save_magic));
  lf_muhtari_host_put_u32(output + LF_MUHTARI_HOST_SAVE_VERSION, 1U);
  lf_muhtari_host_put_u32(output + LF_MUHTARI_HOST_SAVE_HEADER,
                          LF_MUHTARI_HOST_SAVE_HEADER_BYTES);
  lf_muhtari_host_put_u64(output + LF_MUHTARI_HOST_SAVE_TOTAL,
                          LF_MUHTARI_HOST_SAVE_TOTAL_BYTES);
  lf_muhtari_host_put_u64(output + LF_MUHTARI_HOST_SAVE_MEDIA,
                          LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES);
  lf_muhtari_host_put_u64(output + LF_MUHTARI_HOST_SAVE_GENERATION,
                          generation);
  memcpy(output + LF_MUHTARI_HOST_SAVE_CORE_BUILD, snapshot + 44U, 64U);
  memcpy(output + LF_MUHTARI_HOST_SAVE_LIBFUTURO_BUILD, snapshot + 108U, 80U);
  memcpy(output + LF_MUHTARI_HOST_SAVE_PROFILE, snapshot + 188U, 32U);
  memcpy(output + LF_MUHTARI_HOST_SAVE_CONFIGURATION, snapshot + 220U, 32U);
  memcpy(output + LF_MUHTARI_HOST_SAVE_OPTIONS, snapshot + 252U, 32U);
  memcpy(output + LF_MUHTARI_HOST_SAVE_CONTENT_DIGEST, snapshot + 284U, 32U);
  lf_muhtari_host_put_u64(output + LF_MUHTARI_HOST_SAVE_CONTENT_BYTES,
                          lf_muhtari_host_get_u64(snapshot + 356U));
  lf_muhtari_host_digest(media, LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES,
                         output + LF_MUHTARI_HOST_SAVE_PAYLOAD_DIGEST);
  lf_muhtari_host_put_u32(output + LF_MUHTARI_HOST_SAVE_API_REVISION, 8U);
  memcpy(output + LF_MUHTARI_HOST_SAVE_HEADER_BYTES, media,
         LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES);
  return 1;
}

static int lf_muhtari_host_save_validate(
    const uint8_t *save, size_t save_extent, const uint8_t *snapshot,
    size_t snapshot_extent, const uint8_t *expected_media,
    uint64_t *generation_out) {
  uint8_t payload_digest[32];
  if (save == NULL || snapshot == NULL || expected_media == NULL ||
      save_extent != LF_MUHTARI_HOST_SAVE_TOTAL_BYTES ||
      snapshot_extent < LF_MUHTARI_HOST_SNAPSHOT_HEADER_BYTES ||
      !lf_muhtari_host_snapshot_integrity_matches(snapshot,
                                                  snapshot_extent) ||
      lf_muhtari_host_get_u64(snapshot + 16U) !=
          (uint64_t)snapshot_extent ||
      lf_muhtari_host_get_u64(snapshot + 24U) !=
          (uint64_t)(snapshot_extent - LF_MUHTARI_HOST_SNAPSHOT_HEADER_BYTES) ||
      memcmp(save, lf_muhtari_host_save_magic,
             sizeof(lf_muhtari_host_save_magic)) != 0 ||
      lf_muhtari_host_get_u32(save + LF_MUHTARI_HOST_SAVE_VERSION) != 1U ||
      lf_muhtari_host_get_u32(save + LF_MUHTARI_HOST_SAVE_HEADER) !=
          LF_MUHTARI_HOST_SAVE_HEADER_BYTES ||
      lf_muhtari_host_get_u64(save + LF_MUHTARI_HOST_SAVE_TOTAL) !=
          (uint64_t)save_extent ||
      lf_muhtari_host_get_u64(save + LF_MUHTARI_HOST_SAVE_MEDIA) !=
          LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES ||
      lf_muhtari_host_get_u32(save + LF_MUHTARI_HOST_SAVE_API_REVISION) != 8U ||
      lf_muhtari_host_get_u32(save + LF_MUHTARI_HOST_SAVE_RESERVED) != 0U ||
      memcmp(save + LF_MUHTARI_HOST_SAVE_CORE_BUILD, snapshot + 44U, 64U) != 0 ||
      memcmp(save + LF_MUHTARI_HOST_SAVE_LIBFUTURO_BUILD, snapshot + 108U, 80U) != 0 ||
      memcmp(save + LF_MUHTARI_HOST_SAVE_PROFILE, snapshot + 188U, 32U) != 0 ||
      memcmp(save + LF_MUHTARI_HOST_SAVE_CONFIGURATION, snapshot + 220U, 32U) != 0 ||
      memcmp(save + LF_MUHTARI_HOST_SAVE_OPTIONS, snapshot + 252U, 32U) != 0 ||
      memcmp(save + LF_MUHTARI_HOST_SAVE_CONTENT_DIGEST, snapshot + 284U, 32U) != 0 ||
      lf_muhtari_host_get_u64(save + LF_MUHTARI_HOST_SAVE_CONTENT_BYTES) !=
          lf_muhtari_host_get_u64(snapshot + 356U) ||
      memcmp(save + LF_MUHTARI_HOST_SAVE_HEADER_BYTES, expected_media,
             LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES) != 0) {
    return 0;
  }
  lf_muhtari_host_digest(save + LF_MUHTARI_HOST_SAVE_HEADER_BYTES,
                         LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES,
                         payload_digest);
  if (memcmp(payload_digest, save + LF_MUHTARI_HOST_SAVE_PAYLOAD_DIGEST,
             sizeof(payload_digest)) != 0) {
    return 0;
  }
  if (generation_out != NULL) {
    *generation_out = lf_muhtari_host_get_u64(
        save + LF_MUHTARI_HOST_SAVE_GENERATION);
  }
  (void)snapshot_extent;
  return 1;
}

static int lf_muhtari_host_ack_bytes(const uint8_t *save, size_t save_extent,
                                     char output[160]) {
  uint8_t digest[32];
  char hex[65];
  int length = 0;
  if (save == NULL || save_extent == 0U) {
    return 0;
  }
  lf_muhtari_host_digest(save, save_extent, digest);
  lf_muhtari_host_hex(digest, hex);
  length = snprintf(output, 160U, "save-sha256=%s\ngeneration=%" PRIu64 "\n",
                    hex, lf_muhtari_host_get_u64(
                             save + LF_MUHTARI_HOST_SAVE_GENERATION));
  return length > 0 && length < 160;
}

static int lf_muhtari_host_replace_file(const char *path, const uint8_t *bytes,
                                        size_t extent) {
  char temp_path[PATH_MAX];
  int descriptor = -1;
  int ok = 0;
  if (path == NULL || bytes == NULL || extent == 0U ||
      !lf_muhtari_host_make_temp(path, temp_path)) {
    return 0;
  }
  descriptor = mkstemp(temp_path);
  if (descriptor < 0) {
    return 0;
  }
  if (!lf_muhtari_host_write_all(descriptor, bytes, extent)) {
    goto cleanup;
  }
  if (close(descriptor) != 0) {
    descriptor = -1;
    goto cleanup;
  }
  descriptor = -1;
  if (rename(temp_path, path) != 0) {
    goto cleanup;
  }
  ok = 1;

cleanup:
  if (descriptor >= 0 && close(descriptor) != 0) {
    ok = 0;
  }
  if (ok == 0) {
    (void)unlink(temp_path);
  }
  return ok;
}

static int lf_muhtari_host_write_checkpoint(const char *path,
                                            const uint8_t *snapshot,
                                            size_t extent, char digest_hex[65]) {
  uint8_t digest[32];
  uint8_t *readback = NULL;
  int ok = 0;
  if (!lf_muhtari_host_replace_file(path, snapshot, extent) ||
      !lf_muhtari_host_read_exact_file(path, extent,
                                       LF_MUHTARI_HOST_SNAPSHOT_MAX_BYTES,
                                       &readback) ||
      memcmp(readback, snapshot, extent) != 0) {
    goto cleanup;
  }
  lf_muhtari_host_digest(readback, extent, digest);
  lf_muhtari_host_hex(digest, digest_hex);
  ok = 1;

cleanup:
  free(readback);
  return ok;
}

static int lf_muhtari_host_pre_rename_failure(const char *save_path,
                                               const uint8_t *save,
                                               size_t extent) {
  char temp_path[PATH_MAX];
  int descriptor = -1;
  int ok = 0;
  const size_t prefix = extent / 2U;
  if (save_path == NULL || save == NULL || prefix == 0U ||
      !lf_muhtari_host_make_temp(save_path, temp_path)) {
    return 0;
  }
  descriptor = mkstemp(temp_path);
  if (descriptor < 0) {
    return 0;
  }
  if (!lf_muhtari_host_write_all(descriptor, save, prefix)) {
    goto cleanup;
  }
  if (close(descriptor) != 0) {
    descriptor = -1;
    goto cleanup;
  }
  descriptor = -1;
  if (unlink(temp_path) != 0) {
    return 0;
  }
  return lstat(temp_path, &(struct stat){0}) != 0 && errno == ENOENT;

cleanup:
  if (descriptor >= 0 && close(descriptor) != 0) {
    ok = 0;
  }
  (void)unlink(temp_path);
  return ok;
}

static int lf_muhtari_host_commit_save(const char *save_path,
                                       const char *ack_path,
                                       const uint8_t *snapshot,
                                       size_t snapshot_extent,
                                       const uint8_t *media,
                                       uint64_t generation,
                                       char digest_hex[65],
                                       char ack_save_digest_hex[65]) {
  uint8_t *save = NULL;
  uint8_t *readback = NULL;
  uint8_t payload_digest[32];
  char ack[160];
  char ack_temp[PATH_MAX] = {0};
  const char *failed_at = "allocate-or-encode";
  int descriptor = -1;
  int ok = 0;
  save = (uint8_t *)malloc(LF_MUHTARI_HOST_SAVE_TOTAL_BYTES);
  if (save == NULL ||
      !lf_muhtari_host_save_encode(snapshot, snapshot_extent, media, generation,
                                   save) ||
      !lf_muhtari_host_make_temp(save_path, ack_temp)) {
    goto cleanup;
  }
  descriptor = mkstemp(ack_temp);
  failed_at = "save-stage-create-or-write";
  if (descriptor < 0 ||
      !lf_muhtari_host_write_all(descriptor, save,
                                 LF_MUHTARI_HOST_SAVE_TOTAL_BYTES)) {
    goto cleanup;
  }
  failed_at = "save-stage-close";
  if (close(descriptor) != 0) {
    descriptor = -1;
    goto cleanup;
  }
  descriptor = -1;
  failed_at = "save-rename-or-readback";
  if (rename(ack_temp, save_path) != 0 ||
      !lf_muhtari_host_read_exact_file(save_path,
                                       LF_MUHTARI_HOST_SAVE_TOTAL_BYTES,
                                       LF_MUHTARI_HOST_SAVE_TOTAL_BYTES,
                                       &readback) ||
      memcmp(readback, save, LF_MUHTARI_HOST_SAVE_TOTAL_BYTES) != 0 ||
      !lf_muhtari_host_save_validate(
          readback, LF_MUHTARI_HOST_SAVE_TOTAL_BYTES, snapshot,
          snapshot_extent, media, NULL)) {
    goto cleanup;
  }
  lf_muhtari_host_digest(readback, LF_MUHTARI_HOST_SAVE_TOTAL_BYTES,
                         payload_digest);
  lf_muhtari_host_hex(payload_digest, digest_hex);
  failed_at = "ack-encode-or-stage-name";
  if (!lf_muhtari_host_ack_bytes(readback,
                                 LF_MUHTARI_HOST_SAVE_TOTAL_BYTES, ack) ||
      !lf_muhtari_host_make_temp(ack_path, ack_temp)) {
    goto cleanup;
  }
  descriptor = mkstemp(ack_temp);
  failed_at = "ack-stage-create-or-write";
  if (descriptor < 0 ||
      !lf_muhtari_host_write_all(descriptor, (const uint8_t *)ack,
                                 strlen(ack))) {
    goto cleanup;
  }
  failed_at = "ack-stage-close";
  if (close(descriptor) != 0) {
    descriptor = -1;
    goto cleanup;
  }
  descriptor = -1;
  failed_at = "ack-rename";
  if (rename(ack_temp, ack_path) != 0) {
    goto cleanup;
  }
  {
    uint8_t *ack_readback = NULL;
    const size_t ack_extent = strlen(ack);
    if (!lf_muhtari_host_read_exact_file(ack_path, ack_extent, 160U,
                                         &ack_readback) ||
        memcmp(ack_readback, ack, ack_extent) != 0) {
      free(ack_readback);
      failed_at = "ack-readback";
      goto cleanup;
    }
    free(ack_readback);
  }
  if (ack_save_digest_hex != NULL) {
    (void)snprintf(ack_save_digest_hex, 65U, "%s", digest_hex);
  }
  failed_at = NULL;
  ok = 1;

cleanup:
  if (ok == 0 && failed_at != NULL) {
    (void)fprintf(stderr,
                  "muhtari_api8_host_save: transaction failed at %s errno=%d\n",
                  failed_at, errno);
  }
  if (descriptor >= 0) {
    if (close(descriptor) != 0) {
      ok = 0;
    }
    (void)unlink(ack_temp);
  }
  if (ok == 0 && ack_temp[0] != '\0') {
    (void)unlink(ack_temp);
  }
  free(readback);
  free(save);
  return ok;
}

static int lf_muhtari_host_read_save(const char *save_path,
                                     const char *ack_path,
                                     const uint8_t *snapshot,
                                     size_t snapshot_extent,
                                     const uint8_t *expected_media,
                                     uint8_t **media_out,
                                     uint64_t *generation_out,
                                     char digest_hex[65]) {
  uint8_t *save = NULL;
  uint8_t *ack = NULL;
  uint8_t digest[32];
  char expected_ack[160];
  const char *failed_at = "arguments";
  int ok = 0;
  if (media_out == NULL || generation_out == NULL || digest_hex == NULL) {
    return 0;
  }
  *media_out = NULL;
  failed_at = "save-file-read";
  if (!lf_muhtari_host_read_exact_file(
          save_path, LF_MUHTARI_HOST_SAVE_TOTAL_BYTES,
          LF_MUHTARI_HOST_SAVE_TOTAL_BYTES, &save)) {
    goto cleanup;
  }
  failed_at = "save-identity-extent-or-payload";
  if (!lf_muhtari_host_save_validate(save, LF_MUHTARI_HOST_SAVE_TOTAL_BYTES,
                                     snapshot, snapshot_extent, expected_media,
                                     generation_out)) {
    goto cleanup;
  }
  failed_at = "ack-template";
  if (!lf_muhtari_host_ack_bytes(save, LF_MUHTARI_HOST_SAVE_TOTAL_BYTES,
                                 expected_ack)) {
    goto cleanup;
  }
  failed_at = "ack-file-read";
  if (!lf_muhtari_host_read_exact_file(ack_path, strlen(expected_ack), 160U,
                                       &ack)) {
    goto cleanup;
  }
  failed_at = "ack-bytes-mismatch";
  if (memcmp(ack, expected_ack, strlen(expected_ack)) != 0) {
    goto cleanup;
  }
  *media_out = (uint8_t *)malloc(LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES);
  if (*media_out == NULL) {
    goto cleanup;
  }
  memcpy(*media_out, save + LF_MUHTARI_HOST_SAVE_HEADER_BYTES,
         LF_MUHTARI_SNAPSHOT_FIXTURE_MEDIA_BYTES);
  lf_muhtari_host_digest(save, LF_MUHTARI_HOST_SAVE_TOTAL_BYTES, digest);
  lf_muhtari_host_hex(digest, digest_hex);
  failed_at = NULL;
  ok = 1;

cleanup:
  if (ok == 0 && failed_at != NULL) {
    (void)fprintf(stderr,
                  "muhtari_api8_host_save: selected save refused at %s errno=%d\n",
                  failed_at, errno);
  }
  free(ack);
  free(save);
  if (ok == 0) {
    free(*media_out);
    *media_out = NULL;
  }
  return ok;
}

#endif
