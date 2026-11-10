/* SPDX-License-Identifier: MIT */
#import "LFHost.h"
#import "LFInputState.h"

#include "muhtari_oracle.h"

#include <stdio.h>
#include <stdlib.h>

typedef struct {
  unsigned short keyCode;
  NSString *characters;
  uint32_t bit;
} LFNativeKey;

typedef struct {
  uint32_t buttons;
  uint8_t color;
} LFInputOracleCase;

static const LFNativeKey kKeys[] = {
    {126U, @"\uF700", UINT32_C(0x0010)},
    {125U, @"\uF701", UINT32_C(0x0020)},
    {123U, @"\uF702", UINT32_C(0x0040)},
    {124U, @"\uF703", UINT32_C(0x0080)},
    {49U, @" ", UINT32_C(0x0001)},
    {3U, @"f", UINT32_C(0x0100)},
    {13U, @"w", UINT32_C(0x1000)},
    {1U, @"s", UINT32_C(0x2000)},
    {0U, @"a", UINT32_C(0x4000)},
    {2U, @"d", UINT32_C(0x8000)},
};

static const LFInputOracleCase kCases[] = {
    {UINT32_C(0x1000), LF_MUHTARI_ORACLE_PORT1_UP_COLOR},
    {UINT32_C(0x0000), LF_MUHTARI_ORACLE_RELEASED_COLOR},
    {UINT32_C(0x2000), LF_MUHTARI_ORACLE_PORT1_DOWN_COLOR},
    {UINT32_C(0x4000), LF_MUHTARI_ORACLE_PORT1_LEFT_COLOR},
    {UINT32_C(0x8000), LF_MUHTARI_ORACLE_PORT1_RIGHT_COLOR},
    {UINT32_C(0x0100), LF_MUHTARI_ORACLE_PORT1_FIRE_COLOR},
    {UINT32_C(0x0010), LF_MUHTARI_ORACLE_PORT0_UP_COLOR},
    {UINT32_C(0x0020), LF_MUHTARI_ORACLE_PORT0_DOWN_COLOR},
    {UINT32_C(0x0040), LF_MUHTARI_ORACLE_PORT0_LEFT_COLOR},
    {UINT32_C(0x0080), LF_MUHTARI_ORACLE_PORT0_RIGHT_COLOR},
    {UINT32_C(0x0001), LF_MUHTARI_ORACLE_PORT0_FIRE_COLOR},
    {UINT32_C(0x0101), LF_MUHTARI_ORACLE_BOTH_FIRE_COLOR},
    {UINT32_C(0x2010), LF_MUHTARI_ORACLE_PORT0_UP_COLOR},
    {UINT32_C(0x2010), LF_MUHTARI_ORACLE_PORT0_UP_COLOR},
    {UINT32_C(0x8000), LF_MUHTARI_ORACLE_PORT1_RIGHT_COLOR},
};

static NSEvent *keyboard_event(NSEventType type, unsigned short keyCode,
                               NSString *characters, BOOL repeated) {
  return [NSEvent keyEventWithType:type
                           location:NSZeroPoint
                      modifierFlags:0
                          timestamp:0.0
                       windowNumber:0
                            context:nil
                         characters:characters
        charactersIgnoringModifiers:characters
                          isARepeat:repeated
                            keyCode:keyCode];
}

static void send_key(LFInputView *view, const LFNativeKey *key, BOOL pressed,
                     BOOL repeated) {
  NSEvent *event = keyboard_event(pressed ? NSEventTypeKeyDown
                                          : NSEventTypeKeyUp,
                                  key->keyCode, key->characters, repeated);
  if (pressed) {
    [view keyDown:event];
  } else {
    [view keyUp:event];
  }
}

static void transition_to_mask(LFInputView *view, uint32_t previous,
                               uint32_t next) {
  for (NSUInteger index = 0U; index < sizeof(kKeys) / sizeof(kKeys[0]);
       ++index) {
    const BOOL wasPressed = (previous & kKeys[index].bit) != 0U;
    const BOOL isPressed = (next & kKeys[index].bit) != 0U;
    if (wasPressed && !isPressed) {
      send_key(view, &kKeys[index], NO, NO);
    }
  }
  for (NSUInteger index = 0U; index < sizeof(kKeys) / sizeof(kKeys[0]);
       ++index) {
    const BOOL wasPressed = (previous & kKeys[index].bit) != 0U;
    const BOOL isPressed = (next & kKeys[index].bit) != 0U;
    if (!wasPressed && isPressed) {
      send_key(view, &kKeys[index], YES, NO);
    }
  }
}

static BOOL run_loop_until(BOOL (^finished)(void), NSTimeInterval timeout) {
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  while (!finished()) {
    if ([deadline timeIntervalSinceNow] <= 0.0) {
      return NO;
    }
    (void)[[NSRunLoop currentRunLoop]
        runMode:NSDefaultRunLoopMode
     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
  }
  return YES;
}

static BOOL semaphore_completed_now(dispatch_semaphore_t semaphore) {
  return dispatch_semaphore_wait(semaphore, DISPATCH_TIME_NOW) == 0 ? YES : NO;
}

static int fail(const char *message) {
  (void)fprintf(stderr, "host_input_session: %s failed\n", message);
  return EXIT_FAILURE;
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc != 2 || argv[1] == NULL || argv[1][0] == '\0') {
      return fail("fixture argument");
    }
    (void)[NSApplication sharedApplication];

    dispatch_semaphore_t firstAdvanceEntered = dispatch_semaphore_create(0);
    dispatch_semaphore_t releaseFirstAdvance = dispatch_semaphore_create(0);
    dispatch_semaphore_t secondAdvanceEntered = dispatch_semaphore_create(0);
    dispatch_semaphore_t releaseSecondAdvance = dispatch_semaphore_create(0);
    dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
    __block LFHostSession *session = nil;
    __block LFInputState *state = nil;
    __block LFInputView *view = nil;
    __block uint32_t currentMask = 0U;
    __block NSUInteger frameCount = 0U;
    __block NSUInteger advanceCount = 0U;
    __block NSUInteger advanceStartedCount = 0U;
    __block NSUInteger inputSampleCount = 0U;
    __block NSUInteger mainSentinelCount = 0U;
    NSMutableData *sampledMaskBytes = [NSMutableData
        dataWithLength:(sizeof(kCases) / sizeof(kCases[0]) + 1U) *
                      sizeof(uint32_t)];
    __block uint32_t mostRecentSample = 0U;
    __block NSUInteger callOrderStage = 0U;
    __block BOOL callOrderPassed = YES;
    __block BOOL barrierTimedOut = NO;
    __block BOOL callbackFailed = NO;
    __block BOOL opened = NO;
    __block BOOL steadyStarted = NO;
    __block BOOL pcmOraclePassed = YES;
    __block BOOL pcmStorageValid = YES;

    LFHostSessionObserver observer = ^(LFHostSessionEvent event,
                                       LFHostFrame *frame,
                                       NSData *audioSamples,
                                       NSUInteger audioCapacitySamples,
                                       uint32_t inputButtons) {
      if (event == LFHostSessionEventAdvanceStarted) {
        ++advanceStartedCount;
        if (callOrderStage != 0U) {
          callOrderPassed = NO;
        }
        callOrderStage = 1U;
        if (advanceStartedCount == 2U) {
          dispatch_semaphore_signal(firstAdvanceEntered);
          const dispatch_time_t limit =
              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5U * NSEC_PER_SEC));
          if (dispatch_semaphore_wait(releaseFirstAdvance, limit) != 0) {
            barrierTimedOut = YES;
          }
        } else if (advanceStartedCount == 3U) {
          dispatch_semaphore_signal(secondAdvanceEntered);
          const dispatch_time_t limit =
              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5U * NSEC_PER_SEC));
          if (dispatch_semaphore_wait(releaseSecondAdvance, limit) != 0) {
            barrierTimedOut = YES;
          }
        }
        return;
      }
      if (event == LFHostSessionEventInputSampled) {
        uint32_t expectedMask = UINT32_MAX;
        if (inputSampleCount == 0U) {
          expectedMask = UINT32_C(0x0001);
        } else if (inputSampleCount <= sizeof(kCases) / sizeof(kCases[0])) {
          expectedMask = kCases[inputSampleCount - 1U].buttons;
        }
        if (callOrderStage != 1U ||
            inputSampleCount > sizeof(kCases) / sizeof(kCases[0]) ||
            inputButtons != expectedMask) {
          callOrderPassed = NO;
        }
        if (inputSampleCount <= sizeof(kCases) / sizeof(kCases[0])) {
          uint32_t *sampledMasks = sampledMaskBytes.mutableBytes;
          sampledMasks[inputSampleCount] = inputButtons;
        }
        ++inputSampleCount;
        mostRecentSample = inputButtons;
        callOrderStage = 2U;
        return;
      }
      if (event == LFHostSessionEventCoreAdvanceStarted) {
        if (callOrderStage != 2U || inputButtons != mostRecentSample) {
          callOrderPassed = NO;
        }
        callOrderStage = 3U;
        return;
      }
      if (event == LFHostSessionEventAdvanceFinished) {
        if (callOrderStage != 3U || inputButtons != mostRecentSample) {
          callOrderPassed = NO;
        }
        callOrderStage = 0U;
        const BOOL valid = frame != nil && audioSamples != nil &&
                           audioCapacitySamples == 801U &&
                           (audioSamples.length % sizeof(int16_t)) == 0U &&
                           audioSamples.length <=
                               audioCapacitySamples * sizeof(int16_t);
        if (!valid) {
          pcmStorageValid = NO;
          callOrderPassed = NO;
          return;
        }
        pcmOraclePassed = pcmOraclePassed &&
            (advanceCount >= LF_MUHTARI_ORACLE_FRAME_COUNT ||
             lf_muhtari_oracle_pcm_matches(
                 (const int16_t *)audioSamples.bytes,
                 audioSamples.length / sizeof(int16_t), advanceCount,
                 (char[65]){0}) != 0);
        ++advanceCount;
      }
    };

    session = [[LFHostSession alloc]
        initWithFrameHandler:^(LFHostFrame *frame) {
          const NSUInteger frameIndex = frameCount;
          ++frameCount;
          if (frameIndex > sizeof(kCases) / sizeof(kCases[0])) {
            callbackFailed = YES;
            [session stopWithCompletion:^{
              dispatch_semaphore_signal(stopped);
            }];
            return;
          }
          const NSUInteger testIndex = frameIndex == 0U ? 0U : frameIndex - 1U;
          const uint8_t expectedColor = frameIndex == 0U
              ? LF_MUHTARI_ORACLE_PORT0_FIRE_COLOR
              : kCases[testIndex].color;
          const uint32_t expectedMask = frameIndex == 0U
              ? UINT32_C(0x0001)
              : kCases[testIndex].buttons;
          const BOOL imageMatches = frameIndex == 0U
              ? lf_muhtari_oracle_first_image(
                    frame.rawIndices.bytes, 320U, expectedColor) != 0
              : lf_muhtari_oracle_steady_image(
                    frame.rawIndices.bytes, 320U, expectedColor) != 0;
          if (frame.sequence != frameIndex + 1U || !imageMatches) {
            callbackFailed = YES;
            const uint32_t *observedMasks = sampledMaskBytes.bytes;
            const uint32_t observedMask = frameIndex < inputSampleCount
                ? observedMasks[frameIndex]
                : UINT32_MAX;
            (void)fprintf(stderr,
                          "host_input_session: frame %lu sampled 0x%04x; "
                          "expected 0x%04x with color 0x%02x, first-row="
                          "%02x/%02x and next-row=%02x\n",
                          (unsigned long)frame.sequence,
                          observedMask,
                          expectedMask, expectedColor,
                          ((const uint8_t *)frame.rawIndices.bytes)
                              [224U * 320U + 64U],
                          ((const uint8_t *)frame.rawIndices.bytes)
                              [224U * 320U + 319U],
                          ((const uint8_t *)frame.rawIndices.bytes)
                              [225U * 320U]);
            [session stopWithCompletion:^{
              dispatch_semaphore_signal(stopped);
            }];
            return;
          }
          if (frameIndex == sizeof(kCases) / sizeof(kCases[0])) {
            [session stopWithCompletion:^{
              dispatch_semaphore_signal(stopped);
            }];
            return;
          }
          if (frameIndex >= 2U) {
            const NSUInteger nextTestIndex = frameIndex;
            const uint32_t nextMask = kCases[nextTestIndex].buttons;
            transition_to_mask(view, currentMask, nextMask);
            currentMask = nextMask;
          }
          if (frameIndex == 0U) {
            [session startSteadyUpdatesWithCompletion:^(BOOL success,
                                                        NSError *error) {
              (void)error;
              steadyStarted = success;
              if (!success) {
                callbackFailed = YES;
                [session stopWithCompletion:^{
                  dispatch_semaphore_signal(stopped);
                }];
              }
            }];
          }
        }
        callbackQueue:dispatch_get_main_queue()
                clock:nil
             observer:observer];
    if (session == nil) {
      return fail("session construction");
    }

    __weak LFHostSession *weakSession = session;
    state = [[LFInputState alloc] initWithButtonsHandler:^(uint32_t buttons) {
      [weakSession setInputButtons:buttons];
    }];
    view = [[LFInputView alloc] initWithFrame:NSZeroRect];
    view.inputState = state;
    [state observeWindow:nil application:NSApp];
    transition_to_mask(view, 0U, UINT32_C(0x0001));
    currentMask = UINT32_C(0x0001);

    NSString *fixturePath = [NSString stringWithUTF8String:argv[1]];
    [session openContentAtPath:fixturePath
                    completion:^(BOOL success, NSError *error) {
                      (void)error;
                      opened = success;
                    }];

    __block BOOL firstBarrierEntered = NO;
    if (!run_loop_until(^{
          if (!firstBarrierEntered &&
              semaphore_completed_now(firstAdvanceEntered)) {
            firstBarrierEntered = YES;
          }
          return (BOOL)(firstBarrierEntered || callbackFailed);
        }, 5.0) || callbackFailed) {
      [session stopWithCompletion:^{ dispatch_semaphore_signal(stopped); }];
      (void)run_loop_until(^{ return semaphore_completed_now(stopped); }, 5.0);
      return fail("first steady-frame barrier was not reached");
    }

    __block BOOL mainInputProcessed = NO;
    (void)[NSTimer
        scheduledTimerWithTimeInterval:0.001
                               repeats:NO
                                 block:^(NSTimer *timer) {
                                   (void)timer;
                                   if (![NSThread isMainThread]) {
                                     callbackFailed = YES;
                                   }
                                   transition_to_mask(view, currentMask,
                                                      kCases[0].buttons);
                                   currentMask = kCases[0].buttons;
                                   ++mainSentinelCount;
                                   mainInputProcessed = YES;
                                   dispatch_semaphore_signal(releaseFirstAdvance);
                                 }];
    if (!run_loop_until(^{ return mainInputProcessed; }, 2.0)) {
      dispatch_semaphore_signal(releaseFirstAdvance);
      [session stopWithCompletion:^{ dispatch_semaphore_signal(stopped); }];
      (void)run_loop_until(^{
        return semaphore_completed_now(stopped);
      }, 5.0);
      return fail("main-thread input sentinel did not run during the barrier");
    }

    __block BOOL secondBarrierEntered = NO;
    const BOOL secondBarrierWaited = run_loop_until(^{
          if (!secondBarrierEntered &&
              semaphore_completed_now(secondAdvanceEntered)) {
            secondBarrierEntered = YES;
          }
          return (BOOL)(secondBarrierEntered || callbackFailed);
        }, 5.0);
    if (callbackFailed) {
      (void)run_loop_until(^{ return semaphore_completed_now(stopped); }, 5.0);
      [state stopObserving];
      return fail("native input and real-core oracle sequence");
    }
    if (!secondBarrierWaited || !secondBarrierEntered) {
      dispatch_semaphore_signal(releaseSecondAdvance);
      [session stopWithCompletion:^{ dispatch_semaphore_signal(stopped); }];
      (void)run_loop_until(^{ return semaphore_completed_now(stopped); }, 5.0);
      return fail("focus-loss barrier was not reached");
    }

    __block BOOL focusSentinelProcessed = NO;
    (void)[NSTimer
        scheduledTimerWithTimeInterval:0.001
                               repeats:NO
                                 block:^(NSTimer *timer) {
                                   (void)timer;
                                   [[NSNotificationCenter defaultCenter]
                                       postNotificationName:
                                           NSApplicationDidResignActiveNotification
                                                     object:NSApp];
                                   currentMask = 0U;
                                   ++mainSentinelCount;
                                   focusSentinelProcessed = YES;
                                   dispatch_semaphore_signal(releaseSecondAdvance);
                                 }];
    if (!run_loop_until(^{ return focusSentinelProcessed; }, 2.0)) {
      dispatch_semaphore_signal(releaseSecondAdvance);
      [session stopWithCompletion:^{ dispatch_semaphore_signal(stopped); }];
      (void)run_loop_until(^{ return semaphore_completed_now(stopped); }, 5.0);
      return fail("main-thread focus-loss sentinel did not run during the barrier");
    }

    if (!run_loop_until(^{
          return semaphore_completed_now(stopped);
        }, 10.0)) {
      [session stopWithCompletion:^{ dispatch_semaphore_signal(stopped); }];
      (void)run_loop_until(^{
        return semaphore_completed_now(stopped);
      }, 5.0);
      return fail("bounded session stop");
    }
    [state stopObserving];

    BOOL sampledMasksMatch = YES;
    const uint32_t *sampledMasks = sampledMaskBytes.bytes;
    sampledMasksMatch = sampledMasks[0] == UINT32_C(0x0001);
    for (NSUInteger index = 0U; index < sizeof(kCases) / sizeof(kCases[0]);
         ++index) {
      sampledMasksMatch = sampledMasksMatch &&
                          sampledMasks[index + 1U] == kCases[index].buttons;
    }

    if (!opened || !steadyStarted || callbackFailed || barrierTimedOut ||
        mainSentinelCount != 2U ||
        frameCount != sizeof(kCases) / sizeof(kCases[0]) + 1U ||
        advanceCount != frameCount || inputSampleCount != frameCount ||
        callOrderStage != 0U || !callOrderPassed || !sampledMasksMatch ||
        !pcmStorageValid ||
        !pcmOraclePassed) {
      return fail("native input and real-core oracle sequence");
    }

    (void)printf(
        "host_input_session: samples=16 native=10 release=pass both=pass "
        "mixed=pass held=pass later-change=pass queue-barrier=pass "
        "focus-loss=pass call-order=pass main-sentinel=2 pcm=valid result=pass\n");
    return EXIT_SUCCESS;
  }
}
