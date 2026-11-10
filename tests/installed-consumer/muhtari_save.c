#define _POSIX_C_SOURCE 200809L

#include <libfuturo/libfuturo.h>

#include "muhtari_oracle.h"
#include "muhtari_save_oracle.h"

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef LIBFUTURO_MUHTARI_SOURCE_REVISION
#define LIBFUTURO_MUHTARI_SOURCE_REVISION "unverified"
#endif

#define SAVE_HEADER_BYTES 128U
#define SAVE_VERSION 1U
#define SAVE_MAX_FRAMES 2400U
#define VIDEO_BYTES (320U * 242U)
#define AUDIO_SAMPLES 801U

typedef struct save_acknowledgment {
  const uint8_t *payload;
  size_t extent_bytes;
  uint64_t guest_generation;
  int committed;
} save_acknowledgment;

typedef enum save_commit_status {
  SAVE_COMMIT_FAILED = 0,
  SAVE_COMMIT_COMMITTED = 1,
  SAVE_COMMIT_INJECTED_PREFIX_FAILURE = 2
} save_commit_status;

static const uint8_t k_save_magic[8] = {'L', 'F', 'M', 'U', 'S', 'A', 'V', '1'};

static int fail(const char *message) {
  (void)fprintf(stderr, "muhtari_save: %s failed\n", message);
  return 1;
}

static void digest_bytes(const uint8_t *bytes, size_t count,
                         uint8_t digest[32]) {
  lf_muhtari_oracle_sha256 context;
  lf_muhtari_oracle_sha256_init(&context);
  lf_muhtari_oracle_sha256_update(&context, bytes, count);
  lf_muhtari_oracle_sha256_finish(&context, digest);
}

static int digest_matches_fixture(const uint8_t *bytes, size_t count,
                                  uint8_t digest[32]) {
  char actual[65];
  digest_bytes(bytes, count, digest);
  lf_muhtari_oracle_hex_digest(digest, actual);
  return count == LF_MUHTARI_SAVE_FIXTURE_BYTES &&
         strcmp(actual, LF_MUHTARI_SAVE_FIXTURE_SHA256) == 0;
}

static int read_fixture(const char *path, uint8_t **bytes_out,
                        size_t *size_out, uint8_t digest[32]) {
  FILE *file = NULL;
  long measured_size = 0L;
  uint8_t *bytes = NULL;
  size_t size = 0U;
  int ok = 0;
  if (path == NULL || bytes_out == NULL || size_out == NULL ||
      digest == NULL) {
    return 0;
  }
  *bytes_out = NULL;
  *size_out = 0U;
  file = fopen(path, "rb");
  if (file == NULL || fseek(file, 0L, SEEK_END) != 0 ||
      (measured_size = ftell(file)) < 0L ||
      (unsigned long)measured_size !=
          (unsigned long)LF_MUHTARI_SAVE_FIXTURE_BYTES ||
      fseek(file, 0L, SEEK_SET) != 0) {
    goto cleanup;
  }
  size = (size_t)measured_size;
  bytes = (uint8_t *)malloc(size);
  if (bytes == NULL || fread(bytes, 1U, size, file) != size ||
      fgetc(file) != EOF || ferror(file) != 0 ||
      !digest_matches_fixture(bytes, size, digest)) {
    goto cleanup;
  }
  *bytes_out = bytes;
  *size_out = size;
  bytes = NULL;
  ok = 1;

cleanup:
  if (file != NULL && fclose(file) != 0) {
    ok = 0;
  }
  free(bytes);
  if (ok == 0) {
    free(*bytes_out);
    *bytes_out = NULL;
    *size_out = 0U;
  }
  return ok;
}

static void put_u32_le(uint8_t *destination, uint32_t value) {
  for (size_t index = 0U; index < 4U; ++index) {
    destination[index] = (uint8_t)(value >> (unsigned int)(index * 8U));
  }
}

static void put_u64_le(uint8_t *destination, uint64_t value) {
  for (size_t index = 0U; index < 8U; ++index) {
    destination[index] = (uint8_t)(value >> (unsigned int)(index * 8U));
  }
}

static uint32_t get_u32_le(const uint8_t *source) {
  uint32_t value = 0U;
  for (size_t index = 0U; index < 4U; ++index) {
    value |= (uint32_t)source[index] << (unsigned int)(index * 8U);
  }
  return value;
}

static uint64_t get_u64_le(const uint8_t *source) {
  uint64_t value = 0U;
  for (size_t index = 0U; index < 8U; ++index) {
    value |= (uint64_t)source[index] << (unsigned int)(index * 8U);
  }
  return value;
}

static int fixed_field_matches(const uint8_t *field, size_t field_size,
                               const char *expected) {
  const size_t expected_size = strlen(expected);
  const uint8_t *terminator =
      (const uint8_t *)memchr(field, 0, field_size);
  if (terminator == NULL || (size_t)(terminator - field) != expected_size ||
      memcmp(field, expected, expected_size) != 0) {
    return 0;
  }
  for (size_t index = expected_size + 1U; index < field_size; ++index) {
    if (field[index] != 0U) {
      return 0;
    }
  }
  return 1;
}

static void make_save_header(uint8_t header[SAVE_HEADER_BYTES],
                             const uint8_t content_digest[32],
                             uint64_t generation) {
  memset(header, 0, SAVE_HEADER_BYTES);
  memcpy(header, k_save_magic, sizeof(k_save_magic));
  put_u32_le(header + 8U, SAVE_VERSION);
  put_u32_le(header + 12U, SAVE_HEADER_BYTES);
  put_u64_le(header + 16U, LF_MUHTARI_SAVE_MEDIA_BYTES);
  put_u64_le(header + 24U, generation);
  memcpy(header + 32U, content_digest, 32U);
  memcpy(header + 64U, "muhtari-ntsc-battery-diagnostic",
         sizeof("muhtari-ntsc-battery-diagnostic"));
  memcpy(header + 104U, "muhtari-battery-v1",
         sizeof("muhtari-battery-v1"));
}

static int validate_save_header(const uint8_t *header,
                                const uint8_t content_digest[32]) {
  return memcmp(header, k_save_magic, sizeof(k_save_magic)) == 0 &&
         get_u32_le(header + 8U) == SAVE_VERSION &&
         get_u32_le(header + 12U) == SAVE_HEADER_BYTES &&
         get_u64_le(header + 16U) == LF_MUHTARI_SAVE_MEDIA_BYTES &&
         memcmp(header + 32U, content_digest, 32U) == 0 &&
         fixed_field_matches(header + 64U, 40U,
                             "muhtari-ntsc-battery-diagnostic") &&
         fixed_field_matches(header + 104U, 24U, "muhtari-battery-v1");
}

static int copy_media(lf_instance *instance, uint8_t *media,
                      lf_media_info *info);

static int import_save_envelope(lf_instance *instance, const uint8_t *save,
                                size_t save_size,
                                const uint8_t content_digest[32],
                                size_t *import_calls) {
  const size_t expected_save_size =
      (size_t)SAVE_HEADER_BYTES + (size_t)LF_MUHTARI_SAVE_MEDIA_BYTES;
  if (instance == NULL || save == NULL || content_digest == NULL ||
      import_calls == NULL || save_size != expected_save_size ||
      !validate_save_header(save, content_digest)) {
    return 0;
  }
  ++*import_calls;
  return lf_import_media(instance, "muhtari-battery-v1",
                         save + SAVE_HEADER_BYTES,
                         LF_MUHTARI_SAVE_MEDIA_BYTES) == LF_OK;
}

static int rejects_save_without_media_change(
    lf_instance *instance, const uint8_t *candidate, size_t candidate_size,
    const uint8_t content_digest[32], const uint8_t *baseline,
    uint8_t *observed, size_t *import_calls) {
  lf_media_info info = {.struct_size = sizeof(info)};
  size_t calls_before = 0U;
  if (import_calls == NULL) {
    return 0;
  }
  calls_before = *import_calls;
  if (import_save_envelope(instance, candidate, candidate_size,
                           content_digest, import_calls) ||
      *import_calls != calls_before || !copy_media(instance, observed, &info)) {
    return 0;
  }
  return memcmp(observed, baseline, LF_MUHTARI_SAVE_MEDIA_BYTES) == 0;
}

static int verify_rejected_envelopes(lf_instance *instance,
                                     const uint8_t *valid_save,
                                     size_t valid_save_size,
                                     const uint8_t content_digest[32],
                                     const uint8_t *baseline,
                                     uint8_t *observed,
                                     size_t *import_calls) {
  const size_t expected_save_size =
      (size_t)SAVE_HEADER_BYTES + (size_t)LF_MUHTARI_SAVE_MEDIA_BYTES;
  uint8_t *candidate = NULL;
  size_t rejected_cases = 0U;
  int ok = 0;
  if (valid_save == NULL || valid_save_size != expected_save_size ||
      content_digest == NULL || baseline == NULL || observed == NULL ||
      import_calls == NULL) {
    return 0;
  }
  candidate = (uint8_t *)malloc(expected_save_size + 1U);
  if (candidate == NULL) {
    return 0;
  }

#define CHECK_REJECTED_MUTATION(statement)                                  \
  do {                                                                      \
    memcpy(candidate, valid_save, expected_save_size);                      \
    statement;                                                              \
    if (!rejects_save_without_media_change(                                 \
            instance, candidate, expected_save_size, content_digest,        \
            baseline, observed, import_calls)) {                            \
      goto cleanup;                                                         \
    }                                                                       \
    ++rejected_cases;                                                       \
  } while (0)

  CHECK_REJECTED_MUTATION(candidate[0] ^= UINT8_C(0x01));
  CHECK_REJECTED_MUTATION(put_u32_le(candidate + 8U, SAVE_VERSION + 1U));
  CHECK_REJECTED_MUTATION(put_u32_le(candidate + 12U, SAVE_HEADER_BYTES + 1U));
  CHECK_REJECTED_MUTATION(candidate[32U] ^= UINT8_C(0x01));
  CHECK_REJECTED_MUTATION(candidate[64U] ^= UINT8_C(0x01));
  CHECK_REJECTED_MUTATION(candidate[104U] ^= UINT8_C(0x01));
  CHECK_REJECTED_MUTATION(
      put_u64_le(candidate + 16U, LF_MUHTARI_SAVE_MEDIA_BYTES + 1U));
  CHECK_REJECTED_MUTATION(
      candidate[64U + sizeof("muhtari-ntsc-battery-diagnostic")] =
          UINT8_C(0xA5));

  memcpy(candidate, valid_save, expected_save_size);
  if (!rejects_save_without_media_change(
          instance, candidate, expected_save_size - 1U, content_digest,
          baseline, observed, import_calls)) {
    goto cleanup;
  }
  ++rejected_cases;

  memcpy(candidate, valid_save, expected_save_size);
  candidate[expected_save_size] = UINT8_C(0xA5);
  if (!rejects_save_without_media_change(
          instance, candidate, expected_save_size + 1U, content_digest,
          baseline, observed, import_calls)) {
    goto cleanup;
  }
  ++rejected_cases;
  ok = rejected_cases == 10U;

cleanup:
#undef CHECK_REJECTED_MUTATION
  free(candidate);
  return ok;
}

static int write_all(int descriptor, const uint8_t *bytes, size_t size) {
  size_t written = 0U;
  while (written < size) {
    const ssize_t result = write(descriptor, bytes + written, size - written);
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

static int read_all(int descriptor, uint8_t *bytes, size_t size) {
  size_t received = 0U;
  while (received < size) {
    const ssize_t result = read(descriptor, bytes + received, size - received);
    if (result < 0) {
      if (errno == EINTR) {
        continue;
      }
      return 0;
    }
    if (result == 0) {
      return 0;
    }
    received += (size_t)result;
  }
  return 1;
}

static int read_save_file(const char *path, uint8_t **save_out,
                          size_t *save_size_out) {
  const size_t expected_size =
      (size_t)SAVE_HEADER_BYTES + (size_t)LF_MUHTARI_SAVE_MEDIA_BYTES;
  struct stat file_status;
  uint8_t *save = NULL;
  int descriptor = -1;
  int ok = 0;
  if (path == NULL || save_out == NULL || save_size_out == NULL) {
    return 0;
  }
  *save_out = NULL;
  *save_size_out = 0U;
  descriptor = open(path, O_RDONLY);
  if (descriptor < 0 || fstat(descriptor, &file_status) != 0 ||
      file_status.st_size < 0 ||
      (uintmax_t)file_status.st_size != (uintmax_t)expected_size) {
    goto cleanup;
  }
  save = (uint8_t *)malloc(expected_size);
  if (save == NULL || !read_all(descriptor, save, expected_size)) {
    goto cleanup;
  }
  {
    uint8_t trailing = 0U;
    if (read(descriptor, &trailing, 1U) != 0) {
      goto cleanup;
    }
  }
  *save_out = save;
  *save_size_out = expected_size;
  save = NULL;
  ok = 1;

cleanup:
  if (descriptor >= 0 && close(descriptor) != 0) {
    ok = 0;
  }
  free(save);
  if (ok == 0) {
    free(*save_out);
    *save_out = NULL;
    *save_size_out = 0U;
  }
  return ok;
}

static int acknowledge_committed_file(const char *path,
                                     const uint8_t *expected_save,
                                     size_t expected_size,
                                     save_acknowledgment *acknowledgment) {
  uint8_t *readback = NULL;
  size_t readback_size = 0U;
  int ok = 0;
  if (path == NULL || expected_save == NULL || acknowledgment == NULL ||
      expected_size !=
          (size_t)SAVE_HEADER_BYTES + (size_t)LF_MUHTARI_SAVE_MEDIA_BYTES ||
      !read_save_file(path, &readback, &readback_size) ||
      readback_size != expected_size ||
      memcmp(readback, expected_save, expected_size) != 0) {
    goto cleanup;
  }
  *acknowledgment = (save_acknowledgment){
      .payload = expected_save + SAVE_HEADER_BYTES,
      .extent_bytes = LF_MUHTARI_SAVE_MEDIA_BYTES,
      .guest_generation = get_u64_le(expected_save + 24U),
      .committed = 1,
  };
  ok = 1;

cleanup:
  free(readback);
  return ok;
}

static int acknowledgments_match(const save_acknowledgment *left,
                                 const save_acknowledgment *right) {
  return left != NULL && right != NULL && left->committed == 1 &&
         right->committed == 1 && left->payload != NULL &&
         right->payload != NULL && left->extent_bytes == right->extent_bytes &&
         left->extent_bytes == LF_MUHTARI_SAVE_MEDIA_BYTES &&
         left->guest_generation == right->guest_generation &&
         memcmp(left->payload, right->payload, left->extent_bytes) == 0;
}

static int acknowledgment_matches_media(const save_acknowledgment *acknowledgment,
                                        const uint8_t *media,
                                        uint64_t generation) {
  return acknowledgment != NULL && media != NULL &&
         acknowledgment->committed == 1 &&
         acknowledgment->payload != NULL &&
         acknowledgment->extent_bytes == LF_MUHTARI_SAVE_MEDIA_BYTES &&
         acknowledgment->guest_generation == generation &&
         memcmp(acknowledgment->payload, media,
                LF_MUHTARI_SAVE_MEDIA_BYTES) == 0;
}

static save_commit_status commit_save(const char *path, const uint8_t *header,
                                      const uint8_t *media,
                                      int inject_partial_write_failure,
                                      save_acknowledgment *acknowledgment,
                                      int *temporary_removed) {
  static const char suffix[] = ".stage.XXXXXX";
  size_t path_size = 0U;
  const size_t total_size =
      (size_t)SAVE_HEADER_BYTES + (size_t)LF_MUHTARI_SAVE_MEDIA_BYTES;
  char *temporary_path = NULL;
  uint8_t *expected = NULL;
  uint8_t *readback = NULL;
  size_t readback_size = 0U;
  int descriptor = -1;
  int temporary_created = 0;
  save_commit_status result = SAVE_COMMIT_FAILED;
  save_acknowledgment next_acknowledgment = {0};
  if (temporary_removed != NULL) {
    *temporary_removed = 0;
  }
  if (path == NULL || header == NULL || media == NULL ||
      acknowledgment == NULL || temporary_removed == NULL ||
      (inject_partial_write_failure != 0 &&
       inject_partial_write_failure != 1)) {
    return SAVE_COMMIT_FAILED;
  }
  path_size = strlen(path);
  if (path_size > SIZE_MAX - sizeof(suffix)) {
    return SAVE_COMMIT_FAILED;
  }
  temporary_path = (char *)malloc(path_size + sizeof(suffix));
  expected = (uint8_t *)malloc(total_size);
  if (temporary_path == NULL || expected == NULL) {
    goto cleanup;
  }
  memcpy(temporary_path, path, path_size);
  memcpy(temporary_path + path_size, suffix, sizeof(suffix));
  memcpy(expected, header, SAVE_HEADER_BYTES);
  memcpy(expected + SAVE_HEADER_BYTES, media, LF_MUHTARI_SAVE_MEDIA_BYTES);
  descriptor = mkstemp(temporary_path);
  if (descriptor < 0) {
    goto cleanup;
  }
  temporary_created = 1;
  if (inject_partial_write_failure != 0) {
    const size_t partial_payload_bytes =
        (size_t)LF_MUHTARI_SAVE_MEDIA_BYTES / 2U;
    if (!write_all(descriptor, expected, SAVE_HEADER_BYTES) ||
        partial_payload_bytes == 0U ||
        !write_all(descriptor, expected + SAVE_HEADER_BYTES,
                   partial_payload_bytes)) {
      goto cleanup;
    }
    result = SAVE_COMMIT_INJECTED_PREFIX_FAILURE;
    goto cleanup;
  }
  if (!write_all(descriptor, expected, total_size)) {
    goto cleanup;
  }
  if (close(descriptor) != 0) {
    descriptor = -1;
    goto cleanup;
  }
  descriptor = -1;
  if (rename(temporary_path, path) != 0 ||
      !read_save_file(path, &readback, &readback_size) ||
      readback_size != total_size ||
      memcmp(readback, expected, total_size) != 0 ||
      !acknowledge_committed_file(path, expected, total_size,
                                  &next_acknowledgment)) {
    goto cleanup;
  }
  next_acknowledgment.payload = media;
  *acknowledgment = next_acknowledgment;
  result = SAVE_COMMIT_COMMITTED;

cleanup:
  if (descriptor >= 0) {
    (void)close(descriptor);
  }
  if (temporary_created != 0 && result != SAVE_COMMIT_COMMITTED) {
    if (unlink(temporary_path) == 0 || errno == ENOENT) {
      if (access(temporary_path, F_OK) == -1 && errno == ENOENT) {
        *temporary_removed = 1;
      } else {
        result = SAVE_COMMIT_FAILED;
      }
    } else {
      result = SAVE_COMMIT_FAILED;
    }
    if (*temporary_removed == 0) {
      result = SAVE_COMMIT_FAILED;
    }
  }
  free(readback);
  free(expected);
  free(temporary_path);
  return result;
}

static int verify_discovery(void) {
  lf_profile default_profile = {.struct_size = sizeof(lf_profile)};
  lf_profile diagnostic_profile = {.struct_size = sizeof(lf_profile)};
  uint32_t supported = 0U;
  return lf_get_profile("muhtari-ntsc-v1", NULL, &default_profile) == LF_OK &&
         default_profile.input_mask == UINT32_C(0xF1F1) &&
         default_profile.effective_configuration_id != NULL &&
         strcmp(default_profile.effective_configuration_id,
                "muhtari-ntsc-joystick-default") == 0 &&
         lf_get_profile("muhtari-ntsc-v1",
                        "muhtari-ntsc-battery-diagnostic",
                        &diagnostic_profile) == LF_OK &&
         diagnostic_profile.input_mask == UINT32_C(0xF1) &&
         diagnostic_profile.effective_configuration_id != NULL &&
         strcmp(diagnostic_profile.effective_configuration_id,
                "muhtari-ntsc-battery-diagnostic") == 0 &&
         lf_get_capability("muhtari-ntsc-v1", NULL,
                           LF_CAP_IN_MEMORY_MEDIA_COPY, &supported) ==
             LF_UNSUPPORTED &&
         supported == 0U;
}

static int create_loaded_instance(const uint8_t *content, size_t content_size,
                                  lf_instance **instance_out) {
  lf_load_result loaded = {.struct_size = sizeof(lf_load_result)};
  if (instance_out == NULL) {
    return 0;
  }
  *instance_out = NULL;
  if (lf_create("muhtari-ntsc-v1", NULL, instance_out) != LF_OK ||
      *instance_out == NULL ||
      lf_load(*instance_out,
              &(lf_load_request){
                  .struct_size = sizeof(lf_load_request),
                  .content_data = content,
                  .content_size_bytes = content_size,
                  .configuration_id =
                      "muhtari-ntsc-battery-diagnostic",
              },
              &loaded) != LF_OK ||
      loaded.loaded != 1U || loaded.content_size_bytes != content_size ||
      loaded.effective_configuration_id == NULL ||
      strcmp(loaded.effective_configuration_id,
             "muhtari-ntsc-battery-diagnostic") != 0) {
    (void)lf_destroy(instance_out);
    return 0;
  }
  return 1;
}

static int copy_media(lf_instance *instance, uint8_t *media,
                      lf_media_info *info) {
  if (info == NULL) {
    return 0;
  }
  *info = (lf_media_info){.struct_size = sizeof(*info)};
  return lf_copy_media(instance, media, LF_MUHTARI_SAVE_MEDIA_BYTES, info) ==
             LF_OK &&
         info->identity != NULL &&
         strcmp(info->identity, "muhtari-battery-v1") == 0 &&
         info->extent_bytes == LF_MUHTARI_SAVE_MEDIA_BYTES;
}

static int advance_to_progress(lf_instance *instance, uint8_t *media,
                               uint8_t counter, lf_media_info *info) {
  uint8_t video[VIDEO_BYTES];
  int16_t audio[AUDIO_SAMPLES];
  for (size_t frame = 0U; frame < SAVE_MAX_FRAMES; ++frame) {
    lf_run_result result = {.struct_size = sizeof(lf_run_result)};
    const lf_run_request request = {
        .struct_size = sizeof(lf_run_request),
        .work_units = 1U,
        .video_data = video,
        .video_capacity_bytes = sizeof(video),
        .video_stride_bytes = 320U,
        .audio_data = audio,
        .audio_capacity_samples = AUDIO_SAMPLES,
    };
    if (lf_advance(instance, &request, &result) != LF_OK ||
        result.actual_units != 1U || !copy_media(instance, media, info)) {
      return 0;
    }
    if (lf_muhtari_save_oracle_matches(media, counter)) {
      return 1;
    }
    if (result.stop_reason == LF_STOP_CORE_HALTED) {
      return 0;
    }
  }
  return 0;
}

static int run_save_oracle_probe(const char *fixture_path,
                                 int deliberately_wrong) {
  uint8_t *content = NULL;
  size_t content_size = 0U;
  uint8_t content_digest[32];
  uint8_t *media = NULL;
  lf_media_info info = {.struct_size = sizeof(info)};
  lf_instance *instance = NULL;
  int result = 1;

  media = (uint8_t *)malloc(LF_MUHTARI_SAVE_MEDIA_BYTES);
  if (media == NULL ||
      !read_fixture(fixture_path, &content, &content_size, content_digest) ||
      !create_loaded_instance(content, content_size, &instance) ||
      !copy_media(instance, media, &info) ||
      !advance_to_progress(instance, media, UINT8_C(1), &info)) {
    (void)fail("save oracle probe reaches normal 1/1 progress");
    goto cleanup;
  }

  if (deliberately_wrong != 0) {
    if (lf_muhtari_save_oracle_matches(media, UINT8_C(2))) {
      (void)fail("deliberately wrong 2/2 expectation unexpectedly matched");
      goto cleanup;
    }
    (void)fprintf(stderr,
                  "muhtari_save_oracle: full-span mismatch expected=2/2 "
                  "actual=1/1\n");
    result = 1;
  } else {
    if (!lf_muhtari_save_oracle_matches(media, UINT8_C(1))) {
      (void)fail("normal full-span 1/1 expectation");
      goto cleanup;
    }
    (void)printf(
        "muhtari_save_oracle: normal full-span progress=1/1 result=pass\n");
    result = 0;
  }

cleanup:
  (void)lf_destroy(&instance);
  free(content);
  free(media);
  return result;
}

static int run_writer(const char *fixture_path, const char *save_path) {
  uint8_t *content = NULL;
  size_t content_size = 0U;
  uint8_t content_digest[32];
  uint8_t *media = NULL;
  uint8_t header[SAVE_HEADER_BYTES];
  save_acknowledgment acknowledgment = {0};
  int temporary_removed = 0;
  lf_media_info info = {.struct_size = sizeof(info)};
  lf_instance *instance = NULL;
  int result = 1;
  media = (uint8_t *)malloc(LF_MUHTARI_SAVE_MEDIA_BYTES);
  if (media == NULL || !verify_discovery() ||
      !lf_muhtari_oracle_sha256_self_check() ||
      !read_fixture(fixture_path, &content, &content_size, content_digest) ||
      !create_loaded_instance(content, content_size, &instance) ||
      !copy_media(instance, media, &info) ||
      !lf_muhtari_save_oracle_is_fresh(media) ||
      !advance_to_progress(instance, media, UINT8_C(1), &info) ||
      !lf_muhtari_save_oracle_matches(media, UINT8_C(1))) {
    (void)fail("writer load, diagnostic progress, and full-span oracle");
    goto cleanup;
  }
  make_save_header(header, content_digest, info.guest_generation);
  if (commit_save(save_path, header, media, 0, &acknowledgment,
                  &temporary_removed) != SAVE_COMMIT_COMMITTED ||
      !acknowledgment_matches_media(&acknowledgment, media,
                                    info.guest_generation)) {
    (void)fail("same-directory staged commit and exact readback");
    goto cleanup;
  }
  (void)printf(
      "muhtari_save_writer: source=%s fixture=%s@%s license=%s extent=%zu "
      "progress=1/1 committed=rename-readback generation=%" PRIu64
      " result=pass\n",
      LIBFUTURO_MUHTARI_SOURCE_REVISION,
      LF_MUHTARI_SAVE_FIXTURE_SOURCE_COMMIT, LF_MUHTARI_SAVE_FIXTURE_SHA256,
      LF_MUHTARI_SAVE_FIXTURE_LICENSE, info.extent_bytes,
      info.guest_generation);
  result = 0;

cleanup:
  (void)lf_destroy(&instance);
  free(content);
  free(media);
  return result;
}

static int run_restorer(const char *fixture_path, const char *save_path) {
  const size_t expected_save_size =
      (size_t)SAVE_HEADER_BYTES + (size_t)LF_MUHTARI_SAVE_MEDIA_BYTES;
  uint8_t *content = NULL;
  size_t content_size = 0U;
  uint8_t content_digest[32];
  uint8_t *saved = NULL;
  size_t saved_size = 0U;
  uint8_t *media = NULL;
  uint8_t *baseline = NULL;
  lf_media_info info = {.struct_size = sizeof(info)};
  lf_instance *instance = NULL;
  size_t import_calls = 0U;
  int result = 1;
  media = (uint8_t *)malloc(LF_MUHTARI_SAVE_MEDIA_BYTES);
  baseline = (uint8_t *)malloc(LF_MUHTARI_SAVE_MEDIA_BYTES);
  if (media == NULL || baseline == NULL || !verify_discovery() ||
      !lf_muhtari_oracle_sha256_self_check() ||
      !read_fixture(fixture_path, &content, &content_size, content_digest) ||
      !read_save_file(save_path, &saved, &saved_size) ||
      saved_size != expected_save_size ||
      !validate_save_header(saved, content_digest) ||
      !lf_muhtari_save_oracle_matches(
          saved + SAVE_HEADER_BYTES, UINT8_C(1)) ||
      !create_loaded_instance(content, content_size, &instance) ||
      !copy_media(instance, media, &info) ||
      !lf_muhtari_save_oracle_is_fresh(media)) {
    (void)fail("restorer validates identities and fresh baseline");
    goto cleanup;
  }
  memcpy(baseline, media, LF_MUHTARI_SAVE_MEDIA_BYTES);
  if (!verify_rejected_envelopes(instance, saved, saved_size, content_digest,
                                 baseline, media, &import_calls) ||
      import_calls != 0U ||
      !import_save_envelope(instance, saved, saved_size, content_digest,
                            &import_calls) ||
      import_calls != 1U ||
      !copy_media(instance, media, &info) ||
      !lf_muhtari_save_oracle_matches(media, UINT8_C(1))) {
    (void)fail("restorer imports the committed media before guest work");
    goto cleanup;
  }
  if (!advance_to_progress(instance, media, UINT8_C(2), &info) ||
      !lf_muhtari_save_oracle_matches(media, UINT8_C(2))) {
    (void)fail("restored diagnostic continuation reaches independent 2/2 oracle");
    goto cleanup;
  }
  (void)printf(
      "muhtari_save_restorer: source=%s fixture=%s@%s configuration="
      "muhtari-ntsc-battery-diagnostic media=muhtari-battery-v1 extent=%zu "
      "import=before-guest-work restored=1/1 continuation=2/2 result=pass\n",
      LIBFUTURO_MUHTARI_SOURCE_REVISION,
      LF_MUHTARI_SAVE_FIXTURE_SOURCE_COMMIT, LF_MUHTARI_SAVE_FIXTURE_SHA256,
      info.extent_bytes);
  (void)printf(
      "muhtari_save_rejections: cases=10 invalid-imports=0 "
      "unchanged-live-span=34816 valid-import=before-guest-work result=pass\n");
  result = 0;

cleanup:
  (void)lf_destroy(&instance);
  free(content);
  free(saved);
  free(media);
  free(baseline);
  return result;
}

static int run_failed_update(const char *fixture_path, const char *save_path) {
  const size_t expected_save_size =
      (size_t)SAVE_HEADER_BYTES + (size_t)LF_MUHTARI_SAVE_MEDIA_BYTES;
  uint8_t *content = NULL;
  size_t content_size = 0U;
  uint8_t content_digest[32];
  uint8_t *saved = NULL;
  size_t saved_size = 0U;
  uint8_t *current = NULL;
  size_t current_size = 0U;
  uint8_t *media = NULL;
  uint8_t header[SAVE_HEADER_BYTES];
  size_t import_calls = 0U;
  save_acknowledgment previous_acknowledgment = {0};
  save_acknowledgment host_acknowledgment = {0};
  save_commit_status commit_status = SAVE_COMMIT_FAILED;
  lf_media_info info = {.struct_size = sizeof(info)};
  lf_instance *instance = NULL;
  int temporary_removed = 0;
  int result = 1;
  media = (uint8_t *)malloc(LF_MUHTARI_SAVE_MEDIA_BYTES);
  if (media == NULL || !verify_discovery() ||
      !lf_muhtari_oracle_sha256_self_check() ||
      !read_fixture(fixture_path, &content, &content_size, content_digest) ||
      !read_save_file(save_path, &saved, &saved_size) ||
      saved_size != expected_save_size ||
      !validate_save_header(saved, content_digest) ||
      !lf_muhtari_save_oracle_matches(saved + SAVE_HEADER_BYTES,
                                      UINT8_C(1)) ||
      !acknowledge_committed_file(save_path, saved, saved_size,
                                  &previous_acknowledgment) ||
      !acknowledgment_matches_media(
          &previous_acknowledgment, saved + SAVE_HEADER_BYTES,
          get_u64_le(saved + 24U)) ||
      !create_loaded_instance(content, content_size, &instance) ||
      !copy_media(instance, media, &info) ||
      !lf_muhtari_save_oracle_is_fresh(media) ||
      !import_save_envelope(instance, saved, saved_size, content_digest,
                            &import_calls) ||
      import_calls != 1U || !copy_media(instance, media, &info) ||
      !lf_muhtari_save_oracle_matches(media, UINT8_C(1)) ||
      !advance_to_progress(instance, media, UINT8_C(2), &info) ||
      !lf_muhtari_save_oracle_matches(media, UINT8_C(2))) {
    (void)fail("failed update restores the previous commit and reaches 2/2");
    goto cleanup;
  }

  host_acknowledgment = previous_acknowledgment;
  make_save_header(header, content_digest, info.guest_generation);
  commit_status = commit_save(save_path, header, media, 1,
                              &host_acknowledgment, &temporary_removed);
  if (commit_status != SAVE_COMMIT_INJECTED_PREFIX_FAILURE ||
      temporary_removed == 0 ||
      !acknowledgments_match(&host_acknowledgment,
                             &previous_acknowledgment) ||
      !read_save_file(save_path, &current, &current_size) ||
      current_size != saved_size ||
      memcmp(current, saved, saved_size) != 0) {
    (void)fail("partial pre-rename failure preserves the old save and acknowledgment");
    goto cleanup;
  }

  (void)printf(
      "muhtari_save_failure_writer: prefix-write=failed-before-rename "
      "committed-file=previous-exact host-ack=previous-exact "
      "previous=1/1 attempted=2/2 generation-ack=preserved "
      "stage-cleanup=pass result=pass\n");
  result = 0;

cleanup:
  (void)lf_destroy(&instance);
  free(content);
  free(saved);
  free(current);
  free(media);
  return result;
}

static int run_fresh_recovery(const char *fixture_path,
                              const char *save_path) {
  if (run_restorer(fixture_path, save_path) != 0) {
    return 1;
  }
  (void)printf(
      "muhtari_save_recovery: prior-commit=1/1 recovered=1/1 "
      "continuation=2/2 process=fresh result=pass\n");
  return 0;
}

int main(int argc, char **argv) {
  if (argc == 3 && strcmp(argv[1], "--oracle-positive") == 0) {
    return run_save_oracle_probe(argv[2], 0);
  }
  if (argc == 3 && strcmp(argv[1], "--wrong-save-oracle") == 0) {
    return run_save_oracle_probe(argv[2], 1);
  }
  if (argc == 4 && strcmp(argv[1], "--writer") == 0) {
    return run_writer(argv[2], argv[3]);
  }
  if (argc == 4 && strcmp(argv[1], "--restorer") == 0) {
    return run_restorer(argv[2], argv[3]);
  }
  if (argc == 4 && strcmp(argv[1], "--failed-update") == 0) {
    return run_failed_update(argv[2], argv[3]);
  }
  if (argc == 4 && strcmp(argv[1], "--recovery") == 0) {
    return run_fresh_recovery(argv[2], argv[3]);
  }
  (void)fprintf(stderr,
                "usage: %s (--writer|--restorer|--failed-update|--recovery) "
                "<fixture.a78> <save-file>\n"
                "       %s (--oracle-positive|--wrong-save-oracle) "
                "<fixture.a78>\n",
                argv[0], argv[0]);
  return 2;
}
