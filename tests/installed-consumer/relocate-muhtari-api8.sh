#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root_dir=$(CDPATH= cd -- "$script_dir/../.." && pwd)
build_dir=${1:-}
if [ -z "$build_dir" ] || [ ! -f "$build_dir/CMakeCache.txt" ]; then
  echo 'muhtari api8 relocation: configured API 8 build directory is required' >&2
  exit 2
fi
case "$(uname -s)/$(uname -m)" in
  Darwin/arm64) ;;
  *) echo 'muhtari api8 relocation: requires the selected Darwin/arm64 host' >&2; exit 2 ;;
esac
for expected in \
  'LIBFUTURO_ENABLE_MUHTARI:BOOL=ON' \
  'LIBFUTURO_MUHTARI_API_REVISION:STRING=8' \
  'LIBFUTURO_MUHTARI_CONFIGURED_API_REVISION:INTERNAL=8' \
  'LIBFUTURO_MUHTARI_CONFIGURED_VERSION:INTERNAL=0.11.1' \
  'LIBFUTURO_MUHTARI_CONFIGURED_SOURCE_REVISION:INTERNAL=d58f125297c4d63a7a8108112a5eafff6f53a76a'; do
  if ! grep -Fqx "$expected" "$build_dir/CMakeCache.txt"; then
    echo "muhtari api8 relocation: build identity mismatch: $expected" >&2
    exit 3
  fi
done

umask 077
scratch=$(mktemp -d /private/tmp/libfuturo-muhtari-api8-relocate.XXXXXXXX) || exit 1
run_id=${LF_MUHTARI_API8_RUN_ID:-"api8-$(date -u '+%Y%m%dT%H%M%SZ')-$$"}
case "$run_id" in
  ''|*[!A-Za-z0-9._-]*) echo 'muhtari api8 relocation: invalid evidence run id' >&2; exit 2 ;;
esac
original_stage_root="$scratch/original-stage"
original_prefix="$original_stage_root/prefix"
moved_prefix="$scratch/moved-prefix"
consumer_source="$scratch/consumer-source"
consumer_build="$scratch/consumer-build"
conflict_build="$scratch/conflict-build"
ambient_prefix="$scratch/ambient"
evidence_root="$build_dir/evidence/$run_id"
report_tmp="$scratch/installed-route.report"
root_mode=$(stat -f %Lp "$root_dir")
build_mode=$(stat -f %Lp "$build_dir")
ROOT_DIR=$root_dir
BUILD_DIR=$build_dir
ROOT_MODE=$root_mode
BUILD_MODE=$build_mode
SCRATCH=$scratch
STAGE_ROOT="$scratch/absent-isolation-stage"
REPORT_TMP="$scratch/relocation-report.txt"
PATHS_PROTECTED=0

. "$root_dir/scripts/process-tree-cleanup.sh"
. "$script_dir/relocate-bounded-stage.sh"

cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$PATHS_PROTECTED" -eq 1 ]; then
    restore_original_paths || status=1
  fi
  if [ "$status" -ne 0 ]; then
    printf 'muhtari api8 relocation: diagnostic scratch retained at %s\n' "$scratch" >&2
  else
    rm -rf -- "$scratch"
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

cmake_bin=$(command -v cmake)
ctest_bin=$(command -v ctest)
c_compiler=$(sed -n 's/^CMAKE_C_COMPILER:[^=]*=//p' "$build_dir/CMakeCache.txt" | head -n 1)
osx_sysroot=$(sed -n 's/^CMAKE_OSX_SYSROOT:PATH=//p' "$build_dir/CMakeCache.txt" | head -n 1)
if [ -z "$c_compiler" ]; then
  echo 'muhtari api8 relocation: configured C compiler is missing' >&2
  exit 3
fi

mkdir -p "$original_prefix" "$consumer_source" \
  "$ambient_prefix/lib/cmake/libfuturo" \
  "$ambient_prefix/lib/cmake/nesturbator" \
  "$ambient_prefix/lib/cmake/muhtari"
printf '%s\n' 'message(FATAL_ERROR "ambient libfuturo package selected")' \
  > "$ambient_prefix/lib/cmake/libfuturo/libfuturoConfig.cmake"
printf '%s\n' 'message(FATAL_ERROR "ambient Nesturbator package selected")' \
  > "$ambient_prefix/lib/cmake/nesturbator/nesturbatorConfig.cmake"
printf '%s\n' 'message(FATAL_ERROR "ambient Muhtari package selected")' \
  > "$ambient_prefix/lib/cmake/muhtari/muhtariConfig.cmake"

install_started=$(date +%s)
"$cmake_bin" --install "$build_dir" --prefix "$original_prefix"
install_elapsed=$(( $(date +%s) - install_started ))
cp -R "$root_dir/tests/installed-consumer/." "$consumer_source/"
cp "$root_dir/tests/muhtari_fresh_process_supervisor.sh" \
  "$consumer_source/muhtari_fresh_process_supervisor.sh"
cp "$root_dir/tests/muhtari_fresh_process_oracle_controls.sh" \
  "$consumer_source/muhtari_fresh_process_oracle_controls.sh"
cp "$root_dir/scripts/process-tree-cleanup.sh" \
  "$consumer_source/process-tree-cleanup.sh"
cp "$script_dir/relocate-muhtari-api8-consumer-stage.sh" \
  "$scratch/consumer-stage.sh"
chmod +x "$consumer_source/muhtari_fresh_process_supervisor.sh" \
  "$consumer_source/muhtari_fresh_process_oracle_controls.sh" \
  "$consumer_source/process-tree-cleanup.sh" "$scratch/consumer-stage.sh"
mv "$original_prefix" "$moved_prefix"
if [ -e "$original_prefix" ]; then
  echo 'muhtari api8 relocation: original staging prefix remained after move' >&2
  exit 4
fi

cd "$scratch"
stage_started=$(date +%s)
if run_isolated_stage api8-downstream 1200 /bin/sh \
    "$scratch/consumer-stage.sh" "$consumer_source" "$conflict_build" \
    "$consumer_build" "$moved_prefix" "$ambient_prefix" "$cmake_bin" \
    "$c_compiler" "$osx_sysroot" "$ctest_bin" "$root_dir" "$build_dir"; then
  :
else
  stage_status=$?
  exit "$stage_status"
fi
stage_elapsed=$(( $(date +%s) - stage_started ))

if [ -e "$evidence_root" ]; then
  echo "muhtari api8 relocation: evidence run id already exists: $run_id" >&2
  exit 13
fi
mkdir -p "$evidence_root/artifacts/moved-prefix" \
  "$evidence_root/artifacts/installed-consumer" \
  "$evidence_root/artifacts/installed-test-sources"
cp -R "$moved_prefix/." "$evidence_root/artifacts/moved-prefix/"
cp "$consumer_build/muhtari_api8_consumer" \
  "$evidence_root/artifacts/installed-consumer/muhtari_api8_consumer"
for source_file in \
  CMakeLists.txt muhtari_snapshot.c muhtari_fixture.h \
  muhtari_snapshot_fixture.h muhtari_snapshot_oracle.h \
  muhtari_snapshot_host.h muhtari_snapshot_faults.h \
  muhtari_fresh_process_supervisor.sh \
  muhtari_fresh_process_oracle_controls.sh process-tree-cleanup.sh; do
  cp "$consumer_source/$source_file" \
    "$evidence_root/artifacts/installed-test-sources/$source_file"
done

escape_sed_path() {
  printf '%s' "$1" | sed 's/[.\\]/\\&/g'
}
scratch_re=$(escape_sed_path "$scratch")
root_re=$(escape_sed_path "$root_dir")
build_re=$(escape_sed_path "$build_dir")
"$cmake_bin" -E cat "$consumer_build/ctest-inventory.json" | \
  sed -e "s#$scratch_re#<scratch>#g" \
      -e "s#$root_re#<checkout>#g" \
      -e "s#$build_re#<api8-build>#g" \
  > "$evidence_root/installed-ctest-inventory.json"
sed -e "s#$scratch_re#<scratch>#g" \
    -e "s#$root_re#<checkout>#g" \
    -e "s#$build_re#<api8-build>#g" \
  "$consumer_build/ctest-results.junit.xml" \
  > "$evidence_root/installed-ctest-results.junit.xml"
sed -e "s#$scratch_re#<scratch>#g" \
    -e "s#$root_re#<checkout>#g" \
    -e "s#$build_re#<api8-build>#g" \
  "$consumer_build/ctest-output.log" \
  > "$evidence_root/installed-ctest-output.log"
cp "$consumer_build/process-facts.txt" \
  "$evidence_root/installed-ctest-process-facts.txt"
cp "$consumer_build/package-resolution.txt" \
  "$evidence_root/installed-package-resolution.txt"
printf '%s\n' \
  'libfuturo=lib/liblibfuturo.a' \
  'nesturbator=lib/libnesturbator.a' \
  'muhtari=lib/libmuhtari.a' \
  'resolution=only-moved-prefix' \
  'source-and-build-fallback=unavailable-during-configure-build-ctest' \
  > "$evidence_root/installed-link-audit.txt"

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | awk '{print $1}'
}
hash_named_file() {
  source=$1
  destination=$2
  expected_hash=$(sha256_file "$source")
  copied_hash=$(sha256_file "$destination")
  if [ "$expected_hash" != "$copied_hash" ]; then
    echo "muhtari api8 relocation: retained artifact changed: $destination" >&2
    exit 14
  fi
  printf '%s\n' "$copied_hash"
}

fixture_line=$(sed -E 's/^[[:space:]]*[0-9]+: //' \
  "$consumer_build/ctest-output.log" | \
  grep -m 1 '^muhtari_api8_fixture_identity: bytes=')
fixture_bytes=$(printf '%s\n' "$fixture_line" | sed -E 's/.* bytes=([0-9]+) sha256=.*/\1/')
fixture_digest=$(printf '%s\n' "$fixture_line" | sed -E 's/.* sha256=([0-9a-f]{64}) .*/\1/')
checkpoint_line=$(sed -E 's/^[[:space:]]*[0-9]+: //' \
  "$consumer_build/ctest-output.log" | \
  grep -m 1 '^event=checkpoint-close bytes=')
checkpoint_bytes=$(printf '%s\n' "$checkpoint_line" | sed -E 's/^event=checkpoint-close bytes=([0-9]+) sha256=.*/\1/')
checkpoint_digest=$(printf '%s\n' "$checkpoint_line" | sed -E 's/.* sha256=([0-9a-f]{64})$/\1/')
if ! printf '%s\n' "$fixture_bytes:$fixture_digest:$checkpoint_bytes:$checkpoint_digest" | \
    grep -Eq '^[0-9]+:[0-9a-f]{64}:[0-9]+:[0-9a-f]{64}$'; then
  echo 'muhtari api8 relocation: generated fixture/checkpoint identity is incomplete' >&2
  exit 15
fi

source_commit=$(git -C "$root_dir" rev-parse HEAD)
source_worktree_fingerprint=$(
  {
    git -C "$root_dir" diff --binary HEAD -- CMakeLists.txt \
      cmake/ValidateRequiredResults.cmake cmake/ValidateMuhtariApi8Results.cmake \
      scripts/check-muhtari-api8.sh tests/installed-consumer \
      tests/muhtari_fresh_process_supervisor.sh \
      tests/muhtari_fresh_process_oracle_controls.sh \
      tests/muhtari_api8_result_controls.cmake
    for changed_file in \
      tests/installed-consumer/relocate-muhtari-api8.sh \
      tests/installed-consumer/relocate-muhtari-api8-consumer-stage.sh \
      cmake/ValidateMuhtariApi8Results.cmake \
      tests/muhtari_api8_result_controls.cmake; do
      if [ -f "$root_dir/$changed_file" ] &&
         ! git -C "$root_dir" ls-files --error-unmatch "$changed_file" >/dev/null 2>&1; then
        printf '%s\n' "$changed_file"
        cat "$root_dir/$changed_file"
      fi
    done
  } | /usr/bin/shasum -a 256 | awk '{print $1}'
)
build_fingerprint=$(
  cat "$build_dir/CMakeCache.txt" "$build_dir/compile_commands.json" |
    /usr/bin/shasum -a 256 | awk '{print $1}'
)
libfuturo_hash=$(hash_named_file "$moved_prefix/lib/liblibfuturo.a" \
  "$evidence_root/artifacts/moved-prefix/lib/liblibfuturo.a")
nesturbator_hash=$(hash_named_file "$moved_prefix/lib/libnesturbator.a" \
  "$evidence_root/artifacts/moved-prefix/lib/libnesturbator.a")
muhtari_hash=$(hash_named_file "$moved_prefix/lib/libmuhtari.a" \
  "$evidence_root/artifacts/moved-prefix/lib/libmuhtari.a")
consumer_hash=$(hash_named_file "$consumer_build/muhtari_api8_consumer" \
  "$evidence_root/artifacts/installed-consumer/muhtari_api8_consumer")
fixture_generator_hash=$(sha256_file \
  "$evidence_root/artifacts/installed-test-sources/muhtari_snapshot_fixture.h")
fixture_base_hash=$(sha256_file \
  "$evidence_root/artifacts/installed-test-sources/muhtari_fixture.h")
consumer_source_hash=$(sha256_file \
  "$evidence_root/artifacts/installed-test-sources/muhtari_snapshot.c")
snapshot_oracle_hash=$(sha256_file \
  "$evidence_root/artifacts/installed-test-sources/muhtari_snapshot_oracle.h")
supervisor_hash=$(sha256_file \
  "$evidence_root/artifacts/installed-test-sources/muhtari_fresh_process_supervisor.sh")
helper_hash=$(sha256_file \
  "$evidence_root/artifacts/installed-test-sources/process-tree-cleanup.sh")
oracle_hash=$(sha256_file \
  "$evidence_root/artifacts/installed-test-sources/muhtari_fresh_process_oracle_controls.sh")
libfuturo_config_hash=$(sha256_file \
  "$evidence_root/artifacts/moved-prefix/lib/cmake/libfuturo/libfuturoConfig.cmake")
muhtari_config_hash=$(sha256_file \
  "$evidence_root/artifacts/moved-prefix/lib/cmake/muhtari/muhtariConfig.cmake")
nesturbator_config_hash=$(sha256_file \
  "$evidence_root/artifacts/moved-prefix/lib/cmake/nesturbator/nesturbatorConfig.cmake")
inventory_hash=$(sha256_file "$evidence_root/installed-ctest-inventory.json")
junit_hash=$(sha256_file "$evidence_root/installed-ctest-results.junit.xml")
log_hash=$(sha256_file "$evidence_root/installed-ctest-output.log")
process_facts_hash=$(sha256_file "$evidence_root/installed-ctest-process-facts.txt")
resolution_hash=$(sha256_file "$evidence_root/installed-package-resolution.txt")
link_audit_hash=$(sha256_file "$evidence_root/installed-link-audit.txt")

{
  printf 'format=libfuturo-muhtari-api8-route-v1\n'
  printf 'route=installed\nrun_id=%s\nresult=pass\n' "$run_id"
  printf 'source_commit=%s\nsource_worktree_fingerprint=sha256:%s\nbuild_fingerprint=sha256:%s\n' \
    "$source_commit" "$source_worktree_fingerprint" "$build_fingerprint"
  printf 'platform=%s\narchitecture=%s\n' "$(uname -s)" "$(uname -m)"
  printf 'api_revision=8\napi_abi=1\nbehavior_revision=6\nstate_format=1\n'
  printf 'muhtari_version=0.11.1\nmuhtari_source_revision=d58f125297c4d63a7a8108112a5eafff6f53a76a\n'
  printf 'profile=muhtari-ntsc-v2\nconfiguration=muhtari-ntsc-battery-diagnostic\n'
  printf 'effective_options=none\nreplay_frame=3\n'
  printf 'snapshot_boundary=R2-frame2-pending-savekey-write\n'
  printf 'replay_boundary=R3-frame3-savekey-published\nreplay_savekey_offset=2051\n'
  printf 'replay_video_sha256=59b78332303fa3c631ae7cd522ad45627f739b49a48e8c0b0c07f45ea79bd225\n'
  printf 'replay_pcm_sha256=09474df08fabeb22495ea69a6becd73374879d6840862382d0691c6e7a13a13f\n'
  printf 'replay_battery=full-span-r3\n'
  printf 'replay_battery_sha256=495ead1f5e803049666b25490aa47495e529eda7c8516eb3513947b403b4a583\n'
  printf 'snapshot_r2_battery_sha256=036d171c7642abeb0acc3670afc5a67422bf028b0086d0d8720a95985fdfdb64\n'
  printf 'fixture_bytes=%s\nfixture_sha256=sha256:%s\n' "$fixture_bytes" "$fixture_digest"
  printf 'fixture_generator_ref=artifacts/installed-test-sources/muhtari_snapshot_fixture.h\n'
  printf 'fixture_generator_sha256=sha256:%s\n' "$fixture_generator_hash"
  printf 'fixture_base_ref=artifacts/installed-test-sources/muhtari_fixture.h\nfixture_base_sha256=sha256:%s\n' "$fixture_base_hash"
  printf 'consumer_source_ref=artifacts/installed-test-sources/muhtari_snapshot.c\nconsumer_source_sha256=sha256:%s\n' "$consumer_source_hash"
  printf 'snapshot_oracle_ref=artifacts/installed-test-sources/muhtari_snapshot_oracle.h\nsnapshot_oracle_sha256=sha256:%s\n' "$snapshot_oracle_hash"
  printf 'checkpoint_bytes=%s\ncheckpoint_sha256=sha256:%s\n' "$checkpoint_bytes" "$checkpoint_digest"
  printf 'libfuturo_ref=artifacts/moved-prefix/lib/liblibfuturo.a\nlibfuturo_sha256=sha256:%s\n' "$libfuturo_hash"
  printf 'nesturbator_ref=artifacts/moved-prefix/lib/libnesturbator.a\nnesturbator_sha256=sha256:%s\n' "$nesturbator_hash"
  printf 'muhtari_ref=artifacts/moved-prefix/lib/libmuhtari.a\nmuhtari_sha256=sha256:%s\n' "$muhtari_hash"
  printf 'consumer_ref=artifacts/installed-consumer/muhtari_api8_consumer\nconsumer_sha256=sha256:%s\n' "$consumer_hash"
  printf 'libfuturo_config_ref=artifacts/moved-prefix/lib/cmake/libfuturo/libfuturoConfig.cmake\nlibfuturo_config_sha256=sha256:%s\n' "$libfuturo_config_hash"
  printf 'muhtari_config_ref=artifacts/moved-prefix/lib/cmake/muhtari/muhtariConfig.cmake\nmuhtari_config_sha256=sha256:%s\n' "$muhtari_config_hash"
  printf 'nesturbator_config_ref=artifacts/moved-prefix/lib/cmake/nesturbator/nesturbatorConfig.cmake\nnesturbator_config_sha256=sha256:%s\n' "$nesturbator_config_hash"
  printf 'supervisor_ref=artifacts/installed-test-sources/muhtari_fresh_process_supervisor.sh\nsupervisor_sha256=sha256:%s\n' "$supervisor_hash"
  printf 'process_tree_helper_ref=artifacts/installed-test-sources/process-tree-cleanup.sh\nprocess_tree_helper_sha256=sha256:%s\n' "$helper_hash"
  printf 'oracle_controls_ref=artifacts/installed-test-sources/muhtari_fresh_process_oracle_controls.sh\noracle_controls_sha256=sha256:%s\n' "$oracle_hash"
  printf 'ctest_inventory_ref=installed-ctest-inventory.json\nctest_inventory_sha256=sha256:%s\n' "$inventory_hash"
  printf 'ctest_junit_ref=installed-ctest-results.junit.xml\nctest_junit_sha256=sha256:%s\n' "$junit_hash"
  printf 'ctest_log_ref=installed-ctest-output.log\nctest_log_sha256=sha256:%s\n' "$log_hash"
  printf 'ctest_process_facts_ref=installed-ctest-process-facts.txt\nctest_process_facts_sha256=sha256:%s\n' "$process_facts_hash"
  printf 'package_resolution_ref=installed-package-resolution.txt\npackage_resolution_sha256=sha256:%s\n' "$resolution_hash"
  printf 'link_audit_ref=installed-link-audit.txt\nlink_audit_sha256=sha256:%s\n' "$link_audit_hash"
  printf 'ctest_exit_status=0\nctest_signal=none\nctest_timed_out=no\n'
  printf 'isolation=checkout,build unavailable during downstream configure,build,ctest\n'
  printf 'outer_install_seconds=%s\nouter_configure_build_ctest_seconds=%s\n' \
    "$install_elapsed" "$stage_elapsed"
  expected_tests='muhtari_api8_profile muhtari_api8_fixture_boundary muhtari_api8_fixture_oracle_controls muhtari_api8_snapshot_contract muhtari_api8_installed_fresh_process muhtari_api8_installed_oracle_controls'
  for test_name in $expected_tests; do
    printf 'test_result=%s|passed\n' "$test_name"
  done
} > "$report_tmp"
sed -E 's/^[[:space:]]*[0-9]+: //' "$consumer_build/ctest-output.log" | \
  awk -v start='event=supervisor-start route=installed' \
      -v finish='event=supervisor-success route=installed result=pass' \
      '$0 == start { recording = 1 } recording && /^verified_lifecycle=/ { print "lifecycle_event=" $0 } recording && /^event=/ { print "behavior_event=" $0; if ($0 == finish) { found = 1; exit } } END { if (!found) exit 1 }' \
  >> "$report_tmp" || {
    echo 'muhtari api8 relocation: ordered installed supervisor event record is missing' >&2
    exit 16
  }
cp "$report_tmp" "$evidence_root/installed-route.report"
report_hash=$(sha256_file "$evidence_root/installed-route.report")
printf 'report_sha256=sha256:%s\n' "$report_hash" \
  > "$evidence_root/installed-route-report-identity.txt"

printf 'muhtari_api8_relocated_consumer: route=installed tests=6 result=pass report=installed-route.report report_sha256=sha256:%s run_id=%s\n' \
  "$report_hash" "$run_id"
