/* SPDX-License-Identifier: MIT */
#import "LFHost.h"
#import "LFHostSessionTesting.h"
#import "LFAudioOutput.h"

#include "LFHostAudioMetadata.h"
#include "muhtari_oracle.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int fail(const char *message) {
  (void)fprintf(stderr, "host_tracer: %s failed\n", message);
  return 1;
}

typedef enum audio_metadata_field {
  AUDIO_METADATA_ENCODING,
  AUDIO_METADATA_LAYOUT,
  AUDIO_METADATA_RATE_NUMERATOR,
  AUDIO_METADATA_RATE_DENOMINATOR,
  AUDIO_METADATA_CHANNELS
} audio_metadata_field;

typedef struct audio_metadata_case {
  audio_metadata_field field;
  const char *name;
  uint32_t value;
} audio_metadata_case;

static const audio_metadata_case unsupported_audio_metadata[] = {
    {AUDIO_METADATA_ENCODING, "encoding-zero", 0U},
    {AUDIO_METADATA_ENCODING, "encoding-unknown", 2U},
    {AUDIO_METADATA_LAYOUT, "layout-zero", 0U},
    {AUDIO_METADATA_LAYOUT, "layout-unknown", 2U},
    {AUDIO_METADATA_RATE_NUMERATOR, "rate-numerator-zero", 0U},
    {AUDIO_METADATA_RATE_NUMERATOR, "rate-numerator-low", 47999U},
    {AUDIO_METADATA_RATE_NUMERATOR, "rate-numerator-high", 48001U},
    {AUDIO_METADATA_RATE_NUMERATOR, "rate-numerator-maximum", UINT32_MAX},
    {AUDIO_METADATA_RATE_DENOMINATOR, "rate-denominator-zero", 0U},
    {AUDIO_METADATA_RATE_DENOMINATOR, "rate-denominator-two", 2U},
    {AUDIO_METADATA_RATE_DENOMINATOR, "rate-denominator-maximum", UINT32_MAX},
    {AUDIO_METADATA_CHANNELS, "channels-zero", 0U},
    {AUDIO_METADATA_CHANNELS, "channels-two", 2U},
    {AUDIO_METADATA_CHANNELS, "channels-maximum", UINT32_MAX},
};

static lf_profile supported_profile_audio(void) {
  lf_profile profile = {0};
  profile.audio_encoding = LF_AUDIO_S16_NATIVE;
  profile.audio_layout = LF_AUDIO_INTERLEAVED;
  profile.audio_rate_numerator = 48000U;
  profile.audio_rate_denominator = 1U;
  profile.audio_channels = 1U;
  return profile;
}

static lf_run_result supported_result_audio(void) {
  lf_run_result result = {0};
  result.audio_encoding = LF_AUDIO_S16_NATIVE;
  result.audio_layout = LF_AUDIO_INTERLEAVED;
  result.audio_rate_numerator = 48000U;
  result.audio_rate_denominator = 1U;
  result.audio_channels = 1U;
  return result;
}

static const char *audio_metadata_field_name(audio_metadata_field field) {
  switch (field) {
  case AUDIO_METADATA_ENCODING:
    return "encoding";
  case AUDIO_METADATA_LAYOUT:
    return "layout";
  case AUDIO_METADATA_RATE_NUMERATOR:
    return "rate-numerator";
  case AUDIO_METADATA_RATE_DENOMINATOR:
    return "rate-denominator";
  case AUDIO_METADATA_CHANNELS:
    return "channels";
  }
  return "unknown";
}

static void set_profile_audio_field(lf_profile *profile,
                                    audio_metadata_field field,
                                    uint32_t value) {
  switch (field) {
  case AUDIO_METADATA_ENCODING:
    profile->audio_encoding = (lf_audio_encoding)value;
    break;
  case AUDIO_METADATA_LAYOUT:
    profile->audio_layout = (lf_audio_layout)value;
    break;
  case AUDIO_METADATA_RATE_NUMERATOR:
    profile->audio_rate_numerator = value;
    break;
  case AUDIO_METADATA_RATE_DENOMINATOR:
    profile->audio_rate_denominator = value;
    break;
  case AUDIO_METADATA_CHANNELS:
    profile->audio_channels = value;
    break;
  }
}

static void set_result_audio_field(lf_run_result *result,
                                   audio_metadata_field field,
                                   uint32_t value) {
  switch (field) {
  case AUDIO_METADATA_ENCODING:
    result->audio_encoding = (lf_audio_encoding)value;
    break;
  case AUDIO_METADATA_LAYOUT:
    result->audio_layout = (lf_audio_layout)value;
    break;
  case AUDIO_METADATA_RATE_NUMERATOR:
    result->audio_rate_numerator = value;
    break;
  case AUDIO_METADATA_RATE_DENOMINATOR:
    result->audio_rate_denominator = value;
    break;
  case AUDIO_METADATA_CHANNELS:
    result->audio_channels = value;
    break;
  }
}

static int fail_audio_metadata_case(const char *record, const char *name,
                                    uint32_t value) {
  (void)fprintf(stderr,
                "host_tracer: audio metadata accepted unsupported %s.%s=%"
                PRIu32 "\n",
                record, name, value);
  return 1;
}

static int verify_audio_metadata(void) {
  const lf_profile validProfile = supported_profile_audio();
  const lf_run_result validResult = supported_result_audio();
  if (!lf_host_profile_audio_is_supported(&validProfile) ||
      !lf_host_result_audio_is_supported(&validResult)) {
    return fail("audio metadata rejected the supported tuple");
  }
  if (lf_host_profile_audio_is_supported(NULL) ||
      lf_host_result_audio_is_supported(NULL)) {
    return fail("audio metadata accepted null input");
  }

  const size_t caseCount = sizeof(unsupported_audio_metadata) /
                           sizeof(unsupported_audio_metadata[0]);
  for (size_t index = 0U; index < caseCount; ++index) {
    const audio_metadata_case testCase = unsupported_audio_metadata[index];
    lf_profile profile = supported_profile_audio();
    set_profile_audio_field(&profile, testCase.field, testCase.value);
    if (lf_host_profile_audio_is_supported(&profile)) {
      return fail_audio_metadata_case("profile", testCase.name,
                                      testCase.value);
    }

    lf_run_result result = supported_result_audio();
    set_result_audio_field(&result, testCase.field, testCase.value);
    if (lf_host_result_audio_is_supported(&result)) {
      return fail_audio_metadata_case("result", testCase.name,
                                      testCase.value);
    }
  }

  lf_profile alternateProfile = supported_profile_audio();
  alternateProfile.audio_rate_numerator = 96000U;
  alternateProfile.audio_rate_denominator = 2U;
  lf_run_result alternateResult = supported_result_audio();
  alternateResult.audio_rate_numerator = 96000U;
  alternateResult.audio_rate_denominator = 2U;
  if (lf_host_profile_audio_is_supported(&alternateProfile) ||
      lf_host_result_audio_is_supported(&alternateResult)) {
    return fail("audio metadata accepted the equivalent 96000/2 tuple");
  }

  lf_run_result zeroSampleResult = supported_result_audio();
  zeroSampleResult.audio_channels = 2U;
  if (zeroSampleResult.audio_produced_samples != 0U ||
      lf_host_result_audio_is_supported(&zeroSampleResult)) {
    return fail("audio metadata accepted an invalid zero-sample result");
  }

  if (!lf_host_profile_audio_is_supported(&validProfile) ||
      lf_host_result_audio_is_supported(&zeroSampleResult)) {
    return fail("audio metadata did not reject a result under a valid profile");
  }

  lf_profile sharedUnsupportedProfile = supported_profile_audio();
  lf_run_result sharedUnsupportedResult = supported_result_audio();
  sharedUnsupportedProfile.audio_rate_numerator = 96000U;
  sharedUnsupportedProfile.audio_rate_denominator = 2U;
  sharedUnsupportedResult.audio_rate_numerator = 96000U;
  sharedUnsupportedResult.audio_rate_denominator = 2U;
  if (lf_host_profile_audio_is_supported(&sharedUnsupportedProfile) ||
      lf_host_result_audio_is_supported(&sharedUnsupportedResult)) {
    return fail("audio metadata accepted a shared unsupported profile/result tuple");
  }
  return 0;
}

static uint64_t monotonic_nanoseconds(void) {
  struct timespec now = {0, 0};
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0 || now.tv_sec < 0 ||
      now.tv_nsec < 0) {
    return 0U;
  }
  return (uint64_t)now.tv_sec * UINT64_C(1000000000) +
         (uint64_t)now.tv_nsec;
}

static BOOL pcm_matches(NSData *samples, NSUInteger expectedCount,
                        size_t oracleIndex) {
  if (samples.length != expectedCount * sizeof(int16_t)) {
    return NO;
  }
  char actual[65];
  return lf_muhtari_oracle_pcm_matches((const int16_t *)samples.bytes,
                                        expectedCount, oracleIndex, actual) != 0;
}

@interface LFMetadataTrace : NSObject {
@private
  NSMutableArray<NSString *> *_events;
  BOOL _openSucceeded;
  NSString *_openErrorDomain;
  NSInteger _openErrorCode;
}
- (void)record:(NSString *)event;
- (NSUInteger)count:(NSString *)event;
- (NSUInteger)countWithPrefix:(NSString *)prefix;
- (NSUInteger)indexOf:(NSString *)event;
- (NSArray<NSString *> *)events;
- (void)recordOpenCompletionSuccess:(BOOL)success error:(NSError *)error;
- (BOOL)openSucceeded;
- (NSString *)openErrorDomain;
- (NSInteger)openErrorCode;
- (NSString *)diagnostic;
@end

@implementation LFMetadataTrace
- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _events = [NSMutableArray array];
    _openErrorDomain = @"";
  }
  return self;
}

- (void)record:(NSString *)event {
  @synchronized(self) {
    [_events addObject:event];
  }
}

- (NSUInteger)count:(NSString *)event {
  @synchronized(self) {
    NSUInteger result = 0U;
    for (NSString *candidate in _events) {
      if ([candidate isEqualToString:event]) {
        ++result;
      }
    }
    return result;
  }
}

- (NSUInteger)countWithPrefix:(NSString *)prefix {
  @synchronized(self) {
    NSUInteger result = 0U;
    for (NSString *candidate in _events) {
      if ([candidate hasPrefix:prefix]) {
        ++result;
      }
    }
    return result;
  }
}

- (NSUInteger)indexOf:(NSString *)event {
  @synchronized(self) {
    return [_events indexOfObject:event];
  }
}

- (NSArray<NSString *> *)events {
  @synchronized(self) {
    return [_events copy];
  }
}

- (void)recordOpenCompletionSuccess:(BOOL)success error:(NSError *)error {
  @synchronized(self) {
    _openSucceeded = success;
    _openErrorDomain = error.domain != nil ? [error.domain copy] : @"";
    _openErrorCode = error != nil ? error.code : 0;
    [_events addObject:success ? @"completion.open.success"
                               : @"completion.open.failure"];
  }
}

- (BOOL)openSucceeded {
  @synchronized(self) {
    return _openSucceeded;
  }
}

- (NSString *)openErrorDomain {
  @synchronized(self) {
    return _openErrorDomain;
  }
}

- (NSInteger)openErrorCode {
  @synchronized(self) {
    return _openErrorCode;
  }
}

- (NSString *)diagnostic {
  NSArray<NSString *> *snapshot = [self events];
  return [NSString stringWithFormat:
      @"open=%d error=%@/%ld reads=%lu allocations=%lu advances=%lu "
       "schedules=%lu disarms=%lu stops=%lu created=%lu destroyed=%lu "
       "released=%lu profile-mutations=%lu result-mutations=%lu events=[%@]",
      self.openSucceeded,
      self.openErrorDomain, (long)self.openErrorCode,
      (unsigned long)[self count:@"reader.read"],
      (unsigned long)[self count:@"allocator.allocate"],
      (unsigned long)[self count:@"host.advance.started"],
      (unsigned long)[self count:@"audio.schedule"],
      (unsigned long)[self count:@"audio.disarm"],
      (unsigned long)[self count:@"audio.stop"],
      (unsigned long)[self count:@"host.instance.created"],
      (unsigned long)[self count:@"host.instance.destroyed"],
      (unsigned long)[self count:@"host.buffers.released"],
      (unsigned long)[self count:@"mutation.profile.called"],
      (unsigned long)[self count:@"mutation.result.called"],
      [snapshot componentsJoinedByString:@","]];
}
@end

@interface LFCountingContentReader : LFContentReader
- (instancetype)initWithTrace:(LFMetadataTrace *)trace;
@end

@implementation LFCountingContentReader {
  LFMetadataTrace *_trace;
}
- (instancetype)initWithTrace:(LFMetadataTrace *)trace {
  self = [super init];
  if (self != nil) {
    _trace = trace;
  }
  return self;
}

- (nullable NSData *)readAtPath:(NSString *)path
                   maximumBytes:(size_t)maximumBytes
                          error:(NSError * _Nullable * _Nullable)error {
  [_trace record:@"reader.read"];
  return [super readAtPath:path maximumBytes:maximumBytes error:error];
}
@end

@interface LFCountingAudioOutput : LFAudioOutput
- (instancetype)initWithTrace:(LFMetadataTrace *)trace;
@end

@implementation LFCountingAudioOutput {
  LFMetadataTrace *_trace;
}
- (instancetype)initWithTrace:(LFMetadataTrace *)trace {
  self = [super init];
  if (self != nil) {
    _trace = trace;
  }
  return self;
}

- (BOOL)scheduleSamples:(const int16_t *)samples count:(size_t)sampleCount {
  [_trace record:@"audio.schedule"];
  if (samples != NULL && sampleCount > 0U) {
    [_trace record:@"audio.schedule.positive"];
    [_trace record:[NSString stringWithFormat:@"audio.schedule.count.%lu",
                                              (unsigned long)sampleCount]];
  }
  return sampleCount == 0U || samples != NULL;
}

- (void)disarm {
  [_trace record:@"audio.disarm"];
}

- (BOOL)stop {
  [_trace record:@"audio.stop"];
  return YES;
}
@end

typedef NS_ENUM(NSUInteger, LFMetadataScenario) {
  LFMetadataScenarioUnsupportedProfile,
  LFMetadataScenarioPositiveSampleResult,
  LFMetadataScenarioZeroSampleResult,
  LFMetadataScenarioUnmutatedControl,
  LFMetadataScenarioSteadyResult,
};

static const char *metadata_scenario_name(LFMetadataScenario scenario) {
  switch (scenario) {
  case LFMetadataScenarioUnsupportedProfile:
    return "unsupported-profile";
  case LFMetadataScenarioPositiveSampleResult:
    return "positive-sample-result";
  case LFMetadataScenarioZeroSampleResult:
    return "zero-sample-result";
  case LFMetadataScenarioUnmutatedControl:
    return "unmutated-control";
  case LFMetadataScenarioSteadyResult:
    return "steady-result";
  }
  return "unknown";
}

static BOOL profile_matches_full_supported_baseline(const lf_profile *profile) {
  return profile != NULL && lf_host_profile_audio_is_supported(profile) &&
         profile->profile_id != NULL &&
         strcmp(profile->profile_id, "muhtari-ntsc-v1") == 0 &&
         profile->core_id != NULL && strcmp(profile->core_id, "muhtari") == 0 &&
         profile->input_mask == UINT32_C(0xF1F1) &&
         profile->max_work_units == 1U &&
         profile->video_format == LF_VIDEO_INDEX8 &&
         profile->video_width == 320U && profile->video_height == 242U &&
         profile->max_audio_samples_per_call == 801U &&
         profile->max_content_bytes == 1048704U &&
         profile->frame_rate_numerator == 39375000U &&
         profile->frame_rate_denominator == 656711U;
}

static BOOL result_matches_supported_sample_count(
    const lf_run_result *result, uint32_t expectedSampleCount) {
  const size_t expectedVideoExtent = (size_t)320U * (size_t)242U;
  return result != NULL && lf_host_result_audio_is_supported(result) &&
         result->requested_units == 1U && result->actual_units == 1U &&
         result->overshoot_units == 0U && result->video_valid == 1U &&
         result->audio_valid == 1U &&
         result->video_format == LF_VIDEO_INDEX8 &&
         result->video_width == 320U && result->video_height == 242U &&
         result->video_stride_bytes == 320U &&
         result->video_extent_bytes == expectedVideoExtent &&
         result->audio_produced_samples <= 801U &&
         result->audio_produced_samples == expectedSampleCount &&
         result->audio_produced_samples > 0U &&
         result->core_ticks_valid == 0U &&
         result->cumulative_core_ticks == 0U;
}

static BOOL result_matches_full_supported_baseline(const lf_run_result *result) {
  return result_matches_supported_sample_count(
      result, LF_MUHTARI_ORACLE_FIRST_FRAME_SAMPLES);
}

static NSString *host_event_name(LFHostSessionEvent event) {
  switch (event) {
  case LFHostSessionEventAdvanceStarted:
    return @"host.advance.started";
  case LFHostSessionEventAdvanceFinished:
    return @"host.advance.finished";
  case LFHostSessionEventInstanceDestroyed:
    return @"host.instance.destroyed";
  case LFHostSessionEventContentReleased:
    return @"host.content.released";
  case LFHostSessionEventInstanceCreated:
    return @"host.instance.created";
  case LFHostSessionEventLoadStarted:
    return @"host.load.started";
  case LFHostSessionEventLoadFinished:
    return @"host.load.finished";
  case LFHostSessionEventOutputBuffersAllocated:
    return @"host.buffers.allocated";
  case LFHostSessionEventLoadAccepted:
    return @"host.load.accepted";
  case LFHostSessionEventInputSampled:
    return @"host.input.sampled";
  case LFHostSessionEventCoreAdvanceStarted:
    return @"host.core.advance.started";
  case LFHostSessionEventOutputBuffersReleased:
    return @"host.buffers.released";
  case LFHostSessionEventFrameInvalidationScheduled:
    return @"host.frame.invalidation";
  }
  return @"host.event.unknown";
}

static int metadata_case_failure(LFMetadataScenario scenario,
                                 LFMetadataTrace *trace,
                                 const char *reason) {
  NSString *diagnostic = [trace diagnostic];
  (void)fprintf(stderr, "host_tracer: metadata case=%s reason=%s %s\n",
                metadata_scenario_name(scenario), reason,
                diagnostic.UTF8String);
  return 1;
}

static BOOL wait_for_metadata_test_semaphore(dispatch_semaphore_t semaphore) {
  const dispatch_time_t deadline =
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5U * NSEC_PER_SEC));
  return dispatch_semaphore_wait(semaphore, deadline) == 0;
}

static BOOL stop_metadata_test_session(LFHostSession *session,
                                       dispatch_queue_t callbackQueue) {
  if (session == nil) {
    return YES;
  }
  dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
  [session stopWithCompletion:^{
    dispatch_semaphore_signal(stopped);
  }];
  const BOOL completed = wait_for_metadata_test_semaphore(stopped);
  if (completed) {
    dispatch_sync(callbackQueue, ^{});
  }
  return completed;
}

static int run_metadata_session_case(NSString *fixturePath,
                                     dispatch_queue_t callbackQueue,
                                     dispatch_time_t deadline,
                                     LFMetadataScenario scenario) {
  LFMetadataTrace *trace = [[LFMetadataTrace alloc] init];
  LFCountingContentReader *reader =
      [[LFCountingContentReader alloc] initWithTrace:trace];
  LFCountingAudioOutput *audio =
      [[LFCountingAudioOutput alloc] initWithTrace:trace];
  dispatch_semaphore_t completed = dispatch_semaphore_create(0);
  __block LFHostSession *session = nil;

  LFHostSessionProfileMutation profileMutation = nil;
  if (scenario == LFMetadataScenarioUnsupportedProfile) {
    profileMutation = ^(lf_profile *profile) {
      [trace record:@"mutation.profile.called"];
      const BOOL originalProfileIsRealAndSupported =
          profile_matches_full_supported_baseline(profile);
      [trace record:originalProfileIsRealAndSupported
                        ? @"mutation.profile.original-supported"
                        : @"mutation.profile.original-unexpected"];
      if (originalProfileIsRealAndSupported) {
        profile->audio_channels = 2U;
        [trace record:@"mutation.profile.applied"];
      }
    };
  }

  LFHostSessionResultMutation resultMutation = nil;
  if (scenario == LFMetadataScenarioPositiveSampleResult ||
      scenario == LFMetadataScenarioZeroSampleResult) {
    const BOOL zeroSamples =
        scenario == LFMetadataScenarioZeroSampleResult;
    resultMutation = ^(lf_run_result *result) {
      [trace record:@"mutation.result.called"];
      const BOOL originalResultIsRealAndSupported =
          result_matches_full_supported_baseline(result);
      [trace record:originalResultIsRealAndSupported
                        ? @"mutation.result.original-supported-positive"
                        : @"mutation.result.original-unexpected"];
      if (!originalResultIsRealAndSupported) {
        return;
      }
      if (zeroSamples) {
        result->audio_produced_samples = 0U;
      }
      result->audio_encoding = (lf_audio_encoding)2U;
      [trace record:zeroSamples ? @"mutation.result.applied-zero"
                                : @"mutation.result.applied-positive"];
    };
  }

  LFHostSessionObserver observer = ^(LFHostSessionEvent event,
                                     LFHostFrame *frame,
                                     NSData *audioSamples,
                                     NSUInteger audioCapacitySamples,
                                     uint32_t inputButtons) {
    (void)inputButtons;
    [trace record:host_event_name(event)];
    if (event == LFHostSessionEventAdvanceFinished) {
      NSString *detail = nil;
      if (frame == nil && audioSamples == nil) {
        detail = @"observer.advance.finished.nil-frame.nil-audio";
      } else if (frame == nil) {
        detail = @"observer.advance.finished.nil-frame.with-audio";
      } else if (audioSamples == nil) {
        detail = @"observer.advance.finished.with-frame.nil-audio";
      } else {
        detail = @"observer.advance.finished.with-frame.with-audio";
      }
      [trace record:detail];
      [trace record:[NSString stringWithFormat:
                               @"observer.advance.capacity.%lu",
                               (unsigned long)audioCapacitySamples]];
    }
  };
  LFHostOutputAllocator allocator = ^void *(size_t count, size_t size) {
    [trace record:@"allocator.allocate"];
    return calloc(count, size);
  };
  session = [[LFHostSession alloc]
      initWithFrameHandler:^(LFHostFrame *frame) {
        (void)frame;
        [trace record:@"frame.callback"];
      }
        callbackQueue:callbackQueue
                clock:nil
             observer:observer
      outputAllocator:allocator
          audioOutput:audio];
  if (session == nil ||
      ![session configureTestingBeforeOpenWithProfileMutation:profileMutation
                                               resultMutation:resultMutation
                                                 contentReader:reader]) {
    return metadata_case_failure(scenario, trace,
                                 "session-configuration-rejected");
  }

  [session openContentAtPath:fixturePath
                  completion:^(BOOL success, NSError *error) {
                    [trace recordOpenCompletionSuccess:success error:error];
                    if (!success) {
                      [trace record:[NSString stringWithFormat:
                                                 @"cleanup.before-explicit-stop.stop.%lu",
                                                 (unsigned long)[trace count:@"audio.stop"]]];
                      [trace record:[NSString stringWithFormat:
                                                 @"cleanup.before-explicit-stop.destroy.%lu",
                                                 (unsigned long)[trace count:@"host.instance.destroyed"]]];
                      [trace record:[NSString stringWithFormat:
                                                 @"cleanup.before-explicit-stop.release.%lu",
                                                 (unsigned long)[trace count:@"host.buffers.released"]]];
                      [trace record:[NSString stringWithFormat:
                                                 @"cleanup.before-explicit-stop.schedule.%lu",
                                                 (unsigned long)[trace count:@"audio.schedule"]]];
                    }
                    const BOOL reconfigurationAccepted =
                        [session configureTestingBeforeOpenWithProfileMutation:profileMutation
                                                                 resultMutation:resultMutation
                                                                   contentReader:reader];
                    [trace record:reconfigurationAccepted
                                      ? @"testing.reconfigure.accepted"
                                      : @"testing.reconfigure.rejected"];
                    [session stopWithCompletion:^{
                      [trace record:@"completion.explicit-stop"];
                      dispatch_semaphore_signal(completed);
                    }];
                  }];
  if (dispatch_semaphore_wait(completed, deadline) != 0) {
    [session stopWithCompletion:nil];
    return metadata_case_failure(scenario, trace,
                                 "shared-bounded-deadline-expired");
  }
  dispatch_sync(callbackQueue, ^{});

  const BOOL isProfileCase =
      scenario == LFMetadataScenarioUnsupportedProfile;
  const BOOL isResultCase =
      scenario == LFMetadataScenarioPositiveSampleResult ||
      scenario == LFMetadataScenarioZeroSampleResult;
  const BOOL isControl = scenario == LFMetadataScenarioUnmutatedControl;
  const BOOL expectedSuccess = isControl;
  const NSInteger expectedError =
      isProfileCase ? LFHostSessionErrorProfile : LFHostSessionErrorAdvance;

  if ([trace count:@"completion.open.success"] +
              [trace count:@"completion.open.failure"] !=
          1U ||
      [trace openSucceeded] != expectedSuccess ||
      (expectedSuccess && ([trace openErrorDomain].length != 0U ||
                           [trace openErrorCode] != 0)) ||
      (!expectedSuccess &&
       (![[trace openErrorDomain] isEqualToString:LFHostSessionErrorDomain] ||
        [trace openErrorCode] != expectedError))) {
    return metadata_case_failure(scenario, trace,
                                 "open-result-or-error-mismatch");
  }
  if ([trace count:@"testing.reconfigure.rejected"] != 1U ||
      [trace count:@"testing.reconfigure.accepted"] != 0U) {
    return metadata_case_failure(scenario, trace,
                                 "testing-configuration-was-not-sealed");
  }

  if ([trace count:@"mutation.profile.called"] !=
          (isProfileCase ? 1U : 0U) ||
      [trace count:@"mutation.result.called"] !=
          (isResultCase ? 1U : 0U) ||
      [trace count:@"mutation.profile.original-supported"] !=
          (isProfileCase ? 1U : 0U) ||
      [trace count:@"mutation.result.original-supported-positive"] !=
          (isResultCase ? 1U : 0U) ||
      [trace count:@"mutation.profile.original-unexpected"] != 0U ||
      [trace count:@"mutation.result.original-unexpected"] != 0U ||
      [trace count:@"mutation.profile.applied"] !=
          (isProfileCase ? 1U : 0U) ||
      [trace count:@"mutation.result.applied-positive"] !=
          (scenario == LFMetadataScenarioPositiveSampleResult ? 1U : 0U) ||
      [trace count:@"mutation.result.applied-zero"] !=
          (scenario == LFMetadataScenarioZeroSampleResult ? 1U : 0U)) {
    return metadata_case_failure(scenario, trace,
                                 "real-metadata-mutation-count-or-origin");
  }

  const NSUInteger readerCalls = [trace count:@"reader.read"];
  const NSUInteger allocationCalls = [trace count:@"allocator.allocate"];
  if (readerCalls != (isProfileCase ? 0U : 1U) ||
      allocationCalls != (isProfileCase ? 0U : 2U) ||
      [trace count:@"audio.schedule"] != (isControl ? 1U : 0U) ||
      [trace count:@"audio.schedule.positive"] != (isControl ? 1U : 0U)) {
    return metadata_case_failure(scenario, trace,
                                 "reader-allocation-or-pcm-use-mismatch");
  }

  if (isProfileCase) {
    NSString *const forbiddenEvents[] = {
        @"host.instance.created", @"host.load.started", @"host.load.finished",
        @"host.load.accepted", @"host.advance.started",
        @"host.core.advance.started", @"host.input.sampled",
        @"host.advance.finished", @"host.buffers.allocated",
        @"host.frame.invalidation", @"frame.callback",
        @"audio.schedule", @"host.instance.destroyed"};
    for (size_t index = 0U;
         index < sizeof(forbiddenEvents) / sizeof(forbiddenEvents[0]);
         ++index) {
      if ([trace count:forbiddenEvents[index]] != 0U) {
        return metadata_case_failure(scenario, trace,
                                     "profile-refusal-crossed-work-boundary");
      }
    }
  } else {
    const NSUInteger expectedFrameAndAudioCount = isControl ? 1U : 0U;
    if ([trace count:@"host.instance.created"] != 1U ||
        [trace count:@"host.load.accepted"] != 1U ||
        [trace count:@"host.buffers.allocated"] != 1U ||
        [trace count:@"host.advance.started"] != 1U ||
        [trace count:@"host.core.advance.started"] != 1U ||
        [trace count:@"host.advance.finished"] != 1U ||
        [trace count:@"observer.advance.finished.nil-frame.nil-audio"] !=
            (isResultCase ? 1U : 0U) ||
        [trace count:@"observer.advance.finished.with-frame.with-audio"] !=
            expectedFrameAndAudioCount ||
        [trace count:@"host.frame.invalidation"] !=
            expectedFrameAndAudioCount ||
        [trace count:@"frame.callback"] != expectedFrameAndAudioCount ||
        [trace count:@"host.instance.destroyed"] != 1U ||
        [trace count:@"host.buffers.released"] != 1U) {
      return metadata_case_failure(scenario, trace,
                                   "result-publication-or-lifecycle-mismatch");
    }
    if (isResultCase &&
        [trace count:@"observer.advance.finished.nil-frame.nil-audio"] != 1U) {
      return metadata_case_failure(scenario, trace,
                                   "invalid-result-observer-was-not-empty");
    }
  }

  if ([trace count:@"audio.stop"] != 1U ||
      [trace count:@"host.buffers.released"] != 1U ||
      [trace count:@"completion.explicit-stop"] != 1U) {
    return metadata_case_failure(scenario, trace,
                                 "cleanup-count-or-stop-completion-mismatch");
  }
  const NSUInteger disarmIndex = [trace indexOf:@"audio.disarm"];
  const NSUInteger stopIndex = [trace indexOf:@"audio.stop"];
  const NSUInteger destroyIndex = [trace indexOf:@"host.instance.destroyed"];
  const NSUInteger releaseIndex = [trace indexOf:@"host.buffers.released"];
  const NSUInteger openCompletionIndex =
      [trace indexOf:expectedSuccess ? @"completion.open.success"
                                    : @"completion.open.failure"];
  if (disarmIndex == NSNotFound || stopIndex == NSNotFound ||
      releaseIndex == NSNotFound || openCompletionIndex == NSNotFound ||
      disarmIndex >= stopIndex || stopIndex >= releaseIndex ||
      (!expectedSuccess && releaseIndex >= openCompletionIndex) ||
      (expectedSuccess && openCompletionIndex >= disarmIndex) ||
      (isProfileCase && destroyIndex != NSNotFound) ||
      ((isResultCase || isControl) &&
       (destroyIndex == NSNotFound || stopIndex >= destroyIndex ||
        destroyIndex >= releaseIndex))) {
    return metadata_case_failure(scenario, trace,
                                 "ordered-cleanup-or-completion-mismatch");
  }

  if (isResultCase &&
      ([trace count:@"cleanup.before-explicit-stop.stop.1"] != 1U ||
       [trace count:@"cleanup.before-explicit-stop.destroy.1"] != 1U ||
       [trace count:@"cleanup.before-explicit-stop.release.1"] != 1U ||
       [trace count:@"cleanup.before-explicit-stop.schedule.0"] != 1U ||
       [trace count:@"audio.stop"] != 1U ||
       [trace count:@"host.instance.destroyed"] != 1U ||
       [trace count:@"host.buffers.released"] != 1U ||
       [trace count:@"audio.schedule"] != 0U)) {
    return metadata_case_failure(scenario, trace,
                                 "explicit-stop-repeated-terminal-work");
  }

  (void)printf("host_tracer: metadata_session case=%s error=%ld reader=%lu "
               "allocations=%lu schedule=%lu destroy=%lu release=%lu result=pass\n",
               metadata_scenario_name(scenario), (long)[trace openErrorCode],
               (unsigned long)readerCalls, (unsigned long)allocationCalls,
               (unsigned long)[trace count:@"audio.schedule"],
               (unsigned long)[trace count:@"host.instance.destroyed"],
               (unsigned long)[trace count:@"host.buffers.released"]);
  return 0;
}

static int verify_invalid_path_releases_testing_capture(
    dispatch_queue_t callbackQueue, dispatch_time_t deadline) {
  LFMetadataTrace *trace = [[LFMetadataTrace alloc] init];
  dispatch_semaphore_t completed = dispatch_semaphore_create(0);
  __weak LFHostSession *weakSession = nil;
  @autoreleasepool {
    LFHostSession *session = [[LFHostSession alloc]
        initWithFrameHandler:^(LFHostFrame *frame) {
          (void)frame;
        }
          callbackQueue:callbackQueue
                  clock:nil
               observer:nil];
    if (session == nil) {
      return fail("metadata invalid-path session construction");
    }
    weakSession = session;
    LFHostSessionProfileMutation retainedMutation = ^(lf_profile *profile) {
      (void)profile;
      if (session != nil) {
        [trace record:@"invalid-path.retained-mutation-invoked"];
      }
    };
    const BOOL configured =
        [session configureTestingBeforeOpenWithProfileMutation:retainedMutation
                                                 resultMutation:nil
                                                   contentReader:nil];
    retainedMutation = nil;
    if (!configured) {
      return fail("metadata invalid-path testing configuration");
    }

    [session openContentAtPath:@""
                    completion:^(BOOL success, NSError *error) {
                      [trace recordOpenCompletionSuccess:success error:error];
                      dispatch_semaphore_signal(completed);
                    }];
    session = nil;
    if (dispatch_semaphore_wait(completed, deadline) != 0) {
      return fail("metadata invalid-path completion deadline");
    }
    dispatch_sync(callbackQueue, ^{});
  }

  LFHostSession *leakedSession = weakSession;
  if (leakedSession != nil) {
    dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
    [leakedSession stopWithCompletion:^{
      dispatch_semaphore_signal(stopped);
    }];
    leakedSession = nil;
    (void)dispatch_semaphore_wait(stopped, deadline);
    dispatch_sync(callbackQueue, ^{});
    (void)fprintf(stderr,
                  "host_tracer: metadata case=invalid-path-lifetime "
                  "reason=session-retained-after-rejection %s\n",
                  [trace diagnostic].UTF8String);
    return 1;
  }
  if ([trace count:@"completion.open.failure"] != 1U ||
      [trace count:@"completion.open.success"] != 0U ||
      [trace openErrorCode] != LFHostSessionErrorInvalidRequest ||
      ![[trace openErrorDomain] isEqualToString:LFHostSessionErrorDomain] ||
      [trace count:@"invalid-path.retained-mutation-invoked"] != 0U) {
    return metadata_case_failure(LFMetadataScenarioUnsupportedProfile, trace,
                                 "invalid-path-rejection-result-mismatch");
  }
  (void)printf("host_tracer: metadata_session case=invalid-path-lifetime "
               "configured=1 deallocated=1 result=pass\n");
  return 0;
}

static int verify_steady_result_rejection(NSString *fixturePath,
                                         dispatch_queue_t callbackQueue) {
  LFMetadataTrace *trace = [[LFMetadataTrace alloc] init];
  NSObject *clockLock = [[NSObject alloc] init];
  __block uint64_t fakeNow = UINT64_C(3000000000);
  __block BOOL profileWasSupported = NO;
  __block LFHostFrame *startupFrame = nil;
  __block NSData *startupFrameBytes = nil;
  LFCountingContentReader *reader =
      [[LFCountingContentReader alloc] initWithTrace:trace];
  LFCountingAudioOutput *audio =
      [[LFCountingAudioOutput alloc] initWithTrace:trace];
  dispatch_semaphore_t opened = dispatch_semaphore_create(0);
  dispatch_semaphore_t started = dispatch_semaphore_create(0);
  dispatch_semaphore_t timerDelivered = dispatch_semaphore_create(0);
  dispatch_semaphore_t timingRead = dispatch_semaphore_create(0);
  dispatch_semaphore_t postStopTimerDelivered = dispatch_semaphore_create(0);
  dispatch_semaphore_t explicitlyStopped = dispatch_semaphore_create(0);
  __block BOOL openSucceeded = NO;
  __block BOOL steadyStarted = NO;
  __block BOOL timerStateActive = YES;
  __block uint64_t nextIndex = 0U;
  __block uint64_t deadline = 0U;
  __block NSUInteger stopCompletions = 0U;

  LFHostClock clock = ^uint64_t{
    @synchronized(clockLock) {
      return fakeNow;
    }
  };
  LFHostSessionObserver observer = ^(LFHostSessionEvent event,
                                     LFHostFrame *frame,
                                     NSData *audioSamples,
                                     NSUInteger audioCapacitySamples,
                                     uint32_t inputButtons) {
    (void)inputButtons;
    [trace record:host_event_name(event)];
    if (event != LFHostSessionEventAdvanceFinished) {
      return;
    }
    NSString *detail = nil;
    if (frame == nil && audioSamples == nil) {
      detail = @"observer.advance.finished.nil-frame.nil-audio";
    } else if (frame == nil) {
      detail = @"observer.advance.finished.nil-frame.with-audio";
    } else if (audioSamples == nil) {
      detail = @"observer.advance.finished.with-frame.nil-audio";
    } else {
      detail = @"observer.advance.finished.with-frame.with-audio";
      [trace record:[NSString stringWithFormat:
                               @"observer.advance.sample-bytes.%lu",
                               (unsigned long)audioSamples.length]];
      [trace record:[NSString stringWithFormat:
                               @"observer.advance.frame-samples.%lu",
                               (unsigned long)frame.audioProducedSamples]];
    }
    [trace record:detail];
    [trace record:[NSString stringWithFormat:
                             @"observer.advance.capacity.%lu",
                             (unsigned long)audioCapacitySamples]];
  };
  LFHostOutputAllocator allocator = ^void *(size_t count, size_t size) {
    [trace record:@"allocator.allocate"];
    return calloc(count, size);
  };
  LFHostSession *session = [[LFHostSession alloc]
      initWithFrameHandler:^(LFHostFrame *frame) {
        [trace record:@"frame.callback"];
        if (frame.sequence == 1U) {
          startupFrame = frame;
          startupFrameBytes = [frame.rawIndices copy];
        }
      }
        callbackQueue:callbackQueue
                clock:clock
             observer:observer
      outputAllocator:allocator
          audioOutput:audio];

#define STEADY_RESULT_FAIL(reason)                                             \
  do {                                                                         \
    if (!stop_metadata_test_session(session, callbackQueue)) {                \
      [trace record:@"failure.cleanup-timeout"];                              \
    }                                                                          \
    return metadata_case_failure(LFMetadataScenarioSteadyResult, trace,         \
                                 (reason));                                    \
  } while (0)

  if (session == nil || ![session enableManualTimerDeliveryForTesting]) {
    STEADY_RESULT_FAIL("session-construction-or-manual-timer-setup");
  }
  LFHostSessionProfileMutation profileMutation = ^(lf_profile *profile) {
    const BOOL supported = profile_matches_full_supported_baseline(profile);
    @synchronized(trace) {
      profileWasSupported = supported;
    }
    [trace record:supported ? @"profile.real-supported"
                            : @"profile.real-unsupported"];
  };
  if (![session configureTestingBeforeOpenWithProfileMutation:profileMutation
                                                resultMutation:nil
                                                  contentReader:reader]) {
    STEADY_RESULT_FAIL("testing-configuration-rejected");
  }

  [session openContentAtPath:fixturePath
                  completion:^(BOOL success, NSError *error) {
                    [trace recordOpenCompletionSuccess:success error:error];
                    openSucceeded = success;
                    dispatch_semaphore_signal(opened);
                  }];
  if (!wait_for_metadata_test_semaphore(opened)) {
    STEADY_RESULT_FAIL("open-completion-timeout");
  }
  dispatch_sync(callbackQueue, ^{});

  const BOOL startupBaselineValid =
      openSucceeded && profileWasSupported &&
      [trace count:@"completion.open.success"] == 1U &&
      [trace count:@"completion.open.failure"] == 0U &&
      [trace count:@"reader.read"] == 1U &&
      [trace count:@"allocator.allocate"] == 2U &&
      [trace count:@"host.advance.started"] == 1U &&
      [trace count:@"host.core.advance.started"] == 1U &&
      [trace count:@"host.advance.finished"] == 1U &&
      [trace count:@"observer.advance.finished.with-frame.with-audio"] ==
          1U &&
      [trace count:@"observer.advance.frame-samples.54"] == 1U &&
      [trace count:@"observer.advance.sample-bytes.108"] == 1U &&
      [trace count:@"observer.advance.capacity.801"] == 1U &&
      [trace count:@"host.frame.invalidation"] == 1U &&
      [trace count:@"frame.callback"] == 1U &&
      [trace count:@"audio.schedule"] == 1U &&
      [trace count:@"audio.schedule.positive"] == 1U &&
      [trace count:@"mutation.result.called"] == 0U &&
      startupFrame != nil && startupFrame.sequence == 1U &&
      startupFrame.audioProducedSamples ==
          LF_MUHTARI_ORACLE_FIRST_FRAME_SAMPLES &&
      startupFrameBytes != nil &&
      [startupFrame.rawIndices isEqualToData:startupFrameBytes];
  if (!startupBaselineValid) {
    STEADY_RESULT_FAIL("supported-startup-baseline");
  }

  LFHostSessionResultMutation resultMutation = ^(lf_run_result *result) {
    [trace record:@"mutation.result.steady.called"];
    BOOL supportedProfile = NO;
    @synchronized(trace) {
      supportedProfile = profileWasSupported;
    }
    if (!supportedProfile ||
        !result_matches_supported_sample_count(
            result, LF_MUHTARI_ORACLE_STEADY_FRAME_SAMPLES)) {
      [trace record:@"mutation.result.steady.invalid-origin"];
      return;
    }
    [trace record:@"mutation.result.steady.original-supported"];
    result->audio_encoding = (lf_audio_encoding)2U;
    [trace record:@"mutation.result.steady.applied"];
  };
  if (![session armResultMutationForTesting:resultMutation]) {
    STEADY_RESULT_FAIL("post-open-mutation-arming-rejected");
  }
  [session startSteadyUpdatesWithCompletion:^(BOOL success, NSError *error) {
    (void)error;
    steadyStarted = success;
    dispatch_semaphore_signal(started);
  }];
  if (!wait_for_metadata_test_semaphore(started) || !steadyStarted) {
    STEADY_RESULT_FAIL("steady-scheduler-start");
  }

  [session readTimingStateForTesting:^(uint64_t readIndex,
                                       uint64_t readDeadline,
                                       BOOL active) {
    nextIndex = readIndex;
    deadline = readDeadline;
    timerStateActive = active;
    dispatch_semaphore_signal(timingRead);
  }];
  if (!wait_for_metadata_test_semaphore(timingRead) || !timerStateActive ||
      nextIndex != 1U || deadline == 0U) {
    STEADY_RESULT_FAIL("first-steady-deadline");
  }
  BOOL deadlineIsFuture = NO;
  @synchronized(clockLock) {
    deadlineIsFuture = deadline > fakeNow;
    fakeNow = deadline;
  }
  if (!deadlineIsFuture) {
    STEADY_RESULT_FAIL("steady-deadline-not-in-future");
  }
  [session deliverTimerForTestingWithCompletion:^{
    dispatch_semaphore_signal(timerDelivered);
  }];
  if (!wait_for_metadata_test_semaphore(timerDelivered)) {
    STEADY_RESULT_FAIL("steady-timer-delivery-timeout");
  }

  timerStateActive = YES;
  deadline = UINT64_MAX;
  [session readTimingStateForTesting:^(uint64_t readIndex,
                                       uint64_t readDeadline,
                                       BOOL active) {
    nextIndex = readIndex;
    deadline = readDeadline;
    timerStateActive = active;
    dispatch_semaphore_signal(timingRead);
  }];
  if (!wait_for_metadata_test_semaphore(timingRead)) {
    STEADY_RESULT_FAIL("automatic-cleanup-owner-barrier-timeout");
  }

  NSArray<NSString *> *events = [trace events];
  const NSUInteger mutationIndex =
      [events indexOfObject:@"mutation.result.steady.applied"];
  const NSUInteger rejectedIndex =
      [events indexOfObject:@"observer.advance.finished.nil-frame.nil-audio"];
  const NSUInteger disarmIndex = [events indexOfObject:@"audio.disarm"];
  const NSUInteger stopIndex = [events indexOfObject:@"audio.stop"];
  const NSUInteger destroyIndex =
      [events indexOfObject:@"host.instance.destroyed"];
  const NSUInteger releaseIndex =
      [events indexOfObject:@"host.buffers.released"];
  const BOOL automaticCleanupValid =
      !timerStateActive && deadline == 0U &&
      [trace count:@"mutation.result.steady.called"] == 1U &&
      [trace count:@"mutation.result.steady.original-supported"] == 1U &&
      [trace count:@"mutation.result.steady.applied"] == 1U &&
      [trace count:@"mutation.result.steady.invalid-origin"] == 0U &&
      [trace count:@"host.advance.started"] == 2U &&
      [trace count:@"host.core.advance.started"] == 2U &&
      [trace count:@"host.advance.finished"] == 2U &&
      [trace count:@"observer.advance.finished.with-frame.with-audio"] ==
          1U &&
      [trace count:@"observer.advance.finished.nil-frame.nil-audio"] == 1U &&
      [trace count:@"observer.advance.frame-samples.54"] == 1U &&
      [trace count:@"observer.advance.sample-bytes.108"] == 1U &&
      [trace count:@"host.frame.invalidation"] == 1U &&
      [trace count:@"frame.callback"] == 1U &&
      [trace count:@"audio.schedule"] == 1U &&
      [trace count:@"audio.schedule.positive"] == 1U &&
      [trace count:@"audio.schedule.count.54"] == 1U &&
      [trace count:@"audio.disarm"] == 1U &&
      [trace count:@"audio.stop"] == 1U &&
      [trace count:@"host.instance.destroyed"] == 1U &&
      [trace count:@"host.buffers.released"] == 1U &&
      [trace count:@"allocator.allocate"] == 2U &&
      mutationIndex != NSNotFound && rejectedIndex != NSNotFound &&
      disarmIndex != NSNotFound && stopIndex != NSNotFound &&
      destroyIndex != NSNotFound && releaseIndex != NSNotFound &&
      mutationIndex < rejectedIndex && rejectedIndex < disarmIndex &&
      disarmIndex < stopIndex && stopIndex < destroyIndex &&
      destroyIndex < releaseIndex && rejectedIndex > 0U &&
      [events[rejectedIndex - 1U] isEqualToString:@"host.advance.finished"] &&
      startupFrameBytes != nil &&
      [startupFrame.rawIndices isEqualToData:startupFrameBytes];
  if (!automaticCleanupValid) {
    STEADY_RESULT_FAIL("steady-rejection-publication-or-automatic-cleanup");
  }

  [session deliverTimerForTestingWithCompletion:^{
    dispatch_semaphore_signal(postStopTimerDelivered);
  }];
  if (!wait_for_metadata_test_semaphore(postStopTimerDelivered)) {
    STEADY_RESULT_FAIL("post-stop-timer-delivery-timeout");
  }
  [session stopWithCompletion:^{
    ++stopCompletions;
    dispatch_semaphore_signal(explicitlyStopped);
  }];
  if (!wait_for_metadata_test_semaphore(explicitlyStopped)) {
    STEADY_RESULT_FAIL("explicit-stop-completion-timeout");
  }
  dispatch_sync(callbackQueue, ^{});

  const BOOL finalStateValid =
      stopCompletions == 1U &&
      [trace count:@"mutation.result.steady.called"] == 1U &&
      [trace count:@"host.advance.started"] == 2U &&
      [trace count:@"host.core.advance.started"] == 2U &&
      [trace count:@"host.advance.finished"] == 2U &&
      [trace count:@"host.frame.invalidation"] == 1U &&
      [trace count:@"frame.callback"] == 1U &&
      [trace count:@"audio.schedule"] == 1U &&
      [trace count:@"audio.stop"] == 1U &&
      [trace count:@"host.instance.destroyed"] == 1U &&
      [trace count:@"host.buffers.released"] == 1U &&
      [trace count:@"audio.disarm"] >= 2U && startupFrame != nil &&
      startupFrameBytes != nil &&
      [startupFrame.rawIndices isEqualToData:startupFrameBytes];
  if (!finalStateValid) {
    STEADY_RESULT_FAIL("post-stop-work-or-duplicate-cleanup");
  }
  (void)printf("host_tracer: metadata_session case=steady-result-invalid "
               "advances=2 schedules=1 stop=once destroy=once "
               "release=once result=pass\n");
  return 0;
#undef STEADY_RESULT_FAIL
}

static int verify_metadata_sessions(NSString *fixturePath,
                                    dispatch_queue_t callbackQueue,
                                    dispatch_time_t deadline) {
  const LFMetadataScenario scenarios[] = {
      LFMetadataScenarioUnsupportedProfile,
      LFMetadataScenarioPositiveSampleResult,
      LFMetadataScenarioZeroSampleResult,
      LFMetadataScenarioUnmutatedControl};
  for (size_t index = 0U; index <
                         sizeof(scenarios) / sizeof(scenarios[0]);
       ++index) {
    if (run_metadata_session_case(fixturePath, callbackQueue, deadline,
                                  scenarios[index]) != 0) {
      return 1;
    }
  }
  if (verify_invalid_path_releases_testing_capture(callbackQueue, deadline) !=
      0) {
    return 1;
  }
  return verify_steady_result_rejection(fixturePath, callbackQueue);
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc != 2 || argv[1] == NULL || argv[1][0] == '\0') {
      return fail("fixture argument");
    }
    if (verify_audio_metadata() != 0) {
      return EXIT_FAILURE;
    }

    const dispatch_time_t tracerDeadline =
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10U * NSEC_PER_SEC));

    dispatch_queue_t callbackQueue =
        dispatch_queue_create("org.libfuturo.host.tracer.callbacks",
                              DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
    NSObject *clockLock = [[NSObject alloc] init];
    __block uint64_t clockOffset = 0U;
    __block LFHostSession *session = nil;
    __block LFHostFrame *firstFrame = nil;
    __block NSData *retainedFirstRaw = nil;
    __block NSUInteger frameCount = 0U;
    __block NSUInteger openCompletions = 0U;
    __block NSUInteger startCompletions = 0U;
    __block NSUInteger startedCalls = 0U;
    __block NSUInteger finishedCalls = 0U;
    __block NSUInteger activeCalls = 0U;
    __block NSUInteger maximumActiveCalls = 0U;
    __block NSUInteger destroyEvents = 0U;
    __block NSUInteger firstSamples = 0U;
    __block NSUInteger steadySamples = 0U;
    __block NSUInteger firstCapacity = 0U;
    __block NSUInteger steadyCapacity = 0U;
    __block BOOL firstImageValid = NO;
    __block BOOL steadyImageValid = NO;
    __block BOOL firstPcmValid = NO;
    __block BOOL steadyPcmValid = NO;
    __block BOOL snapshotStayedImmutable = NO;
    __block BOOL opened = NO;
    __block BOOL steadyStarted = NO;
    __block BOOL observerFailed = NO;
    __block BOOL callbackFailed = NO;
    __block BOOL contentReleasedBeforeAdvance = NO;
    __block BOOL contentReleased = NO;
    __block BOOL overlapRejected = NO;

    LFHostClock clock = ^uint64_t{
      @synchronized(clockLock) {
        return monotonic_nanoseconds() + clockOffset;
      }
    };
    LFHostSessionObserver observer = ^(LFHostSessionEvent event,
                                       LFHostFrame *frame,
                                       NSData *audioSamples,
                                       NSUInteger audioCapacitySamples,
                                       uint32_t inputButtons) {
      (void)inputButtons;
      if (event == LFHostSessionEventAdvanceStarted) {
        if (activeCalls != 0U || !contentReleased) {
          observerFailed = YES;
        }
        ++activeCalls;
        ++startedCalls;
        if (activeCalls > maximumActiveCalls) {
          maximumActiveCalls = activeCalls;
        }
        return;
      }
      if (event == LFHostSessionEventAdvanceFinished) {
        if (activeCalls != 1U || frame == nil || audioSamples == nil ||
            audioCapacitySamples != 801U) {
          observerFailed = YES;
        }
        if (activeCalls > 0U) {
          --activeCalls;
        }
        ++finishedCalls;
        if (frame == nil || audioSamples == nil) {
          return;
        }
        if (frame.sequence == 1U) {
          firstSamples = frame.audioProducedSamples;
          firstCapacity = audioCapacitySamples;
          firstImageValid =
              lf_muhtari_oracle_first_image(frame.rawIndices.bytes, 320U,
                                             UINT8_C(0x11)) != 0;
          firstPcmValid = pcm_matches(audioSamples, firstSamples, 0U);
          @synchronized(clockLock) {
            clockOffset = UINT64_C(20000000);
          }
        } else if (frame.sequence == 2U) {
          steadySamples = frame.audioProducedSamples;
          steadyCapacity = audioCapacitySamples;
          steadyImageValid =
              lf_muhtari_oracle_steady_image(frame.rawIndices.bytes, 320U,
                                             UINT8_C(0x33)) != 0;
          steadyPcmValid = pcm_matches(audioSamples, steadySamples, 1U);
        } else {
          observerFailed = YES;
        }
        return;
      }
      if (event == LFHostSessionEventContentReleased) {
        contentReleased = YES;
        contentReleasedBeforeAdvance = startedCalls == 0U;
        return;
      }
      if (event == LFHostSessionEventInstanceDestroyed) {
        ++destroyEvents;
      }
    };

    session = [[LFHostSession alloc]
        initWithFrameHandler:^(LFHostFrame *frame) {
          ++frameCount;
          if (frame.sequence == 1U) {
            firstFrame = frame;
            retainedFirstRaw = [frame.rawIndices copy];
            [session setInputButtons:0U];
            [session
                startSteadyUpdatesWithCompletion:^(BOOL success,
                                                    NSError *error) {
                  (void)error;
                  ++startCompletions;
                  steadyStarted = success;
                  if (!success) {
                    callbackFailed = YES;
                    [session stopWithCompletion:^{
                      dispatch_semaphore_signal(stopped);
                    }];
                  }
                }];
          } else if (frame.sequence == 2U) {
            snapshotStayedImmutable =
                retainedFirstRaw != nil &&
                [retainedFirstRaw isEqualToData:firstFrame.rawIndices];
            [session stopWithCompletion:^{
              dispatch_semaphore_signal(stopped);
            }];
          } else {
            callbackFailed = YES;
            [session stopWithCompletion:^{
              dispatch_semaphore_signal(stopped);
            }];
          }
        }
        callbackQueue:callbackQueue
                clock:clock
             observer:observer];
    if (session == nil) {
      return fail("session construction");
    }

    [session setInputButtons:UINT32_C(0x0001)];
    NSString *fixturePath = [NSString stringWithUTF8String:argv[1]];
    [session openContentAtPath:fixturePath
                    completion:^(BOOL success, NSError *error) {
                      ++openCompletions;
                      opened = success;
                      if (!success) {
                        (void)fprintf(stderr, "host_tracer: open error: %s\n",
                                      error.localizedDescription.UTF8String);
                        callbackFailed = YES;
                        [session stopWithCompletion:^{
                          dispatch_semaphore_signal(stopped);
                        }];
                      }
                    }];
    [session openContentAtPath:fixturePath
                    completion:^(BOOL success, NSError *error) {
                      ++openCompletions;
                      overlapRejected = !success &&
                          [error.domain isEqualToString:LFHostSessionErrorDomain] &&
                          error.code == LFHostSessionErrorInvalidRequest;
                      if (!overlapRejected) {
                        callbackFailed = YES;
                      }
                    }];

    if (dispatch_semaphore_wait(stopped, tracerDeadline) != 0) {
      [session stopWithCompletion:^{ dispatch_semaphore_signal(stopped); }];
      return fail("bounded stop");
    }
    dispatch_sync(callbackQueue, ^{});

    if (observerFailed || callbackFailed || !opened || !steadyStarted ||
        frameCount != 2U ||
        openCompletions != 2U || startCompletions != 1U || !overlapRejected ||
        startedCalls != 2U || finishedCalls != 2U || activeCalls != 0U ||
        maximumActiveCalls != 1U || destroyEvents != 1U ||
        firstSamples != LF_MUHTARI_ORACLE_FIRST_FRAME_SAMPLES ||
        steadySamples != LF_MUHTARI_ORACLE_STEADY_FRAME_SAMPLES ||
        firstCapacity != 801U || steadyCapacity != 801U ||
        !firstImageValid || !steadyImageValid || !firstPcmValid ||
        !steadyPcmValid || !snapshotStayedImmutable ||
        !contentReleasedBeforeAdvance) {
      if (firstFrame != nil && !firstImageValid) {
        const uint8_t *pixels = firstFrame.rawIndices.bytes;
        size_t mismatch = 0U;
        for (; mismatch < firstFrame.rawIndices.length; ++mismatch) {
          const size_t y = mismatch / 320U;
          const size_t x = mismatch % 320U;
          uint8_t expected = 0U;
          if (y == LF_MUHTARI_ORACLE_FIRST_BACKGROUND_ROW &&
              x >= LF_MUHTARI_ORACLE_FIRST_CHANGED_PIXEL) {
            expected = UINT8_C(0x11);
          } else if (y > LF_MUHTARI_ORACLE_FIRST_BACKGROUND_ROW) {
            expected = UINT8_C(0x11);
          }
          if (pixels[mismatch] != expected) {
            break;
          }
        }
        const size_t y = mismatch / 320U;
        const size_t x = mismatch % 320U;
        const uint8_t expected =
            (y == LF_MUHTARI_ORACLE_FIRST_BACKGROUND_ROW &&
             x >= LF_MUHTARI_ORACLE_FIRST_CHANGED_PIXEL) ||
                    y > LF_MUHTARI_ORACLE_FIRST_BACKGROUND_ROW
                ? UINT8_C(0x11)
                : UINT8_C(0x00);
        (void)fprintf(stderr,
                      "host_tracer: first image mismatch offset=%lu actual=%02x "
                      "expected=%02x\n",
                      (unsigned long)mismatch,
                      mismatch < firstFrame.rawIndices.length
                          ? pixels[mismatch]
                          : UINT8_C(0x00),
                      expected);
      }
      (void)fprintf(stderr,
                    "host_tracer: frames=%lu calls=%lu/%lu active=%lu "
                    "destroy=%lu samples=%lu,%lu capacity=%lu,%lu "
                    "startup=%d steady=%d pcm=%d,%d immutable=%d\n",
                    (unsigned long)frameCount, (unsigned long)startedCalls,
                    (unsigned long)finishedCalls, (unsigned long)activeCalls,
                    (unsigned long)destroyEvents, (unsigned long)firstSamples,
                    (unsigned long)steadySamples, (unsigned long)firstCapacity,
                    (unsigned long)steadyCapacity, firstImageValid,
                    steadyImageValid, firstPcmValid, steadyPcmValid,
                    snapshotStayedImmutable);
      return EXIT_FAILURE;
    }

    if (verify_metadata_sessions(fixturePath, callbackQueue,
                                 tracerDeadline) != 0) {
      return EXIT_FAILURE;
    }

    (void)printf("host_tracer: profile=muhtari-ntsc-v1 startup=partial "
                 "steady=pass pcm=pass immutable=pass capacity=801 "
                 "serialized=pass overlap=pass ownership=pass destroy=once result=pass\n");
    return EXIT_SUCCESS;
  }
}
