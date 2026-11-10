/* SPDX-License-Identifier: MIT */
#include "LFAudioBufferPool.h"

#include <limits.h>
#include <sched.h>

#define LF_AUDIO_SCHEDULING_CLOSED \
  ((uint_fast32_t)UINT32_C(1) << 31U)
#define LF_AUDIO_SCHEDULING_LEASES_MASK \
  (LF_AUDIO_SCHEDULING_CLOSED - (uint_fast32_t)1U)

static uint_fast64_t lf_audio_token_value(uint32_t generation,
                                          uint32_t sequence) {
  return ((uint_fast64_t)generation << 32U) | (uint_fast64_t)sequence;
}

bool lf_audio_buffer_pool_init(lf_audio_buffer_pool *pool) {
  if (pool == NULL) {
    return false;
  }
  for (size_t index = 0U; index < LF_AUDIO_BUFFER_POOL_CAPACITY; ++index) {
    atomic_init(&pool->slots[index].active_token, UINT64_C(0));
    pool->slots[index].next_sequence = 0U;
  }
  atomic_init(&pool->outstanding, 0U);
  atomic_init(&pool->dropped_packets, UINT64_C(0));
  atomic_init(&pool->data_played_back, UINT64_C(0));
  atomic_init(&pool->callbacks_in_flight, 0U);
  atomic_init(&pool->callbacks_pending, 0U);
  atomic_init(&pool->callbacks_enabled, true);
  atomic_init(&pool->scheduling_state, 0U);
  pool->generation = 1U;
  pool->next_slot = 0U;
  return true;
}

bool lf_audio_buffer_pool_begin_generation(lf_audio_buffer_pool *pool) {
  if (pool == NULL ||
      atomic_load_explicit(&pool->outstanding, memory_order_acquire) != 0U ||
      atomic_load_explicit(&pool->callbacks_in_flight,
                           memory_order_acquire) != 0U ||
      atomic_load_explicit(&pool->callbacks_pending,
                           memory_order_acquire) != 0U ||
      (atomic_load_explicit(&pool->scheduling_state,
                            memory_order_acquire) &
       LF_AUDIO_SCHEDULING_LEASES_MASK) != 0U ||
      pool->generation == UINT32_MAX) {
    return false;
  }
  ++pool->generation;
  pool->next_slot = 0U;
  for (size_t index = 0U; index < LF_AUDIO_BUFFER_POOL_CAPACITY; ++index) {
    atomic_store_explicit(&pool->slots[index].active_token, UINT64_C(0),
                          memory_order_release);
    pool->slots[index].next_sequence = 0U;
  }
  atomic_store_explicit(&pool->dropped_packets, UINT64_C(0),
                        memory_order_relaxed);
  atomic_store_explicit(&pool->data_played_back, UINT64_C(0),
                        memory_order_relaxed);
  atomic_store_explicit(&pool->callbacks_enabled, true, memory_order_release);
  atomic_store_explicit(&pool->scheduling_state, 0U, memory_order_release);
  return true;
}

bool lf_audio_buffer_pool_schedule_begin(lf_audio_buffer_pool *pool) {
  if (pool == NULL) {
    return false;
  }
  uint_fast32_t state =
      atomic_load_explicit(&pool->scheduling_state, memory_order_acquire);
  for (;;) {
    if ((state & LF_AUDIO_SCHEDULING_CLOSED) != 0U ||
        (state & LF_AUDIO_SCHEDULING_LEASES_MASK) ==
            LF_AUDIO_SCHEDULING_LEASES_MASK) {
      return false;
    }
    if (atomic_compare_exchange_weak_explicit(
            &pool->scheduling_state, &state, state + 1U,
            memory_order_acq_rel, memory_order_acquire)) {
      return true;
    }
  }
}

void lf_audio_buffer_pool_schedule_end(lf_audio_buffer_pool *pool) {
  if (pool != NULL) {
    (void)atomic_fetch_sub_explicit(&pool->scheduling_state, 1U,
                                    memory_order_release);
  }
}

void lf_audio_buffer_pool_disarm(lf_audio_buffer_pool *pool) {
  if (pool != NULL) {
    (void)atomic_fetch_or_explicit(&pool->scheduling_state,
                                   LF_AUDIO_SCHEDULING_CLOSED,
                                   memory_order_acq_rel);
    while ((atomic_load_explicit(&pool->scheduling_state,
                                 memory_order_acquire) &
            LF_AUDIO_SCHEDULING_LEASES_MASK) != 0U) {
      (void)sched_yield();
    }
  }
}

lf_audio_buffer_claim_result lf_audio_buffer_pool_claim(
    lf_audio_buffer_pool *pool, size_t frame_count,
    lf_audio_buffer_token *token) {
  if (pool == NULL || token == NULL || frame_count == 0U ||
      frame_count > LF_AUDIO_BUFFER_POOL_MAX_FRAMES) {
    return LF_AUDIO_BUFFER_INVALID;
  }
  if ((atomic_load_explicit(&pool->scheduling_state,
                            memory_order_acquire) &
       LF_AUDIO_SCHEDULING_CLOSED) != 0U) {
    return LF_AUDIO_BUFFER_DISARMED;
  }

  for (size_t offset = 0U; offset < LF_AUDIO_BUFFER_POOL_CAPACITY; ++offset) {
    const size_t slot_index =
        (pool->next_slot + offset) % LF_AUDIO_BUFFER_POOL_CAPACITY;
    lf_audio_buffer_pool_slot *slot = &pool->slots[slot_index];
    if (slot->next_sequence == UINT32_MAX) {
      continue;
    }
    const uint32_t sequence = slot->next_sequence + 1U;
    const uint_fast64_t active_value =
        lf_audio_token_value(pool->generation, sequence);
    uint_fast64_t expected = UINT64_C(0);
    if (!atomic_compare_exchange_strong_explicit(
            &slot->active_token, &expected, active_value,
            memory_order_acq_rel, memory_order_acquire)) {
      continue;
    }
    slot->next_sequence = sequence;
    pool->next_slot = (slot_index + 1U) % LF_AUDIO_BUFFER_POOL_CAPACITY;
    (void)atomic_fetch_add_explicit(&pool->outstanding, 1U,
                                    memory_order_release);
    token->slot = (uint32_t)slot_index;
    token->generation = pool->generation;
    token->sequence = sequence;
    return LF_AUDIO_BUFFER_CLAIMED;
  }

  (void)atomic_fetch_add_explicit(&pool->dropped_packets, UINT64_C(1),
                                  memory_order_relaxed);
  return LF_AUDIO_BUFFER_DROPPED;
}

bool lf_audio_buffer_pool_release_unscheduled(lf_audio_buffer_pool *pool,
                                             lf_audio_buffer_token token) {
  return lf_audio_buffer_pool_retire(pool, token, false);
}

bool lf_audio_buffer_pool_callback_begin(lf_audio_buffer_pool *pool) {
  if (pool == NULL) {
    return false;
  }
  (void)atomic_fetch_add_explicit(&pool->callbacks_in_flight, 1U,
                                  memory_order_acq_rel);
  if (atomic_load_explicit(&pool->callbacks_enabled, memory_order_acquire)) {
    return true;
  }
  (void)atomic_fetch_sub_explicit(&pool->callbacks_in_flight, 1U,
                                  memory_order_release);
  return false;
}

void lf_audio_buffer_pool_callback_end(lf_audio_buffer_pool *pool) {
  if (pool != NULL) {
    (void)atomic_fetch_sub_explicit(&pool->callbacks_in_flight, 1U,
                                    memory_order_release);
  }
}

void lf_audio_buffer_pool_callback_scheduled(lf_audio_buffer_pool *pool) {
  if (pool != NULL) {
    (void)atomic_fetch_add_explicit(&pool->callbacks_pending, 1U,
                                    memory_order_release);
  }
}

void lf_audio_buffer_pool_callback_finished(lf_audio_buffer_pool *pool) {
  if (pool != NULL) {
    (void)atomic_fetch_sub_explicit(&pool->callbacks_pending, 1U,
                                    memory_order_release);
  }
}

bool lf_audio_buffer_pool_retire(lf_audio_buffer_pool *pool,
                                 lf_audio_buffer_token token,
                                 bool data_played_back) {
  if (pool == NULL || token.slot >= LF_AUDIO_BUFFER_POOL_CAPACITY ||
      token.generation == 0U || token.sequence == 0U) {
    return false;
  }
  lf_audio_buffer_pool_slot *slot = &pool->slots[token.slot];
  uint_fast64_t expected =
      lf_audio_token_value(token.generation, token.sequence);
  if (!atomic_compare_exchange_strong_explicit(
          &slot->active_token, &expected, UINT64_C(0), memory_order_acq_rel,
          memory_order_acquire)) {
    return false;
  }
  (void)atomic_fetch_sub_explicit(&pool->outstanding, 1U,
                                  memory_order_release);
  if (data_played_back) {
    (void)atomic_fetch_add_explicit(&pool->data_played_back, UINT64_C(1),
                                    memory_order_relaxed);
  }
  return true;
}

void lf_audio_buffer_pool_disable_callbacks(lf_audio_buffer_pool *pool) {
  if (pool != NULL) {
    atomic_store_explicit(&pool->callbacks_enabled, false,
                          memory_order_release);
  }
}

bool lf_audio_buffer_pool_reconcile_stopped(lf_audio_buffer_pool *pool) {
  if (pool == NULL ||
      atomic_load_explicit(&pool->callbacks_enabled, memory_order_acquire) ||
      atomic_load_explicit(&pool->callbacks_in_flight,
                           memory_order_acquire) != 0U ||
      atomic_load_explicit(&pool->callbacks_pending,
                           memory_order_acquire) != 0U ||
      (atomic_load_explicit(&pool->scheduling_state,
                            memory_order_acquire) &
       LF_AUDIO_SCHEDULING_LEASES_MASK) != 0U) {
    return false;
  }
  for (size_t index = 0U; index < LF_AUDIO_BUFFER_POOL_CAPACITY; ++index) {
    atomic_store_explicit(&pool->slots[index].active_token, UINT64_C(0),
                          memory_order_release);
    pool->slots[index].next_sequence = 0U;
  }
  atomic_store_explicit(&pool->outstanding, 0U, memory_order_release);
  atomic_store_explicit(&pool->scheduling_state,
                        LF_AUDIO_SCHEDULING_CLOSED, memory_order_release);
  if (pool->generation < UINT32_MAX) {
    ++pool->generation;
  }
  return true;
}

uint_fast32_t lf_audio_buffer_pool_outstanding(const lf_audio_buffer_pool *pool) {
  return pool == NULL ? 0U
                      : atomic_load_explicit(&pool->outstanding,
                                             memory_order_acquire);
}

uint_fast32_t lf_audio_buffer_pool_callbacks_in_flight(
    const lf_audio_buffer_pool *pool) {
  return pool == NULL ? 0U
                      : atomic_load_explicit(&pool->callbacks_in_flight,
                                             memory_order_acquire);
}

uint_fast32_t lf_audio_buffer_pool_callbacks_pending(
    const lf_audio_buffer_pool *pool) {
  return pool == NULL ? 0U
                      : atomic_load_explicit(&pool->callbacks_pending,
                                             memory_order_acquire);
}

uint_fast64_t lf_audio_buffer_pool_dropped_packets(
    const lf_audio_buffer_pool *pool) {
  return pool == NULL ? 0U
                      : atomic_load_explicit(&pool->dropped_packets,
                                             memory_order_relaxed);
}

uint_fast64_t lf_audio_buffer_pool_data_played_back(
    const lf_audio_buffer_pool *pool) {
  return pool == NULL ? 0U
                      : atomic_load_explicit(&pool->data_played_back,
                                             memory_order_relaxed);
}

size_t lf_audio_buffer_pool_callback_atomic_count(void) {
  return LF_AUDIO_BUFFER_POOL_CAPACITY + 5U;
}

bool lf_audio_buffer_pool_callback_atomic_is_lock_free(
    const lf_audio_buffer_pool *pool, size_t index) {
  if (pool == NULL) {
    return false;
  }
  if (index < LF_AUDIO_BUFFER_POOL_CAPACITY) {
    return atomic_is_lock_free(&pool->slots[index].active_token);
  }
  switch (index - LF_AUDIO_BUFFER_POOL_CAPACITY) {
    case 0U:
      return atomic_is_lock_free(&pool->outstanding);
    case 1U:
      return atomic_is_lock_free(&pool->data_played_back);
    case 2U:
      return atomic_is_lock_free(&pool->callbacks_in_flight);
    case 3U:
      return atomic_is_lock_free(&pool->callbacks_pending);
    case 4U:
      return atomic_is_lock_free(&pool->callbacks_enabled);
    default:
      return false;
  }
}
