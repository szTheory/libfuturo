/* SPDX-License-Identifier: MIT */
#import "LFInputState.h"

@implementation LFInputState {
  LFInputButtonsHandler _buttonsHandler;
  NSMutableDictionary<NSNumber *, NSNumber *> *_pressedKeys;
  uint32_t _buttons;
  BOOL _observing;
}

static uint32_t lf_buttons_for_key_code(unsigned short keyCode) {
  switch (keyCode) {
    case 49U: /* Space: port 0 Button 1 */
      return UINT32_C(0x0001);
    case 126U: /* Up: port 0 Up */
      return UINT32_C(0x0010);
    case 125U: /* Down: port 0 Down */
      return UINT32_C(0x0020);
    case 123U: /* Left: port 0 Left */
      return UINT32_C(0x0040);
    case 124U: /* Right: port 0 Right */
      return UINT32_C(0x0080);
    case 3U: /* F physical key position: port 1 Button 1 */
      return UINT32_C(0x0100);
    case 13U: /* W physical key position: port 1 Up */
      return UINT32_C(0x1000);
    case 1U: /* S physical key position: port 1 Down */
      return UINT32_C(0x2000);
    case 0U: /* A physical key position: port 1 Left */
      return UINT32_C(0x4000);
    case 2U: /* D physical key position: port 1 Right */
      return UINT32_C(0x8000);
    default:
      return 0U;
  }
}

static uint32_t lf_buttons_for_characters(NSString *characters) {
  if (characters.length != 1U) {
    return 0U;
  }
  const unichar character = [characters.lowercaseString characterAtIndex:0U];
  switch (character) {
    case 'f':
      return UINT32_C(0x0100);
    case 'w':
      return UINT32_C(0x1000);
    case 's':
      return UINT32_C(0x2000);
    case 'a':
      return UINT32_C(0x4000);
    case 'd':
      return UINT32_C(0x8000);
    default:
      return 0U;
  }
}

- (instancetype)initWithButtonsHandler:(LFInputButtonsHandler)handler {
  self = [super init];
  if (self != nil) {
    _buttonsHandler = [handler copy];
    _pressedKeys = [NSMutableDictionary dictionary];
  }
  return self;
}

- (BOOL)handleKeyEvent:(NSEvent *)event pressed:(BOOL)pressed {
  NSAssert([NSThread isMainThread], @"AppKit key state must update on main");
  if (event == nil) {
    return NO;
  }
  uint32_t bit = lf_buttons_for_key_code(event.keyCode);
  if (bit == 0U) {
    bit = lf_buttons_for_characters(event.charactersIgnoringModifiers);
  }
  uint32_t updated = 0U;
  BOOL changed = NO;
  @synchronized(self) {
    const uint32_t previous = _buttons;
    NSNumber *key = @(event.keyCode);
    if (pressed) {
      if (bit != 0U) {
        _pressedKeys[key] = @(bit);
      }
    } else {
      [_pressedKeys removeObjectForKey:key];
    }
    for (NSNumber *pressedBit in _pressedKeys.allValues) {
      updated |= pressedBit.unsignedIntValue;
    }
    changed = updated != previous;
    _buttons = updated;
  }
  if (changed && _buttonsHandler != nil) {
    _buttonsHandler(updated);
  }
  /* The game view has no text input; consume unmapped events to avoid the
   * default NSView key handler beeping for keys without an action. */
  return YES;
}

- (uint32_t)buttons {
  @synchronized(self) {
    return _buttons;
  }
}

- (void)clearAll {
  BOOL changed = NO;
  @synchronized(self) {
    changed = _buttons != 0U;
    [_pressedKeys removeAllObjects];
    _buttons = 0U;
  }
  if (changed && _buttonsHandler != nil) {
    _buttonsHandler(0U);
  }
}

- (void)observeWindow:(NSWindow *)window application:(NSApplication *)application {
  NSAssert([NSThread isMainThread], @"AppKit observers must install on main");
  [self stopObserving];
  NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
  [center addObserver:self
             selector:@selector(windowDidResignKey:)
                 name:NSWindowDidResignKeyNotification
               object:window];
  [center addObserver:self
             selector:@selector(applicationDidResignActive:)
                 name:NSApplicationDidResignActiveNotification
               object:application];
  _observing = YES;
}

- (void)stopObserving {
  if (_observing) {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    _observing = NO;
  }
  [self clearAll];
}

- (void)windowDidResignKey:(NSNotification *)notification {
  (void)notification;
  [self clearAll];
}

- (void)applicationDidResignActive:(NSNotification *)notification {
  (void)notification;
  [self clearAll];
}

@end

@implementation LFInputView
- (BOOL)acceptsFirstResponder {
  return YES;
}

- (void)keyDown:(NSEvent *)event {
  if (![self.inputState handleKeyEvent:event pressed:YES]) {
    [super keyDown:event];
  }
}

- (void)keyUp:(NSEvent *)event {
  if (![self.inputState handleKeyEvent:event pressed:NO]) {
    [super keyUp:event];
  }
}

- (BOOL)resignFirstResponder {
  const BOOL resigned = [super resignFirstResponder];
  if (resigned) {
    [self.inputState clearAll];
  }
  return resigned;
}
@end
