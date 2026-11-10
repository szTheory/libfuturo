/* SPDX-License-Identifier: MIT */
#ifndef LIBFUTURO_INSTALLED_MACOS_HOST_LFINPUTSTATE_H
#define LIBFUTURO_INSTALLED_MACOS_HOST_LFINPUTSTATE_H

#import <AppKit/AppKit.h>

#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^LFInputButtonsHandler)(uint32_t buttons);

@interface LFInputState : NSObject
@property(nonatomic, readonly) uint32_t buttons;
- (instancetype)initWithButtonsHandler:(nullable LFInputButtonsHandler)handler;
/* Returns YES for every nonnil event so the game view consumes non-game keys. */
- (BOOL)handleKeyEvent:(NSEvent *_Nullable)event pressed:(BOOL)pressed;
- (void)clearAll;
- (void)observeWindow:(nullable NSWindow *)window
          application:(NSApplication *)application;
- (void)stopObserving;
@end

@interface LFInputView : NSView
@property(nonatomic, strong, nullable) LFInputState *inputState;
@end

NS_ASSUME_NONNULL_END

#endif
