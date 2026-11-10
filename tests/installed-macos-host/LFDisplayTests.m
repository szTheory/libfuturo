/* SPDX-License-Identifier: MIT */
#import "LFDisplayAdapter.h"
#import "LFHost.h"

#import <QuartzCore/QuartzCore.h>

#include "muhtari_oracle.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

@interface LFHostSession (DisplayTests)
- (BOOL)enableManualTimerDeliveryForTesting;
- (void)deliverTimerForTestingWithCompletion:(dispatch_block_t)completion;
- (void)barrierOwnerForTesting:(dispatch_block_t)completion;
@end

typedef struct {
  uint8_t index;
  uint8_t red;
  uint8_t green;
  uint8_t blue;
} LiteralColor;

static const LiteralColor kLiteralColors[] = {
    {0x00U, 0U, 0U, 0U},
    {0x11U, 58U, 43U, 0U},
    {0x22U, 102U, 40U, 0U},
    {0x33U, 132U, 39U, 0U},
    {0x44U, 148U, 45U, 65U},
    {0x51U, 91U, 0U, 71U},
    {0x52U, 107U, 0U, 89U},
    {0x53U, 122U, 17U, 105U},
    {0x54U, 137U, 40U, 120U},
    {0x61U, 66U, 0U, 119U},
    {0x62U, 83U, 0U, 134U},
    {0x63U, 100U, 25U, 148U},
    {0x64U, 115U, 47U, 162U},
};

static int fail(const char *message) {
  (void)fprintf(stderr, "host_display: %s failed\n", message);
  return EXIT_FAILURE;
}

static BOOL wait_semaphore(dispatch_semaphore_t semaphore,
                           NSTimeInterval timeout) {
  const int64_t nanoseconds = (int64_t)(timeout * 1000000000.0);
  return dispatch_semaphore_wait(
             semaphore,
             dispatch_time(DISPATCH_TIME_NOW, nanoseconds)) == 0;
}

static BOOL pixel_equals(const uint8_t *bytes, size_t bytesPerRow,
                         size_t x, size_t y, uint8_t red, uint8_t green,
                         uint8_t blue, uint8_t alpha) {
  const uint8_t *pixel = bytes + y * bytesPerRow + x * 4U;
  return pixel[0] == red && pixel[1] == green && pixel[2] == blue &&
         pixel[3] == alpha;
}

static BOOL close_enough(CGFloat left, CGFloat right) {
  return fabs((double)(left - right)) < 0.0001;
}

static NSMutableData *make_test_indices(NSUInteger stride,
                                        NSUInteger *literalX) {
  NSMutableData *raw = [NSMutableData
      dataWithLength:stride * (NSUInteger)LFDisplayHeight];
  uint8_t *bytes = raw.mutableBytes;
  memset(bytes, 0xCC, raw.length);
  for (NSUInteger y = 0U; y < (NSUInteger)LFDisplayHeight; ++y) {
    memset(bytes + y * stride, 0U, (NSUInteger)LFDisplayWidth);
  }
  bytes[0U] = UINT8_C(0x11);
  bytes[(NSUInteger)LFDisplayWidth - 1U] = UINT8_C(0x22);
  bytes[(NSUInteger)(LFDisplayHeight - 1U) * stride] = UINT8_C(0x33);
  bytes[(NSUInteger)(LFDisplayHeight - 1U) * stride +
        (NSUInteger)LFDisplayWidth - 1U] = UINT8_C(0x44);
  for (NSUInteger index = 0U;
       index < sizeof(kLiteralColors) / sizeof(kLiteralColors[0]); ++index) {
    const NSUInteger x = 8U + index * 9U;
    literalX[index] = x;
    bytes[10U * stride + x] = kLiteralColors[index].index;
  }
  return raw;
}

static CALayer *make_display_layer(LFDisplaySurface *surface,
                                   CGSize pointSize, CGFloat backingScale,
                                   CGRect *destinationOut) {
  CALayer *root = [CALayer layer];
  root.bounds = CGRectMake(0.0, 0.0, pointSize.width, pointSize.height);
  root.frame = root.bounds;
  root.contentsScale = backingScale;
  root.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
  root.masksToBounds = YES;
  CALayer *video = [CALayer layer];
  video.contentsScale = backingScale;
  video.contentsGravity = kCAGravityResize;
  video.magnificationFilter = kCAFilterNearest;
  video.minificationFilter = kCAFilterNearest;
  video.frame = [LFDisplayAdapter destinationRectForBounds:root.bounds
                                              backingScale:backingScale];
  CGImageRef image = [LFDisplayAdapter copyCGImageForSurface:surface];
  if (image == NULL) {
    return nil;
  }
  video.contents = (__bridge id)image;
  CGImageRelease(image);
  [root addSublayer:video];
  [CATransaction flush];
  if (destinationOut != NULL) {
    *destinationOut = video.frame;
  }
  return root;
}

static NSData *capture_layer(CALayer *layer, CGSize pointSize,
                             CGFloat backingScale, size_t *pixelWidthOut,
                             size_t *pixelHeightOut) {
  const size_t pixelWidth =
      (size_t)floor((double)(pointSize.width * backingScale) + 0.5);
  const size_t pixelHeight =
      (size_t)floor((double)(pointSize.height * backingScale) + 0.5);
  const size_t bytesPerRow = pixelWidth * 4U;
  NSMutableData *pixels =
      [NSMutableData dataWithLength:bytesPerRow * pixelHeight];
  CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  if (colorSpace == NULL) {
    return nil;
  }
  const CGBitmapInfo bitmapInfo =
      (CGBitmapInfo)kCGBitmapByteOrder32Big |
      (CGBitmapInfo)kCGImageAlphaPremultipliedLast;
  CGContextRef context = CGBitmapContextCreate(
      pixels.mutableBytes, pixelWidth, pixelHeight, 8U, bytesPerRow,
      colorSpace, bitmapInfo);
  CGColorSpaceRelease(colorSpace);
  if (context == NULL) {
    return nil;
  }
  CGContextSetShouldAntialias(context, false);
  CGContextSetInterpolationQuality(context, kCGInterpolationNone);
  CGContextSetBlendMode(context, kCGBlendModeCopy);
  CGContextTranslateCTM(context, 0.0, (CGFloat)pixelHeight);
  CGContextScaleCTM(context, backingScale, -backingScale);
  [layer renderInContext:context];
  CGContextRelease(context);
  NSMutableData *topDown =
      [NSMutableData dataWithLength:bytesPerRow * pixelHeight];
  const uint8_t *bottomUpBytes = pixels.bytes;
  uint8_t *topDownBytes = topDown.mutableBytes;
  for (size_t row = 0U; row < pixelHeight; ++row) {
    memcpy(topDownBytes + row * bytesPerRow,
           bottomUpBytes + (pixelHeight - 1U - row) * bytesPerRow,
           bytesPerRow);
  }
  if (pixelWidthOut != NULL) {
    *pixelWidthOut = pixelWidth;
  }
  if (pixelHeightOut != NULL) {
    *pixelHeightOut = pixelHeight;
  }
  return [topDown copy];
}

static int check_geometry(void) {
  struct GeometryCase {
    CGSize view;
    CGFloat scale;
    CGFloat x;
    CGFloat y;
    CGFloat width;
    CGFloat height;
  };
  static const struct GeometryCase cases[] = {
      {{320.0, 242.0}, 1.0, 0.0, 0.0, 320.0, 242.0},
      {{640.0, 500.0}, 1.0, 0.0, 8.0, 640.0, 484.0},
      {{641.0, 500.0}, 1.0, 0.0, 8.0, 640.0, 484.0},
      {{400.0, 242.0}, 1.0, 40.0, 0.0, 320.0, 242.0},
      {{320.0, 300.0}, 1.0, 0.0, 29.0, 320.0, 242.0},
      {{320.0, 242.0}, 2.0, 0.0, 0.0, 320.0, 242.0},
      {{321.0, 251.0}, 2.0, 0.5, 4.5, 320.0, 242.0},
  };
  for (size_t index = 0U; index < sizeof(cases) / sizeof(cases[0]); ++index) {
    const struct GeometryCase *test = &cases[index];
    const CGRect bounds = CGRectMake(0.0, 0.0, test->view.width,
                                     test->view.height);
    const CGRect actual = [LFDisplayAdapter
        destinationRectForBounds:bounds
                    backingScale:test->scale];
    if (!close_enough(actual.origin.x, test->x) ||
        !close_enough(actual.origin.y, test->y) ||
        !close_enough(actual.size.width, test->width) ||
        !close_enough(actual.size.height, test->height)) {
      (void)fprintf(stderr,
                    "host_display: geometry case=%lu actual=%.4fx%.4f+%.4f+%.4f\n",
                    (unsigned long)index, actual.size.width,
                    actual.size.height, actual.origin.x, actual.origin.y);
      return EXIT_FAILURE;
    }
  }
  const CGRect downscaled = [LFDisplayAdapter
      destinationRectForBounds:CGRectMake(0.0, 0.0, 200.0, 151.0)
                  backingScale:1.0];
  const CGFloat inputRatio = 320.0 / 242.0;
  const CGFloat outputRatio = downscaled.size.width / downscaled.size.height;
  if (downscaled.size.width > 200.0 || downscaled.size.height > 151.0 ||
      fabs((double)(outputRatio - inputRatio)) > 0.01) {
    return fail("undersized view preserves aspect ratio");
  }
  return EXIT_SUCCESS;
}

static int check_literal_surface_and_layer(void) {
  const NSUInteger sourceStride = (NSUInteger)LFDisplayWidth + 4U;
  NSUInteger literalX[sizeof(kLiteralColors) / sizeof(kLiteralColors[0])] = {0};
  NSMutableData *raw = make_test_indices(sourceStride, literalX);
  NSData *rawBefore = [raw copy];
  LFDisplaySurface *surface = [LFDisplayAdapter
      surfaceForRawIndices:raw
                  rowBytes:sourceStride
                generation:77U];
  if (surface == nil || surface.generation != 77U ||
      surface.width != (NSUInteger)LFDisplayWidth ||
      surface.height != (NSUInteger)LFDisplayHeight ||
      surface.bytesPerRow != (NSUInteger)LFDisplayWidth * 4U ||
      surface.rgbaBytes.length != (NSUInteger)LFDisplayWidth *
                                      (NSUInteger)LFDisplayHeight * 4U ||
      ![raw isEqualToData:rawBefore]) {
    return fail("surface extent and raw ownership");
  }

  const uint8_t *rgba = surface.rgbaBytes.bytes;
  const size_t rgbaStride = (size_t)surface.bytesPerRow;
  for (size_t index = 0U;
       index < sizeof(kLiteralColors) / sizeof(kLiteralColors[0]); ++index) {
    const LiteralColor *color = &kLiteralColors[index];
    if (!pixel_equals(rgba, rgbaStride, literalX[index], 10U, color->red,
                      color->green, color->blue, UINT8_MAX)) {
      (void)fprintf(stderr,
                    "host_display: palette index=%02x rgba=%u,%u,%u,%u expected=%u,%u,%u,255\n",
                    color->index,
                    rgba[10U * rgbaStride + literalX[index] * 4U],
                    rgba[10U * rgbaStride + literalX[index] * 4U + 1U],
                    rgba[10U * rgbaStride + literalX[index] * 4U + 2U],
                    rgba[10U * rgbaStride + literalX[index] * 4U + 3U],
                    color->red, color->green, color->blue);
      return EXIT_FAILURE;
    }
  }
  if (!pixel_equals(rgba, rgbaStride, 0U, 0U, 58U, 43U, 0U, UINT8_MAX) ||
      !pixel_equals(rgba, rgbaStride, 319U, 0U, 102U, 40U, 0U, UINT8_MAX) ||
      !pixel_equals(rgba, rgbaStride, 0U, 241U, 132U, 39U, 0U, UINT8_MAX) ||
      !pixel_equals(rgba, rgbaStride, 319U, 241U, 148U, 45U, 65U,
                    UINT8_MAX)) {
    return fail("top-down row orientation and edge colors");
  }

  for (NSUInteger scale = 1U; scale <= 2U; ++scale) {
    const CGSize viewSize = CGSizeMake(320.0, 242.0);
    CGRect videoRect = CGRectZero;
    CALayer *layer = make_display_layer(surface, viewSize, (CGFloat)scale,
                                        &videoRect);
    size_t pixelWidth = 0U;
    size_t pixelHeight = 0U;
    NSData *capture = capture_layer(layer, viewSize, (CGFloat)scale,
                                   &pixelWidth, &pixelHeight);
    if (capture == nil || layer == nil || pixelWidth != 320U * scale ||
        pixelHeight != 242U * scale || !CGRectEqualToRect(
            videoRect, CGRectMake(0.0, 0.0, 320.0, 242.0))) {
      return fail("actual layer capture setup at backing scale");
    }
    const uint8_t *captured = capture.bytes;
    const size_t captureStride = pixelWidth * 4U;
    const size_t sampleFactor = scale;
    for (size_t index = 0U;
         index < sizeof(kLiteralColors) / sizeof(kLiteralColors[0]); ++index) {
      const LiteralColor *color = &kLiteralColors[index];
      const size_t x = literalX[index] * sampleFactor;
      const size_t y = 10U * sampleFactor;
      if (!pixel_equals(captured, captureStride, x, y, color->red,
                        color->green, color->blue, UINT8_MAX)) {
        (void)fprintf(stderr,
                      "host_display: actual layer mismatch scale=%lu index=%02x pixel=%lu,%lu actual=%u,%u,%u,%u\n",
                      (unsigned long)scale, color->index,
                      (unsigned long)x, (unsigned long)y,
                      captured[y * captureStride + x * 4U],
                      captured[y * captureStride + x * 4U + 1U],
                      captured[y * captureStride + x * 4U + 2U],
                      captured[y * captureStride + x * 4U + 3U]);
        return EXIT_FAILURE;
      }
    }
  }
  return EXIT_SUCCESS;
}

static int check_geometry_capture(void) {
  NSUInteger literalX[sizeof(kLiteralColors) / sizeof(kLiteralColors[0])] = {0};
  NSMutableData *raw = make_test_indices((NSUInteger)LFDisplayWidth, literalX);
  LFDisplaySurface *surface = [LFDisplayAdapter
      surfaceForRawIndices:raw
                  rowBytes:(NSUInteger)LFDisplayWidth
                generation:80U];
  struct CaptureCase {
    CGSize view;
    CGFloat scale;
    CGFloat x;
    CGFloat y;
    CGFloat width;
    CGFloat height;
  };
  static const struct CaptureCase cases[] = {
      {{320.0, 242.0}, 1.0, 0.0, 0.0, 320.0, 242.0},
      {{640.0, 500.0}, 1.0, 0.0, 8.0, 640.0, 484.0},
      {{641.0, 500.0}, 1.0, 0.0, 8.0, 640.0, 484.0},
      {{400.0, 242.0}, 1.0, 40.0, 0.0, 320.0, 242.0},
      {{320.0, 300.0}, 1.0, 0.0, 29.0, 320.0, 242.0},
      {{320.0, 242.0}, 2.0, 0.0, 0.0, 320.0, 242.0},
      {{321.0, 251.0}, 2.0, 0.5, 4.5, 320.0, 242.0},
      {{200.0, 151.0}, 1.0, 0.0, 0.0, 200.0, 151.0},
      {{200.0, 151.0}, 2.0, 20.0, 15.0, 160.0, 121.0},
      {{400.0, 242.0}, 2.0, 40.0, 0.0, 320.0, 242.0},
      {{320.0, 300.0}, 2.0, 0.0, 29.0, 320.0, 242.0},
  };
  if (surface == nil) {
    return fail("geometry fixture surface");
  }
  for (size_t caseIndex = 0U;
       caseIndex < sizeof(cases) / sizeof(cases[0]); ++caseIndex) {
    const struct CaptureCase *test = &cases[caseIndex];
    CGRect videoRect = CGRectZero;
    CALayer *layer = make_display_layer(surface, test->view, test->scale,
                                        &videoRect);
    size_t pixelWidth = 0U;
    size_t pixelHeight = 0U;
    NSData *capture = capture_layer(layer, test->view, test->scale,
                                   &pixelWidth, &pixelHeight);
    const size_t expectedPixelWidth =
        (size_t)floor((double)(test->view.width * test->scale) + 0.5);
    const size_t expectedPixelHeight =
        (size_t)floor((double)(test->view.height * test->scale) + 0.5);
    if (layer == nil || capture == nil ||
        pixelWidth != expectedPixelWidth ||
        pixelHeight != expectedPixelHeight ||
        !close_enough(videoRect.origin.x, test->x) ||
        !close_enough(videoRect.origin.y, test->y) ||
        !close_enough(videoRect.size.width, test->width) ||
        !close_enough(videoRect.size.height, test->height)) {
      (void)fprintf(stderr,
                    "host_display: actual geometry capture case=%lu bounds=%.2fx%.2f scale=%.1f rect=%.2fx%.2f+%.2f+%.2f\n",
                    (unsigned long)caseIndex, test->view.width,
                    test->view.height, test->scale, videoRect.size.width,
                    videoRect.size.height, videoRect.origin.x,
                    videoRect.origin.y);
      return EXIT_FAILURE;
    }

    const uint8_t *bytes = capture.bytes;
    const size_t stride = pixelWidth * 4U;
    const size_t left =
        (size_t)floor((double)(videoRect.origin.x * test->scale) + 0.5);
    const size_t top = (size_t)floor(
        (double)((test->view.height - videoRect.origin.y -
                  videoRect.size.height) *
                 test->scale) +
        0.5);
    const size_t contentWidth =
        (size_t)floor((double)(videoRect.size.width * test->scale) + 0.5);
    const size_t contentHeight =
        (size_t)floor((double)(videoRect.size.height * test->scale) + 0.5);
    if (!pixel_equals(bytes, stride, left, top, 58U, 43U, 0U, UINT8_MAX) ||
        !pixel_equals(bytes, stride, left + contentWidth - 1U, top, 102U,
                      40U, 0U, UINT8_MAX) ||
        !pixel_equals(bytes, stride, left, top + contentHeight - 1U, 132U,
                      39U, 0U, UINT8_MAX) ||
        !pixel_equals(bytes, stride, left + contentWidth - 1U,
                      top + contentHeight - 1U, 148U, 45U, 65U, UINT8_MAX)) {
      (void)fprintf(stderr,
                    "host_display: geometry edge-color mismatch case=%lu left=%lu top=%lu extent=%lux%lu\n",
                    (unsigned long)caseIndex, (unsigned long)left,
                    (unsigned long)top, (unsigned long)contentWidth,
                    (unsigned long)contentHeight);
      return EXIT_FAILURE;
    }
    if (left > 0U &&
        !pixel_equals(bytes, stride, 0U, pixelHeight / 2U, 0U, 0U, 0U,
                      UINT8_MAX)) {
      return fail("horizontal letterbox is opaque black");
    }
    if (left + contentWidth < pixelWidth &&
        !pixel_equals(bytes, stride, left + contentWidth,
                      pixelHeight / 2U, 0U, 0U, 0U, UINT8_MAX)) {
      return fail("horizontal trailing letterbox is opaque black");
    }
    if (top > 0U &&
        !pixel_equals(bytes, stride, pixelWidth / 2U, 0U, 0U, 0U, 0U,
                      UINT8_MAX)) {
      return fail("vertical letterbox is opaque black");
    }
    if (top + contentHeight < pixelHeight &&
        !pixel_equals(bytes, stride, pixelWidth / 2U,
                      top + contentHeight, 0U, 0U, 0U, UINT8_MAX)) {
      return fail("vertical trailing letterbox is opaque black");
    }

    if (contentWidth % LFDisplayWidth == 0U &&
        contentHeight % LFDisplayHeight == 0U &&
        contentWidth / LFDisplayWidth ==
            contentHeight / LFDisplayHeight) {
      const size_t block = contentWidth / LFDisplayWidth;
      if (block > 1U) {
        for (size_t index = 0U;
             index < sizeof(kLiteralColors) / sizeof(kLiteralColors[0]);
             ++index) {
          const LiteralColor *color = &kLiteralColors[index];
          const size_t x = left + literalX[index] * block;
          const size_t y = top + 10U * block;
          for (size_t dy = 0U; dy < block; ++dy) {
            for (size_t dx = 0U; dx < block; ++dx) {
              if (!pixel_equals(bytes, stride, x + dx, y + dy,
                                color->red, color->green, color->blue,
                                UINT8_MAX)) {
                return fail("nearest filtering preserves backing pixel blocks");
              }
            }
          }
        }
      }
    }
  }
  return EXIT_SUCCESS;
}

static BOOL wait_owner_barrier(LFHostSession *session) {
  dispatch_semaphore_t barrier = dispatch_semaphore_create(0);
  [session barrierOwnerForTesting:^{ dispatch_semaphore_signal(barrier); }];
  return wait_semaphore(barrier, 2.0);
}

static int check_startup_layer_and_mailbox(NSString *fixturePath) {
  dispatch_queue_t callbackQueue =
      dispatch_queue_create("org.libfuturo.host.display-callbacks",
                            DISPATCH_QUEUE_SERIAL);
  dispatch_semaphore_t releaseCallbacks = dispatch_semaphore_create(0);
  dispatch_semaphore_t firstAdvance = dispatch_semaphore_create(0);
  dispatch_semaphore_t frameDelivered = dispatch_semaphore_create(0);
  dispatch_semaphore_t openFinished = dispatch_semaphore_create(0);
  dispatch_semaphore_t stopFinished = dispatch_semaphore_create(0);
  NSObject *stateLock = [[NSObject alloc] init];
  __block uint64_t fakeNow = UINT64_C(1000000000);
  __block LFHostFrame *firstFrameSnapshot = nil;
  __block LFHostFrame *deliveredFrame = nil;
  __block NSData *firstRaw = nil;
  __block NSUInteger publishedFrames = 0U;
  __block NSUInteger scheduledInvalidations = 0U;
  __block NSUInteger deliveredFrames = 0U;
  __block NSUInteger openCompleted = 0U;
  LFHostClock clock = ^uint64_t{
    @synchronized(stateLock) {
      return fakeNow;
    }
  };
  LFHostSessionObserver observer = ^(LFHostSessionEvent event,
                                     LFHostFrame *frame,
                                     NSData *audioSamples,
                                     NSUInteger audioCapacity,
                                     uint32_t inputButtons) {
    (void)audioSamples;
    (void)audioCapacity;
    (void)inputButtons;
    @synchronized(stateLock) {
      if (event == LFHostSessionEventAdvanceFinished && frame != nil) {
        if (publishedFrames == 0U) {
          firstFrameSnapshot = frame;
          firstRaw = [frame.rawIndices copy];
        }
        ++publishedFrames;
        dispatch_semaphore_signal(firstAdvance);
      } else if (event == LFHostSessionEventFrameInvalidationScheduled) {
        ++scheduledInvalidations;
      }
    }
  };
  dispatch_async(callbackQueue, ^{
    (void)dispatch_semaphore_wait(releaseCallbacks, DISPATCH_TIME_FOREVER);
  });
  LFHostSession *session = [[LFHostSession alloc]
      initWithFrameHandler:^(LFHostFrame *frame) {
        @synchronized(stateLock) {
          deliveredFrame = frame;
          ++deliveredFrames;
        }
        dispatch_semaphore_signal(frameDelivered);
      }
        callbackQueue:callbackQueue
                clock:clock
             observer:observer];
  if (![session enableManualTimerDeliveryForTesting]) {
    return fail("manual display mailbox timer setup");
  }
  [session setInputButtons:UINT32_C(0x0001)];
  [session openContentAtPath:fixturePath
                  completion:^(BOOL success, NSError *error) {
                    (void)error;
                    @synchronized(stateLock) {
                      openCompleted = success ? 1U : 2U;
                    }
                    dispatch_semaphore_signal(openFinished);
                  }];
  if (!wait_semaphore(firstAdvance, 5.0)) {
    dispatch_semaphore_signal(releaseCallbacks);
    return fail("installed Muhtari startup frame");
  }
  [session startSteadyUpdatesWithCompletion:^(BOOL success, NSError *error) {
    (void)success;
    (void)error;
  }];
  if (!wait_owner_barrier(session)) {
    dispatch_semaphore_signal(releaseCallbacks);
    return fail("manual display scheduler start");
  }
  for (NSUInteger frame = 0U; frame < 3U; ++frame) {
    @synchronized(stateLock) {
      fakeNow += UINT64_C(17000000);
    }
    [session deliverTimerForTestingWithCompletion:nil];
    if (!wait_owner_barrier(session)) {
      dispatch_semaphore_signal(releaseCallbacks);
      return fail("manual display frame delivery");
    }
  }
  @synchronized(stateLock) {
    if (publishedFrames != 4U || scheduledInvalidations != 1U ||
        firstRaw == nil ||
        !lf_muhtari_oracle_first_image(firstRaw.bytes, (size_t)LFDisplayWidth,
                                       UINT8_C(0x11))) {
      dispatch_semaphore_signal(releaseCallbacks);
      (void)fprintf(stderr,
                    "host_display: mailbox history frames=%lu invalidations=%lu raw=%d image=%d\n",
                    (unsigned long)publishedFrames,
                    (unsigned long)scheduledInvalidations, firstRaw != nil,
                    firstRaw != nil &&
                        lf_muhtari_oracle_first_image(
                            firstRaw.bytes, (size_t)LFDisplayWidth,
                            UINT8_C(0x11)));
      return fail("stalled callback queue keeps one newest-frame invalidation");
    }
  }

  /* Calibrate the independent raw comparator with a deliberate wrong index. */
  NSMutableData *wrongRaw = [firstRaw mutableCopy];
  ((uint8_t *)wrongRaw.mutableBytes)
      [LF_MUHTARI_ORACLE_FIRST_BACKGROUND_ROW * LFDisplayWidth +
       LF_MUHTARI_ORACLE_FIRST_CHANGED_PIXEL] ^= UINT8_C(0x01);
  if (lf_muhtari_oracle_first_image(wrongRaw.bytes, (size_t)LFDisplayWidth,
                                    UINT8_C(0x11))) {
    dispatch_semaphore_signal(releaseCallbacks);
    return fail("raw negative control must be detected");
  }

  dispatch_semaphore_signal(releaseCallbacks);
  if (!wait_semaphore(frameDelivered, 5.0) ||
      !wait_semaphore(openFinished, 5.0)) {
    return fail("latest immutable frame and open completion delivery");
  }
  @synchronized(stateLock) {
    if (openCompleted != 1U || deliveredFrames != 1U ||
        deliveredFrame == nil || deliveredFrame.sequence != 4U ||
        firstFrameSnapshot == nil ||
        ![firstFrameSnapshot.rawIndices isEqualToData:firstRaw]) {
      return fail("latest generation replaces stalled frame notifications");
    }
  }
  if (!lf_muhtari_oracle_first_image(firstRaw.bytes,
                                     (size_t)LFDisplayWidth,
                                     UINT8_C(0x11)) ||
      deliveredFrame.rawIndices.length !=
          (NSUInteger)LFDisplayWidth * (NSUInteger)LFDisplayHeight) {
    return fail("independent startup raw image oracle");
  }
  LFDisplaySurface *startupSurface = firstFrameSnapshot.displaySurface;
  const uint8_t *startupRGBA = startupSurface.rgbaBytes.bytes;
  const size_t startupStride = (size_t)startupSurface.bytesPerRow;
  if (!pixel_equals(startupRGBA, startupStride, 0U, 0U, 0U, 0U, 0U,
                    UINT8_MAX) ||
      !pixel_equals(startupRGBA, startupStride, 64U, 224U, 58U, 43U, 0U,
                    UINT8_MAX) ||
      !pixel_equals(startupRGBA, startupStride, 63U, 224U, 0U, 0U, 0U,
                    UINT8_MAX) ||
      !pixel_equals(startupRGBA, startupStride, 319U, 241U, 58U, 43U, 0U,
                    UINT8_MAX)) {
    return fail("literal partial-startup colors remain visible");
  }

  for (NSUInteger scale = 1U; scale <= 2U; ++scale) {
    const CGSize viewSize = CGSizeMake(320.0, 242.0);
    CALayer *layer = make_display_layer(startupSurface, viewSize,
                                        (CGFloat)scale, NULL);
    size_t pixelWidth = 0U;
    size_t pixelHeight = 0U;
    NSData *capture = capture_layer(layer, viewSize, (CGFloat)scale,
                                   &pixelWidth, &pixelHeight);
    if (capture == nil || pixelWidth != 320U * scale ||
        pixelHeight != 242U * scale) {
      return fail("actual startup surface capture");
    }
    const uint8_t *pixels = capture.bytes;
    const size_t stride = pixelWidth * 4U;
    for (size_t y = 0U; y < (size_t)LFDisplayHeight; ++y) {
      for (size_t x = 0U; x < (size_t)LFDisplayWidth; ++x) {
        const BOOL changed =
            y > LF_MUHTARI_ORACLE_FIRST_BACKGROUND_ROW ||
            (y == LF_MUHTARI_ORACLE_FIRST_BACKGROUND_ROW &&
             x >= LF_MUHTARI_ORACLE_FIRST_CHANGED_PIXEL);
        const uint8_t red = changed ? 58U : 0U;
        const uint8_t green = changed ? 43U : 0U;
        const size_t px = x * scale + (scale == 2U ? 1U : 0U);
        const size_t py = y * scale + (scale == 2U ? 1U : 0U);
        if (!pixel_equals(pixels, stride, px, py, red, green, 0U,
                          UINT8_MAX)) {
          (void)fprintf(stderr,
                        "host_display: startup capture mismatch scale=%lu at=%lu,%lu raw=%02x\n",
                        (unsigned long)scale, (unsigned long)x,
                        (unsigned long)y,
                        ((const uint8_t *)deliveredFrame.rawIndices.bytes)
                            [y * (size_t)LFDisplayWidth + x]);
          return EXIT_FAILURE;
        }
      }
    }
  }

  /* Calibrate the RGB comparator against an intentionally swapped channel. */
  const uint8_t *warm = startupRGBA +
      (size_t)LF_MUHTARI_ORACLE_FIRST_BACKGROUND_ROW * startupStride +
      (size_t)LF_MUHTARI_ORACLE_FIRST_CHANGED_PIXEL * 4U;
  if (!pixel_equals(warm, 4U, 0U, 0U, 58U, 43U, 0U, UINT8_MAX) ||
      pixel_equals(warm, 4U, 0U, 0U, 0U, 43U, 58U, UINT8_MAX)) {
    return fail("RGB negative control and channel order");
  }
  [session stopWithCompletion:^{ dispatch_semaphore_signal(stopFinished); }];
  if (!wait_semaphore(stopFinished, 5.0)) {
    return fail("display mailbox session cleanup");
  }
  return EXIT_SUCCESS;
}

int main(int argc, char **argv) {
  if (argc != 2) {
    (void)fprintf(stderr, "usage: host_display <generated-fixture.a78>\n");
    return EXIT_FAILURE;
  }
  @autoreleasepool {
    if (check_literal_surface_and_layer() != EXIT_SUCCESS ||
        check_geometry() != EXIT_SUCCESS ||
        check_geometry_capture() != EXIT_SUCCESS ||
        check_startup_layer_and_mailbox(
            [NSString stringWithUTF8String:argv[1]]) != EXIT_SUCCESS) {
      return EXIT_FAILURE;
    }
    (void)printf(
        "host_display: indices=13 channels=RGBA8 alpha=opaque raw=unchanged startup=partial capture=layer-scale1,2 geometry=fit,letterbox,nonmultiple,downscale,nearest mailbox=latest,one-invalidation raw-control=detected rgb-control=detected result=pass\n");
    return EXIT_SUCCESS;
  }
}
