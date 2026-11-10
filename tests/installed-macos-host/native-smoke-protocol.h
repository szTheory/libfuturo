/* SPDX-License-Identifier: MIT */

#ifndef LIBFUTURO_NATIVE_SMOKE_PROTOCOL_H
#define LIBFUTURO_NATIVE_SMOKE_PROTOCOL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define LF_SMOKE_PROTOCOL_LINE_CAPACITY 512U

typedef enum {
  LFRequestTerminate,
  LFRequestForceTerminate,
} LFTerminationRequest;

typedef struct {
  char line[LF_SMOKE_PROTOCOL_LINE_CAPACITY];
  size_t line_length;
  bool discarding_line;
  uint64_t last_sequence;
} LFSmokeProtocol;

typedef bool (*LFSmokeRequestHandler)(void *context,
                                     LFTerminationRequest request,
                                     uint64_t sequence);

void lf_smoke_protocol_init(LFSmokeProtocol *protocol);
bool lf_smoke_protocol_feed(LFSmokeProtocol *protocol, const char *bytes,
                            size_t byte_count,
                            LFSmokeRequestHandler handler, void *context);
uint64_t lf_smoke_protocol_last_sequence(const LFSmokeProtocol *protocol);

#endif
