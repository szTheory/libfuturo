#ifndef LIBFUTURO_INTERNAL_H
#define LIBFUTURO_INTERNAL_H

#include <libfuturo/libfuturo.h>

typedef struct lf_muhtari_state lf_muhtari_state;

#if !defined(LF_WEB_BUILD)
typedef struct lf_nesturbator_state lf_nesturbator_state;
#endif

typedef enum lf_muhtari_configuration {
  LF_MUHTARI_CONFIGURATION_JOYSTICK_DEFAULT = 0,
  LF_MUHTARI_CONFIGURATION_BATTERY_DIAGNOSTIC = 1
} lf_muhtari_configuration;

#if !defined(LF_WEB_BUILD)
lf_status lf_nesturbator_query_profile(lf_profile *out);
lf_status lf_nesturbator_create(lf_allocate_fn allocate,
                                lf_deallocate_fn deallocate,
                                void *allocator_context,
                                lf_nesturbator_state **out);
void lf_nesturbator_destroy(lf_nesturbator_state **owned);
lf_status lf_nesturbator_load(lf_nesturbator_state *state,
                              const lf_load_request *request,
                              lf_load_result *out);
lf_status lf_nesturbator_set_input(lf_nesturbator_state *state,
                                   const lf_input *input);
lf_status lf_nesturbator_advance(lf_nesturbator_state *state,
                                 const lf_run_request *request,
                                 lf_run_result *out);
lf_status lf_nesturbator_copy_media(lf_nesturbator_state *state,
                                    uint8_t *destination,
                                    size_t capacity_bytes,
                                    lf_media_info *out);
lf_status lf_nesturbator_import_media(lf_nesturbator_state *state,
                                      const char *identity,
                                      const uint8_t *source,
                                      size_t extent_bytes);
lf_status lf_nesturbator_get_snapshot_size(lf_nesturbator_state *state,
                                            size_t *required_bytes);
lf_status lf_nesturbator_capture_snapshot(lf_nesturbator_state *state,
                                           uint8_t *destination,
                                           size_t capacity_bytes);
lf_status lf_nesturbator_restore_snapshot(lf_nesturbator_state *state,
                                           const uint8_t *source,
                                           size_t extent_bytes);
#endif

#if defined(LF_NESTURBATOR_TESTING)
lf_status lf_nesturbator_set_load_epoch_for_testing(
    lf_nesturbator_state *state, uint64_t load_epoch);
lf_status lf_nesturbator_get_restore_attempts_for_testing(
    const lf_nesturbator_state *state, uint64_t *attempts);
lf_status lf_test_set_nesturbator_load_epoch(lf_instance *instance,
                                              uint64_t load_epoch);
lf_status lf_test_get_nesturbator_restore_attempts(
    const lf_instance *instance, uint64_t *attempts);
#endif

lf_status lf_muhtari_resolve_configuration(
    const char *configuration_id, lf_muhtari_configuration *out);
lf_status lf_muhtari_query_profile(const char *configuration_id,
                                   lf_profile *out);
lf_status lf_muhtari_create(lf_allocate_fn allocate,
                             lf_deallocate_fn deallocate,
                             void *allocator_context,
                             lf_muhtari_state **out);
void lf_muhtari_destroy(lf_muhtari_state **owned);
lf_status lf_muhtari_load(lf_muhtari_state *state,
                          const lf_load_request *request,
                          lf_load_result *out);
lf_status lf_muhtari_set_input(lf_muhtari_state *state,
                               const lf_input *input);
lf_status lf_muhtari_advance(lf_muhtari_state *state,
                             const lf_run_request *request,
                             lf_run_result *out);
lf_status lf_muhtari_copy_media(lf_muhtari_state *state,
                                uint8_t *destination,
                                size_t capacity_bytes, lf_media_info *out);
lf_status lf_muhtari_import_media(lf_muhtari_state *state,
                                  const char *identity,
                                  const uint8_t *source,
                                  size_t extent_bytes);
#if defined(LF_MUHTARI_API_REVISION) && LF_MUHTARI_API_REVISION == 8
lf_status lf_muhtari_get_snapshot_size(lf_muhtari_state *state,
                                       size_t *required_bytes);
lf_status lf_muhtari_capture_snapshot(lf_muhtari_state *state,
                                       uint8_t *destination,
                                       size_t capacity_bytes);
lf_status lf_muhtari_restore_snapshot(lf_muhtari_state *state,
                                       const uint8_t *source,
                                       size_t extent_bytes);
#endif

#endif
