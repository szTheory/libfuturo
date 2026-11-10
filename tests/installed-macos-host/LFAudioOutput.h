/* SPDX-License-Identifier: MIT */
#ifndef LIBFUTURO_INSTALLED_MACOS_HOST_LFAUDIOOUTPUT_H
#define LIBFUTURO_INSTALLED_MACOS_HOST_LFAUDIOOUTPUT_H

#import <AVFAudio/AVFAudio.h>
#import <Foundation/Foundation.h>

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (^LFAudioLockFreeCheckOverride)(NSUInteger index,
                                            BOOL actualLockFree);

typedef struct LFAudioOutputEvidence {
  double outputSampleRate;
  uint32_t outputChannels;
  uint64_t dataPlayedBackCount;
  uint64_t outstandingBuffers;
  uint64_t pendingCallbacks;
  uint64_t droppedPackets;
  uint64_t primeDelayMilliseconds;
  bool lockFree;
  bool outputFormatValid;
  bool playerStopped;
  bool engineStopped;
  bool callbacksQuiescent;
} LFAudioOutputEvidence;

/* Host-private AVFAudio wrapper. All scheduling/start/stop calls are made on
   the LFHostSession owner queue. Completion handlers only update the C pool. */
@interface LFAudioOutput : NSObject
@property(nonatomic, readonly, getter=isMuted) BOOL muted;
- (instancetype)initWithManualRendering:(BOOL)manualRendering
                requirePlaybackEvidence:(BOOL)requirePlaybackEvidence
                 lockFreeCheckOverride:(nullable LFAudioLockFreeCheckOverride)override;
- (void)setMuted:(BOOL)muted;
- (BOOL)scheduleSamples:(const int16_t *)samples
                  count:(size_t)sampleCount;
- (BOOL)startManualRendering;
- (BOOL)renderManualFrames:(AVAudioFrameCount)frameCount
                  toBuffer:(AVAudioPCMBuffer *)buffer
                     error:(NSError * _Nullable * _Nullable)error;
- (void)disarm;
- (BOOL)stop;
- (BOOL)hasDataPlayedBack;
- (LFAudioOutputEvidence)evidence;
- (nullable NSString *)liveEvidenceMarker;
- (AVAudioFormat *)sourceFormat;
- (AVAudioFormat *)engineFormat;
- (BOOL)playerStoppedPostconditionForIsPlaying:(BOOL)isPlaying;
- (BOOL)engineStoppedPostconditionForIsRunning:(BOOL)isRunning;
@end

NS_ASSUME_NONNULL_END

#endif
