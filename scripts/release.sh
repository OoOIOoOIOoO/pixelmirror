#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

app="PixelMirror"
repo="ReffWu/pixelmirror"
team="37V2HFG7YT"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
archive="build/$app.xcarchive"
options="build/export-options.plist"
submitted="build/submitted"
notarized="build/notarized"
packages="build/SourcePackages"
feed="build/feed"

rm -rf "$archive" "$submitted" "$notarized" "$feed" dist
mkdir -p build dist

xcodebuild archive -quiet \
  -project "$app.xcodeproj" -scheme "$app" -configuration Release \
  -archivePath "$archive" -destination 'generic/platform=macOS' \
  -clonedSourcePackagesDirPath "$packages"

cat > "$options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>destination</key>
  <string>upload</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>signingCertificate</key>
  <string>Developer ID Application</string>
  <key>teamID</key>
  <string>${team}</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive -allowProvisioningUpdates \
  -archivePath "$archive" -exportOptionsPlist "$options" -exportPath "$submitted"

for _ in $(seq 1 60); do
  if xcodebuild -exportNotarizedApp -allowProvisioningUpdates \
    -archivePath "$archive" -exportPath "$notarized" >/dev/null 2>&1; then
    break
  fi
  echo "Waiting for Apple to notarize $app $version"
  sleep 30
done
test -d "$notarized/$app.app"

codesign --verify --deep --strict "$notarized/$app.app"
xcrun stapler validate "$notarized/$app.app"
spctl --assess --type execute "$notarized/$app.app"
"$notarized/$app.app/Contents/Resources/Helpers/adb" version >/dev/null

stage="$(mktemp -d "${TMPDIR:-/tmp}/$app-release.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto "$notarized/$app.app" "$stage/$app.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -ov -volname "$app" -srcfolder "$stage" -format UDZO "dist/$app.dmg"
if [ -n "${NOTARY_PROFILE:-}" ]; then
  codesign --force --timestamp --sign "Developer ID Application: XIN SHENG WU ($team)" "dist/$app.dmg"
  xcrun notarytool submit "dist/$app.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "dist/$app.dmg"
fi
(cd dist && shasum -a 256 "$app.dmg" > "$app.dmg.sha256")

mkdir -p "$feed"
cp "dist/$app.dmg" "$feed/"
"$packages/artifacts/sparkle/Sparkle/bin/generate_appcast" "$feed" \
  --download-url-prefix "https://github.com/$repo/releases/download/v$version/"
grep -q "sparkle:edSignature" "$feed/appcast.xml"

if [ "${1:-}" = "--publish" ]; then
  gh release create -R "$repo" "v$version" "dist/$app.dmg" "dist/$app.dmg.sha256" "$feed/appcast.xml" \
    --title "$app $version" --generate-notes --target main --draft
  gh release edit -R "$repo" "v$version" --draft=false --latest
  rm -rf "$archive" "$submitted" "$notarized" dist
fi

echo "$app $version is ready"
