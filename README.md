# libfuturo

libfuturo is an experimental C interface for integrating console emulator cores
with hosts. Its current source-tree proof runs a public C host against the
deterministic `synthetic-v1` development profile. This profile is a conformance
fixture; it does not emulate console hardware or qualify a real core.

## Try the local consumer

From the repository root, run [`./scripts/check.sh`](scripts/check.sh). The
script configures and builds the selected macOS arm64 profile, then executes
the required CTest suite. See [developer instructions](docs/development.md) for
prerequisites, output locations, each test's purpose, and the evidence limits.

The C example is [`examples/synthetic/main.c`](examples/synthetic/main.c). It
uses the public SDK header at [`include/libfuturo/libfuturo.h`](include/libfuturo/libfuturo.h).
The profile rules, formats, ownership, errors, and literal session are in
[`docs/synthetic-profile.md`](docs/synthetic-profile.md).

## Compatibility and evidence

The API is experimental. Source declarations may change; no stable binary or
plugin ABI is promised. `synthetic-v1` defines its own behavior and in-memory
media identity. That does not establish behavior compatibility with real
cores, durable save formats, or machine snapshot compatibility. Snapshots are
unsupported. See the profile and developer guide for the exact tested scope.

The separate [nesturbator seam map](docs/nesturbator-seams.md) records source
observations and the bounded create/destroy probe. That probe does not exercise
cartridge loading, frames, audio/video, durable saves, or restore. The installed
and relocated consumer journey remains Phase 4 work.

The GitHub Actions workflow is manual-only and gated by a repository variable.
Its first approved public `macos-15` run passed on the published source
candidate. See [CI activation](docs/ci-activation.md) for the exact source SHA,
runner identity, test results, and cost policy.
