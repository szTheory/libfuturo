/* SPDX-License-Identifier: MIT */
#ifndef LIBFUTURO_INSTALLED_MACOS_HOST_LFHOSTSESSIONTESTING_H
#define LIBFUTURO_INSTALLED_MACOS_HOST_LFHOSTSESSIONTESTING_H

#if !defined(LF_HOST_SESSION_TESTING)
#error "LFHostSessionTesting.h is available only to host_tracer"
#endif

#import "LFHost.h"
#import "LFContentReader.h"

#include <libfuturo/libfuturo.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^LFHostSessionProfileMutation)(lf_profile *profile);
typedef void (^LFHostSessionResultMutation)(lf_run_result *result);

@interface LFHostSession (Testing)
- (BOOL)enableManualTimerDeliveryForTesting;
- (void)deliverTimerForTestingWithCompletion:(nullable dispatch_block_t)completion;
- (void)readTimingStateForTesting:
    (void (^)(uint64_t nextIndex, uint64_t deadline, BOOL active))completion;
- (BOOL)armResultMutationForTesting:(LFHostSessionResultMutation)resultMutation;
- (BOOL)configureTestingBeforeOpenWithProfileMutation:
            (nullable LFHostSessionProfileMutation)profileMutation
    resultMutation:(nullable LFHostSessionResultMutation)resultMutation
      contentReader:(nullable LFContentReader *)contentReader;
@end

NS_ASSUME_NONNULL_END

#endif
