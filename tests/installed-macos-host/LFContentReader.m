/* SPDX-License-Identifier: MIT */
#import "LFContentReader.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>

static NSString *const kLFContentReaderErrorDomain =
    @"org.libfuturo.installed-host.content-reader";

@implementation LFContentReader {
  LFContentOpenHandler _openFile;
  LFContentStatHandler _statFile;
  LFContentReadHandler _readFile;
  LFContentCloseHandler _closeFile;
  LFContentAllocateHandler _allocate;
  LFContentFreeHandler _deallocate;
}

- (instancetype)init {
  return [self initWithHooks:NULL];
}

- (instancetype)initWithHooks:(const LFContentReaderHooks *)hooks {
  self = [super init];
  if (self != nil) {
    if (hooks != NULL && hooks->openFile != nil) {
      _openFile = [hooks->openFile copy];
    } else {
      _openFile = ^int(const char *path, int flags) {
        return open(path, flags);
      };
    }
    if (hooks != NULL && hooks->statFile != nil) {
      _statFile = [hooks->statFile copy];
    } else {
      _statFile = ^int(int descriptor, struct stat *status) {
        return fstat(descriptor, status);
      };
    }
    if (hooks != NULL && hooks->readFile != nil) {
      _readFile = [hooks->readFile copy];
    } else {
      _readFile = ^ssize_t(int descriptor, void *bytes, size_t count) {
        return read(descriptor, bytes, count);
      };
    }
    if (hooks != NULL && hooks->closeFile != nil) {
      _closeFile = [hooks->closeFile copy];
    } else {
      _closeFile = ^int(int descriptor) { return close(descriptor); };
    }
    if (hooks != NULL && hooks->allocate != nil) {
      _allocate = [hooks->allocate copy];
    } else {
      _allocate = ^void *(size_t size) { return malloc(size); };
    }
    if (hooks != NULL && hooks->deallocate != nil) {
      _deallocate = [hooks->deallocate copy];
    } else {
      _deallocate = ^(void *bytes) { free(bytes); };
    }
  }
  return self;
}

- (void)setError:(NSError * _Nullable * _Nullable)error
            code:(LFContentReaderErrorCode)code
       message:(NSString *)message {
  if (error != NULL) {
    *error = [NSError errorWithDomain:kLFContentReaderErrorDomain
                                 code:code
                             userInfo:@{NSLocalizedDescriptionKey : message}];
  }
}

- (nullable NSData *)readAtPath:(NSString *)path
                   maximumBytes:(size_t)maximumBytes
                          error:(NSError * _Nullable * _Nullable)error {
  if (error != NULL) {
    *error = nil;
  }
  if (path.length == 0U || maximumBytes == 0U) {
    [self setError:error
              code:LFContentReaderErrorExtent
           message:@"The selected content is invalid or unavailable."];
    return nil;
  }

  const int descriptor =
      _openFile(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
  if (descriptor < 0) {
    [self setError:error
              code:LFContentReaderErrorOpen
           message:@"The selected content could not be opened."];
    return nil;
  }

  struct stat before = {0};
  struct stat after = {0};
  LFContentReaderErrorCode errorCode = LFContentReaderErrorMetadata;
  NSString *errorMessage = @"The selected content could not be read.";
  uint8_t *buffer = NULL;
  NSData *content = nil;
  BOOL successfulRead = NO;
  size_t size = 0U;
  size_t offset = 0U;

  if (_statFile(descriptor, &before) != 0) {
    goto cleanup;
  }
  if (!S_ISREG(before.st_mode) || before.st_size <= 0 ||
      (uintmax_t)before.st_size > (uintmax_t)maximumBytes ||
      (uintmax_t)before.st_size > (uintmax_t)SIZE_MAX) {
    errorCode = LFContentReaderErrorExtent;
    errorMessage = @"The selected content has an invalid size or file type.";
    goto cleanup;
  }
  size = (size_t)before.st_size;
  buffer = (uint8_t *)_allocate(size);
  if (buffer == NULL) {
    errorCode = LFContentReaderErrorAllocation;
    errorMessage = @"The selected content could not be loaded.";
    goto cleanup;
  }

  while (offset < size) {
    const ssize_t count = _readFile(descriptor, buffer + offset, size - offset);
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (count <= 0) {
      errorCode = LFContentReaderErrorRead;
      errorMessage = @"The selected content is incomplete or unreadable.";
      goto cleanup;
    }
    offset += (size_t)count;
  }

  for (;;) {
    uint8_t extra = 0U;
    const ssize_t count = _readFile(descriptor, &extra, sizeof(extra));
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (count < 0) {
      errorCode = LFContentReaderErrorRead;
      errorMessage = @"The selected content could not be read completely.";
      goto cleanup;
    }
    if (count != 0) {
      errorCode = LFContentReaderErrorChanged;
      errorMessage = @"The selected content changed while it was being read.";
      goto cleanup;
    }
    break;
  }

  if (_statFile(descriptor, &after) != 0 || before.st_dev != after.st_dev ||
      before.st_ino != after.st_ino || before.st_size != after.st_size ||
      before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec ||
      before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec ||
      before.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec ||
      before.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec) {
    errorCode = LFContentReaderErrorChanged;
    errorMessage = @"The selected content changed while it was being read.";
    goto cleanup;
  }

  content = [NSData dataWithBytes:buffer length:size];
  if (content == nil) {
    errorCode = LFContentReaderErrorAllocation;
    errorMessage = @"The selected content could not be loaded.";
    goto cleanup;
  }
  successfulRead = YES;

cleanup:
  if (buffer != NULL) {
    _deallocate(buffer);
  }
  if (_closeFile(descriptor) != 0) {
    successfulRead = NO;
    errorCode = LFContentReaderErrorMetadata;
    errorMessage = @"The selected content could not be closed after reading.";
    content = nil;
  }
  if (!successfulRead) {
    [self setError:error code:errorCode message:errorMessage];
    return nil;
  }
  return content;
}
@end
