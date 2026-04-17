#!/usr/bin/env bash

set -euo pipefail

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: ${command_name} is required" >&2
    exit 1
  fi
}

require_command curl
require_command ditto
require_command lipo
require_command make
require_command rsync
require_command swift
require_command tar
require_command xcodebuild
require_command xcrun

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build/cpython}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/.build-cpython-selfcontained}"
BEEWARE_TAG="${BEEWARE_TAG:-3.13-b13}"
BUILD_JOBS="${BUILD_JOBS:-$(sysctl -n hw.ncpu)}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-16.0}"
CATALYST_DEPLOYMENT_TARGET="${CATALYST_DEPLOYMENT_TARGET:-13.1}"
MAKEFILE_CACHE_PATH="$WORK_DIR/Python-Apple-support-${BEEWARE_TAG}.Makefile"
TOOLCHAIN_BIN_DIR="$WORK_DIR/toolchain/bin"
HOST_ARCH="$(uname -m)"

PYTHON_FRAMEWORKS_DIR="$BUILD_DIR/frameworks"
OUTPUT_XCFRAMEWORK="$BUILD_DIR/CPython.xcframework"
OUTPUT_ZIP="$BUILD_DIR/CPython.xcframework.zip"

mkdir -p "$BUILD_DIR" "$WORK_DIR/downloads" "$TOOLCHAIN_BIN_DIR" "$PYTHON_FRAMEWORKS_DIR"

download_file() {
  local url="$1"
  local target_path="$2"

  if [[ -f "$target_path" ]]; then
    return
  fi

  mkdir -p "$(dirname "$target_path")"
  echo "Downloading $(basename "$target_path")"
  curl -L --fail --output "$target_path" "$url"
}

parse_makefile_value() {
  local variable_name="$1"
  awk -F= -v variable_name="$variable_name" '
    $1 == variable_name {
      value = substr($0, index($0, "=") + 1)
      gsub(/[[:space:]]+$/, "", value)
      print value
      exit
    }
  ' "$MAKEFILE_CACHE_PATH"
}

resolve_host_python() {
  local requested_series="$1"
  local candidate="${HOST_PYTHON:-}"
  local version=""

  if [[ -n "$candidate" ]]; then
    if [[ "$candidate" != */* ]]; then
      candidate="$(command -v "$candidate" || true)"
    fi
  elif command -v "python${requested_series}" >/dev/null 2>&1; then
    candidate="$(command -v "python${requested_series}")"
  elif command -v python3 >/dev/null 2>&1; then
    candidate="$(command -v python3)"
  else
    echo "error: python${requested_series} or python3 is required as the build python" >&2
    exit 1
  fi

  if [[ -z "$candidate" || ! -x "$candidate" ]]; then
    echo "error: HOST_PYTHON must resolve to an executable Python ${requested_series}.x binary" >&2
    exit 1
  fi

  version="$("$candidate" -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')"
  if [[ "$version" != "$requested_series" ]]; then
    echo "error: build python must be ${requested_series}.x, got ${version} from ${candidate}" >&2
    exit 1
  fi

  printf '%s\n' "$candidate"
}

download_dependency_archive() {
  local release_prefix="$1"
  local asset_prefix="$2"
  local version="$3"
  local asset_target="$4"
  local target_path="$5"
  local asset_name="${asset_prefix}-${version}-${asset_target}.tar.gz"
  local url="https://github.com/beeware/cpython-apple-source-deps/releases/download/${release_prefix}-${version}/${asset_name}"
  download_file "$url" "$target_path"
}

extract_dependency_archive() {
  local archive_path="$1"
  local install_root="$2"

  rm -rf "$install_root"
  mkdir -p "$install_root"
  tar -xzf "$archive_path" -C "$install_root" --exclude="*.dylib"
}

write_toolchain_wrappers() {
  local prefix="$1"
  local arch="$2"
  local target_triple="$3"
  local sdk="$4"

  cat >"$TOOLCHAIN_BIN_DIR/${prefix}-clang" <<EOF
#!/bin/sh
xcrun --sdk ${sdk} clang -target ${target_triple} "\$@"
EOF

  cat >"$TOOLCHAIN_BIN_DIR/${prefix}-clang++" <<EOF
#!/bin/sh
xcrun --sdk ${sdk} clang++ -target ${target_triple} "\$@"
EOF

  cat >"$TOOLCHAIN_BIN_DIR/${prefix}-cpp" <<EOF
#!/bin/sh
xcrun --sdk ${sdk} clang -target ${target_triple} -E "\$@"
EOF

  cat >"$TOOLCHAIN_BIN_DIR/${prefix}-ar" <<EOF
#!/bin/sh
xcrun --sdk ${sdk} ar "\$@"
EOF

  cat >"$TOOLCHAIN_BIN_DIR/${prefix}-strip" <<EOF
#!/bin/sh
xcrun --sdk ${sdk} strip -arch ${arch} "\$@"
EOF

  chmod 755 \
    "$TOOLCHAIN_BIN_DIR/${prefix}-clang" \
    "$TOOLCHAIN_BIN_DIR/${prefix}-clang++" \
    "$TOOLCHAIN_BIN_DIR/${prefix}-cpp" \
    "$TOOLCHAIN_BIN_DIR/${prefix}-ar" \
    "$TOOLCHAIN_BIN_DIR/${prefix}-strip"
}

write_static_setup_local() {
  local source_dir="$1"
  local setup_stdlib="$source_dir/Modules/Setup.stdlib"
  local setup_local="$source_dir/Modules/Setup.local"
  local module
  local modules=(
    array _asyncio _bisect _contextvars _csv _heapq _json _lsprof _opcode
    _pickle _queue _random _struct _zoneinfo math cmath _statistics _datetime
    _decimal binascii _bz2 _lzma zlib _md5 _sha1 _sha2 _sha3 _blake2 pyexpat
    _elementtree _codecs_cn _codecs_hk _codecs_iso2022 _codecs_jp _codecs_kr
    _codecs_tw _multibytecodec unicodedata fcntl mmap resource select _socket
    termios _sqlite3 _ssl _hashlib _uuid
  )

  if [[ ! -f "$setup_stdlib" ]]; then
    echo "error: missing generated ${setup_stdlib}" >&2
    exit 1
  fi

  printf '*static*\n\n' >"$setup_local"
  for module in "${modules[@]}"; do
    awk -v module="$module" '$1 == module { print; found = 1 } END { exit found ? 0 : 1 }' "$setup_stdlib" \
      >>"$setup_local" || true
  done
}

stage_framework_stdlib() {
  local framework_path="$1"
  local stdlib_source="$2"
  local resource_root="$framework_path/Resources/python"

  if [[ -d "$framework_path/Versions" ]]; then
    local version_dir
    version_dir="$(find "$framework_path/Versions" -mindepth 1 -maxdepth 1 -type d ! -name Current | sort | tail -1)"
    resource_root="$version_dir/Resources/python"
  fi

  rm -rf "$resource_root/lib"
  mkdir -p "$resource_root/lib"
  rsync -a --delete \
    --exclude "__pycache__" \
    --exclude "test" \
    --exclude "idlelib" \
    --exclude "tkinter" \
    --exclude "turtledemo" \
    --exclude "ensurepip" \
    --exclude "venv" \
    "$stdlib_source/" "$resource_root/lib/python${PYTHON_SERIES}/"

  rm -rf "$resource_root/lib/python${PYTHON_SERIES}/lib-dynload"
  find "$resource_root" \( -name "*.so" -o -name "*.dylib" -o -name "*.a" \) -delete
}

build_mobile_architecture_framework() {
  local name="$1"
  local arch="$2"
  local sdk="$3"
  local asset_target="$4"
  local compiler_target_triple="$5"
  local configure_host_triple="$6"
  local deployment_target="$7"
  local output_framework="$8"
  local arch_work_dir="$WORK_DIR/$name"
  local source_dir="$arch_work_dir/src/Python-${PYTHON_VERSION}"
  local install_dir="$arch_work_dir/install/python-${PYTHON_VERSION}"
  local dependency_root="$arch_work_dir/deps"
  local build_log_dir="$arch_work_dir/logs"
  local wrapper_prefix="${name}-${arch}"

  mkdir -p "$arch_work_dir/src" "$arch_work_dir/install" "$dependency_root" "$build_log_dir"

  write_toolchain_wrappers "$wrapper_prefix" "$arch" "$compiler_target_triple" "$sdk"

  download_dependency_archive "BZip2" "bzip2" "$BZIP2_VERSION" "$asset_target" "$WORK_DIR/downloads/bzip2-${BZIP2_VERSION}-${asset_target}.tar.gz"
  download_dependency_archive "mpdecimal" "mpdecimal" "$MPDECIMAL_VERSION" "$asset_target" "$WORK_DIR/downloads/mpdecimal-${MPDECIMAL_VERSION}-${asset_target}.tar.gz"
  download_dependency_archive "OpenSSL" "openssl" "$OPENSSL_VERSION" "$asset_target" "$WORK_DIR/downloads/openssl-${OPENSSL_VERSION}-${asset_target}.tar.gz"
  download_dependency_archive "XZ" "xz" "$XZ_VERSION" "$asset_target" "$WORK_DIR/downloads/xz-${XZ_VERSION}-${asset_target}.tar.gz"

  extract_dependency_archive "$WORK_DIR/downloads/bzip2-${BZIP2_VERSION}-${asset_target}.tar.gz" "$dependency_root/bzip2"
  extract_dependency_archive "$WORK_DIR/downloads/mpdecimal-${MPDECIMAL_VERSION}-${asset_target}.tar.gz" "$dependency_root/mpdecimal"
  extract_dependency_archive "$WORK_DIR/downloads/openssl-${OPENSSL_VERSION}-${asset_target}.tar.gz" "$dependency_root/openssl"
  extract_dependency_archive "$WORK_DIR/downloads/xz-${XZ_VERSION}-${asset_target}.tar.gz" "$dependency_root/xz"

  local framework_link_libs
  framework_link_libs="-ldl -lpthread -lz -lsqlite3"
  framework_link_libs+=" $dependency_root/mpdecimal/lib/libmpdec.a"
  framework_link_libs+=" $dependency_root/bzip2/lib/libbz2.a"
  framework_link_libs+=" $dependency_root/xz/lib/liblzma.a"
  framework_link_libs+=" $dependency_root/openssl/lib/libssl.a"
  framework_link_libs+=" $dependency_root/openssl/lib/libcrypto.a"
  framework_link_libs+=" $source_dir/Modules/expat/libexpat.a"
  framework_link_libs+=" $source_dir/Modules/_hacl/libHacl_Hash_SHA2.a"
  framework_link_libs+=" -lm"

  rm -rf "$source_dir" "$install_dir"
  mkdir -p "$source_dir" "$install_dir"
  tar -xzf "$PYTHON_SOURCE_ARCHIVE" --strip-components 1 -C "$source_dir"

  echo "Configuring CPython for ${name} (${arch})"
  (
    cd "$source_dir"
    PATH="$TOOLCHAIN_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin:/Library/Apple/usr/bin" \
      IPHONEOS_DEPLOYMENT_TARGET="$deployment_target" \
      LIBLZMA_CFLAGS="-I$dependency_root/xz/include" \
      LIBLZMA_LIBS="-L$dependency_root/xz/lib -llzma" \
      BZIP2_CFLAGS="-I$dependency_root/bzip2/include" \
      BZIP2_LIBS="-L$dependency_root/bzip2/lib -lbz2" \
      LIBMPDEC_CFLAGS="-I$dependency_root/mpdecimal/include" \
      LIBMPDEC_LIBS="-L$dependency_root/mpdecimal/lib -lmpdec" \
      CC="$TOOLCHAIN_BIN_DIR/${wrapper_prefix}-clang" \
      CPP="$TOOLCHAIN_BIN_DIR/${wrapper_prefix}-cpp" \
      CXX="$TOOLCHAIN_BIN_DIR/${wrapper_prefix}-clang++" \
      AR="$TOOLCHAIN_BIN_DIR/${wrapper_prefix}-ar" \
      STRIP="$TOOLCHAIN_BIN_DIR/${wrapper_prefix}-strip" \
      ./configure \
        --host="$configure_host_triple" \
        --build="${HOST_ARCH}-apple-darwin" \
        --with-build-python="$HOST_PYTHON_PATH" \
        --enable-ipv6 \
        --with-openssl="$dependency_root/openssl" \
        --enable-framework="$install_dir" \
        --with-system-libmpdec
  ) 2>&1 | tee "$build_log_dir/configure.log"

  write_static_setup_local "$source_dir"

  echo "Building CPython for ${name} (${arch})"
  (
    cd "$source_dir"
    PATH="$TOOLCHAIN_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin:/Library/Apple/usr/bin" \
      IPHONEOS_DEPLOYMENT_TARGET="$deployment_target" \
      make -j"$BUILD_JOBS" all LIBS="$framework_link_libs"
  ) 2>&1 | tee "$build_log_dir/build.log"

  echo "Installing CPython for ${name} (${arch})"
  (
    cd "$source_dir"
    PATH="$TOOLCHAIN_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin:/Library/Apple/usr/bin" \
      IPHONEOS_DEPLOYMENT_TARGET="$deployment_target" \
      make install LIBS="$framework_link_libs"
  ) 2>&1 | tee "$build_log_dir/install.log"

  if [[ ! -d "$install_dir/Python.framework" ]]; then
    echo "error: build did not produce Python.framework for ${name} ${arch}" >&2
    exit 1
  fi

  stage_framework_stdlib "$install_dir/Python.framework" "$install_dir/lib/python${PYTHON_SERIES}"

  rm -rf "$output_framework"
  mkdir -p "$(dirname "$output_framework")"
  cp -R "$install_dir/Python.framework" "$output_framework"
}

merge_frameworks() {
  local arm_framework="$1"
  local x86_framework="$2"
  local output_framework="$3"

  rm -rf "$output_framework"
  mkdir -p "$(dirname "$output_framework")"
  cp -R "$arm_framework" "$output_framework"

  lipo -create \
    -output "$output_framework/Python" \
    "$arm_framework/Python" \
    "$x86_framework/Python"

  if [[ -f "$output_framework/Headers/pyconfig.h" ]]; then
    mv "$output_framework/Headers/pyconfig.h" "$output_framework/Headers/pyconfig-arm64.h"
    cp "$x86_framework/Headers/pyconfig.h" "$output_framework/Headers/pyconfig-x86_64.h"
    cat >"$output_framework/Headers/pyconfig.h" <<'EOF'
#ifdef __arm64__
#include "pyconfig-arm64.h"
#endif

#ifdef __x86_64__
#include "pyconfig-x86_64.h"
#endif
EOF
  fi
}

download_file "https://raw.githubusercontent.com/beeware/Python-Apple-support/${BEEWARE_TAG}/Makefile" "$MAKEFILE_CACHE_PATH"

PYTHON_VERSION="$(parse_makefile_value "PYTHON_VERSION")"
BZIP2_VERSION="$(parse_makefile_value "BZIP2_VERSION")"
MPDECIMAL_VERSION="$(parse_makefile_value "MPDECIMAL_VERSION")"
OPENSSL_VERSION="$(parse_makefile_value "OPENSSL_VERSION")"
XZ_VERSION="$(parse_makefile_value "XZ_VERSION")"
PYTHON_SERIES="$(printf '%s' "$PYTHON_VERSION" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')"
PYTHON_MICRO_VERSION="$(printf '%s' "$PYTHON_VERSION" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
HOST_PYTHON_PATH="$(resolve_host_python "$PYTHON_SERIES")"
PYTHON_SOURCE_ARCHIVE="$WORK_DIR/downloads/Python-${PYTHON_VERSION}.tgz"

if [[ -z "$PYTHON_VERSION" || -z "$BZIP2_VERSION" || -z "$MPDECIMAL_VERSION" || -z "$OPENSSL_VERSION" || -z "$XZ_VERSION" ]]; then
  echo "error: failed to parse BeeWare build metadata for ${BEEWARE_TAG}" >&2
  exit 1
fi

download_file "https://www.python.org/ftp/python/${PYTHON_MICRO_VERSION}/Python-${PYTHON_VERSION}.tgz" "$PYTHON_SOURCE_ARCHIVE"

MACOS_ASSET="Python-${PYTHON_SERIES}-macOS-support.${BEEWARE_TAG#*-}.tar.gz"
MACOS_URL="https://github.com/beeware/Python-Apple-support/releases/download/${BEEWARE_TAG}/${MACOS_ASSET}"
MACOS_WORK_DIR="$WORK_DIR/macos"
download_file "$MACOS_URL" "$WORK_DIR/downloads/$MACOS_ASSET"
rm -rf "$MACOS_WORK_DIR"
mkdir -p "$MACOS_WORK_DIR"
tar -xzf "$WORK_DIR/downloads/$MACOS_ASSET" -C "$MACOS_WORK_DIR"

MACOS_FRAMEWORK="$MACOS_WORK_DIR/Python.xcframework/macos-arm64_x86_64/Python.framework"
if [[ ! -d "$MACOS_FRAMEWORK" ]]; then
  echo "error: missing macOS Python.framework in ${MACOS_WORK_DIR}/Python.xcframework" >&2
  exit 1
fi

mkdir -p "$PYTHON_FRAMEWORKS_DIR/macos-arm64_x86_64"
rm -rf "$PYTHON_FRAMEWORKS_DIR/macos-arm64_x86_64/Python.framework"
cp -R "$MACOS_FRAMEWORK" "$PYTHON_FRAMEWORKS_DIR/macos-arm64_x86_64/Python.framework"

build_mobile_architecture_framework \
  "ios-device" \
  "arm64" \
  "iphoneos" \
  "iphoneos.arm64" \
  "arm64-apple-ios${IOS_DEPLOYMENT_TARGET}" \
  "arm64-apple-ios${IOS_DEPLOYMENT_TARGET}" \
  "$IOS_DEPLOYMENT_TARGET" \
  "$PYTHON_FRAMEWORKS_DIR/ios-arm64/Python.framework"

build_mobile_architecture_framework \
  "ios-simulator-arm64" \
  "arm64" \
  "iphonesimulator" \
  "iphonesimulator.arm64" \
  "arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator" \
  "arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator" \
  "$IOS_DEPLOYMENT_TARGET" \
  "$WORK_DIR/ios-simulator-arm64/Python.framework"

build_mobile_architecture_framework \
  "ios-simulator-x86_64" \
  "x86_64" \
  "iphonesimulator" \
  "iphonesimulator.x86_64" \
  "x86_64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator" \
  "x86_64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator" \
  "$IOS_DEPLOYMENT_TARGET" \
  "$WORK_DIR/ios-simulator-x86_64/Python.framework"

merge_frameworks \
  "$WORK_DIR/ios-simulator-arm64/Python.framework" \
  "$WORK_DIR/ios-simulator-x86_64/Python.framework" \
  "$PYTHON_FRAMEWORKS_DIR/ios-arm64_x86_64-simulator/Python.framework"

build_mobile_architecture_framework \
  "catalyst-arm64" \
  "arm64" \
  "macosx" \
  "macabi.arm64" \
  "arm64-apple-ios${CATALYST_DEPLOYMENT_TARGET}-macabi" \
  "arm64-apple-ios${CATALYST_DEPLOYMENT_TARGET}-simulator" \
  "$CATALYST_DEPLOYMENT_TARGET" \
  "$WORK_DIR/catalyst-arm64/Python.framework"

build_mobile_architecture_framework \
  "catalyst-x86_64" \
  "x86_64" \
  "macosx" \
  "macabi.x86_64" \
  "x86_64-apple-ios${CATALYST_DEPLOYMENT_TARGET}-macabi" \
  "x86_64-apple-ios${CATALYST_DEPLOYMENT_TARGET}-simulator" \
  "$CATALYST_DEPLOYMENT_TARGET" \
  "$WORK_DIR/catalyst-x86_64/Python.framework"

merge_frameworks \
  "$WORK_DIR/catalyst-arm64/Python.framework" \
  "$WORK_DIR/catalyst-x86_64/Python.framework" \
  "$PYTHON_FRAMEWORKS_DIR/ios-arm64_x86_64-maccatalyst/Python.framework"

rm -rf "$OUTPUT_XCFRAMEWORK" "$OUTPUT_ZIP"

echo "Creating ${OUTPUT_XCFRAMEWORK}"
xcodebuild -create-xcframework \
  -framework "$PYTHON_FRAMEWORKS_DIR/macos-arm64_x86_64/Python.framework" \
  -framework "$PYTHON_FRAMEWORKS_DIR/ios-arm64/Python.framework" \
  -framework "$PYTHON_FRAMEWORKS_DIR/ios-arm64_x86_64-simulator/Python.framework" \
  -framework "$PYTHON_FRAMEWORKS_DIR/ios-arm64_x86_64-maccatalyst/Python.framework" \
  -output "$OUTPUT_XCFRAMEWORK"

echo "Packaging ${OUTPUT_ZIP}"
ditto -c -k --sequesterRsrc --keepParent "$OUTPUT_XCFRAMEWORK" "$OUTPUT_ZIP"

CHECKSUM="$(swift package compute-checksum "$OUTPUT_ZIP")"

cat <<EOF

Created self-contained CPython artifact:
  XCFramework: $OUTPUT_XCFRAMEWORK
  Zip:         $OUTPUT_ZIP
  Checksum:    $CHECKSUM
  Python:      $PYTHON_VERSION
  BeeWare:     $BEEWARE_TAG

Notes:
  - iOS and Mac Catalyst slices statically link selected native stdlib modules.
  - Pure-Python stdlib resources are embedded inside Python.framework resources.
  - Publish this zip and update Package.swift with the printed checksum.
EOF
