#include <libfuturo/libfuturo.h>

#include "muhtari_snapshot_fixture.h"

#include <emscripten/emscripten.h>
#include <stdint.h>
#include <stdlib.h>

#define LF_WEB_SNAPSHOT_PROFILE "muhtari-ntsc-v2"
#define LF_WEB_SNAPSHOT_CONFIGURATION "muhtari-ntsc-battery-diagnostic"
#define LF_WEB_SNAPSHOT_MAX_BYTES ((size_t)128U * 1024U * 1024U)
#define LF_WEB_SNAPSHOT_INSTANCE_ID_OFFSET 316U
#define LF_WEB_SNAPSHOT_INSTANCE_ID_BYTES 32U

static lf_instance *g_instance;
static uint8_t *g_snapshot;
static size_t g_snapshot_bytes;
static uint8_t *g_imported_snapshot;
static size_t g_imported_snapshot_bytes;

static lf_status load_fixture(void) {
  uint8_t content[LF_MUHTARI_FIXTURE_TOTAL_BYTES];
  lf_load_result result = {.struct_size = sizeof(result)};
  const lf_load_request request = {
      .struct_size = sizeof(request),
      .content_data = content,
      .content_size_bytes = sizeof(content),
      .configuration_id = LF_WEB_SNAPSHOT_CONFIGURATION,
  };
  if (g_instance == NULL ||
      lf_build_muhtari_snapshot_fixture(content, sizeof(content)) !=
          sizeof(content)) {
    return LF_INVALID_ARGUMENT;
  }
  const lf_status status = lf_load(g_instance, &request, &result);
  return status != LF_OK ? status : result.loaded == 1U ? LF_OK
                                                       : LF_UNSUPPORTED;
}

static lf_status create_loaded_instance(void) {
  if (g_instance != NULL) {
    return LF_INVALID_ARGUMENT;
  }
  const lf_status status = lf_create(LF_WEB_SNAPSHOT_PROFILE, NULL,
                                     &g_instance);
  if (status != LF_OK || g_instance == NULL) {
    return status == LF_OK ? LF_RESOURCE_EXHAUSTED : status;
  }
  const lf_status load_status = load_fixture();
  if (load_status != LF_OK) {
    (void)lf_destroy(&g_instance);
  }
  return load_status;
}

static lf_status capture_current_snapshot(void) {
  lf_status status = LF_OK;
  free(g_snapshot);
  g_snapshot = NULL;
  g_snapshot_bytes = 0U;
  if (g_instance == NULL) {
    return LF_INVALID_ARGUMENT;
  }
  status = lf_get_snapshot_size(g_instance, &g_snapshot_bytes);
  if (status != LF_OK) {
    return status;
  }
  if (g_snapshot_bytes == 0U ||
      g_snapshot_bytes > LF_WEB_SNAPSHOT_MAX_BYTES) {
    g_snapshot_bytes = 0U;
    return LF_LIMIT_EXCEEDED;
  }
  g_snapshot = (uint8_t *)malloc(g_snapshot_bytes);
  if (g_snapshot == NULL) {
    g_snapshot_bytes = 0U;
    return LF_RESOURCE_EXHAUSTED;
  }
  status = lf_capture_snapshot(g_instance, g_snapshot, g_snapshot_bytes);
  if (status != LF_OK) {
    free(g_snapshot);
    g_snapshot = NULL;
    g_snapshot_bytes = 0U;
  }
  return status;
}

EMSCRIPTEN_KEEPALIVE int lf_web_snapshot_capture_current(void) {
  const lf_status status = create_loaded_instance();
  if (status != LF_OK) {
    return (int)status;
  }
  return (int)capture_current_snapshot();
}

EMSCRIPTEN_KEEPALIVE uintptr_t lf_web_snapshot_pointer(void) {
  return (uintptr_t)g_snapshot;
}

EMSCRIPTEN_KEEPALIVE size_t lf_web_snapshot_size(void) {
  return g_snapshot_bytes;
}

EMSCRIPTEN_KEEPALIVE uintptr_t lf_web_snapshot_identity_pointer(void) {
  if (g_snapshot == NULL ||
      g_snapshot_bytes < LF_WEB_SNAPSHOT_INSTANCE_ID_OFFSET +
                             LF_WEB_SNAPSHOT_INSTANCE_ID_BYTES) {
    return (uintptr_t)0U;
  }
  return (uintptr_t)(g_snapshot + LF_WEB_SNAPSHOT_INSTANCE_ID_OFFSET);
}

EMSCRIPTEN_KEEPALIVE int lf_web_snapshot_prepare_receiver(void) {
  return (int)create_loaded_instance();
}

EMSCRIPTEN_KEEPALIVE int lf_web_snapshot_reload_receiver(void) {
  const lf_status status = load_fixture();
  return status == LF_OK ? (int)capture_current_snapshot() : (int)status;
}

EMSCRIPTEN_KEEPALIVE uintptr_t
lf_web_snapshot_import_buffer(size_t extent_bytes) {
  if (extent_bytes == 0U || extent_bytes > LF_WEB_SNAPSHOT_MAX_BYTES) {
    return (uintptr_t)0U;
  }
  free(g_imported_snapshot);
  g_imported_snapshot = (uint8_t *)malloc(extent_bytes);
  if (g_imported_snapshot == NULL) {
    g_imported_snapshot_bytes = 0U;
    return (uintptr_t)0U;
  }
  g_imported_snapshot_bytes = extent_bytes;
  return (uintptr_t)g_imported_snapshot;
}

EMSCRIPTEN_KEEPALIVE int lf_web_snapshot_restore_import(
    size_t extent_bytes) {
  if (g_instance == NULL || g_imported_snapshot == NULL ||
      extent_bytes != g_imported_snapshot_bytes) {
    return (int)LF_INVALID_ARGUMENT;
  }
  return (int)lf_restore_snapshot(g_instance, g_imported_snapshot,
                                  extent_bytes);
}

EMSCRIPTEN_KEEPALIVE void lf_web_snapshot_dispose(void) {
  (void)lf_destroy(&g_instance);
  free(g_snapshot);
  g_snapshot = NULL;
  g_snapshot_bytes = 0U;
  free(g_imported_snapshot);
  g_imported_snapshot = NULL;
  g_imported_snapshot_bytes = 0U;
}
