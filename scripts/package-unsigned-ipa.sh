#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
build_number="${BUILD_NUMBER:-1}"
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || { echo 'BUILD_NUMBER must be a positive integer'; exit 1; }
bundle_id='dev.yurashu2.otogurashi'
build_root="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/otogurashi-ipa.XXXXXX")"
output_root="$repo_root/build/unsigned-ipa-output"
mkdir -p "$build_root/Payload" "$output_root"
xcodebuild -version
flutter --version
flutter pub get
flutter build ios --release --no-codesign --config-only --build-number="$build_number"

# iPhone device archive only. iLoader signs locally on the user's Windows PC.
xcodebuild archive \
  -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release \
  -destination 'generic/platform=iOS' -sdk iphoneos \
  -archivePath "$build_root/OtoGrashi.xcarchive" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
  DEVELOPMENT_TEAM='' PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" \
  2>&1 | tee build/unsigned-ipa-log.txt

app="$build_root/OtoGrashi.xcarchive/Products/Applications/Runner.app"
test -f "$app/Info.plist"
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")"
test -f "$app/$executable"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")" = "$bundle_id"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms:0' "$app/Info.plist")" = 'iPhoneOS'
lipo -verify_arch arm64 "$app/$executable"
test ! -e "$app/embedded.mobileprovision"
test ! -d "$app/_CodeSignature"
ditto "$app" "$build_root/Payload/Runner.app"
ditto -c -k --keepParent "$build_root/Payload" "$output_root/OtoGrashi-unsigned.ipa"
unzip -tq "$output_root/OtoGrashi-unsigned.ipa"
(
  cd "$output_root"
  shasum -a256 OtoGrashi-unsigned.ipa > SHA256SUMS.txt
)
git rev-parse HEAD > "$output_root/commit.txt"
printf 'Bundle ID: %s\nTeam ID: (empty)\nBuild: %s\nConfiguration: Release / iPhoneOS arm64\nSigning: disabled; sign with iLoader on Windows\n' \
  "$bundle_id" "$build_number" > "$output_root/build-info.txt"
if [[ -d "$build_root/OtoGrashi.xcarchive/dSYMs" ]]; then
  ditto -c -k --keepParent "$build_root/OtoGrashi.xcarchive/dSYMs" "$output_root/dSYMs.zip"
fi
echo "IPA: $output_root/OtoGrashi-unsigned.ipa"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf '### iLoader用・署名なしRelease IPA\n\nArtifacts の **OtoGrashi-unsigned-ipa** をダウンロードし、ZIP内の `OtoGrashi-unsigned.ipa` をWindowsのiLoaderで署名してください。\n\nBundle ID: `%s` / Team ID: 空欄 / Build: `%s`\n\nAppleへのアップロード・署名・実機インストールはこのジョブでは行っていません。\n' \
    "$bundle_id" "$build_number" >> "$GITHUB_STEP_SUMMARY"
fi
