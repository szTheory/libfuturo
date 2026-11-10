#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  echo 'native app bundle preflight: expected app bundle and report path' >&2
  exit 2
fi

APP_ARGUMENT=$1
REPORT_PATH=$2
/bin/mkdir -p "$(dirname "$REPORT_PATH")"
: > "$REPORT_PATH"
exec >> "$REPORT_PATH" 2>&1

fail() {
  printf 'result=fail\nreason=%s\n' "$1"
  exit 1
}

printf 'format=libfuturo-native-app-bundle-preflight-v1\n'
printf 'app_argument=%s\n' "$APP_ARGUMENT"
printf 'umask=%s\n' "$(umask)"

[ -d "$APP_ARGUMENT" ] || fail app-bundle-missing
APP_BUNDLE=$(CDPATH= cd "$APP_ARGUMENT" && pwd -P) || fail app-bundle-unresolvable
printf 'app_real_path=%s\n' "$APP_BUNDLE"

INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
[ -f "$INFO_PLIST" ] || fail info-plist-missing
if /usr/bin/plutil -lint "$INFO_PLIST"; then
  printf 'info-plist=valid\n'
else
  fail info-plist-invalid
fi

if BUNDLE_IDENTIFIER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$INFO_PLIST" 2>&1); then
  printf 'cfbundle-identifier=%s\n' "$BUNDLE_IDENTIFIER"
else
  printf 'cfbundle-identifier-error=%s\n' "$BUNDLE_IDENTIFIER"
  fail cfbundle-identifier-unreadable
fi
[ "$BUNDLE_IDENTIFIER" = org.libfuturo.installed-host ] ||
  fail cfbundle-identifier-unexpected

if EXECUTABLE_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
    "$INFO_PLIST" 2>&1); then
  :
else
  printf 'cfbundle-executable-error=%s\n' "$EXECUTABLE_NAME"
  fail cfbundle-executable-unreadable
fi
case "$EXECUTABLE_NAME" in
  ''|.|..|*/*) fail cfbundle-executable-not-a-basename ;;
esac
printf 'cfbundle-executable=%s\n' "$EXECUTABLE_NAME"

EXECUTABLE_PATH="$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
[ -f "$EXECUTABLE_PATH" ] || fail named-executable-missing
[ -x "$EXECUTABLE_PATH" ] || fail named-executable-not-executable
printf 'named-executable=present-and-executable\n'

if FILE_DESCRIPTION=$(/usr/bin/file -b "$EXECUTABLE_PATH" 2>&1); then
  printf 'file-description=%s\n' "$FILE_DESCRIPTION"
else
  fail executable-file-inspection-failed
fi
case "$FILE_DESCRIPTION" in
  *Mach-O*) ;;
  *) fail executable-is-not-mach-o ;;
esac

if EXECUTABLE_ARCHES=$(/usr/bin/lipo -archs "$EXECUTABLE_PATH" 2>&1); then
  printf 'executable-architectures=%s\n' "$EXECUTABLE_ARCHES"
else
  printf 'executable-architecture-error=%s\n' "$EXECUTABLE_ARCHES"
  fail executable-architecture-inspection-failed
fi
case " $EXECUTABLE_ARCHES " in
  *' arm64 '*) ;;
  *) fail executable-lacks-arm64 ;;
esac

if /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"; then
  printf 'codesign-verification=passed\n'
else
  fail codesign-verification-failed
fi
if /usr/bin/codesign -dv --verbose=4 "$APP_BUNDLE"; then
  :
else
  fail codesign-details-unavailable
fi

printf 'bundle-files-begin\n'
find "$APP_BUNDLE" -type f -print | LC_ALL=C sort |
while IFS= read -r file_path; do
  relative_path=${file_path#"$APP_BUNDLE"/}
  file_hash=$(/usr/bin/shasum -a 256 "$file_path" | awk '{print $1}')
  file_facts=$(/usr/bin/stat -f 'bytes=%z mode=%Sp uid=%u gid=%g' "$file_path")
  printf 'bundle-file=%s %s sha256:%s\n' \
    "$relative_path" "$file_facts" "$file_hash"
done
printf 'bundle-files-end\n'

printf 'path-access-and-metadata-begin\n'
for bundle_path in "$APP_BUNDLE" "$APP_BUNDLE/Contents" \
    "$APP_BUNDLE/Contents/MacOS" "$EXECUTABLE_PATH"; do
  [ -e "$bundle_path" ] || fail bundle-path-component-missing
  printf 'bundle-path=%s\n' "$bundle_path"
  /bin/ls -ldeO "$bundle_path"
  printf 'extended-attribute-names-begin\n'
  /usr/bin/xattr "$bundle_path" 2>/dev/null || true
  printf 'extended-attribute-names-end\n'
done

parent_path=$(dirname "$APP_BUNDLE")
while :; do
  [ -x "$parent_path" ] || fail bundle-parent-not-searchable
  printf 'bundle-parent=%s\n' "$parent_path"
  /usr/bin/stat -f 'mode=%Sp uid=%u gid=%g' "$parent_path"
  /bin/ls -ldeO "$parent_path"
  printf 'extended-attribute-names-begin\n'
  /usr/bin/xattr "$parent_path" 2>/dev/null || true
  printf 'extended-attribute-names-end\n'
  [ "$parent_path" != / ] || break
  parent_path=$(dirname "$parent_path")
done
printf 'path-access-and-metadata-end\n'

printf 'linked-images-begin\n'
/usr/bin/otool -L "$EXECUTABLE_PATH"
printf 'linked-images-end\n'
printf 'result=pass\n'
