#!/usr/bin/env bash

set -euo pipefail

if ! command -v curl >/dev/null 2>&1; then
  echo "error: curl is required" >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild is required" >&2
  exit 1
fi

if ! command -v ditto >/dev/null 2>&1; then
  echo "error: ditto is required" >&2
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "error: swift is required" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build/cpython}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/.build-cpython-apple-support}"
BEEWARE_TAG="${BEEWARE_TAG:-3.13-b13}"
REQUIRE_CATALYST="${REQUIRE_CATALYST:-0}"
CATALYST_FRAMEWORK_PATH="${CPYTHON_CATALYST_FRAMEWORK_PATH:-}"

PYTHON_SERIES="${BEEWARE_TAG%%-*}"
BEEWARE_BUILD="${BEEWARE_TAG#*-}"

MACOS_ASSET="Python-${PYTHON_SERIES}-macOS-support.${BEEWARE_BUILD}.tar.gz"
IOS_ASSET="Python-${PYTHON_SERIES}-iOS-support.${BEEWARE_BUILD}.tar.gz"
BASE_URL="https://github.com/beeware/Python-Apple-support/releases/download/${BEEWARE_TAG}"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$BUILD_DIR"

download_asset() {
  local asset_name="$1"
  local target_path="$2"
  echo "Downloading ${asset_name}"
  curl -L --fail --output "$target_path" "${BASE_URL}/${asset_name}"
}

download_asset "$MACOS_ASSET" "$WORK_DIR/$MACOS_ASSET"
download_asset "$IOS_ASSET" "$WORK_DIR/$IOS_ASSET"

mkdir -p "$WORK_DIR/extracted/macos" "$WORK_DIR/extracted/ios"
tar -xzf "$WORK_DIR/$MACOS_ASSET" -C "$WORK_DIR/extracted/macos"
tar -xzf "$WORK_DIR/$IOS_ASSET" -C "$WORK_DIR/extracted/ios"

MACOS_XCFRAMEWORK="$WORK_DIR/extracted/macos/Python.xcframework"
IOS_XCFRAMEWORK="$WORK_DIR/extracted/ios/Python.xcframework"

if [[ ! -d "$MACOS_XCFRAMEWORK/macos-arm64_x86_64/Python.framework" ]]; then
  echo "error: missing macOS Python.framework in ${MACOS_XCFRAMEWORK}" >&2
  exit 1
fi

if [[ ! -d "$IOS_XCFRAMEWORK/ios-arm64/Python.framework" ]]; then
  echo "error: missing iOS device Python.framework in ${IOS_XCFRAMEWORK}" >&2
  exit 1
fi

if [[ ! -d "$IOS_XCFRAMEWORK/ios-arm64_x86_64-simulator/Python.framework" ]]; then
  echo "error: missing iOS simulator Python.framework in ${IOS_XCFRAMEWORK}" >&2
  exit 1
fi

FRAMEWORK_ARGS=(
  -framework "$MACOS_XCFRAMEWORK/macos-arm64_x86_64/Python.framework"
  -framework "$IOS_XCFRAMEWORK/ios-arm64/Python.framework"
  -framework "$IOS_XCFRAMEWORK/ios-arm64_x86_64-simulator/Python.framework"
)

if [[ -n "$CATALYST_FRAMEWORK_PATH" ]]; then
  if [[ ! -d "$CATALYST_FRAMEWORK_PATH" ]]; then
    echo "error: CPYTHON_CATALYST_FRAMEWORK_PATH does not exist: ${CATALYST_FRAMEWORK_PATH}" >&2
    exit 1
  fi
  FRAMEWORK_ARGS+=(-framework "$CATALYST_FRAMEWORK_PATH")
elif [[ "$REQUIRE_CATALYST" == "1" ]]; then
  echo "error: REQUIRE_CATALYST=1 but CPYTHON_CATALYST_FRAMEWORK_PATH is not set" >&2
  exit 1
fi

OUTPUT_XCFRAMEWORK="$BUILD_DIR/CPython.xcframework"
OUTPUT_ZIP="$BUILD_DIR/CPython.xcframework.zip"

rm -rf "$OUTPUT_XCFRAMEWORK" "$OUTPUT_ZIP"

echo "Creating ${OUTPUT_XCFRAMEWORK}"
xcodebuild -create-xcframework "${FRAMEWORK_ARGS[@]}" -output "$OUTPUT_XCFRAMEWORK"

echo "Packaging ${OUTPUT_ZIP}"
ditto -c -k --sequesterRsrc --keepParent "$OUTPUT_XCFRAMEWORK" "$OUTPUT_ZIP"

CHECKSUM="$(swift package compute-checksum "$OUTPUT_ZIP")"

cat <<EOF

Created:
  XCFramework: $OUTPUT_XCFRAMEWORK
  Zip:         $OUTPUT_ZIP
  Checksum:    $CHECKSUM

Notes:
  - The merged artifact contains Python.framework slices sourced from BeeWare's support packages.
  - To include Mac Catalyst, provide CPYTHON_CATALYST_FRAMEWORK_PATH=/abs/path/to/Python.framework
    and re-run this script.
  - Enabling iOS/Mac Catalyst runtime support in Bash.swift still requires follow-up packaging work.
EOF
