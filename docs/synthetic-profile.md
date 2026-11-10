# Synthetic profile: `synthetic-v1`

`synthetic-v1` is a deterministic development and conformance profile for the experimental libfuturo C source API. It demonstrates one public host/core boundary. It does not emulate console hardware or qualify a real core.

Shared obligations are defined in the [native contract](contract.md):
[LC-LIFE-01](contract.md#lc-life-01), [LC-OWN-01](contract.md#lc-own-01),
[LC-LOAD-01](contract.md#lc-load-01), [LC-INPUT-01](contract.md#lc-input-01),
[LC-TIME-01](contract.md#lc-time-01), [LC-LIMIT-01](contract.md#lc-limit-01),
[LC-ERROR-01](contract.md#lc-error-01), and
[LC-HOST-01](contract.md#lc-host-01). This file remains authoritative for
synthetic-v1 values and profile-specific outcomes.

## Identity, capabilities, and limits

Profile-specific bounds and capabilities for [LC-LIMIT-01](contract.md#lc-limit-01).

The profile reports `core_id=synthetic`, API revision `1`, behavior revision `1`, and a configure-time build identifier. Profile strings are immutable library-owned storage valid while the linked library remains live. The build identifier identifies the source revision observed at configure time; it is not a compatibility promise.

The profile supports logical input, bounded execution, Gray8 software video, signed-16 audio, and in-memory media copy/import. Snapshot, hardware-video, and concurrent-use capabilities are known and explicitly return `LF_UNSUPPORTED` with `supported=0`. Unknown profile or capability identifiers return `LF_INVALID_ARGUMENT`.

| Limit | Value |
|---|---:|
| Input mask | `3` (`A=1`, `B=2`) |
| Work units per call | `4` maximum |
| Guest steps per instance | `8` maximum |
| Time unit / atomic quantum | `LF_TIME_SYNTHETIC_STEP` / `1` |
| Permitted overshoot | `0` steps |
| Video | Gray8, 2 × 2, 1 byte per pixel, minimum stride 2 bytes |
| Audio | native-endian signed 16-bit, mono interleaved, 8000/1 Hz, at most 8 samples per call |
| Fixed profile media extent | 4 bytes |

These guest-work limits do not promise a wall-time deadline, preemption, or cancellation. Each call is synchronous. Callers serialize all calls per instance, including destruction; callbacks must not reenter that instance. No concurrency or interruption guarantee is provided.

`LF_CAP_SNAPSHOT`, `LF_CAP_HARDWARE_VIDEO`, and
`LF_CAP_CONCURRENT_USE` are known capabilities that return `LF_UNSUPPORTED`
with `supported=0`. An unknown capability identifier returns
`LF_INVALID_ARGUMENT` and also clears `supported` to zero. Independent instances
may be interleaved by sequential calls; that does not qualify concurrent calls.

## Input and state transitions

Profile-specific sampling and guest-unit rules for
[LC-INPUT-01](contract.md#lc-input-01) and
[LC-TIME-01](contract.md#lc-time-01).

An instance starts at step `n=0`, accumulator `a=0`, pending input `0`, media bytes `[76,70,0,0]`, and guest generation `0`. A valid `lf_set_input` replaces pending logical buttons without advancing guest state. At the start of the next positive-work `lf_advance`, the current input is sampled once and held for every step in that call. A zero-work advance does not sample input or produce output. Repeating an advance is stateful; it advances again.

For each executed step, increment `n` by one and add `sampled_buttons + 1` to `a`. Input bits outside mask `3` are invalid. Work above four units or beyond the remaining eight-step lifetime returns `LF_LIMIT_EXCEEDED` before progress. The remaining-work comparison uses subtraction; this profile has no partial-success stop.

The prescribed session uses these input masks and requested work units:

| Call | Input mask | Requested steps | Cumulative steps |
|---:|---:|---:|---:|
| 1 | 0 | 1 | 1 |
| 2 | 1 | 2 | 3 |
| 3 | 2 | 1 | 4 |

## Audio and video outputs

Output ownership and profile limits follow
[LC-OWN-01](contract.md#lc-own-01) and
[LC-LIMIT-01](contract.md#lc-limit-01).

Positive-work calls produce the final-step image as row-major `LF_VIDEO_GRAY8`, width 2, height 2, one byte per pixel. The host supplies a byte pointer, capacity, and byte stride of at least 2. The touched extent is `(height - 1) * stride + width`; arithmetic is checked before guest progress or output writes. At packed stride 2, the extent is four bytes. Pixels are `[n, a, sampled_input, n + a]`. Row padding and bytes beyond the touched extent remain unchanged.

Audio uses native-endian signed `int16_t` samples, mono interleaved, with rate numerator/denominator `8000/1`. Each executed step appends `[a * 16, -a * 16]`. Capacity and produced counts are measured in samples. The maximum call produces eight samples. The caller owns both output buffers and their contents after return, later calls, and instance destruction; the library retains no output pointer.

All guest progress, accumulator values, sample values, extents, and sample counts use bounded integer arithmetic. The profile performs no floating-point conversion or rounding. This describes the synthetic profile only; it does not promise a host-time rate or asynchronous cancellation.

Every successful positive advance reports the requested and actual steps, sampled buttons, cumulative position, budget-reached stop reason, zero overshoot, and complete audio/video metadata. Successful zero-work calls report zero actual work, zero `sampled_buttons`, false validity flags, and zero output counts/extents while retaining the profile's format metadata. Rejected calls with a valid result record also leave `sampled_buttons` at zero. Consumers should treat this field as meaningful only when `actual_units` is positive. A valid result record on rejection is initialized deterministically with zero actual work, overshoot, output validity/counts/extents, unchanged cumulative state, and `LF_STOP_REJECTED`.

## In-memory media

This section supplies this profile's load and media rules for
[LC-LOAD-01](contract.md#lc-load-01) and
[LC-HOST-01](contract.md#lc-host-01).

`lf_profile.media_extent_bytes` is the profile's static fixed extent when known. This profile reports `4`. A zero value explicitly marks a content-dependent/dynamic extent. `lf_media_info.extent_bytes` reports the exact writable span for currently loaded content; the synthetic profile's fixed four-byte allocation also reports `4` before its test content is loaded.

After each positive call, the synthetic guest's four media bytes are `[76,70,n,a]`, with identity `synthetic-media-v1`, extent four, and guest generation `n`. `lf_copy_media` copies these bytes into a bounded host buffer and never returns a mutable core span. A zero- or short-capacity copy returns `LF_BUFFER_TOO_SMALL` without changing the destination or guest state. A copied host buffer remains valid after later calls and destruction. The media identity names the writable media kind/slot; the host envelope associates its bytes with loaded content and effective configuration.

One project-owned four-byte test signature, `LFT1`, is accepted by `lf_load` only to exercise the public import boundary. It is not a cartridge format or general synthetic content loader. Successful load resets the test session and its media generation. Other well-formed content or configuration requests remain `LF_UNSUPPORTED`; malformed requests remain `LF_INVALID_ARGUMENT` and preserve the active state.

`lf_import_media` accepts exactly four bytes with identity `synthetic-media-v1` only after that successful test load and before the first positive guest advance. It validates timing, identity, and exact extent before copying. Malformed input, a wrong extent, or an import before load/after positive advancement returns `LF_INVALID_ARGUMENT`; a different well-formed media identity returns `LF_UNSUPPORTED`. A host import does not increment guest generation, and repeating the same import is idempotent. The profile remains in-memory only: it does not access files, acknowledge durable storage, or demonstrate recovery across process restart.

## Ownership, errors, and postconditions

These profile-owned lifecycle, memory-lifetime, and status details implement
[LC-LIFE-01](contract.md#lc-life-01),
[LC-OWN-01](contract.md#lc-own-01), and
[LC-ERROR-01](contract.md#lc-error-01).

| Object | Owner and lifetime |
|---|---|
| `lf_instance` | Host owns the opaque handle returned by `lf_create`; `lf_destroy` frees it and clears the owning handle. Destroying an already-null owner is a successful no-op. Stale aliases are invalid caller use. |
| Custom allocator context | Borrowed from the host until destruction. Allocation and deallocation callbacks must be paired, meet normal C alignment requirements, and not reenter the instance. |
| Profile identity strings | Immutable library-owned strings valid while linked code remains live. |
| `lf_media_info.identity` | Immutable library-owned string, valid until its instance is destroyed or the linked library code is unloaded, whichever happens first. Copy it to retain it longer. |
| Video/audio destination | Host-owned memory; the core writes only within checked capacities and retains no pointer. |
| Copied media bytes | Host-owned copy with no dependency on the instance after `lf_copy_media` returns. |
| Imported media source | Borrowed readable host memory for the duration of `lf_import_media`; the bytes are copied into the instance. |

`lf_create` clears its output handle before work and allocates the instance and four-byte media separately. If either allocation fails, every successful allocation is released once, the output remains null, and the result is `LF_RESOURCE_EXHAUSTED`. No general fault-injection interface is provided.

| Result | Postcondition |
|---|---|
| `LF_INVALID_ARGUMENT` | Malformed record sizes, unknown IDs, invalid input bits/stride, missing required pointers, malformed import data, wrong media extent, or import outside its allowed timing are rejected before guest progress or media mutation. A malformed output record is not written. |
| `LF_UNSUPPORTED` | A known unsupported capability or unsupported well-formed content/configuration/media identity is reported without changing active state. |
| `LF_LIMIT_EXCEEDED` | Work or checked extent limits reject before guest progress or output mutation. |
| `LF_BUFFER_TOO_SMALL` | Capacity rejection happens before progress; video/audio buffers and media-copy destinations remain unchanged. |
| `LF_RESOURCE_EXHAUSTED` | Partial initialization is cleaned up and no instance handle escapes. |
| `LF_OK` | Queries and copies do not advance guest state; input replacement does not advance it; successful load initializes a new test session; media import changes media bytes without counting as a guest write; positive-work advance adds guest progress. |

Each extensible record begins with `struct_size`. This revision accepts exactly `sizeof(record)` and does not inspect other fields until that size is validated. Required pointers must refer to valid, aligned, readable/writable memory as appropriate. The caller must keep the declared audio and video destination spans disjoint from each other, records, and instance storage. For `lf_copy_media`, the full declared destination capacity span must also be disjoint from its `lf_media_info` output record and instance storage. Adjacent non-overlapping spans in one allocation are permitted. Overlap is invalid caller use; runtime detection is not promised. A C API around trusted native code is not a sandbox: a faulty in-process core can still crash or corrupt its host.

The canonical boundary test exercises work counts `0`, `1`, `4`, and `5`; the eight-step lifetime limit and rejected ninth step; input masks `0`, `3`, and `4`; and short, exact, and one-over capacities. For a packed two-row image, stride `1` is invalid and capacities `0` or `3` are short while `4` and `5` are sufficient. At stride `3`, the touched extent is five bytes: capacity `5` succeeds while the one-under capacity `4` is rejected before progress or writes. Row padding and trailing canaries remain host-owned. A `SIZE_MAX` stride is rejected when checked extent arithmetic overflows, before output access. A one-step audio call needs two samples: capacities `0` and `1` reject, while `2` and `3` succeed. A four-step call needs eight samples; a two-sample capacity demonstrates bounded-output pressure, while capacity `8` or `9` succeeds. Media-copy capacities `3`, `4`, and `5` cover short, exact, and one-over cases. Rejected advances preserve guest position, media generation, pending input, and output buffers; a following valid call is compared with a clean reference instance. Allocation refusal at each create allocation leaves no owner and frees every partial allocation; an independently tracked session still matches its same-history control. These checks are representative public-boundary evidence for this profile, not an exhaustive claim about arbitrary native pointers or other profiles.

## Compatibility and fixture provenance

| Compatibility axis | `synthetic-v1` statement |
|---|---|
| Source API | Experimental. Declarations and record shapes may change as implementation and specification evolve. |
| Binary ABI | No stable binary ABI, plugin ABI, or cross-compiler struct-layout promise is made. |
| Core behavior | Behavior revision `1` names this synthetic profile's rules; it does not promise behavior compatibility with real cores or other profile revisions. |
| Persistent-media identity | `synthetic-media-v1` names four in-memory synthetic bytes only; it is not a durable save format or a cross-core migration promise. |
| Snapshot compatibility | Snapshot capability is unsupported. No snapshot bytes or restore compatibility are promised. |

The literal fixture is project-authored in `tests/synthetic_oracle.h`, independently of `src/synthetic.c`. Its input sequence is the table above: masks `0, 1, 2` and requested work `1, 2, 1`. Expected video, audio, media, generation, progress, and stop values are stored as literals; no ROM/BIOS data or copied helper code is used.

The local `./scripts/check.sh` verifies the selected macOS arm64 source-build consumer path. This profile does not establish real-core integration, durable saves, installed or relocated packages, browser behavior, another target row, hardware output, or a general performance guarantee.
