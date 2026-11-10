# libfuturo shared native contract

This document defines the shared rules for the experimental libfuturo C
source API. It covers the host/core boundary, not a stable binary ABI or a
security boundary. Profile documents remain authoritative for supported
values, limits, timing details, and core-specific results:
[synthetic-v1](synthetic-profile.md) and
[nesturbator-ntsc-v1](nesturbator-profile.md), and
[Muhtari API 7 and API 8 profiles](muhtari-profile.md).

## Requirement words

The uppercase words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and
**MAY** have the meanings defined by [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119.html),
as clarified by [RFC 8174](https://www.rfc-editor.org/rfc/rfc8174.html).
Only these words in uppercase carry those special meanings in this document.

- **MUST** is an absolute requirement; **MUST NOT** is an absolute
  prohibition.
- **SHOULD** and **SHOULD NOT** express recommendations. A conforming
  implementation may depart only for a valid reason after the implications
  are understood and weighed.
- **MAY** marks a genuinely optional behavior.

## Shared obligations

<a id="lc-life-01"></a>
### LC-LIFE-01 — instance lifecycle

The host MUST own the `lf_instance` handle returned by `lf_create`. The host
MUST serialize operations on an instance, including `lf_destroy`. A successful
destroy consumes the supplied owner handle and clears it; a null owner handle
may be destroyed as specified by the API. If creation fails, no instance
handle is transferred to the host. These rules do not make stale aliases valid
and do not promise concurrent calls.

<a id="lc-own-01"></a>
### LC-OWN-01 — memory ownership and lifetime

Pointers supplied by the host MUST refer to valid, suitably aligned memory for
the declared extent and for the duration required by the call. A successful
load MUST leave the host free to release or change its input bytes after the
call. Audio and video destinations and copied media bytes remain host-owned;
the library MUST NOT retain those output pointers. Library-owned identity
strings remain valid only for the lifetime stated by the applicable profile
and linked library.

The host MUST keep declared audio and video destination spans disjoint from
each other, request/result records, and instance storage. For `lf_copy_media`,
the full declared destination capacity span MUST be disjoint from its
`lf_media_info` output record and instance storage. Adjacent spans in one
allocation are permitted. Overlap is invalid caller use; the library does not
promise runtime detection or valid outputs for such a call.

<a id="lc-load-01"></a>
### LC-LOAD-01 — load state changes

A successful load replaces the active content and begins the profile-defined
session state. A rejected load MUST NOT replace the active session. When a
valid result record is available, its failure contents and the precise status
mapping are defined by the selected profile. A rejected request against an
unloaded instance MUST leave it unloaded. This obligation covers the state
transition; it does not require profiles to accept the same content or expose
the same configuration options.

<a id="lc-input-01"></a>
### LC-INPUT-01 — logical input

The host supplies logical button state through `lf_set_input`. A successful
call updates pending input; the selected profile defines its accepted mask and
sampling point. Device discovery and physical-controller mapping remain host
responsibilities. A host MUST NOT infer that changing pending input advances
guest time.

<a id="lc-time-01"></a>
### LC-TIME-01 — guest progress

`lf_run_request.work_units` is measured in the selected profile's guest-work
unit. `lf_run_result.actual_units` and `cumulative_units` report completed
work in that same unit. They MUST NOT be presented as host elapsed time. If a
profile reports a finer source clock, that clock and its cumulative value are
separate measurements with independent validity; an implementation MUST NOT
derive one from the other unless the profile explicitly defines that
relationship.

`LF_TIME_FRAME` counts completed profile frame-advance intervals. A profile
may define its first successful interval as partial; callers MUST use the
profile's startup rule and MUST NOT treat cumulative frames as equal-duration
wall-clock time. `lf_profile.frame_rate_numerator` and
`frame_rate_denominator` declare exact steady-state cadence only when both are
positive. `0/0` means cadence is undeclared or inapplicable; callers MUST NOT
substitute an assumed rate. Synthetic and Nesturbator currently report `0/0`.

`LF_VIDEO_INDEX8` means each output byte is the raw color-number value defined
by the selected profile. It is neither grayscale nor RGB, and the library does
not apply palette lookup or color conversion. Presentation and palette policy
belong to the host.

<a id="lc-limit-01"></a>
### LC-LIMIT-01 — bounds and preflight rejection

Each profile MUST expose or document its applicable work, media, and output
bounds. A host MUST check the selected profile rather than assume one profile's
limits apply to another. Requests rejected during preflight, including work
limit and output-capacity failures, MUST NOT advance guest work or modify
caller output buffers. Each profile defines the exact bound and status.

<a id="lc-error-01"></a>
### LC-ERROR-01 — status meaning and postconditions

`LF_INVALID_ARGUMENT` identifies a malformed or invalid request;
`LF_UNSUPPORTED` identifies a well-formed operation or value the selected
profile does not support; `LF_LIMIT_EXCEEDED` identifies a profile bound;
`LF_BUFFER_TOO_SMALL` identifies insufficient caller output capacity; and
`LF_RESOURCE_EXHAUSTED` identifies a resource allocation failure. A profile
MUST define the postcondition for each result it can return. Callers MUST use
the operation's documented postcondition rather than infer rollback from the
status name alone.

<a id="lc-host-01"></a>
### LC-HOST-01 — persistent media and durable writes

`lf_copy_media` exposes a host-owned copy of the profile's current persistent
media span. The media identity names the media kind or slot; the host associates
the bytes with content and configuration identity. `guest_generation` is a
profile-defined core media-change token, not a host revision or durability
receipt. The profile defines how guest work, media import, and snapshot restore
affect that token. Media import changes in-memory core state under the profile's
rules; it is not a durable commit. A successful snapshot restore changes
persistent media only as defined by the selected profile, and restore does not
change a host-managed save or acknowledgment.

The host owns save serialization, file or device writes, recovery, and any
durable acknowledgment. Before committing copied media, the host MUST validate
the associated content/configuration identity, media identity, and exact extent.
A failed pre-rename staging write MUST leave the prior selected save bytes and
acknowledgment intact. After selecting a replacement, the host MUST reopen and
verify the intended header and payload before advancing its acknowledgment.
A distinct payload at one selected path can represent a new revision; revision
IDs or save history are not required by this contract. Core support for media
access does not imply file I/O, crash safety, or cross-profile save
compatibility.

For the Muhtari battery diagnostic, `lf_copy_media` returns the exact loaded
`muhtari-battery-v1` span as caller-owned bytes; the adapter does not expose or
retain Muhtari's native media pointer. The host associates the span with its
loaded-content digest and effective configuration. Before `lf_import_media`,
the host MUST validate the save envelope's framing, content and configuration
identity, media identity, and exact loaded extent. It MUST import only after a
successful load and before the first positive guest advance. A rejected
envelope MUST leave the active media span unchanged. The reported guest
generation remains a core change token, not a durable acknowledgment.

<a id="lc-snapshot-01"></a>
### LC-SNAPSHOT-01 — snapshot selection and ownership

Snapshot capability is discovered through `lf_get_capability` with the
selected profile ID and the profile's configuration selector. A consumer MUST
check this capability before relying on the experimental operations. Profiles
that qualify a NULL configuration retain that query convention; the API 8
Muhtari battery-diagnostic route requires its explicit configuration ID and
returns `LF_UNSUPPORTED` for the NULL selector. Snapshot bytes are opaque,
caller-owned spans. The library MUST
NOT retain either span after its call. The host MUST keep every declared
snapshot span valid for the call, disjoint from the instance and other live
API arguments, and serialize snapshot calls with all other calls on that
instance.

<a id="lc-snapshot-02"></a>
### LC-SNAPSHOT-02 — exact sizing and capture

After every successful content load, the host MUST query the exact snapshot
extent for that loaded instance before capturing. Size discovery, capture, and
restore MUST NOT advance guest execution. Capture MUST recheck the current
extent, write only the required bytes, and leave the full caller-declared
destination and active machine unchanged when capacity is short; that result
is `LF_BUFFER_TOO_SMALL`. A successful capture retains no caller pointer.

<a id="lc-snapshot-03"></a>
### LC-SNAPSHOT-03 — restore identity and continuation

Snapshot validity is profile-defined and is bound to the exact compatibility
identity declared by the selected profile. For the qualified battery-free
Nesturbator route, stable identity includes the `LFSNAP2` envelope version,
deterministic LibFuturo build ID, core build ID, core ABI and behavior revision,
native state format, profile, effective configuration and options, and the
exact loaded-content byte extent and SHA-256. This exact-build identity permits
the qualified checkpoint to be restored by a fresh process only when it loads
the same content with the matching linked builds and profile configuration; it
does not establish general cross-build or cross-core portability. The envelope
also carries an instance identity and successful-load epoch, but the epoch is
checked only to reject stale snapshots when restoring on the same instance. It
is not cross-process identity.

For that battery-free route, qualification covers Process A successfully
writing and closing a checkpoint, exiting normally, and Process B opening the
exact bytes in a fresh process and restoring a fresh public instance. The host
owns the checkpoint path, serialization to storage, writes, close, reopen, and
verification.

The exact battery-backed fresh-process exception is separately qualified only
for Nesturbator v0.1.12 at source commit
`2338608ab184f040620a30d17756f5e06a42d4e3`, build
`nesturbator-2338608ab184f040620a30d17756f5e06a42d4e3`, API revision 1,
behavior revision 9, native state format 3, profile `nesturbator-ntsc-v1`,
effective configuration `nesturbator-default`, options
`nesturbator-options-none-v1`, and the exact project-generated 40,976-byte
MMC1 content with SHA-256
`2282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9`.
Qualification requires both the source consumer and an independently relocated
installed consumer on local macOS arm64; one route cannot qualify the other.

In that route, Process A captures S2 while its battery media is R2, commits a
newer selected save R3, successfully closes the host-owned checkpoint, and
exits orderly. Process B loads the exact same content, imports R3 before any
positive guest advance, then restores S2 to R2. The successful-load epoch
remains local to each instance and is not compared across processes. In B,
restoring different media bytes increases the media generation by exactly one;
an identical-byte restore leaves it unchanged. Restore and a controlled
pre-rename staging-write failure preserve the selected R3 bytes and host
acknowledgment. Only an explicit successful R2 commit that the host reopens
and verifies for identity, header, exact extent, and complete payload may
advance that acknowledgment. The independent replay after restore produces
R3 guest bytes again. Both fresh-process exceptions cover orderly close and
exit only; they do not establish abrupt-termination, crash, `fsync`, power-loss,
or uncertain post-rename recovery. Other builds, cores, profiles, layouts,
targets, and architectures do not inherit either exception. This local
consumer evidence does not qualify physical hardware or a browser runtime.

The API 8 Muhtari exception is independently qualified for Muhtari v0.11.1 at
source commit `d58f125297c4d63a7a8108112a5eafff6f53a76a` (API 8, ABI 1,
behavior revision 6, native state format 1), profile `muhtari-ntsc-v2`,
configuration `muhtari-ntsc-battery-diagnostic`, options `none`, and the
project-generated 16,512-byte A78 fixture with SHA-256
`136cbead3da4bde24ea23acf36eb8daacced88074bbe021888aa4e17d987195e`. The
selected loaded fixture has a 34,816-byte HSC plus SaveKey media span.
Qualification requires separate source and relocated installed public
consumers on local macOS arm64. In both routes, Process A captures R2 after
public frame 2 with the SaveKey page write pending at aggregate offset 2051;
capture and size discovery do not advance guest work. Process A later commits
selected save R3, successfully closes the host-owned checkpoint, and exits
orderly. Fresh Process B reopens the exact checkpoint, imports R3 before
positive guest work, and restores R2. The restored pending page publishes
`0x5A` at frame 3, where literal frame, video, PCM, and complete battery-span
expectations are checked. The snapshot must match the exact LibFuturo and
Muhtari builds, API/ABI/behavior/state-format tuple, profile, effective
configuration and options, loaded-content digest, and exact extents before
native loading. Receiver generation is compared only against B's own prior
value: restoring changed bytes advances it once, and an identical-byte
restore leaves it unchanged. A rejected restore preserves B's continuation,
full media span, local generation, and exact selected-save/acknowledgment pair.
The host owns checkpoint/save paths, serialization, staging, commit decisions,
readback, and durable acknowledgments. Restore and the controlled pre-rename
failure preserve selected R3 and its acknowledgment; only an explicit host
commit followed by exact reopen/readback can advance acknowledgment to R2.
These claims do not establish crash, abrupt-exit, `fsync`, power-loss, or
uncertain post-rename recovery. SHA-256/CRC detect byte identity/corruption,
not authenticity. The experimental native state has no stable API/ABI or
snapshot-format promise and is not portable across builds. The API 7
`muhtari-ntsc-v1` route and default-off installation remain unchanged; other
profiles, layouts, builds, cores, targets, and architectures do not inherit
the API 8 exception. The linked Muhtari core remains trusted in-process code
without sandboxing or crash isolation.

Restore MUST validate the LibFuturo envelope, stable identity, and exact bounds
before calling the native loader. The native payload remains subject to the
core's own state validation. On success, the implementation MUST restore
native state first and publish the saved adapter continuation only after the
native loader accepts the payload. That continuation includes pending logical
input and guest frame/tick history and validity, plus session flags that affect
future calls. Transient caller-owned audio/video outputs, physical devices, and
host telemetry are not restored. When a profile includes persistent media in
its machine snapshot, successful restore MUST restore that media with the
machine. The subsequent `lf_copy_media` result reports any generation effect
defined by that profile; the host's durable save and acknowledgment remain
independent.

<a id="lc-snapshot-04"></a>
### LC-SNAPSHOT-04 — refusal effects

A rejected restore MUST preserve the active native state and all adapter
continuation state, including pending logical input and frame/tick history and
validity, and the profile-defined persistent media bytes and generation.
Restore MUST NOT change host-managed save files or acknowledgments.
`LF_INVALID_ARGUMENT` reports malformed, truncated, or mismatched state;
`LF_LIMIT_EXCEEDED` reports an envelope outside the selected bounds. Neither
result advances guest execution or writes caller outputs. Snapshot operations
on an unloaded instance return `LF_INVALID_ARGUMENT`. A well-formed snapshot
operation unsupported for the loaded content or selected profile/configuration
returns `LF_UNSUPPORTED` without changing the active machine, media, or caller
buffers.

<a id="lc-snapshot-05"></a>
### LC-SNAPSHOT-05 — scope and persistence boundary

Snapshot support and media effects are profile-defined. The selected
Nesturbator profile supports its battery-free route and the exact generated
battery-backed MMC1 route documented in the [Nesturbator profile](nesturbator-profile.md#machine-snapshot-capture-and-restore);
both exact routes have separate fresh-process qualification, and no other
profile, battery layout, build, core, target, or architecture is implied. The
private per-instance
successful-load epoch starts at zero and advances only after a successful
native content load. A failed load does not advance it; an exhausted epoch
rejects a new load with `LF_LIMIT_EXCEEDED` before native mutation. Snapshot
bytes represent machine state and are not a host-managed durable revision. The
envelope SHA-256 and the selected core's native CRC-32 provide byte identity
and corruption checks, not authentication. The experimental envelope has no
stable shared-format or cross-build compatibility promise, and the linked core
runs in the host process without sandboxing or crash isolation.

Phase 13 qualified the exact Nesturbator `v0.1.12` source commit
`2338608ab184f040620a30d17756f5e06a42d4e3`, profile
`nesturbator-ntsc-v1`, effective configuration `nesturbator-default`, and
generated 24,592-byte battery-free NROM content with SHA-256
`e74fae7b6d5d8438e7f0c36f3b86f52eab426166b521bb923a8d93bf6d628235` on local
macOS arm64. Phase 14 separately qualifies the exact 40,976-byte generated
battery-backed MMC1 identity above. Each qualification requires source and
relocated installed public consumers with identity-bound evidence. Neither
qualifies another target, core, profile, build, or release.

Phase 15 separately qualifies only the exact API 8 Muhtari profile, fixture,
and local macOS arm64 source and moved-install routes stated in LC-SNAPSHOT-03.
The API 8 snapshot capability query reports configuration-level availability
and does not inspect loaded content; snapshot operations also require the exact
fixture. API 7
`muhtari-ntsc-v1` and API 8 configurations other than the battery diagnostic
remain unsupported for snapshots. The project-generated fixture's pending
SaveKey page is covered only at the proven public frame boundary. These local
routes establish successful checkpoint close, orderly exit, and fresh-process
reopen; they do not establish abrupt termination, crash, `fsync`, power-loss,
or post-rename uncertain-readback recovery. No API/ABI/native-format stability
or cross-build portability follows from this qualification. See the
[Muhtari API 8 profile](muhtari-profile.md#api-8-muhtari-ntsc-v2-snapshot-qualification)
and [fixture record](muhtari-snapshot-fixture.md) for its exact literals and
route identities.

The version-2 API 8 snapshot envelope has a 416-byte metadata header. A
SHA-256 digest covers the complete header with the digest field zeroed,
including instance identity and successful-load epoch. This detects metadata
corruption but does not authenticate snapshots.

## Traceability index

The examples illustrate normal public use. The cited conformance and
integration assertions establish the listed behavior for their stated
profiles; they do not broaden the support matrix.

| Obligation | Public declarations | Example | Profile rule | Executable assertion |
|---|---|---|---|---|
| [LC-LIFE-01](#lc-life-01) | `lf_create`, `lf_destroy` in [`libfuturo.h`](../include/libfuturo/libfuturo.h) | [`synthetic main`](../examples/synthetic/main.c) and [`Muhtari main`](../examples/muhtari/main.c) create and destroy their owners. | [Synthetic ownership](synthetic-profile.md#ownership-errors-and-postconditions); [Nesturbator ownership](nesturbator-profile.md#ownership-and-native-call-preconditions); [Muhtari ownership](muhtari-profile.md#ownership-and-call-preconditions) | [`test_allocator_lifecycle`](../tests/synthetic_boundaries.c), the `nesturbator_probe` CTest, and `muhtari_example`. |
| [LC-OWN-01](#lc-own-01) | `lf_load`, `lf_advance`, `lf_copy_media`, `lf_import_media` | [`synthetic main`](../examples/synthetic/main.c) and [`Muhtari main`](../examples/muhtari/main.c) retain host-owned output spans. | [Synthetic ownership](synthetic-profile.md#ownership-errors-and-postconditions); [Nesturbator ownership](nesturbator-profile.md#ownership-and-native-call-preconditions); [Muhtari ownership](muhtari-profile.md#ownership-and-call-preconditions) | `synthetic_session`, `nesturbator_session` and the relocated `muhtari_installed_consumer` buffer-lifetime assertions. |
| [LC-LOAD-01](#lc-load-01) | `lf_load`, `lf_load_request`, `lf_load_result` | [`synthetic main`](../examples/synthetic/main.c) and [`Muhtari main`](../examples/muhtari/main.c) demonstrate successful load. | [Synthetic load effects](synthetic-profile.md#in-memory-media); [Nesturbator replacement](nesturbator-profile.md#content-loading-and-replacement); [Muhtari replacement](muhtari-profile.md#content-loading-and-replacement) | [`check_load_state`](../tests/conformance.c) with the [`ExpectConformanceFailure` harness](../cmake/ExpectConformanceFailure.cmake), plus synthetic, Nesturbator and relocated Muhtari refusal/continuation assertions. |
| [LC-INPUT-01](#lc-input-01) | `lf_input`, `lf_set_input` | [`synthetic main`](../examples/synthetic/main.c) and [`Muhtari main`](../examples/muhtari/main.c) supply logical masks. | [Synthetic sampling](synthetic-profile.md#input-and-state-transitions); [Nesturbator sampling](nesturbator-profile.md#input-frames-video-and-audio); [Muhtari sampling](muhtari-profile.md#input-frames-video-and-audio) | `synthetic_session`, `nesturbator_session`, `muhtari_example` and the relocated `muhtari_installed_consumer` input/result assertions. |
| [LC-TIME-01](#lc-time-01) | `lf_run_request`, `lf_run_result`, `lf_time_unit`, `lf_profile` cadence fields | Both public examples check profile metadata and completed guest work. | [Synthetic time](synthetic-profile.md#input-and-state-transitions); [Nesturbator time](nesturbator-profile.md#input-frames-video-and-audio); [Muhtari time](muhtari-profile.md#input-frames-video-and-audio) | [`check_common_profile_declarations`](../tests/conformance.c) checks existing formats and `0/0` cadence; `muhtari_example` and the relocated consumer check exact Muhtari cadence and startup progress. |
| [LC-LIMIT-01](#lc-limit-01) | `lf_profile`, `lf_run_request`, `lf_run_result` | Both public examples read selected profile limits and submit bounded output spans. | [Synthetic bounds](synthetic-profile.md#identity-capabilities-and-limits); [Nesturbator bounds](nesturbator-profile.md#input-frames-video-and-audio); [Muhtari bounds](muhtari-profile.md#input-frames-video-and-audio) | [`test_work_and_lifetime_boundaries`](../tests/synthetic_boundaries.c), `exercise_frame_failures`, and the relocated Muhtari frame-boundary assertions. |
| [LC-ERROR-01](#lc-error-01) | `lf_status` and all status-returning declarations | Both public examples report failed public operations. | [Synthetic postconditions](synthetic-profile.md#ownership-errors-and-postconditions); [Nesturbator postconditions](nesturbator-profile.md#errors-and-postconditions); [Muhtari postconditions](muhtari-profile.md#capabilities-errors-and-evidence-boundary) | `synthetic_boundaries`, `exercise_load_failure_cases`, `exercise_frame_failures`, and the relocated Muhtari refusal/boundary assertions. |
| [LC-HOST-01](#lc-host-01) | `lf_media_info`, `lf_copy_media`, `lf_import_media` | [`main`](../examples/synthetic/main.c) copies media into host storage. | [Synthetic media](synthetic-profile.md#in-memory-media); [Nesturbator media](nesturbator-profile.md#persistent-media-and-extent); [Muhtari media](muhtari-profile.md#persistent-media-and-save-identity) | [`ExpectNesturbatorSaveRestart.cmake`](../cmake/ExpectNesturbatorSaveRestart.cmake) and the relocated Muhtari save/restart journey check commit, rejection, fresh restore, and prior-save recovery. |
| [LC-SNAPSHOT-01–05](#lc-snapshot-01) | `lf_get_snapshot_size`, `lf_capture_snapshot`, `lf_restore_snapshot` | Snapshot spans remain caller-owned and serialized. | [Nesturbator snapshot rules](nesturbator-profile.md#machine-snapshot-capture-and-restore); [Muhtari API 8 snapshot rules](muhtari-profile.md#api-8-muhtari-ntsc-v2-snapshot-qualification) | Nesturbator session/fresh-process assertions plus `muhtari_api8_snapshot_contract`, `muhtari_api8_source_fresh_process`, and the moved `muhtari_api8_installed_fresh_process`; both API 8 route reports are accepted by `ValidateMuhtariApi8Results.cmake`. |

## Reading the profile rules

The traceability index points to profile-owned details rather than restating
them. Profile tables define exact input bits, work units, buffer geometry,
content limits, capability support, status mapping, and result postconditions.
The shared baseline does not promise a stable source API, binary ABI,
cross-compiler layout, sandbox, browser runtime, or behavior beyond the
profiles and evidence linked here.

## Source and binary compatibility

The appended cadence fields change the size of `lf_profile`, and
`LF_VIDEO_INDEX8` adds a public enum value. Consumers must rebuild against the
matching header and library after these experimental source changes; an older
binary consumer is not promised layout or enum compatibility. A profile's
`api_revision` identifies the linked source core's API revision. It is not a
libfuturo ABI version or a promise of binary stability.
