#!/usr/bin/env bash
# Fetches the pinned adb and scrcpy-server into Vendor/Helpers and verifies
# them against vendor.lock. A no-op when the right versions are in place.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source vendor.lock

out="Vendor/Helpers"
stamp="$out/versions.txt"
want="adb=$ADB_VERSION scrcpy=$SCRCPY_VERSION"
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

curl -fsSL "$SCRCPY_URL" -o "$tmp/scrcpy-server"
check "$tmp/scrcpy-server" "$SCRCPY_SHA256"

mkdir -p "$out"
install -m 755 "$tmp/platform-tools/adb" "$out/adb"
install -m 644 "$tmp/platform-tools/NOTICE.txt" "$out/adb-NOTICE.txt"
install -m 644 "$tmp/scrcpy-server" "$out/scrcpy-server"
printf '%s' "$SCRCPY_VERSION" > "$out/scrcpy-version.txt"
printf '%s' "$want" > "$stamp"
echo "Vendored $want"
