/* SPDX-License-Identifier: MIT */
#import "LFHost.h"
#import "LFAudioOutput.h"

#include "LFAudioBufferPool.h"

#import <AppKit/AppKit.h>

#include "muhtari_oracle.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

@interface LFHostSession (TimingTests)
- (BOOL)enableManualTimerDeliveryForTesting;
- (BOOL)enableCatchUpFaultForTesting;
- (void)deliverTimerForTestingWithCompletion:(dispatch_block_t)completion;
- (void)readTimingStateForTesting:
    (void (^)(uint64_t nextIndex, uint64_t deadline, BOOL active))completion;
- (void)barrierOwnerForTesting:(dispatch_block_t)completion;
@end

static const uint64_t kRateNumerator = UINT64_C(39375000);
static const uint64_t kRateDenominator = UINT64_C(656711);
static const uint64_t kNanosecondsPerSecond = UINT64_C(1000000000);

typedef struct {
  NSUInteger advances;
  NSUInteger finishes;
  NSUInteger frames;
  NSUInteger destroys;
  NSUInteger buffersReleased;
  NSUInteger activeCalls;
  NSUInteger maximumActiveCalls;
  NSUInteger startSamples;
  NSUInteger startCapacity;
  NSUInteger steadySamples;
  NSUInteger steadyCapacity;
  NSUInteger callOrderErrors;
  NSUInteger eventOrder;
  NSUInteger destroyOrder;
  NSUInteger releaseOrder;
  NSUInteger completionOrder;
  NSUInteger lifecycleOrder;
  NSUInteger reservationOrder;
  NSUInteger stopOrder;
  NSUInteger advanceReturnOrder;
  NSUInteger stopCompletions;
  BOOL blockNextAdvance;
  BOOL barrierTimedOut;
} LFTimingTrace;

typedef struct {
  NSUInteger mutedAdvances;
  NSUInteger unmutedAdvances;
  uint64_t mutedSamples;
  uint64_t unmutedSamples;
  NSUInteger firstMutedSamples;
  BOOL pcmCountsValid;
  BOOL preopenMuteApplied;
  BOOL activeUnmuteApplied;
  BOOL shutdownMuteApplied;
  BOOL postStopUnmuteIgnored;
  BOOL deadlinesPreserved;
} LFAudioMuteProgress;

static BOOL reference_deadline(uint64_t origin, uint64_t index,
                               uint64_t *deadline) {
  const __uint128_t numerator = (__uint128_t)index * kRateDenominator *
                                kNanosecondsPerSecond;
  const __uint128_t quotient = numerator / kRateNumerator;
  const __uint128_t remainder = numerator % kRateNumerator;
  const __uint128_t offset = quotient + (remainder == 0U ? 0U : 1U);
  if (offset > UINT64_MAX || offset + origin > UINT64_MAX) {
    return NO;
  }
  *deadline = origin + (uint64_t)offset;
  return YES;
}

static BOOL run_loop_until(BOOL (^finished)(void), NSTimeInterval timeout) {
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  while (!finished()) {
    if ([deadline timeIntervalSinceNow] <= 0.0) {
      return NO;
    }
    (void)[[NSRunLoop currentRunLoop]
        runMode:NSDefaultRunLoopMode
     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
  }
  return YES;
}

static BOOL open_session(LFHostSession *session, NSString *path) {
  __block BOOL completed = NO;
  __block BOOL success = NO;
  [session openContentAtPath:path completion:^(BOOL opened, NSError *error) {
    (void)error;
    success = opened;
    completed = YES;
  }];
  return run_loop_until(^{ return completed; }, 5.0) && success;
}

static BOOL start_steady(LFHostSession *session) {
  __block BOOL completed = NO;
  __block BOOL success = NO;
  [session startSteadyUpdatesWithCompletion:^(BOOL started, NSError *error) {
    (void)error;
    success = started;
    completed = YES;
  }];
  return run_loop_until(^{ return completed; }, 5.0) && success;
}

static BOOL read_scheduler(LFHostSession *session, uint64_t *index,
                           uint64_t *deadline, BOOL *active) {
  __block BOOL completed = NO;
  [session readTimingStateForTesting:^(uint64_t nextIndex,
                                      uint64_t nextDeadline,
                                      BOOL isActive) {
    *index = nextIndex;
    *deadline = nextDeadline;
    *active = isActive;
    completed = YES;
  }];
  return run_loop_until(^{ return completed; }, 2.0);
}

static BOOL set_audio_muted_and_wait(LFHostSession *session,
                                     LFAudioOutput *audioOutput,
                                     BOOL muted) {
  __block BOOL completed = NO;
  __block BOOL applied = NO;
  [session setAudioMuted:muted];
  [session barrierOwnerForTesting:^{
    applied = audioOutput.isMuted == muted;
    completed = YES;
  }];
  return run_loop_until(^{ return completed; }, 2.0) && applied;
}

static BOOL scheduler_advanced_after(LFHostSession *session,
                                     uint64_t origin,
                                     uint64_t handledIndex) {
  uint64_t nextIndex = 0U;
  uint64_t actualDeadline = 0U;
  uint64_t expectedDeadline = 0U;
  BOOL active = NO;
  return reference_deadline(origin, handledIndex + 1U, &expectedDeadline) &&
         read_scheduler(session, &nextIndex, &actualDeadline, &active) &&
         active && nextIndex == handledIndex + 1U &&
         actualDeadline == expectedDeadline;
}

static BOOL fire_timer(LFHostSession *session, NSUInteger *completedCount) {
  __block BOOL completed = NO;
  [session deliverTimerForTestingWithCompletion:^{
    if (completedCount != NULL) {
      ++*completedCount;
    }
    completed = YES;
  }];
  return run_loop_until(^{ return completed; }, 5.0);
}

static BOOL close_session(LFHostSession *session, NSObject *traceLock,
                          LFTimingTrace *trace) {
  __block BOOL completed = NO;
  [session stopWithCompletion:^{
    @synchronized(traceLock) {
      trace->completionOrder = ++trace->eventOrder;
    }
    completed = YES;
  }];
  return run_loop_until(^{ return completed; }, 5.0);
}

static BOOL run_audio_close_history(NSString *fixturePath,
                                    LFAudioMuteProgress *muteProgress) {
  NSObject *clockLock = [[NSObject alloc] init];
  NSObject *traceLock = [[NSObject alloc] init];
  __block uint64_t fakeNow = UINT64_C(4000000000);
  __block NSUInteger advances = 0U;
  __block NSUInteger stopCompletions = 0U;
  __block NSUInteger destroys = 0U;
  __block NSUInteger releases = 0U;
  __block NSUInteger lifecycleOrder = 0U;
  __block NSUInteger reservationOrder = 0U;
  __block NSUInteger stopOrder = 0U;
  __block NSUInteger returnOrder = 0U;
  __block NSUInteger destroyOrder = 0U;
  __block NSUInteger releaseOrder = 0U;
  __block NSUInteger completionOrder = 0U;
  __block BOOL barrierTimedOut = NO;
  __block BOOL audioStoppedBeforeDestroy = NO;
  __block BOOL blockNextCoreAdvance = NO;
  __block LFAudioMuteProgress progress = {.pcmCountsValid = YES,
                                           .deadlinesPreserved = YES};
  dispatch_semaphore_t entered = dispatch_semaphore_create(0);
  dispatch_semaphore_t releaseAdvance = dispatch_semaphore_create(0);
  __block LFAudioOutput *audioOutput = [[LFAudioOutput alloc]
      initWithManualRendering:YES
      requirePlaybackEvidence:NO
      lockFreeCheckOverride:nil];
  LFHostClock clock = ^uint64_t{
    @synchronized(clockLock) {
      return fakeNow;
    }
  };
  LFHostSessionObserver observer = ^(LFHostSessionEvent event,
                                     LFHostFrame *frame,
                                     NSData *audioSamples,
                                     NSUInteger audioCapacity,
                                     uint32_t inputButtons) {
    (void)inputButtons;
    if (event == LFHostSessionEventAdvanceStarted) {
      @synchronized(traceLock) {
        ++advances;
        if (advances == 6U) {
          reservationOrder = ++lifecycleOrder;
          blockNextCoreAdvance = YES;
        }
      }
    } else if (event == LFHostSessionEventCoreAdvanceStarted) {
      BOOL shouldBlock = NO;
      @synchronized(traceLock) {
        shouldBlock = blockNextCoreAdvance;
        blockNextCoreAdvance = NO;
      }
      if (shouldBlock) {
        dispatch_semaphore_signal(entered);
        const dispatch_time_t limit = dispatch_time(
            DISPATCH_TIME_NOW, (int64_t)(5U * NSEC_PER_SEC));
        if (dispatch_semaphore_wait(releaseAdvance, limit) != 0) {
          @synchronized(traceLock) {
            barrierTimedOut = YES;
          }
        }
      }
    } else if (event == LFHostSessionEventAdvanceFinished) {
      @synchronized(traceLock) {
        returnOrder = ++lifecycleOrder;
        if (frame != nil) {
          const NSUInteger sampleCount = frame.audioProducedSamples;
          if (sampleCount == 0U || audioSamples == nil ||
              audioSamples.length != sampleCount * sizeof(int16_t) ||
              audioCapacity < sampleCount) {
            progress.pcmCountsValid = NO;
          }
          if (audioOutput.isMuted) {
            if (frame.sequence == 1U) {
              progress.firstMutedSamples = sampleCount;
            }
            ++progress.mutedAdvances;
            progress.mutedSamples += sampleCount;
          } else {
            ++progress.unmutedAdvances;
            progress.unmutedSamples += sampleCount;
          }
        }
      }
    } else if (event == LFHostSessionEventInstanceDestroyed) {
      const LFAudioOutputEvidence evidence = audioOutput.evidence;
      @synchronized(traceLock) {
        ++destroys;
        destroyOrder = ++lifecycleOrder;
        audioStoppedBeforeDestroy = evidence.playerStopped &&
                                    evidence.engineStopped &&
                                    evidence.callbacksQuiescent &&
                                    evidence.outstandingBuffers == 0U &&
                                    evidence.pendingCallbacks == 0U;
      }
    } else if (event == LFHostSessionEventOutputBuffersReleased) {
      @synchronized(traceLock) {
        ++releases;
        releaseOrder = ++lifecycleOrder;
      }
    }
  };
  LFHostSession *session = [[LFHostSession alloc]
      initWithFrameHandler:^(LFHostFrame *frame) { (void)frame; }
        callbackQueue:dispatch_get_main_queue()
                clock:clock
             observer:observer
       outputAllocator:nil
             audioOutput:audioOutput];
  if (session == nil || audioOutput == nil ||
      ![session enableManualTimerDeliveryForTesting] ||
      !set_audio_muted_and_wait(session, audioOutput, YES)) {
    dispatch_semaphore_signal(releaseAdvance);
    [session stopWithCompletion:nil];
    return NO;
  }
  progress.preopenMuteApplied = audioOutput.isMuted;
  if (!progress.preopenMuteApplied ||
      !open_session(session, fixturePath) ||
      !set_audio_muted_and_wait(session, audioOutput, YES) ||
      ![audioOutput startManualRendering] || !start_steady(session)) {
    dispatch_semaphore_signal(releaseAdvance);
    [session stopWithCompletion:nil];
    return NO;
  }

  for (uint64_t index = 1U; index <= 4U; ++index) {
    if (index == 3U) {
      progress.activeUnmuteApplied =
          set_audio_muted_and_wait(session, audioOutput, NO);
      if (!progress.activeUnmuteApplied) {
        [session stopWithCompletion:nil];
        return NO;
      }
    }
    uint64_t deadline = 0U;
    if (!reference_deadline(UINT64_C(4000000000), index, &deadline)) {
      [session stopWithCompletion:nil];
      return NO;
    }
    @synchronized(clockLock) {
      fakeNow = deadline;
    }
    if (!fire_timer(session, NULL)) {
      [session stopWithCompletion:nil];
      return NO;
    }
    progress.deadlinesPreserved =
        progress.deadlinesPreserved &&
        scheduler_advanced_after(session, UINT64_C(4000000000), index);
    if (!progress.deadlinesPreserved) {
      [session stopWithCompletion:nil];
      return NO;
    }
  }
  progress.shutdownMuteApplied =
      set_audio_muted_and_wait(session, audioOutput, YES);
  if (!progress.shutdownMuteApplied) {
    [session stopWithCompletion:nil];
    return NO;
  }
  if (audioOutput.evidence.outstandingBuffers !=
          LF_AUDIO_BUFFER_POOL_CAPACITY ||
      audioOutput.evidence.pendingCallbacks != LF_AUDIO_BUFFER_POOL_CAPACITY) {
    [session stopWithCompletion:nil];
    return NO;
  }

  uint64_t sixthDeadline = 0U;
  if (!reference_deadline(UINT64_C(4000000000), 5U, &sixthDeadline)) {
    [session stopWithCompletion:nil];
    return NO;
  }
  @synchronized(clockLock) {
    fakeNow = sixthDeadline;
  }
  __block BOOL reservedDeliveryDone = NO;
  [session deliverTimerForTestingWithCompletion:^{
    reservedDeliveryDone = YES;
  }];
  const dispatch_time_t barrierLimit =
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5U * NSEC_PER_SEC));
  if (dispatch_semaphore_wait(entered, barrierLimit) != 0) {
    dispatch_semaphore_signal(releaseAdvance);
    [session stopWithCompletion:nil];
    return NO;
  }

  __block BOOL stopCompleted = NO;
  [session stopWithCompletion:^{
    @synchronized(traceLock) {
      ++stopCompletions;
      completionOrder = ++lifecycleOrder;
    }
    stopCompleted = YES;
  }];
  [session setAudioMuted:NO];
  __block BOOL postStopMutationChecked = NO;
  [session barrierOwnerForTesting:^{
    progress.postStopUnmuteIgnored =
        audioOutput.isMuted && audioOutput.evidence.playerStopped &&
        audioOutput.evidence.engineStopped;
    postStopMutationChecked = YES;
  }];
  @synchronized(traceLock) { stopOrder = ++lifecycleOrder; }
  int16_t rejectedSample = INT16_C(1234);
  const BOOL newScheduleRejected =
      ![audioOutput scheduleSamples:&rejectedSample count:1U];
  const BOOL pendingStateRetained =
      audioOutput.evidence.outstandingBuffers ==
          LF_AUDIO_BUFFER_POOL_CAPACITY &&
      audioOutput.evidence.pendingCallbacks == LF_AUDIO_BUFFER_POOL_CAPACITY;
  dispatch_semaphore_signal(releaseAdvance);
  const BOOL completed = run_loop_until(^{
    return (BOOL)(stopCompleted && reservedDeliveryDone &&
                  postStopMutationChecked);
  }, 5.0);
  [session stopWithCompletion:nil];
  BOOL historyPassed = NO;
  @synchronized(traceLock) {
    historyPassed = newScheduleRejected && pendingStateRetained && completed &&
                    advances == 6U && stopCompletions == 1U && destroys == 1U &&
                    releases == 1U && reservationOrder < stopOrder &&
                    stopOrder < returnOrder && returnOrder < destroyOrder &&
                    destroyOrder < releaseOrder && releaseOrder < completionOrder &&
                    audioStoppedBeforeDestroy && !barrierTimedOut &&
                    audioOutput.evidence.playerStopped &&
                    audioOutput.evidence.engineStopped &&
                    audioOutput.evidence.callbacksQuiescent &&
                    audioOutput.evidence.outstandingBuffers == 0U &&
                    audioOutput.evidence.pendingCallbacks == 0U &&
                    progress.pcmCountsValid &&
                    progress.preopenMuteApplied &&
                    progress.activeUnmuteApplied &&
                    progress.shutdownMuteApplied &&
                    progress.postStopUnmuteIgnored &&
                    progress.deadlinesPreserved &&
                    progress.firstMutedSamples == 54U &&
                    progress.mutedAdvances == 3U &&
                    progress.unmutedAdvances == 2U &&
                    progress.mutedSamples >= 54U &&
                    progress.unmutedSamples > 0U;
  }
  if (muteProgress != NULL) {
    *muteProgress = progress;
  }
  return historyPassed;
}

static int fail(const char *message) {
  (void)fprintf(stderr, "host_timing: %s failed\n", message);
  return EXIT_FAILURE;
}

static BOOL one_call_per_overdue_burst(NSUInteger before, NSUInteger after) {
  return after - before <= 1U;
}

static BOOL shutdown_history_valid(NSUInteger stopOrder,
                                   NSUInteger reservationOrder,
                                   NSUInteger advanceReturnOrder,
                                   NSUInteger destroyOrder,
                                   NSUInteger releaseOrder,
                                   NSUInteger completionOrder) {
  if (stopOrder == 0U || destroyOrder <= stopOrder ||
      releaseOrder <= destroyOrder || completionOrder <= releaseOrder) {
    return NO;
  }
  if (reservationOrder == 0U) {
    return advanceReturnOrder == 0U;
  }
  return reservationOrder < stopOrder &&
         advanceReturnOrder > stopOrder &&
         destroyOrder > advanceReturnOrder;
}

static BOOL run_stale_callback_history(NSString *fixturePath) {
  dispatch_queue_t staleQueue =
      dispatch_queue_create("org.libfuturo.host.stale-callback-test",
                            DISPATCH_QUEUE_SERIAL);
  dispatch_suspend(staleQueue);
  dispatch_semaphore_t firstAdvance = dispatch_semaphore_create(0);
  dispatch_semaphore_t firstStopped = dispatch_semaphore_create(0);
  dispatch_semaphore_t ownerBarrier = dispatch_semaphore_create(0);
  dispatch_semaphore_t callbackDrain = dispatch_semaphore_create(0);
  NSObject *stateLock = [[NSObject alloc] init];
  __block LFHostSession *oldSession = nil;
  __block LFHostSession *newSession = nil;
  __block __weak LFHostSession *weakOldSession = nil;
  __block __weak LFHostSession *weakNewSession = nil;
  __block LFHostSession *activeSession = nil;
  __block NSUInteger oldFrameCalls = 0U;
  __block NSUInteger staleOpenCompletionsDropped = 0U;
  __block NSUInteger staleOpenCompletionsApplied = 0U;
  __block NSUInteger newFrameCalls = 0U;
  __block uint64_t displayedGeneration = 0U;
  LFHostSessionObserver observer = ^(LFHostSessionEvent event,
                                     LFHostFrame *frame,
                                     NSData *audioSamples,
                                     NSUInteger audioCapacity,
                                     uint32_t inputButtons) {
    (void)frame;
    (void)audioSamples;
    (void)audioCapacity;
    (void)inputButtons;
    if (event == LFHostSessionEventAdvanceFinished) {
      dispatch_semaphore_signal(firstAdvance);
    } else if (event == LFHostSessionEventOutputBuffersReleased) {
      dispatch_semaphore_signal(firstStopped);
    }
  };
  oldSession = [[LFHostSession alloc]
      initWithFrameHandler:^(LFHostFrame *frame) {
        @synchronized(stateLock) {
          LFHostSession *callbackSession = weakOldSession;
          if (callbackSession != nil && activeSession == callbackSession &&
              frame.generation != 0U) {
            ++oldFrameCalls;
          }
        }
      }
        callbackQueue:staleQueue
                clock:nil
             observer:observer];
  weakOldSession = oldSession;
  activeSession = oldSession;
  [oldSession openContentAtPath:fixturePath
                      completion:^(BOOL success, NSError *error) {
    (void)error;
    @synchronized(stateLock) {
      LFHostSession *callbackSession = weakOldSession;
      if (callbackSession == nil || activeSession != callbackSession) {
        ++staleOpenCompletionsDropped;
      } else if (success) {
        ++staleOpenCompletionsApplied;
      }
    }
  }];
  const dispatch_time_t limit =
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5U * NSEC_PER_SEC));
  BOOL oldStarted = dispatch_semaphore_wait(firstAdvance, limit) == 0;
  if (oldStarted) {
    [oldSession barrierOwnerForTesting:^{
      dispatch_semaphore_signal(ownerBarrier);
    }];
  }
  BOOL ownerFinished = oldStarted &&
      dispatch_semaphore_wait(ownerBarrier,
                              dispatch_time(DISPATCH_TIME_NOW,
                                            (int64_t)(5U * NSEC_PER_SEC))) == 0;
  if (ownerFinished) {
    [oldSession stopWithCompletion:nil];
  }
  BOOL oldStopped = ownerFinished &&
      dispatch_semaphore_wait(firstStopped,
                              dispatch_time(DISPATCH_TIME_NOW,
                                            (int64_t)(5U * NSEC_PER_SEC))) == 0;
  BOOL newOpened = NO;
  if (oldStopped) {
    newSession = [[LFHostSession alloc]
        initWithFrameHandler:^(LFHostFrame *frame) {
          @synchronized(stateLock) {
            LFHostSession *callbackSession = weakNewSession;
            if (callbackSession != nil && activeSession == callbackSession &&
                frame.generation != 0U) {
              ++newFrameCalls;
              displayedGeneration = frame.generation;
            }
          }
        }
        callbackQueue:dispatch_get_main_queue()
                clock:nil
             observer:nil];
    weakNewSession = newSession;
    activeSession = newSession;
    newOpened = open_session(newSession, fixturePath);
  }
  dispatch_resume(staleQueue);
  dispatch_async(staleQueue, ^{
    dispatch_semaphore_signal(callbackDrain);
  });
  const BOOL callbacksDrained =
      dispatch_semaphore_wait(callbackDrain,
                              dispatch_time(DISPATCH_TIME_NOW,
                                            (int64_t)(5U * NSEC_PER_SEC))) == 0;
  __block BOOL stoppedNew = NO;
  if (newSession != nil) {
    [newSession stopWithCompletion:^{
      stoppedNew = YES;
    }];
    (void)run_loop_until(^{ return stoppedNew; }, 5.0);
  }
  if (oldSession != nil) {
    [oldSession stopWithCompletion:nil];
  }
  @synchronized(stateLock) {
    return oldStarted && ownerFinished && oldStopped && newOpened &&
           callbacksDrained && oldFrameCalls == 0U &&
           staleOpenCompletionsDropped == 1U &&
           staleOpenCompletionsApplied == 0U && newFrameCalls == 1U &&
           activeSession == newSession && newSession != nil &&
           displayedGeneration != 0U && stoppedNew;
  }
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc != 2 || argv[1] == NULL || argv[1][0] == '\0') {
      return fail("fixture argument");
    }
    (void)[NSApplication sharedApplication];

    NSObject *clockLock = [[NSObject alloc] init];
    NSObject *traceLock = [[NSObject alloc] init];
    __block uint64_t fakeNow = UINT64_C(3000000000);
    __block LFTimingTrace trace = {0};
    dispatch_semaphore_t entered = dispatch_semaphore_create(0);
    dispatch_semaphore_t release = dispatch_semaphore_create(0);
    __block LFHostSession *session = nil;

    LFHostClock clock = ^uint64_t{
      @synchronized(clockLock) {
        return fakeNow;
      }
    };
    LFHostSessionObserver observer = ^(LFHostSessionEvent event,
                                       LFHostFrame *frame,
                                       NSData *audioSamples,
                                       NSUInteger audioCapacity,
                                       uint32_t inputButtons) {
      (void)audioSamples;
      (void)inputButtons;
      BOOL shouldBlock = NO;
      @synchronized(traceLock) {
        if (event == LFHostSessionEventAdvanceStarted) {
          ++trace.advances;
          if (trace.advances == 5U) {
            trace.reservationOrder = ++trace.lifecycleOrder;
          }
          ++trace.activeCalls;
          if (trace.activeCalls > trace.maximumActiveCalls) {
            trace.maximumActiveCalls = trace.activeCalls;
          }
          if (trace.eventOrder != 0U) {
            ++trace.callOrderErrors;
          }
          trace.eventOrder = 1U;
          shouldBlock = trace.blockNextAdvance;
          trace.blockNextAdvance = NO;
        } else if (event == LFHostSessionEventInputSampled) {
          if (trace.eventOrder != 1U) {
            ++trace.callOrderErrors;
          }
          trace.eventOrder = 2U;
        } else if (event == LFHostSessionEventCoreAdvanceStarted) {
          if (trace.eventOrder != 2U) {
            ++trace.callOrderErrors;
          }
          trace.eventOrder = 3U;
        } else if (event == LFHostSessionEventAdvanceFinished) {
          if (trace.eventOrder != 3U || trace.activeCalls != 1U) {
            ++trace.callOrderErrors;
          }
          trace.activeCalls = 0U;
          ++trace.finishes;
          trace.advanceReturnOrder = ++trace.lifecycleOrder;
          trace.eventOrder = 0U;
          if (frame != nil) {
            if (frame.sequence == 1U) {
              trace.startSamples = frame.audioProducedSamples;
              trace.startCapacity = audioCapacity;
            } else {
              trace.steadySamples = frame.audioProducedSamples;
              trace.steadyCapacity = audioCapacity;
            }
          }
        } else if (event == LFHostSessionEventInstanceDestroyed) {
          ++trace.destroys;
          trace.destroyOrder = ++trace.lifecycleOrder;
        } else if (event == LFHostSessionEventOutputBuffersReleased) {
          ++trace.buffersReleased;
          trace.releaseOrder = ++trace.lifecycleOrder;
        }
      }
      if (shouldBlock) {
        dispatch_semaphore_signal(entered);
        const dispatch_time_t limit = dispatch_time(
            DISPATCH_TIME_NOW, (int64_t)(5U * NSEC_PER_SEC));
        if (dispatch_semaphore_wait(release, limit) != 0) {
          @synchronized(traceLock) {
            trace.barrierTimedOut = YES;
          }
        }
      }
    };

    session = [[LFHostSession alloc]
        initWithFrameHandler:^(LFHostFrame *frame) {
          (void)frame;
          @synchronized(traceLock) {
            ++trace.frames;
          }
        }
        callbackQueue:dispatch_get_main_queue()
                clock:clock
             observer:observer];
    if (![session enableManualTimerDeliveryForTesting]) {
      return fail("manual timer setup");
    }
    [session setInputButtons:UINT32_C(0x0001)];
    if (!open_session(session, [NSString stringWithUTF8String:argv[1]])) {
      return fail("installed core startup");
    }
    if (!start_steady(session)) {
      return fail("steady scheduler start");
    }

    uint64_t index = 0U;
    uint64_t target = 0U;
    BOOL timerActive = NO;
    if (!read_scheduler(session, &index, &target, &timerActive) ||
        !timerActive || index != 1U ||
        !reference_deadline(UINT64_C(3000000000), 1U, &target)) {
      return fail("first steady target");
    }
    uint64_t actualTarget = 0U;
    if (!read_scheduler(session, &index, &actualTarget, &timerActive) ||
        index != 1U || actualTarget != target || !timerActive) {
      return fail("first rational deadline");
    }
    @synchronized(traceLock) {
      if (trace.advances != 1U || trace.frames != 1U ||
          trace.startSamples != 54U || trace.startCapacity != 801U) {
        return fail("immediate startup interval");
      }
    }

    @synchronized(clockLock) {
      fakeNow = target - 1U;
    }
    NSUInteger deliveries = 0U;
    if (!fire_timer(session, &deliveries)) {
      return fail("deadline-minus-one delivery");
    }
    @synchronized(traceLock) {
      if (trace.advances != 1U || trace.frames != 1U) {
        return fail("early deadline must not advance");
      }
    }

    uint64_t targetEight = 0U;
    if (!reference_deadline(UINT64_C(3000000000), 8U, &targetEight)) {
      return fail("late target reference");
    }
    @synchronized(traceLock) {
      trace.blockNextAdvance = YES;
    }
    @synchronized(clockLock) {
      fakeNow = target;
    }
    __block NSUInteger queuedCompleted = 0U;
    [session deliverTimerForTestingWithCompletion:^{
      ++queuedCompleted;
    }];
    const dispatch_time_t barrierLimit =
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5U * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(entered, barrierLimit) != 0) {
      dispatch_semaphore_signal(release);
      return fail("reserved-call barrier");
    }

    __block BOOL mainSentinel = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
      mainSentinel = YES;
    });
    if (!run_loop_until(^{ return mainSentinel; }, 2.0)) {
      dispatch_semaphore_signal(release);
      return fail("main sentinel while guest call is blocked");
    }
    @synchronized(clockLock) {
      fakeNow = targetEight + 1U;
    }
    for (NSUInteger indexToQueue = 0U; indexToQueue < 3U; ++indexToQueue) {
      [session deliverTimerForTestingWithCompletion:^{
        ++queuedCompleted;
      }];
    }
    dispatch_semaphore_signal(release);
    if (!run_loop_until(^{ return (BOOL)(queuedCompleted == 4U); }, 5.0)) {
      return fail("queued timer completions");
    }

    uint64_t expectedNext = 0U;
    uint64_t expectedDeadline = 0U;
    if (!reference_deadline(UINT64_C(3000000000), 9U, &expectedDeadline) ||
        !read_scheduler(session, &index, &actualTarget, &timerActive) ||
        index != 9U || actualTarget != expectedDeadline || !timerActive) {
      return fail("overload skips to first future target");
    }
    @synchronized(traceLock) {
      if (trace.advances != 2U || trace.frames != 2U ||
          trace.maximumActiveCalls != 1U || trace.callOrderErrors != 0U ||
          trace.barrierTimedOut || trace.steadySamples != 801U ||
          trace.steadyCapacity != 801U ||
          !one_call_per_overdue_burst(1U, trace.advances)) {
        return fail("single advance after delayed guest return");
      }
    }

    @synchronized(clockLock) {
      fakeNow = targetEight + 1U;
    }
    if (!fire_timer(session, &deliveries)) {
      return fail("duplicate overdue delivery");
    }
    @synchronized(traceLock) {
      if (trace.advances != 2U) {
        return fail("duplicate overdue delivery must not catch up");
      }
    }

    uint64_t targetTen = 0U;
    if (!reference_deadline(UINT64_C(3000000000), 10U, &targetTen)) {
      return fail("next deadline reference");
    }
    @synchronized(clockLock) {
      fakeNow = expectedDeadline + 1U;
    }
    if (!fire_timer(session, &deliveries) ||
        !read_scheduler(session, &index, &actualTarget, &timerActive) ||
        index != 10U || !reference_deadline(UINT64_C(3000000000), 10U,
                                            &expectedNext) ||
        actualTarget != expectedNext || !timerActive) {
      return fail("deadline plus one advances once");
    }
    @synchronized(traceLock) {
      if (trace.advances != 3U || trace.frames != 3U) {
        return fail("deadline equality and plus-one history");
      }
    }

    uint64_t longTarget = 0U;
    uint64_t longFuture = 0U;
    if (!reference_deadline(UINT64_C(3000000000), UINT64_C(1000000000),
                            &longTarget) ||
        !reference_deadline(UINT64_C(3000000000), UINT64_C(1000000001),
                            &longFuture)) {
      return fail("long ordinal reference");
    }
    @synchronized(clockLock) {
      fakeNow = longTarget;
    }
    if (!fire_timer(session, &deliveries) ||
        !read_scheduler(session, &index, &actualTarget, &timerActive) ||
        index != UINT64_C(1000000001) || actualTarget != longFuture ||
        !timerActive) {
      return fail("long rational ordinal and no catch-up");
    }
    @synchronized(traceLock) {
      if (trace.advances != 4U || trace.frames != 4U) {
        return fail("long-late delivery performs one frame");
      }
    }

    @synchronized(traceLock) {
      trace.blockNextAdvance = YES;
    }
    @synchronized(clockLock) {
      fakeNow = longFuture;
    }
    __block BOOL reservedDeliveryDone = NO;
    [session deliverTimerForTestingWithCompletion:^{
      reservedDeliveryDone = YES;
    }];
    const dispatch_time_t closeBarrierLimit =
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5U * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(entered, closeBarrierLimit) != 0) {
      dispatch_semaphore_signal(release);
      return fail("reservation-before-stop barrier");
    }
    __block BOOL closeSentinel = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
      closeSentinel = YES;
    });
    __block NSUInteger stopCompletions = 0U;
    LFHostStopCompletion stopCompletion = ^{
      @synchronized(traceLock) {
        ++stopCompletions;
        ++trace.stopCompletions;
        trace.completionOrder = ++trace.lifecycleOrder;
      }
    };
    [session stopWithCompletion:stopCompletion];
    @synchronized(traceLock) {
      trace.stopOrder = ++trace.lifecycleOrder;
    }
    [session stopWithCompletion:stopCompletion];
    __block BOOL unreservedTimerDone = NO;
    [session deliverTimerForTestingWithCompletion:^{
      unreservedTimerDone = YES;
    }];
    if (!run_loop_until(^{ return closeSentinel; }, 2.0)) {
      dispatch_semaphore_signal(release);
      return fail("main sentinel during reserved close drain");
    }
    @synchronized(traceLock) {
      if (trace.destroys != 0U || trace.stopCompletions != 0U) {
        dispatch_semaphore_signal(release);
        return fail("reserved work must drain before destroy and completion");
      }
    }
    dispatch_semaphore_signal(release);
    if (!run_loop_until(^{
          @synchronized(traceLock) {
            return (BOOL)(stopCompletions == 2U && reservedDeliveryDone &&
                          unreservedTimerDone);
          }
        }, 5.0)) {
      return fail("duplicate close callbacks and post-stop timer delivery");
    }
    @synchronized(traceLock) {
      if (trace.destroys != 1U || trace.buffersReleased != 1U ||
          trace.destroyOrder == 0U ||
          trace.releaseOrder <= trace.destroyOrder ||
          trace.completionOrder <= trace.releaseOrder ||
          !shutdown_history_valid(trace.stopOrder, trace.reservationOrder,
                                  trace.advanceReturnOrder,
                                  trace.destroyOrder, trace.releaseOrder,
                                  trace.completionOrder) ||
          trace.stopCompletions != 2U || trace.advances != 5U ||
          trace.maximumActiveCalls != 1U || trace.barrierTimedOut) {
        return fail("destroy, buffer release and completion ordering");
      }
    }

    @synchronized(clockLock) {
      fakeNow = UINT64_MAX - UINT64_C(10);
    }
    NSObject *overflowTraceLock = [[NSObject alloc] init];
    __block NSUInteger overflowFrames = 0U;
    __block NSUInteger overflowDestroys = 0U;
    __block NSUInteger overflowBufferReleases = 0U;
    LFHostSessionObserver overflowObserver = ^(LFHostSessionEvent event,
                                               LFHostFrame *frame,
                                               NSData *audioSamples,
                                               NSUInteger audioCapacity,
                                               uint32_t inputButtons) {
      (void)frame;
      (void)audioSamples;
      (void)audioCapacity;
      (void)inputButtons;
      @synchronized(overflowTraceLock) {
        if (event == LFHostSessionEventInstanceDestroyed) {
          ++overflowDestroys;
        } else if (event == LFHostSessionEventOutputBuffersReleased) {
          ++overflowBufferReleases;
        }
      }
    };
    LFHostSession *overflowSession = [[LFHostSession alloc]
        initWithFrameHandler:^(LFHostFrame *frame) {
          (void)frame;
          @synchronized(overflowTraceLock) {
            ++overflowFrames;
          }
        }
        callbackQueue:dispatch_get_main_queue()
                clock:clock
             observer:overflowObserver];
    if (![overflowSession enableManualTimerDeliveryForTesting]) {
      return fail("overflow timer setup");
    }
    [overflowSession setInputButtons:UINT32_C(0x0001)];
    if (!open_session(overflowSession,
                      [NSString stringWithUTF8String:argv[1]])) {
      return fail("overflow session startup");
    }
    __block BOOL overflowStartCompleted = NO;
    __block BOOL overflowStartSucceeded = YES;
    [overflowSession
        startSteadyUpdatesWithCompletion:^(BOOL started, NSError *error) {
          (void)error;
          overflowStartSucceeded = started;
          overflowStartCompleted = YES;
        }];
    if (!run_loop_until(^{ return overflowStartCompleted; }, 5.0)) {
      return fail("overflow scheduler completion");
    }
    if (overflowStartSucceeded) {
      return fail("scheduler must reject overflowing first deadline");
    }
    @synchronized(overflowTraceLock) {
      if (overflowFrames != 1U || overflowDestroys != 1U ||
          overflowBufferReleases != 1U) {
        return fail("overflow cleanup after immediate startup");
      }
    }

    @synchronized(clockLock) {
      fakeNow = UINT64_C(5000000000);
    }
    NSObject *faultTraceLock = [[NSObject alloc] init];
    __block NSUInteger faultAdvances = 0U;
    __block NSUInteger faultDestroys = 0U;
    LFHostSessionObserver faultObserver = ^(LFHostSessionEvent event,
                                            LFHostFrame *frame,
                                            NSData *audioSamples,
                                            NSUInteger audioCapacity,
                                            uint32_t inputButtons) {
      (void)frame;
      (void)audioSamples;
      (void)audioCapacity;
      (void)inputButtons;
      if (event == LFHostSessionEventAdvanceStarted) {
        @synchronized(faultTraceLock) {
          ++faultAdvances;
        }
      } else if (event == LFHostSessionEventInstanceDestroyed) {
        @synchronized(faultTraceLock) {
          ++faultDestroys;
        }
      }
    };
    LFHostSession *faultSession = [[LFHostSession alloc]
        initWithFrameHandler:^(LFHostFrame *frame) {
          (void)frame;
        }
        callbackQueue:dispatch_get_main_queue()
                clock:clock
             observer:faultObserver];
    if (![faultSession enableManualTimerDeliveryForTesting] ||
        ![faultSession enableCatchUpFaultForTesting]) {
      return fail("catch-up fault setup");
    }
    [faultSession setInputButtons:UINT32_C(0x0001)];
    if (!open_session(faultSession,
                      [NSString stringWithUTF8String:argv[1]]) ||
        !start_steady(faultSession)) {
      return fail("catch-up control session startup");
    }
    uint64_t burstDeadline = 0U;
    if (!reference_deadline(UINT64_C(5000000000), 5U, &burstDeadline)) {
      return fail("catch-up control reference");
    }
    @synchronized(clockLock) {
      fakeNow = burstDeadline + 1U;
    }
    NSUInteger faultBefore = 0U;
    @synchronized(faultTraceLock) {
      faultBefore = faultAdvances;
    }
    if (!fire_timer(faultSession, NULL)) {
      return fail("catch-up control first overdue callback");
    }
    if (!fire_timer(faultSession, NULL)) {
      return fail("catch-up control duplicate overdue callback");
    }
    BOOL faultWasDetected = NO;
    @synchronized(faultTraceLock) {
      faultWasDetected =
          !one_call_per_overdue_burst(faultBefore, faultAdvances);
    }
    LFTimingTrace faultCleanupTrace = {0};
    if (!faultWasDetected ||
        !close_session(faultSession, faultTraceLock, &faultCleanupTrace)) {
      return fail("catch-up negative control must violate the shared comparator");
    }
    @synchronized(faultTraceLock) {
      if (faultDestroys != 1U) {
        return fail("catch-up control cleanup");
      }
    }
    NSUInteger faultAdvancesBeforePostStop = 0U;
    @synchronized(faultTraceLock) {
      faultAdvancesBeforePostStop = faultAdvances;
    }
    __block BOOL postStopFaultTimerDone = NO;
    [faultSession deliverTimerForTestingWithCompletion:^{
      postStopFaultTimerDone = YES;
    }];
    if (!run_loop_until(^{ return postStopFaultTimerDone; }, 2.0)) {
      return fail("post-stop timer completion");
    }
    @synchronized(faultTraceLock) {
      if (faultAdvances != faultAdvancesBeforePostStop ||
          faultDestroys != 1U) {
        return fail("stop before reservation prevents queued timer work");
      }
    }

    const BOOL noReservationOrderAccepted = shutdown_history_valid(1U, 0U,
                                                                  0U, 2U, 3U,
                                                                  4U);
    const BOOL postStopReservationRejected =
        !shutdown_history_valid(1U, 2U, 3U, 4U, 5U, 6U);
    const BOOL prematureDestroyRejected =
        !shutdown_history_valid(2U, 1U, 4U, 3U, 5U, 6U);
    if (!noReservationOrderAccepted || !postStopReservationRejected ||
        !prematureDestroyRejected) {
      return fail("shutdown wrong-order controls must fail the shared comparator");
    }

    if (!run_stale_callback_history(
            [NSString stringWithUTF8String:argv[1]])) {
      return fail("old session callbacks must not affect a later session");
    }
    LFAudioMuteProgress muteProgress = {0};
    if (!run_audio_close_history(
            [NSString stringWithUTF8String:argv[1]], &muteProgress)) {
      return fail("audio close must disarm, drain, stop and quiesce before release");
    }

    (void)printf(
        "host_timing: startup=immediate samples=54 boundary=minus-one,equal,plus-one "
        "rational=long-ordinal overload=skip duplicate=single max-inflight=1 "
        "sentinel=pass prestop=pass reserved-stop=pass duplicate-stop=pass destroy=once "
        "overflow=checked catchup-control=detected wrong-order-control=detected "
        "stale-callbacks=filtered "
        "audio-close=reserved,disarm,owner-drain,player-stop,engine-stop,quiescent "
        "audio-mute=preopen,active,shutdown,post-stop-ignored owner-queue=pass "
        "guest=continued pcm=valid muted-advances=%lu unmuted-advances=%lu deadlines=1-4 "
        "stop-controls=detected "
        "result=pass\n",
        (unsigned long)muteProgress.mutedAdvances,
        (unsigned long)muteProgress.unmutedAdvances);
    return EXIT_SUCCESS;
  }
}
