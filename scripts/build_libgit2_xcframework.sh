#!/usr/bin/env bash

set -euo pipefail

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: ${command_name} is required" >&2
    exit 1
  fi
}

require_command cmake
require_command curl
require_command ditto
require_command make
require_command swift
require_command tar
require_command xcodebuild
require_command xcrun

default_build_jobs() {
  sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build/libgit2}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/.build-libgit2}"
LIBGIT2_TAG="${LIBGIT2_TAG:-v1.9.2}"
LIBGIT2_ARTIFACT_REVISION="${LIBGIT2_ARTIFACT_REVISION:-r2}"
LIBGIT2_RELEASE_TAG="${LIBGIT2_RELEASE_TAG:-libgit2-${LIBGIT2_TAG#v}-${LIBGIT2_ARTIFACT_REVISION}}"
BUILD_JOBS="${BUILD_JOBS:-$(default_build_jobs)}"
MACOS_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET:-13.0}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-16.0}"
CATALYST_DEPLOYMENT_TARGET="${CATALYST_DEPLOYMENT_TARGET:-16.0}"

DOWNLOAD_PATH="$WORK_DIR/downloads/libgit2-${LIBGIT2_TAG}.tar.gz"
SOURCE_DIR="$WORK_DIR/source"
SLICE_DIR="$WORK_DIR/slices"
HEADERS_DIR="$BUILD_DIR/Headers"
OUTPUT_XCFRAMEWORK="$BUILD_DIR/Clibgit2.xcframework"
OUTPUT_ZIP="$BUILD_DIR/Clibgit2.xcframework.zip"
SOURCE_URL="https://github.com/libgit2/libgit2/archive/refs/tags/${LIBGIT2_TAG}.tar.gz"

mkdir -p "$BUILD_DIR" "$WORK_DIR/downloads" "$SLICE_DIR"

download_source() {
  if [[ -f "$DOWNLOAD_PATH" ]]; then
    return
  fi

  echo "Downloading libgit2 ${LIBGIT2_TAG}"
  curl -L --fail --output "$DOWNLOAD_PATH" "$SOURCE_URL"
}

extract_source() {
  rm -rf "$SOURCE_DIR"
  mkdir -p "$SOURCE_DIR"
  tar -xzf "$DOWNLOAD_PATH" -C "$SOURCE_DIR" --strip-components 1
}

build_arch() {
  local slice_name="$1"
  local sdk="$2"
  local system_name="$3"
  local arch="$4"
  local target_triple="$5"
  local deployment_target="$6"
  local build_path="$WORK_DIR/build/${slice_name}-${arch}"
  local output_dir="$SLICE_DIR/$slice_name/$arch"
  local sdk_path
  local clang_path

  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  clang_path="$(xcrun --sdk "$sdk" --find clang)"

  rm -rf "$build_path" "$output_dir"
  mkdir -p "$build_path" "$output_dir"

  echo "Building libgit2 ${LIBGIT2_TAG} for ${slice_name} ${arch}"
  cmake -S "$SOURCE_DIR" -B "$build_path" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME="$system_name" \
    -DCMAKE_OSX_SYSROOT="$sdk_path" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target" \
    -DCMAKE_C_COMPILER="$clang_path" \
    -DCMAKE_C_COMPILER_TARGET="$target_triple" \
    -DCMAKE_C_FLAGS="-target ${target_triple}" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTS=OFF \
    -DBUILD_CLI=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_FUZZERS=OFF \
    -DENABLE_REPRODUCIBLE_BUILDS=OFF \
    -DUSE_HTTPS=SecureTransport \
    -DUSE_SHA1=CollisionDetection \
    -DUSE_SHA256=CommonCrypto \
    -DUSE_HTTP_PARSER=builtin \
    -DREGEX_BACKEND=builtin \
    -DUSE_BUNDLED_ZLIB=ON \
    -DUSE_SSH=OFF \
    -DUSE_NTLMCLIENT=ON \
    -DUSE_GSSAPI=OFF \
    -DUSE_THREADS=ON \
    -DUSE_ICONV=ON

  cmake --build "$build_path" --target libgit2package --parallel "$BUILD_JOBS"

  if [[ ! -f "$build_path/libgit2.a" ]]; then
    echo "error: expected libgit2 archive not found: ${build_path}/libgit2.a" >&2
    exit 1
  fi

  cp "$build_path/libgit2.a" "$output_dir/libgit2.a"
}

combine_slice() {
  local slice_name="$1"
  shift

  local output_dir="$SLICE_DIR/$slice_name"
  local output_library="$output_dir/libgit2.a"
  local libraries=()
  local arch

  for arch in "$@"; do
    libraries+=("$output_dir/$arch/libgit2.a")
  done

  if [[ "${#libraries[@]}" -eq 1 ]]; then
    cp "${libraries[0]}" "$output_library"
  else
    xcrun lipo -create "${libraries[@]}" -output "$output_library"
  fi

  xcrun lipo -info "$output_library"
}

prepare_headers() {
  rm -rf "$HEADERS_DIR"
  mkdir -p "$HEADERS_DIR"

  cp "$SOURCE_DIR/include/git2.h" "$HEADERS_DIR/git2.h"
  cp -R "$SOURCE_DIR/include/git2" "$HEADERS_DIR/git2"

  cat >"$HEADERS_DIR/module.modulemap" <<'EOF'
module Clibgit2 [system] {
  umbrella header "git2.h"
  export *

  link "iconv"
  link framework "CoreFoundation"
  link framework "Security"
}
EOF
}

create_xcframework() {
  rm -rf "$OUTPUT_XCFRAMEWORK" "$OUTPUT_ZIP"

  echo "Creating ${OUTPUT_XCFRAMEWORK}"
  xcodebuild -create-xcframework \
    -library "$SLICE_DIR/macos/libgit2.a" -headers "$HEADERS_DIR" \
    -library "$SLICE_DIR/ios/libgit2.a" -headers "$HEADERS_DIR" \
    -library "$SLICE_DIR/ios-simulator/libgit2.a" -headers "$HEADERS_DIR" \
    -library "$SLICE_DIR/maccatalyst/libgit2.a" -headers "$HEADERS_DIR" \
    -output "$OUTPUT_XCFRAMEWORK"

  echo "Packaging ${OUTPUT_ZIP}"
  ditto -c -k --sequesterRsrc --keepParent "$OUTPUT_XCFRAMEWORK" "$OUTPUT_ZIP"
}

download_source
extract_source

build_arch macos macosx Darwin arm64 "arm64-apple-macos${MACOS_DEPLOYMENT_TARGET}" "$MACOS_DEPLOYMENT_TARGET"
build_arch macos macosx Darwin x86_64 "x86_64-apple-macos${MACOS_DEPLOYMENT_TARGET}" "$MACOS_DEPLOYMENT_TARGET"
combine_slice macos arm64 x86_64

build_arch ios iphoneos iOS arm64 "arm64-apple-ios${IOS_DEPLOYMENT_TARGET}" "$IOS_DEPLOYMENT_TARGET"
combine_slice ios arm64

build_arch ios-simulator iphonesimulator iOS arm64 "arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator" "$IOS_DEPLOYMENT_TARGET"
build_arch ios-simulator iphonesimulator iOS x86_64 "x86_64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator" "$IOS_DEPLOYMENT_TARGET"
combine_slice ios-simulator arm64 x86_64

build_arch maccatalyst macosx Darwin arm64 "arm64-apple-ios${CATALYST_DEPLOYMENT_TARGET}-macabi" "$CATALYST_DEPLOYMENT_TARGET"
build_arch maccatalyst macosx Darwin x86_64 "x86_64-apple-ios${CATALYST_DEPLOYMENT_TARGET}-macabi" "$CATALYST_DEPLOYMENT_TARGET"
combine_slice maccatalyst arm64 x86_64

prepare_headers
create_xcframework

CHECKSUM="$(swift package compute-checksum "$OUTPUT_ZIP")"

cat <<EOF

Created libgit2 artifact:
  Source:      ${SOURCE_URL}
  XCFramework: ${OUTPUT_XCFRAMEWORK}
  Zip:         ${OUTPUT_ZIP}
  Checksum:    ${CHECKSUM}

Package.swift snippet:
  .binaryTarget(
      name: "Clibgit2",
      url: "https://github.com/velos/Bash.swift/releases/download/${LIBGIT2_RELEASE_TAG}/Clibgit2.xcframework.zip",
      checksum: "${CHECKSUM}"
  )
EOF
