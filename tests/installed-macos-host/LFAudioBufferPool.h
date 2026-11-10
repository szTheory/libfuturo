/* SPDX-License-Identifier: MIT */
#ifndef LIBFUTURO_INSTALLED_MACOS_HOST_LFAUDIOBUFFERPOOL_H
#define LIBFUTURO_INSTALLED_MACOS_HOST_LFAUDIOBUFFERPOOL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdatomic.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LF_AUDIO_BUFFER_POOL_CAPACITY 5U
#define LF_AUDIO_BUFFER_POOL_MAX_FRAMES 801U

typedef struct lf_audio_buffer_token {
  uint32_t slot;
  uint32_t generation;
  uint32_t sequence;
} lf_audio_buffer_token;

typedef struct lf_audio_buffer_pool_slot {
  atomic_uint_fast64_t active_token;
  uint32_t next_sequence;
} lf_audio_buffer_pool_slot;

/* Owner-side scheduling state is separate from callback-side atomics. */
typedef struct lf_audio_buffer_pool {
  lf_audio_buffer_pool_slot slots[LF_AUDIO_BUFFER_POOL_CAPACITY];
  atomic_uint_fast32_t outstanding;
  atomic_uint_fast64_t dropped_packets;
  atomic_uint_fast64_t data_played_back;
  atomic_uint_fast32_t callbacks_in_flight;
  atomic_uint_fast32_t callbacks_pending;
  atomic_bool callbacks_enabled;
  /* High bit closes admission; low bits count owner-side schedule leases. */
  atomic_uint_fast32_t scheduling_state;
  uint32_t generation;
  size_t next_slot;
} lf_audio_buffer_pool;

typedef enum lf_audio_buffer_claim_result {
  LF_AUDIO_BUFFER_CLAIMED = 0,
  LF_AUDIO_BUFFER_DROPPED = 1,
  LF_AUDIO_BUFFER_INVALID = 2,
  LF_AUDIO_BUFFER_DISARMED = 3
} lf_audio_buffer_claim_result;

bool lf_audio_buffer_pool_init(lf_audio_buffer_pool *pool);
bool lf_audio_buffer_pool_begin_generation(lf_audio_buffer_pool *pool);
/* Hold a lease across claim, copy, and AVFAudio submission; disarm closes the
   gate and waits until every admitted submission releases its lease. */
bool lf_audio_buffer_pool_schedule_begin(lf_audio_buffer_pool *pool);
void lf_audio_buffer_pool_schedule_end(lf_audio_buffer_pool *pool);
void lf_audio_buffer_pool_disarm(lf_audio_buffer_pool *pool);
lf_audio_buffer_claim_result lf_audio_buffer_pool_claim(
    lf_audio_buffer_pool *pool, size_t frame_count,
    lf_audio_buffer_token *token);
bool lf_audio_buffer_pool_release_unscheduled(lf_audio_buffer_pool *pool,
                                             lf_audio_buffer_token token);
bool lf_audio_buffer_pool_callback_begin(lf_audio_buffer_pool *pool);
void lf_audio_buffer_pool_callback_end(lf_audio_buffer_pool *pool);
void lf_audio_buffer_pool_callback_scheduled(lf_audio_buffer_pool *pool);
void lf_audio_buffer_pool_callback_finished(lf_audio_buffer_pool *pool);
bool lf_audio_buffer_pool_retire(lf_audio_buffer_pool *pool,
                                 lf_audio_buffer_token token,
                                 bool data_played_back);
void lf_audio_buffer_pool_disable_callbacks(lf_audio_buffer_pool *pool);
bool lf_audio_buffer_pool_reconcile_stopped(lf_audio_buffer_pool *pool);
uint_fast32_t lf_audio_buffer_pool_outstanding(const lf_audio_buffer_pool *pool);
uint_fast32_t lf_audio_buffer_pool_callbacks_in_flight(
    const lf_audio_buffer_pool *pool);
uint_fast32_t lf_audio_buffer_pool_callbacks_pending(
    const lf_audio_buffer_pool *pool);
uint_fast64_t lf_audio_buffer_pool_dropped_packets(
    const lf_audio_buffer_pool *pool);
uint_fast64_t lf_audio_buffer_pool_data_played_back(
    const lf_audio_buffer_pool *pool);
size_t lf_audio_buffer_pool_callback_atomic_count(void);
bool lf_audio_buffer_pool_callback_atomic_is_lock_free(
    const lf_audio_buffer_pool *pool, size_t index);

#ifdef __cplusplus
}
#endif

#endif
