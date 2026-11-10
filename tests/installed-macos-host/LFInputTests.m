/* SPDX-License-Identifier: MIT */
#import "LFInputState.h"

#include <stdio.h>
#include <stdlib.h>

typedef struct {
  unsigned short keyCode;
  __unsafe_unretained NSString *characters;
  uint32_t buttons;
} LFInputMappingCase;

@interface LFInputRoutingProbe : LFInputView
@property(nonatomic) BOOL interpretedKeyEvents;
@end

@implementation LFInputRoutingProbe
- (void)interpretKeyEvents:(NSArray<NSEvent *> *)eventArray {
  (void)eventArray;
  self.interpretedKeyEvents = YES;
}
@end

static NSEvent *keyboard_event(NSEventType type, unsigned short keyCode,
                               NSString *characters, BOOL repeated) {
  return [NSEvent keyEventWithType:type
                           location:NSZeroPoint
                      modifierFlags:0
                          timestamp:0.0
                       windowNumber:0
                            context:nil
                         characters:characters
        charactersIgnoringModifiers:characters
                          isARepeat:repeated
                            keyCode:keyCode];
}

static void send_key(LFInputView *view, unsigned short keyCode,
                     NSString *characters, BOOL pressed, BOOL repeated) {
  NSEvent *event = keyboard_event(pressed ? NSEventTypeKeyDown
                                          : NSEventTypeKeyUp,
                                  keyCode,
                                  characters, repeated);
  if (pressed) {
    [view keyDown:event];
  } else {
    [view keyUp:event];
  }
}

static BOOL input_state_has(LFInputState *state, uint32_t expected) {
  return state.buttons == expected;
}

static BOOL test_port1_w_mapping(void) {
  LFInputState *state = [[LFInputState alloc] initWithButtonsHandler:nil];
  LFInputView *view = [[LFInputView alloc] initWithFrame:NSZeroRect];
  view.inputState = state;
  if (!view.acceptsFirstResponder) {
    return NO;
  }
  send_key(view, 13U, @"w", YES, NO);
  const BOOL pressed = input_state_has(state, UINT32_C(0x1000));
  send_key(view, 13U, @"w", NO, NO);
  return pressed && input_state_has(state, 0U);
}

static BOOL test_remaining_mappings(void) {
  static const LFInputMappingCase cases[] = {
      {0U, @"a", UINT32_C(0x4000)},
      {1U, @"s", UINT32_C(0x2000)},
      {2U, @"d", UINT32_C(0x8000)},
      {3U, @"f", UINT32_C(0x0100)},
      {49U, @" ", UINT32_C(0x0001)},
      {123U, @"\uF702", UINT32_C(0x0040)},
      {124U, @"\uF703", UINT32_C(0x0080)},
      {125U, @"\uF701", UINT32_C(0x0020)},
      {126U, @"\uF700", UINT32_C(0x0010)},
  };
  LFInputState *state = [[LFInputState alloc] initWithButtonsHandler:nil];
  LFInputView *view = [[LFInputView alloc] initWithFrame:NSZeroRect];
  view.inputState = state;
  for (NSUInteger index = 0U;
       index < sizeof(cases) / sizeof(cases[0]); ++index) {
    send_key(view, cases[index].keyCode, cases[index].characters, YES, NO);
    if (!input_state_has(state, cases[index].buttons)) {
      return NO;
    }
    send_key(view, cases[index].keyCode, cases[index].characters, NO, NO);
    if (!input_state_has(state, 0U)) {
      return NO;
    }
  }
  return YES;
}

static BOOL test_layout_letters_and_unmapped_key_consumption(void) {
  static const LFInputMappingCase cases[] = {
      {10U, @"w", UINT32_C(0x1000)},
      {12U, @"a", UINT32_C(0x4000)},
      {6U, @"s", UINT32_C(0x2000)},
      {8U, @"d", UINT32_C(0x8000)},
      {9U, @"f", UINT32_C(0x0100)},
  };
  LFInputState *state = [[LFInputState alloc] initWithButtonsHandler:nil];
  LFInputView *view = [[LFInputView alloc] initWithFrame:NSZeroRect];
  view.inputState = state;
  for (NSUInteger index = 0U;
       index < sizeof(cases) / sizeof(cases[0]); ++index) {
    send_key(view, cases[index].keyCode, cases[index].characters, YES, NO);
    if (!input_state_has(state, cases[index].buttons)) {
      return NO;
    }
    send_key(view, cases[index].keyCode, cases[index].characters, NO, NO);
    if (!input_state_has(state, 0U)) {
      return NO;
    }
  }

  send_key(view, 13U, @"w", YES, NO);
  send_key(view, 10U, @"w", YES, NO);
  send_key(view, 13U, @"w", NO, NO);
  if (!input_state_has(state, UINT32_C(0x1000))) {
    return NO;
  }
  send_key(view, 10U, @"w", NO, NO);
  if (!input_state_has(state, 0U)) {
    return NO;
  }

  LFInputRoutingProbe *probe =
      [[LFInputRoutingProbe alloc] initWithFrame:NSZeroRect];
  probe.inputState = state;
  send_key(probe, 7U, @"x", YES, NO);
  return input_state_has(state, 0U) && !probe.interpretedKeyEvents;
}

static BOOL test_independent_held_keys(void) {
  LFInputState *state = [[LFInputState alloc] initWithButtonsHandler:nil];
  LFInputView *view = [[LFInputView alloc] initWithFrame:NSZeroRect];
  view.inputState = state;
  send_key(view, 13U, @"w", YES, NO);
  send_key(view, 1U, @"s", YES, NO);
  send_key(view, 13U, @"w", YES, YES);
  if (!input_state_has(state, UINT32_C(0x3000))) {
    return NO;
  }
  send_key(view, 13U, @"w", NO, NO);
  if (!input_state_has(state, UINT32_C(0x2000))) {
    return NO;
  }
  send_key(view, 1U, @"s", NO, NO);
  if (!input_state_has(state, 0U)) {
    return NO;
  }
  send_key(view, 126U, @"\uF700", YES, NO);
  send_key(view, 125U, @"\uF701", YES, NO);
  if (!input_state_has(state, UINT32_C(0x0030))) {
    return NO;
  }
  send_key(view, 126U, @"\uF700", NO, NO);
  if (!input_state_has(state, UINT32_C(0x0020))) {
    return NO;
  }
  send_key(view, 7U, @"x", YES, NO);
  if (!input_state_has(state, UINT32_C(0x0020))) {
    return NO;
  }
  send_key(view, 125U, @"\uF701", NO, NO);
  return input_state_has(state, 0U);
}

static BOOL test_null_key_event_is_ignored(void) {
  LFInputState *state = [[LFInputState alloc] initWithButtonsHandler:nil];
  if ([state handleKeyEvent:nil pressed:YES] ||
      !input_state_has(state, 0U)) {
    return NO;
  }
  return ![state handleKeyEvent:nil pressed:NO] &&
         input_state_has(state, 0U);
}

static BOOL test_first_responder_loss_clears(void) {
  LFInputState *state = [[LFInputState alloc] initWithButtonsHandler:nil];
  LFInputView *view = [[LFInputView alloc] initWithFrame:NSZeroRect];
  view.inputState = state;
  send_key(view, 13U, @"w", YES, NO);
  send_key(view, 3U, @"f", YES, NO);
  if (!input_state_has(state, UINT32_C(0x1100))) {
    return NO;
  }
  return [view resignFirstResponder] && input_state_has(state, 0U);
}

static BOOL test_focus_notifications_and_teardown(void) {
  LFInputState *state = [[LFInputState alloc] initWithButtonsHandler:nil];
  LFInputView *view = [[LFInputView alloc] initWithFrame:NSZeroRect];
  view.inputState = state;
  [state observeWindow:nil application:NSApp];
  send_key(view, 13U, @"w", YES, NO);
  send_key(view, 3U, @"f", YES, NO);
  [[NSNotificationCenter defaultCenter]
      postNotificationName:NSWindowDidResignKeyNotification
                    object:nil];
  if (!input_state_has(state, 0U)) {
    return NO;
  }
  send_key(view, 13U, @"w", YES, NO);
  send_key(view, 3U, @"f", YES, NO);
  [[NSNotificationCenter defaultCenter]
      postNotificationName:NSApplicationDidResignActiveNotification
                    object:NSApp];
  if (!input_state_has(state, 0U)) {
    return NO;
  }
  [state stopObserving];
  send_key(view, 13U, @"w", YES, NO);
  [[NSNotificationCenter defaultCenter]
      postNotificationName:NSWindowDidResignKeyNotification
                    object:nil];
  return input_state_has(state, UINT32_C(0x1000));
}

int main(void) {
  @autoreleasepool {
    (void)[NSApplication sharedApplication];
    static const struct {
      const char *name;
      BOOL (*run)(void);
    } tests[] = {
        {"port 1 W key sets and clears bit 12", test_port1_w_mapping},
        {"remaining nine key mappings set and clear their bits",
         test_remaining_mappings},
        {"letter aliases hold independently and unmapped keys are consumed",
         test_layout_letters_and_unmapped_key_consumption},
        {"repeats, interleaved releases, opposing keys and unknown keys preserve independent state",
         test_independent_held_keys},
        {"null key events do not mutate a joystick bit",
         test_null_key_event_is_ignored},
        {"resigning the first responder releases all held keys",
         test_first_responder_loss_clears},
        {"window and application resignation clear keys and teardown unregisters observers",
         test_focus_notifications_and_teardown},
    };
    NSUInteger failures = 0U;
    (void)printf("TAP version 13\n");
    for (NSUInteger index = 0U;
         index < sizeof(tests) / sizeof(tests[0]); ++index) {
      const BOOL passed = tests[index].run();
      (void)printf("%s %lu - %s\n", passed ? "ok" : "not ok",
                   (unsigned long)(index + 1U), tests[index].name);
      if (!passed) {
        ++failures;
      }
    }
    (void)printf("1..%lu\n",
                 (unsigned long)(sizeof(tests) / sizeof(tests[0])));
    (void)printf("# host_input: mappings=10 layout=letters-and-US-position aliases=independent unmapped=consumed repeats=pass focus=first-responder,window,app lost result=%s\n",
                 failures == 0U ? "pass" : "fail");
    return failures == 0U ? EXIT_SUCCESS : EXIT_FAILURE;
  }
}
