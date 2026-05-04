#!/usr/bin/env bash

set -euo pipefail

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: ${command_name} is required" >&2
    exit 1
  fi
}

require_command gh
require_command curl
require_command swift
require_command tar

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="$ROOT_DIR/scripts/build_cpython_xcframework.sh"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build/cpython}"
DEFAULT_BEEWARE_TAG="3.13-b13"
EFFECTIVE_BEEWARE_TAG="${BEEWARE_TAG:-$DEFAULT_BEEWARE_TAG}"
RELEASE_TAG="${RELEASE_TAG:-cpython-${EFFECTIVE_BEEWARE_TAG}}"
RELEASE_TITLE="${RELEASE_TITLE:-$RELEASE_TAG}"
GH_REPO="${GH_REPO:-${GITHUB_REPOSITORY:-}}"
ASSET_NAME="${ASSET_NAME:-CPython.xcframework.zip}"
CHECKSUM_ASSET_NAME="${CHECKSUM_ASSET_NAME:-CPython.xcframework.checksum.txt}"
METADATA_ASSET_NAME="${METADATA_ASSET_NAME:-CPython.artifact-metadata.json}"
NOTICES_ASSET_NAME="${NOTICES_ASSET_NAME:-CPython.third-party-notices.txt}"
DRY_RUN="${DRY_RUN:-0}"
OVERWRITE_ASSETS="${OVERWRITE_ASSETS:-1}"
SKIP_BUILD="${SKIP_BUILD:-0}"
UPLOAD_PACKAGE_ASSET="${UPLOAD_PACKAGE_ASSET:-1}"
PACKAGE_CHECKSUM="${PACKAGE_CHECKSUM:-}"
COMPLIANCE_ONLY="${COMPLIANCE_ONLY:-0}"
UPDATE_RELEASE_NOTES="${UPDATE_RELEASE_NOTES:-1}"
INCLUDES_CATALYST=1

if [[ "$COMPLIANCE_ONLY" == "1" ]]; then
  SKIP_BUILD=1
  UPLOAD_PACKAGE_ASSET=0
fi

if [[ -z "$GH_REPO" ]]; then
  echo "error: GH_REPO or GITHUB_REPOSITORY must be set" >&2
  exit 1
fi

if [[ ! -x "$BUILD_SCRIPT" ]]; then
  echo "error: build script is missing or not executable: ${BUILD_SCRIPT}" >&2
  exit 1
fi

mkdir -p "$BUILD_DIR"

ZIP_PATH="$BUILD_DIR/$ASSET_NAME"
CHECKSUM_PATH="$BUILD_DIR/$CHECKSUM_ASSET_NAME"
METADATA_PATH="$BUILD_DIR/$METADATA_ASSET_NAME"
NOTICES_PATH="$BUILD_DIR/$NOTICES_ASSET_NAME"
SOURCES_DIR="$BUILD_DIR/sources"
MAKEFILE_ASSET_NAME="Python-Apple-support-${EFFECTIVE_BEEWARE_TAG}.Makefile"
MAKEFILE_PATH="$BUILD_DIR/$MAKEFILE_ASSET_NAME"
COMPLIANCE_ASSETS=()

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
  ' "$MAKEFILE_PATH"
}

upstream_version() {
  local packaged_version="$1"
  printf '%s\n' "${packaged_version%-*}"
}

append_archive_members() {
  local title="$1"
  local archive_path="$2"
  local pattern="$3"
  local matched=0

  while IFS= read -r member; do
    [[ -n "$member" ]] || continue
    matched=1
    {
      printf '\n\n===== %s: %s =====\n\n' "$title" "$member"
      tar -xOf "$archive_path" "$member"
    } >>"$NOTICES_PATH"
  done < <((tar -tzf "$archive_path" | grep -E "$pattern") || true)

  if [[ "$matched" == "0" ]]; then
    {
      printf '\n\n===== %s =====\n\n' "$title"
      printf 'No matching notice file was found in %s using pattern %s.\n' "$(basename "$archive_path")" "$pattern"
    } >>"$NOTICES_PATH"
  fi
}

prepare_compliance_assets() {
  local beeware_makefile_url="https://raw.githubusercontent.com/beeware/Python-Apple-support/${EFFECTIVE_BEEWARE_TAG}/Makefile"
  download_file "$beeware_makefile_url" "$MAKEFILE_PATH"

  PYTHON_VERSION="$(parse_makefile_value "PYTHON_VERSION")"
  BZIP2_VERSION="$(parse_makefile_value "BZIP2_VERSION")"
  MPDECIMAL_VERSION="$(parse_makefile_value "MPDECIMAL_VERSION")"
  OPENSSL_VERSION="$(parse_makefile_value "OPENSSL_VERSION")"
  XZ_VERSION="$(parse_makefile_value "XZ_VERSION")"

  if [[ -z "$PYTHON_VERSION" || -z "$BZIP2_VERSION" || -z "$MPDECIMAL_VERSION" || -z "$OPENSSL_VERSION" || -z "$XZ_VERSION" ]]; then
    echo "error: failed to parse BeeWare build metadata for ${EFFECTIVE_BEEWARE_TAG}" >&2
    exit 1
  fi

  PYTHON_MICRO_VERSION="$(printf '%s' "$PYTHON_VERSION" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
  BZIP2_SOURCE_VERSION="$(upstream_version "$BZIP2_VERSION")"
  MPDECIMAL_SOURCE_VERSION="$(upstream_version "$MPDECIMAL_VERSION")"
  OPENSSL_SOURCE_VERSION="$(upstream_version "$OPENSSL_VERSION")"
  XZ_SOURCE_VERSION="$(upstream_version "$XZ_VERSION")"

  mkdir -p "$SOURCES_DIR"

  PYTHON_SOURCE_PATH="$SOURCES_DIR/Python-${PYTHON_VERSION}.tgz"
  BZIP2_SOURCE_PATH="$SOURCES_DIR/bzip2-${BZIP2_SOURCE_VERSION}.tar.gz"
  MPDECIMAL_SOURCE_PATH="$SOURCES_DIR/mpdecimal-${MPDECIMAL_SOURCE_VERSION}.tar.gz"
  OPENSSL_SOURCE_PATH="$SOURCES_DIR/openssl-${OPENSSL_SOURCE_VERSION}.tar.gz"
  XZ_SOURCE_PATH="$SOURCES_DIR/xz-${XZ_SOURCE_VERSION}.tar.gz"

  download_file "https://www.python.org/ftp/python/${PYTHON_MICRO_VERSION}/Python-${PYTHON_VERSION}.tgz" "$PYTHON_SOURCE_PATH"
  download_file "https://sourceware.org/pub/bzip2/bzip2-${BZIP2_SOURCE_VERSION}.tar.gz" "$BZIP2_SOURCE_PATH"
  download_file "https://www.bytereef.org/software/mpdecimal/releases/mpdecimal-${MPDECIMAL_SOURCE_VERSION}.tar.gz" "$MPDECIMAL_SOURCE_PATH"
  download_file "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_SOURCE_VERSION}/openssl-${OPENSSL_SOURCE_VERSION}.tar.gz" "$OPENSSL_SOURCE_PATH"
  download_file "https://github.com/tukaani-project/xz/releases/download/v${XZ_SOURCE_VERSION}/xz-${XZ_SOURCE_VERSION}.tar.gz" "$XZ_SOURCE_PATH"

  cat >"$NOTICES_PATH" <<EOF
CPython.xcframework third-party notices

Artifact: ${ASSET_NAME}
BeeWare Python-Apple-support metadata: ${EFFECTIVE_BEEWARE_TAG}
BeeWare metadata asset: ${MAKEFILE_ASSET_NAME}

This artifact embeds CPython and statically links selected native dependencies
into the iOS and Mac Catalyst framework slices. The release assets include the
CPython source archive and source archives for the non-system native
dependencies used by the build script.

Dependency versions from BeeWare metadata:
- CPython: ${PYTHON_VERSION}
- BZip2: ${BZIP2_VERSION}
- mpdecimal: ${MPDECIMAL_VERSION}
- OpenSSL: ${OPENSSL_VERSION}
- XZ/liblzma: ${XZ_VERSION}
EOF

  append_archive_members "CPython license" "$PYTHON_SOURCE_PATH" '(^|/)LICENSE$'
  append_archive_members "BZip2 license" "$BZIP2_SOURCE_PATH" '(^|/)LICENSE$'
  append_archive_members "mpdecimal license" "$MPDECIMAL_SOURCE_PATH" '(^|/)(LICENSE(\.txt)?|COPYRIGHT\.txt)$'
  append_archive_members "OpenSSL license and notice" "$OPENSSL_SOURCE_PATH" '(^|/)(LICENSE\.txt|NOTICE\.txt)$'
  append_archive_members "XZ license files" "$XZ_SOURCE_PATH" '(^|/)COPYING(\..*)?$'

  COMPLIANCE_ASSETS=(
    "$NOTICES_PATH"
    "$MAKEFILE_PATH"
    "$PYTHON_SOURCE_PATH"
    "$BZIP2_SOURCE_PATH"
    "$MPDECIMAL_SOURCE_PATH"
    "$OPENSSL_SOURCE_PATH"
    "$XZ_SOURCE_PATH"
  )
}

if [[ "$UPLOAD_PACKAGE_ASSET" == "1" ]]; then
  if [[ "$SKIP_BUILD" == "1" && -f "$ZIP_PATH" ]]; then
    echo "Using existing CPython artifact at ${ZIP_PATH}"
  else
    echo "Building CPython artifact from BeeWare tag ${EFFECTIVE_BEEWARE_TAG}"
    BEEWARE_TAG="$EFFECTIVE_BEEWARE_TAG" \
      BUILD_DIR="$BUILD_DIR" \
      "$BUILD_SCRIPT"
  fi

  if [[ ! -f "$ZIP_PATH" ]]; then
    echo "error: expected artifact not found: ${ZIP_PATH}" >&2
    exit 1
  fi

  CHECKSUM="$(swift package compute-checksum "$ZIP_PATH")"
elif [[ -f "$ZIP_PATH" && -z "$PACKAGE_CHECKSUM" ]]; then
  CHECKSUM="$(swift package compute-checksum "$ZIP_PATH")"
elif [[ -n "$PACKAGE_CHECKSUM" ]]; then
  CHECKSUM="$PACKAGE_CHECKSUM"
else
  echo "error: PACKAGE_CHECKSUM must be set when UPLOAD_PACKAGE_ASSET=0 and ${ZIP_PATH} is unavailable" >&2
  exit 1
fi

prepare_compliance_assets

printf '%s\n' "$CHECKSUM" > "$CHECKSUM_PATH"

cat >"$METADATA_PATH" <<EOF
{
  "asset_name": "${ASSET_NAME}",
  "beeware_tag": "${EFFECTIVE_BEEWARE_TAG}",
  "python_version": "${PYTHON_VERSION}",
  "checksum": "${CHECKSUM}",
  "includes_catalyst": ${INCLUDES_CATALYST},
  "self_contained": true,
  "release_tag": "${RELEASE_TAG}",
  "source_release_url": "https://github.com/beeware/Python-Apple-support/releases/tag/${EFFECTIVE_BEEWARE_TAG}",
  "notices_asset_name": "${NOTICES_ASSET_NAME}",
  "beeware_metadata_asset_name": "${MAKEFILE_ASSET_NAME}",
  "source_asset_names": [
    "$(basename "$PYTHON_SOURCE_PATH")",
    "$(basename "$BZIP2_SOURCE_PATH")",
    "$(basename "$MPDECIMAL_SOURCE_PATH")",
    "$(basename "$OPENSSL_SOURCE_PATH")",
    "$(basename "$XZ_SOURCE_PATH")"
  ],
  "dependency_versions": {
    "bzip2": "${BZIP2_VERSION}",
    "mpdecimal": "${MPDECIMAL_VERSION}",
    "openssl": "${OPENSSL_VERSION}",
    "xz": "${XZ_VERSION}"
  },
  "published_at_utc": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

PACKAGE_URL="https://github.com/${GH_REPO}/releases/download/${RELEASE_TAG}/${ASSET_NAME}"
RELEASE_NOTES="Self-contained CPython.xcframework artifact built from BeeWare Python-Apple-support metadata ${EFFECTIVE_BEEWARE_TAG}.

Compliance assets:
- ${NOTICES_ASSET_NAME}: CPython and native dependency license notices
- ${MAKEFILE_ASSET_NAME}: BeeWare build metadata used to resolve versions
- $(basename "$PYTHON_SOURCE_PATH"): CPython source archive
- $(basename "$BZIP2_SOURCE_PATH"), $(basename "$MPDECIMAL_SOURCE_PATH"), $(basename "$OPENSSL_SOURCE_PATH"), $(basename "$XZ_SOURCE_PATH"): native dependency source archives
- ${METADATA_ASSET_NAME}: build metadata and SwiftPM checksum"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "Dry run enabled; skipping GitHub release upload."
else
  if gh release view "$RELEASE_TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
    echo "Updating existing release ${GH_REPO}@${RELEASE_TAG}"
    if [[ "$UPDATE_RELEASE_NOTES" == "1" ]]; then
      gh release edit "$RELEASE_TAG" \
        --repo "$GH_REPO" \
        --notes "$RELEASE_NOTES"
    fi
  else
    echo "Creating release ${GH_REPO}@${RELEASE_TAG}"
    gh release create "$RELEASE_TAG" \
      --repo "$GH_REPO" \
      --title "$RELEASE_TITLE" \
      --notes "$RELEASE_NOTES"
  fi

  upload_args=(
    "$RELEASE_TAG"
    "$CHECKSUM_PATH"
    "$METADATA_PATH"
    "${COMPLIANCE_ASSETS[@]}"
    --repo "$GH_REPO"
  )

  if [[ "$UPLOAD_PACKAGE_ASSET" == "1" ]]; then
    upload_args=(
      "$RELEASE_TAG"
      "$ZIP_PATH"
      "$CHECKSUM_PATH"
      "$METADATA_PATH"
      "${COMPLIANCE_ASSETS[@]}"
      --repo "$GH_REPO"
    )
  fi

  if [[ "$OVERWRITE_ASSETS" == "1" ]]; then
    upload_args+=(--clobber)
  fi

  gh release upload "${upload_args[@]}"
fi

cat <<EOF

Published artifact summary:
  Repo:      ${GH_REPO}
  Release:   ${RELEASE_TAG}
  BeeWare:   ${EFFECTIVE_BEEWARE_TAG}
  Catalyst:  ${INCLUDES_CATALYST}
  Layout:    self-contained framework resources
  Artifact:  ${ZIP_PATH}
  Checksum:  ${CHECKSUM}
  Notices:   ${NOTICES_PATH}
  Sources:   ${SOURCES_DIR}

Package.swift snippet:
  .binaryTarget(
      name: "CPython",
      url: "${PACKAGE_URL}",
      checksum: "${CHECKSUM}"
  )
EOF

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat >>"$GITHUB_STEP_SUMMARY" <<EOF
## CPython Artifact

- Release: \`${RELEASE_TAG}\`
- BeeWare tag: \`${EFFECTIVE_BEEWARE_TAG}\`
- Includes Catalyst: \`${INCLUDES_CATALYST}\`
- Self-contained: \`true\`
- Artifact URL: \`${PACKAGE_URL}\`
- Checksum: \`${CHECKSUM}\`
- Notices asset: \`${NOTICES_ASSET_NAME}\`
- Source assets: \`$(basename "$PYTHON_SOURCE_PATH")\`, \`$(basename "$BZIP2_SOURCE_PATH")\`, \`$(basename "$MPDECIMAL_SOURCE_PATH")\`, \`$(basename "$OPENSSL_SOURCE_PATH")\`, \`$(basename "$XZ_SOURCE_PATH")\`
EOF
fi
