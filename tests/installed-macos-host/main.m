/* SPDX-License-Identifier: MIT */

#import "LFHost.h"
#import "LFInputState.h"
#import "LFAudioOutput.h"

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static NSString *lf_test_result_path = nil;
static NSString *lf_test_progress_path = nil;
static BOOL lf_test_panel_flow = NO;
static BOOL lf_test_cli_retry = NO;
static BOOL lf_test_scheduler_retry = NO;
static BOOL lf_test_production_view = NO;
static BOOL lf_test_production_view_passed = NO;
static LFAudioOutput *lf_live_audio_output = nil;

static const char *lf_production_view_marker =
    "installed_macos_host: production-view=LFHostView input=port0-fire "
    "startup-rgb=pass geometry=320:242,fit,letterbox "
    "capture=backing-rgba controls=rgb,geometry result=pass\n";

typedef enum {
  LFProductionViewMatch = 0,
  LFProductionViewRGBMismatch = 1,
  LFProductionViewGeometryMismatch = 2,
} LFProductionViewResult;

typedef struct {
  CGRect bounds;
  CGRect videoFrame;
  CGFloat backingScale;
  size_t pixelWidth;
  size_t pixelHeight;
  size_t bytesPerRow;
  NSData *rgbaBytes;
  BOOL geometryFlipped;
  BOOL nearestFilters;
} LFProductionViewCapture;

typedef NS_ENUM(NSUInteger, LFHostTestDrainMode) {
  LFHostTestDrainModeNone = 0,
  LFHostTestDrainModeWindowClose = 1,
  LFHostTestDrainModeTerminate = 2,
  LFHostTestDrainModeLoadErrorClose = 3,
};

typedef NS_ENUM(NSUInteger, LFHostContentFeedbackState) {
  LFHostContentFeedbackUninitialized = 0,
  LFHostContentFeedbackNoContent = 1,
  LFHostContentFeedbackOpening = 2,
  LFHostContentFeedbackReady = 3,
};

static LFHostTestDrainMode lf_test_drain_mode = LFHostTestDrainModeNone;

static BOOL lf_write_test_result(NSString *path);
static void lf_append_test_progress(NSString *line);
static const char *lf_test_result_marker(void);
static void lf_append_test_progress(NSString *line);

@interface LFHostView : LFInputView
@property(nonatomic, copy) void (^presentationHandler)(LFHostFrame *frame);
@property(nonatomic, readonly) uint64_t completedPresentations;
- (void)showFrame:(LFHostFrame *)frame;
- (void)clearFrame;
- (CGRect)videoFrame;
- (BOOL)captureProductionViewForFrame:(LFHostFrame *)frame
                              result:(LFProductionViewCapture *)capture;
@end

@implementation LFHostView {
  LFHostFrame *_frame;
  CALayer *_videoLayer;
  uint64_t _completedPresentations;
  uint64_t _lastPresentedGeneration;
  uint64_t _lastPresentedSequence;
}
- (BOOL)wantsUpdateLayer {
  return YES;
}
- (BOOL)isOpaque {
  return YES;
}
- (CALayer *)makeBackingLayer {
  CALayer *backingLayer = [CALayer layer];
  backingLayer.backgroundColor = NSColor.blackColor.CGColor;
  backingLayer.masksToBounds = YES;
  _videoLayer = [CALayer layer];
  _videoLayer.contentsGravity = kCAGravityResize;
  _videoLayer.magnificationFilter = kCAFilterNearest;
  _videoLayer.minificationFilter = kCAFilterNearest;
  _videoLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
  [backingLayer addSublayer:_videoLayer];
  return backingLayer;
}
- (void)layout {
  [super layout];
  [self updateVideoGeometry];
}
- (void)viewDidChangeBackingProperties {
  [super viewDidChangeBackingProperties];
  [self updateVideoGeometry];
}
- (void)updateVideoGeometry {
  if (self.layer == nil) {
    return;
  }
  const CGFloat backingScale = self.window != nil
                                   ? self.window.backingScaleFactor
                                   : self.layer.contentsScale;
  self.layer.contentsScale = backingScale > 0.0 ? backingScale : 1.0;
  _videoLayer.contentsScale = self.layer.contentsScale;
  _videoLayer.frame = [LFDisplayAdapter
      destinationRectForBounds:self.layer.bounds
                  backingScale:self.layer.contentsScale];
  if (_frame != nil) {
    [self updateLayer];
  }
}
- (void)showFrame:(LFHostFrame *)frame {
  if (![NSThread isMainThread] || frame == nil) {
    return;
  }
  _frame = frame;
  if ((lf_test_panel_flow || lf_test_cli_retry) && frame.sequence <= 3U) {
    lf_append_test_progress([NSString
        stringWithFormat:@"view-frame: generation=%llu sequence=%llu\n",
                             (unsigned long long)frame.generation,
                             (unsigned long long)frame.sequence]);
  }
  [self setNeedsDisplay:YES];
  [self updateLayer];
}
- (void)clearFrame {
  _frame = nil;
  _videoLayer.contents = nil;
  [self setNeedsDisplay:YES];
}
- (CGRect)videoFrame {
  return _videoLayer.frame;
}
- (void)updateLayer {
  if (_frame == nil || _frame.displaySurface.rgbaBytes.length !=
                            (NSUInteger)(LFDisplayWidth * LFDisplayHeight *
                                         LFDisplayBytesPerPixel)) {
    return;
  }
  CGImageRef image =
      [LFDisplayAdapter copyCGImageForSurface:_frame.displaySurface];
  if (image == NULL) {
    return;
  }
  __weak LFHostView *weakSelf = self;
  LFHostFrame *frame = _frame;
  [CATransaction begin];
  [CATransaction setCompletionBlock:^{
    dispatch_async(dispatch_get_main_queue(), ^{
      LFHostView *strongSelf = weakSelf;
      if (strongSelf == nil ||
          strongSelf->_frame.generation != frame.generation ||
          strongSelf.window == nil || !strongSelf.window.isVisible ||
          strongSelf->_videoLayer.contents == nil) {
        return;
      }
      if (frame.generation < strongSelf->_lastPresentedGeneration ||
          (strongSelf->_lastPresentedGeneration == frame.generation &&
           frame.sequence <= strongSelf->_lastPresentedSequence)) {
        return;
      }
      strongSelf->_lastPresentedGeneration = frame.generation;
      strongSelf->_lastPresentedSequence = frame.sequence;
      ++strongSelf->_completedPresentations;
      if ((lf_test_panel_flow || lf_test_cli_retry) &&
          strongSelf->_completedPresentations <= 3U) {
        lf_append_test_progress([NSString
            stringWithFormat:@"presentation: count=%llu generation=%llu sequence=%llu\n",
                                 (unsigned long long)strongSelf->_completedPresentations,
                                 (unsigned long long)frame.generation,
                                 (unsigned long long)frame.sequence]);
      }
      if (strongSelf.presentationHandler != nil) {
        strongSelf.presentationHandler(frame);
      }
    });
  }];
  _videoLayer.contents = (__bridge id)image;
  [CATransaction commit];
  CGImageRelease(image);
  if ((lf_test_panel_flow || lf_test_cli_retry) && frame.sequence <= 3U) {
    lf_append_test_progress([NSString
        stringWithFormat:@"layer-set: generation=%llu sequence=%llu\n",
                             (unsigned long long)frame.generation,
                             (unsigned long long)frame.sequence]);
  }
}
- (uint64_t)completedPresentations {
  return _completedPresentations;
}
- (BOOL)captureProductionViewForFrame:(LFHostFrame *)frame
                              result:(LFProductionViewCapture *)capture {
  if (![NSThread isMainThread] || frame == nil || capture == NULL ||
      self.window == nil || !self.window.isVisible || self.hidden ||
      self.layer == nil || _videoLayer == nil ||
      _videoLayer.superlayer != self.layer || _videoLayer.contents == nil ||
      _frame != frame || frame.generation == 0U || frame.sequence == 0U ||
      _lastPresentedGeneration != frame.generation ||
      _lastPresentedSequence != frame.sequence) {
    return NO;
  }

  const CGRect bounds = self.layer.bounds;
  const CGFloat backingScale = self.window.backingScaleFactor;
  if (!isfinite(bounds.origin.x) || !isfinite(bounds.origin.y) ||
      !isfinite(bounds.size.width) || !isfinite(bounds.size.height) ||
      !isfinite(backingScale) || backingScale <= 0.0 ||
      bounds.size.width <= 0.0 || bounds.size.height <= 0.0 ||
      CGRectIsEmpty(_videoLayer.frame) ||
      !isfinite(_videoLayer.frame.origin.x) ||
      !isfinite(_videoLayer.frame.origin.y) ||
      !isfinite(_videoLayer.frame.size.width) ||
      !isfinite(_videoLayer.frame.size.height)) {
    return NO;
  }

  const double pixelWidthValue =
      ceil((double)bounds.size.width * backingScale);
  const double pixelHeightValue =
      ceil((double)bounds.size.height * backingScale);
  if (!isfinite(pixelWidthValue) || !isfinite(pixelHeightValue) ||
      pixelWidthValue < 1.0 || pixelHeightValue < 1.0 ||
      pixelWidthValue > 4096.0 || pixelHeightValue > 4096.0) {
    return NO;
  }
  const size_t pixelWidth = (size_t)pixelWidthValue;
  const size_t pixelHeight = (size_t)pixelHeightValue;
  if (pixelWidth > SIZE_MAX / 4U ||
      pixelHeight > SIZE_MAX / (pixelWidth * 4U)) {
    return NO;
  }
  const size_t bytesPerRow = pixelWidth * 4U;
  const size_t byteCount = bytesPerRow * pixelHeight;
  if (byteCount > 64U * 1024U * 1024U) {
    return NO;
  }

  NSMutableData *pixels = [NSMutableData dataWithLength:byteCount];
  if (pixels == nil) {
    return NO;
  }
  CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  if (colorSpace == NULL) {
    return NO;
  }
  const CGBitmapInfo bitmapInfo =
      (CGBitmapInfo)kCGBitmapByteOrder32Big |
      (CGBitmapInfo)kCGImageAlphaPremultipliedLast;
  CGContextRef context = CGBitmapContextCreate(
      pixels.mutableBytes, pixelWidth, pixelHeight, 8U, bytesPerRow,
      colorSpace, bitmapInfo);
  CGColorSpaceRelease(colorSpace);
  if (context == NULL) {
    return NO;
  }

  CGContextSetInterpolationQuality(context, kCGInterpolationNone);
  CGContextTranslateCTM(context, 0.0, (CGFloat)pixelHeight);
  CGContextScaleCTM(context, backingScale, -backingScale);
  CGContextTranslateCTM(context, -bounds.origin.x, -bounds.origin.y);
  [self.layer renderInContext:context];
  CGContextFlush(context);
  CGContextRelease(context);

  capture->bounds = bounds;
  capture->videoFrame = _videoLayer.frame;
  capture->backingScale = backingScale;
  capture->pixelWidth = pixelWidth;
  capture->pixelHeight = pixelHeight;
  capture->bytesPerRow = bytesPerRow;
  capture->rgbaBytes = [pixels copy];
  capture->geometryFlipped = self.layer.geometryFlipped;
  capture->nearestFilters =
      [_videoLayer.magnificationFilter isEqualToString:kCAFilterNearest] &&
      [_videoLayer.minificationFilter isEqualToString:kCAFilterNearest];
  return capture->rgbaBytes.length == byteCount;
}
@end

static BOOL lf_production_pixel_offset_at_source_position(
    const LFProductionViewCapture *capture, CGFloat sourceX, CGFloat sourceY,
    size_t *offset) {
  if (capture == NULL || capture->rgbaBytes == nil || offset == NULL ||
      !isfinite(sourceX) || !isfinite(sourceY) || sourceX < 0.0 ||
      sourceY < 0.0 || sourceX >= 320.0 || sourceY >= 242.0 ||
      capture->backingScale <= 0.0 || CGRectIsEmpty(capture->videoFrame)) {
    return NO;
  }
  const CGFloat pointX = capture->videoFrame.origin.x +
      (sourceX * capture->videoFrame.size.width / 320.0);
  const CGFloat sourceProgress = sourceY / 242.0;
  const CGFloat pointY = capture->geometryFlipped
      ? capture->videoFrame.origin.y + sourceProgress * capture->videoFrame.size.height
      : capture->videoFrame.origin.y +
            (1.0 - sourceProgress) * capture->videoFrame.size.height;
  const CGFloat pixelXValue = floor((pointX - capture->bounds.origin.x) *
                                    capture->backingScale);
  /* The backing bitmap's first memory row is the bottom row in Quartz. */
  const CGFloat pixelYValue = floor(
      (capture->geometryFlipped
           ? capture->bounds.origin.y + capture->bounds.size.height - pointY
           : pointY - capture->bounds.origin.y) *
      capture->backingScale);
  if (!isfinite(pixelXValue) || !isfinite(pixelYValue) ||
      pixelXValue < 0.0 || pixelYValue < 0.0 ||
      pixelXValue >= (CGFloat)capture->pixelWidth ||
      pixelYValue >= (CGFloat)capture->pixelHeight) {
    return NO;
  }
  const size_t pixelX = (size_t)pixelXValue;
  const size_t pixelY = (size_t)pixelYValue;
  if (pixelY > SIZE_MAX / capture->bytesPerRow) {
    return NO;
  }
  *offset = pixelY * capture->bytesPerRow + pixelX * 4U;
  return *offset <= capture->rgbaBytes.length - 4U;
}

static BOOL lf_production_pixel_offset(const LFProductionViewCapture *capture,
                                      uint32_t sourceX, uint32_t sourceY,
                                      size_t *offset) {
  return lf_production_pixel_offset_at_source_position(
      capture, (CGFloat)sourceX + 0.5, (CGFloat)sourceY + 0.5, offset);
}

static BOOL lf_production_pixel_is(const LFProductionViewCapture *capture,
                                   const uint8_t *pixels, size_t x, size_t y,
                                   uint8_t red, uint8_t green, uint8_t blue,
                                   uint8_t alpha) {
  if (capture == NULL || pixels == NULL || x >= capture->pixelWidth ||
      y >= capture->pixelHeight || y > SIZE_MAX / capture->bytesPerRow) {
    return NO;
  }
  const size_t offset = y * capture->bytesPerRow + x * 4U;
  return offset <= capture->rgbaBytes.length - 4U &&
         pixels[offset] == red && pixels[offset + 1U] == green &&
         pixels[offset + 2U] == blue && pixels[offset + 3U] == alpha;
}

static LFProductionViewResult lf_compare_production_rgb(
    const LFProductionViewCapture *capture, const uint8_t *pixels) {
  for (uint32_t sourceY = 0U; sourceY < 242U; ++sourceY) {
    for (uint32_t sourceX = 0U; sourceX < 320U; ++sourceX) {
      size_t offset = 0U;
      if (!lf_production_pixel_offset(capture, sourceX, sourceY, &offset)) {
        return LFProductionViewRGBMismatch;
      }
      const BOOL warm = sourceY > 224U ||
                        (sourceY == 224U && sourceX >= 64U);
      const uint8_t expectedRed = warm ? 58U : 0U;
      const uint8_t expectedGreen = warm ? 43U : 0U;
      if (pixels[offset] != expectedRed ||
          pixels[offset + 1U] != expectedGreen ||
          pixels[offset + 2U] != 0U || pixels[offset + 3U] != 255U) {
        lf_append_test_progress([NSString
            stringWithFormat:
                @"production-view: rgb-mismatch source=%u,%u actual=%u,%u,%u,%u expected=%u,%u,0,255\n",
                sourceX, sourceY, pixels[offset], pixels[offset + 1U],
                pixels[offset + 2U], pixels[offset + 3U], expectedRed,
                expectedGreen]);
        return LFProductionViewRGBMismatch;
      }
    }
  }

  const CGFloat pixelScaleX =
      capture->videoFrame.size.width * capture->backingScale / 320.0;
  const CGFloat pixelScaleY =
      capture->videoFrame.size.height * capture->backingScale / 242.0;
  const long roundedScaleX = lround(pixelScaleX);
  const long roundedScaleY = lround(pixelScaleY);
  if (roundedScaleX > 1L && roundedScaleX <= 16L &&
      roundedScaleX == roundedScaleY &&
      fabs(pixelScaleX - (CGFloat)roundedScaleX) < 0.01 &&
      fabs(pixelScaleY - (CGFloat)roundedScaleY) < 0.01) {
    const struct {
      uint32_t sourceX;
      uint32_t sourceY;
      BOOL warm;
    } transitions[] = {{63U, 224U, NO}, {64U, 223U, NO}, {64U, 224U, YES}};
    for (size_t transitionIndex = 0U;
         transitionIndex < sizeof(transitions) / sizeof(transitions[0]);
         ++transitionIndex) {
      for (long subY = 0L; subY < roundedScaleY; ++subY) {
        for (long subX = 0L; subX < roundedScaleX; ++subX) {
          size_t offset = 0U;
          const CGFloat sourceX = (CGFloat)transitions[transitionIndex].sourceX +
              ((CGFloat)subX + 0.5) / (CGFloat)roundedScaleX;
          const CGFloat sourceY = (CGFloat)transitions[transitionIndex].sourceY +
              ((CGFloat)subY + 0.5) / (CGFloat)roundedScaleY;
          const BOOL warm = transitions[transitionIndex].warm;
          const uint8_t expectedRed = warm ? 58U : 0U;
          const uint8_t expectedGreen = warm ? 43U : 0U;
          if (!lf_production_pixel_offset_at_source_position(
                  capture, sourceX, sourceY, &offset) ||
              pixels[offset] != expectedRed ||
              pixels[offset + 1U] != expectedGreen || pixels[offset + 2U] != 0U ||
              pixels[offset + 3U] != 255U) {
            return LFProductionViewRGBMismatch;
          }
        }
      }
    }
  }
  return LFProductionViewMatch;
}

static LFProductionViewResult lf_compare_production_geometry(
    const LFProductionViewCapture *capture, CGRect actualFrame,
    BOOL nearestFilters) {
  if (capture == NULL || capture->rgbaBytes == nil || !nearestFilters ||
      !isfinite(capture->backingScale) || capture->backingScale <= 0.0 ||
      !isfinite(capture->bounds.size.width) ||
      !isfinite(capture->bounds.size.height)) {
    return LFProductionViewGeometryMismatch;
  }
  const CGFloat scale = capture->backingScale;
  const CGFloat availableWidth =
      floor(capture->bounds.size.width * scale + 0.5);
  const CGFloat availableHeight =
      floor(capture->bounds.size.height * scale + 0.5);
  if (availableWidth < 1.0 || availableHeight < 1.0 ||
      fabs(availableWidth - (CGFloat)capture->pixelWidth) > 1.0 ||
      fabs(availableHeight - (CGFloat)capture->pixelHeight) > 1.0) {
    return LFProductionViewGeometryMismatch;
  }

  const CGFloat widthScale = availableWidth / 320.0;
  const CGFloat heightScale = availableHeight / 242.0;
  const CGFloat fitScale = fmin(widthScale, heightScale);
  CGFloat expectedWidth = 0.0;
  CGFloat expectedHeight = 0.0;
  if (fitScale >= 1.0) {
    const CGFloat integerScale = floor(fitScale);
    expectedWidth = 320.0 * integerScale;
    expectedHeight = 242.0 * integerScale;
  } else if (widthScale <= heightScale) {
    expectedWidth = availableWidth;
    expectedHeight = floor(expectedWidth * 242.0 / 320.0 + 0.5);
    if (expectedHeight > availableHeight) {
      expectedHeight = availableHeight;
      expectedWidth = floor(expectedHeight * 320.0 / 242.0 + 0.5);
    }
  } else {
    expectedHeight = availableHeight;
    expectedWidth = floor(expectedHeight * 320.0 / 242.0 + 0.5);
    if (expectedWidth > availableWidth) {
      expectedWidth = availableWidth;
      expectedHeight = floor(expectedWidth * 242.0 / 320.0 + 0.5);
    }
  }
  const CGFloat expectedX = floor((availableWidth - expectedWidth) / 2.0);
  const CGFloat expectedY = floor((availableHeight - expectedHeight) / 2.0);
  const CGFloat actualX =
      (actualFrame.origin.x - capture->bounds.origin.x) * scale;
  const CGFloat actualY =
      (actualFrame.origin.y - capture->bounds.origin.y) * scale;
  const CGFloat actualWidth = actualFrame.size.width * scale;
  const CGFloat actualHeight = actualFrame.size.height * scale;
  if (expectedX <= 0.0 || expectedY <= 0.0 ||
      fabs(actualX - expectedX) > 1.0 ||
      fabs(actualY - expectedY) > 1.0 ||
      fabs(actualWidth - expectedWidth) > 1.0 ||
      fabs(actualHeight - expectedHeight) > 1.0) {
    return LFProductionViewGeometryMismatch;
  }

  const uint8_t *pixels = capture->rgbaBytes.bytes;
  const size_t horizontalMid = capture->pixelHeight / 2U;
  const size_t verticalMid = capture->pixelWidth / 2U;
  if (!lf_production_pixel_is(capture, pixels, 0U, horizontalMid,
                              0U, 0U, 0U, 255U) ||
      !lf_production_pixel_is(capture, pixels, capture->pixelWidth - 1U,
                              horizontalMid, 0U, 0U, 0U, 255U) ||
      !lf_production_pixel_is(capture, pixels, verticalMid, 0U,
                              0U, 0U, 0U, 255U) ||
      !lf_production_pixel_is(capture, pixels, verticalMid,
                              capture->pixelHeight - 1U,
                              0U, 0U, 0U, 255U)) {
    return LFProductionViewGeometryMismatch;
  }
  return LFProductionViewMatch;
}

@interface LFHostApplicationDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation>
@property(nonatomic, copy) NSString *contentPath;
@property(nonatomic, copy) NSArray<NSString *> *testFailurePaths;
@property(nonatomic, copy) NSString *testRetryPath;
@property(nonatomic) BOOL testPanelFlow;
@property(nonatomic) BOOL testCliRetry;
@property(nonatomic) BOOL testSchedulerRetry;
@property(nonatomic) BOOL testProductionView;
@property(nonatomic) LFHostTestDrainMode testDrainMode;
@property(nonatomic) NSUInteger closeAfterPresentations;
@property(nonatomic) int exitCode;
@property(nonatomic, readonly) BOOL testCloseCompleted;
- (void)startHost;
- (void)openContent:(nullable id)sender;
- (BOOL)finishDrainTest;
- (void)blockGuestCallForDrainTest;
- (void)requestDrainWithCompletion:(dispatch_block_t)completion;
- (void)requestTestDrain:(NSTimer *)timer;
- (void)releaseTestGuestBarrier:(NSTimer *)timer;
- (BOOL)verifyProductionViewFrame:(LFHostFrame *)frame;
- (void)failProductionViewCheck;
- (void)waitForAudioPlaybackThenClose;
- (void)pollAudioPlaybackBeforeClose;
- (BOOL)canOpenContent;
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem;
- (void)postAccessibilityAnnouncement:(NSString *)announcement
                              priority:(NSAccessibilityPriorityLevel)priority;
- (BOOL)publishContentFeedback:(LFHostContentFeedbackState)state
                     generation:(uint64_t)generation
                       basename:(nullable NSString *)basename
                    announcement:(BOOL)announcement;
- (BOOL)handlePresentedFrame:(LFHostFrame *)frame
                     session:(LFHostSession *)session
                     attempt:(uint64_t)attempt;
- (BOOL)verifyOpenActionForTest:(NSString *)stage
                     enabled:(BOOL)enabled
             pressKeyEquivalent:(BOOL)pressKeyEquivalent
                  activePanel:(nullable NSOpenPanel *)activePanel;
- (NSString *)audioFooterTextForMutedState:(BOOL)muted;
- (CGFloat)maximumAudioFooterWidth;
- (CGFloat)minimumMuteButtonWidth;
- (void)updateAudioMuteControl;
- (void)toggleAudioMute:(nullable id)sender;
- (BOOL)verifyAudioMuteControlStateForTest:(BOOL)muted
                                      stage:(NSString *)stage;
- (void)verifyAudioMuteAfterReadyForTest;
- (BOOL)verifyMinimumWindowGeometryForTest;
- (void)handleSchedulerStart:(BOOL)success
                       error:(nullable NSError *)error
                     session:(LFHostSession *)session
                  generation:(uint64_t)generation
                     attempt:(uint64_t)attempt;
@end

@implementation LFHostApplicationDelegate {
  NSWindow *_window;
  LFHostView *_gameView;
  NSTextField *_statusLabel;
  NSButton *_muteButton;
  NSButton *_openButton;
  NSOpenPanel *_openPanel;
  NSAlert *_errorAlert;
  NSMenu *_fileMenu;
  NSMenuItem *_openMenuItem;
  LFHostSession *_session;
  LFInputState *_inputState;
  BOOL _closeRequested;
  BOOL _closeReady;
  BOOL _printedSuccess;
  BOOL _testCloseCompleted;
  BOOL _didStart;
  BOOL _opening;
  BOOL _audioMuted;
  BOOL _testAudioMutePreferenceArmed;
  BOOL _steadyUpdatesStarted;
  LFHostContentFeedbackState _contentFeedbackState;
  uint64_t _contentAttempt;
  uint64_t _readyAttempt;
  uint64_t _readyGeneration;
  NSString *_contentBasename;
  BOOL _testCancelWasIdle;
  BOOL _testFlowFailed;
  BOOL _productionViewCheckFinished;
  BOOL _productionViewFailureStarted;
  BOOL _productionInputSampled;
  BOOL _productionInputSeedSeen;
  BOOL _audioPlaybackWaitScheduled;
  dispatch_time_t _audioPlaybackWaitDeadline;
  BOOL _testFailOutputAllocationOnNextOpen;
  BOOL _testCliRetryPanelShown;
  BOOL _testSchedulerRetryPanelShown;
  BOOL _testSchedulerFaultApplied;
  NSUInteger _testSchedulerErrorsShown;
  NSUInteger _testSchedulerRetryReadyCount;
  NSUInteger _testFeedbackTransitions;
  NSUInteger _testAccessibilityAnnouncements;
  NSUInteger _testReadyTransitions;
  NSUInteger _testOpenActionInvocations;
  NSUInteger _testOpenPanelRequests;
  LFHostSession *_testStaleSession;
  LFHostFrame *_testStaleFrame;
  uint64_t _testStaleAttempt;
  uint64_t _testStaleGeneration;
  LFHostSession *_testSchedulerFailedSession;
  NSError *_testSchedulerError;
  uint64_t _testSchedulerAttempt;
  uint64_t _testSchedulerGeneration;
  BOOL _testDrainBarrierScheduled;
  BOOL _testDrainRequestReturned;
  BOOL _testDrainMainSentinel;
  BOOL _testDrainKeyConsumed;
  BOOL _testDrainResizeHandled;
  BOOL _testDrainBarrierTimedOut;
  BOOL _testDrainCompletionSeen;
  BOOL _testDrainErrorSuppressed;
  BOOL _testDrainOpenUnavailable;
  BOOL _testDrainWindowClosed;
  BOOL _testDrainApplicationWillTerminate;
  BOOL _drainInitiated;
  BOOL _terminationReplyPending;
  dispatch_semaphore_t _testDrainRelease;
  NSMutableArray<dispatch_block_t> *_drainCompletions;
  NSUInteger _testDrainEventOrder;
  NSUInteger _testDrainAdvanceStartedOrder;
  NSUInteger _testDrainInputSampledOrder;
  NSUInteger _testDrainCoreAdvanceStartedOrder;
  NSUInteger _testDrainAdvanceFinishedOrder;
  NSUInteger _testDrainLoadStartedOrder;
  NSUInteger _testDrainLoadFinishedOrder;
  NSUInteger _testDrainContentReleasedOrder;
  NSUInteger _testDrainDestroyOrder;
  NSUInteger _testDrainBuffersReleasedOrder;
  NSUInteger _testDrainCompletionOrder;
  NSUInteger _testDrainAdvanceFinishedCount;
  NSUInteger _testDrainLoadStartedCount;
  NSUInteger _testDrainLoadFinishedCount;
  NSUInteger _testDrainContentReleasedCount;
  NSUInteger _testDrainDestroyCount;
  NSUInteger _testDrainBuffersReleasedCount;
  uint64_t _activeGeneration;
  NSUInteger _testPanelStep;
  NSUInteger _testPanelCancels;
  NSUInteger _testSelections;
  NSUInteger _testErrorsShown;
  NSUInteger _testErrorsDismissed;
  NSUInteger _testReaderFailures;
  NSUInteger _testLoadFailures;
  NSUInteger _testOutputAllocationFailures;
  NSUInteger _testInstancesCreated;
  NSUInteger _testLoadsStarted;
  NSUInteger _testLoadsFinished;
  NSUInteger _testLoadsAccepted;
  NSUInteger _testBuffersAllocated;
  NSUInteger _testContentReleased;
  NSUInteger _testInstancesDestroyed;
  NSUInteger _testAdvancesStarted;
  NSUInteger _testOpenCreateCountBefore;
  NSUInteger _testOpenLoadCountBefore;
  NSUInteger _testOpenLoadFinishCountBefore;
  NSUInteger _testOpenLoadAcceptedCountBefore;
  NSUInteger _testOpenBufferCountBefore;
  NSUInteger _testOpenDestroyCountBefore;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  (void)notification;
  if (self.testProductionView) {
    lf_append_test_progress(@"app-start: did-finish-launching\n");
  }
  [self startHost];
}
- (void)blockGuestCallForDrainTest {
  lf_append_test_progress(@"drain-barrier: guest-call-blocked\n");
  __weak LFHostApplicationDelegate *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    LFHostApplicationDelegate *strongSelf = weakSelf;
    if (strongSelf != nil) {
      [NSTimer scheduledTimerWithTimeInterval:0.05
                                       target:strongSelf
                                     selector:@selector(requestTestDrain:)
                                     userInfo:nil
                                      repeats:NO];
    }
  });
  const dispatch_time_t limit =
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8U * NSEC_PER_SEC));
  if (dispatch_semaphore_wait(_testDrainRelease, limit) != 0) {
    @synchronized(self) {
      _testDrainBarrierTimedOut = YES;
    }
  }
}
- (void)requestTestDrain:(NSTimer *)timer {
  (void)timer;
  NSAssert([NSThread isMainThread], @"drain test actions must run on AppKit");
  lf_append_test_progress([NSString
      stringWithFormat:@"drain-request: mode=%lu close-before=%d\n",
                           (unsigned long)self.testDrainMode,
                           _closeRequested]);
  if (self.testDrainMode == LFHostTestDrainModeTerminate) {
    _testDrainRequestReturned = YES;
    NSTimer *sentinelTimer = [NSTimer
        timerWithTimeInterval:0.05
                       target:self
                     selector:@selector(releaseTestGuestBarrier:)
                     userInfo:nil
                      repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:sentinelTimer
                              forMode:NSRunLoopCommonModes];
    [NSApp terminate:nil];
  } else {
    [_window performClose:nil];
    [_window performClose:nil];
    _testDrainRequestReturned = YES;
    lf_append_test_progress([NSString
        stringWithFormat:@"drain-request: close-after=%d returned=%d\n",
                             _closeRequested, _testDrainRequestReturned]);
    NSTimer *sentinelTimer = [NSTimer
        timerWithTimeInterval:0.05
                       target:self
                     selector:@selector(releaseTestGuestBarrier:)
                     userInfo:nil
                      repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:sentinelTimer
                              forMode:NSRunLoopCommonModes];
  }
}
- (void)releaseTestGuestBarrier:(NSTimer *)timer {
  (void)timer;
  NSAssert([NSThread isMainThread], @"drain test sentinel must run on AppKit");
  NSEvent *keyDown = [NSEvent
      keyEventWithType:NSEventTypeKeyDown
             location:NSZeroPoint
        modifierFlags:0
            timestamp:NSProcessInfo.processInfo.systemUptime
         windowNumber:_window.windowNumber
              context:nil
           characters:@"w"
  charactersIgnoringModifiers:@"w"
            isARepeat:NO
              keyCode:13U];
  NSEvent *keyUp = [NSEvent
      keyEventWithType:NSEventTypeKeyUp
             location:NSZeroPoint
        modifierFlags:0
            timestamp:NSProcessInfo.processInfo.systemUptime
         windowNumber:_window.windowNumber
              context:nil
           characters:@"w"
  charactersIgnoringModifiers:@"w"
            isARepeat:NO
              keyCode:13U];
  [_gameView keyDown:keyDown];
  _testDrainKeyConsumed = (_inputState.buttons & UINT32_C(0x1000)) != 0U;
  [_gameView keyUp:keyUp];
  NSRect resizedFrame = _window.frame;
  resizedFrame.size.width += 1.0;
  [_window setFrame:resizedFrame display:YES];
  _testDrainResizeHandled = _window.frame.size.width == resizedFrame.size.width;
  _statusLabel.stringValue = @"Shutdown drain is responsive";
  _testDrainMainSentinel =
      _testDrainKeyConsumed && _inputState.buttons == 0U &&
      _testDrainResizeHandled &&
      _testDrainOpenUnavailable &&
      [_statusLabel.stringValue isEqualToString:@"Shutdown drain is responsive"];
  dispatch_semaphore_signal(_testDrainRelease);
}
- (void)requestDrainWithCompletion:(dispatch_block_t)completion {
  NSAssert([NSThread isMainThread], @"session drain requests must run on AppKit");
  _closeRequested = YES;
  [self updateOpenAction];
  if (self.testDrainMode != LFHostTestDrainModeNone) {
    _testDrainOpenUnavailable =
        [self verifyOpenActionForTest:@"closing-drain"
                              enabled:NO
                   pressKeyEquivalent:YES
                           activePanel:_openPanel];
    lf_append_test_progress([NSString
        stringWithFormat:@"drain-open-action: disabled=%d\n",
                             _testDrainOpenUnavailable]);
  }
  if (_openPanel != nil) {
    [_openPanel cancel:nil];
  }
  if (completion != nil) {
    if (_drainCompletions == nil) {
      _drainCompletions = [NSMutableArray array];
    }
    [_drainCompletions addObject:[completion copy]];
  }
  if (_drainInitiated) {
    return;
  }
  _drainInitiated = YES;
  __weak LFHostApplicationDelegate *weakSelf = self;
  void (^finishDrain)(void) = ^{
    LFHostApplicationDelegate *strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }
    strongSelf->_closeReady = YES;
    strongSelf->_testDrainCompletionSeen =
        strongSelf.testDrainMode != LFHostTestDrainModeNone;
    if (strongSelf->_testDrainCompletionSeen) {
      @synchronized(strongSelf) {
        strongSelf->_testDrainCompletionOrder =
            ++strongSelf->_testDrainEventOrder;
      }
    }
    NSArray<dispatch_block_t> *completions =
        strongSelf->_drainCompletions != nil
            ? [strongSelf->_drainCompletions copy]
            : @[];
    [strongSelf->_drainCompletions removeAllObjects];
    for (dispatch_block_t drainCompletion in completions) {
      drainCompletion();
    }
  };
  LFHostSession *session = _session;
  if (session == nil) {
    dispatch_async(dispatch_get_main_queue(), finishDrain);
  } else {
    [session stopWithCompletion:finishDrain];
  }
}
- (void)waitForAudioPlaybackThenClose {
  NSAssert([NSThread isMainThread],
           @"audio-smoke completion polling must run on AppKit");
  if (_audioPlaybackWaitScheduled || _closeRequested) {
    return;
  }
  _audioPlaybackWaitScheduled = YES;
  _audioPlaybackWaitDeadline =
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5U * NSEC_PER_SEC));
  [self pollAudioPlaybackBeforeClose];
}
- (void)pollAudioPlaybackBeforeClose {
  NSAssert([NSThread isMainThread],
           @"audio-smoke completion polling must run on AppKit");
  if (_closeRequested || !_audioPlaybackWaitScheduled) {
    return;
  }
  if ([lf_live_audio_output hasDataPlayedBack]) {
    _audioPlaybackWaitScheduled = NO;
    [_window performClose:nil];
    return;
  }
  if (dispatch_time(DISPATCH_TIME_NOW, 0) >= _audioPlaybackWaitDeadline) {
    self.exitCode = 1;
    _audioPlaybackWaitScheduled = NO;
    [_window performClose:nil];
    return;
  }
  __weak LFHostApplicationDelegate *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                               (int64_t)(10U * NSEC_PER_MSEC)),
                 dispatch_get_main_queue(), ^{
    [weakSelf pollAudioPlaybackBeforeClose];
  });
}
- (BOOL)verifyProductionViewFrame:(LFHostFrame *)frame {
  NSAssert([NSThread isMainThread],
           @"production-view capture must run on AppKit");
  lf_append_test_progress(@"production-view: verification-started\n");
  if (!self.testProductionView || frame == nil ||
      frame.generation == 0U || frame.generation != _activeGeneration ||
      frame.sequence != 1U) {
    lf_append_test_progress(@"production-view: first-frame-invalid\n");
    return NO;
  }
  @synchronized(self) {
    if (!_productionInputSampled || !_productionInputSeedSeen) {
      lf_append_test_progress(@"production-view: input-seed-invalid\n");
      return NO;
    }
  }

  LFProductionViewCapture capture = {0};
  lf_append_test_progress(@"production-view: capture-started\n");
  const BOOL captured =
      [_gameView captureProductionViewForFrame:frame result:&capture];
  lf_append_test_progress(captured
                              ? @"production-view: capture-finished\n"
                              : @"production-view: capture-failed\n");
  if (!captured ||
      capture.rgbaBytes == nil || capture.rgbaBytes.length < 4U ||
      capture.pixelWidth == 0U || capture.pixelHeight == 0U) {
    lf_append_test_progress(@"production-view: capture-invalid\n");
    return NO;
  }
  if (lf_compare_production_rgb(&capture, capture.rgbaBytes.bytes) !=
      LFProductionViewMatch) {
    lf_append_test_progress(@"production-view: rgb-mismatch\n");
    return NO;
  }
  if (lf_compare_production_geometry(&capture, capture.videoFrame,
                                     capture.nearestFilters) !=
      LFProductionViewMatch) {
    lf_append_test_progress(@"production-view: geometry-mismatch\n");
    return NO;
  }

  NSMutableData *corruptedPixels = [capture.rgbaBytes mutableCopy];
  size_t transitionOffset = 0U;
  if (corruptedPixels == nil ||
      !lf_production_pixel_offset(&capture, 64U, 224U, &transitionOffset)) {
    return NO;
  }
  ((uint8_t *)corruptedPixels.mutableBytes)[transitionOffset] ^= 1U;
  const LFProductionViewResult corruptedRGB = lf_compare_production_rgb(
      &capture, corruptedPixels.bytes);
  const LFProductionViewResult restoredRGB = lf_compare_production_rgb(
      &capture, capture.rgbaBytes.bytes);
  if (corruptedRGB != LFProductionViewRGBMismatch ||
      restoredRGB != LFProductionViewMatch) {
    lf_append_test_progress(@"production-view: rgb-control-failed\n");
    return NO;
  }

  CGRect corruptedFrame = capture.videoFrame;
  corruptedFrame.size.width += 2.0 / capture.backingScale;
  const LFProductionViewResult corruptedGeometry =
      lf_compare_production_geometry(&capture, corruptedFrame,
                                     capture.nearestFilters);
  const LFProductionViewResult restoredGeometry =
      lf_compare_production_geometry(&capture, capture.videoFrame,
                                     capture.nearestFilters);
  if (corruptedGeometry != LFProductionViewGeometryMismatch ||
      restoredGeometry != LFProductionViewMatch) {
    lf_append_test_progress(@"production-view: geometry-control-failed\n");
    return NO;
  }

  lf_append_test_progress([NSString
      stringWithFormat:
          @"production-view-observation backing-scale=%.2f bounds=%.0fx%.0f backing=%zux%zu video=%.0f,%.0f,%.0fx%.0f rgba=8,32,srgb,opaque flipped=%d\n",
          (double)capture.backingScale,
          (double)capture.bounds.size.width,
          (double)capture.bounds.size.height, capture.pixelWidth,
          capture.pixelHeight,
          (double)((capture.videoFrame.origin.x - capture.bounds.origin.x) *
                   capture.backingScale),
          (double)((capture.videoFrame.origin.y - capture.bounds.origin.y) *
                   capture.backingScale),
          (double)(capture.videoFrame.size.width * capture.backingScale),
          (double)(capture.videoFrame.size.height * capture.backingScale),
          capture.geometryFlipped]);
  lf_append_test_progress(@"production-view: verification-passed\n");
  return YES;
}
- (void)failProductionViewCheck {
  NSAssert([NSThread isMainThread],
           @"production-view failure cleanup must run on AppKit");
  if (_productionViewFailureStarted) {
    return;
  }
  _productionViewFailureStarted = YES;
  self.exitCode = EXIT_FAILURE;
  __weak LFHostApplicationDelegate *weakSelf = self;
  [self requestDrainWithCompletion:^{
    LFHostApplicationDelegate *strongSelf = weakSelf;
    if (strongSelf != nil) {
      [strongSelf->_window performClose:nil];
    }
  }];
}
- (NSString *)audioFooterTextForMutedState:(BOOL)muted {
  return [NSString
      stringWithFormat:
          @"Port 0: Arrows + Space     Port 1: W/A/S/D + F     Audio: %@",
          muted ? @"Muted" : @"On"];
}
- (CGFloat)maximumAudioFooterWidth {
  if (_statusLabel == nil) {
    return 0.0;
  }
  NSString *savedText = _statusLabel.stringValue;
  _statusLabel.stringValue = [self audioFooterTextForMutedState:NO];
  const CGFloat onWidth = ceil(_statusLabel.fittingSize.width);
  _statusLabel.stringValue = [self audioFooterTextForMutedState:YES];
  const CGFloat mutedWidth = ceil(_statusLabel.fittingSize.width);
  _statusLabel.stringValue = savedText;
  return MAX(onWidth, mutedWidth);
}
- (CGFloat)minimumMuteButtonWidth {
  if (_muteButton == nil) {
    return 88.0;
  }
  NSString *savedTitle = _muteButton.title;
  _muteButton.title = @"Mute";
  const CGFloat muteTitleWidth = ceil(_muteButton.fittingSize.width);
  _muteButton.title = @"Unmute";
  const CGFloat unmuteTitleWidth = ceil(_muteButton.fittingSize.width);
  _muteButton.title = savedTitle;
  return MAX(88.0, MAX(muteTitleWidth, unmuteTitleWidth) + 16.0);
}
- (void)updateAudioMuteControl {
  NSString *audioStatus = _audioMuted ? @"Muted" : @"On";
  NSString *actionTitle = _audioMuted ? @"Unmute" : @"Mute";
  NSString *actionLabel = _audioMuted ? @"Unmute audio" : @"Mute audio";
  NSString *actionHelp =
      _audioMuted
          ? @"Audio is muted. Click to restore output; gameplay and audio generation continue."
          : @"Audio is on. Click to mute output; gameplay and audio generation continue.";
  if (_statusLabel != nil) {
    _statusLabel.stringValue = [self audioFooterTextForMutedState:_audioMuted];
    _statusLabel.accessibilityLabel = _statusLabel.stringValue;
    _statusLabel.accessibilityValue = audioStatus;
  }
  if (_muteButton != nil) {
    _muteButton.title = actionTitle;
    _muteButton.accessibilityLabel = actionLabel;
    _muteButton.accessibilityValue = audioStatus;
    _muteButton.accessibilityHelp = actionHelp;
  }
}
- (void)toggleAudioMute:(id)sender {
  (void)sender;
  if (_closeRequested || _closeReady) {
    return;
  }
  _audioMuted = !_audioMuted;
  [self updateAudioMuteControl];
  [_session setAudioMuted:_audioMuted];
  if (_muteButton != nil) {
    NSAccessibilityPostNotification(_muteButton,
                                    NSAccessibilityValueChangedNotification);
  }
  if (_statusLabel != nil) {
    NSAccessibilityPostNotification(_statusLabel,
                                    NSAccessibilityValueChangedNotification);
  }
}
- (BOOL)verifyAudioMuteControlStateForTest:(BOOL)muted
                                      stage:(NSString *)stage {
  NSString *expectedStatus = muted ? @"Muted" : @"On";
  NSString *expectedTitle = muted ? @"Unmute" : @"Mute";
  NSString *expectedAction = muted ? @"Unmute audio" : @"Mute audio";
  NSString *expectedFooter = [self audioFooterTextForMutedState:muted];
  const BOOL buttonPassed =
      _audioMuted == muted && _muteButton != nil && _muteButton.enabled &&
      [_muteButton.title isEqualToString:expectedTitle] &&
      [_muteButton.accessibilityLabel isEqualToString:expectedAction] &&
      [_muteButton.accessibilityValue isEqualToString:expectedStatus] &&
      [_muteButton.accessibilityHelp
          containsString:@"gameplay and audio generation continue"];
  const BOOL footerPassed =
      _statusLabel != nil &&
      [_statusLabel.stringValue isEqualToString:expectedFooter] &&
      [_statusLabel.accessibilityLabel isEqualToString:expectedFooter];
  const BOOL passed = buttonPassed && footerPassed;
  if (!passed) {
    _testFlowFailed = YES;
    lf_append_test_progress([NSString
        stringWithFormat:
            @"test-assertion-failed: audio-toggle stage=%@ expected-muted=%d actual-muted=%d enabled=%d button=%d title=%@ label=%@ value=%@ help=%@ footer=%d footer-label=%@ footer-value=%@ footer-text=%@\n",
            stage, muted, _audioMuted, _muteButton.enabled, buttonPassed,
            _muteButton.title, _muteButton.accessibilityLabel,
            _muteButton.accessibilityValue, _muteButton.accessibilityHelp,
            footerPassed, _statusLabel.accessibilityLabel,
            _statusLabel.accessibilityValue, _statusLabel.stringValue]);
  }
  return passed;
}
- (void)verifyAudioMuteAfterReadyForTest {
  if (!_testAudioMutePreferenceArmed) {
    return;
  }
  if (![self verifyAudioMuteControlStateForTest:YES stage:@"ready"]) {
    return;
  }
  const BOOL waitingForSchedulerRetry =
      self.testSchedulerRetry && _testSchedulerRetryReadyCount == 0U;
  if (waitingForSchedulerRetry) {
    lf_append_test_progress(
        @"audio-toggle: before-load=muted first-session=ready result=pass\n");
    return;
  }
  [_muteButton performClick:nil];
  if (![self verifyAudioMuteControlStateForTest:NO stage:@"replacement-ready"]) {
    return;
  }
  _testAudioMutePreferenceArmed = NO;
  lf_append_test_progress(
      @"audio-toggle: retained=before-load,session,replacement reset=unmuted result=pass\n");
}
- (void)startHost {
  if (_didStart) {
    return;
  }
  _didStart = YES;
  if (self.testProductionView) {
    lf_append_test_progress(@"app-start: host-initialization=begin\n");
  }
  if (self.testDrainMode != LFHostTestDrainModeNone) {
    _testDrainRelease = dispatch_semaphore_create(0);
  }
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
  const NSRect windowFrame = NSMakeRect(0.0, 0.0, 680.0, 540.0);
  _window = [[NSWindow alloc]
      initWithContentRect:windowFrame
                styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                           NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                  backing:NSBackingStoreBuffered
                    defer:NO];
  _window.title = @"libfuturo";
  _window.delegate = self;
  _contentAttempt = 0U;
  _contentFeedbackState = LFHostContentFeedbackUninitialized;
  [self publishContentFeedback:LFHostContentFeedbackNoContent
                    generation:_contentAttempt
                      basename:nil
                   announcement:YES];
  if (self.testPanelFlow || self.testCliRetry || self.testSchedulerRetry) {
    const BOOL hasInitialFeedback =
        [_window.title containsString:@"No content"] &&
        [_window.accessibilityTitle isEqualToString:_window.title];
    if (!hasInitialFeedback) {
      lf_append_test_progress([NSString
          stringWithFormat:@"test-assertion-failed: initial-feedback expected=No-content actual=%@\n",
                               _window.title]);
      exit(EXIT_FAILURE);
    }
  }
  NSView *container = [[NSView alloc] initWithFrame:windowFrame];
  container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  __weak LFHostApplicationDelegate *weakSelf = self;
  _inputState = [[LFInputState alloc]
      initWithButtonsHandler:^(uint32_t buttons) {
        LFHostApplicationDelegate *strongSelf = weakSelf;
        if (strongSelf != nil && strongSelf->_session != nil) {
          [strongSelf->_session setInputButtons:buttons];
        }
      }];
  [_inputState observeWindow:_window application:NSApp];
  _statusLabel = [NSTextField labelWithString:
      @"Port 0: Arrows + Space     Port 1: W/A/S/D + F     Audio: On"];
  _statusLabel.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
  _statusLabel.accessibilityHelp =
      @"W, A, S, D, and F are recognized by their typed letters and their US keyboard physical positions. Other keys in the game view are ignored. Held-key input is sampled at the start of each guest advance; a tap shorter than one frame can be missed. Display colors use a warm NTSC emulator palette approximation, not calibrated Atari hardware or CRT output.";
  _muteButton = [NSButton buttonWithTitle:@"Mute"
                                  target:self
                                  action:@selector(toggleAudioMute:)];
  _muteButton.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
  _openButton = [NSButton buttonWithTitle:@"Open…"
                                   target:self
                                   action:@selector(openContent:)];
  _openButton.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
  _openButton.accessibilityLabel = @"Open content";
  [self updateAudioMuteControl];
  const CGFloat footerWidth = [self maximumAudioFooterWidth];
  const CGFloat muteButtonWidth = [self minimumMuteButtonWidth];
  const CGFloat minimumContentWidth =
      MAX(320.0 + 24.0, footerWidth + 140.0 + muteButtonWidth);
  const CGFloat initialContentWidth =
      MAX(container.bounds.size.width, minimumContentWidth);
  if (initialContentWidth > container.bounds.size.width) {
    container.frame = NSMakeRect(0.0, 0.0, initialContentWidth,
                                 container.bounds.size.height);
    [_window setContentSize:NSMakeSize(initialContentWidth,
                                       container.bounds.size.height)];
  }
  _statusLabel.frame = NSMakeRect(
      16.0, 12.0,
      MAX(container.bounds.size.width - 140.0 - muteButtonWidth, 1.0), 20.0);
  _openButton.frame = NSMakeRect(container.bounds.size.width - 104.0,
                                 8.0, 88.0, 28.0);
  _muteButton.frame = NSMakeRect(NSMinX(_openButton.frame) - 8.0 -
                                      muteButtonWidth,
                                  8.0, muteButtonWidth, 28.0);
  _gameView = [[LFHostView alloc]
      initWithFrame:NSMakeRect(12.0, 40.0,
                              MAX(container.bounds.size.width - 24.0, 1.0),
                              MAX(container.bounds.size.height - 60.0, 1.0))];
  _gameView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  _gameView.wantsLayer = YES;
  _gameView.inputState = _inputState;
  _gameView.accessibilityLabel = @"Atari 7800 display";
  _gameView.accessibilityHelp =
      @"The warm NTSC colors are an emulator palette approximation, not calibrated Atari hardware or CRT output.";
  [container addSubview:_gameView];
  [container addSubview:_statusLabel];
  [container addSubview:_muteButton];
  [container addSubview:_openButton];
  _window.contentView = container;
  _window.contentMinSize = NSMakeSize(minimumContentWidth, 302.0);
  [_window center];
  [_window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
  [_window makeFirstResponder:_gameView];
  if (self.testPanelFlow || self.testCliRetry || self.testSchedulerRetry) {
    lf_append_test_progress([NSString
        stringWithFormat:@"window: visible=%d key=%d screens=%lu content=%.0fx%.0f\n",
                             _window.isVisible, _window.isKeyWindow,
                             (unsigned long)NSScreen.screens.count,
                             container.bounds.size.width,
                             container.bounds.size.height]);
  }
  if (self.testProductionView) {
    lf_append_test_progress(@"production-view: window-visible\n");
  }

  NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"libfuturo"];
  NSMenuItem *fileItem = [[NSMenuItem alloc] initWithTitle:@"File"
                                                    action:nil
                                             keyEquivalent:@""];
  _fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
  NSMenuItem *openItem = [[NSMenuItem alloc] initWithTitle:@"Open…"
                                                   action:@selector(openContent:)
                                            keyEquivalent:@"o"];
  openItem.target = self;
  _openMenuItem = openItem;
  [_fileMenu addItem:openItem];
  fileItem.submenu = _fileMenu;
  [mainMenu addItem:fileItem];
  NSApp.mainMenu = mainMenu;
  [self updateOpenAction];
  if (![self verifyMinimumWindowGeometryForTest]) {
    _testFlowFailed = YES;
  }
  if (self.testPanelFlow || self.testCliRetry || self.testSchedulerRetry) {
    if (![self verifyAudioMuteControlStateForTest:NO stage:@"before-load"]) {
      _testFlowFailed = YES;
    } else {
      [_muteButton performClick:nil];
      if ([self verifyAudioMuteControlStateForTest:YES
                                             stage:@"before-load-muted"]) {
        _testAudioMutePreferenceArmed = YES;
        lf_append_test_progress(
            @"audio-toggle: before-load=muted accessible=pass result=pass\n");
      }
    }
  }

  _gameView.presentationHandler = ^(LFHostFrame *frame) {
    LFHostApplicationDelegate *strongSelf = weakSelf;
    if (strongSelf == nil || strongSelf->_closeRequested ||
        strongSelf->_session == nil ||
        frame.generation != strongSelf->_activeGeneration) {
      return;
    }
    if (strongSelf.testProductionView &&
        !strongSelf->_productionViewCheckFinished) {
      strongSelf->_productionViewCheckFinished = YES;
      if (![strongSelf verifyProductionViewFrame:frame]) {
        [strongSelf failProductionViewCheck];
        return;
      }
      lf_test_production_view_passed = YES;
    }
    const uint64_t presentedAttempt = strongSelf->_contentAttempt;
    LFHostSession *presentedSession = strongSelf->_session;
    if (![strongSelf handlePresentedFrame:frame
                                  session:presentedSession
                                  attempt:presentedAttempt]) {
      return;
    }
    if ((strongSelf.testPanelFlow || strongSelf.testCliRetry ||
         strongSelf.testSchedulerRetry) &&
        (![strongSelf->_window.title containsString:@"Ready:"] ||
         ![strongSelf->_window.accessibilityTitle
             isEqualToString:strongSelf->_window.title])) {
      strongSelf->_testFlowFailed = YES;
      lf_append_test_progress(@"test-assertion-failed: ready-state not presented\n");
    }
    if (strongSelf.testSchedulerRetry &&
        strongSelf->_testSchedulerFailedSession != nil &&
        strongSelf->_testSchedulerFailedSession != strongSelf->_session &&
        strongSelf->_testSchedulerRetryReadyCount == 0U) {
      ++strongSelf->_testSchedulerRetryReadyCount;
      NSString *readyTitle = strongSelf->_window.title;
      const LFHostContentFeedbackState readyState =
          strongSelf->_contentFeedbackState;
      const NSUInteger announcementsBefore =
          strongSelf->_testAccessibilityAnnouncements;
      const NSUInteger errorsBefore = strongSelf->_testSchedulerErrorsShown;
      [strongSelf handleSchedulerStart:NO
                                 error:strongSelf->_testSchedulerError
                               session:strongSelf->_testSchedulerFailedSession
                            generation:strongSelf->_testSchedulerGeneration
                               attempt:strongSelf->_testSchedulerAttempt];
      if (strongSelf->_errorAlert != nil ||
          ![strongSelf->_window.title isEqualToString:readyTitle] ||
          strongSelf->_contentFeedbackState != readyState ||
          strongSelf->_testAccessibilityAnnouncements != announcementsBefore ||
          strongSelf->_testSchedulerErrorsShown != errorsBefore) {
        strongSelf->_testFlowFailed = YES;
        lf_append_test_progress(@"test-assertion-failed: stale-scheduler-completion-changed-retry-state\n");
      } else {
        lf_append_test_progress(@"scheduler-stale-completion: ignored\n");
      }
    }
    [strongSelf verifyAudioMuteAfterReadyForTest];
    if (!strongSelf->_steadyUpdatesStarted) {
      strongSelf->_steadyUpdatesStarted = YES;
      if (strongSelf.testPanelFlow || strongSelf.testCliRetry ||
          strongSelf.testSchedulerRetry) {
        lf_append_test_progress(@"steady-start: requested\n");
      }
      LFHostSession *startedSession = strongSelf->_session;
      const uint64_t startedAttempt = strongSelf->_contentAttempt;
      const uint64_t startedGeneration = frame.generation;
      [startedSession
          startSteadyUpdatesWithCompletion:^(BOOL success, NSError *error) {
            LFHostApplicationDelegate *completedSelf = weakSelf;
            if (completedSelf != nil &&
                (completedSelf.testPanelFlow || completedSelf.testCliRetry ||
                 completedSelf.testSchedulerRetry)) {
              lf_append_test_progress(success
                                          ? @"steady-start: success\n"
                                          : @"steady-start: failed\n");
            }
            if (completedSelf == nil) {
              return;
            }
            [completedSelf handleSchedulerStart:success
                                           error:error
                                         session:startedSession
                                      generation:startedGeneration
                                         attempt:startedAttempt];
          }];
      return;
    }
    if (strongSelf->_closeRequested || strongSelf.closeAfterPresentations == 0U ||
        strongSelf->_gameView.completedPresentations <
            strongSelf.closeAfterPresentations) {
      return;
    }
    if (strongSelf.testProductionView &&
        ![lf_live_audio_output hasDataPlayedBack]) {
      [strongSelf waitForAudioPlaybackThenClose];
      return;
    }
    [strongSelf->_window performClose:nil];
  };
  if (self.contentPath.length > 0U) {
    [self beginOpenContentAtPath:self.contentPath];
  } else {
    [self showOpenPanel];
  }
}
- (void)postAccessibilityAnnouncement:(NSString *)announcement
                              priority:(NSAccessibilityPriorityLevel)priority {
  if (announcement.length == 0U) {
    return;
  }
  NSAccessibilityPostNotificationWithUserInfo(
      NSApp, NSAccessibilityAnnouncementRequestedNotification,
      @{NSAccessibilityAnnouncementKey : announcement,
        NSAccessibilityPriorityKey : @(priority)});
  if (self.testPanelFlow || self.testCliRetry || self.testSchedulerRetry) {
    ++_testAccessibilityAnnouncements;
    lf_append_test_progress([NSString
        stringWithFormat:@"announcement: count=%lu text=%@\n",
                             (unsigned long)_testAccessibilityAnnouncements,
                             announcement]);
  }
}
- (BOOL)publishContentFeedback:(LFHostContentFeedbackState)state
                    generation:(uint64_t)generation
                      basename:(NSString *)basename
                   announcement:(BOOL)announcement {
  NSAssert([NSThread isMainThread], @"content feedback must be published on AppKit");
  if (_window == nil || _closeRequested || generation != _contentAttempt) {
    return NO;
  }
  NSString *title = nil;
  NSString *announcementText = nil;
  switch (state) {
    case LFHostContentFeedbackNoContent:
      title = @"libfuturo — No content";
      announcementText = @"No content is open.";
      basename = nil;
      break;
    case LFHostContentFeedbackOpening:
      title = @"libfuturo — Opening";
      announcementText = @"Opening content.";
      break;
    case LFHostContentFeedbackReady:
      if (basename.length == 0U) {
        return NO;
      }
      title = [NSString stringWithFormat:@"libfuturo — Ready: %@", basename];
      announcementText = [NSString stringWithFormat:@"Ready: %@", basename];
      break;
    case LFHostContentFeedbackUninitialized:
      return NO;
  }
  const BOOL basenameMatches =
      _contentBasename == nil
          ? basename == nil
          : basename != nil && [_contentBasename isEqualToString:basename];
  const BOOL changed = _contentFeedbackState != state || !basenameMatches;
  if (!changed) {
    return YES;
  }
  _contentFeedbackState = state;
  _contentBasename = [basename copy];
  _window.title = title;
  _window.accessibilityTitle = title;
  if (self.testPanelFlow || self.testCliRetry || self.testSchedulerRetry) {
    ++_testFeedbackTransitions;
    if (state == LFHostContentFeedbackReady) {
      ++_testReadyTransitions;
    }
    lf_append_test_progress([NSString
        stringWithFormat:@"feedback: state=%lu title=%@ generation=%llu\n",
                             (unsigned long)state, title,
                             (unsigned long long)generation]);
  }
  if (announcement) {
    [self postAccessibilityAnnouncement:announcementText
                                priority:state == LFHostContentFeedbackReady
                                             ? NSAccessibilityPriorityMedium
                                             : NSAccessibilityPriorityHigh];
  }
  [self updateOpenAction];
  return YES;
}
- (BOOL)canOpenContent {
  return !_opening && _contentFeedbackState != LFHostContentFeedbackOpening &&
         !_closeRequested && _openPanel == nil && _errorAlert == nil;
}
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
  if (menuItem.action == @selector(openContent:)) {
    return [self canOpenContent];
  }
  return YES;
}
- (BOOL)verifyOpenActionForTest:(NSString *)stage
                        enabled:(BOOL)enabled
             pressKeyEquivalent:(BOOL)pressKeyEquivalent
                     activePanel:(NSOpenPanel *)activePanel {
  if (!(self.testPanelFlow || self.testCliRetry || self.testSchedulerRetry ||
        self.testDrainMode != LFHostTestDrainModeNone)) {
    return YES;
  }
  [_fileMenu update];
  BOOL passed = _openButton.enabled == enabled && _openMenuItem.isEnabled == enabled;
  const NSUInteger actionCallsBefore = _testOpenActionInvocations;
  const NSUInteger panelRequestsBefore = _testOpenPanelRequests;
  BOOL handled = NO;
  if (pressKeyEquivalent) {
    NSEvent *event = [NSEvent
        keyEventWithType:NSEventTypeKeyDown
               location:NSZeroPoint
          modifierFlags:NSEventModifierFlagCommand
              timestamp:NSProcessInfo.processInfo.systemUptime
           windowNumber:_window.windowNumber
                context:nil
             characters:@"o"
    charactersIgnoringModifiers:@"o"
               isARepeat:NO
                 keyCode:31];
    handled = [_fileMenu performKeyEquivalent:event];
    if (enabled) {
      passed = passed && handled && _openPanel != nil &&
               _testOpenActionInvocations == actionCallsBefore + 1U &&
               _testOpenPanelRequests == panelRequestsBefore + 1U;
    } else {
      passed = passed && _openPanel == activePanel &&
               _testOpenActionInvocations == actionCallsBefore &&
               _testOpenPanelRequests == panelRequestsBefore;
    }
  }
  if (!passed) {
    _testFlowFailed = YES;
    lf_append_test_progress([NSString
        stringWithFormat:@"test-assertion-failed: open-action stage=%@ expected-enabled=%d button=%d menu=%d key-handled=%d panel-stable=%d action-stable=%d panel-request-stable=%d\n",
                             stage, enabled, _openButton.enabled,
                             _openMenuItem.isEnabled, handled,
                             _openPanel == activePanel,
                             _testOpenActionInvocations == actionCallsBefore,
                             _testOpenPanelRequests == panelRequestsBefore]);
  }
  return pressKeyEquivalent && enabled ? handled && _openPanel != nil : passed;
}
- (BOOL)verifyMinimumWindowGeometryForTest {
  if (!(self.testPanelFlow || self.testCliRetry || self.testSchedulerRetry)) {
    return YES;
  }
  const NSSize minimum = _window.contentMinSize;
  const NSSize requested = NSMakeSize(MAX(minimum.width - 80.0, 1.0),
                                      MAX(minimum.height - 80.0, 1.0));
  const NSRect beforeFrame = _window.frame;
  const NSSize beforeContent = _window.contentView.bounds.size;
  const NSSize beforeContentMinimum = _window.contentMinSize;
  const NSSize beforeFrameMinimum = _window.minSize;
  const NSRect minimumFrameRect = [_window
      frameRectForContentRect:NSMakeRect(0.0, 0.0, minimum.width,
                                         minimum.height)];
  lf_append_test_progress([NSString
      stringWithFormat:@"minimum-size-before: window=%p number=%ld visible=%d attached=%d frame=%.0fx%.0f content=%.0fx%.0f content-min=%.0fx%.0f frame-min-property=%.0fx%.0f required-frame=%.0fx%.0f request=%.0fx%.0f\n",
                           (void *)_window, (long)_window.windowNumber,
                           _window.isVisible,
                           _window.contentView.window == _window,
                           beforeFrame.size.width, beforeFrame.size.height,
                           beforeContent.width, beforeContent.height,
                           beforeContentMinimum.width,
                           beforeContentMinimum.height, beforeFrameMinimum.width,
                           beforeFrameMinimum.height, minimumFrameRect.size.width,
                           minimumFrameRect.size.height, requested.width,
                           requested.height]);
  [_window setContentSize:requested];
  const NSRect afterFrame = _window.frame;
  const NSSize afterContent = _window.contentView.bounds.size;
  const NSRect afterBounds = _window.contentView.bounds;
  lf_append_test_progress([NSString
      stringWithFormat:@"minimum-size-after: window=%p number=%ld frame=%.0fx%.0f content=%.0fx%.0f bounds=%.0fx%.0f\n",
                           (void *)_window, (long)_window.windowNumber,
                           afterFrame.size.width, afterFrame.size.height,
                           afterContent.width, afterContent.height,
                           afterBounds.size.width, afterBounds.size.height]);
  const NSRect requestedFrameRect = [_window
      frameRectForContentRect:NSMakeRect(0.0, 0.0, requested.width,
                                         requested.height)];
  const NSSize clampedFrameSize =
      [self windowWillResize:_window toSize:requestedFrameRect.size];
  const BOOL resizeClamped =
      clampedFrameSize.width + 1.0 >= minimumFrameRect.size.width &&
      clampedFrameSize.height + 1.0 >= minimumFrameRect.size.height;
  NSRect clampedFrame = _window.frame;
  clampedFrame.size = clampedFrameSize;
  [_window setFrame:clampedFrame display:YES];
  [_window.contentView layoutSubtreeIfNeeded];
  const NSRect bounds = _window.contentView.bounds;
  const NSRect legend = _statusLabel.frame;
  const NSRect muteButton = _muteButton.frame;
  const NSRect openButton = _openButton.frame;
  const NSRect video = NSOffsetRect(_gameView.videoFrame,
                                    _gameView.frame.origin.x,
                                    _gameView.frame.origin.y);
  const CGFloat legendWidth = [self maximumAudioFooterWidth];
  const CGFloat muteButtonWidth = [self minimumMuteButtonWidth];
  const BOOL passed =
      resizeClamped &&
      bounds.size.width + 1.0 >= minimum.width &&
      bounds.size.height + 1.0 >= minimum.height &&
      video.size.width + 1.0 >= 320.0 && video.size.height + 1.0 >= 242.0 &&
      legend.size.width + 1.0 >= legendWidth &&
      NSMinX(legend) >= NSMinX(bounds) && NSMaxX(legend) <= NSMaxX(bounds) &&
      muteButton.size.width + 1.0 >= muteButtonWidth &&
      NSMinX(muteButton) >= NSMinX(bounds) &&
      NSMaxX(muteButton) <= NSMaxX(bounds) &&
      NSMinX(openButton) >= NSMinX(bounds) &&
      NSMaxX(openButton) <= NSMaxX(bounds) &&
      NSMaxX(legend) + 1.0 < NSMinX(muteButton) &&
      NSMaxX(muteButton) + 1.0 < NSMinX(openButton) &&
      NSMinY(video) >= NSMaxY(legend) &&
      !NSIntersectsRect(video, muteButton) &&
      !NSIntersectsRect(video, openButton);
  if (!passed) {
    _testFlowFailed = YES;
    lf_append_test_progress([NSString
        stringWithFormat:@"test-assertion-failed: minimum-geometry min=%.0fx%.0f actual=%.0fx%.0f video=%.0fx%.0f legend=%.0fx%.0f mute-x=%.0f open-x=%.0f\n",
                             minimum.width, minimum.height, bounds.size.width,
                             bounds.size.height, video.size.width,
                             video.size.height, legend.size.width,
                             legend.size.height, NSMinX(muteButton),
                             NSMinX(openButton)]);
    return NO;
  }
  lf_append_test_progress([NSString
      stringWithFormat:@"native_host_ui: resize-hook=clamped minimum=%.0fx%.0f content=%.0fx%.0f display=%.0fx%.0f legend=%.0f mute-x=%.0f open-x=%.0f result=pass\n",
                           minimum.width, minimum.height, bounds.size.width,
                           bounds.size.height, video.size.width,
                           video.size.height, legend.size.width,
                           NSMinX(muteButton),
                           NSMinX(openButton)]);
  return YES;
}
- (void)handleSchedulerStart:(BOOL)success
                       error:(NSError *)error
                     session:(LFHostSession *)session
                  generation:(uint64_t)generation
                     attempt:(uint64_t)attempt {
  if (_closeRequested || _session != session || _contentAttempt != attempt ||
      _activeGeneration != generation) {
    return;
  }
  if (!success) {
    if (self.testSchedulerRetry) {
      _testSchedulerFailedSession = session;
      _testSchedulerError = error;
      _testSchedulerGeneration = generation;
      _testSchedulerAttempt = attempt;
    }
    [self showOpenError:error];
  }
}
- (BOOL)handlePresentedFrame:(LFHostFrame *)frame
                     session:(LFHostSession *)session
                     attempt:(uint64_t)attempt {
  if (frame == nil || _closeRequested || _session != session ||
      _contentAttempt != attempt || frame.generation != _activeGeneration) {
    return NO;
  }
  if (_readyAttempt == attempt && _readyGeneration == frame.generation) {
    return YES;
  }
  _readyAttempt = attempt;
  _readyGeneration = frame.generation;
  if (self.testPanelFlow || self.testCliRetry || self.testSchedulerRetry) {
    _testStaleSession = session;
    _testStaleFrame = frame;
    _testStaleAttempt = attempt;
    _testStaleGeneration = frame.generation;
  }
  return [self publishContentFeedback:LFHostContentFeedbackReady
                            generation:attempt
                              basename:_contentBasename
                           announcement:YES];
}
- (void)updateOpenAction {
  const BOOL enabled = [self canOpenContent];
  if (_openButton != nil) {
    _openButton.enabled = enabled;
  }
  if (_fileMenu != nil) {
    [_fileMenu update];
  }
  if (_openButton != nil && _openMenuItem != nil) {
    (void)[self verifyOpenActionForTest:@"state-change"
                               enabled:enabled
                    pressKeyEquivalent:NO
                            activePanel:_openPanel];
  }
}
- (void)openContent:(id)sender {
  (void)sender;
  if (self.testPanelFlow || self.testCliRetry || self.testSchedulerRetry ||
      self.testDrainMode != LFHostTestDrainModeNone) {
    ++_testOpenActionInvocations;
  }
  if (![self canOpenContent]) {
    return;
  }
  [self showOpenPanel];
}
- (void)showOpenPanel {
  if (![self canOpenContent]) {
    return;
  }
  if (self.testPanelFlow || self.testCliRetry || self.testSchedulerRetry ||
      self.testDrainMode != LFHostTestDrainModeNone) {
    ++_testOpenPanelRequests;
  }
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  if (self.testPanelFlow || self.testCliRetry || self.testSchedulerRetry) {
    lf_append_test_progress([NSString
        stringWithFormat:@"panel: step=%lu\n", (unsigned long)_testPanelStep]);
  }
  panel.canChooseFiles = YES;
  panel.canChooseDirectories = NO;
  panel.allowsMultipleSelection = NO;
  UTType *contentType = [UTType typeWithFilenameExtension:@"a78"];
  panel.allowedContentTypes = contentType == nil ? @[] : @[contentType];
  _openPanel = panel;
  [self updateOpenAction];
  (void)[self verifyOpenActionForTest:@"open-sheet"
                             enabled:NO
                  pressKeyEquivalent:YES
                          activePanel:panel];
  (void)[self verifyOpenActionForTest:@"open-sheet"
                             enabled:NO
                  pressKeyEquivalent:YES
                          activePanel:panel];
  __weak LFHostApplicationDelegate *weakSelf = self;
  [panel beginSheetModalForWindow:_window
                completionHandler:^(NSModalResponse response) {
    LFHostApplicationDelegate *strongSelf = weakSelf;
    if (strongSelf != nil) {
      [strongSelf completeOpenPanel:panel
                           response:response
                         selectedURL:response == NSModalResponseOK ? panel.URL : nil];
    }
  }];
  if (self.testPanelFlow || self.testCliRetry || self.testSchedulerRetry) {
    const NSUInteger panelStep = _testPanelStep;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(250U * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
      LFHostApplicationDelegate *strongSelf = weakSelf;
      if (strongSelf == nil || strongSelf->_openPanel != panel ||
          strongSelf->_testPanelStep != panelStep) {
        return;
      }
      if (strongSelf.testCliRetry && panelStep == 0U) {
        NSURL *selectedURL = [NSURL fileURLWithPath:strongSelf.testRetryPath];
        [panel orderOut:nil];
        [strongSelf completeOpenPanel:panel
                             response:NSModalResponseOK
                           selectedURL:selectedURL];
      } else if (strongSelf.testSchedulerRetry && panelStep == 0U) {
        NSURL *selectedURL = [NSURL fileURLWithPath:strongSelf.testRetryPath];
        [panel orderOut:nil];
        [strongSelf completeOpenPanel:panel
                             response:NSModalResponseOK
                           selectedURL:selectedURL];
      } else if (panelStep == 0U && strongSelf.testPanelFlow) {
        [panel cancel:nil];
      } else if (panelStep >= 1U &&
                 panelStep <= strongSelf.testFailurePaths.count) {
        NSString *path = strongSelf.testFailurePaths[panelStep - 1U];
        NSURL *selectedURL = [NSURL fileURLWithPath:path];
        [panel orderOut:nil];
        [strongSelf completeOpenPanel:panel
                             response:NSModalResponseOK
                           selectedURL:selectedURL];
      } else if (panelStep == strongSelf.testFailurePaths.count + 1U) {
        NSURL *selectedURL = [NSURL fileURLWithPath:strongSelf.testRetryPath];
        [panel orderOut:nil];
        [strongSelf completeOpenPanel:panel
                             response:NSModalResponseOK
                           selectedURL:selectedURL];
      }
    });
  }
}
- (void)completeOpenPanel:(NSOpenPanel *)panel
                  response:(NSModalResponse)response
                selectedURL:(NSURL *)selectedURL {
  if (_openPanel != panel) {
    return;
  }
  _openPanel = nil;
  if (self.testPanelFlow || self.testCliRetry || self.testSchedulerRetry) {
    lf_append_test_progress([NSString
        stringWithFormat:@"panel-result: step=%lu selected=%d\n",
                             (unsigned long)_testPanelStep,
                             response == NSModalResponseOK && selectedURL != nil]);
  }
  if (_closeRequested) {
    [self updateOpenAction];
    return;
  }
  if (response != NSModalResponseOK || selectedURL == nil) {
    if (self.testPanelFlow && _testPanelStep == 0U) {
      ++_testPanelCancels;
      @synchronized(self) {
        _testCancelWasIdle = _testInstancesCreated == 0U &&
                             _testLoadsStarted == 0U &&
                             _testInstancesDestroyed == 0U;
      }
      _testPanelStep = 1U;
      [self updateOpenAction];
      if (![self verifyOpenActionForTest:@"after-picker-cancel"
                                 enabled:YES
                      pressKeyEquivalent:YES
                              activePanel:nil] &&
          _openPanel == nil) {
        [self showOpenPanel];
      }
    } else {
      [self updateOpenAction];
    }
    [self restoreGameViewFocus];
    return;
  }
  if (self.testPanelFlow) {
    ++_testSelections;
    if (_testPanelStep == self.testFailurePaths.count) {
      _testFailOutputAllocationOnNextOpen = YES;
    }
    ++_testPanelStep;
  } else if (self.testCliRetry) {
    ++_testSelections;
  } else if (self.testSchedulerRetry) {
    ++_testSelections;
  }
  [self restoreGameViewFocus];
  [self beginOpenContentAtPath:selectedURL.path];
}
- (void)restoreGameViewFocus {
  if (!_closeRequested && _window.isKeyWindow && _openPanel == nil &&
      _errorAlert == nil && _gameView != nil) {
    [_window makeFirstResponder:_gameView];
  }
}
- (void)windowDidBecomeKey:(NSNotification *)notification {
  (void)notification;
  [self restoreGameViewFocus];
}
- (NSSize)windowWillResize:(NSWindow *)sender toSize:(NSSize)frameSize {
  if (sender != _window) {
    return frameSize;
  }
  const NSSize minimumContent = sender.contentMinSize;
  const NSRect minimumFrameRect = [sender
      frameRectForContentRect:NSMakeRect(0.0, 0.0, minimumContent.width,
                                         minimumContent.height)];
  return NSMakeSize(MAX(frameSize.width, minimumFrameRect.size.width),
                    MAX(frameSize.height, minimumFrameRect.size.height));
}
- (void)beginOpenContentAtPath:(NSString *)path {
  if (_opening || _closeRequested || path.length == 0U) {
    return;
  }
  if (self.testProductionView) {
    lf_append_test_progress(@"production-view: open-started\n");
  }
  _opening = YES;
  ++_contentAttempt;
  const uint64_t openAttempt = _contentAttempt;
  _contentBasename = path.lastPathComponent;
  _readyAttempt = 0U;
  _readyGeneration = 0U;
  if (self.testPanelFlow || self.testCliRetry || self.testSchedulerRetry) {
    lf_append_test_progress([NSString
        stringWithFormat:@"open-begin: panel-step=%lu\n",
                             (unsigned long)_testPanelStep]);
  }
  _activeGeneration = 0U;
  _steadyUpdatesStarted = NO;
  [_gameView clearFrame];
  [self publishContentFeedback:LFHostContentFeedbackOpening
                    generation:openAttempt
                      basename:_contentBasename
                   announcement:YES];
  if ((self.testPanelFlow || self.testCliRetry || self.testSchedulerRetry) &&
      _testStaleFrame != nil && _testStaleSession != nil) {
    NSString *openingTitle = _window.title;
    const NSUInteger transitionsBefore = _testFeedbackTransitions;
    const NSUInteger announcementsBefore = _testAccessibilityAnnouncements;
    const BOOL staleAccepted =
        [self handlePresentedFrame:_testStaleFrame
                           session:_testStaleSession
                           attempt:_testStaleAttempt];
    if (staleAccepted || ![_window.title isEqualToString:openingTitle] ||
        _testFeedbackTransitions != transitionsBefore ||
        _testAccessibilityAnnouncements != announcementsBefore) {
      _testFlowFailed = YES;
      lf_append_test_progress(@"test-assertion-failed: stale-presentation-changed-opening-state\n");
    }
  }
  [self updateOpenAction];
  (void)[self verifyOpenActionForTest:@"opening"
                             enabled:NO
                  pressKeyEquivalent:YES
                          activePanel:nil];
  __weak LFHostApplicationDelegate *weakSelf = self;
  void (^startOpen)(void) = ^{
    LFHostApplicationDelegate *strongSelf = weakSelf;
    if (strongSelf == nil || strongSelf->_closeRequested ||
        strongSelf->_contentAttempt != openAttempt) {
      return;
    }
    BOOL failOutputAllocation = strongSelf->_testFailOutputAllocationOnNextOpen;
    strongSelf->_testFailOutputAllocationOnNextOpen = NO;
    LFHostSessionObserver observer = nil;
    if (strongSelf.testPanelFlow || strongSelf.testCliRetry ||
        strongSelf.testSchedulerRetry ||
        strongSelf.testDrainMode != LFHostTestDrainModeNone) {
      @synchronized(strongSelf) {
        strongSelf->_testOpenCreateCountBefore = strongSelf->_testInstancesCreated;
        strongSelf->_testOpenLoadCountBefore = strongSelf->_testLoadsStarted;
        strongSelf->_testOpenLoadFinishCountBefore = strongSelf->_testLoadsFinished;
        strongSelf->_testOpenLoadAcceptedCountBefore = strongSelf->_testLoadsAccepted;
        strongSelf->_testOpenBufferCountBefore = strongSelf->_testBuffersAllocated;
        strongSelf->_testOpenDestroyCountBefore = strongSelf->_testInstancesDestroyed;
      }
      __block BOOL destroyed = NO;
      observer = ^(LFHostSessionEvent event, LFHostFrame *frame,
                   NSData *audioSamples, NSUInteger capacity,
                   uint32_t inputButtons) {
        (void)frame;
        (void)audioSamples;
        (void)capacity;
        (void)inputButtons;
        LFHostApplicationDelegate *observerSelf = weakSelf;
        if (observerSelf == nil) {
          return;
        }
        BOOL shouldBlockGuest = NO;
        @synchronized(observerSelf) {
          const BOOL isDrainTest =
              observerSelf.testDrainMode != LFHostTestDrainModeNone;
          const NSUInteger eventOrder =
              isDrainTest ? ++observerSelf->_testDrainEventOrder : 0U;
          if (destroyed &&
              event != LFHostSessionEventInstanceDestroyed &&
              event != LFHostSessionEventOutputBuffersReleased) {
            observerSelf->_testFlowFailed = YES;
          }
          switch (event) {
            case LFHostSessionEventAdvanceStarted:
              ++observerSelf->_testAdvancesStarted;
              if ((observerSelf.testPanelFlow || observerSelf.testCliRetry ||
                   observerSelf.testSchedulerRetry) &&
                  observerSelf->_testAdvancesStarted <= 3U) {
                lf_append_test_progress([NSString
                    stringWithFormat:@"advance-started: count=%lu\n",
                                         (unsigned long)observerSelf->_testAdvancesStarted]);
              }
              if (isDrainTest && observerSelf->_testAdvancesStarted == 2U) {
                observerSelf->_testDrainAdvanceStartedOrder = eventOrder;
                if (observerSelf.testDrainMode ==
                    LFHostTestDrainModeWindowClose ||
                    observerSelf.testDrainMode ==
                        LFHostTestDrainModeTerminate) {
                  shouldBlockGuest =
                      !observerSelf->_testDrainBarrierScheduled;
                }
              }
              break;
            case LFHostSessionEventInstanceCreated:
              ++observerSelf->_testInstancesCreated;
              break;
            case LFHostSessionEventLoadStarted:
              ++observerSelf->_testLoadsStarted;
              if (isDrainTest) {
                ++observerSelf->_testDrainLoadStartedCount;
                observerSelf->_testDrainLoadStartedOrder = eventOrder;
                if (observerSelf.testDrainMode ==
                    LFHostTestDrainModeLoadErrorClose) {
                  shouldBlockGuest =
                      !observerSelf->_testDrainBarrierScheduled;
                }
              }
              break;
            case LFHostSessionEventLoadFinished:
              ++observerSelf->_testLoadsFinished;
              if (isDrainTest) {
                ++observerSelf->_testDrainLoadFinishedCount;
                observerSelf->_testDrainLoadFinishedOrder = eventOrder;
              }
              break;
            case LFHostSessionEventLoadAccepted:
              ++observerSelf->_testLoadsAccepted;
              break;
            case LFHostSessionEventOutputBuffersAllocated:
              ++observerSelf->_testBuffersAllocated;
              break;
            case LFHostSessionEventContentReleased:
              ++observerSelf->_testContentReleased;
              if (isDrainTest) {
                ++observerSelf->_testDrainContentReleasedCount;
                observerSelf->_testDrainContentReleasedOrder = eventOrder;
              }
              break;
            case LFHostSessionEventInstanceDestroyed:
              if (destroyed) {
                observerSelf->_testFlowFailed = YES;
              }
              destroyed = YES;
              ++observerSelf->_testInstancesDestroyed;
              if (isDrainTest) {
                ++observerSelf->_testDrainDestroyCount;
                observerSelf->_testDrainDestroyOrder = eventOrder;
              }
              break;
            case LFHostSessionEventAdvanceFinished:
              if (isDrainTest) {
                ++observerSelf->_testDrainAdvanceFinishedCount;
                observerSelf->_testDrainAdvanceFinishedOrder = eventOrder;
              }
              break;
            case LFHostSessionEventInputSampled:
              if (isDrainTest &&
                  observerSelf->_testAdvancesStarted == 2U) {
                observerSelf->_testDrainInputSampledOrder = eventOrder;
              }
              break;
            case LFHostSessionEventCoreAdvanceStarted:
              if (isDrainTest &&
                  observerSelf->_testAdvancesStarted == 2U) {
                observerSelf->_testDrainCoreAdvanceStartedOrder = eventOrder;
              }
              break;
            case LFHostSessionEventOutputBuffersReleased:
              if (isDrainTest) {
                ++observerSelf->_testDrainBuffersReleasedCount;
                observerSelf->_testDrainBuffersReleasedOrder = eventOrder;
              }
              break;
            case LFHostSessionEventFrameInvalidationScheduled:
              break;
          }
          if (shouldBlockGuest) {
            observerSelf->_testDrainBarrierScheduled = YES;
          }
        }
        if (shouldBlockGuest) {
          [observerSelf blockGuestCallForDrainTest];
        }
      };
    }
    if (strongSelf.testProductionView) {
      __weak LFHostApplicationDelegate *observerSelf = strongSelf;
      observer = ^(LFHostSessionEvent event, LFHostFrame *frame,
                   NSData *audioSamples, NSUInteger capacity,
                   uint32_t inputButtons) {
        (void)frame;
        (void)audioSamples;
        (void)capacity;
        const char *eventName = NULL;
        switch (event) {
          case LFHostSessionEventAdvanceStarted:
            eventName = "advance-started";
            break;
          case LFHostSessionEventAdvanceFinished:
            eventName = "advance-finished";
            break;
          case LFHostSessionEventInstanceDestroyed:
            eventName = "instance-destroyed";
            break;
          case LFHostSessionEventContentReleased:
            eventName = "content-released";
            break;
          case LFHostSessionEventInstanceCreated:
            eventName = "instance-created";
            break;
          case LFHostSessionEventLoadStarted:
            eventName = "load-started";
            break;
          case LFHostSessionEventLoadFinished:
            eventName = "load-finished";
            break;
          case LFHostSessionEventOutputBuffersAllocated:
            eventName = "output-buffers-allocated";
            break;
          case LFHostSessionEventLoadAccepted:
            eventName = "load-accepted";
            break;
          case LFHostSessionEventInputSampled:
            eventName = "input-sampled";
            break;
          case LFHostSessionEventCoreAdvanceStarted:
            eventName = "core-advance-started";
            break;
          case LFHostSessionEventOutputBuffersReleased:
            eventName = "output-buffers-released";
            break;
          case LFHostSessionEventFrameInvalidationScheduled:
            eventName = "frame-invalidation-scheduled";
            break;
        }
        if (eventName != NULL) {
          lf_append_test_progress([NSString
              stringWithFormat:@"session-event=%s\n", eventName]);
        }
        if (event != LFHostSessionEventInputSampled) {
          return;
        }
        LFHostApplicationDelegate *observedSelf = observerSelf;
        if (observedSelf == nil) {
          return;
        }
        @synchronized(observedSelf) {
          if (!observedSelf->_productionInputSampled) {
            observedSelf->_productionInputSampled = YES;
            observedSelf->_productionInputSeedSeen =
                inputButtons == UINT32_C(0x0001);
          }
        }
      };
    }
    LFHostOutputAllocator allocator = nil;
    if (failOutputAllocation) {
      allocator = ^void *(size_t count, size_t size) {
        (void)count;
        (void)size;
        return NULL;
      };
    }
    const BOOL enableAudioOutput =
        !strongSelf.testPanelFlow && !strongSelf.testCliRetry &&
        !strongSelf.testSchedulerRetry &&
        strongSelf.testDrainMode == LFHostTestDrainModeNone;
    if (strongSelf.testProductionView) {
      lf_append_test_progress(@"production-view: audio-init=begin\n");
    }
    LFAudioOutput *audioOutput =
        enableAudioOutput
            ? [[LFAudioOutput alloc]
                  initWithManualRendering:NO
                  requirePlaybackEvidence:strongSelf.testProductionView
                  lockFreeCheckOverride:nil]
            : nil;
    if (strongSelf.testProductionView) {
      lf_append_test_progress([NSString
          stringWithFormat:@"production-view: audio-init=returned object=%d\n",
                               audioOutput != nil]);
    }
    lf_live_audio_output = audioOutput;
    __block __weak LFHostSession *weakSession = nil;
    LFHostClock clock = nil;
    if (strongSelf.testSchedulerRetry &&
        !strongSelf->_testSchedulerFaultApplied) {
      clock = ^uint64_t{ return UINT64_MAX; };
      strongSelf->_testSchedulerFaultApplied = YES;
    }
    if (strongSelf.testProductionView) {
      lf_append_test_progress(@"production-view: session-init=begin\n");
    }
    LFHostSession *session = [[LFHostSession alloc]
        initWithFrameHandler:^(LFHostFrame *frame) {
          LFHostApplicationDelegate *frameSelf = weakSelf;
          if (frameSelf != nil &&
              (frameSelf.testPanelFlow || frameSelf.testCliRetry ||
               frameSelf.testSchedulerRetry) &&
              frame.sequence <= 3U) {
            lf_append_test_progress([NSString
                stringWithFormat:@"session-frame: generation=%llu sequence=%llu\n",
                                     (unsigned long long)frame.generation,
                                     (unsigned long long)frame.sequence]);
          }
          if (frameSelf == nil || frameSelf->_closeRequested ||
              frameSelf->_session != weakSession) {
            return;
          }
          frameSelf->_activeGeneration = frame.generation;
          if (frameSelf.testProductionView && frame.sequence == 1U) {
            lf_append_test_progress(@"production-view: first-frame\n");
          }
          [frameSelf->_gameView showFrame:frame];
        }
        callbackQueue:dispatch_get_main_queue()
                clock:clock
             observer:observer
      outputAllocator:allocator
          audioOutput:audioOutput];
    if (strongSelf.testProductionView) {
      lf_append_test_progress([NSString
          stringWithFormat:@"production-view: session-init=returned object=%d\n",
                               session != nil]);
    }
    weakSession = session;
    strongSelf->_session = session;
    [session setAudioMuted:strongSelf->_audioMuted];
    [session setInputButtons:strongSelf.testProductionView
                                 ? UINT32_C(0x0001)
                                 : strongSelf->_inputState.buttons];
    if (strongSelf.testProductionView) {
      lf_append_test_progress(@"production-view: open-call=begin\n");
    }
    [session openContentAtPath:path completion:^(BOOL success, NSError *error) {
      LFHostApplicationDelegate *completedSelf = weakSelf;
      if (completedSelf == nil || completedSelf->_session != weakSession ||
          completedSelf->_contentAttempt != openAttempt) {
        return;
      }
      if (completedSelf.testProductionView) {
        NSString *errorDomain = error.domain.length > 0U ? error.domain : @"none";
        lf_append_test_progress([NSString
            stringWithFormat:@"production-view: open-completion success=%d error-domain=%@ error-code=%ld\n",
                                 success, errorDomain, (long)error.code]);
      }
      if (completedSelf->_closeRequested) {
        if (!success && completedSelf.testDrainMode ==
                            LFHostTestDrainModeLoadErrorClose) {
          completedSelf->_testDrainErrorSuppressed = YES;
          lf_append_test_progress(
              @"drain-open-completion: close-requested=1 error-suppressed=1\n");
        }
        return;
      }
      completedSelf->_opening = NO;
      [completedSelf updateOpenAction];
      if (success) {
        if (completedSelf.testPanelFlow || completedSelf.testCliRetry ||
            completedSelf.testSchedulerRetry) {
          lf_append_test_progress(@"open-result: success\n");
        }
        return;
      }
      if (completedSelf.testPanelFlow || completedSelf.testCliRetry ||
          completedSelf.testSchedulerRetry) {
        lf_append_test_progress([NSString
            stringWithFormat:@"open-result: failure errors=%lu reader=%lu load=%lu allocation=%lu\n",
                                 (unsigned long)completedSelf->_testErrorsShown,
                                 (unsigned long)completedSelf->_testReaderFailures,
                                 (unsigned long)completedSelf->_testLoadFailures,
                                 (unsigned long)completedSelf->_testOutputAllocationFailures]);
      }
      if (completedSelf.testDrainMode ==
          LFHostTestDrainModeLoadErrorClose) {
        lf_append_test_progress([NSString
            stringWithFormat:@"drain-open-completion: close-requested=%d error-suppressed=%d\n",
                                 completedSelf->_closeRequested,
                                 completedSelf->_testDrainErrorSuppressed]);
      }
      [completedSelf showOpenError:error];
    }];
    if (strongSelf.testProductionView) {
      lf_append_test_progress(@"production-view: open-call=returned\n");
    }
  };
  LFHostSession *previousSession = _session;
  _session = nil;
  if (previousSession != nil) {
    [previousSession stopWithCompletion:startOpen];
  } else {
    startOpen();
  }
}
- (void)showOpenError:(NSError *)error {
  if (_closeRequested || _errorAlert != nil) {
    if (self.testDrainMode == LFHostTestDrainModeLoadErrorClose) {
      lf_append_test_progress([NSString
          stringWithFormat:@"drain-error-presentation: suppressed close=%d alert=%d\n",
                               _closeRequested, _errorAlert != nil]);
    }
    return;
  }
  if (self.testProductionView) {
    self.exitCode = 1;
    __weak LFHostApplicationDelegate *weakSelf = self;
    [self requestDrainWithCompletion:^{
      LFHostApplicationDelegate *strongSelf = weakSelf;
      if (strongSelf != nil) {
        [strongSelf->_window performClose:nil];
      }
    }];
    return;
  }
  _opening = NO;
  [self publishContentFeedback:LFHostContentFeedbackNoContent
                    generation:_contentAttempt
                      basename:nil
                   announcement:NO];
  if (self.testPanelFlow || self.testCliRetry) {
    @synchronized(self) {
      const NSUInteger createDelta =
          _testInstancesCreated - _testOpenCreateCountBefore;
      const NSUInteger loadDelta = _testLoadsStarted - _testOpenLoadCountBefore;
      const NSUInteger loadFinishDelta =
          _testLoadsFinished - _testOpenLoadFinishCountBefore;
      const NSUInteger acceptedDelta =
          _testLoadsAccepted - _testOpenLoadAcceptedCountBefore;
      const NSUInteger bufferDelta =
          _testBuffersAllocated - _testOpenBufferCountBefore;
      const NSUInteger contentReleaseDelta =
          _testContentReleased - _testOpenLoadCountBefore;
      const NSUInteger destroyDelta =
          _testInstancesDestroyed - _testOpenDestroyCountBefore;
      if (![error.domain isEqualToString:LFHostSessionErrorDomain]) {
        _testFlowFailed = YES;
      }
      if (loadDelta == 0U) {
        if (createDelta != 0U || loadFinishDelta != 0U ||
            contentReleaseDelta != 0U || destroyDelta != 0U ||
            error.code != LFHostSessionErrorReader ||
            error.userInfo[NSUnderlyingErrorKey] == nil) {
          _testFlowFailed = YES;
        } else {
          ++_testReaderFailures;
        }
      } else if (createDelta != 1U || loadDelta != 1U ||
                 loadFinishDelta != 1U || destroyDelta != 1U ||
                 contentReleaseDelta != 1U || acceptedDelta > 1U ||
                 bufferDelta > 1U ||
                 ![error.domain isEqualToString:LFHostSessionErrorDomain]) {
        _testFlowFailed = YES;
      } else if (acceptedDelta == 0U && bufferDelta == 0U) {
        if (error.code != LFHostSessionErrorLoad ||
            error.userInfo[LFHostSessionCoreStatusKey] == nil) {
          _testFlowFailed = YES;
        }
        ++_testLoadFailures;
      } else if (acceptedDelta == 1U && bufferDelta == 0U) {
        if (error.code != LFHostSessionErrorOutputAllocation) {
          _testFlowFailed = YES;
        }
        ++_testOutputAllocationFailures;
      } else {
        _testFlowFailed = YES;
      }
      ++_testErrorsShown;
      lf_append_test_progress([NSString
          stringWithFormat:@"error-shown: count=%lu reader=%lu load=%lu allocation=%lu\n",
                               (unsigned long)_testErrorsShown,
                               (unsigned long)_testReaderFailures,
                               (unsigned long)_testLoadFailures,
                               (unsigned long)_testOutputAllocationFailures]);
    }
  }
  NSAlert *alert = [[NSAlert alloc] init];
  const BOOL contentFailure =
      [error.domain isEqualToString:LFHostSessionErrorDomain] &&
      (error.code == LFHostSessionErrorReader ||
       error.code == LFHostSessionErrorLoad);
  const BOOL playbackFailure =
      [error.domain isEqualToString:LFHostSessionErrorDomain] &&
      (error.code == LFHostSessionErrorAdvance ||
       error.code == LFHostSessionErrorScheduler);
  if (contentFailure) {
    alert.messageText = @"Could not open content";
    alert.informativeText =
        @"The selected content could not be opened. Check that it is supported and try again.";
  } else if (playbackFailure) {
    alert.messageText = @"Playback could not start";
    alert.informativeText =
        @"The content opened, but playback could not start. Dismiss this message and choose Open… to try again.";
  } else {
    alert.messageText = @"Could not start the session";
    alert.informativeText =
        @"The selected content could not be started. Dismiss this message and choose Open… to try again.";
  }
  if (self.testPanelFlow || self.testCliRetry || self.testSchedulerRetry) {
    @synchronized(self) {
      for (NSString *failurePath in self.testFailurePaths) {
        if ([alert.messageText containsString:failurePath] ||
            [alert.informativeText containsString:failurePath]) {
          _testFlowFailed = YES;
        }
      }
      if ([alert.messageText containsString:self.testRetryPath] ||
          [alert.informativeText containsString:self.testRetryPath]) {
        _testFlowFailed = YES;
      }
    }
  }
  [alert addButtonWithTitle:@"OK"];
  _errorAlert = alert;
  [self updateOpenAction];
  if (self.testSchedulerRetry) {
    const NSUInteger createDelta =
        _testInstancesCreated - _testOpenCreateCountBefore;
    const NSUInteger loadDelta = _testLoadsStarted - _testOpenLoadCountBefore;
    const NSUInteger finishDelta =
        _testLoadsFinished - _testOpenLoadFinishCountBefore;
    const NSUInteger acceptedDelta =
        _testLoadsAccepted - _testOpenLoadAcceptedCountBefore;
    const NSUInteger bufferDelta =
        _testBuffersAllocated - _testOpenBufferCountBefore;
    const NSUInteger releasedDelta =
        _testContentReleased - _testOpenLoadCountBefore;
    const NSUInteger destroyDelta =
        _testInstancesDestroyed - _testOpenDestroyCountBefore;
    const BOOL schedulerCleanupPassed =
        error.code == LFHostSessionErrorScheduler &&
        [error.domain isEqualToString:LFHostSessionErrorDomain] &&
        createDelta == 1U && loadDelta == 1U && finishDelta == 1U &&
        acceptedDelta == 1U && bufferDelta == 1U && releasedDelta == 1U &&
        destroyDelta == 1U && !contentFailure && playbackFailure &&
        [alert.messageText isEqualToString:@"Playback could not start"] &&
        [alert.informativeText containsString:@"choose Open…"];
    if (!schedulerCleanupPassed) {
      _testFlowFailed = YES;
      lf_append_test_progress([NSString
          stringWithFormat:@"test-assertion-failed: scheduler-cleanup code=%ld create=%lu load=%lu finish=%lu accepted=%lu buffers=%lu released=%lu destroyed=%lu\n",
                               (long)error.code, (unsigned long)createDelta,
                               (unsigned long)loadDelta,
                               (unsigned long)finishDelta,
                               (unsigned long)acceptedDelta,
                               (unsigned long)bufferDelta,
                               (unsigned long)releasedDelta,
                               (unsigned long)destroyDelta]);
    }
    ++_testSchedulerErrorsShown;
    ++_testErrorsShown;
    [self postAccessibilityAnnouncement:alert.messageText
                                priority:NSAccessibilityPriorityHigh];
    lf_append_test_progress([NSString
        stringWithFormat:@"scheduler-error: code=%ld destroyed-before-alert=%lu playback-copy=%d\n",
                             (long)error.code, (unsigned long)destroyDelta,
                             playbackFailure]);
    (void)[self verifyOpenActionForTest:@"scheduler-alert"
                               enabled:NO
                    pressKeyEquivalent:YES
                            activePanel:nil];
  } else if (self.testPanelFlow || self.testCliRetry) {
    [self postAccessibilityAnnouncement:alert.messageText
                                priority:NSAccessibilityPriorityHigh];
  }
  __weak LFHostApplicationDelegate *weakSelf = self;
  [alert beginSheetModalForWindow:_window completionHandler:^(NSModalResponse response) {
    (void)response;
    LFHostApplicationDelegate *strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }
    strongSelf->_errorAlert = nil;
    if (strongSelf.testPanelFlow || strongSelf.testCliRetry ||
        strongSelf.testSchedulerRetry) {
      @synchronized(strongSelf) {
        ++strongSelf->_testErrorsDismissed;
      }
    }
    [strongSelf updateOpenAction];
    if (strongSelf.testCliRetry && !strongSelf->_testCliRetryPanelShown) {
      strongSelf->_testCliRetryPanelShown = YES;
      [strongSelf showOpenPanel];
    } else if (strongSelf.testSchedulerRetry &&
               !strongSelf->_testSchedulerRetryPanelShown) {
      strongSelf->_testSchedulerRetryPanelShown = YES;
      (void)[strongSelf verifyOpenActionForTest:@"scheduler-dismissed"
                                         enabled:YES
                              pressKeyEquivalent:NO
                                      activePanel:nil];
      [strongSelf showOpenPanel];
    } else if (strongSelf.testPanelFlow &&
        strongSelf->_testPanelStep <= strongSelf.testFailurePaths.count + 1U) {
      [strongSelf showOpenPanel];
    }
    [strongSelf restoreGameViewFocus];
  }];
  if (self.testPanelFlow || self.testCliRetry || self.testSchedulerRetry) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(250U * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
      LFHostApplicationDelegate *strongSelf = weakSelf;
      if (strongSelf == nil || strongSelf->_errorAlert != alert ||
          alert.buttons.count == 0U) {
        return;
      }
      [alert.buttons.firstObject performClick:nil];
    });
  }
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
  (void)sender;
  return YES;
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
  if (_closeReady) {
    return NSTerminateNow;
  }
  if (_terminationReplyPending) {
    return NSTerminateLater;
  }
  _terminationReplyPending = YES;
  __weak LFHostApplicationDelegate *weakSelf = self;
  [self requestDrainWithCompletion:^{
    LFHostApplicationDelegate *strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }
    [sender replyToApplicationShouldTerminate:YES];
  }];
  return NSTerminateLater;
}
- (void)applicationWillTerminate:(NSNotification *)notification {
  (void)notification;
  _testDrainApplicationWillTerminate =
      self.testDrainMode != LFHostTestDrainModeNone;
  [_inputState stopObserving];
  [_gameView clearFrame];
  if (self.testDrainMode != LFHostTestDrainModeNone) {
    if (![self finishDrainTest] ||
        !lf_write_test_result(lf_test_result_path)) {
      exit(EXIT_FAILURE);
    }
    (void)fputs(lf_test_result_marker(), stdout);
    (void)fflush(stdout);
    exit(EXIT_SUCCESS);
  }
}
- (BOOL)windowShouldClose:(NSWindow *)sender {
  (void)sender;
  if (_closeReady) {
    if (self.closeAfterPresentations > 0U && !_printedSuccess) {
      if (!_window.isVisible ||
          _window.firstResponder != _gameView ||
          _gameView.completedPresentations < self.closeAfterPresentations) {
        self.exitCode = 1;
        return YES;
      }
      _printedSuccess = YES;
      _testCloseCompleted = YES;
    }
    return YES;
  }
  if (!_closeRequested) {
    __weak LFHostApplicationDelegate *weakSelf = self;
    [self requestDrainWithCompletion:^{
        LFHostApplicationDelegate *strongSelf = weakSelf;
        if (strongSelf == nil) {
          return;
        }
        if (strongSelf.testDrainMode ==
            LFHostTestDrainModeLoadErrorClose) {
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                       (int64_t)(50U * NSEC_PER_MSEC)),
                         dispatch_get_main_queue(), ^{
            [strongSelf->_window performClose:nil];
          });
        } else {
          [strongSelf->_window performClose:nil];
        }
      }];
  }
  return NO;
}
- (void)windowWillClose:(NSNotification *)notification {
  (void)notification;
  _testDrainWindowClosed =
      self.testDrainMode != LFHostTestDrainModeNone;
  [_inputState stopObserving];
  if (self.testProductionView) {
    const BOOL audioPlayed = [lf_live_audio_output hasDataPlayedBack];
    lf_append_test_progress([NSString
        stringWithFormat:@"production-view: window-will-close close-completed=%d view-passed=%d audio-played=%d\n",
                             _testCloseCompleted,
                             lf_test_production_view_passed, audioPlayed]);
  }
  if (self.closeAfterPresentations > 0U && _testCloseCompleted) {
    if (self.testPanelFlow || self.testCliRetry || self.testSchedulerRetry) {
      lf_append_test_progress([NSString
          stringWithFormat:@"window-close: presentations=%llu errors=%lu dismissed=%lu selections=%lu\n",
                               (unsigned long long)_gameView.completedPresentations,
                               (unsigned long)_testErrorsShown,
                               (unsigned long)_testErrorsDismissed,
                               (unsigned long)_testSelections]);
    }
    if (lf_test_panel_flow) {
      @synchronized(self) {
        const BOOL countersMatch =
            !_testFlowFailed && _testPanelCancels == 1U && _testCancelWasIdle &&
            _testErrorsShown == self.testFailurePaths.count &&
            _testErrorsDismissed == self.testFailurePaths.count &&
            _testSelections == self.testFailurePaths.count + 1U &&
            _testReaderFailures == 6U && _testLoadFailures == 2U &&
            _testOutputAllocationFailures == 1U &&
            _testInstancesCreated == 4U && _testLoadsStarted == 4U &&
            _testLoadsFinished == 4U && _testLoadsAccepted == 2U &&
            _testContentReleased == 4U && _testBuffersAllocated == 1U &&
            _testInstancesDestroyed == 4U && _testAdvancesStarted >= 2U;
        if (!countersMatch) {
          (void)fprintf(stderr, "native host open retry: flow oracle failed\n");
          exit(EXIT_FAILURE);
        }
      }
    } else if (lf_test_cli_retry) {
      @synchronized(self) {
        const BOOL countersMatch =
            !_testFlowFailed && _testCliRetryPanelShown &&
            _testErrorsShown == 1U && _testErrorsDismissed == 1U &&
            _testSelections == 1U && _testReaderFailures == 0U &&
            _testLoadFailures == 1U && _testOutputAllocationFailures == 0U &&
            _testInstancesCreated == 2U && _testLoadsStarted == 2U &&
            _testLoadsFinished == 2U && _testLoadsAccepted == 1U &&
            _testContentReleased == 2U && _testBuffersAllocated == 1U &&
            _testInstancesDestroyed == 2U && _testAdvancesStarted >= 2U;
        if (!countersMatch) {
          (void)fprintf(stderr, "native host CLI retry: flow oracle failed\n");
          exit(EXIT_FAILURE);
        }
      }
    } else if (lf_test_scheduler_retry) {
      @synchronized(self) {
        const BOOL countersMatch =
            !_testFlowFailed && _testSchedulerRetryPanelShown &&
            _testSchedulerRetryReadyCount == 1U &&
            _testSchedulerErrorsShown == 1U && _testReadyTransitions == 2U &&
            _testErrorsShown == 1U && _testErrorsDismissed == 1U &&
            _testSelections == 1U && _testInstancesCreated == 2U &&
            _testLoadsStarted == 2U && _testLoadsFinished == 2U &&
            _testLoadsAccepted == 2U && _testContentReleased == 2U &&
            _testBuffersAllocated == 2U && _testInstancesDestroyed == 2U &&
            _testAdvancesStarted >= 3U &&
            _contentFeedbackState == LFHostContentFeedbackReady &&
            [_window.title containsString:@"Ready:"];
        if (!countersMatch) {
          (void)fprintf(stderr,
                        "native host scheduler retry: flow oracle failed\n");
          exit(EXIT_FAILURE);
        }
      }
    }
    if (lf_test_result_path != nil &&
        !lf_write_test_result(lf_test_result_path)) {
      (void)fprintf(stderr, "could not write native host smoke result\n");
      exit(EXIT_FAILURE);
    }
    if (lf_test_panel_flow) {
      (void)printf("installed_macos_host: picker=present cancel=idle reader=6 "
                   "load=2 allocation=1 retry=presented result=pass\n");
    } else if (lf_test_cli_retry) {
      (void)printf("installed_macos_host: cli=invalid-load "
                   "error=after-cleanup retry=presented result=pass\n");
    } else if (lf_test_scheduler_retry) {
      (void)printf("installed_macos_host: scheduler=overflow cleanup=before-alert "
                   "retry=presented result=pass\n");
    } else {
      (void)printf("installed_macos_host: profile=muhtari-ntsc-v1 "
                   "native-window=pass presentation=pass close=pass result=pass\n");
    }
    (void)fflush(stdout);
    exit(EXIT_SUCCESS);
  }
}
- (BOOL)testCloseCompleted {
  return _testCloseCompleted;
}
- (BOOL)finishDrainTest {
  const BOOL advanceCase =
      self.testDrainMode == LFHostTestDrainModeWindowClose ||
      self.testDrainMode == LFHostTestDrainModeTerminate;
  const BOOL errorCase =
      self.testDrainMode == LFHostTestDrainModeLoadErrorClose;
  BOOL ordered = NO;
  if (advanceCase) {
    ordered = _testDrainAdvanceStartedOrder > 0U &&
              _testDrainAdvanceStartedOrder < _testDrainInputSampledOrder &&
              _testDrainInputSampledOrder < _testDrainCoreAdvanceStartedOrder &&
              _testDrainCoreAdvanceStartedOrder < _testDrainAdvanceFinishedOrder &&
              _testDrainAdvanceFinishedOrder < _testDrainDestroyOrder;
  } else if (errorCase) {
    ordered = _testDrainLoadStartedOrder > 0U &&
              _testDrainLoadStartedOrder < _testDrainContentReleasedOrder &&
              _testDrainContentReleasedOrder < _testDrainLoadFinishedOrder &&
              _testDrainLoadFinishedOrder < _testDrainDestroyOrder;
  }
  const BOOL common =
      _testDrainBarrierScheduled && !_testDrainBarrierTimedOut &&
      _testDrainRequestReturned && _testDrainMainSentinel &&
      _testDrainOpenUnavailable &&
      _testDrainCompletionSeen && _testDrainCompletionOrder > 0U && ordered &&
      _testDrainDestroyCount == 1U &&
      _testDrainBuffersReleasedCount == 1U &&
      _testDrainDestroyOrder < _testDrainBuffersReleasedOrder &&
      _testDrainBuffersReleasedOrder < _testDrainCompletionOrder &&
      _testInstancesCreated == 1U && _testInstancesDestroyed == 1U &&
      _testLoadsFinished == 1U && _testContentReleased == 1U;
  const BOOL caseSpecific =
      errorCase
          ? (_testDrainLoadStartedCount == 1U &&
             _testDrainLoadFinishedCount == 1U &&
             _testDrainContentReleasedCount == 1U &&
             _testDrainErrorSuppressed && _errorAlert == nil &&
             _testAdvancesStarted == 0U && _testBuffersAllocated == 0U &&
             _testDrainWindowClosed && _testDrainApplicationWillTerminate)
          : (_testAdvancesStarted == 2U &&
             _testDrainLoadStartedCount == 1U &&
             _testDrainLoadFinishedCount == 1U &&
             _testDrainContentReleasedCount == 1U &&
             _testDrainAdvanceFinishedCount == 2U &&
             _testDrainAdvanceFinishedOrder < _testDrainDestroyOrder &&
             _testBuffersAllocated == 1U &&
             _testDrainKeyConsumed && _testDrainResizeHandled &&
             (self.testDrainMode == LFHostTestDrainModeTerminate
                  ? _testDrainApplicationWillTerminate
                  : (_testDrainWindowClosed &&
                     _testDrainApplicationWillTerminate)));
  const BOOL passed = common && caseSpecific;
  if (!passed) {
    (void)fprintf(stderr,
                  "native host lifecycle: drain oracle failed mode=%lu "
                  "advances=%lu loads=%lu destroyed=%lu released=%lu "
                  "timeout=%d sentinel=%d error-suppressed=%d\n",
                  (unsigned long)self.testDrainMode,
                  (unsigned long)_testAdvancesStarted,
                  (unsigned long)_testDrainLoadStartedCount,
                  (unsigned long)_testDrainDestroyCount,
                  (unsigned long)_testDrainBuffersReleasedCount,
                  _testDrainBarrierTimedOut, _testDrainMainSentinel,
                  _testDrainErrorSuppressed);
    if (lf_test_result_path != nil) {
      NSString *diagnostic = [NSString
          stringWithFormat:
              @"installed_macos_host: lifecycle=failed mode=%lu advances=%lu "
               "advance-finishes=%lu loads=%lu load-finishes=%lu "
               "content-released=%lu destroyed=%lu buffers-released=%lu "
               "completion=%d request-returned=%d sentinel=%d timeout=%d "
               "window-closed=%d will-terminate=%d error-suppressed=%d\n",
              (unsigned long)self.testDrainMode,
              (unsigned long)_testAdvancesStarted,
              (unsigned long)_testDrainAdvanceFinishedCount,
              (unsigned long)_testDrainLoadStartedCount,
              (unsigned long)_testDrainLoadFinishedCount,
              (unsigned long)_testDrainContentReleasedCount,
              (unsigned long)_testDrainDestroyCount,
              (unsigned long)_testDrainBuffersReleasedCount,
              _testDrainCompletionSeen, _testDrainRequestReturned,
              _testDrainMainSentinel, _testDrainBarrierTimedOut,
              _testDrainWindowClosed, _testDrainApplicationWillTerminate,
              _testDrainErrorSuppressed];
      NSData *bytes = [diagnostic dataUsingEncoding:NSUTF8StringEncoding];
      int descriptor = open(lf_test_result_path.fileSystemRepresentation,
                            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                            S_IRUSR | S_IWUSR);
      if (descriptor >= 0) {
        (void)write(descriptor, bytes.bytes, bytes.length);
        (void)close(descriptor);
      }
    }
  }
  return passed;
}
@end

static BOOL lf_parse_arguments(int argc, const char *argv[],
                               NSString **contentPath,
                               NSArray<NSString *> **testFailurePaths,
                               NSString **testRetryPath,
                               BOOL *testPanelFlow,
                               BOOL *testCliRetry,
                               BOOL *testSchedulerRetry,
                               LFHostTestDrainMode *testDrainMode,
                               NSUInteger *closeAfterPresentations,
                               NSString **testResultPath,
                               BOOL *testProductionView) {
  BOOL foundContent = NO;
  BOOL foundResultPath = NO;
  BOOL foundRetryPath = NO;
  BOOL foundDrainMode = NO;
  BOOL foundProductionView = NO;
  NSMutableArray<NSString *> *failurePaths = [NSMutableArray array];
  NSUInteger closeCount = 0U;
  for (int index = 1; index < argc; ++index) {
    if (strcmp(argv[index], "--content") == 0 && index + 1 < argc) {
      if (foundContent) {
        return NO;
      }
      *contentPath = [NSString stringWithUTF8String:argv[++index]];
      if (*contentPath == nil || (*contentPath).length == 0U) {
        return NO;
      }
      foundContent = YES;
    } else if (strcmp(argv[index], "--test-panel-flow") == 0) {
      if (*testPanelFlow) {
        return NO;
      }
      *testPanelFlow = YES;
    } else if (strcmp(argv[index], "--test-cli-retry") == 0 &&
               index + 1 < argc) {
      if (*testCliRetry || foundRetryPath) {
        return NO;
      }
      *testRetryPath = [NSString stringWithUTF8String:argv[++index]];
      if (*testRetryPath == nil || (*testRetryPath).length == 0U) {
        return NO;
      }
      *testCliRetry = YES;
      foundRetryPath = YES;
    } else if (strcmp(argv[index], "--test-scheduler-retry") == 0 &&
               index + 1 < argc) {
      if (*testSchedulerRetry || foundRetryPath) {
        return NO;
      }
      *testRetryPath = [NSString stringWithUTF8String:argv[++index]];
      if (*testRetryPath == nil || (*testRetryPath).length == 0U) {
        return NO;
      }
      *testSchedulerRetry = YES;
      foundRetryPath = YES;
    } else if (strcmp(argv[index], "--test-drain-close") == 0 ||
               strcmp(argv[index], "--test-drain-quit") == 0 ||
               strcmp(argv[index], "--test-drain-close-error") == 0) {
      if (foundDrainMode) {
        return NO;
      }
      foundDrainMode = YES;
      if (strcmp(argv[index], "--test-drain-close") == 0) {
        *testDrainMode = LFHostTestDrainModeWindowClose;
      } else if (strcmp(argv[index], "--test-drain-quit") == 0) {
        *testDrainMode = LFHostTestDrainModeTerminate;
      } else {
        *testDrainMode = LFHostTestDrainModeLoadErrorClose;
      }
    } else if (strcmp(argv[index], "--test-panel-failure") == 0 &&
               index + 1 < argc) {
      NSString *failurePath = [NSString stringWithUTF8String:argv[++index]];
      if (failurePath == nil || failurePath.length == 0U) {
        return NO;
      }
      [failurePaths addObject:failurePath];
    } else if (strcmp(argv[index], "--test-retry") == 0 && index + 1 < argc) {
      if (foundRetryPath) {
        return NO;
      }
      *testRetryPath = [NSString stringWithUTF8String:argv[++index]];
      if (*testRetryPath == nil || (*testRetryPath).length == 0U) {
        return NO;
      }
      foundRetryPath = YES;
    } else if (strcmp(argv[index], "--test-close-after-presentations") == 0 &&
               index + 1 < argc) {
      char *end = NULL;
      const unsigned long parsed = strtoul(argv[++index], &end, 10);
      if (end == argv[index] || *end != '\0' || parsed == 0UL || parsed > 100UL) {
        return NO;
      }
      closeCount = (NSUInteger)parsed;
    } else if (strcmp(argv[index], "--test-result-file") == 0 &&
               index + 1 < argc) {
      if (foundResultPath) {
        return NO;
      }
      *testResultPath = [NSString stringWithUTF8String:argv[++index]];
      if (*testResultPath == nil || (*testResultPath).length == 0U) {
        return NO;
      }
      foundResultPath = YES;
    } else if (strcmp(argv[index], "--test-production-view") == 0) {
      if (foundProductionView) {
        return NO;
      }
      foundProductionView = YES;
      *testProductionView = YES;
    } else {
      return NO;
    }
  }
  if (foundContent && *testPanelFlow) {
    return NO;
  }
  if (*testPanelFlow &&
      (*testCliRetry || failurePaths.count == 0U || !foundRetryPath)) {
    return NO;
  }
  if (*testCliRetry &&
      (!foundContent || failurePaths.count != 0U || !foundRetryPath)) {
    return NO;
  }
  if (*testSchedulerRetry &&
      (!foundContent || !foundResultPath || closeCount == 0U ||
       failurePaths.count != 0U || !foundRetryPath || *testPanelFlow ||
       *testCliRetry || foundDrainMode || foundProductionView)) {
    return NO;
  }
  if (!*testPanelFlow && !*testCliRetry && !*testSchedulerRetry &&
      (failurePaths.count != 0U || foundRetryPath)) {
    return NO;
  }
  if (foundDrainMode &&
      (!foundContent || !foundResultPath || closeCount != 0U ||
       *testPanelFlow || *testCliRetry || failurePaths.count != 0U ||
       *testSchedulerRetry || foundRetryPath)) {
    return NO;
  }
  if (*testProductionView &&
      (!foundContent || !foundResultPath || closeCount == 0U || foundDrainMode ||
       *testPanelFlow || *testCliRetry || failurePaths.count != 0U ||
       *testSchedulerRetry || foundRetryPath)) {
    return NO;
  }
  *testFailurePaths = [failurePaths copy];
  *closeAfterPresentations = closeCount;
  if ((foundResultPath && closeCount == 0U && !foundDrainMode) ||
      ((*testPanelFlow || *testCliRetry) &&
       (!foundResultPath || closeCount == 0U))) {
    return NO;
  }
  if (*testSchedulerRetry &&
      (!foundResultPath || closeCount == 0U || !foundContent)) {
    return NO;
  }
  return YES;
}

static const char *lf_test_result_marker(void) {
  if (lf_test_drain_mode == LFHostTestDrainModeWindowClose) {
    return "installed_macos_host: lifecycle=close phase=advance "
           "owner-drained=pass main-sentinel=pass destroy=once result=pass\n";
  }
  if (lf_test_drain_mode == LFHostTestDrainModeTerminate) {
    return "installed_macos_host: lifecycle=quit phase=advance "
           "owner-drained=pass main-sentinel=pass destroy=once result=pass\n";
  }
  if (lf_test_drain_mode == LFHostTestDrainModeLoadErrorClose) {
    return "installed_macos_host: lifecycle=close phase=load-error "
           "owner-drained=pass main-sentinel=pass error-suppressed=pass "
           "destroy=once result=pass\n";
  }
  return lf_test_panel_flow
      ? "installed_macos_host: picker=present cancel=idle reader=6 load=2 "
        "allocation=1 retry=presented result=pass\n"
      : lf_test_cli_retry
      ? "installed_macos_host: cli=invalid-load error=after-cleanup "
        "retry=presented result=pass\n"
      : lf_test_scheduler_retry
      ? "installed_macos_host: scheduler=overflow cleanup=before-alert "
        "retry=presented result=pass\n"
      : "installed_macos_host: profile=muhtari-ntsc-v1 native-window=pass "
        "presentation=pass close=pass result=pass\n";
}

static BOOL lf_write_test_result(NSString *path) {
  if (lf_test_production_view && !lf_test_production_view_passed) {
    lf_append_test_progress(@"production-view: result-rejected view-not-verified\n");
    return NO;
  }
  NSString *audioMarker = nil;
  if (lf_test_production_view) {
    audioMarker = [lf_live_audio_output liveEvidenceMarker];
    if (audioMarker == nil) {
      const LFAudioOutputEvidence evidence =
          lf_live_audio_output != nil
              ? [lf_live_audio_output evidence]
              : (LFAudioOutputEvidence){0};
      lf_append_test_progress([NSString
          stringWithFormat:
              @"production-view: result-rejected audio-evidence output=%d lock-free=%d format=%d played=%llu player-stopped=%d engine-stopped=%d callbacks-quiescent=%d\n",
              lf_live_audio_output != nil, evidence.lockFree,
              evidence.outputFormatValid,
              (unsigned long long)evidence.dataPlayedBackCount,
              evidence.playerStopped, evidence.engineStopped,
              evidence.callbacksQuiescent]);
      return NO;
    }
  }
  const char *marker = lf_test_result_marker();
  const size_t markerLength = strlen(marker);
  const size_t productionMarkerLength =
      lf_test_production_view ? strlen(lf_production_view_marker) : 0U;
  const char *audioMarkerBytes = audioMarker.UTF8String;
  const size_t audioMarkerLength =
      audioMarkerBytes != NULL ? strlen(audioMarkerBytes) : 0U;
  int descriptor = open(path.fileSystemRepresentation,
                        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                        S_IRUSR | S_IWUSR);
  if (descriptor < 0) {
    if (lf_test_production_view) {
      lf_append_test_progress([NSString
          stringWithFormat:@"production-view: result-open-failed errno=%d\n",
                               errno]);
    }
    return NO;
  }
  const char *markers[] = {marker, lf_production_view_marker,
                           audioMarkerBytes};
  const size_t lengths[] = {markerLength, productionMarkerLength,
                            audioMarkerLength};
  const size_t markerCount = lf_test_production_view ? 3U : 1U;
  for (size_t markerIndex = 0U; markerIndex < markerCount; ++markerIndex) {
    size_t offset = 0U;
    while (offset < lengths[markerIndex]) {
      const ssize_t count = write(descriptor, markers[markerIndex] + offset,
                                  lengths[markerIndex] - offset);
      if (count < 0 && errno == EINTR) {
        continue;
      }
      if (count <= 0) {
        const int writeError = errno;
        (void)close(descriptor);
        if (lf_test_production_view) {
          lf_append_test_progress([NSString
              stringWithFormat:@"production-view: result-write-failed errno=%d\n",
                                   writeError]);
        }
        return NO;
      }
      offset += (size_t)count;
    }
  }
  const int closeStatus = close(descriptor);
  if (closeStatus != 0 && lf_test_production_view) {
    lf_append_test_progress([NSString
        stringWithFormat:@"production-view: result-close-failed errno=%d\n",
                             errno]);
  }
  return closeStatus == 0;
}

static void lf_append_test_progress(NSString *line) {
  if (lf_test_progress_path == nil || line == nil) {
    return;
  }
  NSData *bytes = [line dataUsingEncoding:NSUTF8StringEncoding];
  if (bytes == nil) {
    return;
  }
  int descriptor = open(lf_test_progress_path.fileSystemRepresentation,
                        O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC,
                        S_IRUSR | S_IWUSR);
  if (descriptor < 0) {
    return;
  }
  size_t offset = 0U;
  while (offset < bytes.length) {
    const ssize_t count = write(descriptor,
                                (const uint8_t *)bytes.bytes + offset,
                                bytes.length - offset);
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (count <= 0) {
      break;
    }
    offset += (size_t)count;
  }
  (void)close(descriptor);
}

static void lf_configure_early_test_progress(int argc,
                                             const char *argv[]) {
  BOOL isProductionViewSmoke = NO;
  for (int index = 1; index < argc; ++index) {
    if (strcmp(argv[index], "--test-production-view") == 0) {
      isProductionViewSmoke = YES;
      break;
    }
  }
  if (!isProductionViewSmoke) {
    return;
  }

  for (int index = 1; index + 1 < argc; ++index) {
    if (strcmp(argv[index], "--test-result-file") != 0) {
      continue;
    }
    NSString *resultPath = [NSString stringWithUTF8String:argv[index + 1]];
    if (resultPath != nil && resultPath.length > 0U) {
      lf_test_progress_path =
          [resultPath stringByAppendingString:@".progress"];
      lf_append_test_progress(@"app-start: main-entered\n");
    }
    return;
  }
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    lf_configure_early_test_progress(argc, argv);
    NSString *contentPath = nil;
    NSArray<NSString *> *testFailurePaths = nil;
    NSString *testRetryPath = nil;
    NSString *testResultPath = nil;
    BOOL testPanelFlow = NO;
    BOOL testCliRetry = NO;
    BOOL testSchedulerRetry = NO;
    BOOL testProductionView = NO;
    LFHostTestDrainMode testDrainMode = LFHostTestDrainModeNone;
    NSUInteger closeAfterPresentations = 0U;
    if (!lf_parse_arguments(argc, argv, &contentPath,
                            &testFailurePaths, &testRetryPath, &testPanelFlow,
                            &testCliRetry, &testSchedulerRetry, &testDrainMode,
                            &closeAfterPresentations, &testResultPath,
                            &testProductionView)) {
      lf_append_test_progress([NSString
          stringWithFormat:@"app-start: arguments=rejected argc=%d\n", argc]);
      (void)fprintf(stderr,
                    "usage: installed_macos_host [--content <file>] [--test-close-after-presentations count --test-result-file path [--test-production-view]] [--test-panel-flow --test-panel-failure path... --test-retry path] [--content invalid --test-cli-retry path] [--content path --test-scheduler-retry path --test-close-after-presentations count --test-result-file path] [--test-drain-close|--test-drain-quit|--test-drain-close-error --content path --test-result-file path]\n");
      return EXIT_FAILURE;
    }
    lf_test_result_path = testResultPath;
    lf_test_panel_flow = testPanelFlow;
    lf_test_cli_retry = testCliRetry;
    lf_test_scheduler_retry = testSchedulerRetry;
    lf_test_production_view = testProductionView;
    lf_test_production_view_passed = NO;
    if ((testPanelFlow || testCliRetry || testSchedulerRetry ||
         testProductionView || testDrainMode != LFHostTestDrainModeNone) &&
        testResultPath != nil) {
      lf_test_progress_path =
          [testResultPath stringByAppendingString:@".progress"];
    }
    if (testProductionView) {
      lf_append_test_progress(@"app-start: arguments=accepted mode=production-view\n");
    }
    lf_test_drain_mode = testDrainMode;
    if (testProductionView) {
      lf_append_test_progress(@"app-start: appkit-load=begin\n");
    }
    if (!NSApplicationLoad()) {
      if (testProductionView) {
        lf_append_test_progress(@"app-start: appkit-load=failed\n");
      }
      (void)fprintf(stderr,
                    "The native application environment is unavailable.\n");
      return EXIT_FAILURE;
    }
    NSApplication *application = NSApp;
    if (application == nil) {
      if (testProductionView) {
        lf_append_test_progress(@"app-start: appkit-instance=missing\n");
      }
      (void)fprintf(stderr,
                    "The native application environment is unavailable.\n");
      return EXIT_FAILURE;
    }
    if (testProductionView) {
      lf_append_test_progress(@"app-start: appkit-load=passed\n");
    }
    LFHostApplicationDelegate *delegate =
        [[LFHostApplicationDelegate alloc] init];
    delegate.contentPath = contentPath;
    delegate.testFailurePaths = testFailurePaths;
    delegate.testRetryPath = testRetryPath;
    delegate.testPanelFlow = testPanelFlow;
    delegate.testCliRetry = testCliRetry;
    delegate.testSchedulerRetry = testSchedulerRetry;
    delegate.testProductionView = testProductionView;
    delegate.testDrainMode = testDrainMode;
    delegate.closeAfterPresentations = closeAfterPresentations;
    [application setDelegate:delegate];
    [delegate startHost];
    [application run];
    if (testDrainMode != LFHostTestDrainModeNone) {
      if (![delegate finishDrainTest] ||
          !lf_write_test_result(testResultPath)) {
        return EXIT_FAILURE;
      }
      (void)fputs(lf_test_result_marker(), stdout);
      (void)fflush(stdout);
    }
    return delegate.exitCode;
  }
}
