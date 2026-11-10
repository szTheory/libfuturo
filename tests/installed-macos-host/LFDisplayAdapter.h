/* SPDX-License-Identifier: MIT */
#ifndef LIBFUTURO_INSTALLED_MACOS_HOST_LFDISPLAYADAPTER_H
#define LIBFUTURO_INSTALLED_MACOS_HOST_LFDISPLAYADAPTER_H

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

enum {
  LFDisplayWidth = 320,
  LFDisplayHeight = 242,
  LFDisplayBytesPerPixel = 4,
};

/* Opaque RGBA8, top-to-bottom, tightly packed presentation bytes. */
@interface LFDisplaySurface : NSObject
@property(nonatomic, readonly) uint64_t generation;
@property(nonatomic, readonly) NSUInteger width;
@property(nonatomic, readonly) NSUInteger height;
@property(nonatomic, readonly) NSUInteger bytesPerRow;
@property(nonatomic, copy, readonly) NSData *rgbaBytes;
@end

@interface LFDisplayAdapter : NSObject
+ (nullable LFDisplaySurface *)surfaceForRawIndices:(NSData *)rawIndices
                                            rowBytes:(NSUInteger)rowBytes
                                          generation:(uint64_t)generation;
+ (nullable CGImageRef)copyCGImageForSurface:(LFDisplaySurface *)surface
    CF_RETURNS_RETAINED;
+ (CGRect)destinationRectForBounds:(CGRect)bounds
                       backingScale:(CGFloat)backingScale;
@end

NS_ASSUME_NONNULL_END

#endif
