/* SPDX-License-Identifier: MIT */
#import "LFAudioOutput.h"

#include "LFAudioBufferPool.h"

#include <math.h>
#include <sched.h>
#include <time.h>

static NSString *const LFAudioOutputErrorDomain =
    @"org.libfuturo.installed-host.audio";
static const NSUInteger LFAudioOutputPoolPrimeCount = 3U;
static const double LFAudioOutputSampleRate = 48000.0;

static NSError *lf_audio_error(void) {
  return [NSError errorWithDomain:LFAudioOutputErrorDomain
                             code:1
                         userInfo:@{
                           NSLocalizedDescriptionKey :
                               @"The native audio output could not be started or stopped.",
                         }];
}

static uint64_t lf_audio_monotonic_nanoseconds(void) {
  struct timespec now = {0, 0};
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0 || now.tv_sec < 0 ||
      now.tv_nsec < 0) {
    return 0U;
  }
  return (uint64_t)now.tv_sec * UINT64_C(1000000000) +
         (uint64_t)now.tv_nsec;
}

@interface LFAudioOutputCallbackState : NSObject {
@public
  lf_audio_buffer_pool pool;
}
@end

@implementation LFAudioOutputCallbackState
@end

@implementation LFAudioOutput {
  AVAudioEngine *_engine;
  AVAudioPlayerNode *_player;
  AVAudioFormat *_sourceFormat;
  AVAudioFormat *_engineFormat;
  NSMutableArray<AVAudioPCMBuffer *> *_buffers;
  LFAudioOutputCallbackState *_callbackState;
  LFAudioLockFreeCheckOverride _lockFreeCheckOverride;
  BOOL _manualRendering;
  BOOL _requirePlaybackEvidence;
  BOOL _atomicsChecked;
  BOOL _lockFree;
  BOOL _started;
  BOOL _stopped;
  BOOL _muted;
  float _unmutedOutputVolume;
  BOOL _playerStopped;
  BOOL _engineStopped;
  BOOL _callbacksQuiescent;
  BOOL _outputFormatValid;
  BOOL _playbackMarkerScheduled;
  double _outputSampleRate;
  uint32_t _outputChannels;
  NSUInteger _buffersScheduled;
  uint64_t _firstScheduledNanoseconds;
  uint64_t _engineStartedNanoseconds;
  NSError *_constructionError;
}

- (instancetype)initWithManualRendering:(BOOL)manualRendering
                requirePlaybackEvidence:(BOOL)requirePlaybackEvidence
                 lockFreeCheckOverride:(LFAudioLockFreeCheckOverride)override {
  self = [super init];
  if (self == nil) {
    return nil;
  }
  _manualRendering = manualRendering;
  _requirePlaybackEvidence = requirePlaybackEvidence;
  _lockFreeCheckOverride = [override copy];
  _callbackState = [[LFAudioOutputCallbackState alloc] init];
  if (!lf_audio_buffer_pool_init(&_callbackState->pool)) {
    _constructionError = lf_audio_error();
    return self;
  }

  _sourceFormat = [[AVAudioFormat alloc]
      initWithCommonFormat:AVAudioPCMFormatInt16
               sampleRate:LFAudioOutputSampleRate
                 channels:1U
              interleaved:YES];
  if (_sourceFormat == nil) {
    _constructionError = lf_audio_error();
    return self;
  }
  // AVAudioEngine's player-to-mixer graph uses Float32 PCM in both live and
  // offline modes. Keep S16 at the core boundary and convert before scheduling.
  _engineFormat = [[AVAudioFormat alloc]
      initWithCommonFormat:AVAudioPCMFormatFloat32
               sampleRate:LFAudioOutputSampleRate
                 channels:1U
              interleaved:NO];
  if (_engineFormat == nil) {
    _constructionError = lf_audio_error();
    return self;
  }
  _engine = [[AVAudioEngine alloc] init];
  _player = [[AVAudioPlayerNode alloc] init];
  _buffers = [[NSMutableArray alloc]
      initWithCapacity:LF_AUDIO_BUFFER_POOL_CAPACITY];
  if (_engine == nil || _player == nil || _buffers == nil) {
    _constructionError = lf_audio_error();
    return self;
  }

  [_engine attachNode:_player];
  if (_manualRendering &&
      ![_engine enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline
                                   format:_engineFormat
                        maximumFrameCount:
                            (AVAudioFrameCount)LF_AUDIO_BUFFER_POOL_MAX_FRAMES
                                     error:nil]) {
    _constructionError = lf_audio_error();
    return self;
  }
  [_engine connect:_player
                to:_engine.mainMixerNode
            format:_engineFormat];
  for (NSUInteger index = 0U; index < LF_AUDIO_BUFFER_POOL_CAPACITY; ++index) {
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc]
        initWithPCMFormat:_engineFormat
             frameCapacity:(AVAudioFrameCount)LF_AUDIO_BUFFER_POOL_MAX_FRAMES];
    if (buffer == nil || buffer.floatChannelData == NULL ||
        buffer.floatChannelData[0] == NULL) {
      _constructionError = lf_audio_error();
      return self;
    }
    [_buffers addObject:buffer];
  }
  return self;
}

- (BOOL)isMuted {
  return _muted;
}

- (void)setMuted:(BOOL)muted {
  if (_engine == nil || _constructionError != nil || _stopped ||
      _muted == muted) {
    return;
  }
  AVAudioMixerNode *mainMixer = _engine.mainMixerNode;
  if (mainMixer == nil) {
    return;
  }
  if (muted) {
    _unmutedOutputVolume = mainMixer.outputVolume;
    mainMixer.outputVolume = 0.0F;
    _muted = YES;
    return;
  }
  mainMixer.outputVolume = _unmutedOutputVolume;
  _muted = NO;
}

- (BOOL)checkCallbackAtomics {
  if (_atomicsChecked) {
    return _lockFree;
  }
  BOOL allLockFree = YES;
  const size_t count = lf_audio_buffer_pool_callback_atomic_count();
  for (size_t index = 0U; index < count; ++index) {
    const BOOL actual =
        lf_audio_buffer_pool_callback_atomic_is_lock_free(
            &_callbackState->pool, index)
            ? YES
            : NO;
    const BOOL accepted = _lockFreeCheckOverride != nil
                              ? _lockFreeCheckOverride((NSUInteger)index, actual)
                              : actual;
    if (!accepted) {
      allLockFree = NO;
    }
  }
  _atomicsChecked = YES;
  _lockFree = allLockFree;
  return _lockFree;
}

- (BOOL)startEngineAndPlayer {
  if (_constructionError != nil || _stopped || _engine == nil ||
      _player == nil || ![self checkCallbackAtomics]) {
    if (_constructionError == nil) {
      _constructionError = lf_audio_error();
    }
    return NO;
  }
  if (_started) {
    return YES;
  }
  if (!_engine.isRunning) {
    [_engine prepare];
    if (![_engine startAndReturnError:nil]) {
      _constructionError = lf_audio_error();
      return NO;
    }
  }
  if (!_manualRendering) {
    AVAudioFormat *outputFormat = [_engine.outputNode outputFormatForBus:0U];
    if (outputFormat == nil || !isfinite(outputFormat.sampleRate) ||
        outputFormat.sampleRate <= 0.0 || outputFormat.channelCount == 0U) {
      [_engine stop];
      _constructionError = lf_audio_error();
      return NO;
    }
    _outputSampleRate = outputFormat.sampleRate;
    _outputChannels = outputFormat.channelCount;
    _outputFormatValid = YES;

    // startAndReturnError starts the device, but the first device render can
    // arrive afterward. AVAudioPlayerNode.play may throw until that I/O cycle
    // has occurred, so keep the primed buffers queued and retry on the next
    // guest audio submission after the output node publishes a render time.
    AVAudioTime *outputRenderTime = _engine.outputNode.lastRenderTime;
    if (outputRenderTime == nil || !outputRenderTime.isSampleTimeValid) {
      return YES;
    }
  }
  if (_muted) {
    _engine.mainMixerNode.outputVolume = 0.0F;
  }
  @try {
    [_player play];
  } @catch (NSException *exception) {
    _constructionError = [NSError
        errorWithDomain:LFAudioOutputErrorDomain
                   code:2
               userInfo:@{
                 NSLocalizedDescriptionKey :
                     exception.reason.length > 0U ? exception.reason
                                                 : @"The audio player could not start.",
               }];
    [_engine stop];
    return NO;
  }
  _engineStartedNanoseconds = lf_audio_monotonic_nanoseconds();
  _started = YES;
  return YES;
}

- (BOOL)scheduleSamples:(const int16_t *)samples count:(size_t)sampleCount {
  if (sampleCount == 0U) {
    return YES;
  }
  if (_stopped || _constructionError != nil || samples == NULL ||
      sampleCount > LF_AUDIO_BUFFER_POOL_MAX_FRAMES ||
      _callbackState == nil || _player == nil) {
    return NO;
  }

  if (!lf_audio_buffer_pool_schedule_begin(&_callbackState->pool)) {
    return NO;
  }

  lf_audio_buffer_token token = {0U, 0U, 0U};
  const lf_audio_buffer_claim_result claim = lf_audio_buffer_pool_claim(
      &_callbackState->pool, sampleCount, &token);
  if (claim == LF_AUDIO_BUFFER_DROPPED) {
    lf_audio_buffer_pool_schedule_end(&_callbackState->pool);
    if (!_manualRendering && !_started &&
        _buffersScheduled >= LFAudioOutputPoolPrimeCount &&
        ![self startEngineAndPlayer]) {
      return NO;
    }
    return YES;
  }
  if (claim != LF_AUDIO_BUFFER_CLAIMED) {
    lf_audio_buffer_pool_schedule_end(&_callbackState->pool);
    return NO;
  }

  AVAudioPCMBuffer *buffer = _buffers[token.slot];
  float *output = buffer.floatChannelData[0];
  for (size_t index = 0U; index < sampleCount; ++index) {
    output[index] = (float)samples[index] / 32768.0F;
  }
  buffer.frameLength = (AVAudioFrameCount)sampleCount;

  const BOOL observePlayback =
      _requirePlaybackEvidence && !_playbackMarkerScheduled;
  const AVAudioPlayerNodeCompletionCallbackType callbackType =
      observePlayback ? AVAudioPlayerNodeCompletionDataPlayedBack
                      : AVAudioPlayerNodeCompletionDataConsumed;
  LFAudioOutputCallbackState *callbackState = _callbackState;
  lf_audio_buffer_pool_callback_scheduled(&callbackState->pool);
  [_player scheduleBuffer:buffer
                   atTime:nil
                  options:0U
    completionCallbackType:callbackType
          completionHandler:^(
              AVAudioPlayerNodeCompletionCallbackType completedType) {
            (void)completedType;
            if (lf_audio_buffer_pool_callback_begin(&callbackState->pool)) {
              (void)lf_audio_buffer_pool_retire(&callbackState->pool, token,
                                                observePlayback);
              lf_audio_buffer_pool_callback_end(&callbackState->pool);
            }
            lf_audio_buffer_pool_callback_finished(&callbackState->pool);
          }];
  lf_audio_buffer_pool_schedule_end(&_callbackState->pool);

  if (observePlayback) {
    _playbackMarkerScheduled = YES;
  }
  if (_firstScheduledNanoseconds == 0U) {
    _firstScheduledNanoseconds = lf_audio_monotonic_nanoseconds();
  }
  ++_buffersScheduled;
  if (!_manualRendering && !_started &&
      _buffersScheduled >= LFAudioOutputPoolPrimeCount &&
      ![self startEngineAndPlayer]) {
    return NO;
  }
  return YES;
}

- (BOOL)startManualRendering {
  if (!_manualRendering) {
    return NO;
  }
  return [self startEngineAndPlayer];
}

- (BOOL)renderManualFrames:(AVAudioFrameCount)frameCount
                  toBuffer:(AVAudioPCMBuffer *)buffer
                     error:(NSError **)error {
  if (!_manualRendering || !_started || buffer == nil ||
      frameCount == 0U || frameCount > buffer.frameCapacity ||
      frameCount > LF_AUDIO_BUFFER_POOL_MAX_FRAMES) {
    if (error != NULL) {
      *error = lf_audio_error();
    }
    return NO;
  }
  const AVAudioEngineManualRenderingStatus status =
      [_engine renderOffline:frameCount toBuffer:buffer error:error];
  return status == AVAudioEngineManualRenderingStatusSuccess;
}

- (void)disarm {
  if (_callbackState != nil) {
    lf_audio_buffer_pool_disarm(&_callbackState->pool);
  }
}

- (BOOL)stop {
  if (_stopped) {
    return _playerStopped && _engineStopped && _callbacksQuiescent;
  }
  [self disarm];
  if (_player != nil) {
    [_player stop];
    _playerStopped = [self playerStoppedPostconditionForIsPlaying:
                                 _player.isPlaying];
  } else {
    _playerStopped = YES;
  }
  if (_engine != nil) {
    [_engine stop];
    _engineStopped = [self engineStoppedPostconditionForIsRunning:
                                 _engine.isRunning];
  } else {
    _engineStopped = YES;
  }

  if (_callbackState != nil) {
    lf_audio_buffer_pool_disable_callbacks(&_callbackState->pool);
    while (lf_audio_buffer_pool_callbacks_pending(
               &_callbackState->pool) != 0U ||
           lf_audio_buffer_pool_callbacks_in_flight(
               &_callbackState->pool) != 0U) {
      (void)sched_yield();
    }
    _callbacksQuiescent = lf_audio_buffer_pool_reconcile_stopped(
        &_callbackState->pool);
  } else {
    _callbacksQuiescent = YES;
  }
  _stopped = YES;
  return _playerStopped && _engineStopped && _callbacksQuiescent;
}

- (BOOL)hasDataPlayedBack {
  return _callbackState != nil &&
         lf_audio_buffer_pool_data_played_back(&_callbackState->pool) > 0U;
}

- (LFAudioOutputEvidence)evidence {
  LFAudioOutputEvidence result = {
      .outputSampleRate = 0.0,
      .outputChannels = 0U,
      .dataPlayedBackCount = 0U,
      .outstandingBuffers = 0U,
      .pendingCallbacks = 0U,
      .droppedPackets = 0U,
      .primeDelayMilliseconds = 0U,
      .lockFree = false,
      .outputFormatValid = false,
      .playerStopped = false,
      .engineStopped = false,
      .callbacksQuiescent = false,
  };
  if (_callbackState != nil) {
    result.dataPlayedBackCount = (uint64_t)lf_audio_buffer_pool_data_played_back(
        &_callbackState->pool);
    result.outstandingBuffers =
        (uint64_t)lf_audio_buffer_pool_outstanding(&_callbackState->pool);
    result.pendingCallbacks =
        (uint64_t)lf_audio_buffer_pool_callbacks_pending(&_callbackState->pool);
    result.droppedPackets =
        (uint64_t)lf_audio_buffer_pool_dropped_packets(&_callbackState->pool);
  }
  result.outputSampleRate = _outputSampleRate;
  result.outputChannels = _outputChannels;
  if (_firstScheduledNanoseconds != 0U &&
      _engineStartedNanoseconds >= _firstScheduledNanoseconds) {
    result.primeDelayMilliseconds =
        (_engineStartedNanoseconds - _firstScheduledNanoseconds) /
        UINT64_C(1000000);
  }
  result.lockFree = _atomicsChecked && _lockFree;
  result.outputFormatValid = _outputFormatValid;
  result.playerStopped = _playerStopped;
  result.engineStopped = _engineStopped;
  result.callbacksQuiescent = _callbacksQuiescent;
  return result;
}

- (NSString *)liveEvidenceMarker {
  const LFAudioOutputEvidence result = [self evidence];
  if (!_stopped || !result.lockFree || !result.outputFormatValid ||
      result.outputSampleRate <= 0.0 || result.outputChannels == 0U ||
      result.dataPlayedBackCount == 0U || !result.playerStopped ||
      !result.engineStopped || !result.callbacksQuiescent) {
    return nil;
  }
  return [NSString
      stringWithFormat:
          @"installed_macos_host: audio=system source=s16-native,mono,48000 "
           "output-rate=%.0f output-channels=%u dataPlayedBack=%llu "
           "pool-drops=%llu prime-delay-ms=%llu player-stopped=true "
           "engine-stopped=true result=pass\n",
          result.outputSampleRate, result.outputChannels,
          (unsigned long long)result.dataPlayedBackCount,
          (unsigned long long)result.droppedPackets,
          (unsigned long long)result.primeDelayMilliseconds];
}

- (AVAudioFormat *)sourceFormat {
  return _sourceFormat;
}

- (AVAudioFormat *)engineFormat {
  return _engineFormat;
}

- (BOOL)playerStoppedPostconditionForIsPlaying:(BOOL)isPlaying {
  return !isPlaying;
}

- (BOOL)engineStoppedPostconditionForIsRunning:(BOOL)isRunning {
  return !isRunning;
}

@end
