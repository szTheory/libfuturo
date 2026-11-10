#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  printf '%s\n' \
    "Usage: $0 [--focus profile|fixture|snapshot|fresh-process|installed|evidence|contract]" \
    "Focused runs sample one CTest group. No argument requires the complete API 8 manifest."
}

FOCUS=
if (( $# == 0 )); then
  :
elif (( $# == 2 )) && [[ "$1" == "--focus" ]]; then
  FOCUS="$2"
  case "$FOCUS" in
    profile|fixture|snapshot|fresh-process|installed|evidence|contract) ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
else
  usage >&2
  exit 2
fi

OS_NAME="$(uname -s)"
ARCH_NAME="$(uname -m)"
if [[ "$OS_NAME" != "Darwin" || "$ARCH_NAME" != "arm64" ]]; then
  printf 'error: API 8 profile requires Darwin/arm64; found %s/%s\n' \
    "$OS_NAME" "$ARCH_NAME" >&2
  exit 2
fi
if ! command -v xcrun >/dev/null 2>&1; then
  printf '%s\n' 'error: xcrun is required to select the macOS Clang and SDK' >&2
  exit 2
fi

CMAKE_BIN="$(command -v cmake)"
CTEST_BIN="$(command -v ctest)"
CLANG_PATH="$(xcrun --find clang)"
SDK_PATH="$(xcrun --show-sdk-path)"
BUILD_DIR="$ROOT_DIR/build/muhtari-api8"
INSTALL_PREFIX="$ROOT_DIR/build/muhtari-api8-prefix"
CONFIGURE_SECONDS=
BUILD_SECONDS=
INSTALL_SECONDS=
CTEST_SECONDS=
RUN_ID="api8-$(date -u '+%Y%m%dT%H%M%SZ')-$$"

run_timed() {
  local phase="$1"
  shift
  local started_at=$SECONDS
  "$@"
  local elapsed=$((SECONDS - started_at))
  case "$phase" in
    configure) CONFIGURE_SECONDS="$elapsed" ;;
    build) BUILD_SECONDS="$elapsed" ;;
    install) INSTALL_SECONDS="$elapsed" ;;
    ctest) CTEST_SECONDS="$elapsed" ;;
  esac
}

run_timed configure "$CMAKE_BIN" -S "$ROOT_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Debug \
  "-DCMAKE_C_COMPILER=$CLANG_PATH" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  "-DCMAKE_OSX_SYSROOT=$SDK_PATH" \
  "-DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX" \
  -DFETCHCONTENT_QUIET=OFF \
  -DLIBFUTURO_ENABLE_MUHTARI=ON \
  -DLIBFUTURO_MUHTARI_API_REVISION=8

if ! grep -Fqx \
    'LIBFUTURO_ENABLE_MUHTARI:BOOL=ON' "$BUILD_DIR/CMakeCache.txt" ||
   ! grep -Fqx \
    'LIBFUTURO_MUHTARI_API_REVISION:STRING=8' "$BUILD_DIR/CMakeCache.txt" ||
   ! grep -Fqx \
    'LIBFUTURO_MUHTARI_CONFIGURED_API_REVISION:INTERNAL=8' \
    "$BUILD_DIR/CMakeCache.txt" ||
   ! grep -Fqx \
    'LIBFUTURO_MUHTARI_CONFIGURED_VERSION:INTERNAL=0.11.1' \
    "$BUILD_DIR/CMakeCache.txt" ||
   ! grep -Fqx \
    'LIBFUTURO_MUHTARI_CONFIGURED_SOURCE_REVISION:INTERNAL=d58f125297c4d63a7a8108112a5eafff6f53a76a' \
    "$BUILD_DIR/CMakeCache.txt"; then
  printf '%s\n' 'error: API 8 build cache does not hold the selected profile identity' >&2
  exit 3
fi

if [[ -z "$FOCUS" ]]; then
  API8_TEST_MANIFEST="$BUILD_DIR/muhtari-api8-required-tests.txt"
  REQUIRED_API8_TESTS=(
    muhtari_api8_profile
    muhtari_api8_package_modes
    muhtari_api8_contract
    muhtari_api8_fixture_boundary
    muhtari_api8_fixture_oracle_controls
    muhtari_api8_snapshot_contract
    muhtari_api8_source_fresh_process
    muhtari_api8_source_oracle_controls
    muhtari_api8_supervisor_controls
    muhtari_api8_validator_smoke
    muhtari_api8_relocated_consumer
    muhtari_api8_result_controls
  )
  MISSING_API8_TESTS=()
  for test_name in "${REQUIRED_API8_TESTS[@]}"; do
    if [[ ! -f "$API8_TEST_MANIFEST" ]] ||
       ! grep -Fqx "$test_name" "$API8_TEST_MANIFEST"; then
      MISSING_API8_TESTS+=("$test_name")
    fi
  done
  if (( ${#MISSING_API8_TESTS[@]} > 0 )); then
    printf 'error: complete API 8 acceptance is unavailable; missing required registrations: %s\n' \
      "${MISSING_API8_TESTS[*]}" >&2
    printf '%s\n' 'Use --focus to run an explicitly sampled group; sampling does not qualify API 8.' >&2
    exit 3
  fi
fi

BUILD_TARGETS=(libfuturo)
API8_TARGET_MANIFEST="$BUILD_DIR/muhtari-api8-required-targets.txt"
if [[ -s "$API8_TARGET_MANIFEST" ]]; then
  while IFS= read -r target_name; do
    [[ -z "$target_name" ]] || BUILD_TARGETS+=("$target_name")
  done < "$API8_TARGET_MANIFEST"
fi
run_timed build "$CMAKE_BIN" --build "$BUILD_DIR" \
  --target "${BUILD_TARGETS[@]}"
run_timed install "$CMAKE_BIN" --install "$BUILD_DIR" --prefix "$INSTALL_PREFIX"

if [[ -n "$FOCUS" ]]; then
  TEST_SELECTION=(-L "^muhtari-api8-$FOCUS$")
  MODE=sampling
else
  TEST_SELECTION=(-L '^muhtari-api8-')
  MODE=qualification
fi

if [[ -z "$FOCUS" ]]; then
  EVIDENCE_ROOT="$BUILD_DIR/evidence/$RUN_ID"
  SOURCE_CONSOLE="$BUILD_DIR/api8-ctest-console.log"
  SOURCE_JUNIT="$BUILD_DIR/api8-ctest-results.junit.xml"
  SOURCE_INVENTORY="$BUILD_DIR/api8-ctest-inventory.json"
  SOURCE_PROCESS_FACTS="$BUILD_DIR/api8-ctest-process-facts.txt"
  if ! "$CTEST_BIN" --test-dir "$BUILD_DIR" -L '^muhtari-api8-' \
      --show-only=json-v1 > "$SOURCE_INVENTORY"; then
    printf '%s\n' 'error: API 8 CTest inventory could not be collected' >&2
    exit 4
  fi
  LF_MUHTARI_API8_RUN_ID="$RUN_ID"
  export LF_MUHTARI_API8_RUN_ID
  CTEST_STARTED_AT=$SECONDS
  if "$CTEST_BIN" --test-dir "$BUILD_DIR" "${TEST_SELECTION[@]}" \
      --output-on-failure --no-tests=error --output-junit "$SOURCE_JUNIT" \
      > "$SOURCE_CONSOLE" 2>&1; then
    CTEST_STATUS=0
  else
    CTEST_STATUS=$?
  fi
  CTEST_SECONDS=$((SECONDS - CTEST_STARTED_AT))
  cat "$SOURCE_CONSOLE"
  printf 'run_id=%s\nexit_status=%s\nsignal=none\ntimed_out=no\n' \
    "$RUN_ID" "$CTEST_STATUS" > "$SOURCE_PROCESS_FACTS"
  if [[ "$CTEST_STATUS" -ne 0 ]]; then
    exit "$CTEST_STATUS"
  fi
  write_source_route_evidence() {
    local evidence_root="$1"
    local artifact_root="$evidence_root/artifacts/source-build"
    local source_line fixture_bytes fixture_digest checkpoint_line checkpoint_bytes checkpoint_digest
    local commit fingerprint build_fingerprint source_hash nesturbator_hash muhtari_hash consumer_hash
    local fixture_generator_hash fixture_base_hash consumer_source_hash snapshot_oracle_hash supervisor_hash helper_hash oracle_hash inventory_hash junit_hash log_hash facts_hash resolution_hash audit_hash
    mkdir -p "$artifact_root" "$evidence_root/artifacts/source-test-sources"
    cp "$BUILD_DIR/liblibfuturo.a" "$artifact_root/liblibfuturo.a"
    cp "$BUILD_DIR/_deps/nesturbator-build/libnesturbator.a" "$artifact_root/libnesturbator.a"
    cp "$BUILD_DIR/_deps/muhtari-build/libmuhtari.a" "$artifact_root/libmuhtari.a"
    cp "$BUILD_DIR/muhtari_api8_consumer" "$artifact_root/muhtari_api8_consumer"
    for source_file in muhtari_fixture.h muhtari_snapshot_fixture.h \
        muhtari_snapshot.c muhtari_snapshot_oracle.h muhtari_snapshot_host.h \
        muhtari_snapshot_faults.h; do
      cp "$ROOT_DIR/tests/installed-consumer/$source_file" \
        "$evidence_root/artifacts/source-test-sources/$source_file"
    done
    for source_file in muhtari_fresh_process_supervisor.sh \
        muhtari_fresh_process_oracle_controls.sh; do
      cp "$ROOT_DIR/tests/$source_file" \
        "$evidence_root/artifacts/source-test-sources/$source_file"
    done
    cp "$ROOT_DIR/scripts/process-tree-cleanup.sh" \
      "$evidence_root/artifacts/source-test-sources/process-tree-cleanup.sh"
    sed "s#$ROOT_DIR#<checkout>#g; s#$BUILD_DIR#<api8-build>#g" \
      "$SOURCE_INVENTORY" > "$evidence_root/source-ctest-inventory.json"
    sed "s#$ROOT_DIR#<checkout>#g; s#$BUILD_DIR#<api8-build>#g" \
      "$SOURCE_JUNIT" > "$evidence_root/source-ctest-results.junit.xml"
    {
      cat "$SOURCE_CONSOLE"
      cat "$BUILD_DIR/Testing/Temporary/LastTest.log"
    } > "$evidence_root/source-ctest-output.log"
    sed "s#$ROOT_DIR#<checkout>#g; s#$BUILD_DIR#<api8-build>#g; s#/private/tmp#<scratch>#g" \
      "$evidence_root/source-ctest-output.log" \
      > "$evidence_root/source-ctest-output.sanitized.log"
    mv "$evidence_root/source-ctest-output.sanitized.log" \
      "$evidence_root/source-ctest-output.log"
    cp "$SOURCE_PROCESS_FACTS" "$evidence_root/source-ctest-process-facts.txt"
    sed "s#$ROOT_DIR#<checkout>#g; s#$BUILD_DIR#<api8-build>#g" \
      "$BUILD_DIR/CMakeFiles/muhtari_api8_consumer.dir/link.txt" \
      > "$evidence_root/source-link-audit.txt"
    printf '%s\n' \
      'route=source-build' \
      'libfuturo=artifacts/source-build/liblibfuturo.a' \
      'nesturbator=artifacts/source-build/libnesturbator.a' \
      'muhtari=artifacts/source-build/libmuhtari.a' \
      'consumer=artifacts/source-build/muhtari_api8_consumer' \
      'resolution=source-build-targets-only' \
      > "$evidence_root/source-package-resolution.txt"
    source_line=$(sed -E 's/^[[:space:]]*[0-9]+: //' "$BUILD_DIR/Testing/Temporary/LastTest.log" | \
      awk '/^muhtari_api8_fixture_identity: bytes=/ && !found { print; found = 1 } END { if (!found) exit 1 }')
    checkpoint_line=$(sed -E 's/^[[:space:]]*[0-9]+: //' "$BUILD_DIR/Testing/Temporary/LastTest.log" | \
      awk '/^event=checkpoint-close bytes=/ && !found { print; found = 1 } END { if (!found) exit 1 }')
    fixture_bytes=$(printf '%s\n' "$source_line" | sed -E 's/.* bytes=([0-9]+) sha256=.*/\1/')
    fixture_digest=$(printf '%s\n' "$source_line" | sed -E 's/.* sha256=([0-9a-f]{64}) .*/\1/')
    checkpoint_bytes=$(printf '%s\n' "$checkpoint_line" | sed -E 's/^event=checkpoint-close bytes=([0-9]+) sha256=.*/\1/')
    checkpoint_digest=$(printf '%s\n' "$checkpoint_line" | sed -E 's/.* sha256=([0-9a-f]{64})$/\1/')
    if ! printf '%s\n' "$fixture_bytes:$fixture_digest:$checkpoint_bytes:$checkpoint_digest" | \
        grep -Eq '^[0-9]+:[0-9a-f]{64}:[0-9]+:[0-9a-f]{64}$'; then
      printf '%s\n' 'error: API 8 source route fixture/checkpoint identities are incomplete' >&2
      return 1
    fi
    sha256_file() { /usr/bin/shasum -a 256 "$1" | awk '{print $1}'; }
    commit=$(git -C "$ROOT_DIR" rev-parse HEAD)
    fingerprint=$(
      {
        git -C "$ROOT_DIR" diff --binary HEAD -- CMakeLists.txt \
          cmake/ValidateRequiredResults.cmake cmake/ValidateMuhtariApi8Results.cmake \
          scripts/check-muhtari-api8.sh tests/installed-consumer \
          tests/muhtari_fresh_process_supervisor.sh \
          tests/muhtari_fresh_process_oracle_controls.sh \
          tests/muhtari_api8_result_controls.cmake
        for changed_file in tests/installed-consumer/relocate-muhtari-api8.sh \
            tests/installed-consumer/relocate-muhtari-api8-consumer-stage.sh \
            cmake/ValidateMuhtariApi8Results.cmake tests/muhtari_api8_result_controls.cmake; do
          if [ -f "$ROOT_DIR/$changed_file" ] &&
             ! git -C "$ROOT_DIR" ls-files --error-unmatch "$changed_file" >/dev/null 2>&1; then
            printf '%s\n' "$changed_file"
            cat "$ROOT_DIR/$changed_file"
          fi
        done
      } | /usr/bin/shasum -a 256 | awk '{print $1}'
    )
    build_fingerprint=$(cat "$BUILD_DIR/CMakeCache.txt" "$BUILD_DIR/compile_commands.json" | /usr/bin/shasum -a 256 | awk '{print $1}')
    source_hash=$(sha256_file "$artifact_root/liblibfuturo.a")
    nesturbator_hash=$(sha256_file "$artifact_root/libnesturbator.a")
    muhtari_hash=$(sha256_file "$artifact_root/libmuhtari.a")
    consumer_hash=$(sha256_file "$artifact_root/muhtari_api8_consumer")
    fixture_generator_hash=$(sha256_file "$evidence_root/artifacts/source-test-sources/muhtari_snapshot_fixture.h")
    fixture_base_hash=$(sha256_file "$evidence_root/artifacts/source-test-sources/muhtari_fixture.h")
    consumer_source_hash=$(sha256_file "$evidence_root/artifacts/source-test-sources/muhtari_snapshot.c")
    snapshot_oracle_hash=$(sha256_file "$evidence_root/artifacts/source-test-sources/muhtari_snapshot_oracle.h")
    supervisor_hash=$(sha256_file "$evidence_root/artifacts/source-test-sources/muhtari_fresh_process_supervisor.sh")
    helper_hash=$(sha256_file "$evidence_root/artifacts/source-test-sources/process-tree-cleanup.sh")
    oracle_hash=$(sha256_file "$evidence_root/artifacts/source-test-sources/muhtari_fresh_process_oracle_controls.sh")
    inventory_hash=$(sha256_file "$evidence_root/source-ctest-inventory.json")
    junit_hash=$(sha256_file "$evidence_root/source-ctest-results.junit.xml")
    log_hash=$(sha256_file "$evidence_root/source-ctest-output.log")
    facts_hash=$(sha256_file "$evidence_root/source-ctest-process-facts.txt")
    resolution_hash=$(sha256_file "$evidence_root/source-package-resolution.txt")
    audit_hash=$(sha256_file "$evidence_root/source-link-audit.txt")
    {
      printf 'format=libfuturo-muhtari-api8-route-v1\nroute=source\nrun_id=%s\nresult=pass\n' "$RUN_ID"
      printf 'source_commit=%s\nsource_worktree_fingerprint=sha256:%s\nbuild_fingerprint=sha256:%s\n' "$commit" "$fingerprint" "$build_fingerprint"
      printf 'platform=%s\narchitecture=%s\napi_revision=8\napi_abi=1\nbehavior_revision=6\nstate_format=1\n' "$OS_NAME" "$ARCH_NAME"
      printf 'muhtari_version=0.11.1\nmuhtari_source_revision=d58f125297c4d63a7a8108112a5eafff6f53a76a\nprofile=muhtari-ntsc-v2\nconfiguration=muhtari-ntsc-battery-diagnostic\n'
      printf 'effective_options=none\nsnapshot_boundary=R2-frame2-pending-savekey-write\nreplay_boundary=R3-frame3-savekey-published\nreplay_savekey_offset=2051\nreplay_frame=3\nreplay_video_sha256=59b78332303fa3c631ae7cd522ad45627f739b49a48e8c0b0c07f45ea79bd225\nreplay_pcm_sha256=09474df08fabeb22495ea69a6becd73374879d6840862382d0691c6e7a13a13f\nreplay_battery=full-span-r3\nreplay_battery_sha256=495ead1f5e803049666b25490aa47495e529eda7c8516eb3513947b403b4a583\nsnapshot_r2_battery_sha256=036d171c7642abeb0acc3670afc5a67422bf028b0086d0d8720a95985fdfdb64\n'
      printf 'fixture_bytes=%s\nfixture_sha256=sha256:%s\nfixture_generator_ref=artifacts/source-test-sources/muhtari_snapshot_fixture.h\nfixture_generator_sha256=sha256:%s\nfixture_base_ref=artifacts/source-test-sources/muhtari_fixture.h\nfixture_base_sha256=sha256:%s\n' "$fixture_bytes" "$fixture_digest" "$fixture_generator_hash" "$fixture_base_hash"
      printf 'consumer_source_ref=artifacts/source-test-sources/muhtari_snapshot.c\nconsumer_source_sha256=sha256:%s\nsnapshot_oracle_ref=artifacts/source-test-sources/muhtari_snapshot_oracle.h\nsnapshot_oracle_sha256=sha256:%s\n' "$consumer_source_hash" "$snapshot_oracle_hash"
      printf 'checkpoint_bytes=%s\ncheckpoint_sha256=sha256:%s\n' "$checkpoint_bytes" "$checkpoint_digest"
      printf 'libfuturo_ref=artifacts/source-build/liblibfuturo.a\nlibfuturo_sha256=sha256:%s\n' "$source_hash"
      printf 'nesturbator_ref=artifacts/source-build/libnesturbator.a\nnesturbator_sha256=sha256:%s\n' "$nesturbator_hash"
      printf 'muhtari_ref=artifacts/source-build/libmuhtari.a\nmuhtari_sha256=sha256:%s\n' "$muhtari_hash"
      printf 'consumer_ref=artifacts/source-build/muhtari_api8_consumer\nconsumer_sha256=sha256:%s\n' "$consumer_hash"
      printf 'supervisor_ref=artifacts/source-test-sources/muhtari_fresh_process_supervisor.sh\nsupervisor_sha256=sha256:%s\n' "$supervisor_hash"
      printf 'process_tree_helper_ref=artifacts/source-test-sources/process-tree-cleanup.sh\nprocess_tree_helper_sha256=sha256:%s\n' "$helper_hash"
      printf 'oracle_controls_ref=artifacts/source-test-sources/muhtari_fresh_process_oracle_controls.sh\noracle_controls_sha256=sha256:%s\n' "$oracle_hash"
      printf 'ctest_inventory_ref=source-ctest-inventory.json\nctest_inventory_sha256=sha256:%s\n' "$inventory_hash"
      printf 'ctest_junit_ref=source-ctest-results.junit.xml\nctest_junit_sha256=sha256:%s\n' "$junit_hash"
      printf 'ctest_log_ref=source-ctest-output.log\nctest_log_sha256=sha256:%s\n' "$log_hash"
      printf 'ctest_process_facts_ref=source-ctest-process-facts.txt\nctest_process_facts_sha256=sha256:%s\n' "$facts_hash"
      printf 'package_resolution_ref=source-package-resolution.txt\npackage_resolution_sha256=sha256:%s\n' "$resolution_hash"
      printf 'link_audit_ref=source-link-audit.txt\nlink_audit_sha256=sha256:%s\n' "$audit_hash"
      printf 'ctest_exit_status=0\nctest_signal=none\nctest_timed_out=no\nsource_build=libfuturo-source-tree\n'
      for test_name in muhtari_api8_profile muhtari_api8_fixture_boundary \
          muhtari_api8_fixture_oracle_controls muhtari_api8_snapshot_contract \
          muhtari_api8_source_fresh_process muhtari_api8_source_oracle_controls \
          muhtari_api8_supervisor_controls; do
        printf 'test_result=%s|passed\n' "$test_name"
      done
    } > "$evidence_root/source-route.report"
    sed -E 's/^[[:space:]]*[0-9]+: //' "$BUILD_DIR/Testing/Temporary/LastTest.log" | \
      awk -v start='event=supervisor-start route=source' \
          -v finish='event=supervisor-success route=source result=pass' \
          '!found && $0 == start { recording = 1 } recording && /^verified_lifecycle=/ { print "lifecycle_event=" $0 } recording && /^event=/ { print "behavior_event=" $0; if ($0 == finish) { found = 1; recording = 0 } }' \
      >> "$evidence_root/source-route.report" || {
        printf '%s\n' 'error: ordered API 8 source supervisor events are missing' >&2
        return 1
      }
    sha256_file "$evidence_root/source-route.report" | \
      awk '{print "report_sha256=sha256:" $1}' \
      > "$evidence_root/source-route-report-identity.txt"
  }
  write_source_route_evidence "$EVIDENCE_ROOT"
  cmake_args=(
    -DRESULT_CASES=muhtari-api8-actual
    "-DAPI8_EVIDENCE_ROOT=$EVIDENCE_ROOT"
    "-DAPI8_RUN_ID=$RUN_ID"
    "-DAPI8_SOURCE_REPORT=$EVIDENCE_ROOT/source-route.report"
    "-DAPI8_INSTALLED_REPORT=$EVIDENCE_ROOT/installed-route.report"
    "-DAPI8_RESULT_OUTPUT=$EVIDENCE_ROOT/required-results.tsv"
    -P "$ROOT_DIR/cmake/ValidateRequiredResults.cmake"
  )
  if ! "$CMAKE_BIN" "${cmake_args[@]}"; then
    exit 4
  fi
  cp "$EVIDENCE_ROOT/required-results.tsv" "$BUILD_DIR/required-results.tsv"
else
  run_timed ctest "$CTEST_BIN" --test-dir "$BUILD_DIR" \
    "${TEST_SELECTION[@]}" --output-on-failure --no-tests=error
fi

if [[ -z "$FOCUS" ]]; then
  REQUIRED_RESULTS="$BUILD_DIR/required-results.tsv"
  if [[ ! -s "$REQUIRED_RESULTS" ]]; then
    printf '%s\n' 'error: complete API 8 tests ran without the required-result report manifest' >&2
    exit 4
  fi
fi

printf 'muhtari_api8_check: mode=%s focus=%s result=pass configure_seconds=%s build_seconds=%s install_seconds=%s ctest_seconds=%s\n' \
  "${MODE:-sampling}" "${FOCUS:-all}" "${CONFIGURE_SECONDS}" \
  "${BUILD_SECONDS}" "${INSTALL_SECONDS}" "${CTEST_SECONDS}"
