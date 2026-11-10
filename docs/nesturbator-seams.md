# nesturbator source and adapter seams

## Exact source and rights

The adapter links the public `szTheory/nesturbator` source commit
`2338608ab184f040620a30d17756f5e06a42d4e3` from
`https://github.com/szTheory/nesturbator.git`. CMake fetches it under the local
build tree, rejects `FETCHCONTENT_SOURCE_DIR_NESTURBATOR`, and checks the
acquired Git origin, full `HEAD`, and clean source state before configuration.
The embedded project provides the static target `nesturbator::nesturbator`;
its runner, libretro core, tools, tests, and release packaging are not added.

The pinned source is MIT licensed, copyright 2026 nesturbator contributors.
No upstream implementation or fixture is copied into libfuturo. Keep the
upstream license and copyright notice with any later source or binary
redistribution that includes this statically linked library.

## Compatibility is not one promise

| Surface | Current evidence and limit |
|---|---|
| libfuturo source API | Experimental. Names, declarations, and behavior may change; this plan makes no stability promise. |
| Binary ABI | No stable plugin ABI or cross-build binary compatibility is promised. This integration links a source-built static library into the host process. |
| nesturbator behavior | The public header reports behavior revision 9, separately from ABI version 1 and library version 0.1.12. The full source pin identifies the tested code, not interchangeable behavior across revisions. |
| Persistent media | The source core exposes a mutable battery-backed memory span. The selected profile supports host-owned copy/import for a loaded cartridge; the generated MMC1 fixture and local consumer prove this one pinned profile's ordinary save/restart path. This is not a cross-core or cross-version save format. |
| Snapshots | The public adapter reports snapshot support as unavailable. The source header's state format version 3 is not an interchangeability promise. Restore remains optional future work. |

The complete selected profile, public ownership rules, limits, and status
postconditions are in [nesturbator-profile.md](nesturbator-profile.md).

## Source facts and adapter mapping

The left column records source/header contracts for the exact pin. The right
column describes the libfuturo boundary; measured behavior is listed separately
below.

| Seam | Pinned source fact | Adapter boundary |
|---|---|---|
| Load | The core accepts a bounded set of iNES v1/NES 2 profiles, rejects malformed or unsupported cartridges with `NESTURBATOR_ERR_CARTRIDGE`, and leaves the active cartridge unchanged on every refusal. Its 64 MiB maximum is checked before cartridge allocation. | The adapter checks request/configuration and content-size limits before the core call. It maps core-refused content to `LF_INVALID_ARGUMENT`, unavailable configuration to `LF_UNSUPPORTED`, oversize content to `LF_LIMIT_EXCEEDED`, and allocator refusal to `LF_RESOURCE_EXHAUSTED`. Metadata and pending input reset only after a successful load. |
| Allocator | The public allocator is used at instance creation and cartridge load, not during frame execution. Load allocates/copies a candidate before replacing the existing cartridge. | The host's paired allocator hooks see adapter scratch plus forwarded core allocations. The consumer injects failure at the observed successful-load allocation position and compares later frame output against a same-history control. |
| Input | Two NES button masks are sampled when `nesturbator_run_frame` starts. | The adapter stores pending 16-bit port masks and applies them before the next positive frame call. No sub-frame input update is promised. |
| Guest time | Work is frame-oriented. Reported half-master-clock ticks and frame number are cumulative; instruction completion can overshoot the nominal frame target. | `actual_units` and `cumulative_units` count completed frames. `cumulative_core_ticks` remains a separate cumulative source measurement, never per-call work or a wall-time deadline. |
| Video | The caller supplies `uint16_t` pixels for 256×240 output and a pitch in pixels. The core API has no allocation-capacity argument. | The adapter owns bounded native scratch, converts through the pinned public palette into RGB24 R/G/B bytes, checks host stride/extent, and publishes only a complete frame. |
| Audio | Caller-owned mono signed-16 PCM at 48,000/1 Hz; completed frames produce 798 or 799 samples. | The adapter reserves 799 native samples, requires that conservative capacity before positive work, and copies only the produced sample count. |
| JAM | `NESTURBATOR_STOP_JAM` is latched. Frame output fields are not written; the core may have advanced internally before stopping. | The adapter returns `LF_OK` with `LF_STOP_CORE_HALTED`, no newly completed frame, invalid current A/V and tick validity, and untouched host buffers. It retains only the last valid cumulative tick value as history. Successful load clears the latch; failed load does not. |
| Battery memory | `nesturbator_get_memory` returns the mutable `NESTURBATOR_MEMORY_SAVE_RAM` span. Its pointer is valid until unload, a later successful load, or destroy. The source reports a guest-write generation; host import does not increment it. The core does no file I/O. | The profile's static `media_extent_bytes` is zero because extent depends on loaded content. After load, `lf_media_info.extent_bytes` reports the exact exposed span. The generated MMC1 fixture returns 8 KiB. `lf_copy_media` makes a caller-owned copy and captures the generation; `lf_import_media` accepts the matching media identity and exact loaded extent after load and before positive guest execution. Calls on an instance are serialized. The host owns content/configuration association, envelope serialization, files, and acknowledgments. |

## Generated fixture provenance and identity

`tests/nesturbator_session.c` contains an original project-authored generator
and a fixed 6502 program. It creates a zero-filled iNES v1 header with one
16 KiB PRG bank and one 8 KiB CHR bank, copies the fixed program into PRG ROM,
and writes the reset/interrupt vectors as `$8000`. The generated NROM is
24,592 bytes. The C generator is original test content under this repository's
Apache-2.0 license. No upstream helper, commercial ROM, BIOS, or protected
content is copied or tracked.

The frame-failure mode derives a second in-memory image from that generator.
It inserts a port-0 B serial-bit check and a `$02` JAM opcode. The normal frame
path remains available with B released; pressing B reaches JAM after an
already completed frame. Both variants are generated in memory during normal
tests, so no raw cartridge bytes are tracked.

The consumer implements an explicit file-emission mode for the reproducible
SHA-256 recipe:

```sh
build/check/nesturbator_session --emit-fixture build/check/nesturbator-nrom.bin
shasum -a 256 build/check/nesturbator-nrom.bin
```

The observed SHA-256 is
`e74fae7b6d5d8438e7f0c36f3b86f52eab426166b521bb923a8d93bf6d628235` for the
24,592-byte output. Two emitted files compared byte-for-byte and produced the
same hash. This explicit command requests a build-output file; it is not the
default consumer path. It checks open, write, and close failures, and normal
CTest runs generate bytes in memory without writing ROM files.

## Measured save-span identity

The save consumer uses the project-owned MMC1 battery fixture described in
[nesturbator-save-fixture.md](nesturbator-save-fixture.md). It is generated at
40,976 bytes and is checked against the independent SHA-256 literal
`2282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9` before
load. The host envelope records that content identity, effective configuration
identity `nesturbator-default`, and media identity `nesturbator-save-ram-v1`
separately. The observed loaded writable span is exactly 8,192 bytes; the
profile's zero static extent means "loaded extent determines size," not
"unsupported."

## Bounded save and restart evidence

The required `nesturbator_save_restart` CTest runs the same consumer in ordered
processes through the CMake driver. The first writer advances the generated
guest to literal byte `0x03` at guest generation 3, copies the bytes and
generation together, writes a bounded fixed-endian envelope to a unique
same-directory temporary file, and treats successful rename as the commit
point. It acknowledges only after rename and verifies that a second commit of
the same snapshot produces byte-identical file data and the same captured
guest generation. The host does not assign a durable revision.

A separate update process reads and imports that committed payload before
guest execution, advances its new instance to byte `0x04` (its source-local
generation is 1), then injects a prefix-write failure before rename. It emits
no new acknowledgment, removes the stage, and confirms the prior file bytes
and prior acknowledgment still match exactly. A final fresh process imports
the prior commit and independently verifies continuation to byte `0x04`.
Guest generations are scoped to their source instance and are not compared
across process restarts.

`./scripts/check.sh` requires the CTest plus exact fixture-digest,
writer/failure/restorer, and old-commit recovery result markers. The earlier
local macOS arm64 route passed fourteen required CTests and a separate
relocated installed-consumer save/restart journey. That historical evidence covers an ordinary local
process exit/relaunch and a controlled pre-rename write failure only. It makes
no hosted CI, upstream workflow, hardware, OS-crash, power-loss, post-rename,
corruption, multi-writer, or cross-core recovery claim.

## Earlier measured local consumer evidence

`./scripts/check.sh` is the canonical local command and the command reached by
the existing project workflow. It builds only the pinned static library and
libfuturo-owned targets; it does not run Nesturbator's upstream tests or
campaigns. The required CTests include the generated happy-path session,
`nesturbator_save_restart`, `nesturbator_load_failures`,
`nesturbator_frame_failures`, and `nesturbator_oracle_negative_control`,
alongside the existing synthetic and source-identity checks. The calibration
runs the ordinary literal comparison
successfully, then changes one expected red byte and requires the exact
row/pixel/channel mismatch with exit status 1.

The regular real consumer loaded the generated NROM, supplied input, advanced
eight frames, compared literal RGB24 and silent PCM, and reported 5,718,168
source-reported half-master-clock ticks with 799 samples in its last frame.
The load-failure mode checks malformed/truncated and unsupported-board content,
invalid records and pointers, empty and extent-boundary content, unsupported
configuration, caller storage, active metadata, and one injected forwarded
load allocation failure against matched histories. The valid generated NROM
load uses one caller-allocator allocation in the observed pin.

The frame-failure mode checks no-load and zero-work effects, record/input
rejections, one-frame work limits, short/exact/over video capacities, minimum
and padded stride, both `SIZE_MAX` extent-overflow paths, audio capacities
0/798/799/800, untouched padding/tails, and same-history continuation. Its
generated JAM case verifies withheld partial outputs/ticks, repeated halted
calls, preservation across refused load, and recovery after successful load.

The measured environment for that route was local macOS 26.6.2 arm64, Apple
Clang 21.0.0 (clang-2100.1.1.101), CMake/CTest 4.4.3, and macOS SDK 26.5. That
route also checked the relocated installed consumer described in
[development.md](development.md), including fresh-process save restoration and
controlled pre-rename recovery. These results do not qualify another target,
hardware accuracy, hosted CI, or OS-crash/power-loss durability.

## Current bounded load and installed evidence

The current gap-closure route is `./scripts/check.sh`. In a passing local run
it requires 20/20 CTests and 22/22 required rows: those CTests plus distinct
installed save/restart and installed load/refusal proofs. One separate CTest
loads iNES v1 mapper 1 with zero CHR-ROM banks, then checks three continuation
frames against the save-media oracle; it is not counted in the 307-case matrix.
The load corpus uses an exact-size allocation for each submitted matrix span
and verifies that ASan marks the first byte after that span inaccessible. It
executes 307/307 matrix cases; the allocation test observes complete failure
ordinal coverage for 21 valid layout classes in unloaded and loaded histories.
The positives and two calibrated oracle controls remain separate rows, so a
passing corpus count cannot substitute for preservation, success, or comparator
evidence. The installed consumer proves seven selected refusals and P03
replacement through moved public artifacts, with immediate full 8192-byte
media comparison before three matched continuation frames.

The selected dependency is `https://github.com/szTheory/nesturbator.git` at
`2338608ab184f040620a30d17756f5e06a42d4e3`. The local profile is macOS 26.6.2
arm64, Apple Clang 21.0.0.21000101, CMake/CTest 4.4.3, SDK 26.5, Debug. The
current instrumentation evidence has 22 actual flag records: 19 exact-pin
core units (including `cartridge.c` and the CPU object), two libfuturo
implementation units, and the load-corpus consumer, each compiled with
AddressSanitizer, UBSan, and frame pointers. The normal installed archives and
downstream consumer link have no sanitizer-runtime requirement; the separate
instrumented core is test-only. This is exact-pin local compiler evidence, not
memory-safety certification or qualification of other targets.

The run identity records configure/build/CTest time, corpus/allocation/control/
instrumentation CTest duration, relocation duration, and installed load-child
duration in seconds, together with source/core, corpus, instrumentation and
installed-artifact digests. The final 02-08 summary identifies the selected
successful run and its actual values. The current Phase 02 verifier satisfies
CORE-03 for the accepted finite exact-pin source partition and load-preservation
scope, and REAL-01 for the selected local profile. The matrix and allocation
layouts do not establish exhaustive parser safety. The project also makes no
claim of hidden-state equality, arbitrary cartridge gameplay or accuracy,
near-lifetime maximum behavior, partial-JAM timing, concurrent operation,
cancellation, hardware/browser/other-target support, hosted CI, durability
beyond the controlled local route, or crash containment. Calls on one instance
remain serialized synchronous operations. See the current Phase 02 verification
record for the exact scope.

## Historical bounded lifecycle probe

Plan 02-01's original bounded probe remains a useful history record: it checks
the compiled source revision, creates an instance with the zeroed public
configuration, destroys it, and prints the lifecycle marker. By itself, that
probe does not load content or exercise a frame. The later public session and
failure modes above extend its scope; the historical create/destroy result is
not presented as the current acceptance boundary.

The existing single approved hosted macOS run allowance is spent. No hosted
dispatch or retry, hardware run, sibling-repository edit, or upstream
operational run is authorized by these local checks.
