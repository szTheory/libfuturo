/* SPDX-License-Identifier: MIT */
#import "LFContentReader.h"

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const size_t kMaximumBytes = 1048704U;

typedef struct ReaderProbe {
  size_t openCalls;
  size_t statCalls;
  size_t readCalls;
  size_t closeCalls;
  size_t allocationCalls;
  size_t freeCalls;
  size_t fileSize;
  BOOL rejectOpen;
  BOOL refuseAllocation;
  BOOL truncateBeforeRead;
  BOOL growAfterFirstRead;
  BOOL interruptFirstRead;
  const char *growthPath;
  const char *truncatePath;
} ReaderProbe;

static int fail(const char *caseName) {
  (void)fprintf(stderr, "host_content: %s failed\n", caseName);
  return EXIT_FAILURE;
}

static NSString *temporaryPath(NSString *directory, NSString *suffix) {
  NSString *templatePath = [directory stringByAppendingPathComponent:
      [NSString stringWithFormat:@"reader-%@-%@.XXXXXX", suffix,
                                 NSUUID.UUID.UUIDString]];
  return templatePath;
}

static BOOL writeSizedFile(NSString *path, size_t size) {
  int descriptor = open(path.fileSystemRepresentation,
                         O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC,
                         S_IRUSR | S_IWUSR);
  if (descriptor < 0) {
    return NO;
  }
  BOOL success = ftruncate(descriptor, (off_t)size) == 0;
  if (success && size > 0U) {
    const uint8_t first = UINT8_C(0x5A);
    success = pwrite(descriptor, &first, sizeof(first), 0) == 1;
  }
  if (close(descriptor) != 0) {
    success = NO;
  }
  return success;
}

static LFContentReader *readerWithProbe(ReaderProbe *probe) {
  LFContentReaderHooks hooks = {0};
  hooks.openFile = ^int(const char *path, int flags) {
    ++probe->openCalls;
    if (probe->rejectOpen) {
      errno = EACCES;
      return -1;
    }
    return open(path, flags);
  };
  hooks.statFile = ^int(int descriptor, struct stat *status) {
    ++probe->statCalls;
    return fstat(descriptor, status);
  };
  hooks.readFile = ^ssize_t(int descriptor, void *bytes, size_t count) {
    ++probe->readCalls;
    if (probe->interruptFirstRead && probe->readCalls == 1U) {
      errno = EINTR;
      return -1;
    }
    if (probe->truncateBeforeRead && probe->readCalls == 1U) {
      const int writer = open(probe->truncatePath,
                              O_WRONLY | O_CLOEXEC);
      if (writer < 0 || ftruncate(writer, 0) != 0) {
        if (writer >= 0) {
          (void)close(writer);
        }
        return -1;
      }
      (void)close(writer);
    }
    const ssize_t result = read(descriptor, bytes, count);
    if (result > 0 && probe->growAfterFirstRead && probe->readCalls == 1U) {
      const uint8_t extra = UINT8_C(0xA5);
      const int writer = open(probe->growthPath, O_WRONLY | O_CLOEXEC);
      if (writer < 0 ||
          pwrite(writer, &extra, sizeof(extra), (off_t)probe->fileSize) != 1) {
        if (writer >= 0) {
          (void)close(writer);
        }
        return -1;
      }
      (void)close(writer);
    }
    return result;
  };
  hooks.closeFile = ^int(int descriptor) {
    ++probe->closeCalls;
    return close(descriptor);
  };
  hooks.allocate = ^void *(size_t size) {
    ++probe->allocationCalls;
    return probe->refuseAllocation ? NULL : malloc(size);
  };
  hooks.deallocate = ^(void *bytes) {
    ++probe->freeCalls;
    free(bytes);
  };
  return [[LFContentReader alloc] initWithHooks:&hooks];
}

static int checkSizeCases(NSString *directory) {
  const size_t sizes[] = {0U, 1U, kMaximumBytes - 1U,
                          kMaximumBytes, kMaximumBytes + 1U};
  for (size_t index = 0U; index < sizeof(sizes) / sizeof(sizes[0]); ++index) {
    NSString *path = temporaryPath(directory,
                                   [NSString stringWithFormat:@"%lu",
                                                              (unsigned long)index]);
    if (!writeSizedFile(path, sizes[index])) {
      return fail("create size fixture");
    }
    const BOOL shouldSucceed = sizes[index] > 0U && sizes[index] <= kMaximumBytes;
    ReaderProbe probe = {0};
    NSError *error = nil;
    NSData *content = [readerWithProbe(&probe)
        readAtPath:path maximumBytes:kMaximumBytes error:&error];
    if ((content != nil) != shouldSucceed ||
        (content != nil && content.length != sizes[index]) ||
        (content == nil && error == nil) || probe.openCalls != 1U ||
        probe.closeCalls != 1U ||
        probe.statCalls != (shouldSucceed ? 2U : 1U) ||
        probe.allocationCalls != (shouldSucceed ? 1U : 0U) ||
        probe.freeCalls != (shouldSucceed ? 1U : 0U) ||
        (shouldSucceed ? probe.readCalls < 2U : probe.readCalls != 0U)) {
      (void)unlink(path.fileSystemRepresentation);
      return fail("empty and exact extent boundaries");
    }
    (void)unlink(path.fileSystemRepresentation);
  }
  return EXIT_SUCCESS;
}

static int checkNonRegularCases(NSString *directory) {
  NSString *directoryPath = [directory stringByAppendingPathComponent:@"subdir"];
  if (mkdir(directoryPath.fileSystemRepresentation, S_IRWXU) != 0) {
    return fail("create directory fixture");
  }
  ReaderProbe directoryProbe = {0};
  NSError *error = nil;
  NSData *content = [readerWithProbe(&directoryProbe)
      readAtPath:directoryPath maximumBytes:kMaximumBytes error:&error];
  (void)rmdir(directoryPath.fileSystemRepresentation);
  if (content != nil || error == nil || directoryProbe.openCalls != 1U ||
      directoryProbe.statCalls != 1U || directoryProbe.readCalls != 0U ||
      directoryProbe.allocationCalls != 0U || directoryProbe.closeCalls != 1U) {
    return fail("reject directory");
  }

  NSString *fifoPath = [directory stringByAppendingPathComponent:@"reader-fifo"];
  if (mkfifo(fifoPath.fileSystemRepresentation, S_IRUSR | S_IWUSR) != 0) {
    return fail("create fifo fixture");
  }
  ReaderProbe fifoProbe = {0};
  error = nil;
  content = [readerWithProbe(&fifoProbe)
      readAtPath:fifoPath maximumBytes:kMaximumBytes error:&error];
  (void)unlink(fifoPath.fileSystemRepresentation);
  if (content != nil || error == nil || fifoProbe.openCalls != 1U ||
      fifoProbe.statCalls != 1U || fifoProbe.readCalls != 0U ||
      fifoProbe.allocationCalls != 0U || fifoProbe.closeCalls != 1U) {
    return fail("reject fifo without blocking");
  }
  return EXIT_SUCCESS;
}

static int checkUnreadableFile(NSString *directory) {
  NSString *path = temporaryPath(directory, @"unreadable");
  if (!writeSizedFile(path, 1U) || chmod(path.fileSystemRepresentation, 0U) != 0) {
    return fail("create unreadable fixture");
  }
  ReaderProbe probe = {0};
  NSError *error = nil;
  NSData *content = [readerWithProbe(&probe)
      readAtPath:path maximumBytes:kMaximumBytes error:&error];
  (void)chmod(path.fileSystemRepresentation, S_IRUSR | S_IWUSR);
  (void)unlink(path.fileSystemRepresentation);
  if (content != nil || error == nil || probe.openCalls != 1U ||
      probe.statCalls != 0U || probe.allocationCalls != 0U ||
      probe.closeCalls != 0U) {
    return fail("reject unreadable file");
  }
  return EXIT_SUCCESS;
}

static int checkInjectedFailures(NSString *directory) {
  NSString *path = temporaryPath(directory, @"injected");
  if (!writeSizedFile(path, 32U)) {
    return fail("create injected fixture");
  }

  NSString *missingPath = [directory stringByAppendingPathComponent:
      @"generated-sentinel-missing.a78"];
  ReaderProbe missingProbe = {0};
  NSError *error = nil;
  NSData *content = [readerWithProbe(&missingProbe)
      readAtPath:missingPath maximumBytes:kMaximumBytes error:&error];
  if (content != nil || error == nil ||
      error.code != LFContentReaderErrorOpen || missingProbe.openCalls != 1U ||
      missingProbe.closeCalls != 0U || missingProbe.allocationCalls != 0U ||
      [error.localizedDescription containsString:missingPath.lastPathComponent]) {
    (void)unlink(path.fileSystemRepresentation);
    return fail("missing file refusal without path disclosure");
  }

  ReaderProbe openProbe = {.rejectOpen = YES};
  error = nil;
  content = [readerWithProbe(&openProbe)
      readAtPath:path maximumBytes:kMaximumBytes error:&error];
  if (content != nil || error == nil || openProbe.closeCalls != 0U ||
      openProbe.openCalls != 1U || openProbe.allocationCalls != 0U ||
      [error.localizedDescription containsString:path.lastPathComponent]) {
    (void)unlink(path.fileSystemRepresentation);
    return fail("generic open refusal");
  }

  ReaderProbe allocationProbe = {.refuseAllocation = YES};
  error = nil;
  content = [readerWithProbe(&allocationProbe)
      readAtPath:path maximumBytes:kMaximumBytes error:&error];
  if (content != nil || error == nil || allocationProbe.closeCalls != 1U ||
      allocationProbe.allocationCalls != 1U || allocationProbe.freeCalls != 0U ||
      allocationProbe.statCalls != 1U || allocationProbe.readCalls != 0U) {
    (void)unlink(path.fileSystemRepresentation);
    return fail("allocation refusal cleanup");
  }

  ReaderProbe shortProbe = {.truncateBeforeRead = YES,
                            .truncatePath = path.fileSystemRepresentation};
  error = nil;
  content = [readerWithProbe(&shortProbe)
      readAtPath:path maximumBytes:kMaximumBytes error:&error];
  if (content != nil || error == nil || shortProbe.closeCalls != 1U ||
      shortProbe.allocationCalls != 1U || shortProbe.freeCalls != 1U ||
      shortProbe.statCalls != 1U || shortProbe.readCalls < 1U) {
    (void)unlink(path.fileSystemRepresentation);
    return fail("post-stat truncation cleanup");
  }

  (void)unlink(path.fileSystemRepresentation);
  if (!writeSizedFile(path, 32U)) {
    (void)unlink(path.fileSystemRepresentation);
    return fail("recreate injected fixture");
  }
  ReaderProbe growthProbe = {.fileSize = 32U,
                             .growAfterFirstRead = YES,
                             .growthPath = path.fileSystemRepresentation};
  error = nil;
  content = [readerWithProbe(&growthProbe)
      readAtPath:path maximumBytes:kMaximumBytes error:&error];
  if (content != nil || error == nil || growthProbe.closeCalls != 1U ||
      growthProbe.allocationCalls != 1U || growthProbe.freeCalls != 1U ||
      growthProbe.statCalls != 1U || growthProbe.readCalls < 2U) {
    (void)unlink(path.fileSystemRepresentation);
    return fail("post-stat growth cleanup");
  }

  (void)unlink(path.fileSystemRepresentation);
  if (!writeSizedFile(path, 32U)) {
    (void)unlink(path.fileSystemRepresentation);
    return fail("recreate interruption fixture");
  }
  ReaderProbe interruptProbe = {.interruptFirstRead = YES};
  error = nil;
  content = [readerWithProbe(&interruptProbe)
      readAtPath:path maximumBytes:kMaximumBytes error:&error];
  const BOOL interruptionRecovered = content != nil && content.length == 32U &&
                                     interruptProbe.readCalls >= 3U &&
                                     interruptProbe.closeCalls == 1U &&
                                     interruptProbe.freeCalls == 1U;
  (void)unlink(path.fileSystemRepresentation);
  if (!interruptionRecovered) {
    return fail("EINTR retry and successful ownership cleanup");
  }
  return EXIT_SUCCESS;
}

int main(void) {
  @autoreleasepool {
    NSString *directory = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @"libfuturo-reader-%@", NSUUID.UUID.UUIDString]];
    if (mkdir(directory.fileSystemRepresentation, S_IRWXU) != 0) {
      return fail("create scratch directory");
    }
    int result = checkSizeCases(directory);
    if (result == EXIT_SUCCESS) {
      result = checkNonRegularCases(directory);
    }
    if (result == EXIT_SUCCESS) {
      result = checkUnreadableFile(directory);
    }
    if (result == EXIT_SUCCESS) {
      result = checkInjectedFailures(directory);
    }
    (void)rmdir(directory.fileSystemRepresentation);
    if (result != EXIT_SUCCESS) {
      return result;
    }
    (void)printf("host_content: sizes=empty,1,max-minus-one,max,max-plus-one "
                 "nonregular=directory,fifo unreadable=pass truncation=pass "
                 "growth=pass allocation=pass eintr=pass cleanup=pass result=pass\n");
    return EXIT_SUCCESS;
  }
}
