# libfuturo

libfuturo is an experimental C interface for integrating console emulator cores
with hosts. Its public C examples cover the deterministic `synthetic-v1`
profile and two pinned real-core profiles: Nesturbator for NES and the optional
`muhtari-ntsc-v1` Atari 7800 joystick session. The synthetic profile is a
conformance fixture; it does not emulate console hardware or qualify hardware
accuracy. Muhtari remains disabled in the base SDK unless a consumer opts in.

## Try the local consumer

From the repository root, run [`./scripts/check.sh`](scripts/check.sh). It
configures and builds the selected local macOS arm64 profile, then executes the
required CTest suite, including installed real-core sessions, package-boundary
checks, and failure controls.
See [developer instructions](docs/development.md) for prerequisites, output
locations, required modes, and evidence limits.

To qualify the separate browser package and host, run
[`./scripts/check-browser-package.sh`](scripts/check-browser-package.sh) from a
clean checkout. The exact prerequisites, seven scenarios, report location and
limits are in the [browser-host guide](docs/browser-host.md).

The C examples are [`examples/synthetic/main.c`](examples/synthetic/main.c)
and [`examples/muhtari/main.c`](examples/muhtari/main.c). They use the public SDK header at
[`include/libfuturo/libfuturo.h`](include/libfuturo/libfuturo.h). The synthetic
profile rules, formats, ownership, errors, and literal session are in
[`docs/synthetic-profile.md`](docs/synthetic-profile.md).

## Compatibility and evidence

The API is experimental. Source declarations may change; no stable binary or
plugin ABI is promised. `synthetic-v1` defines its own behavior and in-memory
media identity; it does not establish compatibility with real cores, durable
save formats, or machine snapshots.

The selected real-core profiles, limits, and measured public-consumer behavior
are in [`docs/nesturbator-profile.md`](docs/nesturbator-profile.md) and
[`docs/muhtari-profile.md`](docs/muhtari-profile.md). The shared experimental
source contract is in [`docs/contract.md`](docs/contract.md). The
[`seam and fixture provenance record`](docs/nesturbator-seams.md) names the
exact source pin and project-authored generated-cartridge recipe. The real
consumer loads that NROM, samples input, advances complete frames, and checks
literal RGB24 and silent PCM output through the public C boundary. Its failure
modes test refused loads, bounded output, and the terminal JAM state.

The Muhtari consumer loads a project-authored diagnostic, checks the two
joystick ports, partial startup progress, steady cadence, raw INDEX8 output and
PCM, and verifies refused-load continuation and selected bounds. The public
[`muhtari_host` example](examples/muhtari/main.c) uses the same declared profile
metadata and host-owned buffers. It does not apply a palette or claim battery
recovery.

The local route also verifies game-save restoration across fresh processes,
recovery from a controlled pre-rename write failure, and the same journey from
a relocated SDK/core installation. This does not establish OS-crash or
power-loss durability. The Muhtari base-package check also proves that a
default-off installed consumer needs no Muhtari artifacts or link dependency.
No other target or hardware accuracy is qualified.

The native and Linux browser GitHub Actions workflows are configured for pull
requests, pushes to `main`, manual dispatch, and merge-queue checks. See
[CI activation](docs/ci-activation.md) for workflow details and the recorded
hosted results. A local pass or workflow definition alone does not establish a
hosted pass or required branch protection.
