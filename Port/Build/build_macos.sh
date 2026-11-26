#!/bin/bash
# Run on macOS with Xcode 16.2 installed. Compiles only; never installs/restarts a device.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PORT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
VERIFY="$SCRIPT_DIR/verify.py"
SPEC="$PORT/project.yml"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || fail "requires macOS and Apple Xcode tools; Linux/iSH cannot build Apple arm64e ABI"
[[ "$(uname -m)" == arm64 || "$(uname -m)" == x86_64 ]] || fail "unsupported macOS host architecture"
[[ -x /usr/bin/python3 ]] || fail "python3 is required for fail-closed packaging/inspection"
[[ -f "$SPEC" && -f "$PORT/control" ]] || fail "missing Port/project.yml or Port/control"
[[ -d "$PORT/Sources" && -d "$PORT/Vendor" && -d "$PORT/Resources" ]] || fail "parent-owned Sources/, Vendor/, and Resources/ must exist"
[[ -f "$PORT/Sources/LetterpressSB-Bridging-Header.h" ]] || fail "missing Sources/LetterpressSB-Bridging-Header.h"
[[ -s "$PORT/Vendor/PrivateFrameworks/MediaRemote.tbd" ]] || fail "missing whitelisted MediaRemote.tbd"

DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
export DEVELOPER_DIR
xcodebuild_bin="$DEVELOPER_DIR/usr/bin/xcodebuild"
[[ -x "$xcodebuild_bin" ]] || fail "full Xcode required (Command Line Tools alone are insufficient)"
xcode_version="$(/usr/bin/xcodebuild -version)"
[[ "$xcode_version" == $'Xcode 16.2\n'* ]] || fail "Xcode 16.2 required; found ${xcode_version:-unknown}"
[[ "$(/usr/bin/xcrun --sdk iphoneos --show-sdk-version)" == 18.2 ]] || fail "selected Xcode does not provide expected iOS 18.2 SDK"
command -v xcodegen >/dev/null 2>&1 || fail "install XcodeGen 2.42.0 or add its pinned binary to PATH"
[[ "$(xcodegen --version)" == *'2.42.0' ]] || fail "XcodeGen 2.42.0 required; pin generator version"

# Caller may override with XcodeGen's installed binary, but only within this directory.
OUT="${LETTERPRESSSB_BUILD_DIR:-$SCRIPT_DIR/output}"
case "$(cd -- "$(dirname -- "$OUT")" 2>/dev/null && pwd -P)/$(basename -- "$OUT")" in
  "$SCRIPT_DIR"/*) ;;
  *) fail "LETTERPRESSSB_BUILD_DIR must remain under Port/Build" ;;
esac
mkdir -p "$OUT"
OUT="$(cd -- "$OUT" && pwd -P)"
[[ "$OUT/" == "$SCRIPT_DIR/"* ]] || fail "resolved build directory escaped Port/Build"
shopt -s nullglob dotglob
existing=("$OUT"/*)
shopt -u nullglob dotglob
((${#existing[@]} == 0)) || fail "build output must be empty to avoid stale artifacts"

# Reject the known bare-descriptor failure boundary before the full build.
# Passing this probe is NOT complete ABI validation or a device test.
python3 "$SCRIPT_DIR/preflight_apple.py" --output "$OUT/apple-preflight"

# Restrict generated projects, checkouts and intermediates to Port/Build.
export HOME="$SCRIPT_DIR/home"
mkdir -p "$HOME" "$OUT/derived" "$OUT/project-root"
ROOT="$OUT/project-root"
ln -s "$PORT/Sources" "$ROOT/Sources"
ln -s "$PORT/Vendor" "$ROOT/Vendor"
ln -s "$PORT/Preferences" "$ROOT/Preferences"
cp "$SPEC" "$ROOT/project.yml"
cd "$ROOT"
xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT"
PROJECT="$ROOT/LetterpressSB.xcodeproj"
[[ -d "$PROJECT" ]] || fail "XcodeGen did not generate project"
xcodebuild -resolvePackageDependencies \
  -project "$PROJECT" -scheme LetterpressSB \
  -clonedSourcePackagesDirPath "$OUT/SourcePackages" \
  -derivedDataPath "$OUT/derived"

# Adapt an isolated copy of the pinned Vortex package, not upstream renderer files.
python3 "$SCRIPT_DIR/prepare_apple_vortex.py" \
  --source-packages "$OUT/SourcePackages" \
  --local-package "$OUT/local-packages/Vortex" --project-spec "$ROOT/project.yml"
xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT"
xcodebuild -resolvePackageDependencies \
  -project "$PROJECT" -scheme LetterpressSB \
  -clonedSourcePackagesDirPath "$OUT/SourcePackages" \
  -derivedDataPath "$OUT/derived"

xcodebuild build \
  -project "$PROJECT" -scheme LetterpressSB \
  -configuration Release -sdk iphoneos \
  -derivedDataPath "$OUT/derived" \
  -clonedSourcePackagesDirPath "$OUT/SourcePackages" \
  ARCHS="arm64 arm64e" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  SKIP_INSTALL=YES

PRODUCTS="$OUT/derived/Build/Products/Release-iphoneos"
python3 "$SCRIPT_DIR/prepare_apple_vortex.py" --stage-only \
  --local-package "$OUT/local-packages/Vortex" --products "$PRODUCTS"
DYLIB="$PRODUCTS/LetterpressSB.dylib"
[[ -s "$DYLIB" ]] || fail "missing Xcode-built LetterpressSB.dylib"
/usr/bin/codesign --force --sign - --timestamp=none "$DYLIB"
/usr/bin/codesign --verify --strict --verbose=2 "$DYLIB"
/usr/bin/otool -hv "$DYLIB"
/usr/bin/lipo -info "$DYLIB"
/usr/bin/shasum -a 256 "$DYLIB"
PREFS="$PRODUCTS/LetterpressSBPrefs.bundle"
[[ -s "$PREFS/LetterpressSBPrefs" ]] || fail "missing compiled settings bundle"
/usr/bin/codesign --force --sign - --timestamp=none "$PREFS"
/usr/bin/codesign --verify --strict --verbose=2 "$PREFS"
python3 "$VERIFY" --macho "$DYLIB" --output "$OUT/macho-verification.json"
python3 "$SCRIPT_DIR/package.py" \
  --dylib "$DYLIB" --products "$PRODUCTS" \
  --resources "$PORT/Resources" --control "$PORT/control" --output-dir "$OUT/packages"

printf '\nDraft package and structural report:\n%s\n' "$OUT/packages"
