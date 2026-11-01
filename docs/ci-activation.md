# GitHub Actions preparation and activation record

**Status:** The approved source-only candidate is public, the activation gate is
enabled, and one bounded manual hosted run passed. The workflow remains
manual-only; no recurring trigger or retry is configured.

## Prepared configuration

The proposed job uses the standard GitHub-hosted `macos-15` runner. GitHub's
current runner reference lists that label as macOS arm64 on a 3-core M1 with
7 GB RAM. The label holds the OS major and architecture, not a frozen image or
compiler patch. Each actual run must log the provider image version, macOS
version, Clang, CMake/CTest, and SDK. The canonical script records these values
and invokes the same `./scripts/check.sh` route used locally.

The workflow is manual-dispatch only. Its single job runs only when the
repository variable `LIBFUTURO_CI_ACTIVATED` is exactly `true`, has a bounded
20-minute timeout, and cancels a previous run of this workflow on the same ref.
The job grants only `contents: read`. Its checkout step pins the official
[`actions/checkout` v7.0.1 release](https://github.com/actions/checkout/releases/tag/v7.0.1)
to full commit
[`3d3c42e5aac5ba805825da76410c181273ba90b1`](https://github.com/actions/checkout/commit/3d3c42e5aac5ba805825da76410c181273ba90b1)
and sets `persist-credentials: false`. The full SHA was checked against the
public tag in the official `actions/checkout` repository on 2026-10-31.

The workflow calls no second configure, build, or test recipe. A job skipped by
the activation guard, or a workflow that has not been dispatched, is unrun
evidence and never a required passing check. The local CMake contract checker
verifies the selected runner, manual trigger, read-only permission, full-SHA
checkout, disabled credential persistence, activation guard, and canonical
command before the local build starts. The checker passed the authored file and
rejected a temporary copy whose only change replaced the canonical command.
That is a local configuration check, not GitHub-side workflow validation or a
hosted run.

GitHub's [workflow syntax reference](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)
documents manual `workflow_dispatch`, job permissions, timeouts, and
same-ref concurrency. The workflow is deliberately not configured for push or
pull-request events. Adding those triggers requires the later activation
review and is not part of this local preparation.

## Cost boundary

GitHub's current policy says standard hosted runner usage is free for public
repositories. The standard `macos-15` runner is arm64 (M1, 3 cores, 7 GB). For
private repositories, the published standard macOS rate is `$0.062/minute`,
with partial job minutes rounded up. The configured 20-minute timeout therefore
bounds a private-run estimate at `$1.24` before any included compute; this is a
policy calculation, not an account-specific bill or authorization to run
privately.

The approved acceptance route was one manual dispatch after the repository's
public visibility and account prerequisites were rechecked. No recurring
trigger, retry, cache, or artifact upload is configured. Account-specific plan,
usage, and budget evidence belongs in the private execution record, not this
public-facing document.

Official policy checked on 2026-10-31: [GitHub Actions billing and usage](https://docs.github.com/en/actions/concepts/billing-and-usage),
[GitHub-hosted runner specifications](https://docs.github.com/en/actions/reference/runners/github-hosted-runners),
and [Actions runner pricing](https://docs.github.com/en/billing/reference/actions-runner-pricing).

## Hosted verification

- Repository: [`szTheory/libfuturo`](https://github.com/szTheory/libfuturo),
  public visibility verified before activation.
- Run: [41255584562](https://github.com/szTheory/libfuturo/actions/runs/41255584562),
  `workflow_dispatch` on `main`; conclusion `success`, with no skipped job or
  required step.
- Source commit: `c11145bb5b4197c5a65ef8cc570f1eededdd7ea4` (the reviewed
  source-only candidate tree).
- Runner image: `macos-15`, `macos15` image `20261028.0489.1`, macOS 15.8.2
  arm64, Apple Clang 17.0.0 (`clang-1700.0.13.5`), CMake/CTest 4.4.4,
  macOS SDK 15.5.
- `./scripts/check.sh` passed. `synthetic_tracer`, `synthetic_session`,
  `oracle_negative_control`, `synthetic_boundaries`, and `nesturbator_probe`
  all executed and passed. CTest reported 1.02 seconds; the hosted job took
  18 seconds.
- This was the single approved run. Standard hosted-runner compute for a
  public repository is free under the current GitHub policy. No cache or
  artifact storage was configured.

This verifies the selected source-tree route on the published arm64 runner. It
does not qualify installation, relocation, browser play, or the deferred
real-core session and save behaviors.
