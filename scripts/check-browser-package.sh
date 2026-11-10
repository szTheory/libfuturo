#!/usr/bin/env bash
set -euo pipefail

monotonic_now_ns() {
  perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC \
    -e 'printf "%.0f\n", clock_gettime(CLOCK_MONOTONIC) * 1e9'
}

elapsed_seconds() {
  awk -v start_ns="$1" -v end_ns="$2" \
    'BEGIN { delta = (end_ns - start_ns) / 1000000000; if (delta < 0) exit 2; printf "%.6f\n", delta }'
}

readonly OUTER_ROUTE_START_NS="$(monotonic_now_ns)"
readonly LIBFUTURO_RETURN_UID="$(id -u)"
readonly LIBFUTURO_RETURN_GID="$(id -g)"

readonly SDK_IMAGE='emscripten/emsdk:7.0.0@sha256:6bd7aef93408b10bf7b36642cb7c91119b302f720b9ec2d20439f73cf07fe894'
readonly SDK_PLATFORM='linux/amd64'
readonly CFT_VERSION='157.0.8103.50'
readonly CFT_REVISION='1717349'
readonly CFT_ARCHIVE='chrome-headless-shell-linux64.zip'
readonly CFT_URL="https://storage.googleapis.com/chrome-for-testing-public/${CFT_VERSION}/linux64/${CFT_ARCHIVE}"
readonly CFT_SHA256='7bf0d41e424efd1d6281c4162993ab9dc5de92fac213c211614905a71c057d0f'

usage() {
  cat <<'USAGE'
Usage: scripts/check-browser-package.sh
       scripts/check-browser-package.sh --compile-only
       scripts/check-browser-package.sh --package-only
       scripts/check-browser-package.sh --consumer-only
       scripts/check-browser-package.sh --scenario=host-tracer|host-content|host-input|host-input-audio|host-lifecycle|host-ui

Builds the exact Muhtari API 8 adapter and package archive with the digest-pinned
Emscripten 7.0.0 SDK image. The package mode also installs, relocates and inspects
the exported browser package. Consumer mode also links a relocated public
consumer into final JavaScript/WebAssembly artifacts. With no option, the full
route also serves those moved artifacts to the pinned Chrome for Testing browser
for identity and all six host scenarios without rebuilding the package.
USAGE
}

SCENARIO=identity
SOURCE_SNAPSHOT="${LIBFUTURO_SOURCE_SNAPSHOT:-archived-head}"
if [[ $# -gt 1 ]]; then
  usage >&2
  exit 2
fi
if [[ $# -eq 1 ]]; then
  case "$1" in
    --compile-only|--package-only|--consumer-only) ;;
    --scenario=host-tracer) SCENARIO=host-tracer ;;
    --scenario=host-content|--scenario=host-input|--scenario=host-input-audio|--scenario=host-lifecycle|--scenario=host-ui) SCENARIO="${1#--scenario=}" ;;
    *) usage >&2; exit 2 ;;
  esac
fi
BUILD_PACKAGE=false
PACKAGE_ONLY=false
BUILD_CONSUMER=false
RUN_BROWSER=false
RUN_FULL_SUITE=false
if [[ $# -eq 0 ]]; then
  BUILD_PACKAGE=true
  BUILD_CONSUMER=true
  RUN_BROWSER=true
  RUN_FULL_SUITE=true
else
  case "$1" in
    --package-only)
      BUILD_PACKAGE=true
      PACKAGE_ONLY=true
      ;;
    --consumer-only)
      BUILD_PACKAGE=true
      BUILD_CONSUMER=true
      ;;
  esac
fi
if [[ "$SCENARIO" != identity ]]; then
  BUILD_PACKAGE=true
  BUILD_CONSUMER=true
  RUN_BROWSER=true
fi
readonly BUILD_PACKAGE PACKAGE_ONLY BUILD_CONSUMER RUN_BROWSER RUN_FULL_SUITE

readonly ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$ROOT_DIR" ]]; then
  printf '%s\n' 'error: could not determine the repository root' >&2
  exit 2
fi
readonly SOURCE_REVISION="$(git -C "$ROOT_DIR" rev-parse HEAD)"
readonly SOURCE_TREE="$(git -C "$ROOT_DIR" rev-parse "$SOURCE_REVISION^{tree}")"
if [[ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all)" ]]; then
  printf '%s\n' \
    'error: browser package builds require a clean checkout so the source SHA matches the compiled files' >&2
  git -C "$ROOT_DIR" status --short >&2
  exit 2
fi

readonly BROWSER_CACHE_DIR="${LIBFUTURO_BROWSER_CACHE_DIR:-$ROOT_DIR/build/browser-host-cache}"
mkdir -p "$BROWSER_CACHE_DIR"
readonly SDK_IMAGE_DIGEST="${SDK_IMAGE##*@sha256:}"
readonly SDK_CACHE_PLATFORM="${SDK_PLATFORM//\//-}"
readonly APT_CACHE_DIR="$BROWSER_CACHE_DIR/apt-cache-v1/$SDK_CACHE_PLATFORM/$SDK_IMAGE_DIGEST"
mkdir -p "$APT_CACHE_DIR/lists/partial" "$APT_CACHE_DIR/archives/partial"
chmod 1777 "$APT_CACHE_DIR/lists/partial" "$APT_CACHE_DIR/archives/partial"
# Keep apt's authenticated package archives in this digest-keyed local cache.
# The pinned SDK image's docker-clean hook otherwise deletes the mounted .debs.
readonly APT_CACHE_CONFIG="$APT_CACHE_DIR/keep-archives.conf"
if [[ -L "$APT_CACHE_CONFIG" || ( -e "$APT_CACHE_CONFIG" && ! -f "$APT_CACHE_CONFIG" ) ]]; then
  printf '%s\n' 'error: apt archive retention config is not a regular file' >&2
  exit 2
fi
if [[ ! -e "$APT_CACHE_CONFIG" ]]; then
  (umask 022; : > "$APT_CACHE_CONFIG")
fi
if [[ -s "$APT_CACHE_CONFIG" ]]; then
  printf '%s\n' 'error: apt archive retention config must remain empty' >&2
  exit 2
fi

readonly RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
readonly RUN_DIR="$ROOT_DIR/build/browser-package/$RUN_ID"
readonly SOURCE_DIR="$RUN_DIR/source"
readonly EVIDENCE_DIR="$RUN_DIR/evidence"
readonly ROUTE_LOG="$EVIDENCE_DIR/compile-route.log"

if ! (cd "$ROOT_DIR" && git check-ignore -q build/browser-package/route/evidence.log); then
  printf '%s\n' 'error: build/ is not ignored; refusing to write generated browser artifacts there' >&2
  exit 2
fi
mkdir -p "$EVIDENCE_DIR" "$SOURCE_DIR"
readonly DOCKER_DAEMON_PLATFORM="$(docker info --format '{{.OSType}}/{{.Architecture}}')"
if [[ -z "$DOCKER_DAEMON_PLATFORM" ]]; then
  printf '%s\n' 'error: Docker daemon platform could not be observed' >&2
  exit 2
fi
export SOURCE_REVISION SOURCE_TREE SOURCE_SNAPSHOT DOCKER_DAEMON_PLATFORM EVIDENCE_DIR
node -e '
  const fs = require("node:fs");
  const os = require("node:os");
  const github = process.env.GITHUB_ACTIONS === "true";
  const required = ["GITHUB_SHA", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_WORKFLOW", "GITHUB_JOB", "GITHUB_EVENT_NAME"];
  if (github) {
    const missing = required.filter(name => !process.env[name]);
    if (missing.length) throw new Error(`missing hosted identity fields: ${missing.join(", ")}`);
    if (process.env.GITHUB_SHA !== process.env.SOURCE_REVISION) throw new Error("GITHUB_SHA does not match compiled source revision");
    if (process.env.GITHUB_RUN_ATTEMPT !== "1") throw new Error("hosted qualification requires GITHUB_RUN_ATTEMPT=1");
  }
  const fact = (name, applicable) => ({
    applicability: applicable ? (process.env[name] ? "observed" : "not-provided") : "not-applicable",
    value: applicable ? (process.env[name] || null) : null,
  });
  const record = {
    outer_runner: {
      kind: github ? "github-actions" : "local",
      os: github ? process.env.RUNNER_OS.toLowerCase() : os.platform(),
      architecture: github ? process.env.RUNNER_ARCH.toLowerCase() : os.arch(),
      runner_name: fact("RUNNER_NAME", github),
      image_version: fact("ImageVersion", github),
      github_actions: github ? {
        applicability: "applicable", sha: process.env.GITHUB_SHA,
        run_id: process.env.GITHUB_RUN_ID, run_attempt: Number(process.env.GITHUB_RUN_ATTEMPT),
        workflow: process.env.GITHUB_WORKFLOW, job: process.env.GITHUB_JOB,
        event_name: process.env.GITHUB_EVENT_NAME,
      } : {
        applicability: "not-applicable", sha: null, run_id: null, run_attempt: null,
        workflow: null, job: null, event_name: null,
      },
    },
    docker_daemon: { platform: process.env.DOCKER_DAEMON_PLATFORM },
  };
  if (!record.outer_runner.os || !record.outer_runner.architecture) throw new Error("runner OS and architecture are required");
  fs.writeFileSync(`${process.env.EVIDENCE_DIR}/runner-observations.json`, `${JSON.stringify(record, null, 2)}\n`, { mode: 0o600 });
'
if ! git -C "$ROOT_DIR" archive --format=tar "$SOURCE_REVISION" |
    tar -xf - -C "$SOURCE_DIR"; then
  printf '%s\n' 'error: could not materialize the committed source snapshot' >&2
  exit 1
fi

printf 'SDK image: %s\n' "$SDK_IMAGE"
printf 'Requested image platform: %s\n' "$SDK_PLATFORM"
printf 'Docker daemon platform: %s\n' "$DOCKER_DAEMON_PLATFORM"
if [[ "$DOCKER_DAEMON_PLATFORM" != "$SDK_PLATFORM" ]]; then
  printf 'Platform emulation: enabled by Docker for the %s image\n' "$SDK_PLATFORM"
fi
printf 'LibFuturo source revision: %s\n' "$SOURCE_REVISION"
printf 'Source snapshot kind: %s\n' "$SOURCE_SNAPSHOT"
printf '%s\n' 'Build source: read-only archive of that committed revision'
printf 'Run directory: %s\n' "${RUN_DIR#"$ROOT_DIR"/}"

PINNED_IMAGE_DIGEST="${SDK_IMAGE##*@sha256:}"
LOCAL_IMAGE_PLATFORM="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$SDK_IMAGE" 2>/dev/null || true)"
LOCAL_IMAGE_REPO_DIGESTS="$(docker image inspect --format '{{json .RepoDigests}}' "$SDK_IMAGE" 2>/dev/null || true)"
if [[ "$LOCAL_IMAGE_PLATFORM" == "$SDK_PLATFORM" &&
      "$LOCAL_IMAGE_REPO_DIGESTS" == *"@sha256:$PINNED_IMAGE_DIGEST"* ]]; then
  SDK_IMAGE_CACHE_STATUS=verified-hit
  printf 'Reusing locally cached SDK image after exact digest and platform verification.\n'
else
  SDK_IMAGE_CACHE_STATUS=miss
  printf 'Fetching pinned SDK image because the exact digest/platform is not cached locally.\n'
  if ! docker pull --platform "$SDK_PLATFORM" "$SDK_IMAGE" >"$EVIDENCE_DIR/image-pull.log" 2>&1; then
    cat "$EVIDENCE_DIR/image-pull.log" >&2
    printf 'error: could not pull required SDK image; diagnostics: %s\n' \
      "${EVIDENCE_DIR#"$ROOT_DIR"/}/image-pull.log" >&2
    exit 1
  fi
  cat "$EVIDENCE_DIR/image-pull.log"
fi

readonly RESOLVED_IMAGE_PLATFORM="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$SDK_IMAGE")"
if [[ "$RESOLVED_IMAGE_PLATFORM" != "$SDK_PLATFORM" ]]; then
  printf 'error: pinned image resolved to %s, expected %s\n' \
    "$RESOLVED_IMAGE_PLATFORM" "$SDK_PLATFORM" >&2
  exit 1
fi
printf 'Resolved image platform: %s\n' "$RESOLVED_IMAGE_PLATFORM"

readonly OUTER_SETUP_END_NS="$(monotonic_now_ns)"
readonly OUTER_SETUP_SECONDS="$(elapsed_seconds "$OUTER_ROUTE_START_NS" "$OUTER_SETUP_END_NS")"

set +e
docker run --rm --platform "$SDK_PLATFORM" \
  -e LIBFUTURO_RETURN_UID="$LIBFUTURO_RETURN_UID" \
  -e LIBFUTURO_RETURN_GID="$LIBFUTURO_RETURN_GID" \
  -e LIBFUTURO_SDK_IMAGE="$SDK_IMAGE" \
  -e LIBFUTURO_SDK_PLATFORM="$SDK_PLATFORM" \
  -e LIBFUTURO_SDK_RESOLVED_PLATFORM="$RESOLVED_IMAGE_PLATFORM" \
  -e LIBFUTURO_OUTER_SETUP_SECONDS="$OUTER_SETUP_SECONDS" \
  -e LIBFUTURO_OUTER_SETUP_START_NS="$OUTER_ROUTE_START_NS" \
  -e LIBFUTURO_OUTER_SETUP_END_NS="$OUTER_SETUP_END_NS" \
  -e LIBFUTURO_SDK_IMAGE_CACHE_STATUS="$SDK_IMAGE_CACHE_STATUS" \
  -e LIBFUTURO_SOURCE_REVISION="$SOURCE_REVISION" \
  -e LIBFUTURO_SOURCE_TREE="$SOURCE_TREE" \
  -e LIBFUTURO_RUNNER_OBSERVATIONS=/work/evidence/runner-observations.json \
  -e LIBFUTURO_BUILD_PACKAGE="$BUILD_PACKAGE" \
  -e LIBFUTURO_PACKAGE_ONLY="$PACKAGE_ONLY" \
  -e LIBFUTURO_BUILD_CONSUMER="$BUILD_CONSUMER" \
  -e LIBFUTURO_RUN_BROWSER="$RUN_BROWSER" \
  -e LIBFUTURO_BROWSER_FULL_SUITE="$RUN_FULL_SUITE" \
  -e LIBFUTURO_BROWSER_SCENARIO="$SCENARIO" \
  -e LIBFUTURO_SOURCE_SNAPSHOT="$SOURCE_SNAPSHOT" \
  -e LIBFUTURO_BROWSER_CACHE_DIR=/browser-cache \
  -e LIBFUTURO_CFT_VERSION="$CFT_VERSION" \
  -e LIBFUTURO_CFT_REVISION="$CFT_REVISION" \
  -e LIBFUTURO_CFT_ARCHIVE="$CFT_ARCHIVE" \
  -e LIBFUTURO_CFT_URL="$CFT_URL" \
  -e LIBFUTURO_CFT_SHA256="$CFT_SHA256" \
  -v "$SOURCE_DIR:/src:ro" \
  -v "$RUN_DIR:/work" \
  -v "$BROWSER_CACHE_DIR:/browser-cache" \
  -v "$APT_CACHE_DIR/lists:/var/lib/apt/lists" \
  -v "$APT_CACHE_DIR/archives:/var/cache/apt/archives" \
  -v "$APT_CACHE_CONFIG:/etc/apt/apt.conf.d/docker-clean:ro" \
  -w /src \
  "$SDK_IMAGE" \
  bash -lc '
    set -euo pipefail

    monotonic_now_ns() {
      perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC \
        -e '"'"'printf "%.0f\n", clock_gettime(CLOCK_MONOTONIC) * 1e9'"'"'
    }

    elapsed_seconds() {
      awk -v start_ns="$1" -v end_ns="$2" \
        '"'"'BEGIN { delta = (end_ns - start_ns) / 1000000000; if (delta < 0) exit 2; printf "%.6f\n", delta }'"'"'
    }

    PACKAGE_CONFIGURE_SECONDS=0
    PACKAGE_BUILD_SECONDS=0
    PACKAGE_INSTALL_RELOCATION_SECONDS=0
    CONSUMER_CONFIGURE_SECONDS=0
    CONSUMER_BUILD_SECONDS=0
    BROWSER_SETUP_SECONDS=0
    printf "SDK image: %s\n" "$LIBFUTURO_SDK_IMAGE"
    printf "Requested platform: %s\n" "$LIBFUTURO_SDK_PLATFORM"
    printf "Container architecture: %s\n" "$(uname -m)"
    . /etc/os-release
    CONTAINER_OS_NAME="${PRETTY_NAME:-${NAME:-Linux}}"
    printf "emcc version:\n"
    emcc --version
    printf "Emscripten version: %s\n" "$(emcc --version | sed -n "1p")"
    printf "CMake version:\n"
    cmake --version | sed -n "1p"

    mapfile -t CONTRACT_TESTS < <(
      find /src/tests/browser -maxdepth 1 -type f \
        -name "*-contract.test.mjs" ! -name "host-lifecycle.tdd.test.mjs" -print |
        LC_ALL=C sort
    )
    if (( ${#CONTRACT_TESTS[@]} == 0 )); then
      printf "%s\n" "error: no browser contract tests were discovered" >&2
      exit 2
    fi
    printf "Running browser qualification and %s discovered contract test file(s) before compilation.\n" \
      "${#CONTRACT_TESTS[@]}"
    node --test --test-reporter=tap \
      /src/tests/browser/qualification.test.mjs "${CONTRACT_TESTS[@]}"

    CONFIGURE_PACKAGE_FLAGS=()
    if [[ "$LIBFUTURO_BUILD_PACKAGE" == true ]]; then
      CONFIGURE_PACKAGE_FLAGS+=(
        -DCMAKE_INSTALL_PREFIX=/work/stage
        -DLIBFUTURO_WEB_TEST_PREFIX=/work/relocated
      )
    fi
    PACKAGE_CONFIGURE_START_NS="$(monotonic_now_ns)"
    emcmake cmake -S /src -B /work/build \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
      -DBUILD_TESTING=ON \
      -DFETCHCONTENT_QUIET=OFF \
      -DLIBFUTURO_BUILD_WEB=ON \
      -DLIBFUTURO_ENABLE_MUHTARI=ON \
      -DLIBFUTURO_MUHTARI_API_REVISION=8 \
      "-DLIBFUTURO_WEB_TEST_IDENTITY=$LIBFUTURO_BUILD_PACKAGE" \
      "-DLIBFUTURO_WEB_SDK_IMAGE=$LIBFUTURO_SDK_IMAGE" \
      "-DLIBFUTURO_WEB_SDK_PLATFORM=$LIBFUTURO_SDK_PLATFORM" \
      "-DLIBFUTURO_WEB_SOURCE_REVISION=$LIBFUTURO_SOURCE_REVISION" \
      "${CONFIGURE_PACKAGE_FLAGS[@]}"
    PACKAGE_CONFIGURE_END_NS="$(monotonic_now_ns)"
    PACKAGE_CONFIGURE_SECONDS="$(elapsed_seconds "$PACKAGE_CONFIGURE_START_NS" "$PACKAGE_CONFIGURE_END_NS")"

    printf "\nEffective CMake compiler and flags:\n"
    grep -E "^(CMAKE_C_COMPILER:FILEPATH|CMAKE_C_COMPILER:STRING|CMAKE_C_FLAGS(:|_)|CMAKE_EXE_LINKER_FLAGS(:|_)|CMAKE_STATIC_LINKER_FLAGS(:|_)|CMAKE_SYSTEM_NAME:|CMAKE_SYSTEM_PROCESSOR:)" /work/build/CMakeCache.txt || true
    printf "\nActual selected source compile commands:\n"
    grep -n -A 4 -E "src/(synthetic|muhtari_adapter)\\.c|muhtari-src/.*/src/.*\\.c" /work/build/compile_commands.json

    PACKAGE_BUILD_START_NS="$(monotonic_now_ns)"
    cmake --build /work/build --target libfuturo_web --verbose
    PACKAGE_BUILD_END_NS="$(monotonic_now_ns)"
    PACKAGE_BUILD_SECONDS="$(elapsed_seconds "$PACKAGE_BUILD_START_NS" "$PACKAGE_BUILD_END_NS")"

    test -s /work/build/libfuturo-web.a
    find /work/build/CMakeFiles/libfuturo_web.dir -type f \
      -name "*muhtari_adapter.c.o" -print -quit | grep -q .
    grep -Fq "/src/src/muhtari_adapter.c" /work/build/compile_commands.json
    if ! grep -Eq "muhtari-src/.*/src/[^\"]+\\.c" /work/build/compile_commands.json; then
      printf "%s\n" "error: the selected Muhtari source has no actual compiler entry" >&2
      exit 3
    fi

    ctest --test-dir /work/build -R "^web_package_graph$" --output-on-failure

    if [[ "$LIBFUTURO_BUILD_PACKAGE" == true ]]; then
      PACKAGE_INSTALL_START_NS="$(monotonic_now_ns)"
      cmake --build /work/build --target web_snapshot_identity_probe --verbose
      ctest --test-dir /work/build -R "^web_snapshot_cross_runtime_identity$" --output-on-failure
      cmake --install /work/build --prefix /work/stage
      test -s /work/stage/lib/libfuturo-web.a
      test -s /work/stage/lib/libmuhtari.a
      test -f /work/stage/lib/cmake/libfuturo-web/libfuturo_webConfig.cmake
      test -f /work/stage/lib/cmake/muhtari/muhtariConfig.cmake
      if find /work/stage -iname "*nesturbator*" -print -quit | grep -q .; then
        printf "%s\n" "error: browser staging prefix contains a Nesturbator artifact" >&2
        exit 4
      fi
      mv /work/stage /work/relocated
      ctest --test-dir /work/build -R "^web_package_export$" --output-on-failure
      PACKAGE_INSTALL_END_NS="$(monotonic_now_ns)"
      PACKAGE_INSTALL_RELOCATION_SECONDS="$(elapsed_seconds "$PACKAGE_INSTALL_START_NS" "$PACKAGE_INSTALL_END_NS")"
    fi

    if [[ "$LIBFUTURO_BUILD_CONSUMER" == true ]]; then
      cp -R /src/tests/web-consumer /work/consumer-source
      # The browser host calls the exported C API after main returns, so keep
      # the runtime alive in this isolated consumer build used by the route.
      sed -i 's/"-sEXIT_RUNTIME=1"/"-sEXIT_RUNTIME=0"/' /work/consumer-source/CMakeLists.txt
      if grep -Fq -- -sEXIT_RUNTIME=1 /work/consumer-source/CMakeLists.txt ||
         ! grep -Fq -- -sEXIT_RUNTIME=0 /work/consumer-source/CMakeLists.txt; then
        printf "%s\\n" "error: browser consumer must keep the Emscripten runtime alive after main" >&2
        exit 6
      fi
      cp /src/tests/installed-consumer/muhtari_fixture.h /work/consumer-source/muhtari_fixture.h
      cp /src/tests/installed-consumer/muhtari_oracle.h /work/consumer-source/muhtari_oracle.h
      mkdir -p /work/installed-macos-host
      cp /src/tests/installed-macos-host/MUHTARI-PALETTE-NOTICES.md /work/installed-macos-host/MUHTARI-PALETTE-NOTICES.md
      rm -rf /work/build
      test ! -e /work/build
      test ! -e /work/stage
      test -d /work/relocated

      CONSUMER_CONFIGURE_START_NS="$(monotonic_now_ns)"
      emcmake cmake -S /work/consumer-source -B /work/consumer-build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF \
        -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF \
        -DEXPECTED_INSTALL_PREFIX=/work/relocated \
        -DEXPECTED_MUHTARI_VERSION=0.11.1 \
        -DEXPECTED_MUHTARI_API_REVISION=8 \
        -DEXPECTED_MUHTARI_SOURCE_REVISION=d58f125297c4d63a7a8108112a5eafff6f53a76a \
        "-DEXPECTED_LIBFUTURO_SOURCE_REVISION=$LIBFUTURO_SOURCE_REVISION" \
        -DEXPECTED_PROFILE_ID=muhtari-ntsc-v2 \
        -DEXPECTED_CONFIGURATION_ID=muhtari-ntsc-battery-diagnostic \
        "-DEXPECTED_SDK_IMAGE=$LIBFUTURO_SDK_IMAGE" \
        "-DEXPECTED_SDK_PLATFORM=$LIBFUTURO_SDK_PLATFORM" \
        -DEXPECTED_FIXTURE_SHA256=136cbead3da4bde24ea23acf36eb8daacced88074bbe021888aa4e17d987195e
      CONSUMER_CONFIGURE_END_NS="$(monotonic_now_ns)"
      CONSUMER_CONFIGURE_SECONDS="$(elapsed_seconds "$CONSUMER_CONFIGURE_START_NS" "$CONSUMER_CONFIGURE_END_NS")"
      CONSUMER_BUILD_START_NS="$(monotonic_now_ns)"
      cmake --build /work/consumer-build --target libfuturo_web_consumer --verbose
      CONSUMER_BUILD_END_NS="$(monotonic_now_ns)"
      CONSUMER_BUILD_SECONDS="$(elapsed_seconds "$CONSUMER_BUILD_START_NS" "$CONSUMER_BUILD_END_NS")"

      test -s /work/consumer-build/artifacts/consumer.js
      test -s /work/consumer-build/artifacts/consumer.wasm
      test -s /work/consumer-build/artifacts/consumer.html
      test -s /work/consumer-build/artifacts/consumer-host.js
      test -s /work/consumer-build/artifacts/MUHTARI-PALETTE-NOTICES.md
      node -e "\
        const fs = require(\"node:fs\");\
        const entries = JSON.parse(fs.readFileSync(\"/work/consumer-build/compile_commands.json\", \"utf8\"));\
        if (!entries.length) throw new Error(\"consumer compile database is empty\");\
        for (const entry of entries) {\
          if (entry.command.includes(\"/src/\") || entry.command.includes(\"/work/build/\") || entry.command.includes(\"/work/stage/\")) throw new Error(\"consumer compile consulted an unavailable source/build/staging path\");\
        }\
        const command = entries.map(entry => entry.command).join(String.fromCharCode(32));\
        if (!command.includes(\"/work/relocated/include\")) throw new Error(\"consumer did not use the relocated public headers\");\
        console.log(\"consumer_compile_paths: checkout=absent build=absent staging=absent relocated-headers=pass\");\
      "
      LINK_COMMAND=$(cat /work/consumer-build/CMakeFiles/libfuturo_web_consumer.dir/link.txt)
      if [[ "$LINK_COMMAND" == *"/src/"* ||
            "$LINK_COMMAND" == *"/work/build/"* ||
            "$LINK_COMMAND" == *"/work/stage/"* ]]; then
        printf "%s\n" "error: consumer link consulted an unavailable source/build/staging path" >&2
        exit 6
      fi
      if [[ "$LINK_COMMAND" != *"/work/relocated/lib/libfuturo-web.a"* ||
            "$LINK_COMMAND" != *"/work/relocated/lib/libmuhtari.a"* ]]; then
        printf "%s\n" "error: consumer link did not resolve both colocated installed archives" >&2
        exit 6
      fi

      LIBFUTURO_WEB_BUILD_ID=$(sed -nE "s/^set\\(libfuturo_web_BUILD_ID \\\"([^\\\"]+)\\\"\\)$/\\1/p" \
        /work/relocated/lib/cmake/libfuturo-web/libfuturo_webConfig.cmake)
      test -n "$LIBFUTURO_WEB_BUILD_ID"
      WEB_ARCHIVE_SHA256=$(sha256sum /work/relocated/lib/libfuturo-web.a | cut -d " " -f 1)
      MUHTARI_ARCHIVE_SHA256=$(sha256sum /work/relocated/lib/libmuhtari.a | cut -d " " -f 1)
      CONSUMER_JS_SHA256=$(sha256sum /work/consumer-build/artifacts/consumer.js | cut -d " " -f 1)
      CONSUMER_HOST_SHA256=$(sha256sum /work/consumer-build/artifacts/consumer-host.js | cut -d " " -f 1)
      CONSUMER_WASM_SHA256=$(sha256sum /work/consumer-build/artifacts/consumer.wasm | cut -d " " -f 1)
      EMCC_VERSION=$(emcc --version | sed -n "1p")
      CONTAINER_ARCH=$(uname -m)
      CONTAINER_OS_NAME=${CONTAINER_OS_NAME}
      export LIBFUTURO_WEB_BUILD_ID WEB_ARCHIVE_SHA256 MUHTARI_ARCHIVE_SHA256 \
        CONSUMER_JS_SHA256 CONSUMER_HOST_SHA256 CONSUMER_WASM_SHA256 EMCC_VERSION CONTAINER_ARCH CONTAINER_OS_NAME
      export LIBFUTURO_TIMING_PACKAGE_CONFIGURE_SECONDS="$PACKAGE_CONFIGURE_SECONDS" \
        LIBFUTURO_TIMING_PACKAGE_BUILD_SECONDS="$PACKAGE_BUILD_SECONDS" \
        LIBFUTURO_TIMING_PACKAGE_INSTALL_RELOCATION_SECONDS="$PACKAGE_INSTALL_RELOCATION_SECONDS" \
        LIBFUTURO_TIMING_CONSUMER_CONFIGURE_SECONDS="$CONSUMER_CONFIGURE_SECONDS" \
        LIBFUTURO_TIMING_CONSUMER_BUILD_SECONDS="$CONSUMER_BUILD_SECONDS" \
        LIBFUTURO_TIMING_PACKAGE_CONFIGURE_START_NS="$PACKAGE_CONFIGURE_START_NS" \
        LIBFUTURO_TIMING_PACKAGE_CONFIGURE_END_NS="$PACKAGE_CONFIGURE_END_NS" \
        LIBFUTURO_TIMING_PACKAGE_BUILD_START_NS="$PACKAGE_BUILD_START_NS" \
        LIBFUTURO_TIMING_PACKAGE_BUILD_END_NS="$PACKAGE_BUILD_END_NS" \
        LIBFUTURO_TIMING_PACKAGE_INSTALL_START_NS="$PACKAGE_INSTALL_START_NS" \
        LIBFUTURO_TIMING_PACKAGE_INSTALL_END_NS="$PACKAGE_INSTALL_END_NS" \
        LIBFUTURO_TIMING_CONSUMER_CONFIGURE_START_NS="$CONSUMER_CONFIGURE_START_NS" \
        LIBFUTURO_TIMING_CONSUMER_CONFIGURE_END_NS="$CONSUMER_CONFIGURE_END_NS" \
        LIBFUTURO_TIMING_CONSUMER_BUILD_START_NS="$CONSUMER_BUILD_START_NS" \
        LIBFUTURO_TIMING_CONSUMER_BUILD_END_NS="$CONSUMER_BUILD_END_NS"
      cp /work/consumer-build/CMakeFiles/libfuturo_web_consumer.dir/link.txt /work/evidence/generated-link-command.txt
      node --input-type=module -e "\
        const { readFileSync, writeFileSync } = await import(\"node:fs\");\
        const { parseGeneratedLinkCommand } = await import(\"file:///src/tests/browser/qualification.mjs\");\
        const observations = JSON.parse(readFileSync(process.env.LIBFUTURO_RUNNER_OBSERVATIONS, \"utf8\"));\
        const linkCommand = parseGeneratedLinkCommand(readFileSync(\"/work/evidence/generated-link-command.txt\", \"utf8\"), { buildDirectory: \"/work/consumer-build\", relocatedPrefix: \"/work/relocated\" });\
        const report = {\
          schema_version: 2, status: \"consumer-build-pass\",\
          source_commit: process.env.LIBFUTURO_SOURCE_REVISION,\
          source_tree: process.env.LIBFUTURO_SOURCE_TREE,\
          source_snapshot_kind: process.env.LIBFUTURO_SOURCE_SNAPSHOT,\
          outer_runner: observations.outer_runner, docker_daemon: observations.docker_daemon,\
          container: { os_name: process.env.CONTAINER_OS_NAME, architecture: process.env.CONTAINER_ARCH, node_version: process.version, node_platform: process.platform, node_architecture: process.arch, node_versions: process.versions },\
          timings: {\
            schema_version: 1, finalized: false,\
            clock_domains: { outer: \"host CLOCK_MONOTONIC via Perl Time::HiRes\", container: \"SDK container CLOCK_MONOTONIC via Perl Time::HiRes\", scenarios: \"Node qualification-process performance.now()\" },\
            stage_clock_domains: { outer_setup_image_acquisition: \"outer\", docker_run: \"outer\", package_configure: \"container\", package_build: \"container\", package_install_relocation: \"container\", consumer_configure: \"container\", consumer_build: \"container\", browser_setup: \"container\", scenario_execution: \"scenarios\", scenarios: \"scenarios\", total: \"outer\" },\
            durations_seconds: { outer_setup_image_acquisition: Number(process.env.LIBFUTURO_OUTER_SETUP_SECONDS), package_configure: Number(process.env.LIBFUTURO_TIMING_PACKAGE_CONFIGURE_SECONDS), package_build: Number(process.env.LIBFUTURO_TIMING_PACKAGE_BUILD_SECONDS), package_install_relocation: Number(process.env.LIBFUTURO_TIMING_PACKAGE_INSTALL_RELOCATION_SECONDS), consumer_configure: Number(process.env.LIBFUTURO_TIMING_CONSUMER_CONFIGURE_SECONDS), consumer_build: Number(process.env.LIBFUTURO_TIMING_CONSUMER_BUILD_SECONDS), browser_setup: null, scenario_execution: null, scenarios: {}, docker_run: null, total: null },\
            intervals: { outer_setup_image_acquisition: { start: Number(process.env.LIBFUTURO_OUTER_SETUP_START_NS), end: Number(process.env.LIBFUTURO_OUTER_SETUP_END_NS), unit: \"nanoseconds\" }, docker_run: null, total: null, package_configure: { start: Number(process.env.LIBFUTURO_TIMING_PACKAGE_CONFIGURE_START_NS), end: Number(process.env.LIBFUTURO_TIMING_PACKAGE_CONFIGURE_END_NS), unit: \"nanoseconds\" }, package_build: { start: Number(process.env.LIBFUTURO_TIMING_PACKAGE_BUILD_START_NS), end: Number(process.env.LIBFUTURO_TIMING_PACKAGE_BUILD_END_NS), unit: \"nanoseconds\" }, package_install_relocation: { start: Number(process.env.LIBFUTURO_TIMING_PACKAGE_INSTALL_START_NS), end: Number(process.env.LIBFUTURO_TIMING_PACKAGE_INSTALL_END_NS), unit: \"nanoseconds\" }, consumer_configure: { start: Number(process.env.LIBFUTURO_TIMING_CONSUMER_CONFIGURE_START_NS), end: Number(process.env.LIBFUTURO_TIMING_CONSUMER_CONFIGURE_END_NS), unit: \"nanoseconds\" }, consumer_build: { start: Number(process.env.LIBFUTURO_TIMING_CONSUMER_BUILD_START_NS), end: Number(process.env.LIBFUTURO_TIMING_CONSUMER_BUILD_END_NS), unit: \"nanoseconds\" }, browser_setup: null, scenarios: {} },\
            cache_observations: { sdk_image: process.env.LIBFUTURO_SDK_IMAGE_CACHE_STATUS, browser_archive: \"not-observed\", apt_packages: \"not-claimed-unverified\" },\
            queue: { status: \"not-available-locally\", seconds: null, source: \"hosted GitHub Actions run/job records only (Plan 03-05)\" },\
            nesting: { total_includes: [\"outer_setup_image_acquisition\", \"docker_run\"], docker_run_contains: [\"package_configure\", \"package_build\", \"package_install_relocation\", \"consumer_configure\", \"consumer_build\", \"browser_setup\", \"scenario_execution\"], scenario_execution: \"sum-of-serial-scenario-intervals\", warning: \"container and scenario stage durations are nested inside docker_run; do not add them to total\" }\
          },\

          package: { target: \"libfuturo::web\", core: \"muhtari\", core_version: \"0.11.1\", core_source_revision: \"d58f125297c4d63a7a8108112a5eafff6f53a76a\", api_revision: 8, abi_revision: 1, behavior_revision: 6, profile: \"muhtari-ntsc-v2\", configuration: \"muhtari-ntsc-battery-diagnostic\", libfuturo_build_id: process.env.LIBFUTURO_WEB_BUILD_ID, archive_sha256: process.env.WEB_ARCHIVE_SHA256, core_archive_sha256: process.env.MUHTARI_ARCHIVE_SHA256 },\
          fixture_metadata: { id: \"generated-muhtari-a78-api8-v1\", bytes: 16512, sha256: \"136cbead3da4bde24ea23acf36eb8daacced88074bbe021888aa4e17d987195e\", loaded_or_read: false },\
          sdk: { image: process.env.LIBFUTURO_SDK_IMAGE, requested_platform: process.env.LIBFUTURO_SDK_PLATFORM, resolved_platform: process.env.LIBFUTURO_SDK_RESOLVED_PLATFORM, container_architecture: process.env.CONTAINER_ARCH, compiler: process.env.EMCC_VERSION },\
          consumer: { source: \"public-header-only\", target: \"libfuturo_web_consumer\", javascript_sha256: process.env.CONSUMER_JS_SHA256, host_controller_sha256: process.env.CONSUMER_HOST_SHA256, wasm_sha256: process.env.CONSUMER_WASM_SHA256, link_command: linkCommand, positive_identity: \"built-not-yet-run\", mismatch_before_load: \"built-not-yet-run\" },\
          browser: { status: \"not-run-in-consumer-only-mode\", runtime_packages_classification: \"installed-unpinned\", runtime_packages: [] }\
        };\
        writeFileSync(\"/work/evidence/consumer-report.json\", JSON.stringify(report, null, 2) + \"\\n\", { mode: 0o600 });\
      "
      printf "Relocated consumer: profile=muhtari-ntsc-v2 api=8 behavior=6 js=%s wasm=%s\\n" \
        "$CONSUMER_JS_SHA256" "$CONSUMER_WASM_SHA256"

      if [[ "$LIBFUTURO_RUN_BROWSER" == true ]]; then
        printf "Official browser artifact: Chrome for Testing headless shell %s (%s)\\n" \
          "$LIBFUTURO_CFT_VERSION" "$LIBFUTURO_CFT_ARCHIVE"
        BROWSER_START_SECONDS=$(date +%s)
        BROWSER_SETUP_START_NS="$(monotonic_now_ns)"
        CHROME_ARCHIVE="$LIBFUTURO_BROWSER_CACHE_DIR/chrome-headless-shell-linux64-${LIBFUTURO_CFT_VERSION}.zip"
        CHROME_DOWNLOAD=/work/evidence/chrome-headless-shell-linux64.download.zip
        CHROME_ROOT=/work/chrome
        CFT_CACHE_STATUS=downloaded
        CFT_DOWNLOAD_START_SECONDS=$(date +%s)
        if [[ -s "$CHROME_ARCHIVE" ]]; then
          CACHED_CFT_SHA256=$(sha256sum "$CHROME_ARCHIVE" | cut -d " " -f 1)
          if [[ "$CACHED_CFT_SHA256" == "$LIBFUTURO_CFT_SHA256" ]]; then
            CFT_CACHE_STATUS=verified-hit
            printf "Reused cached official browser archive after SHA-256 verification.\\n"
          else
            printf "Cached official browser archive failed SHA-256; downloading the pinned artifact.\\n"
            rm -f "$CHROME_ARCHIVE"
          fi
        fi
        if [[ ! -s "$CHROME_ARCHIVE" ]]; then
          if ! curl --fail --location --retry 0 --max-time 300 \
              "$LIBFUTURO_CFT_URL" --output "$CHROME_DOWNLOAD"; then
            printf "%s\\n" "error: could not fetch the pinned official browser artifact" >&2
            exit 7
          fi
          DOWNLOADED_CFT_SHA256=$(sha256sum "$CHROME_DOWNLOAD" | cut -d " " -f 1)
          if [[ "$DOWNLOADED_CFT_SHA256" != "$LIBFUTURO_CFT_SHA256" ]]; then
            printf "error: official browser archive SHA-256 was %s, expected %s\\n" \
              "$DOWNLOADED_CFT_SHA256" "$LIBFUTURO_CFT_SHA256" >&2
            exit 7
          fi
          CHROME_ARCHIVE_TMP=$(mktemp "$CHROME_ARCHIVE.tmp.XXXXXX")
          cp "$CHROME_DOWNLOAD" "$CHROME_ARCHIVE_TMP"
          mv -f "$CHROME_ARCHIVE_TMP" "$CHROME_ARCHIVE"
        fi
        ACTUAL_CFT_SHA256=$(sha256sum "$CHROME_ARCHIVE" | cut -d " " -f 1)
        if [[ "$ACTUAL_CFT_SHA256" != "$LIBFUTURO_CFT_SHA256" ]]; then
          printf "error: official browser archive SHA-256 was %s, expected %s\\n" \
            "$ACTUAL_CFT_SHA256" "$LIBFUTURO_CFT_SHA256" >&2
          exit 7
        fi
        printf "Verified official browser archive SHA-256: %s\\n" "$ACTUAL_CFT_SHA256"
        CFT_DOWNLOAD_END_SECONDS=$(date +%s)
        printf "Pinned browser archive acquisition elapsed: %s seconds\\n" \
          "$((CFT_DOWNLOAD_END_SECONDS - CFT_DOWNLOAD_START_SECONDS))"

        dpkg-query -W --showformat="\${binary:Package}=\${Version}\\n" | LC_ALL=C sort \
          > /work/evidence/browser-runtime-packages-before.txt
        APT_SOURCES=/etc/apt/sources.list.d/ubuntu.sources
        if [[ ! -f "$APT_SOURCES" ]]; then
          printf "%s\\n" "error: the pinned SDK image no longer has its expected Ubuntu deb822 sources" >&2
          exit 7
        fi
        mkdir -p /var/lib/apt/lists/partial /var/cache/apt/archives/partial
        chmod 1777 /var/lib/apt/lists/partial /var/cache/apt/archives/partial
        sed -i \
          -e "s#http://archive.ubuntu.com/#https://archive.ubuntu.com/#g" \
          -e "s#http://security.ubuntu.com/#https://security.ubuntu.com/#g" \
          "$APT_SOURCES"
        if ! grep -Fq "URIs: https://archive.ubuntu.com/ubuntu/" "$APT_SOURCES" ||
           ! grep -Fq "URIs: https://security.ubuntu.com/ubuntu/" "$APT_SOURCES"; then
          printf "%s\\n" "error: could not switch the pinned Ubuntu sources to HTTPS" >&2
          exit 7
        fi
        APT_UPDATE_START_SECONDS=$(date +%s)
        timeout 300s apt-get update -qq -o Acquire::ForceIPv4=true
        APT_UPDATE_END_SECONDS=$(date +%s)
        printf "Pinned browser apt index update elapsed: %s seconds\\n" \
          "$((APT_UPDATE_END_SECONDS - APT_UPDATE_START_SECONDS))"
        APT_INSTALL_START_SECONDS=$(date +%s)
        timeout 300s env DEBIAN_FRONTEND=noninteractive apt-get install \
          -o Acquire::ForceIPv4=true -o APT::Keep-Downloaded-Packages=true \
          -y --no-install-recommends \
          libglib2.0-0t64 \
          libatk1.0-0t64 \
          libatk-bridge2.0-0t64 \
          libatspi2.0-0t64 \
          libdbus-1-3 \
          libgbm1 \
          libx11-6 \
          libxcomposite1 \
          libxdamage1 \
          libxext6 \
          libxfixes3 \
          libxrandr2 \
          libxcb1 \
          libxkbcommon0 \
          libasound2t64 \
          fontconfig \
          fonts-liberation
        APT_INSTALL_END_SECONDS=$(date +%s)
        printf "Pinned browser runtime package install elapsed: %s seconds\\n" \
          "$((APT_INSTALL_END_SECONDS - APT_INSTALL_START_SECONDS))"
        dpkg-query -W --showformat="\${binary:Package}=\${Version}\\n" | LC_ALL=C sort \
          > /work/evidence/browser-runtime-packages-after.txt
        cp /work/evidence/browser-runtime-packages-after.txt /work/evidence/browser-runtime-packages.txt
        printf "\\nFull resolved SDK container package inventory (installed and unpinned):\\n"
        cat /work/evidence/browser-runtime-packages.txt
        mkdir -p "$CHROME_ROOT"
        timeout 60s unzip -q "$CHROME_ARCHIVE" -d "$CHROME_ROOT"
        CHROME_BINARY="$CHROME_ROOT/chrome-headless-shell-linux64/chrome-headless-shell"
        if ldd "$CHROME_BINARY" | grep -q "not found"; then
          printf "%s\\n" "error: the pinned browser has unresolved runtime libraries" >&2
          exit 7
        fi
        CHROME_VERSION_OUTPUT=$("$CHROME_BINARY" --version)
        if [[ "$CHROME_VERSION_OUTPUT" != *"$LIBFUTURO_CFT_VERSION"* ]]; then
          printf "error: browser binary reported %s, expected %s\\n" \
            "$CHROME_VERSION_OUTPUT" "$LIBFUTURO_CFT_VERSION" >&2
          exit 7
        fi
        printf "Verified browser binary: %s\\n" "$CHROME_VERSION_OUTPUT"
        node --input-type=module -e "\
          import { readFileSync, writeFileSync } from \"node:fs\";\
          const reportPath = \"/work/evidence/consumer-report.json\";\
          const report = JSON.parse(readFileSync(reportPath, \"utf8\"));\
          report.browser = { status: \"browser-setup-pass\", version: process.env.LIBFUTURO_CFT_VERSION, archive_sha256: process.env.LIBFUTURO_CFT_SHA256, release_revision: process.env.LIBFUTURO_CFT_REVISION, requested_platform: process.env.LIBFUTURO_SDK_PLATFORM, runtime_packages_classification: \"installed-unpinned\", runtime_packages: readFileSync(\"/work/evidence/browser-runtime-packages.txt\", \"utf8\").trimEnd().split(\"\\n\") };\
          writeFileSync(reportPath, JSON.stringify(report, null, 2) + \"\\n\", { mode: 0o600 });\
        "
        BROWSER_SETUP_END_NS="$(monotonic_now_ns)"
        BROWSER_SETUP_SECONDS="$(elapsed_seconds "$BROWSER_SETUP_START_NS" "$BROWSER_SETUP_END_NS")"
        export LIBFUTURO_TIMING_BROWSER_SETUP_SECONDS="$BROWSER_SETUP_SECONDS"
        export LIBFUTURO_TIMING_BROWSER_SETUP_START_NS="$BROWSER_SETUP_START_NS" \
          LIBFUTURO_TIMING_BROWSER_SETUP_END_NS="$BROWSER_SETUP_END_NS" \
          LIBFUTURO_BROWSER_ARCHIVE_CACHE_STATUS="$CFT_CACHE_STATUS"
        node -e "const fs=require(\"node:fs\"); const p=\"/work/evidence/consumer-report.json\"; const r=JSON.parse(fs.readFileSync(p,\"utf8\")); r.timings.durations_seconds.browser_setup=Number(process.env.LIBFUTURO_TIMING_BROWSER_SETUP_SECONDS); r.timings.intervals.browser_setup={start:Number(process.env.LIBFUTURO_TIMING_BROWSER_SETUP_START_NS),end:Number(process.env.LIBFUTURO_TIMING_BROWSER_SETUP_END_NS),unit:\"nanoseconds\"}; r.timings.cache_observations.browser_archive=process.env.LIBFUTURO_BROWSER_ARCHIVE_CACHE_STATUS; fs.writeFileSync(p,JSON.stringify(r,null,2)+\"\\n\",{mode:0o600});"
        export LIBFUTURO_BROWSER_BINARY="$CHROME_BINARY"
        export LIBFUTURO_BROWSER_VERSION="$LIBFUTURO_CFT_VERSION"
        export LIBFUTURO_BROWSER_ARCHIVE="$CHROME_ARCHIVE"
        export LIBFUTURO_BROWSER_ARCHIVE_SHA256="$LIBFUTURO_CFT_SHA256"
        export LIBFUTURO_BROWSER_RUNTIME_PACKAGES=/work/evidence/browser-runtime-packages.txt
        export LIBFUTURO_CONSUMER_DIR=/work/consumer-build/artifacts
        export LIBFUTURO_CONSUMER_REPORT=/work/evidence/consumer-report.json
        export LIBFUTURO_SDK_IMAGE
        export LIBFUTURO_SDK_PLATFORM
        export LIBFUTURO_SOURCE_REVISION
        export LIBFUTURO_BROWSER_SCENARIO
        if [[ "$LIBFUTURO_BROWSER_FULL_SUITE" == true ]]; then
          export LIBFUTURO_BROWSER_QUALIFICATION_REPORT=/work/evidence/browser-qualification.json
          export LIBFUTURO_BROWSER_QUALIFICATION_EVIDENCE=/work/evidence/qualification
          node /src/tests/browser/qualification.mjs --run
        else
          export LIBFUTURO_BROWSER_REPORT=/work/evidence/browser-report.json
          export LIBFUTURO_BROWSER_PROCESS_LOG=/work/evidence/browser-process.log
          node /src/tests/browser/cdp.mjs
        fi
        BROWSER_END_SECONDS=$(date +%s)
        BROWSER_SECONDS=$((BROWSER_END_SECONDS - BROWSER_START_SECONDS))
        printf "Browser setup and execution elapsed: %s seconds\\n" "$BROWSER_SECONDS"
      fi
    fi

    printf "\nExact package compile result: source=%s api=8 revision=%s archive=libfuturo-web.a graph=pass\n" \
      "$LIBFUTURO_SOURCE_REVISION" \
      "d58f125297c4d63a7a8108112a5eafff6f53a76a"
    if [[ "$LIBFUTURO_BUILD_PACKAGE" == true ]]; then
      printf "Relocated package result: prefix=/work/relocated identity=pass nesturbator=absent\n"
    fi
    chown -R "$LIBFUTURO_RETURN_UID:$LIBFUTURO_RETURN_GID" /work/evidence
  ' 2>&1 | tee "$ROUTE_LOG"
route_status=${PIPESTATUS[0]}
set -e

if (( route_status != 0 )); then
  printf 'error: Emscripten package compile failed (status %s); diagnostics: %s\n' \
    "$route_status" "${ROUTE_LOG#"$ROOT_DIR"/}" >&2
  exit "$route_status"
fi

if [[ "$RUN_BROWSER" == true && "$RUN_FULL_SUITE" == true ]]; then
  OUTER_ROUTE_END_NS="$(monotonic_now_ns)"
  node "$SOURCE_DIR/tests/browser/qualification.mjs" --finalize-timings \
    "$EVIDENCE_DIR/browser-qualification.json" "$EVIDENCE_DIR/consumer-report.json" \
    "$OUTER_ROUTE_START_NS" "$OUTER_SETUP_END_NS" "$OUTER_ROUTE_END_NS"
fi

printf 'Result: PASS; compile log: %s\n' "${ROUTE_LOG#"$ROOT_DIR"/}"
