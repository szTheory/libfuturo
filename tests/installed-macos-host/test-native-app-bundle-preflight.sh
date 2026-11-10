#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo 'native app bundle preflight controls: expected preflight script path' >&2
  exit 2
fi

PREFLIGHT=$1
TEMP_ROOT=${TMPDIR:-/tmp}
SCRATCH=$(/usr/bin/mktemp -d "$TEMP_ROOT/libfuturo-bundle-preflight-controls.XXXXXX")
cleanup() {
  rm -rf "$SCRATCH"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

expect_rejected() {
  label=$1
  bundle=$2
  if /bin/sh "$PREFLIGHT" "$bundle" "$SCRATCH/$label.txt"; then
    echo "native app bundle preflight controls: accepted invalid case $label" >&2
    exit 1
  fi
}

expect_rejected missing-bundle "$SCRATCH/not-a-bundle.app"

/bin/mkdir -p "$SCRATCH/missing-info.app/Contents"
expect_rejected missing-info "$SCRATCH/missing-info.app"

/bin/mkdir -p "$SCRATCH/malformed-info.app/Contents"
printf 'not a property list\n' > "$SCRATCH/malformed-info.app/Contents/Info.plist"
expect_rejected malformed-info "$SCRATCH/malformed-info.app"

/bin/mkdir -p "$SCRATCH/missing-executable.app/Contents/MacOS"
cat > "$SCRATCH/missing-executable.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>org.libfuturo.installed-host</string>
  <key>CFBundleExecutable</key><string>absent</string>
</dict></plist>
PLIST
expect_rejected missing-executable "$SCRATCH/missing-executable.app"

/bin/mkdir -p "$SCRATCH/wrong-format.app/Contents/MacOS"
cat > "$SCRATCH/wrong-format.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>org.libfuturo.installed-host</string>
  <key>CFBundleExecutable</key><string>not-macho</string>
</dict></plist>
PLIST
printf '#!/bin/sh\nexit 0\n' > "$SCRATCH/wrong-format.app/Contents/MacOS/not-macho"
chmod 700 "$SCRATCH/wrong-format.app/Contents/MacOS/not-macho"
expect_rejected wrong-format "$SCRATCH/wrong-format.app"

echo 'native_app_bundle_preflight_controls: invalid=missing-bundle,missing-info,malformed-info,missing-executable,wrong-format result=pass'
