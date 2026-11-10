#!/bin/sh
set -eu

source_dir=$1
conflict_dir=$2
consumer_dir=$3
moved_prefix=$4
ambient_prefix=$5
cmake_bin=$6
c_compiler=$7
osx_sysroot=$8
ctest_bin=$9
root_dir=${10}
build_dir=${11}

mkdir -p "$conflict_dir" "$consumer_dir"
if ! "$cmake_bin" -S "$source_dir" -B "$conflict_dir" \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  "-DCMAKE_C_COMPILER=$c_compiler" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  "-DCMAKE_OSX_SYSROOT=$osx_sysroot" \
  "-DCMAKE_PREFIX_PATH=$ambient_prefix" \
  -DCMAKE_FIND_PACKAGE_NO_PACKAGE_REGISTRY=ON \
  "-DEXPECTED_INSTALL_PREFIX=$moved_prefix" \
  -DEXPECTED_MUHTARI_ENABLED=ON \
  -DEXPECTED_MUHTARI_API_REVISION=8 \
  -DEXPECTED_MUHTARI_VERSION=0.11.1 \
  -DEXPECTED_MUHTARI_SOURCE_REVISION=d58f125297c4d63a7a8108112a5eafff6f53a76a \
  -DLIBFUTURO_PRELOADED_CORE_CONFLICT=muhtari; then
  echo 'muhtari api8 relocation: preloaded Muhtari target was not safely rejected' >&2
  exit 8
fi

"$cmake_bin" -S "$source_dir" -B "$consumer_dir" \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  "-DCMAKE_C_COMPILER=$c_compiler" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  "-DCMAKE_OSX_SYSROOT=$osx_sysroot" \
  "-DCMAKE_PREFIX_PATH=$ambient_prefix" \
  -DCMAKE_FIND_PACKAGE_NO_PACKAGE_REGISTRY=ON \
  "-DEXPECTED_INSTALL_PREFIX=$moved_prefix" \
  -DEXPECTED_MUHTARI_ENABLED=ON \
  -DEXPECTED_MUHTARI_API_REVISION=8 \
  -DEXPECTED_MUHTARI_VERSION=0.11.1 \
  -DEXPECTED_MUHTARI_SOURCE_REVISION=d58f125297c4d63a7a8108112a5eafff6f53a76a

inventory="$consumer_dir/ctest-inventory.json"
"$ctest_bin" --test-dir "$consumer_dir" --show-only=json-v1 > "$inventory"
expected_tests="muhtari_api8_profile muhtari_api8_fixture_boundary muhtari_api8_fixture_oracle_controls muhtari_api8_snapshot_contract muhtari_api8_installed_fresh_process muhtari_api8_installed_oracle_controls"
test_regex='^(muhtari_api8_profile|muhtari_api8_fixture_boundary|muhtari_api8_fixture_oracle_controls|muhtari_api8_snapshot_contract|muhtari_api8_installed_fresh_process|muhtari_api8_installed_oracle_controls)$'
missing=
for test_name in $expected_tests; do
  if ! grep -Fq "\"$test_name\"" "$inventory"; then
    missing="$missing $test_name"
  fi
done
if [ -n "$missing" ]; then
  echo "muhtari api8 relocation: downstream suite registration assertion failed; missing:$missing" >&2
  exit 21
fi

"$cmake_bin" --build "$consumer_dir" --target muhtari_api8_consumer
link_file="$consumer_dir/CMakeFiles/muhtari_api8_consumer.dir/link.txt"
compile_file="$consumer_dir/compile_commands.json"
if [ ! -s "$link_file" ] || [ ! -s "$compile_file" ] ||
   ! grep -Fq "$moved_prefix/lib/liblibfuturo.a" "$link_file" ||
   ! grep -Fq "$moved_prefix/lib/libmuhtari.a" "$link_file" ||
   ! grep -Fq "$moved_prefix/lib/libnesturbator.a" "$link_file" ||
   ! grep -Fq "$moved_prefix/include" "$compile_file" ||
   grep -Fq "$root_dir" "$compile_file" ||
   grep -Fq "$build_dir" "$compile_file" ||
   grep -Fq "$root_dir" "$link_file" ||
   grep -Fq "$build_dir" "$link_file"; then
  echo 'muhtari api8 relocation: moved package link/compile path audit failed' >&2
  exit 9
fi

junit="$consumer_dir/ctest-results.junit.xml"
log="$consumer_dir/ctest-output.log"
run_started=$(date +%s)
if ! LF_PROCESS_TREE_HELPER="$source_dir/process-tree-cleanup.sh" \
   LF_FRESH_PROCESS_ROUTE=installed \
   LF_FRESH_PROCESS_TIMEOUT_SECONDS=30 \
   "$ctest_bin" --test-dir "$consumer_dir" \
     -R "$test_regex" --no-tests=error --verbose \
     --output-on-failure --output-junit "$junit" > "$log" 2>&1; then
  cat "$log" >&2
  exit 10
fi
if grep -Eq '<skipped|status="(disabled|notrun)"|failures="[1-9]' "$junit"; then
  echo 'muhtari api8 relocation: nested CTest report contains skipped or failed cases' >&2
  exit 11
fi
for test_name in $expected_tests; do
  if ! grep -Fq "<testcase name=\"$test_name\"" "$junit"; then
    echo "muhtari api8 relocation: nested JUnit result is missing $test_name" >&2
    exit 12
  fi
done
printf 'run_started=%s\n' "$run_started" > "$consumer_dir/process-facts.txt"
printf 'exit_status=0\nsignal=none\ntimed_out=no\n' >> "$consumer_dir/process-facts.txt"
