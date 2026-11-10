#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE 1

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <libfuturo/libfuturo.h>

static lf_status snapshot_control_get_capability(
    const char *profile_id, const char *configuration_id,
    lf_capability capability, uint32_t *supported);
static lf_status snapshot_control_get_snapshot_size(lf_instance *instance,
                                                    size_t *required_bytes);
static lf_status snapshot_control_capture_snapshot(lf_instance *instance,
                                                   void *destination,
                                                   size_t capacity_bytes);
static lf_status snapshot_control_restore_snapshot(lf_instance *instance,
                                                   const void *source,
                                                   size_t source_bytes);

#if defined(SNAPSHOT_CONTROL_INSTALLED)
#define SNAPSHOT_CONTROL_ROUTE "installed"
#define SNAPSHOT_CONTROL_CONSUMER "installed-consumer/nesturbator_session.c"
#else
#define SNAPSHOT_CONTROL_ROUTE "source"
#define SNAPSHOT_CONTROL_CONSUMER "nesturbator_session.c"
#endif

#define main snapshot_control_embedded_main
#define lf_get_capability snapshot_control_get_capability
#define lf_get_snapshot_size snapshot_control_get_snapshot_size
#define lf_capture_snapshot snapshot_control_capture_snapshot
#define lf_restore_snapshot snapshot_control_restore_snapshot
#include SNAPSHOT_CONTROL_CONSUMER
#undef lf_restore_snapshot
#undef lf_capture_snapshot
#undef lf_get_snapshot_size
#undef lf_get_capability
#undef main

typedef struct snapshot_control_outcome {
  const char *name;
  lf_status status;
  uint32_t supported;
} snapshot_control_outcome;

static const snapshot_control_outcome k_denied_outcomes[] = {
    {"ok-unsupported", LF_OK, 0U},
    {"ok-non-one", LF_OK, 2U},
    {"unsupported-supported", LF_UNSUPPORTED, 1U},
    {"invalid-supported", LF_INVALID_ARGUMENT, 1U},
};

static lf_status g_query_status = LF_OK;
static uint32_t g_query_supported = 1U;
static size_t g_query_calls = 0U;
static int g_query_arguments_valid = 1;
static size_t g_snapshot_size_calls = 0U;
static size_t g_snapshot_capture_calls = 0U;
static size_t g_snapshot_restore_calls = 0U;

static void snapshot_control_reset_calls(void) {
  g_query_calls = 0U;
  g_query_arguments_valid = 1;
  g_snapshot_size_calls = 0U;
  g_snapshot_capture_calls = 0U;
  g_snapshot_restore_calls = 0U;
}

static void snapshot_control_set_outcome(lf_status status,
                                         uint32_t supported) {
  g_query_status = status;
  g_query_supported = supported;
}

static lf_status snapshot_control_get_capability(
    const char *profile_id, const char *configuration_id,
    lf_capability capability, uint32_t *supported) {
  const int exact_arguments =
      profile_id != NULL &&
      strcmp(profile_id, "nesturbator-ntsc-v1") == 0 &&
      configuration_id == NULL && capability == LF_CAP_SNAPSHOT &&
      supported != NULL;
  if (g_query_calls == 0U) {
    g_query_arguments_valid = exact_arguments;
  }
  ++g_query_calls;
  if (!exact_arguments) {
    return lf_get_capability(profile_id, configuration_id, capability,
                             supported);
  }
  if (supported != NULL) {
    *supported = g_query_supported;
  }
  if (g_query_status == LF_OK && g_query_supported == 1U &&
      exact_arguments) {
    return lf_get_capability(profile_id, configuration_id, capability,
                             supported);
  }
  return g_query_status;
}

static lf_status snapshot_control_get_snapshot_size(lf_instance *instance,
                                                    size_t *required_bytes) {
  ++g_snapshot_size_calls;
  return lf_get_snapshot_size(instance, required_bytes);
}

static lf_status snapshot_control_capture_snapshot(lf_instance *instance,
                                                   void *destination,
                                                   size_t capacity_bytes) {
  ++g_snapshot_capture_calls;
  return lf_capture_snapshot(instance, destination, capacity_bytes);
}

static lf_status snapshot_control_restore_snapshot(lf_instance *instance,
                                                   const void *source,
                                                   size_t source_bytes) {
  ++g_snapshot_restore_calls;
  return lf_restore_snapshot(instance, source, source_bytes);
}

static int snapshot_control_temp_path(char path[128], size_t path_capacity,
                                      const char *directory,
                                      const char *filename) {
  int written = 0;
  if (path == NULL || path_capacity == 0U || directory == NULL ||
      filename == NULL) {
    return 0;
  }
  written = snprintf(path, path_capacity, "%s/%s", directory, filename);
  return written >= 0 && (size_t)written < path_capacity;
}

static int snapshot_control_query_seen_once(void) {
  return g_query_calls == 1U && g_query_arguments_valid;
}

static int snapshot_control_report_failure(const char *assertion,
                                           const char *case_name,
                                           int handler_result) {
  (void)fprintf(stderr,
                "assertion failed: %s case=%s result=%d query-calls=%zu "
                "query-arguments-valid=%d size=%zu capture=%zu restore=%zu\n",
                assertion, case_name, handler_result, g_query_calls,
                g_query_arguments_valid, g_snapshot_size_calls,
                g_snapshot_capture_calls, g_snapshot_restore_calls);
  return 0;
}

static int snapshot_control_run_denial(const char *checkpoint_path,
                                       const char *case_name,
                                       lf_status status, uint32_t supported,
                                       int process_b, int wrong_oracle) {
  int handler_result = 0;
  snapshot_control_set_outcome(status, supported);
  snapshot_control_reset_calls();
  if (process_b) {
    handler_result =
        run_snapshot_process_restore(checkpoint_path, wrong_oracle);
  } else {
    handler_result = run_snapshot_process_capture(checkpoint_path);
  }
  if (handler_result == 0 || !snapshot_control_query_seen_once() ||
      g_snapshot_size_calls != 0U || g_snapshot_capture_calls != 0U ||
      g_snapshot_restore_calls != 0U) {
    return snapshot_control_report_failure(
        process_b ? "denied B did not fail before all snapshot operations"
                  : "denied A did not fail before all snapshot operations",
        case_name, handler_result);
  }
  return 1;
}

int main(void) {
  char temp_directory[] = "/tmp/libfuturo-snapshot-capability-XXXXXX";
  char checkpoint_path[128] = "";
  char denied_capture_path[128] = "";
  size_t outcome_index = 0U;
  int result = 1;
  int temp_directory_created = 0;

  if (mkdtemp(temp_directory) == NULL) {
    (void)fprintf(stderr,
                  "assertion failed: private temporary directory created\n");
    goto cleanup;
  }
  temp_directory_created = 1;
  if (!snapshot_control_temp_path(checkpoint_path, sizeof(checkpoint_path),
                                  temp_directory, "checkpoint.bin") ||
      !snapshot_control_temp_path(denied_capture_path,
                                  sizeof(denied_capture_path), temp_directory,
                                  "denied-capture.bin")) {
    (void)fprintf(stderr,
                  "assertion failed: private checkpoint paths created\n");
    goto cleanup;
  }

  snapshot_control_set_outcome(LF_OK, 1U);
  snapshot_control_reset_calls();
  result = run_snapshot_process_capture(checkpoint_path);
  if (result != 0 || g_snapshot_size_calls == 0U ||
      g_snapshot_capture_calls == 0U ||
      g_snapshot_restore_calls != 0U) {
    (void)snapshot_control_report_failure(
        "supported A capture control failed", "supported-A", result);
    result = 1;
    goto cleanup;
  }

  snapshot_control_reset_calls();
  result = run_snapshot_process_restore(checkpoint_path, 0);
  if (result != 0 || g_snapshot_restore_calls == 0U) {
    (void)snapshot_control_report_failure(
        "supported B restore control failed", "supported-B", result);
    result = 1;
    goto cleanup;
  }

  snapshot_control_reset_calls();
  result = run_snapshot_process_restore(checkpoint_path, 1);
  if (result != 1 || g_snapshot_restore_calls == 0U) {
    (void)snapshot_control_report_failure(
        "supported B wrong-oracle control failed", "supported-B-wrong",
        result);
    result = 1;
    goto cleanup;
  }

  for (outcome_index = 0U;
       outcome_index < sizeof(k_denied_outcomes) / sizeof(k_denied_outcomes[0]);
       ++outcome_index) {
    const snapshot_control_outcome *outcome =
        &k_denied_outcomes[outcome_index];
    if (!snapshot_control_run_denial(denied_capture_path, outcome->name,
                                     outcome->status, outcome->supported, 0,
                                     0) ||
        !snapshot_control_run_denial(checkpoint_path, outcome->name,
                                     outcome->status, outcome->supported, 1,
                                     0)) {
      result = 1;
      goto cleanup;
    }
  }

  snapshot_control_set_outcome(LF_OK, 0U);
  if (!snapshot_control_run_denial(checkpoint_path, "wrong-oracle-denied",
                                   LF_OK, 0U, 1, 1)) {
    result = 1;
    goto cleanup;
  }

  (void)printf("snapshot_capability_controls: route=%s entries=A,B "
               "denied=zero-snapshot-calls result=pass\n",
               SNAPSHOT_CONTROL_ROUTE);
  result = 0;

cleanup:
  if (checkpoint_path[0] != '\0') {
    (void)unlink(checkpoint_path);
  }
  if (denied_capture_path[0] != '\0') {
    (void)unlink(denied_capture_path);
  }
  if (temp_directory_created) {
    (void)rmdir(temp_directory);
  }
  return result;
}
