/* SPDX-License-Identifier: MIT */
#import "LFHost.h"
#import "LFContentReader.h"
#import "LFAudioOutput.h"
#if defined(LF_HOST_SESSION_TESTING)
#import "LFHostSessionTesting.h"
#endif

#include "LFHostAudioMetadata.h"
#include <libfuturo/libfuturo.h>

#include <inttypes.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

NSString *const LFHostSessionErrorDomain =
    @"org.libfuturo.installed-host.session";
NSString *const LFHostSessionCoreStatusKey = @"lf_core_status";

static NSError *lf_session_error(LFHostSessionErrorCode code,
                                 NSString *description,
                                 NSNumber *coreStatus,
                                 NSError *underlyingError) {
  NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:description
                                                                      forKey:NSLocalizedDescriptionKey];
  if (coreStatus != nil) {
    userInfo[LFHostSessionCoreStatusKey] = coreStatus;
  }
  if (underlyingError != nil) {
    userInfo[NSUnderlyingErrorKey] = underlyingError;
  }
  return [NSError errorWithDomain:LFHostSessionErrorDomain
                             code:code
                         userInfo:userInfo];
}

@implementation LFHostFrame
- (instancetype)initWithGeneration:(uint64_t)generation
                           sequence:(uint64_t)sequence
                audioProducedSamples:(NSUInteger)audioProducedSamples
                          rawIndices:(NSData *)rawIndices
                  displaySurface:(LFDisplaySurface *)displaySurface {
  self = [super init];
  if (self != nil) {
    _generation = generation;
    _sequence = sequence;
    _audioProducedSamples = audioProducedSamples;
    _rawIndices = [rawIndices copy];
    _displaySurface = displaySurface;
  }
  return self;
}
@end

static uint64_t lf_monotonic_nanoseconds(void) {
  struct timespec now = {0, 0};
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0 || now.tv_sec < 0 ||
      now.tv_nsec < 0) {
    return 0U;
  }
  return (uint64_t)now.tv_sec * UINT64_C(1000000000) + (uint64_t)now.tv_nsec;
}

static BOOL lf_deadline(uint64_t origin, uint64_t index, uint64_t *deadline) {
  const __uint128_t scaled = (__uint128_t)index * UINT64_C(656711) *
                              UINT64_C(1000000000);
  const __uint128_t offset =
      (scaled + UINT64_C(39375000) - 1U) / UINT64_C(39375000);
  if (offset > UINT64_MAX || offset + origin > UINT64_MAX) {
    return NO;
  }
  *deadline = origin + (uint64_t)offset;
  return YES;
}


@implementation LFHostSession {
  dispatch_queue_t _queue;
  dispatch_queue_t _callbackQueue;
  LFHostClock _clock;
  LFHostSessionObserver _observer;
  LFHostOutputAllocator _outputAllocator;
  LFAudioOutput *_audioOutput;
  dispatch_source_t _timer;
  lf_instance *_instance;
  lf_profile _profile;
  uint8_t *_video;
  int16_t *_audio;
  size_t _videoBytes;
  size_t _audioCapacity;
  uint64_t _generation;
  uint64_t _sequence;
  uint64_t _clockOrigin;
  uint64_t _nextDeadlineIndex;
  uint32_t _inputButtons;
  BOOL _stopping;
  BOOL _stopQueued;
  BOOL _stopFinished;
  BOOL _callReserved;
  BOOL _timerStarted;
  BOOL _manualTimerDelivery;
  BOOL _testAdvanceOneOverdueDeadline;
  uint64_t _testScheduledDeadline;
  BOOL _opening;
  BOOL _opened;
  BOOL _mainInvalidationPending;
  LFHostFrame *_latestFrame;
  NSMutableArray<LFHostStopCompletion> *_stopCompletions;
  LFContentReader *_contentReader;
#if defined(LF_HOST_SESSION_TESTING)
  LFHostSessionProfileMutation _testingProfileMutation;
  LFHostSessionResultMutation _testingResultMutation;
  BOOL _testingConfigurationSet;
#endif
}

- (instancetype)initWithFrameHandler:(LFHostFrameHandler)frameHandler {
  return [self initWithFrameHandler:frameHandler
                      callbackQueue:dispatch_get_main_queue()
                              clock:nil
                           observer:nil];
}

- (instancetype)initWithFrameHandler:(LFHostFrameHandler)frameHandler
                       callbackQueue:(dispatch_queue_t)callbackQueue
                               clock:(LFHostClock)clock
                            observer:(LFHostSessionObserver)observer {
  return [self initWithFrameHandler:frameHandler
                      callbackQueue:callbackQueue
                              clock:clock
                           observer:observer
                    outputAllocator:nil];
}

- (instancetype)initWithFrameHandler:(LFHostFrameHandler)frameHandler
                       callbackQueue:(dispatch_queue_t)callbackQueue
                               clock:(LFHostClock)clock
                            observer:(LFHostSessionObserver)observer
                     outputAllocator:(LFHostOutputAllocator)outputAllocator {
  return [self initWithFrameHandler:frameHandler
                      callbackQueue:callbackQueue
                              clock:clock
                           observer:observer
                    outputAllocator:outputAllocator
                        audioOutput:nil];
}

- (instancetype)initWithFrameHandler:(LFHostFrameHandler)frameHandler
                       callbackQueue:(dispatch_queue_t)callbackQueue
                               clock:(LFHostClock)clock
                            observer:(LFHostSessionObserver)observer
                     outputAllocator:(LFHostOutputAllocator)outputAllocator
                         audioOutput:(LFAudioOutput *)audioOutput {
  self = [super init];
  if (self != nil) {
    static uint64_t nextGeneration = 0U;
    @synchronized([LFHostSession class]) {
      _generation = ++nextGeneration;
    }
    _queue = dispatch_queue_create("org.libfuturo.host.guest", DISPATCH_QUEUE_SERIAL);
    _callbackQueue = callbackQueue != nil ? callbackQueue
                                         : dispatch_get_main_queue();
    if (clock != nil) {
      _clock = [clock copy];
    } else {
      _clock = ^uint64_t{ return lf_monotonic_nanoseconds(); };
    }
    _observer = [observer copy];
    _audioOutput = audioOutput;
    if (outputAllocator != nil) {
      _outputAllocator = [outputAllocator copy];
    } else {
      _outputAllocator = ^void *(size_t count, size_t size) {
        return calloc(count, size);
      };
    }
    _frameHandler = [frameHandler copy];
    _stopCompletions = [NSMutableArray array];
    _contentReader = [[LFContentReader alloc] init];
  }
  return self;
}

#if defined(LF_HOST_SESSION_TESTING)
- (BOOL)configureTestingBeforeOpenWithProfileMutation:
            (LFHostSessionProfileMutation)profileMutation
    resultMutation:(LFHostSessionResultMutation)resultMutation
      contentReader:(LFContentReader *)contentReader {
  @synchronized(self) {
    if (_stopping || _opening || _opened || _testingConfigurationSet) {
      return NO;
    }
    _testingConfigurationSet = YES;
    _testingProfileMutation = [profileMutation copy];
    _testingResultMutation = [resultMutation copy];
    if (contentReader != nil) {
      _contentReader = contentReader;
    }
    return YES;
  }
}

- (BOOL)armResultMutationForTesting:
    (LFHostSessionResultMutation)resultMutation {
  @synchronized(self) {
    if (resultMutation == nil || !_opened || _opening || _stopping ||
        _stopQueued || _stopFinished || !_manualTimerDelivery ||
        _timerStarted || _testingResultMutation != nil) {
      return NO;
    }
    _testingResultMutation = [resultMutation copy];
    return YES;
  }
}
#endif

- (BOOL)isStopping {
  @synchronized(self) {
    return _stopping;
  }
}

- (BOOL)reserveCoreCall {
  @synchronized(self) {
    if (_stopping || _callReserved) {
      return NO;
    }
    _callReserved = YES;
    return YES;
  }
}

- (void)releaseCoreCall {
  @synchronized(self) {
    _callReserved = NO;
  }
}

- (void)deliverOpenCompletion:(LFHostCompletion)completion
                      success:(BOOL)success
                        error:(NSError *)error {
  if (completion == nil) {
    return;
  }
  dispatch_async(_callbackQueue, ^{
    completion(success, error);
  });
}

- (BOOL)profileIsSupported:(NSString **)message {
  if (!lf_host_profile_audio_is_supported(&_profile) ||
      _profile.profile_id == NULL ||
      strcmp(_profile.profile_id, "muhtari-ntsc-v1") != 0 ||
      _profile.core_id == NULL || strcmp(_profile.core_id, "muhtari") != 0 ||
      _profile.input_mask != UINT32_C(0xF1F1) ||
      _profile.max_work_units != 1U ||
      _profile.video_format != LF_VIDEO_INDEX8 ||
      _profile.video_width != 320U || _profile.video_height != 242U ||
      _profile.max_audio_samples_per_call != 801U ||
      _profile.max_content_bytes != 1048704U ||
      _profile.frame_rate_numerator != 39375000U ||
      _profile.frame_rate_denominator != 656711U) {
    *message = @"The installed profile does not match the host's supported format.";
    return NO;
  }
  return YES;
}

- (void)setInputButtons:(uint32_t)buttons {
  @synchronized(self) {
    if (!_stopping) {
      _inputButtons = buttons;
    }
  }
}

- (void)setAudioMuted:(BOOL)muted {
  dispatch_async(_queue, ^{
    @synchronized(self) {
      if (self->_stopping || self->_stopQueued || self->_stopFinished) {
        return;
      }
      [self->_audioOutput setMuted:muted];
    }
  });
}

- (BOOL)advanceOne {
  if (_instance == NULL || ![self reserveCoreCall]) {
    return NO;
  }
  lf_run_request request = {
      .struct_size = sizeof(request),
      .work_units = 1U,
      .video_data = _video,
      .video_capacity_bytes = _videoBytes,
      .video_stride_bytes = 320U,
      .audio_data = _audio,
      .audio_capacity_samples = _audioCapacity,
  };
  lf_run_result result = {.struct_size = sizeof(result)};
  if (_observer != nil) {
    _observer(LFHostSessionEventAdvanceStarted, nil, nil, _audioCapacity, 0U);
  }
  uint32_t latestButtons = 0U;
  @synchronized(self) {
    latestButtons = _inputButtons;
  }
  lf_input input = {.struct_size = sizeof(input), .buttons = latestButtons};
  if (_observer != nil) {
    _observer(LFHostSessionEventInputSampled, nil, nil, _audioCapacity,
              latestButtons);
  }
  const lf_status inputStatus = lf_set_input(_instance, &input);
  lf_status advanceStatus = inputStatus;
  if (inputStatus == LF_OK) {
    if (_observer != nil) {
      _observer(LFHostSessionEventCoreAdvanceStarted, nil, nil,
                _audioCapacity, latestButtons);
    }
    advanceStatus = lf_advance(_instance, &request, &result);
  }
  [self releaseCoreCall];
#if defined(LF_HOST_SESSION_TESTING)
  if (inputStatus == LF_OK && advanceStatus == LF_OK) {
    LFHostSessionResultMutation mutation = nil;
    @synchronized(self) {
      mutation = _testingResultMutation;
      _testingResultMutation = nil;
    }
    if (mutation != nil) {
      mutation(&result);
    }
  }
#endif
  if (inputStatus != LF_OK || advanceStatus != LF_OK ||
      result.requested_units != 1U || result.actual_units != 1U ||
      result.overshoot_units != 0U || result.video_valid != 1U ||
      result.audio_valid != 1U || result.video_format != LF_VIDEO_INDEX8 ||
      !lf_host_result_audio_is_supported(&result) ||
      result.video_width != 320U || result.video_height != 242U ||
      result.video_stride_bytes != 320U || result.video_extent_bytes != _videoBytes ||
      result.audio_produced_samples > _audioCapacity ||
      result.core_ticks_valid != 0U || result.cumulative_core_ticks != 0U) {
    if (_observer != nil) {
      _observer(LFHostSessionEventAdvanceFinished, nil, nil, _audioCapacity,
                latestButtons);
    }
    return NO;
  }
  if (_audioOutput != nil && result.audio_produced_samples > 0U &&
      ![_audioOutput scheduleSamples:_audio
                               count:result.audio_produced_samples]) {
    if (_observer != nil) {
      _observer(LFHostSessionEventAdvanceFinished, nil, nil, _audioCapacity,
                latestButtons);
    }
    return NO;
  }
  NSData *raw = [NSData dataWithBytes:_video length:_videoBytes];
  LFDisplaySurface *displaySurface =
      [LFDisplayAdapter surfaceForRawIndices:raw
                                    rowBytes:(NSUInteger)LFDisplayWidth
                                  generation:_generation];
  if (displaySurface == nil) {
    if (_observer != nil) {
      _observer(LFHostSessionEventAdvanceFinished, nil, nil, _audioCapacity,
                latestButtons);
    }
    return NO;
  }
  LFHostFrame *frame = [[LFHostFrame alloc]
      initWithGeneration:_generation
                sequence:++_sequence
     audioProducedSamples:result.audio_produced_samples
               rawIndices:raw
          displaySurface:displaySurface];
  if (_observer != nil) {
    NSData *audioSamples = [NSData dataWithBytes:_audio
                                           length:result.audio_produced_samples * sizeof(*_audio)];
    _observer(LFHostSessionEventAdvanceFinished, frame, audioSamples,
              _audioCapacity, latestButtons);
  }
  [self publishFrame:frame];
  return YES;
}

- (void)publishFrame:(LFHostFrame *)frame {
  BOOL scheduleMain = NO;
  @synchronized(self) {
    if (_stopping) {
      return;
    }
    _latestFrame = frame;
    if (!_mainInvalidationPending) {
      _mainInvalidationPending = YES;
      scheduleMain = YES;
    }
  }
  if (!scheduleMain) {
    return;
  }
  if (_observer != nil) {
    _observer(LFHostSessionEventFrameInvalidationScheduled, frame, nil, 0U,
              0U);
  }
  dispatch_async(_callbackQueue, ^{
    LFHostFrame *latest = nil;
    @synchronized(self) {
      latest = self->_latestFrame;
      self->_latestFrame = nil;
      self->_mainInvalidationPending = NO;
      if (self->_stopping || latest.generation != self->_generation) {
        latest = nil;
      }
    }
    if (latest != nil && self.frameHandler != nil) {
      self.frameHandler(latest);
    }
  });
}

- (BOOL)enableManualTimerDeliveryForTesting {
  @synchronized(self) {
    if (_stopping || _opened || _timerStarted) {
      return NO;
    }
    _manualTimerDelivery = YES;
  }
  return YES;
}

- (BOOL)enableCatchUpFaultForTesting {
  @synchronized(self) {
    if (_stopping || _opened || _timerStarted) {
      return NO;
    }
    _testAdvanceOneOverdueDeadline = YES;
  }
  return YES;
}

- (void)deliverTimerForTestingWithCompletion:(dispatch_block_t)completion {
  dispatch_async(_queue, ^{
    [self handleTimer];
    if (completion != nil) {
      dispatch_async(self->_callbackQueue, completion);
    }
  });
}

- (void)readTimingStateForTesting:
    (void (^)(uint64_t nextIndex, uint64_t deadline, BOOL active))completion {
  dispatch_async(_queue, ^{
    const uint64_t nextIndex = self->_nextDeadlineIndex;
    const uint64_t deadline = self->_testScheduledDeadline;
    BOOL active = NO;
    @synchronized(self) {
      active = self->_timerStarted && !self->_stopping;
    }
    dispatch_async(self->_callbackQueue, ^{
      completion(nextIndex, deadline, active);
    });
  });
}

- (void)barrierOwnerForTesting:(dispatch_block_t)completion {
  dispatch_async(_queue, completion);
}

- (BOOL)startTimer {
  @synchronized(self) {
    if (_stopping || _timerStarted) {
      return NO;
    }
    _timerStarted = YES;
    if (!_manualTimerDelivery) {
      _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0U, 0U, _queue);
      if (_timer == nil) {
        _timerStarted = NO;
        return NO;
      }
      __weak LFHostSession *weakSelf = self;
      dispatch_source_set_event_handler(_timer, ^{
        [weakSelf handleTimer];
      });
      dispatch_resume(_timer);
    }
  }
  _nextDeadlineIndex = 1U;
  if (![self scheduleNextDeadline]) {
    return NO;
  }
  return YES;
}

- (BOOL)scheduleNextDeadline {
  BOOL active = NO;
  BOOL manual = NO;
  @synchronized(self) {
    active = _timerStarted && !_stopping;
    manual = _manualTimerDelivery;
  }
  if (!active) {
    return NO;
  }
  const uint64_t now = _clock();
  uint64_t deadline = 0U;
  if (!lf_deadline(_clockOrigin, _nextDeadlineIndex, &deadline)) {
    return NO;
  }
  if (deadline <= now) {
    if (_testAdvanceOneOverdueDeadline) {
      if (_nextDeadlineIndex == UINT64_MAX) {
        return NO;
      }
      ++_nextDeadlineIndex;
    } else {
      const __uint128_t elapsed =
          now >= _clockOrigin ? now - _clockOrigin : 0U;
      const __uint128_t periodDenominator =
          (__uint128_t)656711U * UINT64_C(1000000000);
      __uint128_t next = (elapsed * UINT64_C(39375000)) /
                             periodDenominator +
                         1U;
      if (next <= _nextDeadlineIndex) {
        next = (__uint128_t)_nextDeadlineIndex + 1U;
      }
      if (next > UINT64_MAX) {
        return NO;
      }
      _nextDeadlineIndex = (uint64_t)next;
    }
    if (!lf_deadline(_clockOrigin, _nextDeadlineIndex, &deadline)) {
      return NO;
    }
  }
  const uint64_t delay = deadline > now ? deadline - now : 1U;
  const int64_t boundedDelay = delay > (uint64_t)INT64_MAX
                                   ? INT64_MAX
                                   : (int64_t)delay;
  _testScheduledDeadline = deadline;
  if (manual) {
    return YES;
  }
  dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, boundedDelay),
                            DISPATCH_TIME_FOREVER, 0U);
  return YES;
}

- (void)handleTimer {
  BOOL active = NO;
  @synchronized(self) {
    active = _timerStarted && !_stopping;
  }
  if (!active) {
    return;
  }
  const uint64_t now = _clock();
  uint64_t deadline = 0U;
  if (!lf_deadline(_clockOrigin, _nextDeadlineIndex, &deadline)) {
    [self stopWithCompletion:nil];
    return;
  }
  if (now < deadline) {
    if (![self scheduleNextDeadline]) {
      [self stopWithCompletion:nil];
    }
    return;
  }
  if (![self advanceOne]) {
    [self stopWithCompletion:nil];
    return;
  }
  if (_nextDeadlineIndex < UINT64_MAX) {
    ++_nextDeadlineIndex;
  }
  if (![self scheduleNextDeadline]) {
    [self stopWithCompletion:nil];
  }
}

- (void)openContentAtPath:(NSString *)path completion:(LFHostCompletion)completion {
  BOOL canOpen = NO;
  @synchronized(self) {
    canOpen = path.length > 0U && !_stopping && !_opening && !_opened;
    if (canOpen) {
      _opening = YES;
    }
#if defined(LF_HOST_SESSION_TESTING)
    else if (path.length == 0U && !_stopping && !_opening && !_opened) {
      /* An empty-path rejection is terminal for this configuration attempt.
         Drop test callbacks here so a block that captured the session cannot
         keep the rejected session alive through a retain cycle. */
      _testingProfileMutation = nil;
      _testingResultMutation = nil;
      _testingConfigurationSet = NO;
    }
#endif
  }
  if (!canOpen) {
    [self deliverOpenCompletion:completion success:NO
                          error:lf_session_error(
                                    LFHostSessionErrorInvalidRequest,
                                    @"The selected content could not be opened.",
                                    nil, nil)];
    return;
  }
  dispatch_async(_queue, ^{
    if ([self isStopping]) {
      [self stopWithCompletion:^{
        [self deliverOpenCompletion:completion success:NO
                              error:lf_session_error(
                                        LFHostSessionErrorInvalidRequest,
                                        @"The selected content could not be opened.",
                                        nil, nil)];
      }];
      return;
    }
    self->_profile = (lf_profile){.struct_size = sizeof(self->_profile)};
    if (![self reserveCoreCall]) {
      [self stopWithCompletion:^{
        [self deliverOpenCompletion:completion success:NO
                              error:lf_session_error(
                                        LFHostSessionErrorInvalidRequest,
                                        @"The selected content could not be opened.",
                                        nil, nil)];
      }];
      return;
    }
    const lf_status profileStatus =
        lf_get_profile("muhtari-ntsc-v1", NULL, &self->_profile);
    [self releaseCoreCall];
#if defined(LF_HOST_SESSION_TESTING)
    if (profileStatus == LF_OK) {
      LFHostSessionProfileMutation mutation = nil;
      @synchronized(self) {
        mutation = self->_testingProfileMutation;
        self->_testingProfileMutation = nil;
      }
      if (mutation != nil) {
        mutation(&self->_profile);
      }
    }
#endif
    NSString *message = nil;
    if (profileStatus != LF_OK || ![self profileIsSupported:&message]) {
      if (message == nil) {
        message = @"The installed profile is unavailable.";
      }
      [self stopWithCompletion:^{
        [self deliverOpenCompletion:completion
                            success:NO
                              error:lf_session_error(
                                        LFHostSessionErrorProfile, message,
                                        @(profileStatus), nil)];
      }];
      return;
    }
    NSError *readerError = nil;
    NSData *contentBytes = [self->_contentReader
        readAtPath:path
      maximumBytes:self->_profile.max_content_bytes
             error:&readerError];
    if (contentBytes == nil) {
      [self stopWithCompletion:^{
        [self deliverOpenCompletion:completion success:NO
                              error:lf_session_error(
                                        LFHostSessionErrorReader,
                                        @"The selected content is invalid or unavailable.",
                                        nil, readerError)];
      }];
      return;
    }
    if (![self reserveCoreCall]) {
      contentBytes = nil;
      [self stopWithCompletion:^{
        [self deliverOpenCompletion:completion success:NO
                              error:lf_session_error(
                                        LFHostSessionErrorInvalidRequest,
                                        @"The selected content could not be opened.",
                                        nil, nil)];
      }];
      return;
    }
    lf_status status = lf_create("muhtari-ntsc-v1", NULL, &self->_instance);
    [self releaseCoreCall];
    if (self->_instance != NULL && self->_observer != nil) {
      self->_observer(LFHostSessionEventInstanceCreated, nil, nil, 0U, 0U);
    }
    if (status != LF_OK || self->_instance == NULL) {
      contentBytes = nil;
      [self stopWithCompletion:^{
        [self deliverOpenCompletion:completion success:NO
                              error:lf_session_error(
                                        LFHostSessionErrorCreate,
                                        @"The session could not be created.",
                                        @(status), nil)];
      }];
      return;
    }
    lf_load_request load = {
        .struct_size = sizeof(load),
        .content_data = contentBytes.bytes,
        .content_size_bytes = contentBytes.length,
        .configuration_id = NULL,
    };
    lf_load_result loaded = {.struct_size = sizeof(loaded)};
    if (![self reserveCoreCall]) {
      contentBytes = nil;
      [self stopWithCompletion:^{
        [self deliverOpenCompletion:completion success:NO
                              error:lf_session_error(
                                        LFHostSessionErrorLoad,
                                        @"The selected content could not be loaded.",
                                        nil, nil)];
      }];
      return;
    }
    if (self->_observer != nil) {
      self->_observer(LFHostSessionEventLoadStarted, nil, nil, 0U, 0U);
    }
    status = lf_load(self->_instance, &load, &loaded);
    [self releaseCoreCall];
    contentBytes = nil;
    if (self->_observer != nil) {
      self->_observer(LFHostSessionEventContentReleased, nil, nil, 0U, 0U);
      self->_observer(LFHostSessionEventLoadFinished, nil, nil, 0U, 0U);
    }
    if (status != LF_OK || loaded.loaded != 1U ||
        loaded.content_size_bytes != load.content_size_bytes) {
      [self stopWithCompletion:^{
        [self deliverOpenCompletion:completion success:NO
                              error:lf_session_error(
                                        LFHostSessionErrorLoad,
                                        @"The selected content could not be loaded.",
                                        @(status), nil)];
      }];
      return;
    }
    if (self->_observer != nil) {
      self->_observer(LFHostSessionEventLoadAccepted, nil, nil, 0U, 0U);
    }
    self->_videoBytes = (size_t)self->_profile.video_width *
                        (size_t)self->_profile.video_height;
    self->_audioCapacity = self->_profile.max_audio_samples_per_call;
    self->_video = (uint8_t *)self->_outputAllocator(self->_videoBytes,
                                                     sizeof(*self->_video));
    self->_audio = (int16_t *)self->_outputAllocator(self->_audioCapacity,
                                                      sizeof(*self->_audio));
    if (self->_video == NULL || self->_audio == NULL) {
      [self stopWithCompletion:^{
        [self deliverOpenCompletion:completion success:NO
                              error:lf_session_error(
                                        LFHostSessionErrorOutputAllocation,
                                        @"The session output buffers could not be allocated.",
                                        nil, nil)];
      }];
      return;
    }
    if (self->_observer != nil) {
      self->_observer(LFHostSessionEventOutputBuffersAllocated, nil, nil, 0U,
                      0U);
    }
    @synchronized(self) {
      self->_opening = NO;
      self->_opened = YES;
    }
    self->_clockOrigin = self->_clock();
    self->_nextDeadlineIndex = 1U;
    if (![self advanceOne]) {
      [self stopWithCompletion:^{
        [self deliverOpenCompletion:completion success:NO
                              error:lf_session_error(
                                        LFHostSessionErrorAdvance,
                                        @"The first profile interval failed.",
                                        nil, nil)];
      }];
      return;
    }
    [self deliverOpenCompletion:completion success:YES error:nil];
  });
}

- (void)startSteadyUpdatesWithCompletion:(LFHostCompletion)completion {
  dispatch_async(_queue, ^{
    BOOL started = NO;
    @synchronized(self) {
      started = self->_opened && !self->_stopping && self->_timer == nil;
    }
    if (started) {
      started = [self startTimer];
    }
    if (started) {
      [self deliverOpenCompletion:completion success:YES error:nil];
      return;
    }
    [self stopWithCompletion:^{
      [self deliverOpenCompletion:completion success:NO
                            error:lf_session_error(
                                      LFHostSessionErrorScheduler,
                                      @"The profile scheduler could not start.",
                                      nil, nil)];
    }];
  });
}

- (void)stopWithCompletion:(LFHostStopCompletion)completion {
  dispatch_source_t timer = nil;
  BOOL enqueueStop = NO;
  BOOL finishImmediately = NO;
  @synchronized(self) {
    _stopping = YES;
    _timerStarted = NO;
    _testScheduledDeadline = 0U;
    if (_stopFinished) {
      finishImmediately = completion != nil;
    } else if (completion != nil) {
      [_stopCompletions addObject:[completion copy]];
    }
    if (!_stopQueued && !_stopFinished) {
      _stopQueued = YES;
      enqueueStop = YES;
    }
    timer = _timer;
  }
  [_audioOutput disarm];
  if (timer != nil) {
    dispatch_source_cancel(timer);
  }
  if (finishImmediately) {
    dispatch_async(_callbackQueue, completion);
  }
  if (!enqueueStop) {
    return;
  }
  dispatch_async(_queue, ^{
    if (self->_audioOutput != nil) {
      (void)[self->_audioOutput stop];
    }
    if (self->_instance != NULL) {
      (void)lf_destroy(&self->_instance);
      if (self->_observer != nil) {
        self->_observer(LFHostSessionEventInstanceDestroyed, nil, nil, 0U,
                        0U);
      }
    }
    free(self->_video);
    self->_video = NULL;
    free(self->_audio);
    self->_audio = NULL;
    if (self->_observer != nil) {
      self->_observer(LFHostSessionEventOutputBuffersReleased, nil, nil, 0U,
                      0U);
    }
#if defined(LF_HOST_SESSION_TESTING)
    @synchronized(self) {
      self->_testingProfileMutation = nil;
      self->_testingResultMutation = nil;
    }
#endif
    self->_videoBytes = 0U;
    self->_audioCapacity = 0U;
    NSArray<LFHostStopCompletion> *completions = nil;
    @synchronized(self) {
      self->_opened = NO;
      self->_stopFinished = YES;
      completions = [self->_stopCompletions copy];
      [self->_stopCompletions removeAllObjects];
    }
    dispatch_async(self->_callbackQueue, ^{
      for (LFHostStopCompletion stopCompletion in completions) {
        stopCompletion();
      }
    });
  });
}
@end
