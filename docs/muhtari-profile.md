# Real Muhtari profiles: API 7 `muhtari-ntsc-v1` and API 8 `muhtari-ntsc-v2`

The API 7 section describes libfuturo's experimental adapter around Muhtari
source commit `d5fd241e3f4d701d73867cc2e465c56a6fe6793d`; the API 8 section
documents its separate exact-pin exception. Both static cores are linked into
the host process. A native core failure can affect its host; neither profile
makes a crash-containment claim.

Shared lifecycle, ownership, load, input, time, limits and error obligations
are defined by the [native contract](contract.md):
[LC-LIFE-01](contract.md#lc-life-01), [LC-OWN-01](contract.md#lc-own-01),
[LC-LOAD-01](contract.md#lc-load-01), [LC-INPUT-01](contract.md#lc-input-01),
[LC-TIME-01](contract.md#lc-time-01), [LC-LIMIT-01](contract.md#lc-limit-01),
and [LC-ERROR-01](contract.md#lc-error-01). This file is authoritative for
Muhtari-specific values and behavior.

## Identity and effective configuration

| Field | Value |
|---|---|
| Profile / core | `muhtari-ntsc-v1` / `muhtari` |
| Source origin / commit | `https://github.com/szTheory/muhtari.git` / `d5fd241e3f4d701d73867cc2e465c56a6fe6793d` |
| API / behavior revision | `7` / `6` |
| Effective configurations | Default: `muhtari-ntsc-joystick-default`; diagnostic: `muhtari-ntsc-battery-diagnostic` |
| Default region, firmware, devices | NTSC, no BIOS, one-button joystick on each port |
| Maximum content extent | 1,048,704 bytes |

The adapter requires the exact Muhtari API and a nonzero reported behavior
revision, and checks the fixed NTSC dimensions, cadence and sound format at
creation and before load. It does not add mutable emulator options. A NULL
configuration ID selects `muhtari-ntsc-joystick-default`; that identifier is
also accepted explicitly. The battery-diagnostic selector is also accepted;
other well-formed IDs return `LF_UNSUPPORTED`. Profile and capability queries
use the same selector as load so their metadata describes the effective
configuration.

| Selector | Input mask | Device topology | In-memory media copy/import |
|---|---:|---|---|
| `NULL` or `muhtari-ntsc-joystick-default` | `0xF1F1` | NTSC, no BIOS, joystick on both ports, HSC off, expansion off | Unsupported; `media_extent_bytes=0` |
| `muhtari-ntsc-battery-diagnostic` | `0xF1` | NTSC, no BIOS, joystick on Muhtari port 1 (libfuturo input port 0), HSC plus SaveKey on Muhtari port 2 | Supported; exact loaded extent is 34,816 bytes |

The battery diagnostic is additive: the Phase 5 default selector, two-port
joystick behavior, and unsupported media capability remain unchanged.

Muhtari is an optional SDK dependency. The base configuration leaves it off.
An enabled installation includes a colocated `muhtari::muhtari` static target,
public header, MIT license and third-party notices. Its package identity is
validated from the declared source origin, exact revision and clean fetched
tree before configuration.

## Content loading and replacement

The caller supplies a nonempty in-memory A78 image. The adapter enforces the
1,048,704-byte limit before parsing. The default selector uses NTSC, both
joystick ports, HSC off and expansion off; the battery-diagnostic selector
uses the diagnostic topology in the table above. Muhtari validates the image
and copies accepted content during the load call; the caller may then release
or change its bytes.

| Result | Active session and result postcondition |
|---|---|
| `LF_OK` | `loaded=1`; content extent and effective configuration identify the new session. Pending input, completed-frame count and halt state reset after native success. |
| `LF_INVALID_ARGUMENT` | Invalid records, pointers, empty or refused images are reported. The result describes the prior active session when available. |
| `LF_UNSUPPORTED` | An unavailable configuration or unsupported board/region/device is refused without replacing the active session. |
| `LF_LIMIT_EXCEEDED` | Content above 1,048,704 bytes is rejected before the parser reads it. |
| `LF_RESOURCE_EXHAUSTED` | A native allocation refusal is reported without leaving a partial adapter instance. |

The adapter checks the native profile information before the load call. A
successful load is committed only after Muhtari returns success; no later
metadata check can report refusal after the native core has replaced its
session. The installed public consumer checks eight refused-load cases across
loaded and unloaded histories, then compares three continuation intervals
against independent expectations. These cases include invalid request records,
missing or empty content, an unavailable configuration, content above the
profile limit, a truncated image, and a well-formed unsupported cartridge.
Allocation-refusal ordinals are measured and checked separately. Failed loads
preserve the prior session and caller bytes; successful default or explicit
replacement resets pending input and frame progress.

## Ownership and call preconditions

The host owns and serializes each `lf_instance`, including destruction.
Content and input records are borrowed for their calls. Muhtari copies a
successful image. The adapter owns fixed native video/audio scratch buffers
and copies output to host buffers only after a successful frame. It retains no
host output pointer. The host must supply valid, suitably aligned spans whose
declared extents remain readable or writable for the call.

The allocator and its context remain usable until destruction. Callback
reentry, cancellation and concurrent use are not provided. An in-process
native API is not a sandbox.

## Input, frames, video and audio

| Field | Selected profile behavior |
|---|---|
| Input mask (default configuration) | `0xF1F1`: port 0 bit 0 Button 1, bits 4–7 Up/Down/Left/Right; port 1 uses the same controls at bits 8 and 12–15. |
| Input mask (battery diagnostic configuration) | `0xF1`: port 0 bit 0 Button 1 and bits 4–7 Up/Down/Left/Right; no port 1 input bits are supported. |
| Input sample point | The first packet is applied before fast boot's first opcode. Later packets are sampled at the start of the next positive advance, at VBLANK. `lf_set_input` alone does no guest work. |
| Work unit | One completed profile frame-advance interval; maximum one unit per call, one-unit atomic quantum, zero reported overshoot. |
| Cadence | Steady state is `39375000/656711` frames per second. This rational cadence does not make the first partial interval a full-length frame. |
| Session limit | At most `UINT32_MAX` completed intervals per loaded session. |
| Core ticks | Muhtari exposes no source tick getter through this adapter. `core_ticks_valid=0` and the tick count and tick unit remain zero. No tick count is synthesized from frame timing. |
| Video | `320 × 242`, one byte per pixel, `LF_VIDEO_INDEX8`. Raw MARIA color-number bytes are copied unchanged; no palette or RGB conversion is applied. |
| Video extent | Required checked extent is `(height - 1) * stride + width`. Only active pixels are written; row padding and trailing bytes remain unchanged. |
| Audio | Native-endian signed 16-bit mono interleaved PCM at `48000/1` Hz; maximum 801 samples per positive call. |
| Audio capacity | Every positive call requires room for 801 samples, including startup. Only produced samples are copied; the caller tail stays unchanged. |

The first successful interval after load is a partial startup interval of
8,190 guest ticks and 54 samples. Later steady intervals cover 119,402 ticks
and produce 800 or 801 samples. These source timing figures explain expected
observations; they are not exposed as source tick measurements. The first
image is partial: rows not scanned since load are zero-filled. The independent
fixture and oracle are described in the
[Muhtari diagnostic record](muhtari-session-fixture.md).

The same consumer checks rejected input bits, malformed requests, zero work,
work above the one-frame limit, minimum stride and checked-extent boundaries,
stride overflow, and audio capacities immediately below, at, and above the
801-sample bound. Rejected calls preserve pending input, progress, and output
canaries; valid boundary calls retain the exact raw indexed image and PCM
expectations.

For audio sample counts, Muhtari's fixed accumulator advances by 88 for every
master tick and wraps at 13,125. From a zero startup remainder, the first
8,190-tick interval yields `floor(8190 × 88 / 13125) = 54`. Later counts are
successive differences of `floor((8190+n×119402)×88/13125)`, giving the
independently calculated 15-call vector
`54, 801, 801, 800, 801, 800, 801, 800, 801, 800, 801, 801, 800, 801, 800`.
The installed consumer checks all ten supported controls, released and mixed
inputs, repeated held input, a later change, every raw index image, and the
complete PCM digest for each interval. Expected pixels and PCM values are
derived from the owned diagnostic and published timing/audio arithmetic
before comparing the runtime output; the detailed sequence and hashes are in
the [fixture record](muhtari-session-fixture.md).

## Persistent media and save identity

Only `muhtari-ntsc-battery-diagnostic` advertises
`LF_CAP_IN_MEMORY_MEDIA_COPY`. Once that configuration has loaded the pinned
HSC-plus-SaveKey diagnostic, the media identity is `muhtari-battery-v1` and
the exact aggregate extent is 34,816 bytes: 2,048 HSC bytes followed by 32,768
SaveKey EEPROM bytes. The extent is load-dependent; consumers MUST check the
returned `lf_media_info.identity` and `extent_bytes` rather than infer them
from the profile alone.

`lf_copy_media` copies into stable caller-owned bytes. The adapter never
exposes or retains the native Muhtari media pointer. The host save envelope
keeps loaded-content digest, effective configuration, media identity, exact
extent, and guest generation as distinct fields. Consumers MUST validate the
bounded envelope and all identities before import. `lf_import_media` is valid
only after successful load and before the first positive guest advance; a
rejected envelope leaves active media unchanged. Guest generation is a core
change token, not a host revision or durable acknowledgment. File staging,
rename, readback, recovery, and durable acknowledgment remain host-owned.

## Capabilities, errors and evidence boundary

| Capability | Result |
|---|---|
| Logical input, bounded execution, software video and audio | Supported. |
| In-memory media copy/import with the default selector | `LF_UNSUPPORTED`. |
| In-memory media copy/import with the battery-diagnostic selector | Supported for the exact loaded span described above. |
| API 7 `muhtari-ntsc-v1` snapshots, hardware video and concurrent use | `LF_UNSUPPORTED`. API 8 snapshot support is scoped to the separate profile below. |

Malformed inputs return `LF_INVALID_ARGUMENT`; a known unavailable
configuration or capability returns `LF_UNSUPPORTED`; content/work/extents
over the selected bounds return `LF_LIMIT_EXCEEDED`; insufficient output
capacity returns `LF_BUFFER_TOO_SMALL`; allocation refusal returns
`LF_RESOURCE_EXHAUSTED`. Preflight rejects do not submit pending input or
advance the guest. The accepted in-process core remains trusted and can affect
its host if it fails.

## API 8 `muhtari-ntsc-v2` snapshot qualification

This is a separately selected profile for Muhtari v0.11.1 at source commit
`d58f125297c4d63a7a8108112a5eafff6f53a76a`. It reports API revision 8, ABI
revision 1, behavior revision 6, and native state format 1. The sole qualified
effective configuration is `muhtari-ntsc-battery-diagnostic`, with effective
options `none`. The supported content is limited to the generated fixture in
the [snapshot fixture record](muhtari-snapshot-fixture.md): 16,512 A78 bytes
with SHA-256
`136cbead3da4bde24ea23acf36eb8daacced88074bbe021888aa4e17d987195e`, and a
load-reported `muhtari-battery-v1` extent of 34,816 bytes (2,048 HSC bytes
followed by 32,768 SaveKey bytes). Snapshot capability, size, capture, and
restore are unsupported for the API 7 profile, the API 8 default selector,
and other content/configurations that have not been qualified.

API 7 remains the existing/default API selection when Muhtari is enabled; the
base package still has Muhtari disabled by default. API 8 is explicitly
selected with the CMake option `LIBFUTURO_MUHTARI_API_REVISION=8` and is built
in a separate build tree and install prefix. It retains the conventional
logical targets `libfuturo::libfuturo` and `muhtari::muhtari`. The exported
package reports the selected API revision and source pin through
`libfuturo_MUHTARI_API_REVISION`, `libfuturo_MUHTARI_SOURCE_REVISION`,
`muhtari_API_REVISION`, and `muhtari_SOURCE_REVISION`; a consumer must check
those values and resolved archive/config paths instead of treating the target
names as package identity. A package smoke test against the original prefix
does not replace the separate qualification that moves the installed prefix
and builds/runs the downstream consumer with source and build fallback
unavailable.

The snapshot capability query uses profile `muhtari-ntsc-v2` and the explicit
diagnostic configuration. It reports profile/configuration availability and
does not inspect loaded content. Size discovery, capture, and restore also
require the exact generated fixture and do not advance guest work. Capture
returns
caller-owned opaque bytes. Restore preflights the exact LibFuturo and Muhtari
builds, API/ABI/behavior/state-format tuple, profile, configuration, options,
content digest, and declared extents before native loading. The native state
format and envelope are experimental and exact-build scoped; they do not
promise stable API/ABI or cross-build portability. Version 2 includes a
SHA-256 digest over the metadata header with its digest field zeroed, covering
instance identity and successful-load epoch. SHA-256 and native CRC validate
byte identity/corruption, not authenticity.

The source and moved-installed public routes both capture R2 after frame 2
while the SaveKey write to EEPROM address `0x0003` (aggregate offset 2051) is
pending. Process A later commits host-selected save R3 and closes the
checkpoint before orderly exit. Fresh Process B imports R3 before positive
guest work, restores R2, then replays frame 3 where the pending write publishes
`0x5A`. B compares media generation only with its own pre-restore value;
restoring different bytes advances that value once, while an identical-byte
restore leaves it unchanged. The producer's generation is not transplanted.
The exact R2/R3 video, audio, and full-span battery oracles are listed in the
fixture record and checked independently on both routes.

The host owns checkpoint and save file paths, writes, staging, commit
decisions, reopen/readback, and durable acknowledgments. Restore and the
controlled pre-rename failure preserve selected R3 and its acknowledgment;
only an explicit host commit followed by exact readback may acknowledge the
restored payload. Qualification covers successful checkpoint close, orderly
process exit, and fresh-process reopen only. It does not cover crash,
abrupt-exit, `fsync`, power-loss, or uncertain post-rename recovery. The
selected core is trusted in-process code without sandboxing or crash
isolation. Evidence applies only to these exact local macOS arm64 routes and
does not qualify other profiles, targets, cores, hardware, browser runtimes,
or releases.

## Browser execution qualification

The separate [browser-host guide](browser-host.md) qualifies Muhtari v0.11.1 at
source `d58f125297c4d63a7a8108112a5eafff6f53a76a`, API 8 / ABI 1 / behavior 6,
profile `muhtari-ntsc-v2`, and the explicit
`muhtari-ntsc-battery-diagnostic` configuration through the relocated
`libfuturo::web` consumer and one pinned Chrome for Testing Headless Shell
route. It uses the generated 16,512-byte fixture recorded above and a separate
seven-scenario browser-host inventory.

This browser evidence is session-only: the battery remains in the live browser
session, and the route exercises no browser save or snapshot API. Its audio
checks observe the Web Audio graph rather than physical speaker output, and
BFCache restoration is not qualified. The browser row does not expand the
native snapshot contract above or promise other browsers, mobile or hardware
support, broad Wasm support, a stable ABI, or a software release.

## Building and consuming the optional package

The Muhtari profile is excluded from a normal default-off build. To build and
run the opted-in public example from this checkout:

```sh
cmake -S . -B build/muhtari -DCMAKE_BUILD_TYPE=Debug \
  -DLIBFUTURO_ENABLE_MUHTARI=ON
cmake --build build/muhtari --target libfuturo muhtari_host muhtari_session
ctest --test-dir build/muhtari --output-on-failure \
  -R '^muhtari_example$' --no-tests=error
```

`muhtari_host` accepts a host-owned A78 file path. The checked smoke test uses
the project-authored `muhtari_session --emit-fixture` mode, verifies its exact
byte count, SHA-256 and license provenance, and then runs the public example.
No commercial image or upstream runner is needed for that route.

An ordinary installed consumer can use the SDK without Muhtari:

```sh
cmake -S . -B build/base -DCMAKE_BUILD_TYPE=Debug
cmake --build build/base --target libfuturo
cmake --install build/base --prefix build/base-prefix
cmake -S tests/installed-consumer -B build/base-consumer \
  -DEXPECTED_INSTALL_PREFIX="$PWD/build/base-prefix" \
  -DEXPECTED_MUHTARI_ENABLED=OFF \
  -DLIBFUTURO_CONSUMER_PACKAGE_ONLY=ON
cmake --build build/base-consumer --target muhtari_disabled_consumer
ctest --test-dir build/base-consumer --output-on-failure \
  -R '^muhtari_disabled_consumer$' --no-tests=error
```

The installed consumer asserts that Muhtari has no imported target, header,
archive, package configuration or link requirement and that the base profile
still works. Canonical local evidence is recorded by `./scripts/check.sh` and
its relocation report; those results qualify the exact pinned Muhtari source,
owned fixture, installed artifacts and recorded local macOS arm64 toolchain.
They do not qualify another source revision, compiler, platform, hosted CI,
hardware, or browser execution. The four-process battery save/recovery journey
from the Phase 6 fixture passed on this local profile. This does not qualify
other joystick behavior, platform coverage, or the other environments listed
above. The core remains linked in-process, and software release `0.1.0` remains
unpublished.

The native qualification above is limited to the exact local build and moved
installation exercised by its recorded public consumer. It does not qualify
other source revisions, compilers, platforms, hosted CI or hardware behavior.
Browser evidence has the separate exact scope stated in the [browser-host
guide](browser-host.md).
