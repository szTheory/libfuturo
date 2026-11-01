# GitHub Actions preparation and activation record

**Status:** Local configuration and source-only candidate review are complete.
Repository publication, workflow activation, and hosted execution remain
stopped pending the maintainer's decision on the exact package.

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

The proposed acceptance route is one manual dispatch after the repository's
public visibility and account prerequisites are rechecked. No recurring
trigger, retry, cache, or artifact upload is configured. Account-specific plan,
usage, and budget evidence belongs in the private execution record, not this
public-facing document. Hosted duration remains unmeasured, and local timing is
not a hosted billing estimate.

Official policy checked on 2026-10-31: [GitHub Actions billing and usage](https://docs.github.com/en/actions/concepts/billing-and-usage),
[GitHub-hosted runner specifications](https://docs.github.com/en/actions/reference/runners/github-hosted-runners),
and [Actions runner pricing](https://docs.github.com/en/billing/reference/actions-runner-pricing).

## Current status

This checkout has only been verified locally. No hosted job has run, so this
document makes no claim about hosted results or account-specific costs. Before
using the workflow, confirm the repository visibility and account prerequisites
for the selected runner, then set the activation variable as part of the
repository's CI review. Do not enable recurring triggers or retries without a
separate review.
