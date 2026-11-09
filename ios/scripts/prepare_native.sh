#!/usr/bin/env bash
set -euo pipefail

# Called by CI. Version and digest pins are explicit in ios.yml.
: "${LIBXRAY_VERSION:?}" "${LIBXRAY_SHA256:?}" "${HEV_VERSION:?}" "${HEV_SHA256:?}"
ios_dir="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/neuravpn-native.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$ios_dir/Frameworks" "$work/xray" "$work/hev"

download() {
  local url="$1" output="$2" expected="$3"
  curl --fail --location --retry 4 --retry-all-errors --connect-timeout 20 \
    --max-time 300 "$url" -o "$output"
  local actual
  actual="$(shasum -a 256 "$output" | awk '{print $1}')"
  echo "$(basename "$output") SHA-256: $actual"
  [[ "$actual" == "$expected" ]] || { echo "Checksum mismatch" >&2; exit 1; }
}

download "https://github.com/XTLS/libXray/releases/download/$LIBXRAY_VERSION/libxray-apple-cgo.zip" \
  "$work/libxray.zip" "$LIBXRAY_SHA256"
unzip -q "$work/libxray.zip" -d "$work/xray"
framework="$(find "$work/xray" -type d -name LibXray.xcframework -prune)"
[[ -d "$framework" ]] || { echo "Expected one LibXray.xcframework" >&2; exit 1; }
# Xcode copies every static XCFramework's Headers/ into one shared
# build/<config>/include/. Upstream ships module.modulemap at the top of
# Headers/, where it collides with other libraries' maps; nest each slice's
# headers under Headers/LibXray/ (module maps use relative paths).
for headers in "$framework"/*/Headers; do
  [[ -f "$headers/module.modulemap" ]] || continue
  nested="$(mktemp -d "$work/headers.XXXXXX")"
  find "$headers" -mindepth 1 -maxdepth 1 -exec mv {} "$nested/" \;
  mv "$nested" "$headers/LibXray"
done
ditto "$framework" "$ios_dir/Frameworks/LibXray.xcframework"

# Upstream publishes an Apple build script, not an Apple binary release asset.
# This official release tarball includes the pinned third-party sources.
download "https://github.com/heiher/hev-socks5-tunnel/releases/download/$HEV_VERSION/hev-socks5-tunnel-$HEV_VERSION.tar.xz" \
  "$work/hev.tar.xz" "$HEV_SHA256"
tar -xJf "$work/hev.tar.xz" -C "$work/hev" --strip-components=1
cd "$work/hev"
build_slice() {
  local sdk="$1" arch="$2" minflag="$3"
  local output="$work/slices/$sdk-$arch"
  mkdir -p "$output"
  make PP="xcrun --sdk $sdk clang" CC="xcrun --sdk $sdk clang" \
    CFLAGS="-arch $arch $minflag" LFLAGS="-arch $arch $minflag" static
  xcrun libtool -static -o "$output/libhev-socks5-tunnel.a" \
    bin/libhev-socks5-tunnel.a third-part/lwip/bin/liblwip.a \
    third-part/yaml/bin/libyaml.a third-part/hev-task-system/bin/libhev-task-system.a
  make clean
}
build_slice iphoneos arm64 -miphoneos-version-min=15.0
build_slice iphonesimulator arm64 -mios-simulator-version-min=15.0
build_slice iphonesimulator x86_64 -mios-simulator-version-min=15.0
mkdir -p "$work/slices/simulator" "$work/headers/HevSocks5Tunnel"
xcrun lipo -create "$work/slices/iphonesimulator-arm64/libhev-socks5-tunnel.a" \
  "$work/slices/iphonesimulator-x86_64/libhev-socks5-tunnel.a" \
  -output "$work/slices/simulator/libhev-socks5-tunnel.a"
cp src/hev-main.h module.modulemap "$work/headers/HevSocks5Tunnel/"
xcodebuild -create-xcframework \
  -library "$work/slices/iphoneos-arm64/libhev-socks5-tunnel.a" -headers "$work/headers" \
  -library "$work/slices/simulator/libhev-socks5-tunnel.a" -headers "$work/headers" \
  -output "$work/HevSocks5Tunnel.xcframework"
ditto "$work/HevSocks5Tunnel.xcframework" "$ios_dir/Frameworks/HevSocks5Tunnel.xcframework"
