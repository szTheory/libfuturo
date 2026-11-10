#ifndef LIBFUTURO_TESTS_MUHTARI_SNAPSHOT_FAULTS_H
#define LIBFUTURO_TESTS_MUHTARI_SNAPSHOT_FAULTS_H

#include "muhtari_snapshot_host.h"

#include <libfuturo/libfuturo.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/*
 * Test-only native state mutation. Field offset 115 is the pinned Muhtari
 * v0.11.1 state test's non-boolean CPU jammed flag. Its upstream recipe sets
 * byte 115 to 2, zeros the native checksum at 24, and recomputes CRC across
 * [0,24), four zero bytes, and [28,end). See Muhtari source
 * d58f125297c4d63a7a8108112a5eafff6f53a76a, tests/core/test_state.c around
 * the public-state refusal case. The project owns this small test helper and
 * must recheck it against that exact pin if the selected source changes.
 * The referenced Muhtari source is MIT-licensed. This CRC loop is an
 * independently maintained test implementation in this Apache-2.0 project;
 * no upstream implementation code is copied here.
 * Native layout knowledge is intentionally confined to this test header.
 */
typedef enum lf_muhtari_snapshot_fault {
  LF_MUHTARI_FAULT_ZERO_EXTENT,
  LF_MUHTARI_FAULT_NULL_ZERO_EXTENT,
  LF_MUHTARI_FAULT_TRUNCATED_HEADER,
  LF_MUHTARI_FAULT_TRUNCATED_NATIVE,
  LF_MUHTARI_FAULT_TRAILING_BYTE,
  LF_MUHTARI_FAULT_BAD_MAGIC,
  LF_MUHTARI_FAULT_BAD_VERSION,
  LF_MUHTARI_FAULT_BAD_HEADER_SIZE,
  LF_MUHTARI_FAULT_BAD_HEADER_INTEGRITY,
  LF_MUHTARI_FAULT_ZERO_TOTAL,
  LF_MUHTARI_FAULT_OVERFLOW_TOTAL,
  LF_MUHTARI_FAULT_INCONSISTENT_TOTAL,
  LF_MUHTARI_FAULT_ZERO_NATIVE,
  LF_MUHTARI_FAULT_OVERFLOW_NATIVE,
  LF_MUHTARI_FAULT_INCONSISTENT_NATIVE,
  LF_MUHTARI_FAULT_BAD_CONTENT_EXTENT,
  LF_MUHTARI_FAULT_WRONG_LIBFUTURO_BUILD,
  LF_MUHTARI_FAULT_WRONG_CORE_BUILD,
  LF_MUHTARI_FAULT_WRONG_NATIVE_FORMAT,
  LF_MUHTARI_FAULT_WRONG_CORE_ABI,
  LF_MUHTARI_FAULT_WRONG_BEHAVIOR,
  LF_MUHTARI_FAULT_WRONG_API,
  LF_MUHTARI_FAULT_WRONG_PROFILE,
  LF_MUHTARI_FAULT_WRONG_CONFIGURATION,
  LF_MUHTARI_FAULT_WRONG_OPTIONS,
  LF_MUHTARI_FAULT_WRONG_CONTENT_DIGEST,
  LF_MUHTARI_FAULT_NATIVE_CORRUPTION,
  LF_MUHTARI_FAULT_NATIVE_SEMANTIC_INVALID
} lf_muhtari_snapshot_fault;

typedef struct lf_muhtari_snapshot_fault_case {
  const char *name;
  lf_muhtari_snapshot_fault fault;
  lf_status expected_status;
} lf_muhtari_snapshot_fault_case;

static const lf_muhtari_snapshot_fault_case
    lf_muhtari_snapshot_fault_cases[] = {
        {"zero_extent", LF_MUHTARI_FAULT_ZERO_EXTENT, LF_INVALID_ARGUMENT},
        {"null_zero_extent", LF_MUHTARI_FAULT_NULL_ZERO_EXTENT,
         LF_INVALID_ARGUMENT},
        {"truncated_header", LF_MUHTARI_FAULT_TRUNCATED_HEADER,
         LF_INVALID_ARGUMENT},
        {"truncated_native_payload", LF_MUHTARI_FAULT_TRUNCATED_NATIVE,
         LF_INVALID_ARGUMENT},
        {"trailing_byte", LF_MUHTARI_FAULT_TRAILING_BYTE, LF_INVALID_ARGUMENT},
        {"malformed_magic", LF_MUHTARI_FAULT_BAD_MAGIC, LF_INVALID_ARGUMENT},
        {"malformed_version", LF_MUHTARI_FAULT_BAD_VERSION,
         LF_INVALID_ARGUMENT},
        {"malformed_header", LF_MUHTARI_FAULT_BAD_HEADER_SIZE,
         LF_INVALID_ARGUMENT},
        {"header_integrity", LF_MUHTARI_FAULT_BAD_HEADER_INTEGRITY,
         LF_INVALID_ARGUMENT},
        {"zero_total_extent", LF_MUHTARI_FAULT_ZERO_TOTAL,
         LF_INVALID_ARGUMENT},
        {"overflow_total_extent", LF_MUHTARI_FAULT_OVERFLOW_TOTAL,
         LF_LIMIT_EXCEEDED},
        {"inconsistent_total_extent", LF_MUHTARI_FAULT_INCONSISTENT_TOTAL,
         LF_INVALID_ARGUMENT},
        {"zero_native_extent", LF_MUHTARI_FAULT_ZERO_NATIVE,
         LF_INVALID_ARGUMENT},
        {"overflow_native_extent", LF_MUHTARI_FAULT_OVERFLOW_NATIVE,
         LF_INVALID_ARGUMENT},
        {"inconsistent_native_extent", LF_MUHTARI_FAULT_INCONSISTENT_NATIVE,
         LF_INVALID_ARGUMENT},
        {"malformed_content_extent", LF_MUHTARI_FAULT_BAD_CONTENT_EXTENT,
         LF_INVALID_ARGUMENT},
        {"wrong_libfuturo_build", LF_MUHTARI_FAULT_WRONG_LIBFUTURO_BUILD,
         LF_INVALID_ARGUMENT},
        {"wrong_core_build", LF_MUHTARI_FAULT_WRONG_CORE_BUILD,
         LF_INVALID_ARGUMENT},
        {"wrong_native_format", LF_MUHTARI_FAULT_WRONG_NATIVE_FORMAT,
         LF_INVALID_ARGUMENT},
        {"wrong_core_abi", LF_MUHTARI_FAULT_WRONG_CORE_ABI,
         LF_INVALID_ARGUMENT},
        {"wrong_behavior_revision", LF_MUHTARI_FAULT_WRONG_BEHAVIOR,
         LF_INVALID_ARGUMENT},
        {"wrong_api_revision", LF_MUHTARI_FAULT_WRONG_API,
         LF_INVALID_ARGUMENT},
        {"wrong_profile", LF_MUHTARI_FAULT_WRONG_PROFILE,
         LF_INVALID_ARGUMENT},
        {"wrong_configuration", LF_MUHTARI_FAULT_WRONG_CONFIGURATION,
         LF_INVALID_ARGUMENT},
        {"wrong_options", LF_MUHTARI_FAULT_WRONG_OPTIONS,
         LF_INVALID_ARGUMENT},
        {"wrong_content_digest", LF_MUHTARI_FAULT_WRONG_CONTENT_DIGEST,
         LF_INVALID_ARGUMENT},
        {"native_corruption", LF_MUHTARI_FAULT_NATIVE_CORRUPTION,
         LF_INVALID_ARGUMENT},
        {"native_semantic_invalid", LF_MUHTARI_FAULT_NATIVE_SEMANTIC_INVALID,
         LF_INVALID_ARGUMENT},
    };

static uint32_t lf_muhtari_snapshot_fault_crc32(uint32_t prior,
                                                 const uint8_t *bytes,
                                                 size_t extent) {
  uint32_t crc = ~prior;
  for (size_t index = 0U; index < extent; ++index) {
    crc ^= bytes[index];
    for (unsigned bit = 0U; bit < 8U; ++bit) {
      const uint32_t mask = (uint32_t)(0U - (crc & 1U));
      crc = (crc >> 1U) ^ (UINT32_C(0xEDB88320) & mask);
    }
  }
  return ~crc;
}

static int lf_muhtari_snapshot_fault_crc_known_vector(void) {
  static const uint8_t known[] = "123456789";
  return lf_muhtari_snapshot_fault_crc32(0U, known, sizeof(known) - 1U) ==
         UINT32_C(0xCBF43926);
}

static void lf_muhtari_snapshot_fault_put_u32(uint8_t *destination,
                                               uint32_t value) {
  for (size_t index = 0U; index < 4U; ++index) {
    destination[index] = (uint8_t)(value >> (unsigned int)(index * 8U));
  }
}

static void lf_muhtari_snapshot_fault_put_u64(uint8_t *destination,
                                               uint64_t value) {
  for (size_t index = 0U; index < 8U; ++index) {
    destination[index] = (uint8_t)(value >> (unsigned int)(index * 8U));
  }
}

static void lf_muhtari_snapshot_fault_rechecksum(uint8_t *native,
                                                  size_t extent) {
  static const uint8_t zero_crc[4] = {0U, 0U, 0U, 0U};
  uint32_t crc = 0U;
  if (native == NULL || extent < 28U) {
    return;
  }
  memset(native + 24U, 0, sizeof(zero_crc));
  crc = lf_muhtari_snapshot_fault_crc32(crc, native, 24U);
  crc = lf_muhtari_snapshot_fault_crc32(crc, zero_crc, sizeof(zero_crc));
  crc = lf_muhtari_snapshot_fault_crc32(crc, native + 28U, extent - 28U);
  lf_muhtari_snapshot_fault_put_u32(native + 24U, crc);
}

static void lf_muhtari_snapshot_fault_rechecksum_header(uint8_t *candidate) {
  uint8_t digest[32];
  memset(candidate + 380U, 0, sizeof(digest));
  lf_muhtari_host_digest(candidate, LF_MUHTARI_HOST_SNAPSHOT_HEADER_BYTES,
                         digest);
  memcpy(candidate + 380U, digest, sizeof(digest));
}

static int lf_muhtari_snapshot_fault_make(
    const uint8_t *valid, size_t valid_extent,
    lf_muhtari_snapshot_fault fault, uint8_t **candidate_out,
    size_t *candidate_extent_out) {
  uint8_t *candidate = NULL;
  size_t candidate_extent = valid_extent;
  if (valid == NULL || candidate_out == NULL || candidate_extent_out == NULL ||
      valid_extent <= LF_MUHTARI_HOST_SNAPSHOT_HEADER_BYTES ||
      valid_extent > LF_MUHTARI_HOST_SNAPSHOT_MAX_BYTES) {
    return 0;
  }
  *candidate_out = NULL;
  *candidate_extent_out = valid_extent;
  if (fault == LF_MUHTARI_FAULT_ZERO_EXTENT ||
      fault == LF_MUHTARI_FAULT_NULL_ZERO_EXTENT ||
      fault == LF_MUHTARI_FAULT_OVERFLOW_TOTAL) {
    return 1;
  }
  if (fault == LF_MUHTARI_FAULT_TRUNCATED_HEADER) {
    *candidate_out = (uint8_t *)malloc(valid_extent);
    if (*candidate_out == NULL) {
      return 0;
    }
    memcpy(*candidate_out, valid, valid_extent);
    *candidate_extent_out = LF_MUHTARI_HOST_SNAPSHOT_HEADER_BYTES - 1U;
    return 1;
  }
  if (fault == LF_MUHTARI_FAULT_TRUNCATED_NATIVE) {
    *candidate_out = (uint8_t *)malloc(valid_extent);
    if (*candidate_out == NULL) {
      return 0;
    }
    memcpy(*candidate_out, valid, valid_extent);
    *candidate_extent_out = valid_extent - 1U;
    return 1;
  }
  if (fault == LF_MUHTARI_FAULT_TRAILING_BYTE) {
    if (valid_extent == SIZE_MAX) {
      return 0;
    }
    candidate_extent = valid_extent + 1U;
    candidate = (uint8_t *)malloc(candidate_extent);
    if (candidate == NULL) {
      return 0;
    }
    memcpy(candidate, valid, valid_extent);
    candidate[valid_extent] = UINT8_C(0xA5);
    *candidate_out = candidate;
    *candidate_extent_out = candidate_extent;
    return 1;
  }
  candidate = (uint8_t *)malloc(valid_extent);
  if (candidate == NULL) {
    return 0;
  }
  memcpy(candidate, valid, valid_extent);
  switch (fault) {
  case LF_MUHTARI_FAULT_BAD_MAGIC:
    candidate[0] ^= UINT8_C(0x01);
    break;
  case LF_MUHTARI_FAULT_BAD_VERSION:
    lf_muhtari_snapshot_fault_put_u32(candidate + 8U, 1U);
    break;
  case LF_MUHTARI_FAULT_BAD_HEADER_SIZE:
    lf_muhtari_snapshot_fault_put_u32(candidate + 12U, 0U);
    break;
  case LF_MUHTARI_FAULT_BAD_HEADER_INTEGRITY:
    candidate[380U] ^= UINT8_C(0x01);
    break;
  case LF_MUHTARI_FAULT_ZERO_TOTAL:
    lf_muhtari_snapshot_fault_put_u64(candidate + 16U, 0U);
    break;
  case LF_MUHTARI_FAULT_INCONSISTENT_TOTAL:
    lf_muhtari_snapshot_fault_put_u64(candidate + 16U,
                                      (uint64_t)valid_extent + 1U);
    break;
  case LF_MUHTARI_FAULT_ZERO_NATIVE:
    lf_muhtari_snapshot_fault_put_u64(candidate + 24U, 0U);
    break;
  case LF_MUHTARI_FAULT_OVERFLOW_NATIVE:
    lf_muhtari_snapshot_fault_put_u64(candidate + 24U, UINT64_MAX);
    break;
  case LF_MUHTARI_FAULT_INCONSISTENT_NATIVE:
    lf_muhtari_snapshot_fault_put_u64(candidate + 24U,
                                      (uint64_t)(valid_extent -
                                                LF_MUHTARI_HOST_SNAPSHOT_HEADER_BYTES -
                                                1U));
    break;
  case LF_MUHTARI_FAULT_BAD_CONTENT_EXTENT:
    lf_muhtari_snapshot_fault_put_u64(
        candidate + 356U,
        lf_muhtari_host_get_u64(candidate + 356U) + 1U);
    break;
  case LF_MUHTARI_FAULT_WRONG_LIBFUTURO_BUILD:
    candidate[108U] ^= UINT8_C(0x01);
    break;
  case LF_MUHTARI_FAULT_WRONG_CORE_BUILD:
    candidate[44U] ^= UINT8_C(0x01);
    break;
  case LF_MUHTARI_FAULT_WRONG_NATIVE_FORMAT:
    lf_muhtari_snapshot_fault_put_u32(candidate + 32U, 2U);
    break;
  case LF_MUHTARI_FAULT_WRONG_CORE_ABI:
    lf_muhtari_snapshot_fault_put_u32(candidate + 36U, 2U);
    break;
  case LF_MUHTARI_FAULT_WRONG_BEHAVIOR:
    lf_muhtari_snapshot_fault_put_u32(candidate + 40U, 7U);
    break;
  case LF_MUHTARI_FAULT_WRONG_API:
    lf_muhtari_snapshot_fault_put_u32(candidate + 412U, 7U);
    break;
  case LF_MUHTARI_FAULT_WRONG_PROFILE:
    candidate[188U] ^= UINT8_C(0x01);
    break;
  case LF_MUHTARI_FAULT_WRONG_CONFIGURATION:
    candidate[220U] ^= UINT8_C(0x01);
    break;
  case LF_MUHTARI_FAULT_WRONG_OPTIONS:
    candidate[252U] ^= UINT8_C(0x01);
    break;
  case LF_MUHTARI_FAULT_WRONG_CONTENT_DIGEST:
    candidate[284U] ^= UINT8_C(0x01);
    break;
  case LF_MUHTARI_FAULT_NATIVE_CORRUPTION:
    candidate[valid_extent - 1U] ^= UINT8_C(0x01);
    break;
  case LF_MUHTARI_FAULT_NATIVE_SEMANTIC_INVALID: {
    uint8_t *native = candidate + LF_MUHTARI_HOST_SNAPSHOT_HEADER_BYTES;
    const size_t native_extent =
        valid_extent - LF_MUHTARI_HOST_SNAPSHOT_HEADER_BYTES;
    native[115U] = 2U;
    lf_muhtari_snapshot_fault_rechecksum(native, native_extent);
    break;
  }
  case LF_MUHTARI_FAULT_ZERO_EXTENT:
  case LF_MUHTARI_FAULT_NULL_ZERO_EXTENT:
  case LF_MUHTARI_FAULT_TRUNCATED_HEADER:
  case LF_MUHTARI_FAULT_TRUNCATED_NATIVE:
  case LF_MUHTARI_FAULT_TRAILING_BYTE:
  case LF_MUHTARI_FAULT_OVERFLOW_TOTAL:
    free(candidate);
    return 0;
  }
  if (fault != LF_MUHTARI_FAULT_BAD_HEADER_INTEGRITY) {
    lf_muhtari_snapshot_fault_rechecksum_header(candidate);
  }
  *candidate_out = candidate;
  return 1;
}

static int lf_muhtari_snapshot_fault_semantic_candidate_valid(
    const uint8_t *candidate, size_t extent) {
  const uint8_t *native = NULL;
  size_t native_extent = 0U;
  static const uint8_t zero_crc[4] = {0U, 0U, 0U, 0U};
  uint32_t crc = 0U;
  uint32_t encoded_crc = 0U;
  if (candidate == NULL || extent <= LF_MUHTARI_HOST_SNAPSHOT_HEADER_BYTES ||
      !lf_muhtari_host_snapshot_integrity_matches(candidate, extent) ||
      memcmp(candidate, "LFMU8S1", 7U) != 0 || candidate[7U] != 0U ||
      lf_muhtari_host_get_u32(candidate + 8U) != 2U ||
      lf_muhtari_host_get_u32(candidate + 12U) !=
          LF_MUHTARI_HOST_SNAPSHOT_HEADER_BYTES ||
      lf_muhtari_host_get_u64(candidate + 16U) != (uint64_t)extent ||
      lf_muhtari_host_get_u64(candidate + 24U) !=
          (uint64_t)(extent - LF_MUHTARI_HOST_SNAPSHOT_HEADER_BYTES) ||
      lf_muhtari_host_get_u32(candidate + 412U) != 8U) {
    return 0;
  }
  native = candidate + LF_MUHTARI_HOST_SNAPSHOT_HEADER_BYTES;
  native_extent = extent - LF_MUHTARI_HOST_SNAPSHOT_HEADER_BYTES;
  if (native_extent < 28U || native[115U] != 2U) {
    return 0;
  }
  encoded_crc = lf_muhtari_host_get_u32(native + 24U);
  crc = lf_muhtari_snapshot_fault_crc32(crc, native, 24U);
  crc = lf_muhtari_snapshot_fault_crc32(crc, zero_crc, sizeof(zero_crc));
  crc = lf_muhtari_snapshot_fault_crc32(crc, native + 28U,
                                        native_extent - 28U);
  return crc == encoded_crc;
}

#endif
