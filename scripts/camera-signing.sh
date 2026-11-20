#!/usr/bin/env bash
# Signs the app so it may install its camera, when this Mac has a Developer ID
# provisioning profile for com.reffwu.pixelmirror with the System Extension
# capability. Without one, the camera is left out and nothing else changes.
set -euo pipefail
cd "$(dirname "$0")/.."

out="Config/Camera.local.xcconfig"
profiles="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
rm -f "$out"
shopt -s nullglob
for file in "$profiles"/*.provisionprofile; do
  plist="$(security cms -D -i "$file" 2>/dev/null)" || continue
  value() { /usr/libexec/PlistBuddy -c "Print :$1" /dev/stdin <<<"$plist" 2>/dev/null || true; }
  [ "$(value Entitlements:com.apple.application-identifier)" = "37V2HFG7YT.com.reffwu.pixelmirror" ] || continue
  [ "$(value Entitlements:com.apple.developer.system-extension.install)" = "true" ] || continue
  cat >"$out" <<CONFIG
CODE_SIGN_ENTITLEMENTS = Config/PixelMirror-Camera.entitlements
PROVISIONING_PROFILE_SPECIFIER = $(value UUID)
CONFIG
  echo "Camera: signing with profile $(value Name)"
  exit 0
done
