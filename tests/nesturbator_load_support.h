#ifndef LIBFUTURO_TESTS_NESTURBATOR_LOAD_SUPPORT_H
#define LIBFUTURO_TESTS_NESTURBATOR_LOAD_SUPPORT_H

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <sanitizer/asan_interface.h>

#define LF_LOAD_CORPUS_MAX_LIVE_ENTRIES 128U
#define LF_LOAD_CORPUS_MAX_LIVE_BYTES ((size_t)96U * 1024U * 1024U)
#define LF_LOAD_CORPUS_MAX_SINGLE_ALLOCATION ((size_t)8U * 1024U * 1024U)
#define LF_LOAD_CORPUS_MAX_DESCRIPTORS 384U
#define LF_LOAD_CORPUS_MAX_CANDIDATE_CALLS 32U
#define LF_LOAD_CORPUS_MAX_ACCESSIBLE_SPAN ((size_t)67108865U)

static int load_size_add_checked(size_t left, size_t right, size_t *result) {
  if (result == NULL || right > SIZE_MAX - left) {
    return 0;
  }
  *result = left + right;
  return 1;
}

static int load_size_multiply_checked(size_t left, size_t right,
                                      size_t *result) {
  if (result == NULL || (left != 0U && right > SIZE_MAX / left)) {
    return 0;
  }
  *result = left * right;
  return 1;
}

typedef struct load_allocation_tracker {
  void *live_allocations[LF_LOAD_CORPUS_MAX_LIVE_ENTRIES];
  size_t live_sizes[LF_LOAD_CORPUS_MAX_LIVE_ENTRIES];
  size_t live;
  size_t live_bytes;
  size_t allocations;
  size_t frees;
  size_t calls;
  size_t candidate_call_sizes[LF_LOAD_CORPUS_MAX_CANDIDATE_CALLS];
  size_t candidate_call_count;
  size_t candidate_fail_ordinal;
  size_t invalid_frees;
  uint32_t bound_exceeded;
  uint32_t candidate_load_active;
  uint32_t candidate_failure_reached;
} load_allocation_tracker;

typedef struct load_content_span {
  uint8_t *storage;
  uint8_t *bytes;
  size_t capacity_bytes;
  size_t max_capacity_bytes;
  size_t storage_bytes;
  size_t peak_owned_bytes;
} load_content_span;

static int load_content_span_create(load_content_span *span,
                                    size_t capacity_bytes) {
  if (span == NULL || capacity_bytes > LF_LOAD_CORPUS_MAX_LIVE_BYTES) {
    return 0;
  }
  memset(span, 0, sizeof(*span));
  span->max_capacity_bytes = capacity_bytes;
  return 1;
}

static int load_content_span_prepare(load_content_span *span,
                                     const uint8_t header[16],
                                     size_t actual_extent) {
  size_t index = 0U;
  size_t allocation_bytes = actual_extent == 0U ? 1U : actual_extent;
  if (span == NULL || header == NULL ||
      actual_extent > span->max_capacity_bytes ||
      allocation_bytes > LF_LOAD_CORPUS_MAX_LIVE_BYTES) {
    return 0;
  }

  /* Give every parser call an allocation whose ASan right redzone starts at
     the submitted extent. A reusable maximum-size allocation leaves short
     and truncated inputs addressable through its unused tail. */
  if (span->storage == NULL || span->capacity_bytes != actual_extent) {
    uint8_t *replacement = malloc(allocation_bytes);
    if (replacement == NULL) {
      return 0;
    }
    free(span->storage);
    span->storage = replacement;
    span->capacity_bytes = actual_extent;
    span->storage_bytes = allocation_bytes;
    if (span->peak_owned_bytes < allocation_bytes) {
      span->peak_owned_bytes = allocation_bytes;
    }
    span->bytes = actual_extent == 0U ? span->storage + 1U : span->storage;
    for (index = 0U; index < actual_extent; ++index) {
      span->bytes[index] =
          (uint8_t)((index * (size_t)17U + (size_t)3U) & (size_t)0xffU);
    }
  }
  if (actual_extent != 0U) {
    const size_t header_bytes =
        actual_extent < 16U ? actual_extent : 16U;
    memcpy(span->bytes, header, header_bytes);
  }
  for (index = 0U; index < actual_extent && index < 16U; ++index) {
    if (span->bytes[index] != header[index]) {
      return 0;
    }
  }
  return __asan_address_is_poisoned(span->bytes + actual_extent) != 0;
}

static int load_content_span_unchanged(const load_content_span *span,
                                       const uint8_t header[16],
                                       size_t actual_extent) {
  size_t index = 0U;
  if (span == NULL || span->storage == NULL || span->bytes == NULL ||
      header == NULL || actual_extent > span->capacity_bytes ||
      actual_extent != span->capacity_bytes ||
      span->storage_bytes > LF_LOAD_CORPUS_MAX_LIVE_BYTES ||
      __asan_address_is_poisoned(span->bytes + actual_extent) == 0) {
    return 0;
  }
  for (index = 0U; index < actual_extent; ++index) {
    const uint8_t expected =
        index < 16U
            ? header[index]
            : (uint8_t)((index * (size_t)17U + (size_t)3U) &
                        (size_t)0xffU);
    if (span->bytes[index] != expected) {
      return 0;
    }
  }
  return 1;
}

static void load_content_span_destroy(load_content_span *span) {
  if (span == NULL) {
    return;
  }
  free(span->storage);
  memset(span, 0, sizeof(*span));
}

static void *load_tracked_allocate(void *context, size_t bytes) {
  load_allocation_tracker *tracker = context;
  void *allocation = NULL;
  size_t index = 0U;

  if (tracker == NULL) {
    return NULL;
  }
  tracker->calls += 1U;
  if (tracker->candidate_load_active != 0U) {
    if (tracker->candidate_call_count >=
        LF_LOAD_CORPUS_MAX_CANDIDATE_CALLS) {
      tracker->bound_exceeded = 1U;
      return NULL;
    }
    tracker->candidate_call_sizes[tracker->candidate_call_count] = bytes;
    tracker->candidate_call_count += 1U;
    if (tracker->candidate_fail_ordinal != 0U &&
        tracker->candidate_call_count == tracker->candidate_fail_ordinal) {
      tracker->candidate_failure_reached = 1U;
      return NULL;
    }
  }
  if (bytes > LF_LOAD_CORPUS_MAX_SINGLE_ALLOCATION ||
      bytes > LF_LOAD_CORPUS_MAX_LIVE_BYTES ||
      tracker->live_bytes > LF_LOAD_CORPUS_MAX_LIVE_BYTES - bytes) {
    tracker->bound_exceeded = 1U;
    return NULL;
  }
  allocation = malloc(bytes);
  if (allocation == NULL) {
    return NULL;
  }
  for (index = 0U; index < LF_LOAD_CORPUS_MAX_LIVE_ENTRIES; ++index) {
    if (tracker->live_allocations[index] == NULL) {
      tracker->live_allocations[index] = allocation;
      tracker->live_sizes[index] = bytes;
      tracker->live += 1U;
      tracker->live_bytes += bytes;
      tracker->allocations += 1U;
      return allocation;
    }
  }
  tracker->bound_exceeded = 1U;
  free(allocation);
  return NULL;
}

static void load_tracker_begin_candidate(load_allocation_tracker *tracker,
                                         size_t fail_ordinal) {
  if (tracker == NULL) {
    return;
  }
  memset(tracker->candidate_call_sizes, 0,
         sizeof(tracker->candidate_call_sizes));
  tracker->candidate_call_count = 0U;
  tracker->candidate_fail_ordinal = fail_ordinal;
  tracker->candidate_failure_reached = 0U;
  tracker->candidate_load_active = 1U;
}

static void load_tracker_end_candidate(load_allocation_tracker *tracker) {
  if (tracker != NULL) {
    tracker->candidate_load_active = 0U;
  }
}

static void load_tracked_deallocate(void *context, void *allocation) {
  load_allocation_tracker *tracker = context;
  size_t index = 0U;

  if (allocation == NULL) {
    return;
  }
  if (tracker == NULL) {
    free(allocation);
    return;
  }
  for (index = 0U; index < LF_LOAD_CORPUS_MAX_LIVE_ENTRIES; ++index) {
    if (tracker->live_allocations[index] == allocation) {
      tracker->live_allocations[index] = NULL;
      tracker->live_bytes -= tracker->live_sizes[index];
      tracker->live_sizes[index] = 0U;
      tracker->live -= 1U;
      tracker->frees += 1U;
      free(allocation);
      return;
    }
  }
  tracker->invalid_frees += 1U;
}

static int load_tracker_balanced(const load_allocation_tracker *tracker) {
  return tracker != NULL && tracker->live == 0U &&
         tracker->live_bytes == 0U &&
         tracker->allocations == tracker->frees &&
         tracker->invalid_frees == 0U && tracker->bound_exceeded == 0U;
}

static int load_tracker_same_live_set(const load_allocation_tracker *before,
                                      const load_allocation_tracker *after) {
  size_t index = 0U;
  size_t other = 0U;

  if (before == NULL || after == NULL || before->live != after->live ||
      before->live_bytes != after->live_bytes) {
    return 0;
  }
  for (index = 0U; index < LF_LOAD_CORPUS_MAX_LIVE_ENTRIES; ++index) {
    if (before->live_allocations[index] == NULL) {
      continue;
    }
    for (other = 0U; other < LF_LOAD_CORPUS_MAX_LIVE_ENTRIES; ++other) {
      if (before->live_allocations[index] == after->live_allocations[other] &&
          before->live_sizes[index] == after->live_sizes[other]) {
        break;
      }
    }
    if (other == LF_LOAD_CORPUS_MAX_LIVE_ENTRIES) {
      return 0;
    }
  }
  return 1;
}

#endif
