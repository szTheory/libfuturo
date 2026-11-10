/* SPDX-License-Identifier: MIT AND BSD-3-Clause
 * Copyright (c) 2026 muhtari contributors
 * Warm NTSC palette copied from muhtari/host/palette.c at
 * d5fd241e3f4d701d73867cc2e465c56a6fe6793d. The upstream table is derived
 * from a7800 src/mame/drivers/a7800.cpp at 7a2afdc1ea08fc331b16b750d8c1f02d4ef62fc8.
 * License texts and maintenance ownership are in MUHTARI-PALETTE-NOTICES.md.
 */
#import "LFDisplayAdapter.h"

#include <math.h>
#include <stdint.h>

static const uint32_t kWarmNTSCPalette[256] = {
    0x000000, 0x1e1e1e, 0x333333, 0x454545, 0x575757, 0x676767, 0x767676,
    0x858585, 0x939393, 0xa1a1a1, 0xafafaf, 0xbcbcbc, 0xc9c9c9, 0xd6d6d6,
    0xe3e3e3, 0xefefef, 0x271500, 0x3a2b00, 0x4c3e00, 0x5d5000, 0x6d6100,
    0x7c7000, 0x8b7f00, 0x998e00, 0xa79c17, 0xb4aa2d, 0xc2b740, 0xcfc452,
    0xdbd162, 0xe8de72, 0xf4ea81, 0xfff78f, 0x450000, 0x561000, 0x662800,
    0x763b00, 0x854d00, 0x935e00, 0xa16e00, 0xaf7d11, 0xbc8c28, 0xc99a3c,
    0xd6a84e, 0xe3b55f, 0xefc26e, 0xfbcf7e, 0xffdc8c, 0xffe89a, 0x550000,
    0x650000, 0x750f00, 0x842700, 0x923b00, 0xa04c16, 0xae5d2c, 0xbb6d3f,
    0xc87c51, 0xd58b61, 0xe29971, 0xeea780, 0xfab58f, 0xffc29d, 0xffcfaa,
    0xffdbb8, 0x570000, 0x670000, 0x770018, 0x85172e, 0x942d41, 0xa24052,
    0xaf5163, 0xbd6273, 0xca7282, 0xd78190, 0xe38f9e, 0xef9dac, 0xfcabb9,
    0xffb8c6, 0xffc6d3, 0xffd2e0, 0x4a0035, 0x5b0047, 0x6b0059, 0x7a1169,
    0x892878, 0x973c87, 0xa54e95, 0xb35ea3, 0xc06eb1, 0xcd7dbe, 0xda8ccb,
    0xe69ad8, 0xf2a8e4, 0xffb6f1, 0xffc3fd, 0xffd0ff, 0x2f0067, 0x420077,
    0x530086, 0x641994, 0x732fa2, 0x8242b0, 0x9153bd, 0x9f64ca, 0xad73d7,
    0xba82e3, 0xc791f0, 0xd49ffc, 0xe0acff, 0xedbaff, 0xf9c7ff, 0xffd4ff,
    0x000083, 0x1d0092, 0x3214a0, 0x452bad, 0x563ebb, 0x6650c8, 0x7660d5,
    0x8570e1, 0x937fee, 0xa18efa, 0xaf9cff, 0xbcaaff, 0xc9b7ff, 0xd6c4ff,
    0xe2d1ff, 0xefdeff, 0x000088, 0x001697, 0x062da5, 0x2140b2, 0x3551bf,
    0x4862cc, 0x5971d9, 0x6981e6, 0x788ff2, 0x879dfe, 0x95abff, 0xa3b8ff,
    0xb1c5ff, 0xbed2ff, 0xcbdfff, 0xd8ebff, 0x001a77, 0x003086, 0x004394,
    0x0054a2, 0x1764b0, 0x2d74bd, 0x4083ca, 0x5191d7, 0x629fe3, 0x72adf0,
    0x81bafc, 0x8fc7ff, 0x9dd4ff, 0xabe1ff, 0xb8edff, 0xc6f9ff, 0x002f4f,
    0x004260, 0x005470, 0x00647f, 0x00748d, 0x1d829c, 0x3291a9, 0x459fb7,
    0x56adc4, 0x66bad1, 0x76c7de, 0x85d4ea, 0x93e1f6, 0xa1edff, 0xaff9ff,
    0xbcffff, 0x003b0d, 0x004d25, 0x005d39, 0x006d4b, 0x057c5c, 0x208b6c,
    0x35997b, 0x47a78a, 0x58b598, 0x68c2a6, 0x78cfb4, 0x86dbc1, 0x95e8ce,
    0xa3f4db, 0xb0ffe7, 0xbefff3, 0x003c00, 0x004e00, 0x005e00, 0x036e02,
    0x1f7d1e, 0x348c33, 0x469a46, 0x58a857, 0x68b667, 0x77c377, 0x86d085,
    0x94dc94, 0xa2e9a2, 0xb0f5af, 0xbdffbd, 0xcaffca, 0x003300, 0x004600,
    0x165700, 0x2c6700, 0x3f7700, 0x518500, 0x61940d, 0x71a226, 0x80af3a,
    0x8fbd4c, 0x9dca5c, 0xaad66c, 0xb8e37b, 0xc5ef8a, 0xd2fc98, 0xdeffa6,
    0x122100, 0x293500, 0x3d4800, 0x4f5900, 0x5f6900, 0x6f7800, 0x7e8700,
    0x8d9500, 0x9ba31b, 0xa9b130, 0xb6be43, 0xc3cb55, 0xd0d865, 0xdde474,
    0xe9f183, 0xf6fd92, 0x390000, 0x4b1e00, 0x5c3300, 0x6b4500, 0x7b5600,
    0x896700, 0x987600, 0xa68500, 0xb3931c, 0xc0a132, 0xcdaf44, 0xdabc55,
    0xe7c966, 0xf3d675, 0xffe384, 0xffef93,
};

@interface LFDisplaySurface ()
- (instancetype)initWithGeneration:(uint64_t)generation
                             width:(NSUInteger)width
                            height:(NSUInteger)height
                       bytesPerRow:(NSUInteger)bytesPerRow
                          rgbaBytes:(NSData *)rgbaBytes;
@end

@implementation LFDisplaySurface
- (instancetype)initWithGeneration:(uint64_t)generation
                             width:(NSUInteger)width
                            height:(NSUInteger)height
                       bytesPerRow:(NSUInteger)bytesPerRow
                         rgbaBytes:(NSData *)rgbaBytes {
  self = [super init];
  if (self != nil) {
    _generation = generation;
    _width = width;
    _height = height;
    _bytesPerRow = bytesPerRow;
    _rgbaBytes = [rgbaBytes copy];
  }
  return self;
}
@end

@implementation LFDisplayAdapter

+ (LFDisplaySurface *)surfaceForRawIndices:(NSData *)rawIndices
                                  rowBytes:(NSUInteger)rowBytes
                                generation:(uint64_t)generation {
  const NSUInteger width = LFDisplayWidth;
  const NSUInteger height = LFDisplayHeight;
  if (rawIndices == nil || rowBytes < width ||
      rowBytes > NSUIntegerMax / height) {
    return nil;
  }
  const NSUInteger lastRowStart = (height - 1U) * rowBytes;
  if (lastRowStart > NSUIntegerMax - width ||
      rawIndices.length < lastRowStart + width) {
    return nil;
  }

  NSData *sourceSnapshot = [rawIndices copy];
  NSMutableData *rgba =
      [NSMutableData dataWithLength:width * height * LFDisplayBytesPerPixel];
  if (rgba == nil) {
    return nil;
  }
  const uint8_t *source = sourceSnapshot.bytes;
  uint8_t *destination = rgba.mutableBytes;
  const NSUInteger outputStride = width * LFDisplayBytesPerPixel;
  for (NSUInteger y = 0U; y < height; ++y) {
    const uint8_t *sourceRow = source + y * rowBytes;
    uint8_t *destinationRow = destination + y * outputStride;
    for (NSUInteger x = 0U; x < width; ++x) {
      const uint32_t color = kWarmNTSCPalette[sourceRow[x]];
      destinationRow[x * LFDisplayBytesPerPixel] =
          (uint8_t)((color >> 16U) & 0xFFU);
      destinationRow[x * LFDisplayBytesPerPixel + 1U] =
          (uint8_t)((color >> 8U) & 0xFFU);
      destinationRow[x * LFDisplayBytesPerPixel + 2U] =
          (uint8_t)(color & 0xFFU);
      destinationRow[x * LFDisplayBytesPerPixel + 3U] = UINT8_MAX;
    }
  }
  NSData *immutableRGBA = [rgba copy];
  return [[LFDisplaySurface alloc] initWithGeneration:generation
                                                 width:width
                                                height:height
                                           bytesPerRow:outputStride
                                             rgbaBytes:immutableRGBA];
}

+ (CGImageRef)copyCGImageForSurface:(LFDisplaySurface *)surface {
  if (surface == nil || surface.width == 0U || surface.height == 0U ||
      surface.width > NSUIntegerMax / LFDisplayBytesPerPixel ||
      surface.bytesPerRow < surface.width * LFDisplayBytesPerPixel ||
      surface.height > NSUIntegerMax / surface.bytesPerRow ||
      surface.rgbaBytes.length !=
          surface.bytesPerRow * surface.height) {
    return NULL;
  }

  CGDataProviderRef provider = CGDataProviderCreateWithCFData(
      (__bridge CFDataRef)surface.rgbaBytes);
  if (provider == NULL) {
    return NULL;
  }
  CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  if (colorSpace == NULL) {
    CGDataProviderRelease(provider);
    return NULL;
  }
  const CGBitmapInfo bitmapInfo =
      (CGBitmapInfo)kCGBitmapByteOrder32Big |
      (CGBitmapInfo)kCGImageAlphaPremultipliedLast;
  CGImageRef image = CGImageCreate(
      surface.width, surface.height, 8U, 32U, surface.bytesPerRow,
      colorSpace, bitmapInfo, provider, NULL, false,
      kCGRenderingIntentDefault);
  CGColorSpaceRelease(colorSpace);
  CGDataProviderRelease(provider);
  return image;
}

+ (CGRect)destinationRectForBounds:(CGRect)bounds
                       backingScale:(CGFloat)backingScale {
  if (!isfinite(backingScale) || backingScale <= 0.0 ||
      !isfinite(bounds.size.width) || !isfinite(bounds.size.height) ||
      bounds.size.width <= 0.0 || bounds.size.height <= 0.0) {
    return CGRectZero;
  }
  const CGFloat availableWidth =
      floor(bounds.size.width * backingScale + 0.5);
  const CGFloat availableHeight =
      floor(bounds.size.height * backingScale + 0.5);
  if (!isfinite(availableWidth) || !isfinite(availableHeight) ||
      availableWidth < 1.0 || availableHeight < 1.0) {
    return CGRectZero;
  }

  const CGFloat widthScale = availableWidth / (CGFloat)LFDisplayWidth;
  const CGFloat heightScale = availableHeight / (CGFloat)LFDisplayHeight;
  const CGFloat fitScale = fmin(widthScale, heightScale);
  CGFloat destinationWidth = 0.0;
  CGFloat destinationHeight = 0.0;
  if (fitScale >= 1.0) {
    const CGFloat integralScale = floor(fitScale);
    destinationWidth = (CGFloat)LFDisplayWidth * integralScale;
    destinationHeight = (CGFloat)LFDisplayHeight * integralScale;
  } else if (widthScale <= heightScale) {
    destinationWidth = availableWidth;
    destinationHeight =
        floor(destinationWidth * (CGFloat)LFDisplayHeight /
                  (CGFloat)LFDisplayWidth +
              0.5);
    if (destinationHeight > availableHeight) {
      destinationHeight = availableHeight;
      destinationWidth =
          floor(destinationHeight * (CGFloat)LFDisplayWidth /
                    (CGFloat)LFDisplayHeight +
                0.5);
    }
  } else {
    destinationHeight = availableHeight;
    destinationWidth =
        floor(destinationHeight * (CGFloat)LFDisplayWidth /
                  (CGFloat)LFDisplayHeight +
              0.5);
    if (destinationWidth > availableWidth) {
      destinationWidth = availableWidth;
      destinationHeight =
          floor(destinationWidth * (CGFloat)LFDisplayHeight /
                    (CGFloat)LFDisplayWidth +
                0.5);
    }
  }
  if (destinationWidth < 1.0 || destinationHeight < 1.0) {
    return CGRectZero;
  }

  const CGFloat offsetX =
      floor((availableWidth - destinationWidth) / 2.0) / backingScale;
  const CGFloat offsetY =
      floor((availableHeight - destinationHeight) / 2.0) / backingScale;
  return CGRectMake(bounds.origin.x + offsetX, bounds.origin.y + offsetY,
                    destinationWidth / backingScale,
                    destinationHeight / backingScale);
}
@end
