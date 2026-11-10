# GitHub Actions CI configuration

## Recurring workflows

Two separate workflows now provide recurring qualification coverage:

| Workflow | Stable job check name | Runner | Canonical command |
|---|---|---|---|
| Native validation | `macOS arm64 native checks` | `macos-15` | `./scripts/check.sh` |
| Browser qualification | `Linux browser qualification` | `ubuntu-24.04` | `./scripts/check-browser-package.sh` |

Both workflows run on pull requests, pushes to `main`, manual dispatch, and
merge-queue `checks_requested` events. The jobs are unconditional and have a
20-minute timeout. Each grants only `contents: read`, checks out source using
the verified full `actions/checkout` v7.0.1 commit, and disables persisted
checkout credentials. The native workflow retains its existing same-workflow,
same-ref cancellation policy. The browser workflow has one job and runs the
full no-argument package qualification route; it does not use a matrix,
aggregator, extra cache action, or artifact upload.

The Linux script runs the browser qualification unit tests and discovers all
`*-contract.test.mjs` files from the committed source archive before compiling.
It explicitly excludes `host-lifecycle.tdd.test.mjs`, which starts another
full browser build. The canonical native script remains unchanged and checks
its own workflow contract, including its existing event mutation controls.

These are workflow definitions, not hosted-run evidence. The recurring Linux
workflow and its merge-queue path still need their first hosted run. Plan 03-05
owns that qualification and the current hosted measurements. Until then, the
stable check names describe the configured jobs; no current hosted result is
claimed here.

## What GitHub enforcement is visible

The workflows make the checks run, but branch protection is separate
repository administration. The available branch-protection read path returned
HTTP 403, so required-check configuration could not be inspected. No branch
rule was changed, and this document does not claim either check is required
for merging. A repository administrator would need to make that setting
observable before required-check enforcement could be verified.

GitHub documents that skipped jobs report success, including when a check is
required. These jobs therefore have no job or step conditions, path filters,
or success-masking settings. Their workflow triggers and commands are covered
by dependency-free local mutation tests. That local configuration proof does
not establish GitHub-side required-check settings or replace a hosted run.
See [workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)
and [status checks](https://docs.github.com/en/pull-requests/reference/status-checks).

## Historical native hosted run

The prior manual activation was a bounded check of an earlier native-only
source candidate. It is retained as historical evidence, not evidence that the
current recurring configuration or browser route ran:

- Repository: [`szTheory/libfuturo`](https://github.com/szTheory/libfuturo);
  public visibility was verified before that run.
- Run: [41255584562](https://github.com/szTheory/libfuturo/actions/runs/41255584562),
  `workflow_dispatch` on `main`; conclusion `success`, with no skipped job or
  required step.
- Source commit: `c11145bb5b4197c5a65ef8cc570f1eededdd7ea4`, the reviewed
  source-only candidate for that earlier native workflow.
- Runner image: `macos-15`, image `20261028.0489.1`, macOS 15.8.2 arm64,
  Apple Clang 17.0.0 (`clang-1700.0.13.5`), CMake/CTest 4.4.4, macOS SDK 15.5.
- `./scripts/check.sh` passed. The job took 18 seconds; CTest reported
  1.02 seconds.

That run covered the native source-tree route on its recorded runner. It did
not qualify browser play, installation or relocation, real-core sessions, or
the current workflow files.
