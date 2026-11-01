# nesturbator source and adapter seams

## Exact source and rights

The bounded probe uses the public `szTheory/nesturbator` source commit
`2338608ab184f040620a30d17756f5e06a42d4e3` from
`https://github.com/szTheory/nesturbator.git`. CMake fetches it under the local
build tree, rejects `FETCHCONTENT_SOURCE_DIR_NESTURBATOR`, and checks the
acquired Git `HEAD` and `origin` before configuring the project. The embedded
project provides the static target `nesturbator::nesturbator`; its top-level
runner, libretro core, tools, tests, and release packaging are not added.

The pinned source's `LICENSE` is MIT, copyright 2026 nesturbator contributors.
No upstream implementation or fixture is copied into libfuturo. Keep the
upstream license and copyright notice with any later source or binary
redistribution that includes this statically linked library.

## Compatibility is not one promise

The full source commit identifies this build input. It does not make these
separate compatibility questions interchangeable:

| Surface | Current evidence and limit |
|---|---|
| libfuturo source API | Experimental. Names, declarations, and behavior may change; this plan makes no stability promise. |
| Binary ABI | No stable plugin ABI or cross-build binary compatibility is promised. This probe links the source-built static library into the process. |
| nesturbator behavior | The pinned public header reports behavior revision 9, separately from ABI version 1 and library version 0.1.12. A source pin identifies the tested code, not interchangeable behavior across revisions. |
| Persistent media | The core exposes a mutable battery-backed memory span, not a durable save format or file operation. This plan does not prove cross-version save compatibility or host persistence. |
| Snapshots | libfuturo exposes no snapshot support through this probe. The source header names state format version 3, but that does not promise snapshot interchangeability. Restore remains future, optional work and requires evidence that refusal preserves the active machine and committed progress. |

## Adapter seams from the public source

These are source observations from the pinned public header and the retained
read-only integration review. They are not runtime results from this probe.

| Seam | Source observation | Later adapter boundary |
|---|---|---|
| Input | Two NES button masks are sampled when `nesturbator_run_frame` starts. | Set both masks before each frame call; do not promise sub-frame input changes. |
| Guest time | Work is frame-oriented. Reported half-master-clock ticks and frame number are cumulative; instruction completion can overshoot the nominal frame target. | Preserve the frame unit and actual progress. Do not interpret cumulative ticks as a per-call delta or as a wall-clock deadline. |
| Video | The caller supplies `uint16_t` pixels for 256×240 output and a pitch in pixels. The API has no allocation-capacity argument. | Check pitch and overflow when computing the required `pitch × 240 × sizeof(uint16_t)` allocation before calling the core. Copy or convert into the libfuturo-owned output extent. |
| Audio | Caller-owned mono signed-16 PCM at 48,000/1 Hz; completed frames produce 798 or 799 samples. | Treat capacity as a sample count and report the actual count, encoding, rate, and mono layout. |
| Battery memory | `nesturbator_get_memory` returns a mutable pointer and size. It becomes invalid at unload, a later successful cartridge load, or destroy. The core does no file I/O. | Validate content identity and exact size, copy into host-owned storage, and reacquire after invalidating calls. Import only after load and before the first frame. |
| Save generation | The counter tracks guest CPU writes. A host copy into the mutable span does not increment it. | Do not interpret host restore as guest progress or treat the counter as a durable-write acknowledgment. |

Phase 2 owns cartridge load, input, frame execution, A/V, and close through the
consumer boundary. Phase 3 owns game-written progress across fresh host
processes and failed host-write preservation. Neither is established by this
source map or by a create/destroy probe.

## Bounded probe result

`./scripts/check.sh` is the reproducible local command. It requires the named
CTest `nesturbator_probe`, which builds a libfuturo-owned C17 consumer, checks
the compiled source revision, creates one instance with the zeroed public
configuration, destroys it, and prints a lifecycle marker. The full canonical
run also retains the two synthetic tests. It does not load a cartridge, run a
frame, inspect save memory, or call snapshot APIs.

On the observed macOS 26.6.2 arm64 profile, Apple Clang 21.0.0.21000101,
CMake/CTest 4.4.3, and macOS SDK 26.5 were used. The initial cold FetchContent
populate plus CMake configure took 3.2 seconds; the later warm full
`./scripts/check.sh` run took 2.9 seconds. The script bounds configure plus
dependency fetch to 300 seconds, the required build to 180 seconds, and the
probe test to 15 seconds; Git connection and low-speed limits bound stalled
transfers sooner.

The exact command and required test scope are documented in the
[developer guide](development.md). Local logs and reports are build outputs,
not source artifacts.
