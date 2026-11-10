#ifndef LIBFUTURO_TESTS_NESTURBATOR_LOAD_CASES_H
#define LIBFUTURO_TESTS_NESTURBATOR_LOAD_CASES_H

#include <stddef.h>
#include <stdint.h>

#include <libfuturo/libfuturo.h>

#include "nesturbator_save_fixture.h"

typedef enum lf_load_request_variant {
  LF_LOAD_REQUEST_VALID = 0,
  LF_LOAD_REQUEST_NULL,
  LF_LOAD_REQUEST_BAD_SIZE
} lf_load_request_variant;

typedef enum lf_load_result_variant {
  LF_LOAD_RESULT_VALID = 0,
  LF_LOAD_RESULT_NULL,
  LF_LOAD_RESULT_BAD_SIZE
} lf_load_result_variant;

typedef enum lf_load_size_variant {
  LF_LOAD_SIZE_EXACT = 0,
  LF_LOAD_SIZE_ZERO,
  LF_LOAD_SIZE_SHORT,
  LF_LOAD_SIZE_LONG
} lf_load_size_variant;

typedef struct lf_load_case {
  const char *id;
  lf_status expected_status;
  uint8_t header[16];
  size_t actual_extent;
  const char *configuration_id;
  lf_load_request_variant request_variant;
  lf_load_size_variant request_size_variant;
  lf_load_result_variant result_variant;
  lf_load_size_variant result_size_variant;
  uint32_t content_pointer_null;
  uint32_t instance_null;
  uint32_t executable;
} lf_load_case;

typedef enum lf_matrix_format {
  LF_MATRIX_FORMAT_INES = 0,
  LF_MATRIX_FORMAT_NES2
} lf_matrix_format;

typedef enum lf_matrix_size_mode {
  LF_MATRIX_SIZE_LINEAR = 0,
  LF_MATRIX_SIZE_EXPONENT
} lf_matrix_size_mode;

typedef enum lf_matrix_extent_mode {
  LF_MATRIX_EXTENT_EXACT = 0,
  LF_MATRIX_EXTENT_EXPLICIT,
  LF_MATRIX_EXTENT_DELTA
} lf_matrix_extent_mode;

typedef struct lf_load_matrix_case {
  const char *id;
  lf_status expected_status;
  lf_matrix_format format;
  uint16_t mapper;
  uint8_t submapper;
  lf_matrix_size_mode prg_mode;
  uint16_t prg_value;
  lf_matrix_size_mode chr_mode;
  uint16_t chr_value;
  uint8_t prg_ram_shift;
  uint8_t prg_nvram_shift;
  uint8_t chr_ram_shift;
  uint8_t chr_nvram_shift;
  uint8_t battery;
  uint8_t trainer;
  const char *configuration_id;
  uint8_t magic_corrupt_index;
  uint8_t magic_corrupt_mask;
  lf_matrix_extent_mode extent_mode;
  size_t extent_bytes;
  int32_t extent_delta;
} lf_load_matrix_case;

#define LF_LOAD_LAYOUT_CASE_COUNT 62U
#define LF_MX_ENTRY(id_value, status_value, format_value, mapper_value,       \
                    submapper_value, prg_mode_value, prg_value_value,        \
                    chr_mode_value, chr_value_value, work_value, nv_value,   \
                    chr_ram_value, chr_nv_value, battery_value,              \
                    trainer_value, configuration_value, corrupt_index_value, \
                    corrupt_mask_value, extent_mode_value, extent_value,     \
                    extent_delta_value)                                      \
  {                                                                           \
    .id = id_value, .expected_status = status_value,                         \
    .format = format_value, .mapper = mapper_value,                         \
    .submapper = submapper_value, .prg_mode = prg_mode_value,                \
    .prg_value = prg_value_value, .chr_mode = chr_mode_value,                \
    .chr_value = chr_value_value, .prg_ram_shift = work_value,               \
    .prg_nvram_shift = nv_value, .chr_ram_shift = chr_ram_value,             \
    .chr_nvram_shift = chr_nv_value, .battery = battery_value,               \
    .trainer = trainer_value, .configuration_id = configuration_value,       \
    .magic_corrupt_index = corrupt_index_value,                              \
    .magic_corrupt_mask = corrupt_mask_value,                                \
    .extent_mode = extent_mode_value, .extent_bytes = extent_value,           \
    .extent_delta = extent_delta_value                                        \
  }
#define LF_MX_N(id_value, status_value, mapper_value, submapper_value,       \
                prg_value_value, chr_value_value)                            \
  LF_MX_ENTRY(id_value, status_value, LF_MATRIX_FORMAT_NES2, mapper_value,   \
              submapper_value, LF_MATRIX_SIZE_LINEAR, prg_value_value,       \
              LF_MATRIX_SIZE_LINEAR, chr_value_value, 0U, 0U, 0U, 0U, 0U,   \
              0U, NULL, UINT8_MAX, 0U, LF_MATRIX_EXTENT_EXACT, 0U, 0)
#define LF_MX_N_RAM(id_value, status_value, mapper_value, submapper_value,   \
                    prg_value_value, chr_value_value, work_value, nv_value,  \
                    chr_ram_value, chr_nv_value, battery_value, trainer_value) \
  LF_MX_ENTRY(id_value, status_value, LF_MATRIX_FORMAT_NES2, mapper_value,   \
              submapper_value, LF_MATRIX_SIZE_LINEAR, prg_value_value,       \
              LF_MATRIX_SIZE_LINEAR, chr_value_value, work_value, nv_value,  \
              chr_ram_value, chr_nv_value, battery_value, trainer_value,     \
              NULL, UINT8_MAX, 0U, LF_MATRIX_EXTENT_EXACT, 0U, 0)
#define LF_MX_N_EXP_P(id_value, status_value, mapper_value, submapper_value, \
                      prg_byte_value, chr_value_value)                      \
  LF_MX_ENTRY(id_value, status_value, LF_MATRIX_FORMAT_NES2, mapper_value,   \
              submapper_value, LF_MATRIX_SIZE_EXPONENT, prg_byte_value,      \
              LF_MATRIX_SIZE_LINEAR, chr_value_value, 0U, 0U, 0U, 0U, 0U,  \
              0U, NULL, UINT8_MAX, 0U, LF_MATRIX_EXTENT_EXACT, 0U, 0)
#define LF_MX_N_EXP_P_RAM(id_value, status_value, mapper_value,              \
                          submapper_value, prg_byte_value)                  \
  LF_MX_ENTRY(id_value, status_value, LF_MATRIX_FORMAT_NES2, mapper_value,   \
              submapper_value, LF_MATRIX_SIZE_EXPONENT, prg_byte_value,      \
              LF_MATRIX_SIZE_LINEAR, 0U, 0U, 0U, 7U, 0U, 0U, 0U, NULL,     \
              UINT8_MAX, 0U, LF_MATRIX_EXTENT_EXACT, 0U, 0)
#define LF_MX_N_EXP_P_RAM_SPAN(id_value, status_value, mapper_value,          \
                               submapper_value, prg_byte_value, span_value) \
  LF_MX_ENTRY(id_value, status_value, LF_MATRIX_FORMAT_NES2, mapper_value,   \
              submapper_value, LF_MATRIX_SIZE_EXPONENT, prg_byte_value,      \
              LF_MATRIX_SIZE_LINEAR, 0U, 0U, 0U, 7U, 0U, 0U, 0U, NULL,     \
              UINT8_MAX, 0U, LF_MATRIX_EXTENT_EXPLICIT, span_value, 0)
#define LF_MX_N_EXP_P_SPAN(id_value, status_value, mapper_value,              \
                           submapper_value, prg_byte_value, chr_value_value, \
                           span_value)                                       \
  LF_MX_ENTRY(id_value, status_value, LF_MATRIX_FORMAT_NES2, mapper_value,   \
              submapper_value, LF_MATRIX_SIZE_EXPONENT, prg_byte_value,      \
              LF_MATRIX_SIZE_LINEAR, chr_value_value, 0U, 0U, 0U, 0U, 0U,  \
              0U, NULL, UINT8_MAX, 0U, LF_MATRIX_EXTENT_EXPLICIT,             \
              span_value, 0)
#define LF_MX_N_EXP_C(id_value, status_value, mapper_value, submapper_value, \
                      prg_value_value, chr_byte_value)                      \
  LF_MX_ENTRY(id_value, status_value, LF_MATRIX_FORMAT_NES2, mapper_value,   \
              submapper_value, LF_MATRIX_SIZE_LINEAR, prg_value_value,       \
              LF_MATRIX_SIZE_EXPONENT, chr_byte_value, 0U, 0U, 0U, 0U, 0U,  \
              0U, NULL, UINT8_MAX, 0U, LF_MATRIX_EXTENT_EXACT, 0U, 0)
#define LF_MX_N_EXP_C_SPAN(id_value, status_value, mapper_value,              \
                           submapper_value, prg_value_value, chr_byte_value, \
                           span_value)                                       \
  LF_MX_ENTRY(id_value, status_value, LF_MATRIX_FORMAT_NES2, mapper_value,   \
              submapper_value, LF_MATRIX_SIZE_LINEAR, prg_value_value,       \
              LF_MATRIX_SIZE_EXPONENT, chr_byte_value, 0U, 0U, 0U, 0U, 0U,  \
              0U, NULL, UINT8_MAX, 0U, LF_MATRIX_EXTENT_EXPLICIT,             \
              span_value, 0)
#define LF_MX_N_EXP_BOTH(id_value, status_value, mapper_value,                \
                         submapper_value, prg_byte_value, chr_byte_value)   \
  LF_MX_ENTRY(id_value, status_value, LF_MATRIX_FORMAT_NES2, mapper_value,   \
              submapper_value, LF_MATRIX_SIZE_EXPONENT, prg_byte_value,      \
              LF_MATRIX_SIZE_EXPONENT, chr_byte_value, 0U, 0U, 0U, 0U, 0U,  \
              0U, NULL, UINT8_MAX, 0U, LF_MATRIX_EXTENT_EXACT, 0U, 0)
#define LF_MX_N_EXP_BOTH_SPAN(id_value, status_value, mapper_value,           \
                              submapper_value, prg_byte_value,               \
                              chr_byte_value, span_value)                    \
  LF_MX_ENTRY(id_value, status_value, LF_MATRIX_FORMAT_NES2, mapper_value,   \
              submapper_value, LF_MATRIX_SIZE_EXPONENT, prg_byte_value,      \
              LF_MATRIX_SIZE_EXPONENT, chr_byte_value, 0U, 0U, 0U, 0U, 0U,  \
              0U, NULL, UINT8_MAX, 0U, LF_MATRIX_EXTENT_EXPLICIT,             \
              span_value, 0)
#define LF_MX_N_RAM_TRAINER(id_value, status_value, mapper_value,             \
                            submapper_value, prg_value_value, chr_value_value, \
                            work_value, nv_value, battery_value)             \
  LF_MX_N_RAM(id_value, status_value, mapper_value, submapper_value,         \
              prg_value_value, chr_value_value, work_value, nv_value, 0U,    \
              0U, battery_value, 1U)
#define LF_MX_N_SPAN(id_value, status_value, mapper_value, submapper_value,  \
                     prg_value_value, chr_value_value, span_value)          \
  LF_MX_ENTRY(id_value, status_value, LF_MATRIX_FORMAT_NES2, mapper_value,   \
              submapper_value, LF_MATRIX_SIZE_LINEAR, prg_value_value,       \
              LF_MATRIX_SIZE_LINEAR, chr_value_value, 0U, 0U, 0U, 0U, 0U,  \
              0U, NULL, UINT8_MAX, 0U, LF_MATRIX_EXTENT_EXPLICIT,             \
              span_value, 0)
#define LF_MX_N_DELTA(id_value, status_value, mapper_value, submapper_value, \
                      prg_value_value, chr_value_value, delta_value)        \
  LF_MX_ENTRY(id_value, status_value, LF_MATRIX_FORMAT_NES2, mapper_value,   \
              submapper_value, LF_MATRIX_SIZE_LINEAR, prg_value_value,       \
              LF_MATRIX_SIZE_LINEAR, chr_value_value, 0U, 0U, 0U, 0U, 0U,  \
              0U, NULL, UINT8_MAX, 0U, LF_MATRIX_EXTENT_DELTA, 0U, delta_value)
#define LF_MX_I(id_value, status_value, mapper_value, prg_value_value,       \
                chr_value_value, battery_value, trainer_value)               \
  LF_MX_ENTRY(id_value, status_value, LF_MATRIX_FORMAT_INES, mapper_value,   \
              0U, LF_MATRIX_SIZE_LINEAR, prg_value_value,                    \
              LF_MATRIX_SIZE_LINEAR, chr_value_value, 0U, 0U, 0U, 0U,       \
              battery_value, trainer_value, NULL, UINT8_MAX, 0U,             \
              LF_MATRIX_EXTENT_EXACT, 0U, 0)
#define LF_MX_I_SPAN(id_value, status_value, mapper_value, prg_value_value,  \
                     chr_value_value, battery_value, trainer_value,          \
                     span_value)                                             \
  LF_MX_ENTRY(id_value, status_value, LF_MATRIX_FORMAT_INES, mapper_value,   \
              0U, LF_MATRIX_SIZE_LINEAR, prg_value_value,                    \
              LF_MATRIX_SIZE_LINEAR, chr_value_value, 0U, 0U, 0U, 0U,       \
              battery_value, trainer_value, NULL, UINT8_MAX, 0U,             \
              LF_MATRIX_EXTENT_EXPLICIT, span_value, 0)
#define LF_MX_N_UNKNOWN_BAD_MAGIC(id_value)                                   \
  LF_MX_ENTRY(id_value, LF_UNSUPPORTED, LF_MATRIX_FORMAT_NES2, 3U, 0U,       \
              LF_MATRIX_SIZE_LINEAR, 1U, LF_MATRIX_SIZE_LINEAR, 1U,          \
              0U, 0U, 0U, 0U, 1U, 0U, "unknown", 0U, 1U,                    \
              LF_MATRIX_EXTENT_EXACT, 0U, 0)

#define LF_LOAD_ADMISSION_CASE_COUNT 66U
#define LF_LOAD_HEADER(...) {__VA_ARGS__}
#define LF_LOAD_CASE(id_value, status_value, header_value, extent_value,       \
                     config_value, request_fields, result_fields,             \
                     content_null_value, instance_null_value, ignored_value)  \
  {                                                                            \
    .id = id_value, .expected_status = status_value, .header = header_value,  \
    .actual_extent = extent_value, .configuration_id = config_value,          \
    request_fields, result_fields,                                            \
    .content_pointer_null = content_null_value,                               \
    .instance_null = instance_null_value, .executable = 0U                     \
  }

#define LF_B_HEADER                                                          \
  LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U, 0x00U, 0x00U,     \
                 0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U)
#define LF_Q_HEADER                                                          \
  LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U, 0x00U, 0x08U,     \
                 0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U)
#define LF_B_BYTES ((size_t)16U + (size_t)16U * 1024U + (size_t)8U * 1024U)
#define LF_T_BYTES ((size_t)16U + (size_t)512U + (size_t)16U * 1024U +       \
                    (size_t)8U * 1024U)
#define LF_REQUEST_OK .request_variant = LF_LOAD_REQUEST_VALID,                \
                      .request_size_variant = LF_LOAD_SIZE_EXACT
#define LF_REQUEST_NULL .request_variant = LF_LOAD_REQUEST_NULL,               \
                        .request_size_variant = LF_LOAD_SIZE_EXACT
#define LF_REQUEST_BAD_ZERO .request_variant = LF_LOAD_REQUEST_BAD_SIZE,       \
                            .request_size_variant = LF_LOAD_SIZE_ZERO
#define LF_REQUEST_BAD_SHORT .request_variant = LF_LOAD_REQUEST_BAD_SIZE,      \
                             .request_size_variant = LF_LOAD_SIZE_SHORT
#define LF_REQUEST_BAD_LONG .request_variant = LF_LOAD_REQUEST_BAD_SIZE,       \
                            .request_size_variant = LF_LOAD_SIZE_LONG
#define LF_RESULT_OK .result_variant = LF_LOAD_RESULT_VALID,                   \
                     .result_size_variant = LF_LOAD_SIZE_EXACT
#define LF_RESULT_NULL .result_variant = LF_LOAD_RESULT_NULL,                  \
                       .result_size_variant = LF_LOAD_SIZE_EXACT
#define LF_RESULT_BAD_ZERO .result_variant = LF_LOAD_RESULT_BAD_SIZE,          \
                           .result_size_variant = LF_LOAD_SIZE_ZERO
#define LF_RESULT_BAD_SHORT .result_variant = LF_LOAD_RESULT_BAD_SIZE,         \
                            .result_size_variant = LF_LOAD_SIZE_SHORT
#define LF_RESULT_BAD_LONG .result_variant = LF_LOAD_RESULT_BAD_SIZE,          \
                           .result_size_variant = LF_LOAD_SIZE_LONG

static const lf_load_case lf_load_tracer_h01_01 = {
    .id = "H01-01",
    .expected_status = LF_INVALID_ARGUMENT,
    .header = {0x4fU, 0x45U, 0x53U, 0x1aU, 0x02U, 0x01U, 0x12U},
    .actual_extent = (size_t)LF_NESTURBATOR_SAVE_FIXTURE_TOTAL_BYTES,
    .configuration_id = "nesturbator-default",
    .request_variant = LF_LOAD_REQUEST_VALID,
    .request_size_variant = LF_LOAD_SIZE_EXACT,
    .result_variant = LF_LOAD_RESULT_VALID,
    .result_size_variant = LF_LOAD_SIZE_EXACT,
    .content_pointer_null = 0U,
    .instance_null = 0U,
    .executable = 1U,
};

static const lf_load_case lf_load_admission_cases[] = {
    LF_LOAD_CASE("A01-01", LF_INVALID_ARGUMENT, LF_B_HEADER, LF_B_BYTES, NULL,
                 LF_REQUEST_NULL, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("A01-02", LF_INVALID_ARGUMENT, LF_B_HEADER, LF_B_BYTES, NULL,
                 LF_REQUEST_BAD_ZERO, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("A01-03", LF_INVALID_ARGUMENT, LF_B_HEADER, LF_B_BYTES, NULL,
                 LF_REQUEST_BAD_SHORT, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("A01-04", LF_INVALID_ARGUMENT, LF_B_HEADER, LF_B_BYTES, NULL,
                 LF_REQUEST_BAD_LONG, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("A02-01", LF_INVALID_ARGUMENT, LF_B_HEADER, LF_B_BYTES, NULL,
                 LF_REQUEST_OK, LF_RESULT_NULL, 0U, 0U, 0U),
    LF_LOAD_CASE("A02-02", LF_INVALID_ARGUMENT, LF_B_HEADER, LF_B_BYTES, NULL,
                 LF_REQUEST_OK, LF_RESULT_BAD_ZERO, 0U, 0U, 0U),
    LF_LOAD_CASE("A02-03", LF_INVALID_ARGUMENT, LF_B_HEADER, LF_B_BYTES, NULL,
                 LF_REQUEST_OK, LF_RESULT_BAD_SHORT, 0U, 0U, 0U),
    LF_LOAD_CASE("A02-04", LF_INVALID_ARGUMENT, LF_B_HEADER, LF_B_BYTES, NULL,
                 LF_REQUEST_OK, LF_RESULT_BAD_LONG, 0U, 0U, 0U),
    LF_LOAD_CASE("A03-01", LF_INVALID_ARGUMENT, LF_B_HEADER, 1U, NULL,
                 LF_REQUEST_OK, LF_RESULT_OK, 1U, 0U, 0U),
    LF_LOAD_CASE("A03-02", LF_INVALID_ARGUMENT, LF_B_HEADER, 0U, NULL,
                 LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("A03-03", LF_INVALID_ARGUMENT, LF_B_HEADER, 0U, NULL,
                 LF_REQUEST_OK, LF_RESULT_OK, 1U, 0U, 0U),
    LF_LOAD_CASE("A04-01", LF_UNSUPPORTED, LF_B_HEADER, LF_B_BYTES, "",
                 LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("A04-02", LF_UNSUPPORTED, LF_B_HEADER, LF_B_BYTES, "unknown",
                 LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("A04-03", LF_OK, LF_B_HEADER, LF_B_BYTES, NULL, LF_REQUEST_OK,
                 LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("A04-04", LF_OK, LF_B_HEADER, LF_B_BYTES,
                 "nesturbator-default", LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U,
                 0U),
    LF_LOAD_CASE("A05-01", LF_INVALID_ARGUMENT, LF_B_HEADER,
                 (size_t)67108863U, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U,
                 0U),
    LF_LOAD_CASE("A05-02", LF_INVALID_ARGUMENT, LF_B_HEADER,
                 (size_t)67108864U, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U,
                 0U),
    LF_LOAD_CASE("A05-03", LF_LIMIT_EXCEEDED, LF_B_HEADER,
                 (size_t)67108865U, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U,
                 0U),
    LF_LOAD_CASE("A06-01", LF_UNSUPPORTED, LF_B_HEADER,
                 (size_t)67108865U, "unknown", LF_REQUEST_OK, LF_RESULT_OK,
                 0U, 0U, 0U),
    LF_LOAD_CASE("A06-02", LF_INVALID_ARGUMENT, LF_B_HEADER,
                 (size_t)67108865U, NULL, LF_REQUEST_OK, LF_RESULT_OK, 1U,
                 0U, 0U),
    LF_LOAD_CASE("A06-03", LF_INVALID_ARGUMENT, LF_B_HEADER, LF_B_BYTES,
                 "unknown", LF_REQUEST_BAD_ZERO, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("A06-04", LF_INVALID_ARGUMENT, LF_B_HEADER, LF_B_BYTES, NULL,
                 LF_REQUEST_BAD_ZERO, LF_RESULT_BAD_SHORT, 0U, 0U, 0U),
    LF_LOAD_CASE("A06-05", LF_INVALID_ARGUMENT, LF_B_HEADER, LF_B_BYTES, NULL,
                 LF_REQUEST_OK, LF_RESULT_OK, 0U, 1U, 0U),
    LF_LOAD_CASE("H01-01", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4fU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x00U, 0x00U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H01-02", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x44U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x00U, 0x00U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H01-03", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x52U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x00U, 0x00U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H01-04", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1bU, 0x01U, 0x01U,
                               0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x00U, 0x00U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H02-01", LF_INVALID_ARGUMENT, LF_B_HEADER, 1U, NULL,
                 LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H02-02", LF_INVALID_ARGUMENT, LF_B_HEADER, 15U, NULL,
                 LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H02-03", LF_INVALID_ARGUMENT, LF_B_HEADER, 16U, NULL,
                 LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H03-01", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x04U, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x00U, 0x00U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H03-02", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x0cU, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x00U, 0x00U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H03-03", LF_OK, LF_Q_HEADER, LF_B_BYTES, NULL, LF_REQUEST_OK,
                 LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H04-01", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x08U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x00U, 0x00U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H04-02", LF_OK,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x01U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x00U, 0x00U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H04-03", LF_OK,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x04U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x00U, 0x00U, 0x00U, 0x00U),
                 LF_T_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H05-01", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x01U, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x00U, 0x00U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H05-02", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x02U, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x00U, 0x00U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H05-03", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x03U, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x00U, 0x00U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H05-04", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x09U, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x00U, 0x00U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H05-05", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x0aU, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x00U, 0x00U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H05-06", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x0bU, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x00U, 0x00U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H06-01", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x10U, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x00U, 0x00U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H06-02", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x80U, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x00U, 0x00U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H06-03", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x18U, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x00U, 0x00U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H06-04", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x88U, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x00U, 0x00U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H07-01", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x00U, 0x01U, 0x00U, 0x00U, 0x00U,
                               0x00U, 0x00U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H07-02", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x00U, 0x00U, 0x01U, 0x00U, 0x00U,
                               0x00U, 0x00U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H07-03", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x00U, 0x00U, 0x00U, 0x01U, 0x00U,
                               0x00U, 0x00U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H07-04", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x01U,
                               0x00U, 0x00U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H07-05", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x01U, 0x00U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H07-06", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x00U, 0x01U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H07-07", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x00U, 0x00U, 0x01U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H07-08", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x00U, 0x00U, 0x00U, 0x01U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H08-01", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x08U, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x01U, 0x00U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H08-02", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x08U, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x02U, 0x00U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H08-03", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x08U, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x03U, 0x00U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H08-04", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x08U, 0x00U, 0x00U, 0x00U, 0x00U,
                               0xffU, 0x00U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H08-05", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x08U, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x00U, 0x01U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H08-06", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x08U, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x00U, 0xffU, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H08-07", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x08U, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x00U, 0x00U, 0x01U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H08-08", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x08U, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x00U, 0x00U, 0xffU, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H08-09", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x08U, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x00U, 0x00U, 0x00U, 0x01U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H08-10", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x08U, 0x00U, 0x00U, 0x00U, 0x00U,
                               0x00U, 0x00U, 0x00U, 0xffU),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H09-01", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x08U, 0x01U, 0x00U, 0x00U, 0x00U,
                               0x00U, 0x00U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
    LF_LOAD_CASE("H09-02", LF_INVALID_ARGUMENT,
                 LF_LOAD_HEADER(0x4eU, 0x45U, 0x53U, 0x1aU, 0x01U, 0x01U,
                               0x00U, 0x08U, 0x0fU, 0x00U, 0x00U, 0x00U,
                               0x00U, 0x00U, 0x00U, 0x00U),
                 LF_B_BYTES, NULL, LF_REQUEST_OK, LF_RESULT_OK, 0U, 0U, 0U),
};

_Static_assert(sizeof(lf_load_admission_cases) /
                       sizeof(lf_load_admission_cases[0]) ==
                   LF_LOAD_ADMISSION_CASE_COUNT,
               "A/H matrix must contain exactly 66 fixed cases");

static const lf_load_matrix_case lf_load_layout_cases[] = {
    LF_MX_N("S01-01", LF_INVALID_ARGUMENT, 0U, 0U, 0U, 1U),
    LF_MX_N("S01-02", LF_OK, 0U, 0U, 1U, 1U),
    LF_MX_N("S01-03", LF_OK, 0U, 0U, 2U, 1U),
    LF_MX_N("S01-04", LF_INVALID_ARGUMENT, 0U, 0U, 3U, 1U),
    LF_MX_N("S02-01", LF_INVALID_ARGUMENT, 0U, 0U, 1U, 0U),
    LF_MX_N("S02-02", LF_OK, 0U, 0U, 1U, 1U),
    LF_MX_N("S02-03", LF_INVALID_ARGUMENT, 0U, 0U, 1U, 2U),
    LF_MX_N_RAM("S03-01", LF_OK, 2U, 0U, 256U, 0U, 0U, 0U, 7U, 0U,
                0U, 0U),
    LF_MX_N_RAM("S03-02", LF_INVALID_ARGUMENT, 2U, 0U, 257U, 0U, 0U, 0U,
                7U, 0U, 0U, 0U),
    LF_MX_ENTRY("S03-03", LF_INVALID_ARGUMENT, LF_MATRIX_FORMAT_NES2, 2U,
                0U, LF_MATRIX_SIZE_LINEAR, 3839U, LF_MATRIX_SIZE_LINEAR, 0U,
                0U, 0U, 7U, 0U, 0U, 0U, NULL, UINT8_MAX, 0U,
                LF_MATRIX_EXTENT_EXPLICIT, 16U, 0),
    LF_MX_N_SPAN("S04-01", LF_INVALID_ARGUMENT, 4U, 0U, 2U, 256U, 16U),
    LF_MX_N_SPAN("S04-02", LF_INVALID_ARGUMENT, 4U, 0U, 2U, 3839U, 16U),
    LF_MX_N_EXP_P("S05-01", LF_OK, 0U, 0U, 56U, 1U),
    LF_MX_N_EXP_P("S05-02", LF_OK, 0U, 0U, 60U, 1U),
    LF_MX_N_EXP_P("S05-03", LF_INVALID_ARGUMENT, 0U, 0U, 57U, 1U),
    LF_MX_N_EXP_P("S05-04", LF_INVALID_ARGUMENT, 0U, 0U, 0U, 1U),
    LF_MX_N_EXP_P_SPAN("S05-05", LF_INVALID_ARGUMENT, 0U, 0U, 0xfcU, 1U,
                       16U),
    LF_MX_N_EXP_P_SPAN("S05-06", LF_INVALID_ARGUMENT, 0U, 0U, 0xffU, 1U,
                       16U),
    LF_MX_N_EXP_C("S06-01", LF_OK, 0U, 0U, 1U, 52U),
    LF_MX_N_EXP_C("S06-02", LF_INVALID_ARGUMENT, 0U, 0U, 1U, 53U),
    LF_MX_N_EXP_C("S06-03", LF_INVALID_ARGUMENT, 0U, 0U, 1U, 0U),
    LF_MX_N_EXP_C_SPAN("S06-04", LF_INVALID_ARGUMENT, 0U, 0U, 1U, 0xfcU,
                       16U),
    LF_MX_N_EXP_C_SPAN("S06-05", LF_INVALID_ARGUMENT, 0U, 0U, 1U, 0xffU,
                       16U),
    LF_MX_N_EXP_BOTH("S07-01", LF_OK, 0U, 0U, 56U, 52U),
    LF_MX_N_EXP_P_RAM("S08-01", LF_INVALID_ARGUMENT, 2U, 0U, 52U),
    LF_MX_N_EXP_P_RAM("S08-02", LF_OK, 2U, 0U, 76U),
    LF_MX_N_EXP_P_RAM("S08-03", LF_OK, 2U, 0U, 88U),
    LF_MX_N_EXP_P_RAM_SPAN("S08-04", LF_INVALID_ARGUMENT, 2U, 0U, 89U,
                           16U),
    LF_MX_N_EXP_C("S09-01", LF_OK, 0U, 0U, 1U, 52U),
    LF_MX_N_EXP_P("S09-02", LF_OK, 0U, 0U, 56U, 1U),

    LF_MX_I_SPAN("E01-01", LF_INVALID_ARGUMENT, 0U, 1U, 1U, 0U, 0U, 0U),
    LF_MX_I_SPAN("E01-02", LF_INVALID_ARGUMENT, 0U, 1U, 1U, 0U, 0U, 1U),
    LF_MX_I_SPAN("E01-03", LF_INVALID_ARGUMENT, 0U, 1U, 1U, 0U, 0U, 15U),
    LF_MX_I_SPAN("E01-04", LF_INVALID_ARGUMENT, 0U, 1U, 1U, 0U, 0U, 16U),
    LF_MX_I_SPAN("E01-05", LF_INVALID_ARGUMENT, 0U, 1U, 1U, 0U, 0U,
                 16399U),
    LF_MX_I_SPAN("E01-06", LF_INVALID_ARGUMENT, 0U, 1U, 1U, 0U, 0U,
                 16400U),
    LF_MX_I_SPAN("E01-07", LF_INVALID_ARGUMENT, 0U, 1U, 1U, 0U, 0U,
                 24591U),
    LF_MX_I_SPAN("E01-08", LF_OK, 0U, 1U, 1U, 0U, 0U, 24592U),
    LF_MX_I_SPAN("E01-09", LF_INVALID_ARGUMENT, 0U, 1U, 1U, 0U, 0U,
                 24593U),
    LF_MX_I_SPAN("E02-01", LF_INVALID_ARGUMENT, 0U, 1U, 1U, 0U, 1U, 16U),
    LF_MX_I_SPAN("E02-02", LF_INVALID_ARGUMENT, 0U, 1U, 1U, 0U, 1U, 527U),
    LF_MX_I_SPAN("E02-03", LF_INVALID_ARGUMENT, 0U, 1U, 1U, 0U, 1U, 528U),
    LF_MX_I_SPAN("E02-04", LF_INVALID_ARGUMENT, 0U, 1U, 1U, 0U, 1U,
                 16911U),
    LF_MX_I_SPAN("E02-05", LF_INVALID_ARGUMENT, 0U, 1U, 1U, 0U, 1U,
                 16912U),
    LF_MX_I_SPAN("E02-06", LF_INVALID_ARGUMENT, 0U, 1U, 1U, 0U, 1U,
                 25103U),
    LF_MX_I_SPAN("E02-07", LF_OK, 0U, 1U, 1U, 0U, 1U, 25104U),
    LF_MX_I_SPAN("E02-08", LF_INVALID_ARGUMENT, 0U, 1U, 1U, 0U, 1U,
                 25105U),
    LF_MX_I_SPAN("E03-01", LF_INVALID_ARGUMENT, 0U, 1U, 1U, 0U, 1U,
                 24592U),
    LF_MX_I_SPAN("E03-02", LF_INVALID_ARGUMENT, 0U, 1U, 1U, 0U, 0U,
                 25104U),
    LF_MX_ENTRY("E04-01", LF_INVALID_ARGUMENT, LF_MATRIX_FORMAT_NES2, 1U,
                0U, LF_MATRIX_SIZE_LINEAR, 2U, LF_MATRIX_SIZE_LINEAR, 0U,
                0U, 0U, 7U, 0U, 0U, 1U, NULL, UINT8_MAX, 0U,
                LF_MATRIX_EXTENT_DELTA, 0U, -1),
    LF_MX_ENTRY("E04-02", LF_OK, LF_MATRIX_FORMAT_NES2, 1U, 0U,
                LF_MATRIX_SIZE_LINEAR, 2U, LF_MATRIX_SIZE_LINEAR, 0U, 0U,
                0U, 7U, 0U, 0U, 1U, NULL, UINT8_MAX, 0U,
                LF_MATRIX_EXTENT_EXACT, 0U, 0),
    LF_MX_ENTRY("E04-03", LF_INVALID_ARGUMENT, LF_MATRIX_FORMAT_NES2, 1U,
                0U, LF_MATRIX_SIZE_LINEAR, 2U, LF_MATRIX_SIZE_LINEAR, 0U,
                0U, 0U, 7U, 0U, 0U, 1U, NULL, UINT8_MAX, 0U,
                LF_MATRIX_EXTENT_DELTA, 0U, 1),
    LF_MX_N_RAM("E05-01", LF_OK, 1U, 0U, 2U, 1U, 7U, 7U, 0U, 0U, 1U,
                1U),

    LF_MX_ENTRY("X01-01", LF_OK, LF_MATRIX_FORMAT_NES2, 0U, 0U,
                LF_MATRIX_SIZE_EXPONENT, 56U, LF_MATRIX_SIZE_EXPONENT, 52U,
                0U, 0U, 0U, 0U, 0U, 1U, NULL, UINT8_MAX, 0U,
                LF_MATRIX_EXTENT_EXACT, 0U, 0),
    LF_MX_ENTRY("X01-02", LF_INVALID_ARGUMENT, LF_MATRIX_FORMAT_NES2, 0U,
                0U, LF_MATRIX_SIZE_EXPONENT, 56U, LF_MATRIX_SIZE_EXPONENT,
                52U, 0U, 0U, 0U, 0U, 0U, 1U, NULL, UINT8_MAX, 0U,
                LF_MATRIX_EXTENT_DELTA, 0U, -512),
    LF_MX_N_RAM("X02-01", LF_OK, 1U, 0U, 32U, 1U, 0U, 9U, 0U, 0U, 1U,
                1U),
    LF_MX_N_RAM("X02-02", LF_INVALID_ARGUMENT, 1U, 0U, 32U, 2U, 0U, 9U,
                0U, 0U, 1U, 1U),
    LF_MX_ENTRY("X03-01", LF_OK, LF_MATRIX_FORMAT_NES2, 4U, 4U,
                LF_MATRIX_SIZE_LINEAR, 2U, LF_MATRIX_SIZE_LINEAR, 0U, 0U,
                7U, 7U, 0U, 1U, 1U, NULL, UINT8_MAX, 0U,
                LF_MATRIX_EXTENT_EXACT, 0U, 0),
    LF_MX_ENTRY("X03-02", LF_INVALID_ARGUMENT, LF_MATRIX_FORMAT_NES2, 4U,
                5U, LF_MATRIX_SIZE_LINEAR, 2U, LF_MATRIX_SIZE_LINEAR, 0U,
                0U, 7U, 7U, 0U, 1U, 1U, NULL, UINT8_MAX, 0U,
                LF_MATRIX_EXTENT_EXACT, 0U, 0),
    LF_MX_ENTRY("X04-01", LF_INVALID_ARGUMENT, LF_MATRIX_FORMAT_NES2, 3U,
                0U, LF_MATRIX_SIZE_LINEAR, 1U, LF_MATRIX_SIZE_LINEAR, 1U,
                0U, 0U, 0U, 0U, 1U, 0U, NULL, UINT8_MAX, 0U,
                LF_MATRIX_EXTENT_EXACT, 0U, 0),
    LF_MX_ENTRY("X04-02", LF_INVALID_ARGUMENT, LF_MATRIX_FORMAT_NES2, 3U,
                0U, LF_MATRIX_SIZE_LINEAR, 1U, LF_MATRIX_SIZE_LINEAR, 1U,
                0U, 0U, 0U, 0U, 1U, 0U, NULL, UINT8_MAX, 0U,
                LF_MATRIX_EXTENT_DELTA, 0U, -1),
    LF_MX_N_UNKNOWN_BAD_MAGIC("X04-03"),
};

#define LF_LOAD_BOARD_RAM_CASE_COUNT 179U
#define LF_MX_B_N(id_value, status_value, mapper_value, submapper_value, \
                  prg_value, chr_value) \
  LF_MX_N(id_value, status_value, mapper_value, submapper_value, prg_value, \
          chr_value)
#define LF_MX_B_R(id_value, status_value, mapper_value, submapper_value, \
                  prg_value) \
  LF_MX_N_RAM(id_value, status_value, mapper_value, submapper_value, prg_value, \
              0U, 0U, 0U, 7U, 0U, 0U, 0U)
#define LF_MX_B_RAM(id_value, status_value, mapper_value, submapper_value, \
                    prg_value, chr_value, work_value, nv_value, chr_ram_value, \
                    chr_nv_value, battery_value, trainer_value) \
  LF_MX_N_RAM(id_value, status_value, mapper_value, submapper_value, prg_value, \
              chr_value, work_value, nv_value, chr_ram_value, chr_nv_value, \
              battery_value, trainer_value)

static const lf_load_matrix_case lf_load_board_ram_cases[] = {
    LF_MX_B_N("B00-01", LF_OK, 0U, 0U, 1U, 1U),
    LF_MX_B_N("B00-02", LF_OK, 0U, 0U, 2U, 1U),
    LF_MX_B_R("B00-03", LF_OK, 0U, 0U, 1U),
    LF_MX_B_R("B00-04", LF_OK, 0U, 0U, 2U),
    LF_MX_B_N("B01-01", LF_INVALID_ARGUMENT, 0U, 1U, 1U, 1U),
    LF_MX_B_N("B01-02", LF_INVALID_ARGUMENT, 0U, 0U, 0U, 1U),
    LF_MX_N_EXP_P("B01-03", LF_INVALID_ARGUMENT, 0U, 0U, 52U, 1U),
    LF_MX_B_N("B01-04", LF_INVALID_ARGUMENT, 0U, 0U, 3U, 1U),
    LF_MX_B_N("B01-05", LF_INVALID_ARGUMENT, 0U, 0U, 1U, 2U),
    LF_MX_B_N("B01-06", LF_INVALID_ARGUMENT, 0U, 0U, 1U, 4U),
    LF_MX_N_EXP_C("B01-07", LF_INVALID_ARGUMENT, 0U, 0U, 1U, 40U),
    LF_MX_B_N("B20-01", LF_OK, 2U, 0U, 1U, 1U),
    LF_MX_B_R("B20-02", LF_OK, 2U, 1U, 3U),
    LF_MX_B_R("B20-03", LF_OK, 2U, 2U, 256U),
    LF_MX_B_R("B20-04", LF_OK, 2U, 2U, 1U),
    LF_MX_B_N("B20-05", LF_OK, 2U, 0U, 256U, 1U),
    LF_MX_B_N("B20-06", LF_OK, 2U, 1U, 3U, 1U),
    LF_MX_B_R("B21-01", LF_INVALID_ARGUMENT, 2U, 0U, 0U),
    LF_MX_N_EXP_P_RAM("B21-02", LF_INVALID_ARGUMENT, 2U, 0U, 52U),
    LF_MX_N_EXP_P_RAM("B21-03", LF_INVALID_ARGUMENT, 2U, 0U, 53U),
    LF_MX_B_R("B21-04", LF_INVALID_ARGUMENT, 2U, 0U, 257U),
    LF_MX_B_R("B21-05", LF_INVALID_ARGUMENT, 2U, 3U, 1U),
    LF_MX_B_N("B21-06", LF_INVALID_ARGUMENT, 2U, 0U, 1U, 2U),
    LF_MX_B_N("B30-01", LF_OK, 3U, 0U, 1U, 1U),
    LF_MX_B_N("B30-02", LF_OK, 3U, 1U, 2U, 1U),
    LF_MX_B_N("B30-03", LF_OK, 3U, 2U, 1U, 2U),
    LF_MX_B_N("B30-04", LF_OK, 3U, 0U, 2U, 2U),
    LF_MX_B_N("B30-05", LF_OK, 3U, 1U, 1U, 4U),
    LF_MX_B_N("B30-06", LF_OK, 3U, 2U, 2U, 4U),
    LF_MX_B_R("B31-01", LF_INVALID_ARGUMENT, 3U, 0U, 1U),
    LF_MX_B_N("B31-02", LF_INVALID_ARGUMENT, 3U, 0U, 1U, 0U),
    LF_MX_N_EXP_C("B31-03", LF_INVALID_ARGUMENT, 3U, 0U, 1U, 48U),
    LF_MX_B_N("B31-04", LF_INVALID_ARGUMENT, 3U, 0U, 1U, 8U),
    LF_MX_N_EXP_P("B31-05", LF_INVALID_ARGUMENT, 3U, 0U, 52U, 1U),
    LF_MX_B_N("B31-06", LF_INVALID_ARGUMENT, 3U, 0U, 3U, 1U),
    LF_MX_B_N("B31-07", LF_INVALID_ARGUMENT, 3U, 3U, 1U, 1U),
    LF_MX_B_R("B70-01", LF_OK, 7U, 0U, 2U),
    LF_MX_B_R("B70-02", LF_OK, 7U, 1U, 6U),
    LF_MX_B_R("B70-03", LF_OK, 7U, 2U, 16U),
    LF_MX_B_R("B71-01", LF_INVALID_ARGUMENT, 7U, 0U, 0U),
    LF_MX_B_R("B71-02", LF_INVALID_ARGUMENT, 7U, 0U, 1U),
    LF_MX_B_R("B71-03", LF_INVALID_ARGUMENT, 7U, 0U, 3U),
    LF_MX_B_R("B71-04", LF_INVALID_ARGUMENT, 7U, 0U, 18U),
    LF_MX_B_N("B71-05", LF_INVALID_ARGUMENT, 7U, 0U, 2U, 1U),
    LF_MX_B_R("B71-06", LF_INVALID_ARGUMENT, 7U, 3U, 2U),
    LF_MX_B_RAM("B71-07", LF_INVALID_ARGUMENT, 7U, 0U, 2U, 0U, 0U, 0U, 6U, 0U, 0U, 0U),
    LF_MX_B_N("B10-01", LF_OK, 1U, 0U, 2U, 1U),
    LF_MX_B_N("B10-02", LF_OK, 1U, 0U, 4U, 1U),
    LF_MX_B_N("B10-03", LF_OK, 1U, 0U, 8U, 1U),
    LF_MX_B_N("B10-04", LF_OK, 1U, 0U, 16U, 1U),
    LF_MX_B_N("B10-05", LF_OK, 1U, 0U, 32U, 1U),
    LF_MX_B_N("B10-06", LF_OK, 1U, 0U, 2U, 2U),
    LF_MX_B_N("B10-07", LF_OK, 1U, 0U, 2U, 4U),
    LF_MX_B_N("B10-08", LF_OK, 1U, 0U, 2U, 8U),
    LF_MX_B_N("B10-09", LF_OK, 1U, 0U, 2U, 16U),
    LF_MX_B_R("B10-10", LF_OK, 1U, 0U, 2U),
    LF_MX_B_N("B10-11", LF_OK, 1U, 5U, 2U, 1U),
    LF_MX_B_N("B11-01", LF_INVALID_ARGUMENT, 1U, 0U, 1U, 1U),
    LF_MX_B_N("B11-02", LF_INVALID_ARGUMENT, 1U, 0U, 3U, 1U),
    LF_MX_B_N("B11-03", LF_INVALID_ARGUMENT, 1U, 0U, 64U, 1U),
    LF_MX_N_EXP_C("B11-04", LF_INVALID_ARGUMENT, 1U, 0U, 2U, 48U),
    LF_MX_N_EXP_C("B11-05", LF_INVALID_ARGUMENT, 1U, 0U, 2U, 53U),
    LF_MX_B_N("B11-06", LF_INVALID_ARGUMENT, 1U, 0U, 2U, 32U),
    LF_MX_B_N("B11-07", LF_INVALID_ARGUMENT, 1U, 0U, 32U, 2U),
    LF_MX_B_N("B11-08", LF_INVALID_ARGUMENT, 1U, 1U, 2U, 1U),
    LF_MX_B_N("B11-09", LF_INVALID_ARGUMENT, 1U, 5U, 4U, 1U),
    LF_MX_B_RAM("B12-01", LF_OK, 1U, 0U, 2U, 1U, 0U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("B12-02", LF_OK, 1U, 0U, 2U, 1U, 7U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("B12-03", LF_OK, 1U, 0U, 2U, 1U, 8U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("B12-04", LF_OK, 1U, 0U, 2U, 1U, 9U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("B12-05", LF_OK, 1U, 0U, 2U, 1U, 0U, 7U, 0U, 0U, 1U, 0U),
    LF_MX_B_RAM("B12-06", LF_OK, 1U, 0U, 2U, 1U, 0U, 8U, 0U, 0U, 1U, 0U),
    LF_MX_B_RAM("B12-07", LF_OK, 1U, 0U, 2U, 1U, 0U, 9U, 0U, 0U, 1U, 0U),
    LF_MX_B_RAM("B12-08", LF_OK, 1U, 0U, 2U, 1U, 7U, 7U, 0U, 0U, 1U, 0U),
    LF_MX_B_RAM("B12-09", LF_OK, 1U, 0U, 32U, 0U, 0U, 9U, 7U, 0U, 1U, 0U),
    LF_MX_B_RAM("B13-01", LF_INVALID_ARGUMENT, 1U, 0U, 2U, 1U, 10U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("B13-02", LF_INVALID_ARGUMENT, 1U, 0U, 2U, 1U, 6U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("B13-03", LF_INVALID_ARGUMENT, 1U, 0U, 2U, 1U, 0U, 6U, 0U, 0U, 1U, 0U),
    LF_MX_B_RAM("B13-04", LF_INVALID_ARGUMENT, 1U, 0U, 2U, 1U, 8U, 7U, 0U, 0U, 1U, 0U),
    LF_MX_B_RAM("B13-05", LF_INVALID_ARGUMENT, 1U, 0U, 2U, 1U, 9U, 7U, 0U, 0U, 1U, 0U),
    LF_MX_B_RAM("B13-06", LF_INVALID_ARGUMENT, 1U, 0U, 2U, 1U, 0U, 0U, 0U, 0U, 1U, 0U),
    LF_MX_B_RAM("B13-07", LF_INVALID_ARGUMENT, 1U, 0U, 2U, 1U, 0U, 7U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("B13-08", LF_INVALID_ARGUMENT, 1U, 0U, 2U, 2U, 8U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("B13-09", LF_INVALID_ARGUMENT, 1U, 0U, 2U, 2U, 0U, 9U, 0U, 0U, 1U, 0U),
    LF_MX_B_RAM("B13-10", LF_INVALID_ARGUMENT, 1U, 0U, 2U, 1U, 0U, 0U, 0U, 7U, 0U, 0U),
    LF_MX_B_N("B40-01", LF_OK, 4U, 0U, 1U, 1U),
    LF_MX_B_N("B40-02", LF_OK, 4U, 4U, 2U, 1U),
    LF_MX_B_N("B40-03", LF_OK, 4U, 0U, 4U, 1U),
    LF_MX_B_N("B40-04", LF_OK, 4U, 4U, 8U, 1U),
    LF_MX_B_N("B40-05", LF_OK, 4U, 0U, 16U, 1U),
    LF_MX_B_N("B40-06", LF_OK, 4U, 4U, 32U, 1U),
    LF_MX_B_N("B40-07", LF_OK, 4U, 0U, 2U, 32U),
    LF_MX_B_R("B40-08", LF_OK, 4U, 4U, 2U),
    LF_MX_B_RAM("B41-01", LF_OK, 4U, 0U, 2U, 1U, 0U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("B41-02", LF_OK, 4U, 0U, 2U, 1U, 7U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("B41-03", LF_OK, 4U, 0U, 2U, 1U, 0U, 7U, 0U, 0U, 1U, 0U),
    LF_MX_B_RAM("B41-04", LF_OK, 4U, 4U, 2U, 0U, 0U, 7U, 7U, 0U, 1U, 0U),
    LF_MX_N_EXP_P("B42-01", LF_INVALID_ARGUMENT, 4U, 0U, 52U, 1U),
    LF_MX_B_N("B42-02", LF_INVALID_ARGUMENT, 4U, 0U, 3U, 1U),
    LF_MX_B_N("B42-03", LF_INVALID_ARGUMENT, 4U, 0U, 64U, 1U),
    LF_MX_N_EXP_C("B42-04", LF_INVALID_ARGUMENT, 4U, 0U, 2U, 48U),
    LF_MX_N_EXP_C("B42-05", LF_INVALID_ARGUMENT, 4U, 0U, 2U, 53U),
    LF_MX_B_N("B42-06", LF_INVALID_ARGUMENT, 4U, 0U, 2U, 64U),
    LF_MX_B_N("B42-07", LF_INVALID_ARGUMENT, 4U, 1U, 2U, 1U),
    LF_MX_B_N("B42-08", LF_INVALID_ARGUMENT, 4U, 3U, 2U, 1U),
    LF_MX_B_N("B42-09", LF_INVALID_ARGUMENT, 4U, 5U, 2U, 1U),
    LF_MX_B_RAM("B43-01", LF_INVALID_ARGUMENT, 4U, 0U, 2U, 1U, 6U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("B43-02", LF_INVALID_ARGUMENT, 4U, 0U, 2U, 1U, 8U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("B43-03", LF_INVALID_ARGUMENT, 4U, 0U, 2U, 1U, 0U, 6U, 0U, 0U, 1U, 0U),
    LF_MX_B_RAM("B43-04", LF_INVALID_ARGUMENT, 4U, 0U, 2U, 1U, 0U, 8U, 0U, 0U, 1U, 0U),
    LF_MX_B_RAM("B43-05", LF_INVALID_ARGUMENT, 4U, 0U, 2U, 1U, 0U, 0U, 0U, 0U, 1U, 0U),
    LF_MX_B_RAM("B43-06", LF_INVALID_ARGUMENT, 4U, 0U, 2U, 1U, 0U, 7U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("B43-07", LF_INVALID_ARGUMENT, 4U, 0U, 2U, 1U, 8U, 8U, 0U, 0U, 1U, 0U),
    LF_MX_B_RAM("B43-08", LF_INVALID_ARGUMENT, 4U, 0U, 2U, 1U, 0U, 0U, 0U, 7U, 0U, 0U),
    LF_MX_B_N("B50-01", LF_INVALID_ARGUMENT, 5U, 0U, 2U, 1U),
    LF_MX_B_N("B50-02", LF_INVALID_ARGUMENT, 6U, 0U, 2U, 1U),
    LF_MX_B_N("B50-03", LF_INVALID_ARGUMENT, 8U, 0U, 2U, 1U),
    LF_MX_B_N("B50-04", LF_INVALID_ARGUMENT, 15U, 0U, 2U, 1U),
    LF_MX_B_RAM("R01-01", LF_OK, 1U, 0U, 2U, 1U, 0U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("R01-02", LF_INVALID_ARGUMENT, 1U, 0U, 2U, 1U, 1U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("R01-03", LF_INVALID_ARGUMENT, 1U, 0U, 2U, 1U, 6U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("R01-04", LF_OK, 1U, 0U, 2U, 1U, 7U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("R01-05", LF_OK, 1U, 0U, 2U, 1U, 8U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("R01-06", LF_OK, 1U, 0U, 2U, 1U, 9U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("R01-07", LF_INVALID_ARGUMENT, 1U, 0U, 2U, 1U, 10U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("R01-08", LF_INVALID_ARGUMENT, 1U, 0U, 2U, 1U, 15U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("R02-01", LF_OK, 1U, 0U, 2U, 1U, 0U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("R02-02", LF_INVALID_ARGUMENT, 1U, 0U, 2U, 1U, 0U, 1U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("R02-03", LF_INVALID_ARGUMENT, 1U, 0U, 2U, 1U, 0U, 6U, 0U, 0U, 1U, 0U),
    LF_MX_B_RAM("R02-04", LF_OK, 1U, 0U, 2U, 1U, 0U, 7U, 0U, 0U, 1U, 0U),
    LF_MX_B_RAM("R02-05", LF_OK, 1U, 0U, 2U, 1U, 0U, 8U, 0U, 0U, 1U, 0U),
    LF_MX_B_RAM("R02-06", LF_OK, 1U, 0U, 2U, 1U, 0U, 9U, 0U, 0U, 1U, 0U),
    LF_MX_B_RAM("R02-07", LF_INVALID_ARGUMENT, 1U, 0U, 2U, 1U, 0U, 10U, 0U, 0U, 1U, 0U),
    LF_MX_B_RAM("R02-08", LF_INVALID_ARGUMENT, 1U, 0U, 2U, 1U, 0U, 15U, 0U, 0U, 1U, 0U),
    LF_MX_B_RAM("R03-01", LF_OK, 4U, 0U, 2U, 1U, 0U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("R03-02", LF_INVALID_ARGUMENT, 4U, 0U, 2U, 1U, 1U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("R03-03", LF_INVALID_ARGUMENT, 4U, 0U, 2U, 1U, 6U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("R03-04", LF_OK, 4U, 0U, 2U, 1U, 7U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("R03-05", LF_INVALID_ARGUMENT, 4U, 0U, 2U, 1U, 8U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("R03-06", LF_INVALID_ARGUMENT, 4U, 0U, 2U, 1U, 9U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("R03-07", LF_INVALID_ARGUMENT, 4U, 0U, 2U, 1U, 10U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("R03-08", LF_INVALID_ARGUMENT, 4U, 0U, 2U, 1U, 15U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("R04-01", LF_OK, 4U, 0U, 2U, 1U, 0U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("R04-02", LF_INVALID_ARGUMENT, 4U, 0U, 2U, 1U, 0U, 1U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("R04-03", LF_INVALID_ARGUMENT, 4U, 0U, 2U, 1U, 0U, 6U, 0U, 0U, 1U, 0U),
    LF_MX_B_RAM("R04-04", LF_OK, 4U, 0U, 2U, 1U, 0U, 7U, 0U, 0U, 1U, 0U),
    LF_MX_B_RAM("R04-05", LF_INVALID_ARGUMENT, 4U, 0U, 2U, 1U, 0U, 8U, 0U, 0U, 1U, 0U),
    LF_MX_B_RAM("R04-06", LF_INVALID_ARGUMENT, 4U, 0U, 2U, 1U, 0U, 9U, 0U, 0U, 1U, 0U),
    LF_MX_B_RAM("R04-07", LF_INVALID_ARGUMENT, 4U, 0U, 2U, 1U, 0U, 10U, 0U, 0U, 1U, 0U),
    LF_MX_B_RAM("R04-08", LF_INVALID_ARGUMENT, 4U, 0U, 2U, 1U, 0U, 15U, 0U, 0U, 1U, 0U),
    LF_MX_B_RAM("R05-01", LF_INVALID_ARGUMENT, 0U, 0U, 1U, 0U, 0U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("R05-02", LF_INVALID_ARGUMENT, 0U, 0U, 1U, 0U, 0U, 0U, 6U, 0U, 0U, 0U),
    LF_MX_B_RAM("R05-03", LF_OK, 0U, 0U, 1U, 0U, 0U, 0U, 7U, 0U, 0U, 0U),
    LF_MX_B_RAM("R05-04", LF_INVALID_ARGUMENT, 0U, 0U, 1U, 0U, 0U, 0U, 8U, 0U, 0U, 0U),
    LF_MX_B_RAM("R05-05", LF_INVALID_ARGUMENT, 0U, 0U, 1U, 0U, 0U, 0U, 15U, 0U, 0U, 0U),
    LF_MX_B_RAM("R06-01", LF_OK, 0U, 0U, 1U, 1U, 0U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("R06-02", LF_INVALID_ARGUMENT, 0U, 0U, 1U, 1U, 0U, 0U, 0U, 1U, 0U, 0U),
    LF_MX_B_RAM("R06-03", LF_INVALID_ARGUMENT, 0U, 0U, 1U, 1U, 0U, 0U, 0U, 7U, 0U, 0U),
    LF_MX_B_RAM("R06-04", LF_INVALID_ARGUMENT, 0U, 0U, 1U, 1U, 0U, 0U, 0U, 15U, 0U, 0U),
    LF_MX_B_RAM("R07-01", LF_INVALID_ARGUMENT, 0U, 0U, 1U, 1U, 0U, 0U, 7U, 0U, 0U, 0U),
    LF_MX_B_RAM("R07-02", LF_INVALID_ARGUMENT, 1U, 0U, 2U, 1U, 0U, 0U, 7U, 0U, 0U, 0U),
    LF_MX_B_RAM("R08-01", LF_INVALID_ARGUMENT, 0U, 0U, 1U, 1U, 7U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("R08-02", LF_INVALID_ARGUMENT, 2U, 0U, 1U, 1U, 7U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("R08-03", LF_INVALID_ARGUMENT, 3U, 0U, 1U, 1U, 7U, 0U, 0U, 0U, 0U, 0U),
    LF_MX_B_RAM("R08-04", LF_INVALID_ARGUMENT, 7U, 0U, 2U, 0U, 7U, 0U, 7U, 0U, 0U, 0U),
    LF_MX_B_RAM("R08-05", LF_INVALID_ARGUMENT, 0U, 0U, 1U, 1U, 0U, 7U, 0U, 0U, 1U, 0U),
    LF_MX_B_RAM("R08-06", LF_INVALID_ARGUMENT, 2U, 0U, 1U, 1U, 0U, 7U, 0U, 0U, 1U, 0U),
    LF_MX_B_RAM("R08-07", LF_INVALID_ARGUMENT, 3U, 0U, 1U, 1U, 0U, 7U, 0U, 0U, 1U, 0U),
    LF_MX_B_RAM("R08-08", LF_INVALID_ARGUMENT, 7U, 0U, 2U, 0U, 0U, 7U, 7U, 0U, 1U, 0U),
    LF_MX_I("I01-01", LF_OK, 1U, 16U, 1U, 0U, 0U),
    LF_MX_I("I01-02", LF_OK, 1U, 16U, 1U, 1U, 0U),
    LF_MX_I("I01-03", LF_OK, 1U, 32U, 1U, 0U, 0U),
    LF_MX_I("I01-04", LF_OK, 1U, 32U, 1U, 1U, 0U),
    LF_MX_I("I02-01", LF_OK, 4U, 2U, 1U, 0U, 0U),
    LF_MX_I("I02-02", LF_OK, 4U, 2U, 1U, 1U, 0U),
    LF_MX_I("I03-01", LF_INVALID_ARGUMENT, 0U, 1U, 1U, 1U, 0U),
    LF_MX_I("I03-02", LF_INVALID_ARGUMENT, 2U, 1U, 1U, 1U, 0U),
    LF_MX_I("I03-03", LF_INVALID_ARGUMENT, 3U, 1U, 1U, 1U, 0U),
    LF_MX_I("I03-04", LF_INVALID_ARGUMENT, 7U, 2U, 0U, 1U, 0U),
};

_Static_assert(sizeof(lf_load_board_ram_cases) /
                       sizeof(lf_load_board_ram_cases[0]) ==
                   LF_LOAD_BOARD_RAM_CASE_COUNT,
               "B/R/I matrix must contain exactly 179 fixed cases");

typedef struct lf_load_allocation_class {
  const char *id;
  const char *matrix_case_id;
  const lf_load_matrix_case *custom_case;
} lf_load_allocation_class;

#define LF_LOAD_ALLOCATION_CLASS_COUNT 21U

static const lf_load_matrix_case lf_load_allocation_f03 =
    LF_MX_I("H04-03", LF_OK, 0U, 1U, 1U, 0U, 1U);
static const lf_load_matrix_case lf_load_allocation_f04 =
    LF_MX_N_RAM("B00-03+trainer", LF_OK, 0U, 0U, 1U, 0U, 0U, 0U, 7U, 0U,
                0U, 1U);
static const lf_load_matrix_case lf_load_allocation_f13 =
    LF_MX_N_RAM("mapper1-P512-C-R-W32", LF_OK, 1U, 0U, 32U, 0U, 9U, 0U,
                7U, 0U, 0U, 0U);

static const lf_load_allocation_class lf_load_allocation_classes[] = {
    {"F01", "B00-01", NULL}, {"F02", "B00-03", NULL},
    {"F03", "H04-03", &lf_load_allocation_f03},
    {"F04", "B00-03+trainer", &lf_load_allocation_f04},
    {"F05", "B20-03", NULL}, {"F06", "B20-06", NULL},
    {"F07", "B30-06", NULL}, {"F08", "B70-03", NULL},
    {"F09", "B12-01", NULL}, {"F10", "B12-02", NULL},
    {"F11", "B12-05", NULL}, {"F12", "B12-08", NULL},
    {"F13", "mapper1-P512-C-R-W32", &lf_load_allocation_f13},
    {"F14", "B12-09", NULL}, {"F15", "E05-01", NULL},
    {"F16", "E04-02", NULL}, {"F17", "B41-01", NULL},
    {"F18", "B41-02", NULL}, {"F19", "B41-03", NULL},
    {"F20", "B40-08", NULL}, {"F21", "X03-01", NULL},
};

_Static_assert(sizeof(lf_load_allocation_classes) /
                       sizeof(lf_load_allocation_classes[0]) ==
                   LF_LOAD_ALLOCATION_CLASS_COUNT,
               "D-06 allocation layout list must contain exactly 21 classes");

#undef LF_MX_B_RAM
#undef LF_MX_B_R
#undef LF_MX_B_N


_Static_assert(sizeof(lf_load_layout_cases) / sizeof(lf_load_layout_cases[0]) ==
                   LF_LOAD_LAYOUT_CASE_COUNT,
               "S/E/X matrix must contain exactly 62 fixed cases");

#undef LF_RESULT_OK
#undef LF_RESULT_BAD_LONG
#undef LF_RESULT_BAD_SHORT
#undef LF_RESULT_BAD_ZERO
#undef LF_RESULT_NULL
#undef LF_REQUEST_OK
#undef LF_REQUEST_BAD_LONG
#undef LF_REQUEST_BAD_SHORT
#undef LF_REQUEST_BAD_ZERO
#undef LF_REQUEST_NULL
#undef LF_T_BYTES
#undef LF_B_BYTES
#undef LF_Q_HEADER
#undef LF_B_HEADER
#undef LF_LOAD_CASE
#undef LF_LOAD_HEADER

#endif
