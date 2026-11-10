/* SPDX-License-Identifier: MIT */
#ifndef LIBFUTURO_INSTALLED_MACOS_HOST_LFCONTENTREADER_H
#define LIBFUTURO_INSTALLED_MACOS_HOST_LFCONTENTREADER_H

#import <Foundation/Foundation.h>

#include <sys/stat.h>
#include <sys/types.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, LFContentReaderErrorCode) {
  LFContentReaderErrorOpen = 1,
  LFContentReaderErrorMetadata = 2,
  LFContentReaderErrorExtent = 3,
  LFContentReaderErrorRead = 4,
  LFContentReaderErrorChanged = 5,
  LFContentReaderErrorAllocation = 6,
};

typedef int (^LFContentOpenHandler)(const char *path, int flags);
typedef int (^LFContentStatHandler)(int descriptor, struct stat *status);
typedef ssize_t (^LFContentReadHandler)(int descriptor, void *bytes,
                                        size_t count);
typedef int (^LFContentCloseHandler)(int descriptor);
typedef void * _Nullable (^LFContentAllocateHandler)(size_t size);
typedef void (^LFContentFreeHandler)(void * _Nonnull bytes);

typedef struct LFContentReaderHooks {
  LFContentOpenHandler _Nullable openFile;
  LFContentStatHandler _Nullable statFile;
  LFContentReadHandler _Nullable readFile;
  LFContentCloseHandler _Nullable closeFile;
  LFContentAllocateHandler _Nullable allocate;
  LFContentFreeHandler _Nullable deallocate;
} LFContentReaderHooks;

@interface LFContentReader : NSObject
- (instancetype)init;
- (instancetype)initWithHooks:(const LFContentReaderHooks * _Nullable)hooks;
- (nullable NSData *)readAtPath:(NSString *)path
                   maximumBytes:(size_t)maximumBytes
                          error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END

#endif
