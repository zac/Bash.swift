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
require_command lipo
require_command make
require_command tar
require_command xcrun

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/.build-cpython-catalyst}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build/cpython/catalyst}"
BEEWARE_TAG="${BEEWARE_TAG:-3.13-b13}"
CATALYST_DEPLOYMENT_TARGET="${CATALYST_DEPLOYMENT_TARGET:-13.1}"
BUILD_JOBS="${BUILD_JOBS:-$(sysctl -n hw.ncpu)}"
OUTPUT_FRAMEWORK_PATH="${CPYTHON_CATALYST_OUTPUT_PATH:-$BUILD_DIR/Python.framework}"
MAKEFILE_CACHE_PATH="$WORK_DIR/Python-Apple-support-${BEEWARE_TAG}.Makefile"
TOOLCHAIN_BIN_DIR="$WORK_DIR/toolchain/bin"
HOST_ARCH="$(uname -m)"

mkdir -p "$WORK_DIR" "$BUILD_DIR" "$WORK_DIR/downloads" "$TOOLCHAIN_BIN_DIR"

resolve_host_python() {
  local requested_series="$1"
  local candidate="${HOST_PYTHON:-}"
  local version=""

  if [[ -n "$candidate" ]]; then
    :
  elif command -v "python${requested_series}" >/dev/null 2>&1; then
    candidate="$(command -v "python${requested_series}")"
  elif command -v python3 >/dev/null 2>&1; then
    candidate="$(command -v python3)"
  else
    echo "error: python${requested_series} or python3 is required as the build python" >&2
    exit 1
  fi

  version="$("$candidate" -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')"
  if [[ "$version" != "$requested_series" ]]; then
    echo "error: build python must be ${requested_series}.x, got ${version} from ${candidate}" >&2
    exit 1
  fi

  printf '%s\n' "$candidate"
}

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

write_toolchain_wrappers() {
  local arch="$1"
  local target_triple="$2"
  cat >"$TOOLCHAIN_BIN_DIR/${arch}-apple-ios-macabi-clang" <<EOF
#!/bin/sh
xcrun --sdk macosx clang -target ${target_triple} "\$@"
EOF

  cat >"$TOOLCHAIN_BIN_DIR/${arch}-apple-ios-macabi-clang++" <<EOF
#!/bin/sh
xcrun --sdk macosx clang++ -target ${target_triple} "\$@"
EOF

  cat >"$TOOLCHAIN_BIN_DIR/${arch}-apple-ios-macabi-cpp" <<EOF
#!/bin/sh
xcrun --sdk macosx clang -target ${target_triple} -E "\$@"
EOF

  cat >"$TOOLCHAIN_BIN_DIR/${arch}-apple-ios-macabi-ar" <<'EOF'
#!/bin/sh
xcrun --sdk macosx ar "$@"
EOF

  cat >"$TOOLCHAIN_BIN_DIR/${arch}-apple-ios-macabi-strip" <<EOF
#!/bin/sh
xcrun --sdk macosx strip -arch ${arch} "\$@"
EOF

  chmod 755 \
    "$TOOLCHAIN_BIN_DIR/${arch}-apple-ios-macabi-clang" \
    "$TOOLCHAIN_BIN_DIR/${arch}-apple-ios-macabi-clang++" \
    "$TOOLCHAIN_BIN_DIR/${arch}-apple-ios-macabi-cpp" \
    "$TOOLCHAIN_BIN_DIR/${arch}-apple-ios-macabi-ar" \
    "$TOOLCHAIN_BIN_DIR/${arch}-apple-ios-macabi-strip"
}

download_dependency_archive() {
  local release_prefix="$1"
  local asset_prefix="$2"
  local version="$3"
  local arch="$4"
  local target_path="$5"
  local asset_name="${asset_prefix}-${version}-macabi.${arch}.tar.gz"
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

build_architecture_framework() {
  local arch="$1"
  local compiler_target_triple="${arch}-apple-ios${CATALYST_DEPLOYMENT_TARGET}-macabi"
  # CPython 3.13's config.sub does not recognize macabi, so configure needs a
  # nearby iOS triple while the actual compiler target remains Mac Catalyst.
  local configure_host_triple="${arch}-apple-ios${CATALYST_DEPLOYMENT_TARGET}-simulator"
  local arch_work_dir="$WORK_DIR/${arch}"
  local source_dir="$arch_work_dir/src/Python-${PYTHON_VERSION}"
  local install_dir="$arch_work_dir/install/python-${PYTHON_VERSION}"
  local dependency_root="$arch_work_dir/deps"
  local build_log_dir="$arch_work_dir/logs"

  mkdir -p "$arch_work_dir/src" "$arch_work_dir/install" "$dependency_root" "$build_log_dir"

  write_toolchain_wrappers "$arch" "$compiler_target_triple"

  download_dependency_archive "BZip2" "bzip2" "$BZIP2_VERSION" "$arch" "$WORK_DIR/downloads/bzip2-${BZIP2_VERSION}-macabi.${arch}.tar.gz"
  download_dependency_archive "libFFI" "libffi" "$LIBFFI_VERSION" "$arch" "$WORK_DIR/downloads/libffi-${LIBFFI_VERSION}-macabi.${arch}.tar.gz"
  download_dependency_archive "mpdecimal" "mpdecimal" "$MPDECIMAL_VERSION" "$arch" "$WORK_DIR/downloads/mpdecimal-${MPDECIMAL_VERSION}-macabi.${arch}.tar.gz"
  download_dependency_archive "OpenSSL" "openssl" "$OPENSSL_VERSION" "$arch" "$WORK_DIR/downloads/openssl-${OPENSSL_VERSION}-macabi.${arch}.tar.gz"
  download_dependency_archive "XZ" "xz" "$XZ_VERSION" "$arch" "$WORK_DIR/downloads/xz-${XZ_VERSION}-macabi.${arch}.tar.gz"

  extract_dependency_archive "$WORK_DIR/downloads/bzip2-${BZIP2_VERSION}-macabi.${arch}.tar.gz" "$dependency_root/bzip2"
  extract_dependency_archive "$WORK_DIR/downloads/libffi-${LIBFFI_VERSION}-macabi.${arch}.tar.gz" "$dependency_root/libffi"
  extract_dependency_archive "$WORK_DIR/downloads/mpdecimal-${MPDECIMAL_VERSION}-macabi.${arch}.tar.gz" "$dependency_root/mpdecimal"
  extract_dependency_archive "$WORK_DIR/downloads/openssl-${OPENSSL_VERSION}-macabi.${arch}.tar.gz" "$dependency_root/openssl"
  extract_dependency_archive "$WORK_DIR/downloads/xz-${XZ_VERSION}-macabi.${arch}.tar.gz" "$dependency_root/xz"

  rm -rf "$source_dir" "$install_dir"
  mkdir -p "$source_dir" "$install_dir"
  tar -xzf "$PYTHON_SOURCE_ARCHIVE" --strip-components 1 -C "$source_dir"

  echo "Configuring CPython for Mac Catalyst (${arch})"
  (
    cd "$source_dir"
    PATH="$TOOLCHAIN_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin:/Library/Apple/usr/bin" \
      IPHONEOS_DEPLOYMENT_TARGET="$CATALYST_DEPLOYMENT_TARGET" \
      LIBLZMA_CFLAGS="-I$dependency_root/xz/include" \
      LIBLZMA_LIBS="-L$dependency_root/xz/lib -llzma" \
      BZIP2_CFLAGS="-I$dependency_root/bzip2/include" \
      BZIP2_LIBS="-L$dependency_root/bzip2/lib -lbz2" \
      LIBMPDEC_CFLAGS="-I$dependency_root/mpdecimal/include" \
      LIBMPDEC_LIBS="-L$dependency_root/mpdecimal/lib -lmpdec" \
      LIBFFI_CFLAGS="-I$dependency_root/libffi/include" \
      LIBFFI_LIBS="-L$dependency_root/libffi/lib -lffi" \
      CC="$TOOLCHAIN_BIN_DIR/${arch}-apple-ios-macabi-clang" \
      CPP="$TOOLCHAIN_BIN_DIR/${arch}-apple-ios-macabi-cpp" \
      CXX="$TOOLCHAIN_BIN_DIR/${arch}-apple-ios-macabi-clang++" \
      AR="$TOOLCHAIN_BIN_DIR/${arch}-apple-ios-macabi-ar" \
      STRIP="$TOOLCHAIN_BIN_DIR/${arch}-apple-ios-macabi-strip" \
      ./configure \
        --host="$configure_host_triple" \
        --build="${HOST_ARCH}-apple-darwin" \
        --with-build-python="$HOST_PYTHON_PATH" \
        --enable-ipv6 \
        --with-openssl="$dependency_root/openssl" \
        --enable-framework="$install_dir" \
        --with-system-libmpdec
  ) 2>&1 | tee "$build_log_dir/configure.log"

  echo "Building CPython for Mac Catalyst (${arch})"
  (
    cd "$source_dir"
    PATH="$TOOLCHAIN_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin:/Library/Apple/usr/bin" \
      IPHONEOS_DEPLOYMENT_TARGET="$CATALYST_DEPLOYMENT_TARGET" \
      make -j"$BUILD_JOBS" all
  ) 2>&1 | tee "$build_log_dir/build.log"

  echo "Installing CPython for Mac Catalyst (${arch})"
  (
    cd "$source_dir"
    PATH="$TOOLCHAIN_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin:/Library/Apple/usr/bin" \
      IPHONEOS_DEPLOYMENT_TARGET="$CATALYST_DEPLOYMENT_TARGET" \
      make install
  ) 2>&1 | tee "$build_log_dir/install.log"

  if [[ ! -d "$install_dir/Python.framework" ]]; then
    echo "error: Mac Catalyst build did not produce Python.framework for ${arch}" >&2
    exit 1
  fi
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
}

download_file "https://raw.githubusercontent.com/beeware/Python-Apple-support/${BEEWARE_TAG}/Makefile" "$MAKEFILE_CACHE_PATH"

PYTHON_VERSION="$(parse_makefile_value "PYTHON_VERSION")"
BZIP2_VERSION="$(parse_makefile_value "BZIP2_VERSION")"
LIBFFI_VERSION="$(parse_makefile_value "LIBFFI_VERSION")"
MPDECIMAL_VERSION="$(parse_makefile_value "MPDECIMAL_VERSION")"
OPENSSL_VERSION="$(parse_makefile_value "OPENSSL_VERSION")"
XZ_VERSION="$(parse_makefile_value "XZ_VERSION")"
PYTHON_SERIES="$(printf '%s' "$PYTHON_VERSION" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')"
PYTHON_MICRO_VERSION="$(printf '%s' "$PYTHON_VERSION" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
HOST_PYTHON_PATH="$(resolve_host_python "$PYTHON_SERIES")"
PYTHON_SOURCE_ARCHIVE="$WORK_DIR/downloads/Python-${PYTHON_VERSION}.tgz"

if [[ -z "$PYTHON_VERSION" || -z "$BZIP2_VERSION" || -z "$LIBFFI_VERSION" || -z "$MPDECIMAL_VERSION" || -z "$OPENSSL_VERSION" || -z "$XZ_VERSION" ]]; then
  echo "error: failed to parse BeeWare build metadata for ${BEEWARE_TAG}" >&2
  exit 1
fi

download_file "https://www.python.org/ftp/python/${PYTHON_MICRO_VERSION}/Python-${PYTHON_VERSION}.tgz" "$PYTHON_SOURCE_ARCHIVE"

build_architecture_framework "arm64"
build_architecture_framework "x86_64"

merge_frameworks \
  "$WORK_DIR/arm64/install/python-${PYTHON_VERSION}/Python.framework" \
  "$WORK_DIR/x86_64/install/python-${PYTHON_VERSION}/Python.framework" \
  "$OUTPUT_FRAMEWORK_PATH"

cat <<EOF

Created Mac Catalyst framework:
  Framework:  $OUTPUT_FRAMEWORK_PATH
  BeeWare:    $BEEWARE_TAG
  Python:     $PYTHON_VERSION
  Host Python:$HOST_PYTHON_PATH
  Target:     arm64/x86_64-apple-ios${CATALYST_DEPLOYMENT_TARGET}-macabi

Notes:
  - This builds only the Mac Catalyst Python.framework slice used by the
    CPython XCFramework publisher.
  - App-bundle stdlib/resource packaging for Catalyst is still follow-up work.
EOF
