/* SPDX-License-Identifier: MIT */

#include "native-smoke-protocol.h"

#include <stdio.h>
#include <string.h>

typedef struct {
  size_t handled_count;
  uint64_t handled_sequence;
  LFTerminationRequest handled_request;
} LFProtocolControlState;

static bool lf_record_handled_request(void *context,
                                     LFTerminationRequest request,
                                     uint64_t sequence) {
  LFProtocolControlState *state = context;
  ++state->handled_count;
  state->handled_sequence = sequence;
  state->handled_request = request;
  return true;
}

static bool lf_expect(bool condition, const char *description) {
  if (!condition) {
    (void)fprintf(stderr, "native smoke protocol control failed: %s\n",
                  description);
    return false;
  }
  return true;
}

int main(void) {
  LFSmokeProtocol protocol;
  LFProtocolControlState state = {0U, 0U, LFRequestTerminate};
  lf_smoke_protocol_init(&protocol);

  static const char malformed[] =
      "TERMINATE -1\n"
      "TERMINATE +1\n"
      "TERMINATE 0\n"
      "TERMINATE 18446744073709551616\n"
      "TERMINATE 1 trailing\n";
  if (!lf_expect(lf_smoke_protocol_feed(&protocol, malformed,
                                        sizeof(malformed) - 1U,
                                        lf_record_handled_request, &state),
                 "malformed request batch stopped parsing") ||
      !lf_expect(state.handled_count == 0U &&
                     lf_smoke_protocol_last_sequence(&protocol) == 0U,
                 "signed, zero, overflow, or trailing-field request was accepted")) {
    return 1;
  }

  static const char first_valid[] = "TERMINATE 1\n";
  if (!lf_smoke_protocol_feed(&protocol, first_valid, sizeof(first_valid) - 1U,
                              lf_record_handled_request, &state) ||
      !lf_expect(state.handled_count == 1U && state.handled_sequence == 1U &&
                     state.handled_request == LFRequestTerminate,
                 "valid request after malformed input was not handled")) {
    return 1;
  }

  static const char stale[] = "FORCE_TERMINATE 1\n";
  if (!lf_smoke_protocol_feed(&protocol, stale, sizeof(stale) - 1U,
                              lf_record_handled_request, &state) ||
      !lf_expect(state.handled_count == 1U &&
                     lf_smoke_protocol_last_sequence(&protocol) == 1U,
                 "stale sequence was accepted")) {
    return 1;
  }

  static const char nul_request[] = {
      'T', 'E', 'R', 'M', 'I', 'N', 'A', 'T', 'E', ' ', '\0', '2', '\n'};
  if (!lf_smoke_protocol_feed(&protocol, nul_request, sizeof(nul_request),
                              lf_record_handled_request, &state) ||
      !lf_expect(state.handled_count == 1U &&
                     lf_smoke_protocol_last_sequence(&protocol) == 1U,
                 "NUL-containing request was accepted")) {
    return 1;
  }

  char oversized[LF_SMOKE_PROTOCOL_LINE_CAPACITY + 8U];
  (void)memset(oversized, 'X', sizeof(oversized));
  oversized[sizeof(oversized) - 1U] = '\n';
  if (!lf_smoke_protocol_feed(&protocol, oversized, sizeof(oversized),
                              lf_record_handled_request, &state) ||
      !lf_expect(state.handled_count == 1U &&
                     lf_smoke_protocol_last_sequence(&protocol) == 1U,
                 "oversized request was accepted")) {
    return 1;
  }

  static const char recovery_prefix[] = "FORCE_TERMINATE ";
  static const char recovery_suffix[] = "2\n";
  if (!lf_smoke_protocol_feed(&protocol, recovery_prefix,
                              sizeof(recovery_prefix) - 1U,
                              lf_record_handled_request, &state) ||
      !lf_smoke_protocol_feed(&protocol, recovery_suffix,
                              sizeof(recovery_suffix) - 1U,
                              lf_record_handled_request, &state) ||
      !lf_expect(state.handled_count == 2U && state.handled_sequence == 2U &&
                     state.handled_request == LFRequestForceTerminate &&
                     lf_smoke_protocol_last_sequence(&protocol) ==
                         state.handled_sequence,
                 "valid request after protocol errors was not acknowledged and handled")) {
    return 1;
  }

  (void)printf("native_smoke_protocol_controls: malformed=signed,zero,overflow,trailing nul=ignored oversized=ignored stale=rejected recovery=handled result=pass\n");
  return 0;
}
