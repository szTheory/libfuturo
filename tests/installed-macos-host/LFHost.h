/* SPDX-License-Identifier: MIT */
#ifndef LIBFUTURO_INSTALLED_MACOS_HOST_LFHOST_H
#define LIBFUTURO_INSTALLED_MACOS_HOST_LFHOST_H

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import "LFDisplayAdapter.h"

#include <stddef.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

@class LFAudioOutput;

@interface LFHostFrame : NSObject
@property(nonatomic, readonly) uint64_t generation;
@property(nonatomic, readonly) uint64_t sequence;
@property(nonatomic, readonly) NSUInteger audioProducedSamples;
@property(nonatomic, copy, readonly) NSData *rawIndices;
@property(nonatomic, strong, readonly) LFDisplaySurface *displaySurface;
- (instancetype)initWithGeneration:(uint64_t)generation
                           sequence:(uint64_t)sequence
               audioProducedSamples:(NSUInteger)audioProducedSamples
                         rawIndices:(NSData *)rawIndices
                  displaySurface:(LFDisplaySurface *)displaySurface;
@end

typedef void (^LFHostFrameHandler)(LFHostFrame *frame);
typedef void (^LFHostCompletion)(BOOL success, NSError *_Nullable error);
typedef void (^LFHostStopCompletion)(void);
typedef uint64_t (^LFHostClock)(void);

FOUNDATION_EXPORT NSString *const LFHostSessionErrorDomain;
FOUNDATION_EXPORT NSString *const LFHostSessionCoreStatusKey;
typedef NS_ENUM(NSInteger, LFHostSessionErrorCode) {
  LFHostSessionErrorInvalidRequest = 1,
  LFHostSessionErrorProfile = 2,
  LFHostSessionErrorReader = 3,
  LFHostSessionErrorCreate = 4,
  LFHostSessionErrorLoad = 5,
  LFHostSessionErrorOutputAllocation = 6,
  LFHostSessionErrorAdvance = 7,
  LFHostSessionErrorScheduler = 8,
};

typedef NS_ENUM(NSUInteger, LFHostSessionEvent) {
  LFHostSessionEventAdvanceStarted = 1,
  LFHostSessionEventAdvanceFinished = 2,
  LFHostSessionEventInstanceDestroyed = 3,
  LFHostSessionEventContentReleased = 4,
  LFHostSessionEventInstanceCreated = 5,
  LFHostSessionEventLoadStarted = 6,
  LFHostSessionEventLoadFinished = 7,
  LFHostSessionEventOutputBuffersAllocated = 8,
  LFHostSessionEventLoadAccepted = 9,
  LFHostSessionEventInputSampled = 10,
  LFHostSessionEventCoreAdvanceStarted = 11,
  LFHostSessionEventOutputBuffersReleased = 12,
  LFHostSessionEventFrameInvalidationScheduled = 13,
};

typedef void (^LFHostSessionObserver)(LFHostSessionEvent event,
                                      LFHostFrame *_Nullable frame,
                                      NSData *_Nullable audioSamples,
                                      NSUInteger audioCapacitySamples,
                                      uint32_t inputButtons);
typedef void * _Nullable (^LFHostOutputAllocator)(size_t count, size_t size);

/* Private installed-host contract. Frames are immutable owned snapshots.
   Observer calls run on the session's serial core-owner queue; frame handlers
   and completions run on the configured callback queue. */
@interface LFHostSession : NSObject
@property(nonatomic, copy) LFHostFrameHandler frameHandler;
- (instancetype)initWithFrameHandler:(LFHostFrameHandler)frameHandler;
- (instancetype)initWithFrameHandler:(LFHostFrameHandler)frameHandler
                       callbackQueue:(dispatch_queue_t)callbackQueue
                               clock:(nullable LFHostClock)clock
                            observer:(nullable LFHostSessionObserver)observer;
- (instancetype)initWithFrameHandler:(LFHostFrameHandler)frameHandler
                       callbackQueue:(dispatch_queue_t)callbackQueue
                               clock:(nullable LFHostClock)clock
                            observer:(nullable LFHostSessionObserver)observer
                     outputAllocator:(nullable LFHostOutputAllocator)outputAllocator;
- (instancetype)initWithFrameHandler:(LFHostFrameHandler)frameHandler
                       callbackQueue:(dispatch_queue_t)callbackQueue
                               clock:(nullable LFHostClock)clock
                            observer:(nullable LFHostSessionObserver)observer
                     outputAllocator:(nullable LFHostOutputAllocator)outputAllocator
                         audioOutput:(nullable LFAudioOutput *)audioOutput;
/* Thread-safe publication; the serial owner reads the latest mask before
   each lf_set_input/lf_advance pair. */
- (void)setInputButtons:(uint32_t)buttons;
/* Mute output at the engine mixer without stopping guest work or scheduling. */
- (void)setAudioMuted:(BOOL)muted;
- (void)openContentAtPath:(NSString *)path completion:(LFHostCompletion)completion;
- (void)startSteadyUpdatesWithCompletion:(LFHostCompletion)completion;
- (void)stopWithCompletion:(nullable LFHostStopCompletion)completion;
@end

NS_ASSUME_NONNULL_END

#endif
