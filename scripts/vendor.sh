#!/usr/bin/env bash
# Fetches verified adb and builds the patched scrcpy server into Vendor/Helpers.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source vendor.lock

out="Vendor/Helpers"
stamp="$out/versions.txt"
scrcpy_patch="$PWD/patches/scrcpy-primary-display-power.patch"
patch_hash="$(shasum -a 256 "$scrcpy_patch" | awk '{print $1}')"
want="adb=$ADB_VERSION scrcpy=$SCRCPY_VERSION source=$SCRCPY_SOURCE_SHA256 patch=$patch_hash"
if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$want" ] && [ -x "$out/adb" ] && [ -f "$out/scrcpy-server" ]; then
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

check() {
  local file="$1" expected="$2" actual
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    echo "Checksum mismatch for $file: $actual, expected $expected" >&2
    exit 1
  fi
}

curl -fsSL "$ADB_URL" -o "$tmp/platform-tools.zip"
check "$tmp/platform-tools.zip" "$ADB_SHA256"
unzip -q "$tmp/platform-tools.zip" platform-tools/adb platform-tools/NOTICE.txt -d "$tmp"

curl -fsSL "$SCRCPY_SOURCE_URL" -o "$tmp/scrcpy.tar.gz"
check "$tmp/scrcpy.tar.gz" "$SCRCPY_SOURCE_SHA256"
tar -xzf "$tmp/scrcpy.tar.gz" -C "$tmp"
scrcpy_source="$tmp/scrcpy-$SCRCPY_VERSION"
(
  cd "$scrcpy_source"
  git apply "$scrcpy_patch"
  "${SCRCPY_GRADLE:-./gradlew}" --console=plain :server:assembleRelease
)

mkdir -p "$out"
install -m 755 "$tmp/platform-tools/adb" "$out/adb"
install -m 644 "$tmp/platform-tools/NOTICE.txt" "$out/adb-NOTICE.txt"
install -m 644 "$scrcpy_source/server/build/outputs/apk/release/server-release-unsigned.apk" "$out/scrcpy-server"
printf '%s' "$SCRCPY_VERSION" > "$out/scrcpy-version.txt"
printf '%s' "$want" > "$stamp"
echo "Vendored $want"
