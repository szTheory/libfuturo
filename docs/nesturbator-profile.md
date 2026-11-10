# Real profile: `nesturbator-ntsc-v1`

This document describes libfuturo's experimental adapter around the exact
public Nesturbator source commit `2338608ab184f040620a30d17756f5e06a42d4e3`.
The selected library is linked into the host process. Error results do not
contain a faulty native core, and this integration makes no crash-isolation
claim.

Shared obligations are defined in the [native contract](contract.md):
[LC-LIFE-01](contract.md#lc-life-01), [LC-OWN-01](contract.md#lc-own-01),
[LC-LOAD-01](contract.md#lc-load-01), [LC-INPUT-01](contract.md#lc-input-01),
[LC-TIME-01](contract.md#lc-time-01), [LC-LIMIT-01](contract.md#lc-limit-01),
[LC-ERROR-01](contract.md#lc-error-01), and
[LC-HOST-01](contract.md#lc-host-01). This file remains authoritative for
Nesturbator-specific values and profile behavior.

## Identity and effective configuration

| Field | Value |
|---|---|
| Profile / core | `nesturbator-ntsc-v1` / `nesturbator` |
| Nesturbator release | `v0.1.12` |
| Nesturbator source | `2338608ab184f040620a30d17756f5e06a42d4e3` |
| API / behavior revision | `1` / `9` |
| Effective configuration | `nesturbator-default` |
| Maximum content extent | 67,108,864 bytes (64 MiB) |

The pinned core exposes no machine-option fields. A NULL configuration ID
selects `nesturbator-default`; that exact ID is also accepted explicitly.
Other well-formed configuration IDs return `LF_UNSUPPORTED` before the core
loader is called. The adapter does not invent configuration controls the core
does not expose.

## Content loading and replacement

This profile supplies the exact state transition and status details for
[LC-LOAD-01](contract.md#lc-load-01) and
[LC-ERROR-01](contract.md#lc-error-01).

The caller supplies an in-memory content span and a complete
`lf_load_request`. The pointer must refer to at least `content_size_bytes`
readable bytes for the whole call. A non-NULL configuration string must be
readable and NUL-terminated for the whole call. The adapter enforces the
64 MiB profile limit before calling the parser. Zero-byte content, missing
required pointers, and malformed extensible records are invalid requests.

Nesturbator is the cartridge validator. The adapter does not duplicate its
iNES/NES 2 parser or classify mapper details independently. The pinned core
refuses malformed, truncated, extra-payload, unsupported-board, or
out-of-profile cartridges with `NESTURBATOR_ERR_CARTRIDGE`; libfuturo reports
that refused-content category as `LF_INVALID_ARGUMENT`. Exact-limit content
passes the adapter's extent gate, then remains subject to core validation.

| Result | Active session and result postcondition |
|---|---|
| `LF_OK` | The core has copied the accepted content. `loaded=1`, content extent and effective configuration describe the new cartridge. The adapter resets pending input, frame/tick history, and a prior halted state only after the core reports successful load. |
| `LF_INVALID_ARGUMENT` | Invalid records, required pointers, empty content, or core-refused content are reported. A valid result record still describes the prior active session; if no content was active, it reports `loaded=0`, zero extent and NULL configuration. |
| `LF_UNSUPPORTED` | A well-formed request names an unavailable configuration. The prior loaded state and metadata remain active. |
| `LF_LIMIT_EXCEEDED` | Content above 64 MiB is rejected before parser reads or core allocation. The prior session remains active. |
| `LF_RESOURCE_EXHAUSTED` | A forwarded allocator refusal during candidate cartridge allocation is returned. The pinned loader allocates and copies the candidate before replacing the active cartridge; the prior session remains active. |

For load failures, the consumer test checks the active metadata, caller content
bytes, pending input and next frame against an untouched instance with the same
successful input/frame history. The current bounded route executes all 307
literal cases in [`nesturbator_load_cases.h`](../tests/nesturbator_load_cases.h):
records/configuration and header admission (A/H), NES 2 size encodings (S),
supported and neighboring refused boards (B), RAM/battery interpretations
(R/I), exact payload and trainer extents (E), and cross-field interactions
(X). The canonical log reports `executed=307/expected=307`, with each actual
status equal to that case's independent literal expectation. Refusal histories
compare unloaded and loaded battery-backed instances; classification-only
accepted descriptors are destroyed without guest execution. This is finite
evidence for the listed partitions, not a claim that the count alone classifies
all parser behavior.

Allocation injection covers 21 valid generated layout classes and every
observed candidate-allocation ordinal in each class. The current marker reports
complete ordinal coverage for unloaded and loaded histories and balanced
ownership. Separate executable positives retain default/explicit-default,
replacement/reset, and the known trainer guest. Wrong-status and subject-only
divergence controls pass only when the ordinary comparator emits their intended
diagnostics. The focused relocated public consumer separately checks seven
selected refusals and P03 replacement: all 8192 media bytes and metadata are
compared immediately before continuation, followed by three complete matched
frames. These observations establish selected transaction cases for this pin;
they do not classify every possible parser input or imply that arbitrary
native pointers can be validated. Current run references and exact digests are
recorded under `build/check/verification-identity.txt`, `ctest-output.log`,
`required-results.tsv`, `instrumentation-scope.txt`, and the relocation report.

## Ownership and native call preconditions

These profile-specific lifetimes and call rules implement
[LC-LIFE-01](contract.md#lc-life-01) and
[LC-OWN-01](contract.md#lc-own-01).

| Object | Owner and lifetime |
|---|---|
| `lf_instance` | The host owns the opaque handle returned by `lf_create` and must serialize operations, including destroy. |
| Content bytes | The host owns its input bytes. Nesturbator copies accepted cartridge data during load; it does not retain the caller's span. |
| Configuration ID | Borrowed from the host only for the load call; NULL selects the effective default. |
| Custom allocator and context | Both callbacks must be provided together, return malloc-aligned storage, and remain usable until instance destruction. The context is borrowed. |
| Load result configuration string | Immutable adapter-owned storage, valid while the linked library remains live. |
| `lf_media_info.identity` | Immutable library-owned string, valid until its instance is destroyed or the linked library code is unloaded, whichever happens first. Copy it to retain it longer. |

As with any C API, a non-NULL pointer must be valid, suitably aligned, and
readable or writable for the declared span. `struct_size` is checked before
extension fields are inspected. These are caller preconditions; the native
adapter is not a memory-safety boundary. For `lf_copy_media`, the full
declared destination capacity span must be disjoint from its `lf_media_info`
output record and instance storage. Overlap is invalid caller use; runtime
detection is not promised.

## Input, frames, video, and audio

This profile supplies the exact input and guest-time rules for
[LC-INPUT-01](contract.md#lc-input-01),
[LC-TIME-01](contract.md#lc-time-01), and
[LC-LIMIT-01](contract.md#lc-limit-01).

| Field | Selected profile behavior |
|---|---|
| Work unit | One complete NES frame; `max_work_units=1`, with one frame as the atomic unit and zero frame-unit overshoot. |
| Session frame limit | At most `UINT32_MAX` completed frames per loaded session; the adapter rejects further positive work before entering the core. |
| Input mask | Bits 0–7 are port 0 A/B/Select/Start/Up/Down/Left/Right; bits 8–15 are port 1 in the same order. Other bits are invalid. |
| Input sample point | The pending masks are sampled when the next positive `lf_advance` starts. Input changes cannot affect a frame already in progress. |
| Cumulative progress | `cumulative_units` counts completed frames. `cumulative_core_ticks` is Nesturbator's cumulative NES half-master-clock tick count, not per-call work. Instruction-boundary completion may overshoot the nominal tick target; no wall-time deadline or sub-frame precision is promised. |
| Video | 256 × 240 `LF_VIDEO_RGB24`, byte order R, G, B. The host supplies a byte stride of at least 768 and a byte capacity. |
| Video touched extent | Checked extent is `(height - 1) * stride + width * 3`. Only those pixel bytes are written; row padding and bytes after the extent remain unchanged. |
| Audio | Native-endian signed 16-bit mono interleaved PCM at 48,000/1 Hz. A successful frame produces 798 or 799 samples. |
| Audio capacity | Every positive frame request must supply at least 799 samples. Only the reported produced samples are copied, leaving the remaining caller tail unchanged. |

The adapter allocates bounded native video/audio scratch at instance creation
and performs no caller-allocator calls during `lf_advance`. It validates all
extents and capacities before asking Nesturbator to advance. Native partial
output is copied to host buffers only after a complete frame. Both output
buffers remain host-owned; the core and adapter retain no output pointer.

## Stop behavior, capabilities, and state effects

| Result | Observable postcondition |
|---|---|
| `LF_OK`, positive completed frame | `actual_units=1`; complete video and audio are valid; completed-frame count advances once; successful cumulative core ticks are valid. |
| `LF_OK`, zero work | No guest work or output writes; validity flags and produced extents/counts are zero; the normal stop reason is `LF_STOP_BUDGET_REACHED`. |
| `LF_OK`, `LF_STOP_CORE_HALTED` | The pinned core returned `NESTURBATOR_STOP_JAM`. `actual_units=0`, overshoot is zero, cumulative completed frames do not change, current video/audio/tick validity is false, and output buffers remain untouched. The result retains the last successful cumulative tick value as history only; it is not a partial JAM measurement. |
| Further calls after JAM | The stop remains latched and positive calls keep the same public effects. A refused replacement load preserves the latch. A successful content load resets it and begins a new frame history. |
| Rejected frame request | Invalid records/pointers return `LF_INVALID_ARGUMENT`; work above one frame or an overflowing checked extent returns `LF_LIMIT_EXCEEDED`; short video/audio capacity returns `LF_BUFFER_TOO_SMALL`. These preflight errors report zero newly completed work and leave guest continuation and caller buffers unchanged. |

JAM can occur after the linked core has internally advanced partway through a
frame. The adapter does not claim rollback of that internal state, exact partial
ticks, or protection from a faulty core. It merely withholds incomplete A/V and
does not count the frame as completed.

## Machine snapshot capture and restore

This profile supports the experimental snapshot capability for loaded,
battery-free content and one generated battery-backed MMC1 route. Phase 14
separately qualifies the battery-backed route for orderly fresh-process
restore, but only for Nesturbator release `v0.1.12`, source
`2338608ab184f040620a30d17756f5e06a42d4e3`, API revision 1, behavior revision
9, native state format 3, profile `nesturbator-ntsc-v1`, effective
configuration `nesturbator-default`, options `nesturbator-options-none-v1`,
and the project-authored fixture in [the fixture record](nesturbator-save-fixture.md).
Qualification requires the source consumer and an independently relocated
installed consumer on local macOS arm64. Other battery layouts, profiles,
builds, and targets are not qualified. Battery snapshot operations return
`LF_UNSUPPORTED` for other battery-backed content, including a different MMC1
image or an MMC3 layout; the mapper and save-RAM extent alone do not qualify
content. Eligibility is limited to the complete generated fixture identity
recorded below.

The capability query uses profile ID `nesturbator-ntsc-v1` with
`configuration_id=NULL`; it reports `LF_CAP_SNAPSHOT` as supported for the
effective `nesturbator-default` configuration. The existing capability query
does not qualify snapshots through a non-NULL configuration query. Synthetic,
Muhtari, and other unqualified routes remain unsupported.

After every successful load, the host calls `lf_get_snapshot_size` again to
obtain the exact extent for that live instance and session. The host owns the
resulting opaque bytes, and the library retains no snapshot pointer. Calls on
the instance are serialized with load, input, advance, media operations, and
destroy. Size discovery, capture, and restore do not advance guest execution.
Capture writes only the required extent. If its current capacity is short,
`LF_BUFFER_TOO_SMALL` leaves the full declared destination and machine
unchanged. The encoded extent is bounded to 128 MiB.

The battery-free route has its separate Phase 13 orderly fresh-process
qualification: Process A captures caller-owned bytes, the host writes and
closes the checkpoint, and A exits normally before Process B starts. B opens
and verifies those exact bytes, creates and loads a fresh public instance with
the same content and configuration, then restores and checks literal guest
continuation. The evidence covers the source build and a relocated installed
consumer on local macOS arm64 for the exact release and commit in this profile.

The battery-free route's stable identity is:

| Field | Required value |
|---|---|
| Envelope | Magic `LFSNAP2`, version 2, 388-byte header |
| Native state | Format 3, core ABI 1, behavior revision 9 |
| Core build | `nesturbator-2338608ab184f040620a30d17756f5e06a42d4e3` (release `v0.1.12`) |
| LibFuturo build | Exact deterministic build ID of the linked source or installed library, recorded separately in each route report |
| Profile/configuration/options | `nesturbator-ntsc-v1` / `nesturbator-default` / `nesturbator-options-none-v1` |
| Loaded content | Exact 24,592-byte fixture and its SHA-256 (`e74fae7b6d5d8438e7f0c36f3b86f52eab426166b521bb923a8d93bf6d628235`) |

The separate Phase 14 battery-backed fresh-process identity is:

| Field | Required value |
|---|---|
| Envelope | Magic `LFSNAP2`, version 2, 388-byte header |
| Native state | Format 3, core ABI 1, behavior revision 9 |
| Core build | `nesturbator-2338608ab184f040620a30d17756f5e06a42d4e3` (release `v0.1.12`) |
| LibFuturo build | Exact deterministic build ID of the linked source or installed library, recorded separately in each route report |
| Profile/configuration/options | `nesturbator-ntsc-v1` / `nesturbator-default` / `nesturbator-options-none-v1` |
| Loaded content | Exact generated 40,976-byte MMC1 fixture and SHA-256 (`2282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9`) |
| Qualification target | Local Darwin/macOS arm64; both source and moved-prefix-only installed consumers |

Restore checks the envelope's stable identity and exact bounds before native
restore; Nesturbator independently checks its native state identity and
CRC-32. The envelope also stores instance identity and successful-load epoch.
The epoch advances only after successful native loads and is compared only
when restoring a snapshot from the same instance, where it rejects stale
checkpoints. It is not cross-process identity and does not prevent the
qualified fresh instance from restoring matching bytes. On success, native
machine state is restored before the adapter commits pending buttons,
cumulative frames/ticks and their validity, or halt/session flags. On refusal,
both native state and those adapter fields remain active as before, so the next
public advance continues from the prior state.

The host owns checkpoint file I/O, including writing, close, reopen, and byte
verification. Both qualified cross-process routes require successful
checkpoint close and orderly Process A exit before Process B restores. For the
battery-backed A/B journey, A captures S2 with battery media R2, commits the
newer selected save R3, then closes the checkpoint before exiting. B loads the
matching content and imports R3 before positive guest work, then restores S2
to R2. B's refusal baseline and generation remain local to B; changed restored
bytes increase generation by exactly one, while an identical repeat leaves it
unchanged. Restore and a controlled pre-rename staging-write failure preserve
the selected R3 file and acknowledgment. The host selects R2 only after an
explicit successful commit is reopened and verified for identity, header,
exact extent, and complete payload, then advances the acknowledgment. One
literal replay work unit after restore returns guest media to R3 bytes. These
routes do not qualify abrupt termination, crash, `fsync`, power loss, or
uncertain post-rename recovery. SHA-256 and native CRC-32 detect byte identity
or corruption but do not authenticate the checkpoint. The experimental
envelope is not a stable shared or portable format, and the trusted linked
core remains in the host process without sandboxing or crash isolation. These
local macOS consumer checks do not qualify physical hardware or a browser
runtime.

For the exact generated battery-backed MMC1 route, battery RAM is restored
together with machine continuation. When restored bytes differ from current
media, `guest_generation` increases by exactly one; when the bytes are
identical, it does not increase. The adapter reports this profile's generation
relative to the successful-load baseline. These changed-byte and
identical-byte rules are specific to this pinned core, profile, and build.

| Result | Snapshot-specific postcondition |
|---|---|
| `LF_INVALID_ARGUMENT` | Snapshot operation on an unloaded instance, or malformed, truncated, or identity-mismatched state; the active machine is unchanged. |
| `LF_UNSUPPORTED` | Snapshot operation on a battery-backed layout outside the exact generated MMC1 route above, or on an unsupported profile/configuration; caller buffers and machine remain unchanged. |
| `LF_LIMIT_EXCEEDED` | Snapshot envelope exceeds 128 MiB, or a content load is attempted after the private successful-load epoch is exhausted; a refused load preserves the active session. |
| `LF_BUFFER_TOO_SMALL` | Capture capacity is smaller than the current exact extent; no destination bytes or machine progress change. |

The private per-instance successful-load epoch begins at zero and advances
only after a successful native content load. Failed loads do not advance it.
The epoch prevents an earlier checkpoint from matching a later successful
load session on that same instance and is not cross-process identity. The
checkpoint is host-owned storage state, not a host-managed durable revision.
It is not an authentication boundary, a stable shared format, an `fsync` or
power-loss guarantee, uncertain post-rename recovery, or crash isolation. It
does not include host-managed durable revisions; the linked core remains in
the host process.

## Persistent media and extent

This profile's media identity and import rules implement
[LC-HOST-01](contract.md#lc-host-01) and
[LC-OWN-01](contract.md#lc-own-01).

`lf_profile.media_extent_bytes` describes a static profile extent when one is
known. This profile reports zero to mark that the writable save span depends on
loaded content. Zero does not mean media support is absent. After a successful
load, `lf_media_info.extent_bytes` reports the exact writable span returned by
the pinned core for that loaded cartridge. The adapter fetches that live span
and validates its pointer and extent before copying or importing bytes.

The identity `nesturbator-save-ram-v1` names the writable save-RAM kind/slot.
It does not identify a cartridge or configuration. The host's save envelope
associates the bytes with its loaded-content and effective-configuration
identity. `lf_copy_media` returns a stable host-owned copy and a session-relative
generation from Nesturbator's monotonic media counter. It starts at zero after
a successful load and includes the profile-defined effect of battery snapshot
restore: one increment for changed restored bytes and none for identical bytes.
This exact delta rule is limited to the pinned release/profile/build. `lf_import_media`
accepts only the matching identity
and exact loaded extent after successful load and before the first positive
advance; all checks complete before the live span is changed. The host import
does not count as a guest write. Durable storage and its acknowledgments remain
host responsibilities. The `lf_media_info.identity` pointer is immutable and
library-owned; it remains valid until its instance is destroyed or the linked
library code is unloaded, whichever happens first. Copy it to retain it longer.

For the tested snapshot/save recovery journey, the host keeps its selected
newer payload and acknowledgment unchanged while restoring an older battery
state. A partial staging-write failure before rename leaves the selected bytes
and acknowledgment intact. The host then commits the restored bytes as a
distinct payload at the same selected path, reopens and verifies the exact
envelope and 8192-byte media span, and only then updates its acknowledgment.
Restore itself does not rewrite host storage or change the host acknowledgment.

Calls on one instance, including import, copy, advance, and destruction, must be
serialized. This profile makes no concurrent-use or cross-thread coherence
guarantee.

| Capability | Result |
|---|---|
| Logical input, bounded execution, software video, audio | Supported. |
| In-memory media copy/import | Supported for the loaded cartridge's writable save-RAM span, when the pinned core exposes one. |
| Machine snapshot | Supported for loaded battery-free content and the exact generated battery-backed MMC1 route above; see [snapshot capture and restore](#machine-snapshot-capture-and-restore). |
| Hardware video, concurrent use | `LF_UNSUPPORTED`. Calls on one instance must be serialized. |
| Callback reentry or cancellation | Not provided. Adapter work is synchronous and exposes no public host callback during frame execution. |

## Errors and postconditions

This table supplies the exact selected-profile postconditions for
[LC-ERROR-01](contract.md#lc-error-01) and
[LC-LIMIT-01](contract.md#lc-limit-01).

| Result | Frame/input postcondition |
|---|---|
| `LF_INVALID_ARGUMENT` | An unloaded session, malformed record, missing required pointer, invalid input mask, or too-short stride is rejected without a frame or output write. A malformed result record is left untouched. Non-NULL pointer validity remains a caller precondition. |
| `LF_UNSUPPORTED` | Known unavailable profile configuration/capability requests have no guest effect. |
| `LF_LIMIT_EXCEEDED` | Work or checked stride-extent overflow is rejected before guest progress. |
| `LF_BUFFER_TOO_SMALL` | Capacity is checked before the core frame call; A/V buffers, frame count, and tick history remain unchanged. |
| `LF_RESOURCE_EXHAUSTED` | Creation or candidate content allocation failure returns without leaking a partial instance or replacing an active cartridge. Frame advance itself allocates nothing. |
| `LF_OK` with `LF_STOP_CORE_HALTED` | A partial core stop is reported separately from a successful frame; see the JAM row above. |

## Fixture provenance and identity recipe

`tests/nesturbator_session.c` generates the test cartridge from original
project-authored C data. The generator uses a zero-filled iNES v1 header with
one 16 KiB PRG bank and one 8 KiB CHR bank, the fixed 6502 program in that file,
and reset/interrupt vectors set to `$8000`. The generated image is 24,592 bytes.
The code is original test content under this repository's Apache-2.0 license;
no upstream test helper, commercial ROM, BIOS, or other protected media is
copied or tracked.

The separate JAM variant is generated from the same image. It adds a check for
the controller's second serial bit (port 0 B) and executes opcode `$02` when
that button is pressed. The consumer first proves a complete frame with B
released, then observes the latched stop after B is selected.

The consumer exposes a deliberate build-output emission mode. The reproducible
identity recipe is:

```sh
build/check/nesturbator_session --emit-fixture build/check/nesturbator-nrom.bin
shasum -a 256 build/check/nesturbator-nrom.bin
```

The observed SHA-256 is
`e74fae7b6d5d8438e7f0c36f3b86f52eab426166b521bb923a8d93bf6d628235` for the
24,592-byte output. Repeated emissions compared byte-for-byte and produced the
same hash. Normal CTest sessions generate bytes in memory and do not write ROM
files; this explicit command writes only the caller-requested destination under
the build tree and checks open, write, and close failures.

## Evidence limits

The local consumer runs generated original cartridge data through public
libfuturo calls against the exact pin. The measured local row is macOS 26.6.2
arm64 with Apple Clang 21.0.0.21000101, CMake/CTest 4.4.3, and macOS SDK 26.5.
The canonical route establishes one installed, relocated package and a public
consumer using the exact Nesturbator pin, including A/V, save/restart, seven
selected load refusals, and replacement/reset. Focused source and relocated
installed checks also exercise the generated battery-backed snapshot, refusal,
media-generation, and save-recovery route described above. The Phase 12
identity-bound qualification gate passed on 2026-11-05 for this exact generated
fixture and local macOS 26.6.2 arm64 route. The gate included source and
relocated installed consumers, required-result controls, and installed host
timing/audio evidence. Hosted CI, other platforms or hardware, other battery
content, and release/publication were not qualified by this result.
The Phase 13 gate passed on 2026-11-06 for the battery-free fresh-process
route on the same local macOS 26.6.2 arm64 environment. It ran the exact
`v0.1.12`/`2338608ab184f040620a30d17756f5e06a42d4e3` pin through both the source
consumer and a relocated installed public consumer, requiring A's successful
checkpoint close and normal exit before B opened the checkpoint. Both routes
recorded exact runtime identity and artifact hashes, checked literal
continuation and refusal preservation, and rejected the deliberately wrong
oracle. This is orderly-stop evidence only; it does not qualify abrupt
termination, `fsync`, power-loss durability, another core/build/target, hosted
CI, hardware, browser, release, or publication.
This evidence does not establish general package compatibility, hardware
accuracy, browser behavior, hosted CI, or another host/target row.
The current Phase 02 verifier closes CORE-03 for the accepted finite exact-pin
parser partition and load-preservation scope. This does not establish
exhaustive parser safety; broader input behavior remains unqualified. See [the
adapter seam notes](nesturbator-seams.md) for the route, historical probe
scope, instrumentation boundary, and fixture provenance.
