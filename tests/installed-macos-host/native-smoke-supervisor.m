/* SPDX-License-Identifier: MIT */

#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE 1

#import <AppKit/AppKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "native-smoke-protocol.h"

static bool lf_supervisor_protocol_handler(void *context,
                                           LFTerminationRequest request,
                                           uint64_t sequence);

static uint64_t lf_monotonic_milliseconds(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
    return 0U;
  }
  return (uint64_t)now.tv_sec * UINT64_C(1000) +
         (uint64_t)now.tv_nsec / UINT64_C(1000000);
}

static int lf_write_status(NSString *statusPath, const char *state,
                           uint64_t sequence, int errorCode) {
  char temporaryPath[PATH_MAX];
  const char *path = statusPath.fileSystemRepresentation;
  int pathLength = snprintf(temporaryPath, sizeof(temporaryPath), "%s.tmp.%ld",
                            path, (long)getpid());
  if (pathLength < 0 || (size_t)pathLength >= sizeof(temporaryPath)) {
    errno = ENAMETOOLONG;
    return -1;
  }

  int descriptor = open(temporaryPath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
                        S_IRUSR | S_IWUSR);
  if (descriptor < 0) {
    return -1;
  }

  char line[160];
  int lineLength;
  if (strcmp(state, "unknown") == 0) {
    lineLength = snprintf(line, sizeof(line), "%s %llu %d\n", state,
                          (unsigned long long)sequence, errorCode);
  } else {
    lineLength = snprintf(line, sizeof(line), "%s %llu\n", state,
                          (unsigned long long)sequence);
  }
  if (lineLength < 0 || (size_t)lineLength >= sizeof(line)) {
    (void)close(descriptor);
    (void)unlink(temporaryPath);
    errno = EOVERFLOW;
    return -1;
  }

  size_t bytesWritten = 0U;
  while (bytesWritten < (size_t)lineLength) {
    ssize_t count = write(descriptor, line + bytesWritten,
                          (size_t)lineLength - bytesWritten);
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (count <= 0) {
      int savedError = errno;
      (void)close(descriptor);
      (void)unlink(temporaryPath);
      errno = savedError;
      return -1;
    }
    bytesWritten += (size_t)count;
  }

  int closeStatus = close(descriptor);
  if (closeStatus != 0 || rename(temporaryPath, path) != 0) {
    int savedError = errno;
    (void)unlink(temporaryPath);
    errno = savedError;
    return -1;
  }
  return 0;
}

@interface LFNativeSmokeSupervisor : NSObject {
@private
  LFSmokeProtocol _controlProtocol;
}
@property(nonatomic, copy) NSString *statusPath;
@property(nonatomic, strong) NSRunningApplication *application;
@property(nonatomic, strong) NSError *launchError;
@property(nonatomic) BOOL launchCompleted;
@property(nonatomic) BOOL terminationRequested;
@property(nonatomic) BOOL normalTerminationAttempted;
@property(nonatomic) BOOL forceTerminationRequested;
@property(nonatomic) BOOL forceTerminationSent;
@property(nonatomic) BOOL failed;
@property(nonatomic) uint64_t forceDeadlineMilliseconds;
@property(nonatomic) uint64_t forceVerificationDeadlineMilliseconds;
- (BOOL)handleRequest:(LFTerminationRequest)request sequence:(uint64_t)sequence;
- (int)runWithBundlePath:(NSString *)bundlePath
               arguments:(NSArray<NSString *> *)arguments;
@end

@implementation LFNativeSmokeSupervisor

- (BOOL)publishState:(const char *)state errorCode:(int)errorCode {
  if (lf_write_status(self.statusPath, state,
                      lf_smoke_protocol_last_sequence(&_controlProtocol),
                      errorCode) == 0) {
    return YES;
  }
  (void)fprintf(stderr, "native smoke supervisor: cannot write status: %s\n",
                strerror(errno));
  self.failed = YES;
  return NO;
}

- (void)publishUnknown:(int)errorCode message:(const char *)message {
  (void)fprintf(stderr, "native smoke supervisor: %s\n", message);
  (void)[self publishState:"unknown" errorCode:errorCode];
  self.failed = YES;
}

- (BOOL)requestNormalTermination {
  if (self.application == nil) {
    return YES;
  }
  if (self.application.isTerminated) {
    return [self publishState:"terminated" errorCode:0];
  }
  BOOL requestSent = [self.application terminate];
  if (!requestSent && !self.application.isTerminated) {
    // LaunchServices may report that the app is no longer running before its
    // retained NSRunningApplication instance reflects termination. Keep that
    // exact instance and let the run loop observe it before declaring failure.
    (void)fprintf(stderr,
                  "native smoke supervisor: normal termination request was not sent; waiting for exact-instance state\n");
  }
  self.normalTerminationAttempted = YES;
  self.forceDeadlineMilliseconds =
      lf_monotonic_milliseconds() + UINT64_C(5000);
  return [self publishState:"running" errorCode:0];
}

- (BOOL)requestForceTermination {
  if (self.application == nil) {
    [self publishUnknown:ESRCH
                 message:"cannot force terminate before LaunchServices returns the app instance"];
    return NO;
  }
  if (self.application.isTerminated) {
    return [self publishState:"terminated" errorCode:0];
  }
  if (!self.normalTerminationAttempted) {
    self.terminationRequested = YES;
    if (![self requestNormalTermination]) {
      return NO;
    }
    if (self.application.isTerminated) {
      return [self publishState:"terminated" errorCode:0];
    }
  }
  self.forceTerminationRequested = YES;
  return [self publishState:"running" errorCode:0];
}

- (BOOL)handleRequest:(LFTerminationRequest)request sequence:(uint64_t)sequence {
  (void)sequence;
  if (self.application == nil) {
    if (request == LFRequestForceTerminate) {
      [self publishUnknown:ESRCH
                   message:"force termination requested without a known app instance"];
      return NO;
    }
    self.terminationRequested = YES;
    return [self publishState:"starting" errorCode:0];
  }
  if (self.application.isTerminated) {
    return [self publishState:"terminated" errorCode:0];
  }

  if (request == LFRequestTerminate) {
    self.terminationRequested = YES;
    return [self requestNormalTermination];
  }
  self.terminationRequested = YES;
  return [self requestForceTermination];
}

- (BOOL)readControlRequests {
  struct pollfd controlDescriptor = {STDIN_FILENO, POLLIN, 0};
  int pollStatus = poll(&controlDescriptor, 1U, 0);
  if (pollStatus < 0) {
    if (errno == EINTR) {
      return YES;
    }
    [self publishUnknown:errno message:"control channel poll failed"];
    return NO;
  }
  if (pollStatus == 0) {
    return YES;
  }
  if ((controlDescriptor.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
    [self publishUnknown:EPIPE message:"control channel closed unexpectedly"];
    return NO;
  }

  char bytes[256];
  ssize_t count = read(STDIN_FILENO, bytes, sizeof(bytes));
  if (count < 0) {
    if (errno == EINTR || errno == EAGAIN) {
      return YES;
    }
    [self publishUnknown:errno message:"control channel read failed"];
    return NO;
  }
  if (count == 0) {
    [self publishUnknown:EPIPE message:"control channel reached EOF"];
    return NO;
  }

  return lf_smoke_protocol_feed(&_controlProtocol, bytes, (size_t)count,
                                lf_supervisor_protocol_handler,
                                (__bridge void *)self)
             ? YES
             : NO;
}

- (BOOL)launchBundleAtPath:(NSString *)bundlePath
                 arguments:(NSArray<NSString *> *)arguments {
  NSURL *bundleURL = [NSURL fileURLWithPath:bundlePath isDirectory:YES];
  NSWorkspaceOpenConfiguration *configuration =
      [NSWorkspaceOpenConfiguration configuration];
  configuration.createsNewApplicationInstance = YES;
  configuration.arguments = arguments;
  self.launchCompleted = NO;
  self.launchError = nil;
  self.application = nil;

  [[NSWorkspace sharedWorkspace]
      openApplicationAtURL:bundleURL
             configuration:configuration
         completionHandler:^(NSRunningApplication *application,
                             NSError *error) {
           dispatch_async(dispatch_get_main_queue(), ^{
             self.application = application;
             self.launchError = error;
             self.launchCompleted = YES;
           });
         }];

  const uint64_t launchDeadline =
      lf_monotonic_milliseconds() + UINT64_C(30000);
  while (!self.launchCompleted &&
         lf_monotonic_milliseconds() < launchDeadline) {
    (void)CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
    if (![self readControlRequests]) {
      return NO;
    }
    if (!self.failed) {
      (void)poll(NULL, 0U, 30);
    }
  }

  if (!self.launchCompleted) {
    [self publishUnknown:ETIMEDOUT
                 message:"LaunchServices did not return an app instance within 30 seconds"];
    return NO;
  }
  if (self.launchError != nil || self.application == nil) {
    if (self.launchError != nil) {
      const char *domain = self.launchError.domain.UTF8String;
      NSError *underlyingError =
          self.launchError.userInfo[NSUnderlyingErrorKey];
      const char *underlyingDomain = underlyingError.domain.UTF8String;
      (void)fprintf(stderr,
                    "native smoke supervisor: LaunchServices NSError "
                    "domain=%s code=%ld underlying_domain=%s "
                    "underlying_code=%ld\n",
                    domain == NULL ? "(null)" : domain,
                    (long)self.launchError.code,
                    underlyingDomain == NULL ? "(none)" : underlyingDomain,
                    underlyingError == nil ? 0L : (long)underlyingError.code);
    }
    [self publishUnknown:ENOENT message:"LaunchServices could not open the app bundle"];
    return NO;
  }
  if (self.application.isTerminated) {
    return [self publishState:"terminated" errorCode:0];
  }

  if (self.terminationRequested) {
    return [self requestNormalTermination];
  }
  return [self publishState:"running" errorCode:0];
}

- (int)runWithBundlePath:(NSString *)bundlePath
               arguments:(NSArray<NSString *> *)arguments {
  lf_smoke_protocol_init(&_controlProtocol);
  if (![self publishState:"starting" errorCode:0]) {
    return 2;
  }
  if (![self launchBundleAtPath:bundlePath arguments:arguments]) {
    return 2;
  }

  for (;;) {
    if (self.application != nil && self.application.isTerminated) {
      if (![self publishState:"terminated" errorCode:0]) {
        return 2;
      }
      return 0;
    }
    const uint64_t now = lf_monotonic_milliseconds();
    if (self.forceTerminationRequested &&
        now >= self.forceDeadlineMilliseconds) {
      BOOL requestSent = [self.application forceTerminate];
      if (self.application.isTerminated) {
        if (![self publishState:"terminated" errorCode:0]) {
          return 2;
        }
        return 0;
      }
      self.forceTerminationRequested = NO;
      self.forceTerminationSent = YES;
      self.forceVerificationDeadlineMilliseconds = now + UINT64_C(5000);
      if (!requestSent) {
        (void)fprintf(stderr,
                      "native smoke supervisor: force termination request was not sent; waiting for exact-instance state\n");
      }
      if (![self publishState:"running" errorCode:0]) {
        return 2;
      }
    }
    if (self.forceTerminationSent &&
        now >= self.forceVerificationDeadlineMilliseconds) {
      [self publishUnknown:ETIMEDOUT
                    message:"exact app instance did not terminate within 5 seconds after force termination"];
      return 2;
    }

    (void)CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
    if (![self readControlRequests]) {
      return 2;
    }
    if (self.failed) {
      return 2;
    }
    (void)poll(NULL, 0U, 30);
  }
}
@end

static bool lf_supervisor_protocol_handler(void *context,
                                           LFTerminationRequest request,
                                           uint64_t sequence) {
  LFNativeSmokeSupervisor *supervisor = (__bridge LFNativeSmokeSupervisor *)context;
  return [supervisor handleRequest:request sequence:sequence] ? true : false;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 4 || strcmp(argv[3], "--") != 0) {
      (void)fprintf(stderr,
                    "usage: %s <status-path> <app-bundle> -- <app-argument>...\n",
                    argv[0]);
      return 2;
    }
    NSString *statusPath = [NSString stringWithUTF8String:argv[1]];
    NSString *bundlePath = [NSString stringWithUTF8String:argv[2]];
    if (statusPath == nil || bundlePath == nil) {
      (void)fprintf(stderr, "native smoke supervisor: invalid UTF-8 path\n");
      return 2;
    }
    NSMutableArray<NSString *> *arguments = [NSMutableArray array];
    for (int index = 4; index < argc; ++index) {
      NSString *argument = [NSString stringWithUTF8String:argv[index]];
      if (argument == nil) {
        (void)fprintf(stderr,
                      "native smoke supervisor: invalid UTF-8 app argument\n");
        return 2;
      }
      [arguments addObject:argument];
    }

    LFNativeSmokeSupervisor *supervisor =
        [[LFNativeSmokeSupervisor alloc] init];
    supervisor.statusPath = statusPath;
    return [supervisor runWithBundlePath:bundlePath arguments:arguments];
  }
}
