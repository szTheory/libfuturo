/* SPDX-License-Identifier: MIT */
#import "LFAudioOutput.h"

#include "LFAudioBufferPool.h"

#include <math.h>
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef enum {
  LFHostAudioCallbackRetirePool = 0,
  LFHostAudioCallbackCallGuest = 1,
  LFHostAudioCallbackStopPlayer = 2
} LFHostAudioCallbackAction;

typedef struct {
  lf_audio_buffer_pool *pool;
  lf_audio_buffer_token token;
  BOOL firstRetirement;
  BOOL duplicateRejected;
} LFHostAudioRetirement;

typedef struct {
  lf_audio_buffer_pool *pool;
  atomic_bool started;
  atomic_bool disarmed;
} LFHostAudioDisarm;

static BOOL callback_action_is_allowed(LFHostAudioCallbackAction action) {
  return action == LFHostAudioCallbackRetirePool;
}

static void *retire_concurrently(void *context) {
  LFHostAudioRetirement *retirement = context;
  retirement->firstRetirement = lf_audio_buffer_pool_retire(
      retirement->pool, retirement->token, true);
  retirement->duplicateRejected = !lf_audio_buffer_pool_retire(
      retirement->pool, retirement->token, true);
  return NULL;
}

static void *disarm_concurrently(void *context) {
  LFHostAudioDisarm *disarm = context;
  atomic_store_explicit(&disarm->started, true, memory_order_release);
  lf_audio_buffer_pool_disarm(disarm->pool);
  atomic_store_explicit(&disarm->disarmed, true, memory_order_release);
  return NULL;
}

static BOOL before_deadline(const struct timespec *deadline) {
  struct timespec now = {0, 0};
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
    return NO;
  }
  return now.tv_sec < deadline->tv_sec ||
         (now.tv_sec == deadline->tv_sec && now.tv_nsec < deadline->tv_nsec);
}

static int fail(const char *message) {
  (void)fprintf(stderr, "host_audio: %s failed\n", message);
  return EXIT_FAILURE;
}

static BOOL manual_fail(const char *message) {
  (void)fprintf(stderr, "host_audio: %s failed\n", message);
  return NO;
}

static BOOL run_pool_checks(void) {
  lf_audio_buffer_pool pool;
  if (!lf_audio_buffer_pool_init(&pool)) {
    return NO;
  }
  const size_t atomicCount = lf_audio_buffer_pool_callback_atomic_count();
  if (atomicCount != LF_AUDIO_BUFFER_POOL_CAPACITY + 5U) {
    return NO;
  }
  for (size_t index = 0U; index < atomicCount; ++index) {
    if (!lf_audio_buffer_pool_callback_atomic_is_lock_free(&pool, index)) {
      return NO;
    }
  }

  const size_t frameCounts[] = {54U, 800U, 801U};
  for (size_t index = 0U;
       index < sizeof(frameCounts) / sizeof(frameCounts[0]); ++index) {
    lf_audio_buffer_token token = {0U, 0U, 0U};
    if (lf_audio_buffer_pool_claim(&pool, frameCounts[index], &token) !=
            LF_AUDIO_BUFFER_CLAIMED ||
        frameCounts[index] * sizeof(int16_t) >
            LF_AUDIO_BUFFER_POOL_MAX_FRAMES * sizeof(int16_t) ||
        !lf_audio_buffer_pool_release_unscheduled(&pool, token)) {
      return NO;
    }
  }
  lf_audio_buffer_token invalid = {0U, 0U, 0U};
  if (lf_audio_buffer_pool_claim(&pool, 0U, &invalid) !=
          LF_AUDIO_BUFFER_INVALID ||
      lf_audio_buffer_pool_claim(&pool, 802U, &invalid) !=
          LF_AUDIO_BUFFER_INVALID ||
      LF_AUDIO_BUFFER_POOL_MAX_FRAMES > SIZE_MAX / sizeof(int16_t)) {
    return NO;
  }

  lf_audio_buffer_token tokens[LF_AUDIO_BUFFER_POOL_CAPACITY];
  for (size_t index = 0U; index < LF_AUDIO_BUFFER_POOL_CAPACITY; ++index) {
    if (lf_audio_buffer_pool_claim(&pool, LF_AUDIO_BUFFER_POOL_MAX_FRAMES,
                                   &tokens[index]) != LF_AUDIO_BUFFER_CLAIMED) {
      return NO;
    }
  }
  if (lf_audio_buffer_pool_claim(&pool, 54U, &invalid) !=
          LF_AUDIO_BUFFER_DROPPED ||
      lf_audio_buffer_pool_dropped_packets(&pool) != 1U) {
    return NO;
  }

  for (size_t reverse = LF_AUDIO_BUFFER_POOL_CAPACITY; reverse > 0U;
       --reverse) {
    const size_t index = reverse - 1U;
    if (!lf_audio_buffer_pool_retire(&pool, tokens[index], false) ||
        lf_audio_buffer_pool_retire(&pool, tokens[index], false)) {
      return NO;
    }
  }
  if (lf_audio_buffer_pool_outstanding(&pool) != 0U) {
    return NO;
  }

  LFHostAudioRetirement retirements[LF_AUDIO_BUFFER_POOL_CAPACITY] = {0};
  pthread_t threads[LF_AUDIO_BUFFER_POOL_CAPACITY];
  size_t startedThreads = 0U;
  for (size_t index = 0U; index < LF_AUDIO_BUFFER_POOL_CAPACITY; ++index) {
    if (lf_audio_buffer_pool_claim(&pool, LF_AUDIO_BUFFER_POOL_MAX_FRAMES,
                                   &tokens[index]) != LF_AUDIO_BUFFER_CLAIMED) {
      return NO;
    }
    retirements[index].pool = &pool;
    retirements[index].token = tokens[index];
    if (pthread_create(&threads[index], NULL, retire_concurrently,
                       &retirements[index]) != 0) {
      for (size_t joined = 0U; joined < startedThreads; ++joined) {
        (void)pthread_join(threads[joined], NULL);
      }
      return NO;
    }
    ++startedThreads;
  }
  for (size_t index = 0U; index < LF_AUDIO_BUFFER_POOL_CAPACITY; ++index) {
    if (pthread_join(threads[index], NULL) != 0 ||
        !retirements[index].firstRetirement ||
        !retirements[index].duplicateRejected) {
      return NO;
    }
  }
  if (lf_audio_buffer_pool_outstanding(&pool) != 0U ||
      lf_audio_buffer_pool_data_played_back(&pool) !=
          LF_AUDIO_BUFFER_POOL_CAPACITY) {
    return NO;
  }

  const lf_audio_buffer_token stale = tokens[0];
  if (!lf_audio_buffer_pool_begin_generation(&pool)) {
    return NO;
  }
  lf_audio_buffer_token current = {0U, 0U, 0U};
  if (lf_audio_buffer_pool_claim(&pool, 54U, &current) !=
          LF_AUDIO_BUFFER_CLAIMED ||
      current.generation == stale.generation ||
      lf_audio_buffer_pool_retire(&pool, stale, true) ||
      lf_audio_buffer_pool_outstanding(&pool) != 1U ||
      !lf_audio_buffer_pool_retire(&pool, current, false) ||
      lf_audio_buffer_pool_dropped_packets(&pool) != 0U) {
    return NO;
  }

  if (!lf_audio_buffer_pool_schedule_begin(&pool)) {
    return NO;
  }
  LFHostAudioDisarm disarm = {.pool = &pool};
  atomic_init(&disarm.started, false);
  atomic_init(&disarm.disarmed, false);
  pthread_t disarmThread;
  if (pthread_create(&disarmThread, NULL, disarm_concurrently, &disarm) != 0) {
    lf_audio_buffer_pool_schedule_end(&pool);
    return NO;
  }
  struct timespec deadline = {0, 0};
  BOOL hasDeadline = clock_gettime(CLOCK_MONOTONIC, &deadline) == 0 ? YES : NO;
  if (hasDeadline) {
    deadline.tv_sec += 10;
  }
  while (!atomic_load_explicit(&disarm.started, memory_order_acquire) &&
         hasDeadline && before_deadline(&deadline)) {
    (void)sched_yield();
  }
  BOOL admissionClosed = NO;
  while (hasDeadline && before_deadline(&deadline)) {
    if (!lf_audio_buffer_pool_schedule_begin(&pool)) {
      admissionClosed = YES;
      break;
    }
    lf_audio_buffer_pool_schedule_end(&pool);
    (void)sched_yield();
  }
  const BOOL returnedBeforeLeaseEnded =
      atomic_load_explicit(&disarm.disarmed, memory_order_acquire) ? YES : NO;
  lf_audio_buffer_pool_schedule_end(&pool);
  const int joinStatus = pthread_join(disarmThread, NULL);
  if (!admissionClosed || returnedBeforeLeaseEnded || joinStatus != 0 ||
      !atomic_load_explicit(&disarm.disarmed, memory_order_acquire) ||
      lf_audio_buffer_pool_schedule_begin(&pool) ||
      lf_audio_buffer_pool_claim(&pool, 54U, &invalid) !=
          LF_AUDIO_BUFFER_DISARMED) {
    return NO;
  }
  return YES;
}

static BOOL run_manual_render_checks(void) {
  LFAudioLockFreeCheckOverride rejectOneAtomic =
      ^BOOL(NSUInteger index, BOOL actualLockFree) {
        return index == 0U ? NO : actualLockFree;
      };
  LFAudioOutput *rejected = [[LFAudioOutput alloc]
      initWithManualRendering:YES
      requirePlaybackEvidence:YES
      lockFreeCheckOverride:rejectOneAtomic];
  if (rejected == nil || [rejected startManualRendering] ||
      rejected.evidence.lockFree) {
    return manual_fail("lock-free startup rejection");
  }
  (void)[rejected stop];

  LFAudioOutput *output = [[LFAudioOutput alloc]
      initWithManualRendering:YES
      requirePlaybackEvidence:NO
      lockFreeCheckOverride:nil];
  AVAudioFormat *sourceFormat = output.sourceFormat;
  AVAudioFormat *renderFormat = output.manualRenderingFormat;
  if (output == nil || sourceFormat == nil || renderFormat == nil ||
      sourceFormat.commonFormat != AVAudioPCMFormatInt16 ||
      sourceFormat.channelCount != 1U || sourceFormat.sampleRate != 48000.0 ||
      !sourceFormat.isInterleaved ||
      renderFormat.commonFormat != AVAudioPCMFormatFloat32 ||
      renderFormat.channelCount != 1U || renderFormat.sampleRate != 48000.0 ||
      renderFormat.isInterleaved) {
    return manual_fail("source format");
  }

  int16_t first[54];
  int16_t second[800];
  int16_t third[801];
  for (size_t index = 0U; index < 54U; ++index) {
    first[index] = INT16_C(1200);
  }
  for (size_t index = 0U; index < 800U; ++index) {
    second[index] = INT16_C(2400);
  }
  for (size_t index = 0U; index < 801U; ++index) {
    third[index] = INT16_C(3600);
  }
  if (![output scheduleSamples:first count:54U] ||
      ![output scheduleSamples:second count:800U] ||
      ![output scheduleSamples:third count:801U] ||
      ![output startManualRendering]) {
    return manual_fail("schedule and start");
  }

  AVAudioPCMBuffer *rendered = [[AVAudioPCMBuffer alloc]
      initWithPCMFormat:renderFormat frameCapacity:801U];
  if (rendered == nil || rendered.floatChannelData == NULL ||
      rendered.floatChannelData[0] == NULL) {
    return manual_fail("manual render buffer");
  }
  const AVAudioFrameCount frameCounts[] = {54U, 800U, 801U};
  const int16_t expectedSamples[] = {INT16_C(1200), INT16_C(2400),
                                     INT16_C(3600)};
  for (size_t block = 0U; block < 3U; ++block) {
    NSError *error = nil;
    if (![output renderManualFrames:frameCounts[block]
                           toBuffer:rendered
                              error:&error] ||
        error != nil || rendered.frameLength != frameCounts[block]) {
      return manual_fail("manual render frame count");
    }
    const float expected = (float)expectedSamples[block] / 32768.0F;
    for (AVAudioFrameCount frame = 0U; frame < frameCounts[block]; ++frame) {
      if (fabsf(rendered.floatChannelData[0][frame] - expected) > 0.000001F) {
        return manual_fail("manual rendered block order or sample data");
      }
    }
  }

  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
  while ((output.evidence.outstandingBuffers != 0U ||
          output.evidence.pendingCallbacks != 0U) &&
         [deadline timeIntervalSinceNow] > 0.0) {
    (void)[[NSRunLoop currentRunLoop]
        runMode:NSDefaultRunLoopMode
     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
  }
  if (output.evidence.outstandingBuffers != 0U ||
      output.evidence.pendingCallbacks != 0U) {
    return manual_fail("manual render completion retirement");
  }
  if (![output stop] || !output.evidence.playerStopped ||
      !output.evidence.engineStopped ||
      !output.evidence.callbacksQuiescent) {
    return manual_fail("manual render stop postconditions");
  }

  if ([output playerStoppedPostconditionForIsPlaying:YES] ||
      ![output playerStoppedPostconditionForIsPlaying:NO] ||
      [output engineStoppedPostconditionForIsRunning:YES] ||
      ![output engineStoppedPostconditionForIsRunning:NO] ||
      callback_action_is_allowed(LFHostAudioCallbackCallGuest) ||
      callback_action_is_allowed(LFHostAudioCallbackStopPlayer) ||
      !callback_action_is_allowed(LFHostAudioCallbackRetirePool)) {
    return manual_fail("forbidden callback action controls");
  }
  return YES;
}

static BOOL render_block(LFAudioOutput *output, AVAudioPCMBuffer *rendered,
                         AVAudioFrameCount frameCount,
                         int16_t expectedSample, BOOL expectSilence) {
  NSError *error = nil;
  if (![output renderManualFrames:frameCount toBuffer:rendered error:&error] ||
      error != nil || rendered.frameLength != frameCount) {
    return NO;
  }
  const float expected = expectSilence
                             ? 0.0F
                             : (float)expectedSample / 32768.0F;
  for (AVAudioFrameCount frame = 0U; frame < frameCount; ++frame) {
    const float sample = rendered.floatChannelData[0][frame];
    if (fabsf(sample - expected) > 0.000001F) {
      (void)fprintf(stderr,
                     "host_audio: rendered output mismatch frame=%u expected=%.8f actual=%.8f silence=%d\n",
                     (unsigned int)frame, expected, sample,
                     expectSilence ? 1 : 0);
      return NO;
    }
  }
  return YES;
}

static BOOL run_manual_mute_checks(NSUInteger *transitionBlocksObserved) {
  LFAudioOutput *output = [[LFAudioOutput alloc]
      initWithManualRendering:YES
      requirePlaybackEvidence:NO
      lockFreeCheckOverride:nil];
  AVAudioFormat *format = output.manualRenderingFormat;
  if (output == nil || output.sourceFormat == nil || format == nil ||
      format.commonFormat != AVAudioPCMFormatFloat32 ||
      format.channelCount != 1U || format.sampleRate != 48000.0 ||
      format.isInterleaved) {
    return manual_fail("mute output construction");
  }

  int16_t mutedSamples[54];
  int16_t duplicateMutedSamples[800];
  int16_t restoredSamples[801];
  for (size_t index = 0U; index < 54U; ++index) {
    mutedSamples[index] = INT16_C(1200);
  }
  for (size_t index = 0U; index < 800U; ++index) {
    duplicateMutedSamples[index] = INT16_C(2400);
  }
  for (size_t index = 0U; index < 801U; ++index) {
    restoredSamples[index] = INT16_C(3600);
  }

  [output setMuted:YES];
  if (!output.muted ||
      ![output scheduleSamples:mutedSamples count:54U] ||
      ![output scheduleSamples:duplicateMutedSamples count:800U] ||
      ![output scheduleSamples:restoredSamples count:801U] ||
      ![output scheduleSamples:restoredSamples count:801U] ||
      ![output scheduleSamples:restoredSamples count:801U] ||
      ![output startManualRendering]) {
    return manual_fail("mute before manual engine start");
  }

  AVAudioPCMBuffer *rendered = [[AVAudioPCMBuffer alloc]
      initWithPCMFormat:format frameCapacity:801U];
  if (rendered == nil || rendered.floatChannelData == NULL ||
      rendered.floatChannelData[0] == NULL ||
      !render_block(output, rendered, 54U, 0, YES)) {
    return manual_fail("muted output must render silence");
  }
  [output setMuted:YES];
  if (!output.muted ||
      !render_block(output, rendered, 800U, 0, YES)) {
    return manual_fail("duplicate mute remains silent");
  }
  [output setMuted:NO];
  if (output.muted) {
    return manual_fail("unmuted output restores scheduled samples");
  }
  BOOL restoredStable = NO;
  NSUInteger transitionBlocks = 0U;
  float previousSample = 0.0F;
  const float restoredValue = (float)INT16_C(3600) / 32768.0F;
  for (NSUInteger block = 0U; block < 3U; ++block) {
    NSError *error = nil;
    if (![output renderManualFrames:801U toBuffer:rendered error:&error] ||
        error != nil || rendered.frameLength != 801U) {
      return manual_fail("restored manual render frame count");
    }
    BOOL blockStable = YES;
    for (AVAudioFrameCount frame = 0U; frame < 801U; ++frame) {
      const float sample = rendered.floatChannelData[0][frame];
      if (!isfinite(sample) || sample < 0.0F ||
          sample > restoredValue + 0.000001F || sample < previousSample) {
        return manual_fail("restored output transition bounds and order");
      }
      if (fabsf(sample - restoredValue) > 0.000001F) {
        blockStable = NO;
      }
      previousSample = sample;
    }
    if (restoredStable && !blockStable) {
      return manual_fail("restored output remains stable after transition");
    }
    if (blockStable) {
      restoredStable = YES;
    } else if (!restoredStable) {
      ++transitionBlocks;
    }
  }
  if (!restoredStable || transitionBlocks > 2U) {
    return manual_fail("restored source reaches stable output within bound");
  }
  if (transitionBlocksObserved != NULL) {
    *transitionBlocksObserved = transitionBlocks;
  }

  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
  while ((output.evidence.outstandingBuffers != 0U ||
          output.evidence.pendingCallbacks != 0U) &&
         [deadline timeIntervalSinceNow] > 0.0) {
    (void)[[NSRunLoop currentRunLoop]
        runMode:NSDefaultRunLoopMode
     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
  }
  const LFAudioOutputEvidence beforeStop = output.evidence;
  if (beforeStop.outstandingBuffers != 0U ||
      beforeStop.pendingCallbacks != 0U || beforeStop.droppedPackets != 0U ||
      ![output stop] || !output.evidence.playerStopped ||
      !output.evidence.engineStopped ||
      !output.evidence.callbacksQuiescent) {
    return manual_fail("muted packet retirement and stop postconditions");
  }
  [output setMuted:YES];
  if (output.muted) {
    return manual_fail("mute command after stop must not change output state");
  }
  return YES;
}

int main(void) {
  @autoreleasepool {
    if (!run_pool_checks()) {
      return fail("pool bounds, tokens, generation and concurrent retirement");
    }
    if (!run_manual_render_checks()) {
      return fail("manual rendering, lock-free gate or callback controls");
    }
    NSUInteger transitionBlocksObserved = 0U;
    if (!run_manual_mute_checks(&transitionBlocksObserved)) {
      return fail("manual mute silence, restore, retirement or stop");
    }
    (void)printf(
        "host_audio: pool=capacity5 frames=54,800,801 bounds=checked "
        "drop=newest tokens=duplicate,stale rejected retirement=concurrent "
        "lock-free=10/10 manual=s16-input,float32-render-mono-48000 "
        "blocks=54,800,801 order=pass "
        "mute-output=silent,restored-source "
        "restore-transition=bounded,stable-after=%lu-of-3-blocks "
        "duplicate=stable "
        "completion=retired callback=pool-only close=lease-drained "
        "forbidden-controls=guest,player-stop-rejected "
        "result=pass\n",
        (unsigned long)transitionBlocksObserved);
    return EXIT_SUCCESS;
  }
}
