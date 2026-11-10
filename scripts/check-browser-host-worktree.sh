#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' 'Usage: scripts/check-browser-host-worktree.sh all|host-tracer|host-content|host-input|host-input-audio|host-lifecycle|host-ui' >&2
}

if [[ $# -ne 1 || ! "$1" =~ ^(all|host-tracer|host-content|host-input|host-input-audio|host-lifecycle|host-ui)$ ]]; then
  usage
  exit 2
fi
readonly SCENARIO="$1"
readonly ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || true)"
readonly BROWSER_CACHE_DIR="$ROOT_DIR/build/browser-host-cache"
if [[ -z "$ROOT_DIR" ]]; then
  printf '%s\n' 'error: could not determine the repository root' >&2
  exit 2
fi
readonly SOURCE_CHECKOUT_HEAD="$(git -C "$ROOT_DIR" rev-parse HEAD)"
if ! git -C "$ROOT_DIR" check-ignore -q build/browser-host-cache/browser-artifact.zip; then
  printf '%s\n' 'error: build/ is not ignored; refusing to write browser cache artifacts there' >&2
  exit 2
fi
mkdir -p "$BROWSER_CACHE_DIR"

readonly SNAPSHOT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/libfuturo-browser-host.XXXXXX")"
readonly EVIDENCE_DIR="$ROOT_DIR/build/browser-host-worktree/${SCENARIO}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
preserve_evidence() {
  local route_dir source_evidence destination
  for route_dir in "$SNAPSHOT_DIR"/build/browser-package/*; do
    [[ -d "$route_dir/evidence" ]] || continue
    source_evidence="$route_dir/evidence"
    destination="$EVIDENCE_DIR"
    mkdir -p "$destination"
    for report in image-pull.log compile-route.log consumer-report.json browser-report.json \
                  browser-qualification.json \
                  browser-process.log browser-runtime-packages.txt \
                  host-ui-mobile.png host-ui-desktop.png; do
      if [[ -f "$source_evidence/$report" ]]; then
        cp -p "$source_evidence/$report" "$destination/$report"
      fi
    done
    if [[ -d "$source_evidence/qualification" ]]; then
      cp -pR "$source_evidence/qualification" "$destination/qualification"
    fi
    printf 'scenario=%s snapshot_kind=worktree-snapshot checkout_head=%s synthetic_commit=%s synthetic_tree=%s\n' \
      "$SCENARIO" "$SOURCE_CHECKOUT_HEAD" \
      "$(git -C "$SNAPSHOT_DIR" rev-parse HEAD 2>/dev/null || printf unknown)" \
      "$(git -C "$SNAPSHOT_DIR" rev-parse 'HEAD^{tree}' 2>/dev/null || printf unknown)" \
      > "$destination/snapshot.txt"
    printf 'Preserved browser scenario evidence: %s\n' \
      "${destination#"$ROOT_DIR"/}"
    break
  done
}
cleanup() {
  preserve_evidence
  rm -rf "$SNAPSHOT_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Recreate tracked worktree contents, including edits, while excluding generated
# build output. Only the two planned new source files may enter as untracked files;
# unrelated user files and planning metadata never enter the synthetic snapshot.
while IFS= read -r -d '' relative_path; do
  case "$relative_path" in
    .git/*|build/*) continue ;;
  esac
  source_path="$ROOT_DIR/$relative_path"
  if [[ -e "$source_path" || -L "$source_path" ]]; then
    destination="$SNAPSHOT_DIR/$relative_path"
    mkdir -p "$(dirname "$destination")"
    cp -pR "$source_path" "$destination"
  fi
done < <(git -C "$ROOT_DIR" ls-files -z)

for relative_path in \
  tests/web-consumer/consumer-host.js \
  tests/browser/qualification.mjs \
  tests/browser/qualification.test.mjs \
  scripts/check-browser-host-worktree.sh; do
  if [[ -f "$ROOT_DIR/$relative_path" ]] &&
     ! git -C "$ROOT_DIR" ls-files --error-unmatch -- "$relative_path" >/dev/null 2>&1; then
    destination="$SNAPSHOT_DIR/$relative_path"
    mkdir -p "$(dirname "$destination")"
    cp -p "$ROOT_DIR/$relative_path" "$destination"
  fi
done

git -C "$SNAPSHOT_DIR" init --quiet
git -C "$SNAPSHOT_DIR" config user.name 'LibFuturo Browser Check'
git -C "$SNAPSHOT_DIR" config user.email 'browser-check@localhost'
git -C "$SNAPSHOT_DIR" add --all
git -C "$SNAPSHOT_DIR" commit --quiet -m "test: isolated browser host worktree snapshot"
if [[ -n "$(git -C "$SNAPSHOT_DIR" status --porcelain --untracked-files=all)" ]]; then
  printf '%s\n' 'error: synthetic browser snapshot is not clean' >&2
  exit 2
fi

printf 'Browser worktree snapshot: scenario=%s source=%s\n' \
  "$SCENARIO" "$(git -C "$SNAPSHOT_DIR" rev-parse --short HEAD)"
if [[ "$SCENARIO" == all ]]; then
  (cd "$SNAPSHOT_DIR" && \
    LIBFUTURO_SOURCE_SNAPSHOT=worktree-snapshot \
    LIBFUTURO_BROWSER_CACHE_DIR="$BROWSER_CACHE_DIR" \
    scripts/check-browser-package.sh)
else
  (cd "$SNAPSHOT_DIR" && \
    LIBFUTURO_SOURCE_SNAPSHOT=worktree-snapshot \
    LIBFUTURO_BROWSER_CACHE_DIR="$BROWSER_CACHE_DIR" \
    scripts/check-browser-package.sh "--scenario=$SCENARIO")
fi
