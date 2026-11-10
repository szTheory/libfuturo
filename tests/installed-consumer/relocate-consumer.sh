#!/bin/sh
set -eu
MODE=${1---smoke}
if [ "$MODE" != "--smoke" ] && [ "$MODE" != "--save-restart" ] &&
   [ "$MODE" != "--fresh-process-snapshot" ] &&
   [ "$MODE" != "--battery-fresh-process-snapshot" ] &&
   [ "$MODE" != "--muhtari-session" ] &&
   [ "$MODE" != "--muhtari-save-restart" ] &&
   [ "$MODE" != "--macos-host" ] &&
   [ "$MODE" != "--macos-host-preflight" ]; then
  echo "relocation consumer: unsupported mode '$MODE'" >&2
  exit 2
fi
HOST_MODE=0
if [ "$MODE" = "--macos-host" ] ||
   [ "$MODE" = "--macos-host-preflight" ]; then
  HOST_MODE=1
fi
OS_NAME=$(uname -s)
ARCH_NAME=$(uname -m)
if [ "$OS_NAME" != Darwin ] || [ "$ARCH_NAME" != arm64 ]; then
  echo "relocation consumer: D-06 control requires Darwin/arm64; found $OS_NAME/$ARCH_NAME" >&2
  exit 2
fi
ROOT_DIR=$(CDPATH= cd "$(dirname "$0")/../.." && pwd -P)
. "$ROOT_DIR/scripts/process-tree-cleanup.sh"
. "$ROOT_DIR/tests/installed-consumer/relocate-bounded-stage.sh"
BUILD_DIR="$ROOT_DIR/build/check"
if [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
  echo "relocation consumer: configure the canonical build first with ./scripts/check.sh" >&2
  exit 2
fi
SOURCE_COMMIT=$(git -C "$ROOT_DIR" rev-parse HEAD)
SOURCE_STATUS=$(git -C "$ROOT_DIR" status --porcelain=v1 --untracked-files=all)
if [ -n "$SOURCE_STATUS" ]; then
  SOURCE_WORKTREE=dirty
else
  SOURCE_WORKTREE=clean
fi
SOURCE_WORKTREE_FINGERPRINT=$(git -C "$ROOT_DIR" diff --binary HEAD -- | \
  /usr/bin/shasum -a 256 | awk '{print $1}')
if ! printf '%s\n' "$SOURCE_WORKTREE_FINGERPRINT" | \
    grep -Eq '^[0-9a-f]{64}$'; then
  echo 'relocation consumer: could not fingerprint tracked source changes' >&2
  exit 1
fi
EXPECTED_CORE_ORIGIN=$(sed -nE 's/^set\(_nesturbator_repository "([^"]+)"\)$/\1/p' \
  "$ROOT_DIR/cmake/NesturbatorProbe.cmake")
EXPECTED_CORE_COMMIT=$(sed -nE 's/^set\(_nesturbator_commit "([^"]+)"\)$/\1/p' \
  "$ROOT_DIR/cmake/NesturbatorProbe.cmake")
CORE_SOURCE=$(sed -n 's/^nesturbator_SOURCE_DIR:STATIC=//p' "$BUILD_DIR/CMakeCache.txt")
EXPECTED_MUHTARI_ORIGIN=$(sed -nE 's/^set\(_muhtari_repository "([^"]+)"\)$/\1/p' \
  "$ROOT_DIR/cmake/MuhtariProbe.cmake")
EXPECTED_MUHTARI_API_REVISION=$(sed -n \
  's/^LIBFUTURO_MUHTARI_CONFIGURED_API_REVISION:INTERNAL=//p' \
  "$BUILD_DIR/CMakeCache.txt")
EXPECTED_MUHTARI_VERSION=$(sed -n \
  's/^LIBFUTURO_MUHTARI_CONFIGURED_VERSION:INTERNAL=//p' \
  "$BUILD_DIR/CMakeCache.txt")
EXPECTED_MUHTARI_COMMIT=$(sed -n \
  's/^LIBFUTURO_MUHTARI_CONFIGURED_SOURCE_REVISION:INTERNAL=//p' \
  "$BUILD_DIR/CMakeCache.txt")
MUHTARI_SOURCE=$(sed -n 's/^muhtari_SOURCE_DIR:STATIC=//p' "$BUILD_DIR/CMakeCache.txt")
MUHTARI_ENABLED=$(sed -n 's/^LIBFUTURO_ENABLE_MUHTARI:BOOL=//p' \
  "$BUILD_DIR/CMakeCache.txt")
if [ -z "$SOURCE_COMMIT" ] || [ -z "$EXPECTED_CORE_ORIGIN" ] ||
   [ -z "$EXPECTED_CORE_COMMIT" ] || [ -z "$CORE_SOURCE" ] ||
   [ -z "$EXPECTED_MUHTARI_ORIGIN" ] || [ -z "$EXPECTED_MUHTARI_COMMIT" ] ||
   [ -z "$MUHTARI_SOURCE" ] || [ "$MUHTARI_ENABLED" != ON ] ||
   { [ "$EXPECTED_MUHTARI_API_REVISION" != 7 ] &&
     [ "$EXPECTED_MUHTARI_API_REVISION" != 8 ]; }; then
  echo 'relocation consumer: could not establish source or dependency identity' >&2
  exit 1
fi
case "$EXPECTED_MUHTARI_API_REVISION:$EXPECTED_MUHTARI_VERSION:$EXPECTED_MUHTARI_COMMIT" in
  7:0.10.0:d5fd241e3f4d701d73867cc2e465c56a6fe6793d) ;;
  8:0.11.1:d58f125297c4d63a7a8108112a5eafff6f53a76a) ;;
  *)
    echo 'relocation consumer: configured Muhtari API/version/source tuple is unsupported' >&2
    exit 1
    ;;
esac
CORE_ORIGIN=$(git -C "$CORE_SOURCE" remote get-url origin)
CORE_COMMIT=$(git -C "$CORE_SOURCE" rev-parse HEAD)
if [ "$CORE_ORIGIN" != "$EXPECTED_CORE_ORIGIN" ] ||
   [ "$CORE_COMMIT" != "$EXPECTED_CORE_COMMIT" ]; then
  echo 'relocation consumer: acquired dependency identity differs from the declared pin' >&2
  exit 1
fi
MUHTARI_ORIGIN=$(git -C "$MUHTARI_SOURCE" remote get-url origin)
MUHTARI_COMMIT=$(git -C "$MUHTARI_SOURCE" rev-parse HEAD)
MUHTARI_STATUS=$(git -C "$MUHTARI_SOURCE" status --porcelain=v1 --untracked-files=all)
if [ "$MUHTARI_ORIGIN" != "$EXPECTED_MUHTARI_ORIGIN" ] ||
   [ "$MUHTARI_COMMIT" != "$EXPECTED_MUHTARI_COMMIT" ] ||
   [ -n "$MUHTARI_STATUS" ]; then
  echo 'relocation consumer: acquired Muhtari identity or clean-source check failed' >&2
  exit 1
fi
umask 077
SCRATCH=$(mktemp -d /private/tmp/libfuturo-relocate.XXXXXX)
NONCE=$(basename "$SCRATCH")
CONTROL_STAGE="$BUILD_DIR/.relocation-control-$NONCE"
STAGE_ROOT="$BUILD_DIR/relocation-stage-$NONCE"
STAGE_PREFIX="$STAGE_ROOT/prefix"
MOVED_PREFIX="$SCRATCH/moved-prefix"
CONSUMER_SOURCE="$SCRATCH/consumer-source"
CONSUMER_BUILD="$SCRATCH/consumer-build"
HOST_CONSUMER_SOURCE="$SCRATCH/macos-host-source"
HOST_CONSUMER_BUILD="$SCRATCH/macos-host-build"
HOST_APP_BUNDLE="$HOST_CONSUMER_BUILD/installed_macos_host.app"
AMBIENT_NESTURBATOR_DIR="$SCRATCH/ambient-nesturbator"
AMBIENT_MUHTARI_DIR="$SCRATCH/ambient-muhtari"
REPORT_TMP="$SCRATCH/relocation-report.txt"
REPORT_ROOT="$BUILD_DIR/relocation-reports"
REPORT_PATH="$REPORT_ROOT/relocate-$NONCE.txt"
HOST_REPORT_PUBLISHED=0
KEEP_SCRATCH=0
MUHTARI_SAVE_FIXTURE_CACHE=
MUHTARI_SAVE_FIXTURE_PATH=
ROOT_MODE=$(stat -f %Lp "$ROOT_DIR")
BUILD_MODE=$(stat -f %Lp "$BUILD_DIR")
PATHS_PROTECTED=0
HELPER_PID=
cleanup() {
  cleanup_status=$?
  trap - EXIT
  if [ -n "$HELPER_PID" ]; then
    kill -TERM "$HELPER_PID" 2>/dev/null || true
    wait "$HELPER_PID" 2>/dev/null || true
  fi
  if [ "$PATHS_PROTECTED" -eq 1 ]; then
    restore_original_paths || cleanup_status=1
  fi
  if [ "$HOST_MODE" -eq 1 ] &&
     [ "$HOST_REPORT_PUBLISHED" -eq 0 ] &&
     { [ -f "$SCRATCH/macos-host.process-facts.txt" ] ||
       [ -d "$HOST_APP_BUNDLE" ] ||
       [ -f "$SCRATCH/macos-host-bundle-preflight.txt" ]; }; then
    preserve_failed_macos_host_evidence || cleanup_status=1
  fi
  [ ! -d "$CONTROL_STAGE" ] || /bin/rm -rf "$CONTROL_STAGE"
  [ ! -d "$STAGE_ROOT" ] || /bin/rm -rf "$STAGE_ROOT"
  if [ "$KEEP_SCRATCH" -eq 1 ]; then
    printf 'relocation consumer: diagnostic scratch retained at %s\n' \
      "$SCRATCH" >&2
  else
    /bin/rm -rf "$SCRATCH"
  fi
  exit "$cleanup_status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
cd "$SCRATCH"
if [ "$MODE" = "--save-restart" ] ||
   [ "$MODE" = "--muhtari-save-restart" ]; then
  MUHTARI_SAVE_FIXTURE_CACHE="$BUILD_DIR/muhtari-save-fixtures/battery-4642ded6d026f456acf798a43efb081b76987018.a78"
  MUHTARI_SAVE_FIXTURE_PATH="$SCRATCH/pinned-muhtari-battery.a78"
  if ! git -C "$ROOT_DIR" check-ignore -q \
      "${MUHTARI_SAVE_FIXTURE_CACHE#"$ROOT_DIR"/}"; then
    echo 'relocation consumer: Muhtari save fixture cache is not ignored build output' >&2
    exit 1
  fi
  if [ ! -f "$MUHTARI_SAVE_FIXTURE_CACHE" ] ||
     [ "$(/usr/bin/shasum -a 256 "$MUHTARI_SAVE_FIXTURE_CACHE" | awk '{print $1}')" != \
       10f5bc279d8147b3348e102ca9f7e4dc496dd31b5099adb2ef64320e987fb4d4 ]; then
    /bin/mkdir -p "$(dirname "$MUHTARI_SAVE_FIXTURE_CACHE")"
    /bin/cp "$MUHTARI_SOURCE/tests/diag/battery.a78" \
      "$MUHTARI_SAVE_FIXTURE_CACHE"
  fi
  MUHTARI_SAVE_FIXTURE_HASH=$(/usr/bin/shasum -a 256 \
    "$MUHTARI_SAVE_FIXTURE_CACHE" | awk '{print $1}')
  if [ "$MUHTARI_SAVE_FIXTURE_HASH" != \
       10f5bc279d8147b3348e102ca9f7e4dc496dd31b5099adb2ef64320e987fb4d4 ] ||
     ! awk -F '\t' \
       '$1 == "tests/diag/battery.a78" && $2 == "this-repo" && $3 == "4642ded6d026f456acf798a43efb081b76987018" && $4 == "MIT" && $5 == "10f5bc279d8147b3348e102ca9f7e4dc496dd31b5099adb2ef64320e987fb4d4" && $6 == "-" { found = 1 } END { exit !found }' \
       "$MUHTARI_SOURCE/tests/roms/manifest.txt"; then
    echo 'relocation consumer: pinned MIT Muhtari battery fixture verification failed' >&2
    exit 1
  fi
  /bin/cp "$MUHTARI_SAVE_FIXTURE_CACHE" "$MUHTARI_SAVE_FIXTURE_PATH"
fi
if [ "$MODE" = "--save-restart" ]; then
  printf 'format=libfuturo-relocation-save-restart-v1\n' > "$REPORT_TMP"
elif [ "$MODE" = "--fresh-process-snapshot" ]; then
  printf 'format=libfuturo-relocation-fresh-process-snapshot-v1\n' > "$REPORT_TMP"
elif [ "$MODE" = "--battery-fresh-process-snapshot" ]; then
  printf 'format=libfuturo-relocation-battery-fresh-process-snapshot-v1\n' > "$REPORT_TMP"
elif [ "$MODE" = "--muhtari-session" ]; then
  printf 'format=libfuturo-relocation-muhtari-session-v1\n' > "$REPORT_TMP"
elif [ "$MODE" = "--muhtari-save-restart" ]; then
  printf 'format=libfuturo-relocation-muhtari-save-restart-v1\n' > "$REPORT_TMP"
elif [ "$MODE" = "--macos-host" ]; then
  printf 'format=libfuturo-relocation-macos-host-v1\n' > "$REPORT_TMP"
elif [ "$MODE" = "--macos-host-preflight" ]; then
  printf 'format=libfuturo-relocation-macos-host-preflight-v1\n' > "$REPORT_TMP"
else
  printf 'format=libfuturo-relocation-smoke-v1\n' > "$REPORT_TMP"
fi
printf 'run_id=%s\n' "$NONCE" >> "$REPORT_TMP"
printf 'isolation=candidate-directory-permissions\n' >> "$REPORT_TMP"
printf 'source_commit=%s\n' "$SOURCE_COMMIT" >> "$REPORT_TMP"
printf 'source_worktree=%s\n' "$SOURCE_WORKTREE" >> "$REPORT_TMP"
printf 'dependency_origin=%s\n' "$CORE_ORIGIN" >> "$REPORT_TMP"
printf 'dependency_commit=%s\n' "$CORE_COMMIT" >> "$REPORT_TMP"
printf 'muhtari_dependency_origin=%s\n' "$MUHTARI_ORIGIN" >> "$REPORT_TMP"
printf 'muhtari_dependency_commit=%s\n' "$MUHTARI_COMMIT" >> "$REPORT_TMP"
if [ "$MODE" = "--save-restart" ] ||
   [ "$MODE" = "--muhtari-save-restart" ]; then
  printf 'muhtari-save-fixture-cache=%s\n' \
    "${MUHTARI_SAVE_FIXTURE_CACHE#"$ROOT_DIR"/}" >> "$REPORT_TMP"
  printf 'muhtari-save-fixture-source-commit=4642ded6d026f456acf798a43efb081b76987018\n' \
    >> "$REPORT_TMP"
  printf 'muhtari-save-fixture-license=MIT\n' >> "$REPORT_TMP"
  printf 'muhtari-save-fixture-bytes=16512\n' >> "$REPORT_TMP"
  printf 'muhtari-save-fixture-sha256=sha256:%s\n' \
    "$MUHTARI_SAVE_FIXTURE_HASH" >> "$REPORT_TMP"
fi

# Calibrate normal cleanup against the real checkout, build, and staging paths.
/bin/mkdir -p "$CONTROL_STAGE"
printf 'stage-control\n' > "$CONTROL_STAGE/marker"
CONTROL_STAGE_MODE=$(stat -f %Lp "$CONTROL_STAGE")
chmod 000 "$CONTROL_STAGE"
protect_original_paths
if ! probe_original_paths "$ROOT_DIR" "$BUILD_DIR" "$CONTROL_STAGE" "$CONTROL_STAGE/marker"; then
  restore_original_paths
  chmod "$CONTROL_STAGE_MODE" "$CONTROL_STAGE"
  echo 'relocation consumer: normal isolation control did not block every original path' >&2
  exit 1
fi
restore_original_paths
chmod "$CONTROL_STAGE_MODE" "$CONTROL_STAGE"
for path in "$ROOT_DIR/CMakeLists.txt" "$BUILD_DIR/CMakeCache.txt" "$CONTROL_STAGE/marker"; do
  [ -r "$path" ] || { echo "relocation consumer: normal control did not restore $path" >&2; exit 1; }
done
printf 'normal-control=blocked-and-restored\n' >> "$REPORT_TMP"

# A separate helper proves cleanup after deliberate SIGTERM.
INTERRUPT_HELPER="$SCRATCH/interruption-control.sh"
INTERRUPT_READY="$SCRATCH/interruption.ready"
INTERRUPT_RESULT="$SCRATCH/interruption.result"
cat > "$INTERRUPT_HELPER" <<'SH'
#!/bin/sh
set -eu
source_dir=$1; build_dir=$2; stage_dir=$3; ready_file=$4; result_file=$5
source_mode=$(stat -f %Lp "$source_dir")
build_mode=$(stat -f %Lp "$build_dir")
stage_mode=$(stat -f %Lp "$stage_dir")
restored=0
restore() {
  [ "$restored" -eq 0 ] || return 0
  chmod "$source_mode" "$source_dir" 2>/dev/null || return 1
  chmod "$build_mode" "$build_dir" 2>/dev/null || return 1
  chmod "$stage_mode" "$stage_dir" 2>/dev/null || return 1
  restored=1
  if [ "$(stat -f %Lp "$source_dir")" = "$source_mode" ] &&
     [ "$(stat -f %Lp "$build_dir")" = "$build_mode" ] &&
     [ "$(stat -f %Lp "$stage_dir")" = "$stage_mode" ]; then
    printf 'restored\n' > "$result_file"
  else
    printf 'restore-failed\n' > "$result_file"
    return 1
  fi
}
on_signal() { restore; exit 143; }
trap restore EXIT
trap on_signal HUP INT TERM
chmod 000 "$stage_dir"
chmod 000 "$build_dir"
chmod 000 "$source_dir"
for path in "$source_dir/CMakeLists.txt" "$build_dir/CMakeCache.txt" "$stage_dir/marker"; do
  if [ -r "$path" ] || (CDPATH= cd "$(dirname "$path")" >/dev/null 2>&1); then
    echo "interruption probe found an accessible original path: $path" >&2
    exit 1
  fi
done
: > "$ready_file"
while :; do :; done
SH
chmod 700 "$INTERRUPT_HELPER"
/bin/sh "$INTERRUPT_HELPER" "$ROOT_DIR" "$BUILD_DIR" "$CONTROL_STAGE" \
  "$INTERRUPT_READY" "$INTERRUPT_RESULT" &
HELPER_PID=$!
attempt=0
while [ ! -f "$INTERRUPT_READY" ] && [ "$attempt" -lt 100 ]; do
  /bin/sleep 0.05
  attempt=$((attempt + 1))
done
if [ ! -f "$INTERRUPT_READY" ]; then
  echo 'relocation consumer: interruption control did not reach its blocked state' >&2
  exit 1
fi
kill -TERM "$HELPER_PID"
if wait "$HELPER_PID"; then
  helper_status=0
else
  helper_status=$?
fi
HELPER_PID=
if [ "$helper_status" -ne 143 ] || [ ! -f "$INTERRUPT_RESULT" ] ||
    [ "$(cat "$INTERRUPT_RESULT")" != restored ]; then
  echo "relocation consumer: interrupted control failed cleanup (exit $helper_status)" >&2
  exit 1
fi
for path in "$ROOT_DIR/CMakeLists.txt" "$BUILD_DIR/CMakeCache.txt" "$CONTROL_STAGE/marker"; do
  [ -r "$path" ] || { echo "relocation consumer: interruption did not restore $path" >&2; exit 1; }
done
printf 'interruption-control=blocked-and-restored\n' >> "$REPORT_TMP"
/bin/rm -rf "$CONTROL_STAGE"
if [ -e "$REPORT_PATH" ]; then
  echo "relocation consumer: generated evidence path already exists: $REPORT_PATH" >&2
  exit 1
fi

if ! command -v cmake >/dev/null 2>&1; then
  echo 'relocation consumer: cmake is unavailable' >&2
  exit 2
fi
if ! command -v ctest >/dev/null 2>&1; then
  echo 'relocation consumer: ctest is unavailable' >&2
  exit 2
fi
CMAKE_BIN=$(command -v cmake)
CTEST_BIN=$(command -v ctest)
CLANG_PATH=$(xcrun --find clang)
SDK_PATH=$(xcrun --show-sdk-path)
SDK_VERSION=$(xcrun --show-sdk-version)
MACOS_VERSION=$(sw_vers -productVersion)
CLANG_VERSION=$("$CLANG_PATH" --version | head -n 1)
CMAKE_VERSION=$("$CMAKE_BIN" --version | head -n 1)
CTEST_VERSION=$("$CTEST_BIN" --version | head -n 1)
DEVELOPER_DIR=$(xcode-select -p)
TOOL_PATH="$(dirname "$CMAKE_BIN"):$(dirname "$CLANG_PATH"):/usr/bin:/bin:/usr/sbin:/sbin:/Library/Apple/usr/bin"
/bin/mkdir -p "$SCRATCH/home" "$CONSUMER_SOURCE" "$STAGE_PREFIX"
"$CMAKE_BIN" --build "$BUILD_DIR" --target libfuturo --parallel 2
"$CMAKE_BIN" --install "$BUILD_DIR" --prefix "$STAGE_PREFIX"
if [ ! -f "$STAGE_PREFIX/lib/cmake/libfuturo/libfuturoConfig.cmake" ] ||
   [ ! -f "$STAGE_PREFIX/lib/cmake/nesturbator/nesturbatorConfig.cmake" ] ||
   [ ! -f "$STAGE_PREFIX/lib/cmake/muhtari/muhtariConfig.cmake" ] ||
   [ ! -f "$STAGE_PREFIX/lib/cmake/muhtari/muhtariConfigVersion.cmake" ] ||
   [ ! -f "$STAGE_PREFIX/lib/libmuhtari.a" ] ||
   [ ! -f "$STAGE_PREFIX/include/muhtari.h" ] ||
   [ ! -f "$STAGE_PREFIX/share/licenses/libfuturo/LICENSE" ] ||
   [ ! -f "$STAGE_PREFIX/share/licenses/muhtari/LICENSE" ] ||
   [ ! -f "$STAGE_PREFIX/share/licenses/muhtari/THIRD-PARTY-NOTICES.md" ] ||
   [ ! -f "$STAGE_PREFIX/LICENSE" ]; then
  echo 'relocation consumer: installed package config, archive, or notice is missing' >&2
  exit 1
fi
/bin/mkdir -p "$STAGE_PREFIX/share/licenses/nesturbator"
/bin/cp "$STAGE_PREFIX/LICENSE" "$STAGE_PREFIX/share/licenses/nesturbator/LICENSE"
/bin/cp "$ROOT_DIR/tests/installed-consumer/CMakeLists.txt" "$CONSUMER_SOURCE/CMakeLists.txt"
/bin/cp "$ROOT_DIR/tests/installed-consumer/nesturbator_session.c" "$CONSUMER_SOURCE/nesturbator_session.c"
/bin/cp "$ROOT_DIR/tests/installed-consumer/nesturbator_load.c" "$CONSUMER_SOURCE/nesturbator_load.c"
/bin/cp "$ROOT_DIR/tests/installed-consumer/nesturbator_save_fixture.h" "$CONSUMER_SOURCE/nesturbator_save_fixture.h"
/bin/cp "$ROOT_DIR/tests/installed-consumer/nesturbator_save_oracle.h" "$CONSUMER_SOURCE/nesturbator_save_oracle.h"
/bin/cp "$ROOT_DIR/tests/installed-consumer/muhtari_session.c" "$CONSUMER_SOURCE/muhtari_session.c"
/bin/cp "$ROOT_DIR/tests/installed-consumer/muhtari_fixture.h" "$CONSUMER_SOURCE/muhtari_fixture.h"
/bin/cp "$ROOT_DIR/tests/installed-consumer/muhtari_snapshot.c" "$CONSUMER_SOURCE/muhtari_snapshot.c"
/bin/cp "$ROOT_DIR/tests/installed-consumer/muhtari_oracle.h" "$CONSUMER_SOURCE/muhtari_oracle.h"
/bin/cp "$ROOT_DIR/tests/installed-consumer/muhtari_save.c" "$CONSUMER_SOURCE/muhtari_save.c"
/bin/cp "$ROOT_DIR/tests/installed-consumer/muhtari_save_oracle.h" "$CONSUMER_SOURCE/muhtari_save_oracle.h"
/bin/cp "$ROOT_DIR/cmake/ExpectMuhtariOracleFailure.cmake" "$CONSUMER_SOURCE/ExpectMuhtariOracleFailure.cmake"
if [ "$MODE" = "--battery-fresh-process-snapshot" ]; then
  /bin/cp "$ROOT_DIR/tests/nesturbator_fresh_process_supervisor.sh" \
    "$CONSUMER_SOURCE/nesturbator_fresh_process_supervisor.sh"
  /bin/cp "$ROOT_DIR/scripts/process-tree-cleanup.sh" \
    "$CONSUMER_SOURCE/process-tree-cleanup.sh"
fi
if [ "$HOST_MODE" -eq 1 ]; then
  /bin/mkdir -p "$HOST_CONSUMER_SOURCE"
  /bin/cp -R "$ROOT_DIR/tests/installed-macos-host/." "$HOST_CONSUMER_SOURCE/"
  if [ ! -f "$HOST_CONSUMER_SOURCE/MUHTARI-PALETTE-NOTICES.md" ] ||
     ! grep -Fq 'd5fd241e3f4d701d73867cc2e465c56a6fe6793d' \
       "$HOST_CONSUMER_SOURCE/MUHTARI-PALETTE-NOTICES.md" ||
     ! grep -Fq '## MIT License' \
       "$HOST_CONSUMER_SOURCE/MUHTARI-PALETTE-NOTICES.md" ||
     ! grep -Fq '## BSD 3-Clause License' \
       "$HOST_CONSUMER_SOURCE/MUHTARI-PALETTE-NOTICES.md"; then
    echo 'relocation consumer: copied palette source is missing its provenance or licenses' >&2
    exit 1
  fi
  /bin/cp "$ROOT_DIR/tests/installed-consumer/muhtari_oracle.h" \
    "$HOST_CONSUMER_SOURCE/muhtari_oracle.h"
  /bin/cp "$ROOT_DIR/tests/installed-consumer/muhtari_fixture.h" \
    "$HOST_CONSUMER_SOURCE/muhtari_fixture.h"
fi
/bin/mv "$STAGE_ROOT" "$SCRATCH/original-stage"
/bin/mv "$SCRATCH/original-stage/prefix" "$MOVED_PREFIX"
/bin/rmdir "$SCRATCH/original-stage"
if [ -e "$STAGE_ROOT" ] || [ -e "$STAGE_PREFIX" ]; then
  echo 'relocation consumer: original staging path still exists after relocation' >&2
  exit 1
fi

sanitize_macos_host_evidence() {
  input_path=$1
  output_path=$2
  sed \
    -e "s|$ROOT_DIR|<checkout>|g" \
    -e "s|$BUILD_DIR|<build>|g" \
    -e "s|$SCRATCH|<scratch>|g" \
    -e 's|/Users/[^[:space:]\"]*|<user-path>|g' \
    -e 's|/private/\(tmp\|var\)/[^[:space:]\"]*|<private-path>|g' \
    "$input_path" > "$output_path"
}
bundle_executable_basename_is_safe() {
  case "$1" in
    ''|.|..|*/*) return 1 ;;
    *) return 0 ;;
  esac
}
copy_macos_host_artifact() {
  artifact_kind=$1
  artifact_source=$2
  artifact_name=$3
  artifact_relative_ref="relocation-reports/host-artifacts/$NONCE/$artifact_name"
  artifact_destination="$BUILD_DIR/$artifact_relative_ref"
  if [ ! -f "$artifact_source" ]; then
    echo "relocation consumer: required native host artifact is missing: $artifact_name" >&2
    return 1
  fi
  /bin/mkdir -p "$(dirname "$artifact_destination")"
  /bin/cp "$artifact_source" "$artifact_destination"
  artifact_source_hash=$(/usr/bin/shasum -a 256 "$artifact_source" | awk '{print $1}')
  artifact_copy_hash=$(/usr/bin/shasum -a 256 "$artifact_destination" | awk '{print $1}')
  if [ "$artifact_source_hash" != "$artifact_copy_hash" ]; then
    echo "relocation consumer: preserved native host artifact changed: $artifact_name" >&2
    return 1
  fi
  printf 'macos-host-artifact=%s|%s|sha256:%s\n' \
    "$artifact_kind" "$artifact_relative_ref" "$artifact_copy_hash" \
    >> "$REPORT_TMP"
}
preserve_failed_macos_host_evidence() {
  failure_evidence_dir="$REPORT_ROOT/host-failures/$NONCE"
  failure_manifest="$failure_evidence_dir/summary.txt"
  /bin/mkdir -p "$failure_evidence_dir"
  printf 'format=libfuturo-macos-host-failure-evidence-v1\n' > "$failure_manifest"
  for evidence_name in macos-host-inventory.json macos-host.junit.xml \
      macos-host.log macos-host.process-facts.txt \
      macos-host-bundle-preflight.txt macos-host-report.txt; do
    case "$evidence_name" in
      macos-host-inventory.json) evidence_source="$SCRATCH/$evidence_name" ;;
      macos-host.junit.xml) evidence_source="$SCRATCH/$evidence_name" ;;
      macos-host.log) evidence_source="$SCRATCH/$evidence_name" ;;
      macos-host.process-facts.txt) evidence_source="$SCRATCH/$evidence_name" ;;
      macos-host-bundle-preflight.txt) evidence_source="$SCRATCH/$evidence_name" ;;
      macos-host-report.txt) evidence_source="$REPORT_TMP" ;;
    esac
    if [ -f "$evidence_source" ]; then
      evidence_safe_name=${evidence_name#macos-host-}
      evidence_safe_path="$failure_evidence_dir/$evidence_safe_name"
      sanitize_macos_host_evidence "$evidence_source" "$evidence_safe_path"
      evidence_hash=$(/usr/bin/shasum -a 256 "$evidence_safe_path" | awk '{print $1}')
      printf 'evidence=relocation-reports/host-failures/%s/%s sha256:%s\n' \
        "$NONCE" "$evidence_safe_name" \
        "$evidence_hash" >> "$failure_manifest"
    fi
  done
  if [ -d "$HOST_APP_BUNDLE" ]; then
    failure_bundle="$failure_evidence_dir/installed_macos_host.app"
    /usr/bin/ditto "$HOST_APP_BUNDLE" "$failure_bundle"
    bundle_executable_hash=unavailable
    if source_executable_name=$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundleExecutable' "$HOST_APP_BUNDLE/Contents/Info.plist" \
        2>/dev/null) &&
       copied_executable_name=$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundleExecutable' "$failure_bundle/Contents/Info.plist" \
        2>/dev/null) &&
       [ "$source_executable_name" = "$copied_executable_name" ] &&
       bundle_executable_basename_is_safe "$source_executable_name" &&
       [ -f "$HOST_APP_BUNDLE/Contents/MacOS/$source_executable_name" ] &&
       [ -f "$failure_bundle/Contents/MacOS/$copied_executable_name" ]; then
      source_executable_hash=$(/usr/bin/shasum -a 256 \
        "$HOST_APP_BUNDLE/Contents/MacOS/$source_executable_name" \
        | awk '{print $1}')
      copied_executable_hash=$(/usr/bin/shasum -a 256 \
        "$failure_bundle/Contents/MacOS/$copied_executable_name" \
        | awk '{print $1}')
      if [ "$source_executable_hash" != "$copied_executable_hash" ]; then
        echo 'relocation consumer: preserved host executable changed' >&2
        return 1
      fi
      bundle_executable_hash="sha256:$copied_executable_hash"
    fi
    if /usr/bin/codesign --verify --deep --strict "$failure_bundle"; then
      copied_signature=valid
    else
      copied_signature=invalid
    fi
    printf 'bundle=relocation-reports/host-failures/%s/installed_macos_host.app executable=%s signature=%s\n' \
      "$NONCE" "$bundle_executable_hash" "$copied_signature" \
      >> "$failure_manifest"
  fi
  failure_report_ref="${failure_manifest#"$BUILD_DIR"/}"
  printf 'relocation consumer: host failure evidence=%s\n' "$failure_report_ref" >&2
}
mkdir -p "$AMBIENT_NESTURBATOR_DIR"
cat > "$AMBIENT_NESTURBATOR_DIR/nesturbatorConfig.cmake" <<'CMAKE'
message(FATAL_ERROR "ambient nesturbator_DIR package was incorrectly selected")
CMAKE
mkdir -p "$AMBIENT_MUHTARI_DIR"
cat > "$AMBIENT_MUHTARI_DIR/muhtariConfig.cmake" <<'CMAKE'
message(FATAL_ERROR "ambient muhtari_DIR package was incorrectly selected")
CMAKE
run_isolated_stage configure 60 /usr/bin/env -i \
  "PATH=$TOOL_PATH" "HOME=$SCRATCH/home" "TMPDIR=$SCRATCH" \
  "DEVELOPER_DIR=$DEVELOPER_DIR" "$CMAKE_BIN" \
  -S "$CONSUMER_SOURCE" -B "$CONSUMER_BUILD" \
  -DEXPECTED_INSTALL_PREFIX="$MOVED_PREFIX" \
  -DEXPECTED_MUHTARI_ENABLED=ON \
  -DEXPECTED_MUHTARI_API_REVISION="$EXPECTED_MUHTARI_API_REVISION" \
  -DEXPECTED_MUHTARI_VERSION="$EXPECTED_MUHTARI_VERSION" \
  -DEXPECTED_MUHTARI_SOURCE_REVISION="$EXPECTED_MUHTARI_COMMIT" \
  -Dnesturbator_DIR="$AMBIENT_NESTURBATOR_DIR" \
  -Dmuhtari_DIR="$AMBIENT_MUHTARI_DIR" \
  -DCMAKE_PREFIX_PATH="$MOVED_PREFIX" \
  -DCMAKE_FIND_ROOT_PATH="$MOVED_PREFIX" \
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
  -DCMAKE_FIND_USE_CMAKE_ENVIRONMENT_PATH=FALSE \
  -DCMAKE_FIND_USE_PACKAGE_ROOT_PATH=FALSE \
  -DCMAKE_FIND_USE_PACKAGE_REGISTRY=FALSE \
  -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=FALSE \
  -DCMAKE_FIND_PACKAGE_NO_PACKAGE_REGISTRY=TRUE \
  -DCMAKE_FIND_PACKAGE_NO_SYSTEM_PACKAGE_REGISTRY=TRUE \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_C_COMPILER="$CLANG_PATH" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_SYSROOT="$SDK_PATH"
run_isolated_stage build 60 /usr/bin/env -i \
  "PATH=$TOOL_PATH" "HOME=$SCRATCH/home" "TMPDIR=$SCRATCH" \
  "DEVELOPER_DIR=$DEVELOPER_DIR" "$CMAKE_BIN" \
  --build "$CONSUMER_BUILD" \
  --target nesturbator_installed_consumer nesturbator_installed_link_check \
    nesturbator_installed_load muhtari_installed_consumer \
    muhtari_installed_link_check muhtari_save_installed_consumer \
  --parallel 2
PLAIN_LINK_CHECK="$CONSUMER_BUILD/nesturbator_installed_link_check"
if [ ! -x "$PLAIN_LINK_CHECK" ]; then
  echo 'relocation consumer: unsanitized downstream link check is missing' >&2
  exit 1
fi
PLAIN_LINK_HASH=$(/usr/bin/shasum -a 256 "$PLAIN_LINK_CHECK" | awk '{print $1}')
printf 'plain_consumer_link=no-sanitizer-runtime-required:pass\n' >> "$REPORT_TMP"
printf 'plain_consumer_executable_sha256=sha256:%s\n' "$PLAIN_LINK_HASH" \
  >> "$REPORT_TMP"
MUHTARI_LINK_CHECK="$CONSUMER_BUILD/muhtari_installed_link_check"
if [ ! -x "$MUHTARI_LINK_CHECK" ]; then
  echo 'relocation consumer: unsanitized Muhtari downstream link check is missing' >&2
  exit 1
fi
MUHTARI_LINK_HASH=$(/usr/bin/shasum -a 256 "$MUHTARI_LINK_CHECK" | awk '{print $1}')
if run_isolated_stage muhtari-plain-link 30 /usr/bin/env -i \
    "PATH=$TOOL_PATH" "HOME=$SCRATCH/home" "TMPDIR=$SCRATCH" \
    "DEVELOPER_DIR=$DEVELOPER_DIR" "$MUHTARI_LINK_CHECK"; then
  :
else
  exit "$?"
fi
MUHTARI_MARKER='muhtari_session: source=d5fd241e3f4d701d73867cc2e465c56a6fe6793d profile=muhtari-ntsc-v1 fixture=owned-a78-linear-16k ports=two first_samples=54 steady_samples=801 raw_video=INDEX8 non_silent_audio=pass result=pass'
if ! grep -Fq "$MUHTARI_MARKER" "$SCRATCH/muhtari-plain-link.log"; then
  echo 'relocation consumer: unsanitized Muhtari link did not run the installed session' >&2
  cat "$SCRATCH/muhtari-plain-link.log" >&2
  exit 1
fi
printf 'muhtari_plain_link=no-sanitizer-runtime-required:pass\n' >> "$REPORT_TMP"
printf 'muhtari_plain_executable_sha256=sha256:%s\n' "$MUHTARI_LINK_HASH" \
  >> "$REPORT_TMP"
LOAD_REFUSAL_STARTED=$(date +%s)
if run_isolated_stage load-refusal 60 /usr/bin/env -i \
    "PATH=$TOOL_PATH" "HOME=$SCRATCH/home" "TMPDIR=$SCRATCH" \
    "DEVELOPER_DIR=$DEVELOPER_DIR" ctest --test-dir "$CONSUMER_BUILD" \
    -R '^nesturbator_installed_load$' \
    --output-on-failure --verbose --no-tests=error \
    --output-junit "$SCRATCH/load-refusal.junit.xml"; then
  LOAD_REFUSAL_STATUS=0
else
  LOAD_REFUSAL_STATUS=$?
  exit "$LOAD_REFUSAL_STATUS"
fi
LOAD_REFUSAL_ELAPSED=$(($(date +%s) - LOAD_REFUSAL_STARTED))
LOAD_REFUSAL_EXECUTABLE="$CONSUMER_BUILD/nesturbator_installed_load"
if [ ! -x "$LOAD_REFUSAL_EXECUTABLE" ]; then
  echo 'relocation consumer: focused installed-load executable is missing' >&2
  exit 1
fi
LOAD_REFUSAL_HASH=$(/usr/bin/shasum -a 256 "$LOAD_REFUSAL_EXECUTABLE" | awk '{print $1}')
if ! grep -Fq \
  'nesturbator_installed_load: refusals=7 replacement=reset continuation-frames=3 result=pass' \
  "$SCRATCH/load-refusal.log"; then
  echo 'relocation consumer: installed load/refusal marker is missing or incorrect' >&2
  cat "$SCRATCH/load-refusal.log" >&2
  exit 1
fi
printf 'load-refusal=passed\n' >> "$REPORT_TMP"
printf 'load-refusal-exit=%s\n' "$LOAD_REFUSAL_STATUS" >> "$REPORT_TMP"
printf 'load-refusal-executable-sha256=sha256:%s\n' "$LOAD_REFUSAL_HASH" \
  >> "$REPORT_TMP"
printf 'load-refusal-elapsed-seconds=%s\n' "$LOAD_REFUSAL_ELAPSED" \
  >> "$REPORT_TMP"
MUHTARI_FIXTURE_PATH="$SCRATCH/generated-muhtari-diagnostic.a78"
if run_isolated_stage muhtari-fixture-generation 10 /usr/bin/env -i \
    "PATH=$TOOL_PATH" "HOME=$SCRATCH/home" "TMPDIR=$SCRATCH" \
    "DEVELOPER_DIR=$DEVELOPER_DIR" \
    "$CONSUMER_BUILD/muhtari_installed_consumer" \
    --emit-fixture "$MUHTARI_FIXTURE_PATH"; then
  :
else
  exit "$?"
fi
if [ ! -f "$MUHTARI_FIXTURE_PATH" ] ||
   ! grep -Fq \
     'muhtari_fixture: bytes=16512 source=project-authored-C-generator license=Apache-2.0 output=build-only result=pass' \
     "$SCRATCH/muhtari-fixture-generation.log"; then
  echo 'relocation consumer: Muhtari diagnostic extent or provenance is missing' >&2
  cat "$SCRATCH/muhtari-fixture-generation.log" >&2
  exit 1
fi
MUHTARI_FIXTURE_HASH=$(/usr/bin/shasum -a 256 "$MUHTARI_FIXTURE_PATH" | awk '{print $1}')
printf 'muhtari-fixture-bytes=16512\n' >> "$REPORT_TMP"
printf 'muhtari-fixture-sha256=sha256:%s\n' "$MUHTARI_FIXTURE_HASH" \
  >> "$REPORT_TMP"
printf 'muhtari-fixture-provenance=project-authored-C-generator license=Apache-2.0 output=build-only\n' \
  >> "$REPORT_TMP"
printf 'muhtari-fixture-generator=C17 %s\n' "$CLANG_VERSION" >> "$REPORT_TMP"
printf 'muhtari-fixture-generation: checked=16512 source=project-authored-C-generator license=Apache-2.0 output=build-only result=pass\n' \
  >> "$REPORT_TMP"
if [ "$HOST_MODE" -eq 1 ]; then
  if run_isolated_stage macos-host-configure 60 /usr/bin/env -i \
      "PATH=$TOOL_PATH" "HOME=$SCRATCH/home" "TMPDIR=$SCRATCH" \
      "DEVELOPER_DIR=$DEVELOPER_DIR" "$CMAKE_BIN" \
      -S "$HOST_CONSUMER_SOURCE" -B "$HOST_CONSUMER_BUILD" \
      -DEXPECTED_INSTALL_PREFIX="$MOVED_PREFIX" \
      -DMUHTARI_FIXTURE_PATH="$MUHTARI_FIXTURE_PATH" \
      -DMUHTARI_ORACLE_INCLUDE_DIR="$HOST_CONSUMER_SOURCE" \
      -Dnesturbator_DIR="$AMBIENT_NESTURBATOR_DIR" \
      -Dmuhtari_DIR="$AMBIENT_MUHTARI_DIR" \
      -DCMAKE_PREFIX_PATH="$MOVED_PREFIX" \
      -DCMAKE_FIND_ROOT_PATH="$MOVED_PREFIX" \
      -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
      -DCMAKE_FIND_USE_CMAKE_ENVIRONMENT_PATH=FALSE \
      -DCMAKE_FIND_USE_PACKAGE_ROOT_PATH=FALSE \
      -DCMAKE_FIND_USE_PACKAGE_REGISTRY=FALSE \
      -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=FALSE \
      -DCMAKE_FIND_PACKAGE_NO_PACKAGE_REGISTRY=TRUE \
      -DCMAKE_FIND_PACKAGE_NO_SYSTEM_PACKAGE_REGISTRY=TRUE \
      -DCMAKE_BUILD_TYPE=Debug \
      -DCMAKE_C_COMPILER="$CLANG_PATH" \
      -DCMAKE_OBJC_COMPILER="$CLANG_PATH" \
      -DCMAKE_OSX_ARCHITECTURES=arm64 \
      -DCMAKE_OSX_SYSROOT="$SDK_PATH"; then
    :
  else
    exit "$?"
  fi
  if run_isolated_stage macos-host-build 90 /usr/bin/env -i \
      "PATH=$TOOL_PATH" "HOME=$SCRATCH/home" "TMPDIR=$SCRATCH" \
      "DEVELOPER_DIR=$DEVELOPER_DIR" "$CMAKE_BIN" \
      --build "$HOST_CONSUMER_BUILD" --target installed_macos_host \
      host_tracer host_content host_input host_input_session host_timing \
      host_display host_audio native_smoke_supervisor native_smoke_protocol_controls \
      --parallel 2; then
    :
  else
    exit "$?"
  fi
  if run_isolated_stage macos-host-bundle-preflight-controls 30 \
      /usr/bin/env -i "PATH=$TOOL_PATH" "TMPDIR=$SCRATCH" \
      /bin/sh "$HOST_CONSUMER_SOURCE/test-native-app-bundle-preflight.sh" \
      "$HOST_CONSUMER_SOURCE/native-app-bundle-preflight.sh"; then
    :
  else
    exit "$?"
  fi
  if [ ! -f "$HOST_CONSUMER_BUILD/package-resolution.txt" ] ||
     ! grep -Fq 'libfuturo=lib/cmake/libfuturo' \
       "$HOST_CONSUMER_BUILD/package-resolution.txt" ||
     ! grep -Fq 'nesturbator=lib/cmake/nesturbator' \
       "$HOST_CONSUMER_BUILD/package-resolution.txt" ||
     ! grep -Fq 'muhtari=lib/cmake/muhtari' \
       "$HOST_CONSUMER_BUILD/package-resolution.txt"; then
    echo 'relocation consumer: host packages did not resolve from the moved prefix' >&2
    exit 1
  fi
  if run_isolated_stage macos-host-bundle-preflight 30 /usr/bin/env -i \
      "PATH=$TOOL_PATH" "HOME=$SCRATCH/home" "TMPDIR=$SCRATCH" \
      "DEVELOPER_DIR=$DEVELOPER_DIR" /bin/sh \
      "$HOST_CONSUMER_SOURCE/native-app-bundle-preflight.sh" \
      "$HOST_APP_BUNDLE" "$SCRATCH/macos-host-bundle-preflight.txt"; then
    :
  else
    exit "$?"
  fi
  if [ "$MODE" = "--macos-host-preflight" ]; then
    host_preflight_dir="$REPORT_ROOT/host-preflights/$NONCE"
    /bin/mkdir -p "$host_preflight_dir"
    /usr/bin/ditto "$HOST_APP_BUNDLE" \
      "$host_preflight_dir/installed_macos_host.app"
    sanitize_macos_host_evidence "$SCRATCH/macos-host-bundle-preflight.txt" \
      "$host_preflight_dir/bundle-preflight.txt"
    sanitize_macos_host_evidence "$SCRATCH/macos-host-build.log" \
      "$host_preflight_dir/build.log"
    /bin/cp "$MUHTARI_FIXTURE_PATH" "$host_preflight_dir/muhtari-fixture.a78"
    /bin/cp "$HOST_CONSUMER_BUILD/native_smoke_supervisor" \
      "$host_preflight_dir/native_smoke_supervisor"
    /bin/cp "$HOST_CONSUMER_SOURCE/native-app-bundle-preflight.sh" \
      "$host_preflight_dir/native-app-bundle-preflight.sh"
    /bin/cp "$HOST_CONSUMER_SOURCE/run-native-smoke.sh" \
      "$host_preflight_dir/run-native-smoke.sh"
    /bin/cp "$HOST_CONSUMER_SOURCE/native-smoke-cleanup.sh" \
      "$host_preflight_dir/native-smoke-cleanup.sh"
    /bin/cp "$HOST_CONSUMER_SOURCE/test-native-smoke-cleanup.sh" \
      "$host_preflight_dir/test-native-smoke-cleanup.sh"
    host_executable_name=$(/usr/libexec/PlistBuddy \
      -c 'Print :CFBundleExecutable' \
      "$host_preflight_dir/installed_macos_host.app/Contents/Info.plist")
    host_executable_hash=$(/usr/bin/shasum -a 256 \
      "$host_preflight_dir/installed_macos_host.app/Contents/MacOS/$host_executable_name" \
      | awk '{print $1}')
    host_fixture_hash=$(/usr/bin/shasum -a 256 \
      "$host_preflight_dir/muhtari-fixture.a78" | awk '{print $1}')
    if ! /usr/bin/codesign --verify --deep --strict \
        "$host_preflight_dir/installed_macos_host.app"; then
      echo 'relocation consumer: preserved preflight bundle no longer verifies' >&2
      exit 1
    fi
    printf 'format=libfuturo-macos-host-preflight-artifact-v1\n' \
      > "$host_preflight_dir/summary.txt"
    printf 'bundle=installed_macos_host.app\nexecutable_sha256=sha256:%s\n' \
      "$host_executable_hash" >> "$host_preflight_dir/summary.txt"
    printf 'fixture=muhtari-fixture.a78\nfixture_sha256=sha256:%s\n' \
      "$host_fixture_hash" >> "$host_preflight_dir/summary.txt"
    printf 'native_smoke_supervisor=native_smoke_supervisor\n' \
      >> "$host_preflight_dir/summary.txt"
    printf 'bundle_preflight=bundle-preflight.txt\nbuild_log=build.log\n' \
      >> "$host_preflight_dir/summary.txt"
    printf 'focused_smoke=/bin/sh run-native-smoke.sh installed_macos_host.app muhtari-fixture.a78 native_smoke_supervisor\n' \
      >> "$host_preflight_dir/summary.txt"
    printf 'retained_scratch=%s\n' "$SCRATCH" \
      >> "$host_preflight_dir/summary.txt"
    HOST_REPORT_PUBLISHED=1
    KEEP_SCRATCH=1
    printf 'relocation consumer: no-launch macOS host preflight passed; evidence=%s/summary.txt\n' \
      "${host_preflight_dir#"$BUILD_DIR"/}"
    printf 'relocation consumer: one-smoke command: /bin/sh "%s/run-native-smoke.sh" "%s" "%s" "%s"\n' \
      "$HOST_CONSUMER_SOURCE" "$HOST_APP_BUNDLE" "$MUHTARI_FIXTURE_PATH" \
      "$HOST_CONSUMER_BUILD/native_smoke_supervisor"
    exit 0
  fi
  if run_isolated_stage macos-host-inventory 30 ctest \
      --test-dir "$HOST_CONSUMER_BUILD" --show-only=json-v1; then
    /bin/cp "$SCRATCH/macos-host-inventory.log" \
      "$SCRATCH/macos-host-inventory.json"
  else
    exit "$?"
  fi
  # Leave 60 s beyond the 120 s native_window_smoke limit for remaining tests and teardown;
  # this bounds the aggregate route rather than summing every test's maximum allowance.
  if run_isolated_stage macos-host 180 ctest \
      --test-dir "$HOST_CONSUMER_BUILD" --output-on-failure --verbose \
      --no-tests=error --stop-on-failure \
      --output-junit "$SCRATCH/macos-host.junit.xml"; then
    :
  else
    exit "$?"
  fi
  HOST_MARKER='installed_macos_host: profile=muhtari-ntsc-v1 native-window=pass presentation=pass close=pass result=pass'
  PRODUCTION_VIEW_MARKER='installed_macos_host: production-view=LFHostView input=port0-fire startup-rgb=pass geometry=320:242,fit,letterbox capture=backing-rgba controls=rgb,geometry result=pass'
  OPEN_RETRY_MARKER='installed_macos_host: picker=present cancel=idle reader=6 load=2 allocation=1 retry=presented result=pass'
  CLI_RETRY_MARKER='installed_macos_host: cli=invalid-load error=after-cleanup retry=presented result=pass'
  TRACER_MARKER='host_tracer: profile=muhtari-ntsc-v1 startup=partial steady=pass pcm=pass immutable=pass capacity=801 serialized=pass overlap=pass ownership=pass destroy=once result=pass'
  CONTENT_MARKER='host_content: sizes=empty,1,max-minus-one,max,max-plus-one nonregular=directory,fifo unreadable=pass truncation=pass growth=pass allocation=pass eintr=pass cleanup=pass result=pass'
  INPUT_MARKER='host_input: mappings=10 layout=letters-and-US-position aliases=independent unmapped=consumed repeats=pass focus=first-responder,window,app lost result=pass'
  TIMING_MARKER='host_timing: startup=immediate samples=54 boundary=minus-one,equal,plus-one rational=long-ordinal overload=skip duplicate=single max-inflight=1 sentinel=pass prestop=pass reserved-stop=pass duplicate-stop=pass destroy=once overflow=checked catchup-control=detected wrong-order-control=detected stale-callbacks=filtered audio-close=reserved,disarm,owner-drain,player-stop,engine-stop,quiescent audio-mute=preopen,active,shutdown,post-stop-ignored owner-queue=pass guest=continued pcm=valid muted-advances=3 unmuted-advances=2 deadlines=1-4 stop-controls=detected result=pass'
  DISPLAY_MARKER='host_display: indices=13 channels=RGBA8 alpha=opaque raw=unchanged startup=partial capture=layer-scale1,2 geometry=fit,letterbox,nonmultiple,downscale,nearest mailbox=latest,one-invalidation raw-control=detected rgb-control=detected result=pass'
  AUDIO_TEST_MARKER='host_audio: pool=capacity5 frames=54,800,801 bounds=checked drop=newest tokens=duplicate,stale rejected retirement=concurrent lock-free=10/10 manual=s16-mono-48000 blocks=54,800,801 order=pass mute-output=silent,restored-source restore-transition=bounded,stable-after=2-of-3-blocks duplicate=stable completion=retired callback=pool-only close=lease-drained forbidden-controls=guest,player-stop-rejected result=pass'
  LIFECYCLE_CLOSE_MARKER='installed_macos_host: lifecycle=close phase=advance owner-drained=pass main-sentinel=pass destroy=once result=pass'
  LIFECYCLE_QUIT_MARKER='installed_macos_host: lifecycle=quit phase=advance owner-drained=pass main-sentinel=pass destroy=once result=pass'
  LIFECYCLE_ERROR_MARKER='installed_macos_host: lifecycle=close phase=load-error owner-drained=pass main-sentinel=pass error-suppressed=pass destroy=once result=pass'
  LIFECYCLE_MARKER='native_lifecycle: cases=advance-close,advance-quit,load-error-close result=pass'
  if ! grep -Fq "$HOST_MARKER" "$SCRATCH/macos-host.log"; then
    echo 'relocation consumer: installed native host did not emit its exact smoke marker' >&2
    cat "$SCRATCH/macos-host.log" >&2
    exit 1
  fi
  PRODUCTION_VIEW_MARKER_COUNT=$(awk -v marker="$PRODUCTION_VIEW_MARKER" \
    'length($0) >= length(marker) && \
     substr($0, length($0) - length(marker) + 1) == marker { count++ } \
     END { print count + 0 }' "$SCRATCH/macos-host.log")
  if [ "$PRODUCTION_VIEW_MARKER_COUNT" -ne 1 ]; then
    echo 'relocation consumer: production-view smoke marker is missing or duplicated' >&2
    cat "$SCRATCH/macos-host.log" >&2
    exit 1
  fi
  if ! grep -Fq "$OPEN_RETRY_MARKER" "$SCRATCH/macos-host.log"; then
    echo 'relocation consumer: native picker cancel/error/retry flow did not emit its exact marker' >&2
    cat "$SCRATCH/macos-host.log" >&2
    exit 1
  fi
  if ! grep -Fq "$CLI_RETRY_MARKER" "$SCRATCH/macos-host.log"; then
    echo 'relocation consumer: native --content failure and panel retry did not emit its exact marker' >&2
    cat "$SCRATCH/macos-host.log" >&2
    exit 1
  fi
  if ! grep -Fq "$TRACER_MARKER" "$SCRATCH/macos-host.log"; then
    echo 'relocation consumer: installed host tracer did not emit its exact marker' >&2
    cat "$SCRATCH/macos-host.log" >&2
    exit 1
  fi
  if ! grep -Fq "$CONTENT_MARKER" "$SCRATCH/macos-host.log"; then
    echo 'relocation consumer: installed host content tests did not emit their exact marker' >&2
    cat "$SCRATCH/macos-host.log" >&2
    exit 1
  fi
  if ! grep -Fq "$INPUT_MARKER" "$SCRATCH/macos-host.log"; then
    echo 'relocation consumer: native input responder/focus tests did not emit their exact marker' >&2
    cat "$SCRATCH/macos-host.log" >&2
    exit 1
  fi
  if ! grep -Fq "$TIMING_MARKER" "$SCRATCH/macos-host.log"; then
    echo 'relocation consumer: exact cadence and stop-order tests did not emit their marker' >&2
    cat "$SCRATCH/macos-host.log" >&2
    exit 1
  fi
  if ! grep -Fq "$DISPLAY_MARKER" "$SCRATCH/macos-host.log"; then
    echo 'relocation consumer: native display and actual-pixel oracle did not emit its marker' >&2
    cat "$SCRATCH/macos-host.log" >&2
    exit 1
  fi
  if ! grep -Fq "$AUDIO_TEST_MARKER" "$SCRATCH/macos-host.log"; then
    echo 'relocation consumer: fixed-pool and manual-render audio tests did not emit their marker' >&2
    cat "$SCRATCH/macos-host.log" >&2
    exit 1
  fi
  for marker in "$LIFECYCLE_CLOSE_MARKER" "$LIFECYCLE_QUIT_MARKER" \
      "$LIFECYCLE_ERROR_MARKER" "$LIFECYCLE_MARKER"; do
    if ! grep -Fq "$marker" "$SCRATCH/macos-host.log"; then
      echo 'relocation consumer: native shutdown lifecycle evidence is incomplete' >&2
      cat "$SCRATCH/macos-host.log" >&2
      exit 1
    fi
  done
  printf 'macos-host=passed\n' >> "$REPORT_TMP"
  printf 'macos-host-marker=%s\n' "$HOST_MARKER" >> "$REPORT_TMP"
  printf 'macos-host-production-view-marker=%s\n' "$PRODUCTION_VIEW_MARKER" \
    >> "$REPORT_TMP"
  printf 'macos-host-open-retry-marker=%s\n' "$OPEN_RETRY_MARKER" >> "$REPORT_TMP"
  printf 'macos-host-cli-retry-marker=%s\n' "$CLI_RETRY_MARKER" >> "$REPORT_TMP"
  printf 'macos-host-tracer-marker=%s\n' "$TRACER_MARKER" >> "$REPORT_TMP"
  printf 'macos-host-input-marker=%s\n' "$INPUT_MARKER" >> "$REPORT_TMP"
  printf 'macos-host-timing-marker=%s\n' "$TIMING_MARKER" >> "$REPORT_TMP"
  printf 'macos-host-display-marker=%s\n' "$DISPLAY_MARKER" >> "$REPORT_TMP"
  printf 'macos-host-audio-test-marker=%s\n' "$AUDIO_TEST_MARKER" >> "$REPORT_TMP"
  AUDIO_MARKER_COUNT=$(awk '
    /installed_macos_host: audio=system / {
      line = $0
      sub(/^[0-9]+: /, "", line)
      marker = line
      count++
    }
    END { print count + 0 }
  ' "$SCRATCH/macos-host.log")
  AUDIO_MARKER=$(awk '/installed_macos_host: audio=system / {
    line = $0
    sub(/^[0-9]+: /, "", line)
    print line
  }' "$SCRATCH/macos-host.log")
  if [ "$AUDIO_MARKER_COUNT" -ne 1 ] || [ -z "$AUDIO_MARKER" ]; then
    echo 'relocation consumer: live-audio marker is missing or duplicated in native smoke evidence' >&2
    exit 1
  fi
  printf 'macos-host-audio-marker=%s\n' "$AUDIO_MARKER" >> "$REPORT_TMP"
  printf 'macos-host-audio-evidence=system-path,completion,format,player-stop,engine-stop:validated\n' \
    >> "$REPORT_TMP"
  printf 'macos-host-content-marker=%s\n' "$CONTENT_MARKER" >> "$REPORT_TMP"
  printf 'macos-host-lifecycle-close-marker=%s\n' "$LIFECYCLE_CLOSE_MARKER" >> "$REPORT_TMP"
  printf 'macos-host-lifecycle-quit-marker=%s\n' "$LIFECYCLE_QUIT_MARKER" >> "$REPORT_TMP"
  printf 'macos-host-lifecycle-error-marker=%s\n' "$LIFECYCLE_ERROR_MARKER" >> "$REPORT_TMP"
  printf 'macos-host-lifecycle-marker=%s\n' "$LIFECYCLE_MARKER" >> "$REPORT_TMP"
  printf 'macos-host-package-resolution=libfuturo,nesturbator,muhtari:relocated\n' \
    >> "$REPORT_TMP"
  printf 'macos-host-ctest-result=passed\n' >> "$REPORT_TMP"
  printf 'macos-host-ctest-exit=0\nmacos-host-ctest-signal=none\nmacos-host-ctest-timed-out=no\n' \
    >> "$REPORT_TMP"
  for host_test in host_tracer host_content host_input host_input_session \
      host_timing host_display host_audio native_window_smoke native_smoke_cleanup_controls \
      native_smoke_protocol_controls native_open_retry native_lifecycle; do
    printf 'macos-host-ctest-test=%s|passed\n' "$host_test" >> "$REPORT_TMP"
  done
  printf 'macos-host-ctest-inventory-ref=relocation-reports/host-artifacts/%s/ctest-inventory.json\n' \
    "$NONCE" >> "$REPORT_TMP"
  printf 'macos-host-ctest-junit-ref=relocation-reports/host-artifacts/%s/ctest-junit.xml\n' \
    "$NONCE" >> "$REPORT_TMP"
  printf 'macos-host-ctest-log-ref=relocation-reports/host-artifacts/%s/ctest-log.txt\n' \
    "$NONCE" >> "$REPORT_TMP"
  printf 'macos-host-ctest-process-facts-ref=relocation-reports/host-artifacts/%s/ctest-process-facts.txt\n' \
    "$NONCE" >> "$REPORT_TMP"

  HOST_EVIDENCE_TMP="$SCRATCH/macos-host-evidence"
  /bin/mkdir -p "$HOST_EVIDENCE_TMP"
  sanitize_macos_host_evidence "$SCRATCH/macos-host-inventory.json" \
    "$HOST_EVIDENCE_TMP/ctest-inventory.json"
  sanitize_macos_host_evidence "$SCRATCH/macos-host.junit.xml" \
    "$HOST_EVIDENCE_TMP/ctest-junit.xml"
  sanitize_macos_host_evidence "$SCRATCH/macos-host.log" \
    "$HOST_EVIDENCE_TMP/ctest-log.txt"
  sanitize_macos_host_evidence "$SCRATCH/macos-host.process-facts.txt" \
    "$HOST_EVIDENCE_TMP/ctest-process-facts.txt"
  sanitize_macos_host_evidence \
    "$HOST_CONSUMER_BUILD/package-resolution.txt" \
    "$HOST_EVIDENCE_TMP/package-resolution.txt"

  copy_macos_host_artifact libfuturo_archive \
    "$MOVED_PREFIX/lib/liblibfuturo.a" lib/liblibfuturo.a
  copy_macos_host_artifact nesturbator_archive \
    "$MOVED_PREFIX/lib/libnesturbator.a" lib/libnesturbator.a
  copy_macos_host_artifact muhtari_archive \
    "$MOVED_PREFIX/lib/libmuhtari.a" lib/libmuhtari.a
  copy_macos_host_artifact diagnostic_fixture "$MUHTARI_FIXTURE_PATH" \
    diagnostic-fixture.a78
  copy_macos_host_artifact host_executable \
    "$HOST_CONSUMER_BUILD/installed_macos_host.app/Contents/MacOS/installed_macos_host" \
    installed_macos_host
  for host_test in host_tracer host_content host_input host_input_session \
      host_timing host_display host_audio; do
    copy_macos_host_artifact "${host_test}_executable" \
      "$HOST_CONSUMER_BUILD/$host_test" "$host_test"
  done
  copy_macos_host_artifact package_resolution \
    "$HOST_EVIDENCE_TMP/package-resolution.txt" package-resolution.txt
  copy_macos_host_artifact ctest_inventory \
    "$HOST_EVIDENCE_TMP/ctest-inventory.json" ctest-inventory.json
  copy_macos_host_artifact ctest_junit \
    "$HOST_EVIDENCE_TMP/ctest-junit.xml" ctest-junit.xml
  copy_macos_host_artifact ctest_log \
    "$HOST_EVIDENCE_TMP/ctest-log.txt" ctest-log.txt
  copy_macos_host_artifact ctest_process_facts \
    "$HOST_EVIDENCE_TMP/ctest-process-facts.txt" ctest-process-facts.txt
  printf 'macos-host-ctest-inventory-sha256=sha256:%s\n' \
    "$(/usr/bin/shasum -a 256 "$HOST_EVIDENCE_TMP/ctest-inventory.json" | awk '{print $1}')" \
    >> "$REPORT_TMP"
  printf 'macos-host-ctest-junit-sha256=sha256:%s\n' \
    "$(/usr/bin/shasum -a 256 "$HOST_EVIDENCE_TMP/ctest-junit.xml" | awk '{print $1}')" \
    >> "$REPORT_TMP"
  printf 'macos-host-ctest-log-sha256=sha256:%s\n' \
    "$(/usr/bin/shasum -a 256 "$HOST_EVIDENCE_TMP/ctest-log.txt" | awk '{print $1}')" \
    >> "$REPORT_TMP"
  printf 'macos-host-ctest-process-facts-sha256=sha256:%s\n' \
    "$(/usr/bin/shasum -a 256 "$HOST_EVIDENCE_TMP/ctest-process-facts.txt" | awk '{print $1}')" \
    >> "$REPORT_TMP"
fi
MUHTARI_SESSION_STARTED=$(date +%s)
if run_isolated_stage muhtari-session 30 /usr/bin/env -i \
    "PATH=$TOOL_PATH" "HOME=$SCRATCH/home" "TMPDIR=$SCRATCH" \
    "DEVELOPER_DIR=$DEVELOPER_DIR" ctest --test-dir "$CONSUMER_BUILD" \
    -R '^muhtari_installed_consumer$' --output-on-failure --verbose \
    --no-tests=error --output-junit "$SCRATCH/muhtari-session.junit.xml"; then
  MUHTARI_SESSION_STATUS=0
else
  MUHTARI_SESSION_STATUS=$?
  exit "$MUHTARI_SESSION_STATUS"
fi
MUHTARI_SESSION_ELAPSED=$(($(date +%s) - MUHTARI_SESSION_STARTED))
MUHTARI_SESSION_EXECUTABLE="$CONSUMER_BUILD/muhtari_installed_consumer"
if [ ! -x "$MUHTARI_SESSION_EXECUTABLE" ] ||
   ! grep -Fq "$MUHTARI_MARKER" "$SCRATCH/muhtari-session.log"; then
  echo 'relocation consumer: installed Muhtari session marker is missing or incorrect' >&2
  cat "$SCRATCH/muhtari-session.log" >&2
  exit 1
fi
MUHTARI_SESSION_HASH=$(/usr/bin/shasum -a 256 "$MUHTARI_SESSION_EXECUTABLE" | awk '{print $1}')
printf 'muhtari-session=passed\n' >> "$REPORT_TMP"
printf 'muhtari-session-exit=%s\n' "$MUHTARI_SESSION_STATUS" >> "$REPORT_TMP"
printf 'muhtari-session-executable-sha256=sha256:%s\n' "$MUHTARI_SESSION_HASH" \
  >> "$REPORT_TMP"
printf 'muhtari-session-elapsed-seconds=%s\n' "$MUHTARI_SESSION_ELAPSED" \
  >> "$REPORT_TMP"
printf 'muhtari-session-marker=%s\n' "$MUHTARI_MARKER" >> "$REPORT_TMP"

MUHTARI_LOAD_REFUSAL_STARTED=$(date +%s)
if run_isolated_stage muhtari-load-refusal 30 /usr/bin/env -i \
    "PATH=$TOOL_PATH" "HOME=$SCRATCH/home" "TMPDIR=$SCRATCH" \
    "DEVELOPER_DIR=$DEVELOPER_DIR" ctest --test-dir "$CONSUMER_BUILD" \
    -R '^muhtari_installed_load_refusals$' \
    --output-on-failure --verbose --no-tests=error \
    --output-junit "$SCRATCH/muhtari-load-refusal.junit.xml"; then
  MUHTARI_LOAD_REFUSAL_STATUS=0
else
  MUHTARI_LOAD_REFUSAL_STATUS=$?
  exit "$MUHTARI_LOAD_REFUSAL_STATUS"
fi
MUHTARI_LOAD_REFUSAL_ELAPSED=$(($(date +%s) - MUHTARI_LOAD_REFUSAL_STARTED))
if [ ! -x "$MUHTARI_SESSION_EXECUTABLE" ] ||
   ! grep -Fq \
     'muhtari_load_refusals: cases=8 histories=loaded,unloaded continuation=3 allocation-ordinals=measured default-reset=pass result=pass' \
     "$SCRATCH/muhtari-load-refusal.log"; then
  echo 'relocation consumer: installed Muhtari load-refusal marker is missing or incorrect' >&2
  cat "$SCRATCH/muhtari-load-refusal.log" >&2
  exit 1
fi
MUHTARI_LOAD_REFUSAL_HASH=$(/usr/bin/shasum -a 256 "$MUHTARI_SESSION_EXECUTABLE" | awk '{print $1}')
printf 'muhtari-load-refusal=passed\n' >> "$REPORT_TMP"
printf 'muhtari-load-refusal-exit=%s\n' "$MUHTARI_LOAD_REFUSAL_STATUS" >> "$REPORT_TMP"
printf 'muhtari-load-refusal-executable-sha256=sha256:%s\n' \
  "$MUHTARI_LOAD_REFUSAL_HASH" >> "$REPORT_TMP"
printf 'muhtari-load-refusal-elapsed-seconds=%s\n' \
  "$MUHTARI_LOAD_REFUSAL_ELAPSED" >> "$REPORT_TMP"
printf 'muhtari-load-refusal-marker=cases:8 histories:loaded,unloaded continuation:3 allocation-ordinals:measured default-reset:pass\n' \
  >> "$REPORT_TMP"

MUHTARI_BOUNDARIES_STARTED=$(date +%s)
if run_isolated_stage muhtari-frame-boundaries 90 /usr/bin/env -i \
    "PATH=$TOOL_PATH" "HOME=$SCRATCH/home" "TMPDIR=$SCRATCH" \
    "DEVELOPER_DIR=$DEVELOPER_DIR" ctest --test-dir "$CONSUMER_BUILD" \
    -R '^muhtari_installed_frame_boundaries$' \
    --output-on-failure --verbose --no-tests=error \
    --output-junit "$SCRATCH/muhtari-frame-boundaries.junit.xml"; then
  MUHTARI_BOUNDARIES_STATUS=0
else
  MUHTARI_BOUNDARIES_STATUS=$?
  exit "$MUHTARI_BOUNDARIES_STATUS"
fi
MUHTARI_BOUNDARIES_ELAPSED=$(($(date +%s) - MUHTARI_BOUNDARIES_STARTED))
MUHTARI_BOUNDARIES_MARKER='muhtari_frame_boundaries: rejected=14 unsupported-input-bits=6 stride=319,320,321 video-extent=minus-one,exact,plus-one stride-overflow=multiply,add audio-capacity=800,801,802 zero-work=noop result=pass'
if [ ! -x "$MUHTARI_SESSION_EXECUTABLE" ] ||
   ! grep -Fq "$MUHTARI_BOUNDARIES_MARKER" \
     "$SCRATCH/muhtari-frame-boundaries.log"; then
  echo 'relocation consumer: installed Muhtari frame-boundary marker is missing or incorrect' >&2
  cat "$SCRATCH/muhtari-frame-boundaries.log" >&2
  exit 1
fi
MUHTARI_BOUNDARIES_HASH=$(/usr/bin/shasum -a 256 "$MUHTARI_SESSION_EXECUTABLE" | awk '{print $1}')
printf 'muhtari-frame-boundaries=passed\n' >> "$REPORT_TMP"
printf 'muhtari-frame-boundaries-exit=%s\n' "$MUHTARI_BOUNDARIES_STATUS" >> "$REPORT_TMP"
printf 'muhtari-frame-boundaries-executable-sha256=sha256:%s\n' \
  "$MUHTARI_BOUNDARIES_HASH" >> "$REPORT_TMP"
printf 'muhtari-frame-boundaries-elapsed-seconds=%s\n' \
  "$MUHTARI_BOUNDARIES_ELAPSED" >> "$REPORT_TMP"
printf 'muhtari-frame-boundaries-marker=%s\n' "$MUHTARI_BOUNDARIES_MARKER" \
  >> "$REPORT_TMP"

MUHTARI_ORACLE_CONTROL_STARTED=$(date +%s)
if run_isolated_stage muhtari-oracle-negative-control 50 /usr/bin/env -i \
    "PATH=$TOOL_PATH" "HOME=$SCRATCH/home" "TMPDIR=$SCRATCH" \
    "DEVELOPER_DIR=$DEVELOPER_DIR" ctest --test-dir "$CONSUMER_BUILD" \
    -R '^muhtari_installed_oracle_negative_control$' \
    --output-on-failure --verbose --no-tests=error \
    --output-junit "$SCRATCH/muhtari-oracle-negative-control.junit.xml"; then
  MUHTARI_ORACLE_CONTROL_STATUS=0
else
  MUHTARI_ORACLE_CONTROL_STATUS=$?
  exit "$MUHTARI_ORACLE_CONTROL_STATUS"
fi
MUHTARI_ORACLE_CONTROL_ELAPSED=$(($(date +%s) - MUHTARI_ORACLE_CONTROL_STARTED))
MUHTARI_ORACLE_CONTROL_MARKER='muhtari_oracle_negative_control: detected expected indexed mismatch normal-exit=0 wrong-exit=1'
if [ ! -x "$MUHTARI_SESSION_EXECUTABLE" ] ||
   ! grep -Fq "$MUHTARI_ORACLE_CONTROL_MARKER" \
     "$SCRATCH/muhtari-oracle-negative-control.log"; then
  echo 'relocation consumer: installed Muhtari oracle-control proof is missing or incorrect' >&2
  cat "$SCRATCH/muhtari-oracle-negative-control.log" >&2
  exit 1
fi
MUHTARI_ORACLE_CONTROL_HASH=$(/usr/bin/shasum -a 256 "$MUHTARI_SESSION_EXECUTABLE" | awk '{print $1}')
printf 'muhtari-oracle-negative-control=passed\n' >> "$REPORT_TMP"
printf 'muhtari-oracle-negative-control-exit=%s\n' "$MUHTARI_ORACLE_CONTROL_STATUS" >> "$REPORT_TMP"
printf 'muhtari-oracle-negative-control-executable-sha256=sha256:%s\n' \
  "$MUHTARI_ORACLE_CONTROL_HASH" >> "$REPORT_TMP"
printf 'muhtari-oracle-negative-control-elapsed-seconds=%s\n' \
  "$MUHTARI_ORACLE_CONTROL_ELAPSED" >> "$REPORT_TMP"
printf 'muhtari-oracle-negative-control-marker=%s\n' \
  "$MUHTARI_ORACLE_CONTROL_MARKER" >> "$REPORT_TMP"

run_isolated_stage run 30 /usr/bin/env -i \
  "PATH=$TOOL_PATH" "HOME=$SCRATCH/home" "TMPDIR=$SCRATCH" \
  "DEVELOPER_DIR=$DEVELOPER_DIR" \
  "$CONSUMER_BUILD/nesturbator_installed_consumer"
if ! grep -Fq \
  'nesturbator_installed_consumer: source=2338608ab184f040620a30d17756f5e06a42d4e3 profile=nesturbator-ntsc-v1 fixture=generated-nrom load,input,frame,av,close result=pass' \
  "$SCRATCH/run.log"; then
  echo 'relocation consumer: installed session did not emit its exact success marker' >&2
  cat "$SCRATCH/run.log" >&2
  exit 1
fi
printf 'success-marker=nesturbator_installed_consumer\n' >> "$REPORT_TMP"
printf 'success-marker=muhtari_installed_consumer\n' >> "$REPORT_TMP"
printf 'consumer-av-marker=source:2338608ab184f040620a30d17756f5e06a42d4e3 profile:nesturbator-ntsc-v1 input,frame,av:pass\n' >> "$REPORT_TMP"
cat "$CONSUMER_BUILD/package-resolution.txt" >> "$REPORT_TMP"
printf 'ambient_nesturbator_override=ignored\n' >> "$REPORT_TMP"
printf 'ambient_nesturbator_redirect=ignored\n' >> "$REPORT_TMP"

if [ "$MODE" = "--save-restart" ]; then
  if run_isolated_stage installed-snapshot 45 /usr/bin/env -i \
      "PATH=$TOOL_PATH" "HOME=$SCRATCH/home" "TMPDIR=$SCRATCH" \
      "DEVELOPER_DIR=$DEVELOPER_DIR" ctest --test-dir "$CONSUMER_BUILD" \
      -R '^nesturbator_installed_snapshot$' --output-on-failure --verbose \
      --no-tests=error; then
    SNAPSHOT_CHILD_EXIT=0
  else
    SNAPSHOT_CHILD_EXIT=$?
    exit "$SNAPSHOT_CHILD_EXIT"
  fi
  SNAPSHOT_CONSUMER_MARKER='nesturbator_snapshot_installed_consumer: source=2338608ab184f040620a30d17756f5e06a42d4e3 profile=nesturbator-ntsc-v1 configuration=nesturbator-default fixture=generated-battery-free-nrom-v1 replay=frame3,ticks2144304,av-literal refusals=5,continuation-preserved result=pass'
  if ! grep -Fq "$SNAPSHOT_CONSUMER_MARKER" \
      "$SCRATCH/installed-snapshot.log"; then
    echo 'relocation consumer: installed snapshot replay or refusal marker is missing' >&2
    cat "$SCRATCH/installed-snapshot.log" >&2
    exit 1
  fi
  SNAPSHOT_LIBFUTURO_HASH=$(/usr/bin/shasum -a 256 \
    "$MOVED_PREFIX/lib/liblibfuturo.a" | awk '{print $1}')
  SNAPSHOT_CORE_HASH=$(/usr/bin/shasum -a 256 \
    "$MOVED_PREFIX/lib/libnesturbator.a" | awk '{print $1}')
  SNAPSHOT_CONSUMER_HASH=$(/usr/bin/shasum -a 256 \
    "$CONSUMER_BUILD/nesturbator_installed_consumer" | awk '{print $1}')
  printf 'snapshot-source-commit=%s\n' "$SOURCE_COMMIT" >> "$REPORT_TMP"
  printf 'snapshot-core-source-revision=2338608ab184f040620a30d17756f5e06a42d4e3\n' >> "$REPORT_TMP"
  printf 'snapshot-profile=nesturbator-ntsc-v1\n' >> "$REPORT_TMP"
  printf 'snapshot-effective-configuration=nesturbator-default\n' >> "$REPORT_TMP"
  printf 'snapshot-fixture=generated-battery-free-nrom-v1 bytes=%s\n' \
    "$((16 + 16 * 1024 + 8 * 1024))" >> "$REPORT_TMP"
  printf 'snapshot-route=Darwin/arm64 moved-prefix-only\n' >> "$REPORT_TMP"
  printf 'snapshot-child-exit=%s\n' "$SNAPSHOT_CHILD_EXIT" >> "$REPORT_TMP"
  printf 'snapshot-relocated-libfuturo-archive-sha256=sha256:%s\n' \
    "$SNAPSHOT_LIBFUTURO_HASH" >> "$REPORT_TMP"
  printf 'snapshot-relocated-core-archive-sha256=sha256:%s\n' \
    "$SNAPSHOT_CORE_HASH" >> "$REPORT_TMP"
  printf 'snapshot-consumer-executable-sha256=sha256:%s\n' \
    "$SNAPSHOT_CONSUMER_HASH" >> "$REPORT_TMP"
  printf 'snapshot-consumer-marker=%s\n' "$SNAPSHOT_CONSUMER_MARKER" \
    >> "$REPORT_TMP"
  printf 'snapshot-result-marker=source:2338608ab184f040620a30d17756f5e06a42d4e3 profile:nesturbator-ntsc-v1 configuration:nesturbator-default fixture:generated-battery-free-nrom-v1 child-exit:%s result:pass\n' \
    "$SNAPSHOT_CHILD_EXIT" >> "$REPORT_TMP"

  BATTERY_RECOVERY_MARKER='nesturbator_battery_snapshot: route=installed source=2338608ab184f040620a30d17756f5e06a42d4e3 release=v0.1.12 build=nesturbator-2338608ab184f040620a30d17756f5e06a42d4e3 profile=nesturbator-ntsc-v1 api=1 behavior=9 state-format=3 configuration=nesturbator-default fixture=generated-battery-mmc1-v1 bytes=40976 sha256=2282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9 media=full-span-8192,restored-literal capture=2 newer=3 restored=2 replay=frame3,ticks2144280,rgb5a5a5a,audio799 generation=changed-once,identical-unchanged refusal-vector=continuation,media,generation,selected-save,ack foreign=altered-mmc1,mmc3-refused failed-replacement=prior-commit-and-ack-preserved recovery=prior-exact,restored-selected,reopened-exact result=pass'
  BATTERY_ORACLE_MARKER='nesturbator_battery_snapshot_oracle_control: route=installed progress,video,audio,media=rejected result=pass'
  BATTERY_RECOVERY_STATUS=failed
  BATTERY_RECOVERY_EXIT=unavailable
  BATTERY_ORACLE_STATUS=failed
  BATTERY_ORACLE_EXIT=unavailable
  BATTERY_SNAPSHOT_STAGE_STATUS=failed
  BATTERY_SNAPSHOT_STAGE_EXIT=unavailable
  BATTERY_SNAPSHOT_STAGE_ELAPSED=0
  BATTERY_RECOVERY_REPORTED_MARKER=missing
  BATTERY_ORACLE_REPORTED_MARKER=missing
  BATTERY_SNAPSHOT_INVENTORY=missing
  BATTERY_SNAPSHOT_STARTED=$(date +%s)
  BATTERY_TEST_RUNNER="$SCRATCH/installed-battery-snapshot.sh"
  cat > "$BATTERY_TEST_RUNNER" <<'SH'
#!/bin/sh
set -u
consumer_build=$1
ctest_bin=$2
actual_tests=$("$ctest_bin" --test-dir "$consumer_build" -N \
  -R '^(nesturbator_installed_battery_snapshot|nesturbator_installed_battery_snapshot_oracle_control)$' \
  | sed -nE 's/^[[:space:]]*Test #[[:space:]]*[0-9]+: (.*)$/\1/p' \
  | LC_ALL=C sort)
expected_tests=$(printf '%s\n' \
  nesturbator_installed_battery_snapshot \
  nesturbator_installed_battery_snapshot_oracle_control | LC_ALL=C sort)
if [ "$actual_tests" != "$expected_tests" ]; then
  printf 'battery-snapshot-consumer-test-inventory=wrong\n'
  printf 'expected-tests:\n%s\nactual-tests:\n%s\n' \
    "$expected_tests" "$actual_tests"
  exit 2
fi
printf 'battery-snapshot-consumer-test-inventory=exact\n'
"$ctest_bin" --test-dir "$consumer_build" \
  -R '^nesturbator_installed_battery_snapshot$' \
  --output-on-failure --verbose --no-tests=error
recovery_exit=$?
"$ctest_bin" --test-dir "$consumer_build" \
  -R '^nesturbator_installed_battery_snapshot_oracle_control$' \
  --output-on-failure --verbose --no-tests=error
oracle_exit=$?
printf 'battery-snapshot-recovery-child-exit=%s\n' "$recovery_exit"
printf 'battery-snapshot-oracle-control-child-exit=%s\n' "$oracle_exit"
if [ "$recovery_exit" -ne 0 ] || [ "$oracle_exit" -ne 0 ]; then
  exit 1
fi
SH
  chmod 700 "$BATTERY_TEST_RUNNER"
  if run_isolated_stage installed-battery-snapshot 60 /usr/bin/env -i \
      "PATH=$TOOL_PATH" "HOME=$SCRATCH/home" "TMPDIR=$SCRATCH" \
      "DEVELOPER_DIR=$DEVELOPER_DIR" /bin/sh "$BATTERY_TEST_RUNNER" \
      "$CONSUMER_BUILD" "$CTEST_BIN"; then
    BATTERY_SNAPSHOT_STAGE_STATUS=passed
    BATTERY_SNAPSHOT_STAGE_EXIT=0
  else
    BATTERY_SNAPSHOT_STAGE_EXIT=$?
  fi
  BATTERY_SNAPSHOT_STAGE_ELAPSED=$(( $(date +%s) - BATTERY_SNAPSHOT_STARTED ))
  if [ -f "$SCRATCH/installed-battery-snapshot.log" ]; then
    BATTERY_SNAPSHOT_INVENTORY=$(sed -n \
      's/^battery-snapshot-consumer-test-inventory=//p' \
      "$SCRATCH/installed-battery-snapshot.log" | tail -n 1)
    BATTERY_RECOVERY_EXIT=$(sed -n \
      's/^battery-snapshot-recovery-child-exit=//p' \
      "$SCRATCH/installed-battery-snapshot.log" | tail -n 1)
    BATTERY_ORACLE_EXIT=$(sed -n \
      's/^battery-snapshot-oracle-control-child-exit=//p' \
      "$SCRATCH/installed-battery-snapshot.log" | tail -n 1)
    if grep -Fq "$BATTERY_RECOVERY_MARKER" \
        "$SCRATCH/installed-battery-snapshot.log"; then
      BATTERY_RECOVERY_REPORTED_MARKER=$BATTERY_RECOVERY_MARKER
      BATTERY_RECOVERY_STATUS=passed
    fi
    if grep -Fq "$BATTERY_ORACLE_MARKER" \
        "$SCRATCH/installed-battery-snapshot.log"; then
      BATTERY_ORACLE_REPORTED_MARKER=$BATTERY_ORACLE_MARKER
      BATTERY_ORACLE_STATUS=passed
    fi
  fi
  if [ "$BATTERY_SNAPSHOT_STAGE_STATUS" = passed ] &&
     [ "$BATTERY_SNAPSHOT_INVENTORY" = exact ] &&
     [ "$BATTERY_RECOVERY_EXIT" = 0 ] &&
     [ "$BATTERY_ORACLE_EXIT" = 0 ] &&
     [ "$BATTERY_RECOVERY_STATUS" = passed ] &&
     [ "$BATTERY_ORACLE_STATUS" = passed ]; then
    BATTERY_SNAPSHOT_RESULT=passed
  else
    BATTERY_SNAPSHOT_RESULT=failed
  fi
  BATTERY_LIBFUTURO_HASH=$(/usr/bin/shasum -a 256 \
    "$MOVED_PREFIX/lib/liblibfuturo.a" | awk '{print $1}')
  BATTERY_CORE_HASH=$(/usr/bin/shasum -a 256 \
    "$MOVED_PREFIX/lib/libnesturbator.a" | awk '{print $1}')
  BATTERY_CONSUMER_HASH=$(/usr/bin/shasum -a 256 \
    "$CONSUMER_BUILD/nesturbator_installed_consumer" | awk '{print $1}')
  printf 'battery-snapshot-source-commit=%s\n' "$SOURCE_COMMIT" >> "$REPORT_TMP"
  printf 'battery-snapshot-source-worktree=%s\n' "$SOURCE_WORKTREE" >> "$REPORT_TMP"
  printf 'battery-snapshot-source-worktree-fingerprint=sha256:%s\n' \
    "$SOURCE_WORKTREE_FINGERPRINT" >> "$REPORT_TMP"
  printf 'source_worktree_fingerprint=sha256:%s\n' \
    "$SOURCE_WORKTREE_FINGERPRINT" >> "$REPORT_TMP"
  printf 'battery-snapshot-core-release=v0.1.12\n' >> "$REPORT_TMP"
  printf 'battery-snapshot-core-source-revision=2338608ab184f040620a30d17756f5e06a42d4e3\n' >> "$REPORT_TMP"
  printf 'battery-snapshot-profile=nesturbator-ntsc-v1\n' >> "$REPORT_TMP"
  printf 'battery-snapshot-effective-configuration=nesturbator-default\n' >> "$REPORT_TMP"
  printf 'battery-snapshot-fixture=generated-battery-mmc1-v1\n' >> "$REPORT_TMP"
  printf 'battery-snapshot-fixture-bytes=40976\n' >> "$REPORT_TMP"
  printf 'battery-snapshot-fixture-sha256=sha256:2282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9\n' >> "$REPORT_TMP"
  printf 'battery-snapshot-route=Darwin/arm64 moved-prefix-only\n' >> "$REPORT_TMP"
  printf 'battery-snapshot-build-id=nesturbator-2338608ab184f040620a30d17756f5e06a42d4e3\n' >> "$REPORT_TMP"
  printf 'battery-snapshot-api-revision=1\n' >> "$REPORT_TMP"
  printf 'battery-snapshot-behavior-revision=9\n' >> "$REPORT_TMP"
  printf 'battery-snapshot-state-format-version=3\n' >> "$REPORT_TMP"
  printf 'battery-snapshot-test-inventory=%s\n' "$BATTERY_SNAPSHOT_INVENTORY" >> "$REPORT_TMP"
  printf 'battery-snapshot-result=%s\n' "$BATTERY_SNAPSHOT_RESULT" >> "$REPORT_TMP"
  printf 'battery-snapshot-stage-exit=%s\n' "$BATTERY_SNAPSHOT_STAGE_EXIT" >> "$REPORT_TMP"
  printf 'battery-snapshot-stage-elapsed-seconds=%s\n' \
    "$BATTERY_SNAPSHOT_STAGE_ELAPSED" >> "$REPORT_TMP"
  printf 'battery-snapshot-recovery-status=%s\n' "$BATTERY_RECOVERY_STATUS" >> "$REPORT_TMP"
  printf 'battery-snapshot-recovery-exit=%s\n' "$BATTERY_RECOVERY_EXIT" >> "$REPORT_TMP"
  printf 'battery-snapshot-recovery-marker=%s\n' \
    "$BATTERY_RECOVERY_REPORTED_MARKER" >> "$REPORT_TMP"
  printf 'battery-snapshot-oracle-control-status=%s\n' "$BATTERY_ORACLE_STATUS" >> "$REPORT_TMP"
  printf 'battery-snapshot-oracle-control-exit=%s\n' "$BATTERY_ORACLE_EXIT" >> "$REPORT_TMP"
  printf 'battery-snapshot-oracle-control-marker=%s\n' \
    "$BATTERY_ORACLE_REPORTED_MARKER" >> "$REPORT_TMP"
  printf 'battery-snapshot-relocated-libfuturo-archive-sha256=sha256:%s\n' \
    "$BATTERY_LIBFUTURO_HASH" >> "$REPORT_TMP"
  printf 'battery-snapshot-relocated-core-archive-sha256=sha256:%s\n' \
    "$BATTERY_CORE_HASH" >> "$REPORT_TMP"
  printf 'battery-snapshot-consumer-executable-sha256=sha256:%s\n' \
    "$BATTERY_CONSUMER_HASH" >> "$REPORT_TMP"

  SAVE_SCRATCH="$SCRATCH/save-restart"
  SAVE_WORK_DIR="$SAVE_SCRATCH/storage"
  FIXTURE_PATH="$SAVE_SCRATCH/generated-mmc1-battery.nes"
  SAVE_PATH="$SAVE_WORK_DIR/save.bin"
  /bin/mkdir -p "$SAVE_WORK_DIR"

  run_isolated_stage fixture-generation 10 /usr/bin/env -i \
    "PATH=$TOOL_PATH" "HOME=$SCRATCH/home" "TMPDIR=$SCRATCH" \
    "DEVELOPER_DIR=$DEVELOPER_DIR" \
    "$CONSUMER_BUILD/nesturbator_installed_consumer" \
    --emit-save-fixture "$FIXTURE_PATH"
  FIXTURE_MARKER='nesturbator_session: emitted generated-mmc1-battery bytes=40976 sha256=2282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9 fixture-source=project-authored-generated-test-data notice=Apache-2.0'
  if ! grep -Fq "$FIXTURE_MARKER" "$SCRATCH/fixture-generation.log"; then
    echo 'relocation consumer: fixture digest, provenance, or notice marker is missing' >&2
    cat "$SCRATCH/fixture-generation.log" >&2
    exit 1
  fi
  printf 'fixture-marker=generated-mmc1-battery,digest,provenance,notice:pass\n' >> "$REPORT_TMP"
  FIXTURE_HASH=$(/usr/bin/shasum -a 256 "$FIXTURE_PATH" | awk '{print $1}')
  if [ "$FIXTURE_HASH" != 2282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9 ]; then
    echo 'relocation consumer: generated fixture file digest did not match its literal identity' >&2
    exit 1
  fi
  printf 'fixture-digest=sha256:%s\n' "$FIXTURE_HASH" >> "$REPORT_TMP"
  printf 'fixture-source=project-authored-generated-test-data\n' >> "$REPORT_TMP"
  printf 'fixture-notice=Apache-2.0\n' >> "$REPORT_TMP"
  printf 'save-oracle=separate-literal-byte-and-continuation-expectations\n' >> "$REPORT_TMP"

  run_isolated_stage writer 20 /usr/bin/env -i \
    "PATH=$TOOL_PATH" "HOME=$SCRATCH/home" "TMPDIR=$SCRATCH" \
    "DEVELOPER_DIR=$DEVELOPER_DIR" \
    "$CONSUMER_BUILD/nesturbator_installed_consumer" \
    --save-writer "$SAVE_WORK_DIR"
  WRITER_MARKER='nesturbator_save_writer: guest-byte=3 generation=3 committed-payload=exact idempotent-commit=byte-identical result=pass'
  if ! grep -Fq "$WRITER_MARKER" "$SCRATCH/writer.log"; then
    echo 'relocation consumer: writer result marker is missing or incorrect' >&2
    cat "$SCRATCH/writer.log" >&2
    exit 1
  fi
  printf 'writer-marker=guest-byte:3,commit:exact,idempotent:byte-identical:pass\n' >> "$REPORT_TMP"
  run_isolated_stage committed-restorer 20 /usr/bin/env -i \
    "PATH=$TOOL_PATH" "HOME=$SCRATCH/home" "TMPDIR=$SCRATCH" \
    "DEVELOPER_DIR=$DEVELOPER_DIR" \
    "$CONSUMER_BUILD/nesturbator_installed_consumer" \
    --save-restorer "$SAVE_PATH"
  RESTORER_MARKER='nesturbator_save_restorer: imported-byte=3 continuation=4'
  if ! grep -Fq "$RESTORER_MARKER" "$SCRATCH/committed-restorer.log"; then
    echo 'relocation consumer: fresh process did not restore the committed save' >&2
    cat "$SCRATCH/committed-restorer.log" >&2
    exit 1
  fi
  printf 'committed-restorer-marker=imported-byte:3,continuation:4:pass\n' >> "$REPORT_TMP"
  run_isolated_stage failed-update 20 /usr/bin/env -i \
    "PATH=$TOOL_PATH" "HOME=$SCRATCH/home" "TMPDIR=$SCRATCH" \
    "DEVELOPER_DIR=$DEVELOPER_DIR" \
    "$CONSUMER_BUILD/nesturbator_installed_consumer" \
    --save-failed-writer "$SAVE_PATH"
  FAILURE_MARKER='nesturbator_save_failure_writer: prefix-write=failed-before-rename host-ack=previous-exact previous-payload=exact previous-generation=3 attempted-generation=1 stage-cleanup=pass result=pass'
  if ! grep -Fq "$FAILURE_MARKER" "$SCRATCH/failed-update.log"; then
    echo 'relocation consumer: controlled failed update did not preserve the prior save' >&2
    cat "$SCRATCH/failed-update.log" >&2
    exit 1
  fi
  printf 'failed-update-marker=prior-save,prior-ack,stage-cleanup:pass\n' >> "$REPORT_TMP"
  run_isolated_stage fresh-restorer 20 /usr/bin/env -i \
    "PATH=$TOOL_PATH" "HOME=$SCRATCH/home" "TMPDIR=$SCRATCH" \
    "DEVELOPER_DIR=$DEVELOPER_DIR" \
    "$CONSUMER_BUILD/nesturbator_installed_consumer" \
    --save-restorer "$SAVE_PATH"
  if ! grep -Fq "$RESTORER_MARKER" "$SCRATCH/fresh-restorer.log"; then
    echo 'relocation consumer: fresh process did not recover the prior committed save' >&2
    cat "$SCRATCH/fresh-restorer.log" >&2
    exit 1
  fi
  printf 'fresh-restorer-marker=imported-byte:3,continuation:4:pass\n' >> "$REPORT_TMP"
  /bin/rm -rf "$SAVE_SCRATCH"
  [ ! -e "$SAVE_SCRATCH" ] || { echo 'relocation consumer: save scratch cleanup failed' >&2; exit 1; }
  printf 'save-restart=writer,committed-fresh-restorer,failed-update,fresh-restorer result=pass\n' >> "$REPORT_TMP"
  printf 'prior-save-recovery=old-commit-old-ack-fresh-restorer result=pass\n' >> "$REPORT_TMP"
  printf 'save-scratch-cleanup=passed\n' >> "$REPORT_TMP"
fi
if [ "$MODE" = "--save-restart" ] ||
   [ "$MODE" = "--muhtari-save-restart" ]; then
  SAVE_SCRATCH="$SCRATCH/muhtari-save-restart"
  SAVE_WORK_DIR="$SAVE_SCRATCH/storage"
  SAVE_PATH="$SAVE_WORK_DIR/battery.save"
  MUHTARI_SAVE_EXECUTABLE="$CONSUMER_BUILD/muhtari_save_installed_consumer"
  /bin/mkdir -p "$SAVE_WORK_DIR"
  if [ ! -x "$MUHTARI_SAVE_EXECUTABLE" ]; then
    echo 'relocation consumer: installed Muhtari save executable is missing' >&2
    exit 1
  fi
  MUHTARI_SAVE_EXECUTABLE_HASH=$(/usr/bin/shasum -a 256 \
    "$MUHTARI_SAVE_EXECUTABLE" | awk '{print $1}')
  MUHTARI_SAVE_LIBFUTURO_HASH=$(/usr/bin/shasum -a 256 \
    "$MOVED_PREFIX/lib/liblibfuturo.a" | awk '{print $1}')
  MUHTARI_SAVE_CORE_HASH=$(/usr/bin/shasum -a 256 \
    "$MOVED_PREFIX/lib/libmuhtari.a" | awk '{print $1}')
  MUHTARI_SAVE_SOURCE_MARKER='muhtari_save_writer: source=d5fd241e3f4d701d73867cc2e465c56a6fe6793d fixture=4642ded6d026f456acf798a43efb081b76987018@10f5bc279d8147b3348e102ca9f7e4dc496dd31b5099adb2ef64320e987fb4d4 license=MIT extent=34816 progress=1/1 committed=rename-readback'
  MUHTARI_RESTORER_MARKER='muhtari_save_restorer: source=d5fd241e3f4d701d73867cc2e465c56a6fe6793d fixture=4642ded6d026f456acf798a43efb081b76987018@10f5bc279d8147b3348e102ca9f7e4dc496dd31b5099adb2ef64320e987fb4d4 configuration=muhtari-ntsc-battery-diagnostic media=muhtari-battery-v1 extent=34816 import=before-guest-work restored=1/1 continuation=2/2 result=pass'
  MUHTARI_REJECTION_MARKER='muhtari_save_rejections: cases=10 invalid-imports=0 unchanged-live-span=34816 valid-import=before-guest-work result=pass'
  MUHTARI_FAILURE_MARKER='muhtari_save_failure_writer: prefix-write=failed-before-rename committed-file=previous-exact host-ack=previous-exact previous=1/1 attempted=2/2 generation-ack=preserved stage-cleanup=pass result=pass'
  MUHTARI_RECOVERY_MARKER='muhtari_save_recovery: prior-commit=1/1 recovered=1/1 continuation=2/2 process=fresh result=pass'

  MUHTARI_SAVE_WRITER_STARTED=$(date +%s)
  run_isolated_stage muhtari-save-writer 45 /usr/bin/env -i \
    "PATH=$TOOL_PATH" "HOME=$SCRATCH/home" "TMPDIR=$SCRATCH" \
    "DEVELOPER_DIR=$DEVELOPER_DIR" "$MUHTARI_SAVE_EXECUTABLE" \
    --writer "$MUHTARI_SAVE_FIXTURE_PATH" "$SAVE_PATH"
  MUHTARI_SAVE_WRITER_ELAPSED=$(($(date +%s) - MUHTARI_SAVE_WRITER_STARTED))
  if ! grep -Fq "$MUHTARI_SAVE_SOURCE_MARKER" \
      "$SCRATCH/muhtari-save-writer.log"; then
    echo 'relocation consumer: Muhtari save writer marker is missing or incorrect' >&2
    cat "$SCRATCH/muhtari-save-writer.log" >&2
    exit 1
  fi
  printf 'muhtari-save-writer=passed\n' >> "$REPORT_TMP"
  printf 'muhtari-save-writer-marker=%s generation=core-token-only\n' \
    "$MUHTARI_SAVE_SOURCE_MARKER" >> "$REPORT_TMP"
  printf 'muhtari-save-writer-exit=0\n' >> "$REPORT_TMP"
  printf 'muhtari-save-writer-elapsed-seconds=%s\n' \
    "$MUHTARI_SAVE_WRITER_ELAPSED" >> "$REPORT_TMP"

  MUHTARI_SAVE_RESTORER_STARTED=$(date +%s)
  run_isolated_stage muhtari-save-fresh-restorer 45 /usr/bin/env -i \
    "PATH=$TOOL_PATH" "HOME=$SCRATCH/home" "TMPDIR=$SCRATCH" \
    "DEVELOPER_DIR=$DEVELOPER_DIR" "$MUHTARI_SAVE_EXECUTABLE" \
    --restorer "$MUHTARI_SAVE_FIXTURE_PATH" "$SAVE_PATH"
  MUHTARI_SAVE_RESTORER_ELAPSED=$(($(date +%s) - MUHTARI_SAVE_RESTORER_STARTED))
  if ! grep -Fq "$MUHTARI_RESTORER_MARKER" \
      "$SCRATCH/muhtari-save-fresh-restorer.log"; then
    echo 'relocation consumer: fresh Muhtari process did not restore and continue 1/1 to 2/2' >&2
    cat "$SCRATCH/muhtari-save-fresh-restorer.log" >&2
    exit 1
  fi
  if ! grep -Fq "$MUHTARI_REJECTION_MARKER" \
      "$SCRATCH/muhtari-save-fresh-restorer.log"; then
    echo 'relocation consumer: invalid Muhtari envelopes did not prove pre-import preservation' >&2
    cat "$SCRATCH/muhtari-save-fresh-restorer.log" >&2
    exit 1
  fi
  printf 'muhtari-save-fresh-restorer=passed\n' >> "$REPORT_TMP"
  printf 'muhtari-save-restorer-marker=%s\n' \
    "$MUHTARI_RESTORER_MARKER" >> "$REPORT_TMP"
  printf 'muhtari-save-rejections-marker=%s\n' \
    "$MUHTARI_REJECTION_MARKER" >> "$REPORT_TMP"
  printf 'muhtari-save-restorer-exit=0\n' >> "$REPORT_TMP"
  printf 'muhtari-save-restorer-elapsed-seconds=%s\n' \
    "$MUHTARI_SAVE_RESTORER_ELAPSED" >> "$REPORT_TMP"

  MUHTARI_SAVE_FAILURE_STARTED=$(date +%s)
  run_isolated_stage muhtari-save-failed-update 45 /usr/bin/env -i \
    "PATH=$TOOL_PATH" "HOME=$SCRATCH/home" "TMPDIR=$SCRATCH" \
    "DEVELOPER_DIR=$DEVELOPER_DIR" "$MUHTARI_SAVE_EXECUTABLE" \
    --failed-update "$MUHTARI_SAVE_FIXTURE_PATH" "$SAVE_PATH"
  MUHTARI_SAVE_FAILURE_ELAPSED=$(($(date +%s) - MUHTARI_SAVE_FAILURE_STARTED))
  if ! grep -Fq "$MUHTARI_FAILURE_MARKER" \
      "$SCRATCH/muhtari-save-failed-update.log"; then
    echo 'relocation consumer: partial Muhtari update did not preserve the prior commit' >&2
    cat "$SCRATCH/muhtari-save-failed-update.log" >&2
    exit 1
  fi
  printf 'muhtari-save-failed-update=passed\n' >> "$REPORT_TMP"
  printf 'muhtari-save-failure-marker=%s\n' \
    "$MUHTARI_FAILURE_MARKER" >> "$REPORT_TMP"
  printf 'muhtari-save-failed-update-exit=0\n' >> "$REPORT_TMP"
  printf 'muhtari-save-failed-update-elapsed-seconds=%s\n' \
    "$MUHTARI_SAVE_FAILURE_ELAPSED" >> "$REPORT_TMP"

  MUHTARI_SAVE_RECOVERY_STARTED=$(date +%s)
  run_isolated_stage muhtari-save-recovery 45 /usr/bin/env -i \
    "PATH=$TOOL_PATH" "HOME=$SCRATCH/home" "TMPDIR=$SCRATCH" \
    "DEVELOPER_DIR=$DEVELOPER_DIR" "$MUHTARI_SAVE_EXECUTABLE" \
    --recovery "$MUHTARI_SAVE_FIXTURE_PATH" "$SAVE_PATH"
  MUHTARI_SAVE_RECOVERY_ELAPSED=$(($(date +%s) - MUHTARI_SAVE_RECOVERY_STARTED))
  if ! grep -Fq "$MUHTARI_RECOVERY_MARKER" \
      "$SCRATCH/muhtari-save-recovery.log"; then
    echo 'relocation consumer: distinct fresh Muhtari recovery did not restore the previous commit' >&2
    cat "$SCRATCH/muhtari-save-recovery.log" >&2
    exit 1
  fi
  printf 'muhtari-save-recovery=passed\n' >> "$REPORT_TMP"
  printf 'muhtari-save-recovery-marker=%s\n' \
    "$MUHTARI_RECOVERY_MARKER" >> "$REPORT_TMP"
  printf 'muhtari-save-recovery-exit=0\n' >> "$REPORT_TMP"
  printf 'muhtari-save-recovery-elapsed-seconds=%s\n' \
    "$MUHTARI_SAVE_RECOVERY_ELAPSED" >> "$REPORT_TMP"

  MUHTARI_SAVE_ORACLE_WRAPPER="$SCRATCH/ExpectMuhtariOracleFailure.cmake"
  /bin/cp "$ROOT_DIR/cmake/ExpectMuhtariOracleFailure.cmake" \
    "$MUHTARI_SAVE_ORACLE_WRAPPER"
  MUHTARI_SAVE_ORACLE_STARTED=$(date +%s)
  if run_isolated_stage muhtari-save-oracle-negative-control 70 \
      /usr/bin/env -i "PATH=$TOOL_PATH" "HOME=$SCRATCH/home" \
      "TMPDIR=$SCRATCH" "DEVELOPER_DIR=$DEVELOPER_DIR" "$CMAKE_BIN" \
      "-DMUHTARI_SAVE_EXE=$MUHTARI_SAVE_EXECUTABLE" \
      "-DMUHTARI_SAVE_FIXTURE=$MUHTARI_SAVE_FIXTURE_PATH" \
      -P "$MUHTARI_SAVE_ORACLE_WRAPPER"; then
    :
  else
    echo 'relocation consumer: Muhtari save oracle mismatch control failed' >&2
    cat "$SCRATCH/muhtari-save-oracle-negative-control.log" >&2
    exit 1
  fi
  MUHTARI_SAVE_ORACLE_ELAPSED=$(($(date +%s) - MUHTARI_SAVE_ORACLE_STARTED))
  MUHTARI_SAVE_ORACLE_MARKER='muhtari_save_oracle_negative_control: detected expected full-span mismatch normal-exit=0 wrong-exit=1'
  if ! grep -Fq "$MUHTARI_SAVE_ORACLE_MARKER" \
      "$SCRATCH/muhtari-save-oracle-negative-control.log"; then
    echo 'relocation consumer: save oracle wrapper omitted its exact mismatch marker' >&2
    cat "$SCRATCH/muhtari-save-oracle-negative-control.log" >&2
    exit 1
  fi
  printf 'muhtari-save-oracle-negative-control=passed\n' >> "$REPORT_TMP"
  printf 'muhtari-save-oracle-negative-control-exit=0\n' >> "$REPORT_TMP"
  printf 'muhtari-save-oracle-negative-control-elapsed-seconds=%s\n' \
    "$MUHTARI_SAVE_ORACLE_ELAPSED" >> "$REPORT_TMP"
  printf 'muhtari-save-oracle-negative-control-executable-sha256=sha256:%s\n' \
    "$MUHTARI_SAVE_EXECUTABLE_HASH" >> "$REPORT_TMP"
  printf 'muhtari-save-oracle-negative-control-marker=%s\n' \
    "$MUHTARI_SAVE_ORACLE_MARKER" >> "$REPORT_TMP"
  printf 'muhtari-save-restart=writer,committed-fresh-restorer,failed-update,fresh-recovery result=pass\n' \
    >> "$REPORT_TMP"
  printf 'muhtari-save-executable-sha256=sha256:%s\n' \
    "$MUHTARI_SAVE_EXECUTABLE_HASH" >> "$REPORT_TMP"
  printf 'muhtari-save-libfuturo-archive-sha256=sha256:%s\n' \
    "$MUHTARI_SAVE_LIBFUTURO_HASH" >> "$REPORT_TMP"
  printf 'muhtari-save-core-archive-sha256=sha256:%s\n' \
    "$MUHTARI_SAVE_CORE_HASH" >> "$REPORT_TMP"
fi

if [ "$MODE" = "--battery-fresh-process-snapshot" ]; then
  BATTERY_FRESH_PROCESS_JUNIT="$SCRATCH/installed-battery-fresh-process.junit.xml"
  BATTERY_FRESH_PROCESS_JUNIT_REL="relocate-$NONCE-battery-fresh-process.junit.xml"
  BATTERY_FRESH_PROCESS_JUNIT_PATH="$REPORT_ROOT/$BATTERY_FRESH_PROCESS_JUNIT_REL"
  BATTERY_FRESH_PROCESS_STARTED=$(date +%s)
  if run_isolated_stage installed-battery-fresh-process 180 \
      /usr/bin/env -i \
      "PATH=$TOOL_PATH" "HOME=$SCRATCH/home" "TMPDIR=$SCRATCH" \
      "DEVELOPER_DIR=$DEVELOPER_DIR" \
      "$CTEST_BIN" --test-dir "$CONSUMER_BUILD" \
      -R '^nesturbator_installed_battery_fresh_process_snapshot$' \
      --output-on-failure --verbose --no-tests=error \
      --output-junit "$BATTERY_FRESH_PROCESS_JUNIT"; then
    BATTERY_FRESH_PROCESS_EXIT=0
    BATTERY_FRESH_PROCESS_STATUS=passed
  else
    BATTERY_FRESH_PROCESS_EXIT=$?
    BATTERY_FRESH_PROCESS_STATUS=failed
  fi
  BATTERY_FRESH_PROCESS_ELAPSED=$(( $(date +%s) - BATTERY_FRESH_PROCESS_STARTED ))
  if [ -f "$BATTERY_FRESH_PROCESS_JUNIT" ]; then
    /bin/mkdir -p "$REPORT_ROOT"
    /bin/cp "$BATTERY_FRESH_PROCESS_JUNIT" "$BATTERY_FRESH_PROCESS_JUNIT_PATH"
  fi
  BATTERY_FRESH_PROCESS_LOG="$SCRATCH/installed-battery-fresh-process.log"
  if [ "$BATTERY_FRESH_PROCESS_STATUS" != passed ] ||
     [ ! -f "$BATTERY_FRESH_PROCESS_JUNIT_PATH" ]; then
    echo 'relocation consumer: installed battery fresh-process route failed or omitted its JUnit report' >&2
    [ ! -f "$BATTERY_FRESH_PROCESS_LOG" ] || cat "$BATTERY_FRESH_PROCESS_LOG" >&2
    exit "${BATTERY_FRESH_PROCESS_EXIT:-1}"
  fi
  BATTERY_FRESH_PROCESS_EVENTS="$SCRATCH/installed-battery-fresh-process.events"
  if ! sed 's/^[[:space:]]*[0-9][0-9]*: //' \
      "$BATTERY_FRESH_PROCESS_LOG" > "$BATTERY_FRESH_PROCESS_EVENTS"; then
    echo 'relocation consumer: could not normalize installed battery CTest events' >&2
    exit 1
  fi
  BATTERY_FRESH_PROCESS_LOG="$BATTERY_FRESH_PROCESS_EVENTS"
  if ! grep -Fq 'event=supervisor-success' "$BATTERY_FRESH_PROCESS_LOG" ||
     ! grep -Fq 'event=a-exit status=0' "$BATTERY_FRESH_PROCESS_LOG" ||
     ! grep -Fq 'event=b-exit status=0' "$BATTERY_FRESH_PROCESS_LOG" ||
     ! grep -Fq 'event=a-success-closed-and-destroyed' "$BATTERY_FRESH_PROCESS_LOG" ||
     ! grep -Fq 'event=b-success' "$BATTERY_FRESH_PROCESS_LOG" ||
     ! grep -Fq 'event=battery-save-custody-r3-imported-r2-restored-r2-committed' \
       "$BATTERY_FRESH_PROCESS_LOG"; then
    echo 'relocation consumer: installed battery fresh-process lifecycle or save custody evidence is incomplete' >&2
    cat "$BATTERY_FRESH_PROCESS_LOG" >&2
    exit 1
  fi
  BATTERY_FRESH_ORACLE_BASELINE='event=battery-oracle-baseline result=pass frame=3 ticks=2144280 rgb=5a5a5a audio=799 full-media=pass'
  if [ "$(grep -Fxc 'event=battery-oracle-controls-start' "$BATTERY_FRESH_PROCESS_LOG")" -ne 1 ] ||
     [ "$(grep -Fxc 'event=battery-oracle-controls-pass' "$BATTERY_FRESH_PROCESS_LOG")" -ne 1 ] ||
     [ "$(grep -Fxc "$BATTERY_FRESH_ORACLE_BASELINE" "$BATTERY_FRESH_PROCESS_LOG")" -ne 1 ]; then
    echo 'relocation consumer: installed wrong-oracle baseline or completion event is missing' >&2
    cat "$BATTERY_FRESH_PROCESS_LOG" >&2
    exit 1
  fi
  for oracle_case in progress video audio media; do
    BATTERY_FRESH_ORACLE_EVENT="event=battery-oracle-control name=$oracle_case expected=$oracle_case actual=$oracle_case result=pass"
    if [ "$(grep -Fxc "$BATTERY_FRESH_ORACLE_EVENT" "$BATTERY_FRESH_PROCESS_LOG")" -ne 1 ]; then
      echo "relocation consumer: installed wrong-oracle control is missing: $oracle_case" >&2
      cat "$BATTERY_FRESH_PROCESS_LOG" >&2
      exit 1
    fi
  done
  BATTERY_FRESH_REFUSAL_BASELINE_COUNT=$(grep -Ec \
    '^event=battery-b-refusal-baseline generation=[1-9][0-9]* media=R2 selected-save=R3 result=pass$' \
    "$BATTERY_FRESH_PROCESS_LOG")
  BATTERY_FRESH_REFUSAL_BASELINE_GENERATION=$(sed -n \
    's/^event=battery-b-refusal-baseline generation=\([1-9][0-9]*\) media=R2 selected-save=R3 result=pass$/\1/p' \
    "$BATTERY_FRESH_PROCESS_LOG")
  if [ "$BATTERY_FRESH_REFUSAL_BASELINE_COUNT" -ne 1 ] ||
     [ -z "$BATTERY_FRESH_REFUSAL_BASELINE_GENERATION" ]; then
    echo 'relocation consumer: installed battery generation baseline is missing or duplicated' >&2
    cat "$BATTERY_FRESH_PROCESS_LOG" >&2
    exit 1
  fi
  BATTERY_FRESH_B_SUCCESS_LINE=$(awk '/^event=b-success$/ { print NR }' "$BATTERY_FRESH_PROCESS_LOG")
  BATTERY_FRESH_ORACLE_START_LINE=$(awk '/^event=battery-oracle-controls-start$/ { print NR }' "$BATTERY_FRESH_PROCESS_LOG")
  BATTERY_FRESH_ORACLE_BASELINE_LINE=$(awk -v event="$BATTERY_FRESH_ORACLE_BASELINE" '$0 == event { print NR }' "$BATTERY_FRESH_PROCESS_LOG")
  BATTERY_FRESH_ORACLE_CONTROL_LINE=$(awk '/^event=battery-oracle-control name=progress / { print NR }' "$BATTERY_FRESH_PROCESS_LOG")
  BATTERY_FRESH_ORACLE_PASS_LINE=$(awk '/^event=battery-oracle-controls-pass$/ { print NR }' "$BATTERY_FRESH_PROCESS_LOG")
  BATTERY_FRESH_SUPERVISOR_SUCCESS_LINE=$(awk '/^event=supervisor-success$/ { print NR }' "$BATTERY_FRESH_PROCESS_LOG")
  if [ -z "$BATTERY_FRESH_B_SUCCESS_LINE" ] ||
     [ -z "$BATTERY_FRESH_ORACLE_START_LINE" ] ||
     [ -z "$BATTERY_FRESH_ORACLE_BASELINE_LINE" ] ||
     [ -z "$BATTERY_FRESH_ORACLE_CONTROL_LINE" ] ||
     [ -z "$BATTERY_FRESH_ORACLE_PASS_LINE" ] ||
     [ -z "$BATTERY_FRESH_SUPERVISOR_SUCCESS_LINE" ] ||
     [ "$BATTERY_FRESH_B_SUCCESS_LINE" -ge "$BATTERY_FRESH_ORACLE_START_LINE" ] ||
     [ "$BATTERY_FRESH_ORACLE_START_LINE" -ge "$BATTERY_FRESH_ORACLE_BASELINE_LINE" ] ||
     [ "$BATTERY_FRESH_ORACLE_BASELINE_LINE" -ge "$BATTERY_FRESH_ORACLE_CONTROL_LINE" ] ||
     [ "$BATTERY_FRESH_ORACLE_CONTROL_LINE" -ge "$BATTERY_FRESH_ORACLE_PASS_LINE" ] ||
     [ "$BATTERY_FRESH_ORACLE_PASS_LINE" -ge "$BATTERY_FRESH_SUPERVISOR_SUCCESS_LINE" ]; then
    echo 'relocation consumer: installed wrong-oracle controls were not ordered after the passing B route' >&2
    cat "$BATTERY_FRESH_PROCESS_LOG" >&2
    exit 1
  fi
  BATTERY_FRESH_IDENTITY=$(sed -n 's/^event=snapshot-identity //p' \
    "$BATTERY_FRESH_PROCESS_LOG")
  BATTERY_FRESH_CLOSE=$(sed -n \
    's/^event=checkpoint-close bytes=\([0-9][0-9]*\) sha256=\([0-9a-f]\{64\}\)$/\1 \2/p' \
    "$BATTERY_FRESH_PROCESS_LOG")
  BATTERY_FRESH_REOPEN=$(sed -n \
    's/^event=checkpoint-reopened bytes=\([0-9][0-9]*\) sha256=\([0-9a-f]\{64\}\)$/\1 \2/p' \
    "$BATTERY_FRESH_PROCESS_LOG")
  if [ "$(grep -c '^event=snapshot-identity ' "$BATTERY_FRESH_PROCESS_LOG")" -ne 1 ] ||
     ! printf '%s\n' "$BATTERY_FRESH_IDENTITY" | grep -Eq \
       '^envelope-version=2 header-bytes=388 total-bytes=[0-9]+ native-bytes=[0-9]+ state-format=3 core-abi=1 behavior-revision=9 core-build=nesturbator-2338608ab184f040620a30d17756f5e06a42d4e3 libfuturo-build=sha256:[0-9a-f]{64} profile=nesturbator-ntsc-v1 configuration=nesturbator-default options=nesturbator-options-none-v1 content-bytes=40976 content-sha256=[0-9a-f]{64}$' ||
     [ -z "$BATTERY_FRESH_CLOSE" ] || [ "$BATTERY_FRESH_CLOSE" != "$BATTERY_FRESH_REOPEN" ]; then
    echo 'relocation consumer: installed checkpoint identity or close/reopen digest is invalid' >&2
    cat "$BATTERY_FRESH_PROCESS_LOG" >&2
    exit 1
  fi
  BATTERY_FRESH_CHECKPOINT_BYTES=${BATTERY_FRESH_CLOSE%% *}
  BATTERY_FRESH_CHECKPOINT_HASH=${BATTERY_FRESH_CLOSE#* }
  BATTERY_FRESH_EVENT_COUNT=$(awk '/^event=/ { count += 1 } END { print count + 0 }' \
    "$BATTERY_FRESH_PROCESS_LOG")
  BATTERY_FRESH_LIBFUTURO_HASH=$(/usr/bin/shasum -a 256 \
    "$MOVED_PREFIX/lib/liblibfuturo.a" | awk '{print $1}')
  BATTERY_FRESH_CORE_HASH=$(/usr/bin/shasum -a 256 \
    "$MOVED_PREFIX/lib/libnesturbator.a" | awk '{print $1}')
  BATTERY_FRESH_CONSUMER_HASH=$(/usr/bin/shasum -a 256 \
    "$CONSUMER_BUILD/nesturbator_installed_consumer" | awk '{print $1}')
  BATTERY_FRESH_SUPERVISOR_HASH=$(/usr/bin/shasum -a 256 \
    "$CONSUMER_SOURCE/nesturbator_fresh_process_supervisor.sh" | awk '{print $1}')
  BATTERY_FRESH_HELPER_HASH=$(/usr/bin/shasum -a 256 \
    "$CONSUMER_SOURCE/process-tree-cleanup.sh" | awk '{print $1}')
  BATTERY_FRESH_LIBFUTURO_CONFIG_HASH=$(/usr/bin/shasum -a 256 \
    "$MOVED_PREFIX/lib/cmake/libfuturo/libfuturoTargets.cmake" | awk '{print $1}')
  BATTERY_FRESH_CORE_CONFIG_HASH=$(/usr/bin/shasum -a 256 \
    "$MOVED_PREFIX/lib/cmake/nesturbator/nesturbatorTargets.cmake" | awk '{print $1}')
  printf 'installed-battery-fresh-process-source-commit=%s\n' "$SOURCE_COMMIT" >> "$REPORT_TMP"
  printf 'installed-battery-fresh-process-source-worktree=%s\n' "$SOURCE_WORKTREE" >> "$REPORT_TMP"
  printf 'installed-battery-fresh-process-source-worktree-fingerprint=sha256:%s\n' \
    "$SOURCE_WORKTREE_FINGERPRINT" >> "$REPORT_TMP"
  printf 'installed-battery-fresh-process-core-release=v0.1.12\n' >> "$REPORT_TMP"
  printf 'installed-battery-fresh-process-core-source-revision=2338608ab184f040620a30d17756f5e06a42d4e3\n' >> "$REPORT_TMP"
  printf 'installed-battery-fresh-process-profile=nesturbator-ntsc-v1\n' >> "$REPORT_TMP"
  printf 'installed-battery-fresh-process-effective-configuration=nesturbator-default\n' >> "$REPORT_TMP"
  printf 'installed-battery-fresh-process-fixture=generated-battery-mmc1-v1 bytes=40976 sha256=2282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9\n' >> "$REPORT_TMP"
  printf 'installed-battery-fresh-process-route=Darwin/arm64 moved-prefix-only\n' >> "$REPORT_TMP"
  printf 'installed-battery-fresh-process-status=%s\n' "$BATTERY_FRESH_PROCESS_STATUS" >> "$REPORT_TMP"
  printf 'installed-battery-fresh-process-child-exit=%s\n' "$BATTERY_FRESH_PROCESS_EXIT" >> "$REPORT_TMP"
  printf 'installed-battery-fresh-process-elapsed-seconds=%s\n' "$BATTERY_FRESH_PROCESS_ELAPSED" >> "$REPORT_TMP"
  printf 'installed-battery-fresh-process-a-exit=0\n' >> "$REPORT_TMP"
  printf 'installed-battery-fresh-process-b-exit=0\n' >> "$REPORT_TMP"
  printf 'installed-battery-fresh-process-checkpoint-bytes=%s\n' "$BATTERY_FRESH_CHECKPOINT_BYTES" >> "$REPORT_TMP"
  printf 'installed-battery-fresh-process-checkpoint-sha256=sha256:%s\n' "$BATTERY_FRESH_CHECKPOINT_HASH" >> "$REPORT_TMP"
  printf 'installed-battery-fresh-process-runtime-identity=%s\n' "$BATTERY_FRESH_IDENTITY" >> "$REPORT_TMP"
  printf 'installed-battery-fresh-process-event-count=%s\n' "$BATTERY_FRESH_EVENT_COUNT" >> "$REPORT_TMP"
  printf 'installed-battery-fresh-process-junit=%s\n' "$BATTERY_FRESH_PROCESS_JUNIT_REL" >> "$REPORT_TMP"
  awk '/event=/ { sub(/^.*event=/, "event="); if ($0 ~ /^event=/) print "installed-battery-fresh-process-" $0 }' \
    "$BATTERY_FRESH_PROCESS_LOG" >> "$REPORT_TMP"
  printf 'installed-battery-fresh-process-relocated-libfuturo-archive-sha256=sha256:%s\n' "$BATTERY_FRESH_LIBFUTURO_HASH" >> "$REPORT_TMP"
  printf 'installed-battery-fresh-process-relocated-core-archive-sha256=sha256:%s\n' "$BATTERY_FRESH_CORE_HASH" >> "$REPORT_TMP"
  printf 'installed-battery-fresh-process-consumer-executable-sha256=sha256:%s\n' "$BATTERY_FRESH_CONSUMER_HASH" >> "$REPORT_TMP"
  printf 'installed-battery-fresh-process-supervisor-sha256=sha256:%s\n' "$BATTERY_FRESH_SUPERVISOR_HASH" >> "$REPORT_TMP"
  printf 'installed-battery-fresh-process-helper-sha256=sha256:%s\n' "$BATTERY_FRESH_HELPER_HASH" >> "$REPORT_TMP"
  printf 'installed-battery-fresh-process-libfuturo-package-targets-sha256=sha256:%s\n' "$BATTERY_FRESH_LIBFUTURO_CONFIG_HASH" >> "$REPORT_TMP"
  printf 'installed-battery-fresh-process-core-package-targets-sha256=sha256:%s\n' "$BATTERY_FRESH_CORE_CONFIG_HASH" >> "$REPORT_TMP"
  printf 'installed-battery-fresh-process-wrong-oracle-controls=progress,video,audio,full-media independently rejected after passing baseline\n' >> "$REPORT_TMP"
  printf 'installed-battery-fresh-process-result=separate-A-and-B,close-exit-before-import-and-restore,R3-imported-before-advance,R2-restored,R3-preserved-through-prefailure,R2-readback-before-ack,literal-replay=frame3,ticks2144280,video=5a5a5a,audio=799-silence,media=full-8192,wrong-oracle-controls=progress-video-audio-full-media,refusal-baseline-generation=%s result=pass\n' \
    "$BATTERY_FRESH_REFUSAL_BASELINE_GENERATION" >> "$REPORT_TMP"
elif [ "$MODE" = "--fresh-process-snapshot" ]; then
  FRESH_ROOT="$SCRATCH/fresh-process-relocated"
  FRESH_BIN="$FRESH_ROOT/bin"
  FRESH_SCRIPTS="$FRESH_ROOT/scripts"
  FRESH_CONSUMER_SOURCE="$CONSUMER_BUILD/nesturbator_installed_consumer"
  FRESH_CONSUMER="$FRESH_BIN/nesturbator_installed_consumer"
  FRESH_SUPERVISOR="$FRESH_BIN/nesturbator_fresh_process_supervisor.sh"
  FRESH_PROCESS_TREE_HELPER="$FRESH_SCRIPTS/process-tree-cleanup.sh"
  FRESH_LOG="$SCRATCH/fresh-process-snapshot.log"
  /bin/mkdir -p "$FRESH_BIN" "$FRESH_SCRIPTS"
  /bin/cp "$ROOT_DIR/tests/nesturbator_fresh_process_supervisor.sh" \
    "$FRESH_SUPERVISOR"
  /bin/cp "$ROOT_DIR/scripts/process-tree-cleanup.sh" \
    "$FRESH_PROCESS_TREE_HELPER"
  /bin/cp "$FRESH_CONSUMER_SOURCE" "$FRESH_CONSUMER"
  /bin/chmod 700 "$FRESH_CONSUMER"
  if [ ! -x "$FRESH_CONSUMER" ] ||
     ! cmp -s "$FRESH_CONSUMER_SOURCE" "$FRESH_CONSUMER"; then
    echo 'relocation consumer: fresh-process executable was not copied exactly' >&2
    exit 1
  fi

  if run_isolated_stage fresh-process-snapshot 120 /usr/bin/env -i \
      "PATH=$TOOL_PATH" "HOME=$SCRATCH/home" "TMPDIR=$SCRATCH" \
      "DEVELOPER_DIR=$DEVELOPER_DIR" \
      "LF_PROCESS_TREE_HELPER=$FRESH_PROCESS_TREE_HELPER" \
      "LF_FRESH_PROCESS_TIMEOUT_SECONDS=25" /bin/sh "$FRESH_SUPERVISOR" \
      "$FRESH_CONSUMER"; then
    FRESH_PROCESS_STATUS=passed
  else
    FRESH_PROCESS_EXIT=$?
    echo 'relocation consumer: fresh-process supervisor failed' >&2
    cat "$FRESH_LOG" >&2 2>/dev/null || true
    exit "$FRESH_PROCESS_EXIT"
  fi
  if ! grep -Fq 'event=supervisor-success' "$FRESH_LOG" ||
     ! grep -Fq 'event=a-exit status=0' "$FRESH_LOG" ||
     ! grep -Fq 'event=b-exit status=0' "$FRESH_LOG" ||
     ! grep -Eq '^event=b-wrong-oracle-rejected status=[1-9][0-9]*$' \
       "$FRESH_LOG"; then
    echo 'relocation consumer: fresh-process lifecycle evidence is incomplete' >&2
    cat "$FRESH_LOG" >&2
    exit 1
  fi
  FRESH_CLOSE_COUNT=$(awk '/^event=checkpoint-close / { count += 1 } END { print count + 0 }' "$FRESH_LOG")
  FRESH_REOPEN_COUNT=$(awk '/^event=checkpoint-reopened / { count += 1 } END { print count + 0 }' "$FRESH_LOG")
  FRESH_CLOSE_EVENT=$(awk '/^event=checkpoint-close / { print; exit }' "$FRESH_LOG")
  FRESH_REOPEN_EVENT=$(awk '/^event=checkpoint-reopened / { print; exit }' "$FRESH_LOG")
  if [ "$FRESH_CLOSE_COUNT" -ne 1 ] || [ "$FRESH_REOPEN_COUNT" -ne 1 ] ||
     [ -z "$FRESH_CLOSE_EVENT" ] || [ -z "$FRESH_REOPEN_EVENT" ]; then
    echo 'relocation consumer: fresh-process byte lifecycle markers are missing or duplicated' >&2
    cat "$FRESH_LOG" >&2
    exit 1
  fi
  awk '/^event=/ {
         sub(/^event=/, "fresh-process-event=event=");
         print;
       }' "$FRESH_LOG" >> "$REPORT_TMP"
  FRESH_IDENTITY_COUNT=$(awk '/^event=snapshot-identity / { count += 1 } END { print count + 0 }' "$FRESH_LOG")
  FRESH_IDENTITY=$(sed -n 's/^event=snapshot-identity //p' "$FRESH_LOG")
  FRESH_WRONG_ORACLE_STATUS=$(sed -nE \
    's/^event=b-wrong-oracle-rejected status=([1-9][0-9]*)$/\1/p' \
    "$FRESH_LOG")
  FRESH_CHECKPOINT_BYTES=$(sed -nE \
    's/^event=checkpoint-close bytes=([0-9]+) sha256=[0-9a-f]{64}$/\1/p' \
    "$FRESH_LOG")
  FRESH_CHECKPOINT_HASH=$(sed -nE \
    's/^event=checkpoint-close bytes=[0-9]+ sha256=([0-9a-f]{64})$/\1/p' \
    "$FRESH_LOG")
  FRESH_REOPEN_BYTES=$(sed -nE \
    's/^event=checkpoint-reopened bytes=([0-9]+) sha256=[0-9a-f]{64}$/\1/p' \
    "$FRESH_LOG")
  FRESH_REOPEN_HASH=$(sed -nE \
    's/^event=checkpoint-reopened bytes=[0-9]+ sha256=([0-9a-f]{64})$/\1/p' \
    "$FRESH_LOG")
  if [ "$FRESH_IDENTITY_COUNT" -ne 1 ] ||
     ! printf '%s\n' "$FRESH_IDENTITY" | grep -Eq \
       '^envelope-version=2 header-bytes=388 total-bytes=[0-9]+ native-bytes=[0-9]+ state-format=3 core-abi=1 behavior-revision=9 core-build=nesturbator-2338608ab184f040620a30d17756f5e06a42d4e3 libfuturo-build=sha256:[0-9a-f]{64} profile=nesturbator-ntsc-v1 configuration=nesturbator-default options=nesturbator-options-none-v1 content-bytes=24592 content-sha256=[0-9a-f]{64}$' ||
     [ -z "$FRESH_WRONG_ORACLE_STATUS" ] ||
     [ "$FRESH_CHECKPOINT_BYTES" != "$FRESH_REOPEN_BYTES" ] ||
     [ "$FRESH_CHECKPOINT_HASH" != "$FRESH_REOPEN_HASH" ]; then
    echo 'relocation consumer: fresh-process runtime identity or checkpoint binding is incomplete' >&2
    cat "$FRESH_LOG" >&2
    exit 1
  fi
  FRESH_EVENT_COUNT=$(awk '/^event=/ { count += 1 } END { print count + 0 }' "$FRESH_LOG")
  FRESH_LIBFUTURO_HASH=$(/usr/bin/shasum -a 256 \
    "$MOVED_PREFIX/lib/liblibfuturo.a" | awk '{print $1}')
  FRESH_CORE_HASH=$(/usr/bin/shasum -a 256 \
    "$MOVED_PREFIX/lib/libnesturbator.a" | awk '{print $1}')
  FRESH_CONSUMER_HASH=$(/usr/bin/shasum -a 256 "$FRESH_CONSUMER" | awk '{print $1}')
  FRESH_SUPERVISOR_HASH=$(/usr/bin/shasum -a 256 "$FRESH_SUPERVISOR" | awk '{print $1}')
  FRESH_HELPER_HASH=$(/usr/bin/shasum -a 256 "$FRESH_PROCESS_TREE_HELPER" | awk '{print $1}')
  FRESH_PACKAGE_LIBFUTURO_CONFIG_HASH=$(/usr/bin/shasum -a 256 \
    "$MOVED_PREFIX/lib/cmake/libfuturo/libfuturoTargets.cmake" | awk '{print $1}')
  FRESH_PACKAGE_CORE_CONFIG_HASH=$(/usr/bin/shasum -a 256 \
    "$MOVED_PREFIX/lib/cmake/nesturbator/nesturbatorTargets.cmake" | awk '{print $1}')
  printf 'fresh-process-source-commit=%s\n' "$SOURCE_COMMIT" >> "$REPORT_TMP"
  printf 'fresh-process-source-worktree=%s\n' "$SOURCE_WORKTREE" >> "$REPORT_TMP"
  printf 'fresh-process-source-worktree-fingerprint=sha256:%s\n' \
    "$SOURCE_WORKTREE_FINGERPRINT" >> "$REPORT_TMP"
  printf 'fresh-process-core-release=v0.1.12\n' >> "$REPORT_TMP"
  printf 'fresh-process-core-source-revision=2338608ab184f040620a30d17756f5e06a42d4e3\n' \
    >> "$REPORT_TMP"
  printf 'fresh-process-libfuturo-build-id=%s\n' \
    "$(printf '%s\n' "$FRESH_IDENTITY" | sed -nE 's/.*libfuturo-build=([^ ]+).*/\1/p')" \
    >> "$REPORT_TMP"
  printf 'fresh-process-profile=nesturbator-ntsc-v1\n' >> "$REPORT_TMP"
  printf 'fresh-process-effective-configuration=nesturbator-default\n' \
    >> "$REPORT_TMP"
  printf 'fresh-process-fixture=generated-battery-free-nrom-v1 bytes=%s\n' \
    "$((16 + 16 * 1024 + 8 * 1024))" >> "$REPORT_TMP"
  printf 'fresh-process-target=Darwin/arm64\n' >> "$REPORT_TMP"
  printf 'fresh-process-route=Darwin/arm64 relocated-package-and-consumer\n' \
    >> "$REPORT_TMP"
  printf 'fresh-process-status=%s\n' "$FRESH_PROCESS_STATUS" >> "$REPORT_TMP"
  printf 'fresh-process-a-exit=0\n' >> "$REPORT_TMP"
  printf 'fresh-process-b-exit=0\n' >> "$REPORT_TMP"
  printf 'fresh-process-wrong-oracle=rejected\n' >> "$REPORT_TMP"
  printf 'fresh-process-wrong-oracle-status=%s\n' \
    "$FRESH_WRONG_ORACLE_STATUS" >> "$REPORT_TMP"
  printf 'fresh-process-checkpoint-bytes=%s\n' \
    "$FRESH_CHECKPOINT_BYTES" >> "$REPORT_TMP"
  printf 'fresh-process-checkpoint-sha256=sha256:%s\n' \
    "$FRESH_CHECKPOINT_HASH" >> "$REPORT_TMP"
  printf 'fresh-process-runtime-identity=%s\n' "$FRESH_IDENTITY" >> "$REPORT_TMP"
  printf 'fresh-process-event-count=%s\n' "$FRESH_EVENT_COUNT" >> "$REPORT_TMP"
  printf 'fresh-process-content-sha256=%s\n' \
    "$(printf '%s\n' "$FRESH_IDENTITY" | sed -nE 's/.*content-sha256=([0-9a-f]{64})$/sha256:\1/p')" \
    >> "$REPORT_TMP"
  printf 'fresh-process-a-close=%s\n' "$FRESH_CLOSE_EVENT" >> "$REPORT_TMP"
  printf 'fresh-process-b-reopen=%s\n' "$FRESH_REOPEN_EVENT" >> "$REPORT_TMP"
  printf 'fresh-process-relocated-libfuturo-archive-sha256=sha256:%s\n' \
    "$FRESH_LIBFUTURO_HASH" >> "$REPORT_TMP"
  printf 'fresh-process-relocated-core-archive-sha256=sha256:%s\n' \
    "$FRESH_CORE_HASH" >> "$REPORT_TMP"
  printf 'fresh-process-consumer-executable-sha256=sha256:%s\n' \
    "$FRESH_CONSUMER_HASH" >> "$REPORT_TMP"
  printf 'fresh-process-supervisor-sha256=sha256:%s\n' \
    "$FRESH_SUPERVISOR_HASH" >> "$REPORT_TMP"
  printf 'fresh-process-helper-sha256=sha256:%s\n' \
    "$FRESH_HELPER_HASH" >> "$REPORT_TMP"
  printf 'fresh-process-libfuturo-artifact-sha256=sha256:%s\n' \
    "$FRESH_LIBFUTURO_HASH" >> "$REPORT_TMP"
  printf 'fresh-process-core-artifact-sha256=sha256:%s\n' \
    "$FRESH_CORE_HASH" >> "$REPORT_TMP"
  printf 'fresh-process-consumer-artifact-sha256=sha256:%s\n' \
    "$FRESH_CONSUMER_HASH" >> "$REPORT_TMP"
  printf 'fresh-process-supervisor-artifact-sha256=sha256:%s\n' \
    "$FRESH_SUPERVISOR_HASH" >> "$REPORT_TMP"
  printf 'fresh-process-helper-artifact-sha256=sha256:%s\n' \
    "$FRESH_HELPER_HASH" >> "$REPORT_TMP"
  printf 'fresh-process-package-libfuturo-config-sha256=sha256:%s\n' \
    "$FRESH_PACKAGE_LIBFUTURO_CONFIG_HASH" >> "$REPORT_TMP"
  printf 'fresh-process-package-core-config-sha256=sha256:%s\n' \
    "$FRESH_PACKAGE_CORE_CONFIG_HASH" >> "$REPORT_TMP"
  printf 'fresh-process-result=separate-A-and-B,close-exit-before-restore,literal-continuation result=pass\n' \
    >> "$REPORT_TMP"
fi

CONSUMER_EXECUTABLE="$CONSUMER_BUILD/nesturbator_installed_consumer"
if [ ! -x "$CONSUMER_EXECUTABLE" ]; then
  echo 'relocation consumer: downstream executable is missing after the run' >&2
  exit 1
fi
CONSUMER_HASH=$(/usr/bin/shasum -a 256 "$CONSUMER_EXECUTABLE" | awk '{print $1}')
printf 'target_profile=Darwin/arm64\n' >> "$REPORT_TMP"
printf 'os_version=macOS-%s\n' "$MACOS_VERSION" >> "$REPORT_TMP"
printf 'compiler=%s\n' "$CLANG_VERSION" >> "$REPORT_TMP"
printf 'cmake=%s\n' "$CMAKE_VERSION" >> "$REPORT_TMP"
printf 'ctest=%s\n' "$CTEST_VERSION" >> "$REPORT_TMP"
printf 'sdk=macOS-%s\n' "$SDK_VERSION" >> "$REPORT_TMP"
printf 'build_type=Debug\n' >> "$REPORT_TMP"
printf 'consumer_sanitizers=address,undefined\n' >> "$REPORT_TMP"
printf 'identity_digest_claim=exact-byte-identifiers-only; authenticity=no; reproducibility=no\n' \
  >> "$REPORT_TMP"
printf 'consumer_executable_sha256=sha256:%s\n' "$CONSUMER_HASH" >> "$REPORT_TMP"

INSTALLED_FILES="$SCRATCH/installed-files.txt"
find "$MOVED_PREFIX" -type f -print | LC_ALL=C sort > "$INSTALLED_FILES"
INSTALLED_FILE_COUNT=0
while IFS= read -r installed_file; do
  [ -n "$installed_file" ] || continue
  installed_relative=${installed_file#"$MOVED_PREFIX"/}
  installed_hash=$(/usr/bin/shasum -a 256 "$installed_file" | awk '{print $1}')
  printf 'installed_file_sha256=%s sha256:%s\n' \
    "$installed_relative" "$installed_hash" >> "$REPORT_TMP"
  INSTALLED_FILE_COUNT=$((INSTALLED_FILE_COUNT + 1))
done < "$INSTALLED_FILES"
if [ "$INSTALLED_FILE_COUNT" -eq 0 ]; then
  echo 'relocation consumer: no installed public files were available to identify' >&2
  exit 1
fi
printf 'installed_file_count=%s\n' "$INSTALLED_FILE_COUNT" >> "$REPORT_TMP"
if [ "$MODE" = "--macos-host" ]; then
  cmake \
    -DMACOS_HOST_EVIDENCE_MODE=actual \
    "-DMACOS_HOST_REPORT=$REPORT_TMP" \
    "-DMACOS_HOST_ARTIFACT_ROOT=$BUILD_DIR" \
    -P "$ROOT_DIR/cmake/CheckMacOSHostEvidence.cmake"
fi
/bin/mkdir -p "$REPORT_ROOT"
/bin/cp "$REPORT_TMP" "$REPORT_PATH"
if [ "$MODE" = "--macos-host" ]; then
  HOST_REPORT_PUBLISHED=1
fi
REPORT_REL=$(printf '%s' "$REPORT_PATH" | sed "s|^$ROOT_DIR/||")
if [ "$MODE" = "--save-restart" ]; then
  if [ "$BATTERY_SNAPSHOT_RESULT" = passed ]; then
    printf 'relocation consumer: save/restart passed; evidence=%s\n' "$REPORT_REL"
  else
    printf 'relocation consumer: save/restart failed; evidence=%s\n' "$REPORT_REL"
    exit 1
  fi
elif [ "$MODE" = "--fresh-process-snapshot" ]; then
  printf 'relocation consumer: fresh-process snapshot passed; evidence=%s\n' "$REPORT_REL"
elif [ "$MODE" = "--battery-fresh-process-snapshot" ]; then
  printf 'relocation consumer: battery fresh-process snapshot passed; evidence=%s\n' "$REPORT_REL"
elif [ "$MODE" = "--muhtari-session" ]; then
  printf 'relocation consumer: Muhtari session passed; evidence=%s\n' "$REPORT_REL"
elif [ "$MODE" = "--muhtari-save-restart" ]; then
  printf 'relocation consumer: Muhtari save/restart passed; evidence=%s\n' "$REPORT_REL"
elif [ "$MODE" = "--macos-host" ]; then
  printf '%s\n' 'installed_macos_host: profile=muhtari-ntsc-v1 native-window=pass presentation=pass close=pass result=pass'
  printf 'relocation consumer: macOS host passed; evidence=%s\n' "$REPORT_REL"
else
  printf 'relocation consumer: smoke passed; evidence=%s\n' "$REPORT_REL"
fi
