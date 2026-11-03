#!/usr/bin/env bash
# Single source of truth for unsigned Pomme device builds on macOS CI.
# Called by GitHub Actions and Codemagic. Does not install or sign an app.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/target/ios-build"
APP="$OUT/Build/Products/Release-iphoneos/Pomme.app"
IPA="$OUT/Pomme-unsigned.ipa"
mkdir -p "$OUT"
export PATH="$HOME/.cargo/bin:$PATH"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}"

die() { echo "::error::$*" >&2; exit 1; }
for tool in cargo rustup python3 cmake xcodegen xcodebuild xcrun ditto lipo plutil unzip; do
    command -v "$tool" >/dev/null 2>&1 || die "Missing build tool: $tool"
done
[[ -f pomme-ios/project.yml && -f pomme-ios/build-app.sh ]] || die "Pomme iOS sources missing"
[[ -f Cargo.lock && -f rust-toolchain.toml ]] || die "Pinned Cargo inputs missing"
rustup target list --installed | grep -qx 'aarch64-apple-ios' || die 'Missing Rust iOS ARM64 target'

echo '=== Toolchain and project ==='
xcodebuild -version
rustc --version
cargo --version
xcrun --sdk iphoneos --show-sdk-version
(cd pomme-ios && xcodegen generate)
[[ -d pomme-ios/Pomme.xcodeproj ]] || die 'XcodeGen did not produce Pomme.xcodeproj'

echo '=== Pinned MoltenVK ==='
VULKAN_SDK="$(python3 tools/fetch_moltenvk.py ios)"
export VULKAN_SDK
export SHADERC_LIB_DIR="$VULKAN_SDK/lib"
[[ -s "$VULKAN_SDK/lib/libvulkan.a" ]] || die 'Missing static iOS MoltenVK libvulkan.a'
[[ ! -e "$SHADERC_LIB_DIR/libshaderc_combined.a" ]] || die 'Unexpected shaderc archive in iOS-only MoltenVK SDK'
echo "MoltenVK archive: $VULKAN_SDK/lib/libvulkan.a"
echo "Shaderc explicit search directory: $SHADERC_LIB_DIR"
# This explicit directory prevents shaderc-sys v0.10.1 from requiring
# $VULKAN_SDK/share/vulkan/registry/vk.xml (absent from MoltenVK staging).
# Shaderc is a HOST build dependency; its C++ library must be host-native.

echo '=== Compile native Rust ARM64 client ==='
cargo build --locked --release -p pomme-ios --target aarch64-apple-ios \
    2>&1 | tee "$OUT/rust-preflight.log"
[[ -s target/aarch64-apple-ios/release/pomme-ios ]] || die 'Missing Rust client after successful cargo build'

echo '=== Build Xcode app without code signing ==='
xcodebuild \
    -project pomme-ios/Pomme.xcodeproj \
    -scheme Pomme -configuration Release \
    -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$OUT" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
    build 2>&1 | tee "$OUT/xcodebuild.log"

echo '=== Validate iOS app bundle ==='
[[ -s "$APP/Pomme" ]] || die 'App executable missing'
[[ -s "$APP/Info.plist" ]] || die 'Info.plist missing'
[[ -s "$APP/Frameworks/soft_oal.framework/soft_oal" ]] || die 'OpenAL Soft framework executable missing'
plutil -lint "$APP/Info.plist"
get_plist() { plutil -extract "$1" raw -o - "$APP/Info.plist"; }
[[ "$(get_plist CFBundleIdentifier)" == 'com.pommemc.client' ]] || die 'Unexpected app bundle identifier'
[[ "$(get_plist CFBundleExecutable)" == 'Pomme' ]] || die 'Unexpected app executable metadata'
[[ " $(lipo -archs "$APP/Pomme") " == *' arm64 '* ]] || die 'App binary is not ARM64'
[[ " $(lipo -archs "$APP/Frameworks/soft_oal.framework/soft_oal") " == *' arm64 '* ]] || die 'OpenAL framework is not ARM64'
file "$APP/Pomme" "$APP/Frameworks/soft_oal.framework/soft_oal"
/usr/bin/otool -L "$APP/Pomme" | tee "$OUT/native-dependencies.log"

echo '=== Package and test unsigned IPA ==='
STAGING="$OUT/ipa-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING/Payload"
ditto "$APP" "$STAGING/Payload/Pomme.app"
(cd "$STAGING" && ditto -c -k --sequesterRsrc --keepParent Payload "$IPA")
unzip -tq "$IPA" | tee "$OUT/ipa-zip-check.log"
unzip -Z1 "$IPA" > "$OUT/ipa-members.txt"
grep -Fxq 'Payload/Pomme.app/Pomme' "$OUT/ipa-members.txt" || die 'IPA missing main executable'
grep -q '^Payload/Pomme.app/Frameworks/soft_oal.framework/' "$OUT/ipa-members.txt" || die 'IPA missing OpenAL framework'
shasum -a 256 "$IPA" | tee "$OUT/Pomme-unsigned.ipa.sha256"
ls -lh "$IPA"
echo 'PASS: Unsigned IPA has the expected ARM64 executable, OpenAL framework and bundle metadata.'
