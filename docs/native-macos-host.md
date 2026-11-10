# Native macOS host

The first interactive host is a local macOS arm64 consumer of the installed
`libfuturo` package and the `muhtari-ntsc-v1` profile. It accepts caller
content through an AppKit Open panel or `--content <file>`. Both routes use the
same bounded reader and load path. Starting without `--content` opens the
picker; canceling it leaves the host idle, so the canvas remains black until
content loads.

The window title and accessible title show **No content**, **Opening**, or
**Ready: _filename_**. Ready appears after the active content's first frame has
been presented. The host submits AppKit accessibility announcements when that
state changes. The Open button, File > Open… menu item, and Command-O shortcut
share one availability rule; they are disabled during loading, while a picker
or error sheet is open, and during shutdown.

The minimum content size keeps a 320 × 242 point display viewport and the full
controller legend plus Open button visible. Its height is 302 points; its
width is derived from the larger of the display with margins and the measured
legend width with the existing footer spacing.

## Optional local launch

Run the canonical check first. It creates and verifies a project-authored A78
diagnostic and preserves that generated fixture under ignored build output.
The fixture is for development and automated acceptance; the host does not
special-case it.

From the checkout root on macOS arm64:

```sh
./scripts/check.sh

FIXTURE="$(find build/check/relocation-reports/host-artifacts \
  -type f -name diagnostic-fixture.a78 -print | LC_ALL=C sort | tail -n 1)"
test -n "$FIXTURE" && test -f "$FIXTURE"

PREFIX="$PWD/build/macos-host-prefix"
cmake --install build/check --prefix "$PREFIX"

cmake -S tests/installed-macos-host -B build/macos-host \
  -DEXPECTED_INSTALL_PREFIX="$PREFIX" \
  -DMUHTARI_FIXTURE_PATH="$PWD/$FIXTURE" \
  -DMUHTARI_ORACLE_INCLUDE_DIR="$PWD/tests/installed-consumer" \
  -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build build/macos-host --target installed_macos_host --parallel 2
```

Open the picker:

```sh
open -W -a "$PWD/build/macos-host/installed_macos_host.app"
```

Or load a local A78 directly:

```sh
open -W -a "$PWD/build/macos-host/installed_macos_host.app" \
  --args --content "/path/to/content.a78"
```

The picker accepts caller-selected content; its `.a78` filter is only a
convenience. The selected profile rejects empty, non-regular, unreadable,
truncated, and over-limit files before loading. Its maximum input extent is
1,048,704 bytes. A reader or load failure displays a content-specific error
and returns to idle so another file can be selected. A playback scheduler or
first-advance failure instead says playback could not start and offers Open as
the recovery path; other session-start failures do not incorrectly label the
file unsupported. Closing or rejecting content stops new guest work, waits for
an already reserved call, then destroys the instance and releases its buffers.
A core call that hangs can still prevent shutdown from finishing.

## Controls and display

The visible legend maps the two ports as follows:

| Port | Directions | Button 1 |
| --- | --- | --- |
| 0 | Arrow keys | Space |
| 1 | W / A / S / D | F |

The host recognizes W / A / S / D / F by typed letter and by the matching US
physical key position, so the letter controls work across keyboard layouts.
Other keys are consumed by the game view without reaching AppKit's text-input
handler. Repeated key events are consumed, and held input clears when the view,
window, or application loses focus. Input is sampled immediately before each
serialized `lf_advance`; a tap shorter than one frame can be missed.

The display preserves the profile's 320 × 242 raster ratio, letterboxes when
needed, and uses nearest-neighbor scaling. Raw INDEX8 output remains separate
from the RGBA presentation surface. The copied warm NTSC palette is an
emulator approximation, not calibrated Atari hardware output; its provenance
and required MIT/BSD-3-Clause notices are in
[`tests/installed-macos-host/MUHTARI-PALETTE-NOTICES.md`](../tests/installed-macos-host/MUHTARI-PALETTE-NOTICES.md).

The first partial guest interval runs immediately after load. The schedule
then targets exactly 39,375,000 / 656,711 frames per second using monotonic
deadlines, one `lf_advance` call at a time. Expired deadlines are skipped
rather than replayed in a catch-up burst; macOS scheduling does not guarantee
real-time delivery. Each positive call still receives host-owned capacity for
up to 801 PCM samples. Phase 7 discards those samples and opens no audio
device; Phase 8 schedules generated audio through the native output path.

## Audio

The host schedules generated native-endian signed-16 mono PCM at 48 kHz through
preallocated `AVAudioPlayerNode` buffers. The generated diagnostic is the only
audio source used by the required smoke. The host does not log or persist PCM
or caller content; its fixed pool holds audio blocks only for playback. Pool
exhaustion drops a whole newest packet and records the count. Pool size, startup
prime delay, and observed drop count are measurements rather than latency or
quality targets.

The window has a Mute/Unmute button beside Open and a concise `Audio: On` or
`Audio: Muted` footer status. The button is available before content opens, and
its accessible action name, current value, help, and the footer text follow the
same state. Muting changes only the engine mixer's output gain: guest advances,
PCM generation, buffer scheduling, and retirement continue. The choice belongs
to the current window/process and carries into newly opened or replacement
content; a fresh process starts with audio on.

The relocated smoke succeeds only after a `.dataPlayedBack` completion, a
nonzero active system output-node format, and separate checks that
`AVAudioPlayerNode.isPlaying` and `AVAudioEngine.isRunning` are both false after
stop. This establishes that AVFAudio reported playback through the configured
system output path for that run. It does not establish audible speaker output,
loopback capture, or that anyone listened to the generated sound. Offline
manual rendering verifies sample format, ordering, and completion accounting;
it is device-independent and does not qualify live output by itself.

Audio is generated diagnostic output, not a sandbox boundary. Shutdown closes
audio schedule admission and waits for any submission already admitted to
finish before the session owner drains, stops the player and engine, then waits
for completion handlers before releasing their state. A trusted in-process
`lf_advance` that hangs can still delay close without a bounded shutdown
promise.

## Evidence and limits

`./scripts/check.sh` is the canonical build and verification command. Its
required installed-host route configures, builds, and runs the host from a
moved installed prefix while the original source, build, and staging paths are
unavailable. It runs the host CTests and native app launch through `open`,
checks the actual presented diagnostic pixels, key/focus handling,
content/retry behavior, cadence and shutdown, and preserves sanitized
identity-bound evidence under `build/check/relocation-reports/`.

This local route uses trusted in-process core libraries. It is not a sandbox
or crash boundary. The evidence is limited to macOS arm64, the selected
profile, and the generated diagnostic. A separate local title try is optional
and does not establish title compatibility, hardware accuracy, another
platform, browser support, hosted CI, release qualification, or bounded
shutdown for a hung core.
