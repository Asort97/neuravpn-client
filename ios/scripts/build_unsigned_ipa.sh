#!/usr/bin/env bash
set -euo pipefail

# Shared by GitHub Actions and Codemagic: build the app and its PacketTunnel
# extension without signing, check the bundle, and package an unsigned IPA.
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

xcconfig="$(mktemp "${TMPDIR:-/tmp}/neuravpn-unsigned.XXXXXX.xcconfig")"
trap 'rm -f "$xcconfig"' EXIT
cat > "$xcconfig" <<'CONFIG'
CODE_SIGNING_ALLOWED = NO
CODE_SIGNING_REQUIRED = NO
CODE_SIGN_IDENTITY =
DEVELOPMENT_TEAM =
CONFIG
export XCODE_XCCONFIG_FILE="$xcconfig"
flutter build ios --release --no-codesign

app=build/ios/iphoneos/Runner.app
appex="$app/PlugIns/PacketTunnel.appex"
plist() { /usr/libexec/PlistBuddy -c "Print $2" "$1/Info.plist"; }
test -f "$appex/PacketTunnel"
test "$(plist "$app" CFBundleIdentifier)" = com.neuravpn.app
test "$(plist "$appex" CFBundleIdentifier)" = com.neuravpn.app.PacketTunnel
test "$(plist "$app" CFBundleVersion)" = "$(plist "$appex" CFBundleVersion)"
if find "$appex" -iname '*.dat' -o -name 'Flutter.framework' | grep -q .; then
  echo 'Unexpected Flutter/geo assets in the extension' >&2
  exit 1
fi

rm -rf build/ios/unsigned build/ios/neuravpn-unsigned.ipa
mkdir -p build/ios/unsigned/Payload
ditto "$app" build/ios/unsigned/Payload/Runner.app
(cd build/ios/unsigned && /usr/bin/zip -q -r -y ../neuravpn-unsigned.ipa Payload)
echo "Built $root/build/ios/neuravpn-unsigned.ipa"
