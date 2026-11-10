/* SPDX-License-Identifier: MIT */

#include "native-smoke-protocol.h"

#include <stdio.h>
#include <string.h>

static bool lf_parse_request(const char *line, LFTerminationRequest *request,
                             uint64_t *sequence) {
  const char *digits;
  if (strncmp(line, "TERMINATE ", 10U) == 0) {
    *request = LFRequestTerminate;
    digits = line + 10U;
  } else if (strncmp(line, "FORCE_TERMINATE ", 16U) == 0) {
    *request = LFRequestForceTerminate;
    digits = line + 16U;
  } else {
    return false;
  }

  if (*digits == '\0') {
    return false;
  }
  uint64_t parsed = 0U;
  for (const unsigned char *character = (const unsigned char *)digits;
       *character != (unsigned char)'\0'; ++character) {
    if (*character < (unsigned char)'0' ||
        *character > (unsigned char)'9') {
      return false;
    }
    uint64_t digit = (uint64_t)(*character - (unsigned char)'0');
    if (parsed > (UINT64_MAX - digit) / UINT64_C(10)) {
      return false;
    }
    parsed = parsed * UINT64_C(10) + digit;
  }
  if (parsed == 0U) {
    return false;
  }
  *sequence = parsed;
  return true;
}

void lf_smoke_protocol_init(LFSmokeProtocol *protocol) {
  memset(protocol, 0, sizeof(*protocol));
}

bool lf_smoke_protocol_feed(LFSmokeProtocol *protocol, const char *bytes,
                            size_t byte_count,
                            LFSmokeRequestHandler handler, void *context) {
  for (size_t index = 0U; index < byte_count; ++index) {
    const char character = bytes[index];
    if (character == '\n') {
      if (!protocol->discarding_line) {
        protocol->line[protocol->line_length] = '\0';
        LFTerminationRequest request;
        uint64_t sequence = 0U;
        if (lf_parse_request(protocol->line, &request, &sequence)) {
          if (sequence <= protocol->last_sequence) {
            (void)fprintf(stderr,
                          "native smoke supervisor: stale control request ignored\n");
          } else {
            protocol->last_sequence = sequence;
            if (!handler(context, request, sequence)) {
              return false;
            }
          }
        } else {
          (void)fprintf(stderr,
                        "native smoke supervisor: malformed control request ignored\n");
        }
      }
      protocol->line_length = 0U;
      protocol->discarding_line = false;
    } else if (protocol->discarding_line) {
      continue;
    } else if (character == '\0' ||
               protocol->line_length + 1U >= sizeof(protocol->line)) {
      protocol->line_length = 0U;
      protocol->discarding_line = true;
      (void)fprintf(stderr,
                    "native smoke supervisor: malformed or oversized control request ignored\n");
    } else {
      protocol->line[protocol->line_length] = character;
      ++protocol->line_length;
    }
  }
  return true;
}

uint64_t lf_smoke_protocol_last_sequence(const LFSmokeProtocol *protocol) {
  return protocol->last_sequence;
}
