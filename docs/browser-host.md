# Browser host qualification

This guide describes one reproducible browser route through the installed
`libfuturo::web` consumer. Its evidence applies to the exact source, generated
Muhtari diagnostic, Emscripten package and Chrome for Testing Headless Shell
listed below. It does not establish general browser compatibility.

## Prerequisites and canonical command

You need Git, Docker with Linux/amd64 container support, and public network
access for the pinned core source, Emscripten image, Chrome for Testing archive,
and browser runtime package indexes. The route generates its own licensed test
content; no commercial ROM or BIOS is needed.

From the repository root, run the no-argument route:

```sh
./scripts/check-browser-package.sh
```

A clean checkout is required, including no untracked files. The script refuses
a dirty checkout, records the source commit and tree, and builds from a
read-only archive of that committed revision. This keeps the reported source
identity aligned with the files compiled by the container.

The default route builds the package and relocated consumer once, then runs the
complete seven-scenario inventory without rebuilding between scenarios:

| Scenario | Evidence focus |
| --- | --- |
| `identity` | Public package identity and refusal of a mismatched identity before content load. |
| `host-tracer` | A started session advances through the public consumer with expected frame and audio observations. |
| `host-content` | Generated-content selection, refusal and retry behavior, rendered output and local-file handling. |
| `host-input` | Trusted keyboard input and release behavior. |
| `host-input-audio` | Public PCM checks, Web Audio graph setup and interruption handling. |
| `host-lifecycle` | Hide/restore lifecycle, input and audio retirement, explicit resume and teardown behavior. |
| `host-ui` | User-visible status, controls, keyboard behavior and runtime-error reporting. |

The script also supports `--compile-only`, `--package-only`, `--consumer-only`,
and `--scenario=<name>` for diagnosis. These are diagnostic-only focused modes
and do not replace the no-argument route: a successful single scenario or build
stage is not a complete browser qualification.

## Qualified row and build settings

The route fixes these inputs in the script, relocated-consumer configuration
and qualification inventory. The contract test reads the values from those
files so the guide cannot silently drift from the executable route.

| Input | Qualified value |
| --- | --- |
| Core | Muhtari `0.11.1`, source `d58f125297c4d63a7a8108112a5eafff6f53a76a` |
| Contract tuple | API 8, ABI 1, behavior 6 |
| Profile and configuration | `muhtari-ntsc-v2`; `muhtari-ntsc-battery-diagnostic` |
| Generated fixture | `generated-muhtari-a78-api8-v1`, 16,512 bytes, SHA-256 `136cbead3da4bde24ea23acf36eb8daacced88074bbe021888aa4e17d987195e` |
| Emscripten SDK | `emscripten/emsdk:7.0.0@sha256:6bd7aef93408b10bf7b36642cb7c91119b302f720b9ec2d20439f73cf07fe894` |
| SDK platform | Requested and resolved as `linux/amd64` |
| Browser | Chrome for Testing Headless Shell `157.0.8103.50`, revision `1717349`; archive SHA-256 `7bf0d41e424efd1d6281c4162993ab9dc5de92fac213c211614905a71c057d0f` |

Chrome's [Headless mode](https://developer.chrome.com/docs/automation-and-testing/headless)
runs without a visible browser window. The route uses the separately distributed
[Chrome for Testing](https://developer.chrome.com/docs/automation-and-testing/chrome-for-testing)
Headless Shell and verifies its downloaded archive digest and reported version.
This is one pinned browser row, not a claim about other Chrome releases or
browsers.

The relocated consumer's actual link command selects `-sENVIRONMENT=web`,
`-sEXPORTED_RUNTIME_METHODS=HEAPU8,HEAP16`, and keeps the Emscripten runtime
alive after `main` with `-sEXIT_RUNTIME=0`. The browser is launched with `--no-sandbox`,
`--disable-gpu`, and `--disable-dev-shm-usage` for this controlled test
environment. Those are route-specific launch settings: they make no production
sandbox claim and provide no GPU-rendering qualification. Do not copy them as
production deployment guidance.

The report distinguishes the outer local or GitHub Actions runner from the
Linux/amd64 SDK container and records the Docker daemon and resolved toolchain
identities. It records the browser runtime package inventory as
`installed-unpinned`: the resolved apt packages are observed, but their
versions are not independently pinned. Identity and hashes support lineage
and mismatch detection; they are not authentication or attestation.

## Reports and pass interpretation

The ignored run directory is `build/browser-package/<run-id>/`. The aggregate
qualification report is
`build/browser-package/<run-id>/evidence/browser-qualification.json`; the
relocated consumer report and route log are alongside it. Per-scenario browser
reports and logs are under the `evidence/qualification/` subdirectory. These
files are local generated evidence, not source inputs.

Treat the browser route as passed only when the aggregate reports
`qualification-pass`, binds the consumer and browser reports to the same source
and run identity, and validates all seven attempt-one scenarios as passed. The
script's final `Result: PASS` is its exit result; focused mode success, package
build success or an individual scenario report is not the aggregate result.
The report records local and hosted runner facts differently. A local run does
not establish a hosted result, and workflow configuration alone does not show
that hosted jobs passed or that repository branch protection requires them.

## Evidence limits

- Qualification is limited to the generated fixture only. The browser route
  does not qualify arbitrary games, cartridge boards, firmware or user files.
- Battery media is session-only and exists only in the live browser session. The route has no
  browser save or snapshot path and does not qualify persistent battery or
  machine-state recovery. Native snapshot evidence is described separately in
  the [Muhtari profile](muhtari-profile.md); it does not transfer to this route.
- Audio assertions observe PCM and its Web Audio graph; this is graph-only audio
  evidence. The
  [Web Audio API](https://www.w3.org/TR/webaudio-1.0/) is a software audio
  processing interface; this route does not qualify physical speakers or
  device output.
- The lifecycle route records a same-origin back/forward-cache probe, but the
  pinned delegate reports `BackForwardCacheDisabledForDelegate` and records
  BFCache restoration as not qualified.
- This route provides no cross-browser qualification. It provides no mobile
  qualification, hardware qualification, broad Wasm-target qualification or
  GPU-rendering qualification. It carries no stable ABI or software-release
  promise.
- The core runs in-process in the test consumer. This route does not establish
  crash isolation or a production browser security boundary.

For the recurring workflow configuration and its recorded hosted evidence,
see [CI activation](ci-activation.md). The phase evidence remains the source of
truth for which exact committed revision completed local and hosted runs.
