# Local development

## Prerequisites and supported local profile

The current required native profile is macOS on Apple Silicon (`Darwin/arm64`).
The canonical script rejects other OS/architecture combinations; that does not
mean other platforms are inherently unsupported, only that this repository has
not selected or qualified them yet.

Install or provide:

- A C17 compiler. The selected local profile uses Apple Clang from the macOS
  Command Line Tools or Xcode.
- The macOS SDK and `xcrun`/`sw_vers` utilities supplied by Apple's developer
  tools.
- CMake 3.25 or newer. CTest is included with CMake.
- Git, for the pinned source checkout and source identity.
- Network access to the public `szTheory/nesturbator` Git repository on the
  first configure when its FetchContent source is not already in the build
  tree.

## Build and run the required checks

Run this command from the checkout root:

```sh
./scripts/check.sh
```

It configures a Debug build for arm64 using the Clang and SDK selected by
`xcrun`, builds the project's required targets, and runs every required CTest.
The C host and tests include only the public `include/` directory; they do not
depend on implementation-private headers or UI/device libraries.

Build products, the CTest log, and the JUnit report are written under
`build/check/`. The first run may fetch the exact public nesturbator source pin
`2338608ab184f040620a30d17756f5e06a42d4e3`; repeat runs reuse the populated
build tree and reconfigure, rebuild, and rerun the checks. Removing `build/`
means the next run must fetch that source again.

The script records the observed macOS product/version, `uname` OS and
architecture, Apple Clang path/version, CMake and CTest versions, and SDK
version/path. On GitHub-hosted runners it also prints the provided `ImageOS`
and `ImageVersion` values. These identify the image and tools actually used for
that run; the workflow's `macos-15` label selects an OS major and arm64 runner,
but the hosted image and tool patches remain provider-managed.

The project targets C17 and enables compiler warnings, assertions (`-UNDEBUG`),
AddressSanitizer, and UndefinedBehaviorSanitizer for project-owned targets. The
canonical route requires these five named tests to be registered and pass:

| Test | What it checks |
| --- | --- |
| `synthetic_tracer` | Runs the public C example through the synthetic profile. |
| `synthetic_session` | Compares the prescribed input, guest progress, stop result, audio, video, and in-memory media against independent literal expectations. |
| `synthetic_boundaries` | Exercises lifecycle and allocation failures, invalid requests, guest-work limits, output capacities, overflow rejection, and buffer preservation. |
| `oracle_negative_control` | Proves the session oracle rejects a deliberately wrong expected video byte through its normal comparison path. |
| `nesturbator_probe` | Builds the exact pinned source and creates/destroys one instance through its public C API. It does not load a cartridge or run a frame. |

A missing, disabled, skipped, or failed required test makes the script fail.
Sanitizer diagnostics also fail the route. The negative-control test is
expected to pass only when its internal wrong-value run fails with the exact
video-mismatch result; it is not evidence of a production failure.

## Scope of the evidence

This command tests source-tree consumers on the selected local macOS arm64
profile. The synthetic profile's work unit, formats, and in-memory media are
not general promises about real cores. The nesturbator test is a bounded
create/destroy probe only. No cartridge/frame session, durable save recovery,
installed or relocated package, browser host, or other target is qualified by
this route. Installation and relocation acceptance is reserved for Phase 4.

The workflow in [CI activation](ci-activation.md) invokes this same command on
the selected hosted runner. It is prepared for review but has not been
activated or executed; a skipped or absent hosted job is unrun evidence, not a
passing result.
