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
BUILD_SCRIPT="$ROOT_DIR/scripts/build_libgit2_xcframework.sh"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build/libgit2}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/.build-libgit2}"
DEFAULT_LIBGIT2_TAG="v1.9.2"
EFFECTIVE_LIBGIT2_TAG="${LIBGIT2_TAG:-$DEFAULT_LIBGIT2_TAG}"
EFFECTIVE_LIBGIT2_VERSION="${EFFECTIVE_LIBGIT2_TAG#v}"
ARTIFACT_REVISION="${ARTIFACT_REVISION:-r2}"
RELEASE_TAG="${RELEASE_TAG:-libgit2-${EFFECTIVE_LIBGIT2_VERSION}-${ARTIFACT_REVISION}}"
RELEASE_TITLE="${RELEASE_TITLE:-$RELEASE_TAG}"
GH_REPO="${GH_REPO:-${GITHUB_REPOSITORY:-}}"
ASSET_NAME="${ASSET_NAME:-Clibgit2.xcframework.zip}"
CHECKSUM_ASSET_NAME="${CHECKSUM_ASSET_NAME:-Clibgit2.xcframework.checksum.txt}"
METADATA_ASSET_NAME="${METADATA_ASSET_NAME:-Clibgit2.artifact-metadata.json}"
SOURCE_ASSET_NAME="${SOURCE_ASSET_NAME:-libgit2-${EFFECTIVE_LIBGIT2_TAG}-source.tar.gz}"
NOTICES_ASSET_NAME="${NOTICES_ASSET_NAME:-Clibgit2.third-party-notices.txt}"
DRY_RUN="${DRY_RUN:-0}"
OVERWRITE_ASSETS="${OVERWRITE_ASSETS:-1}"
SKIP_BUILD="${SKIP_BUILD:-0}"
UPLOAD_PACKAGE_ASSET="${UPLOAD_PACKAGE_ASSET:-1}"
PACKAGE_CHECKSUM="${PACKAGE_CHECKSUM:-}"
COMPLIANCE_ONLY="${COMPLIANCE_ONLY:-0}"
UPDATE_RELEASE_NOTES="${UPDATE_RELEASE_NOTES:-1}"

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

ZIP_PATH="$BUILD_DIR/$ASSET_NAME"
CHECKSUM_PATH="$BUILD_DIR/$CHECKSUM_ASSET_NAME"
METADATA_PATH="$BUILD_DIR/$METADATA_ASSET_NAME"
SOURCE_ARCHIVE_PATH="$BUILD_DIR/$SOURCE_ASSET_NAME"
NOTICES_PATH="$BUILD_DIR/$NOTICES_ASSET_NAME"
SOURCE_DOWNLOAD_PATH="$WORK_DIR/downloads/libgit2-${EFFECTIVE_LIBGIT2_TAG}.tar.gz"
SOURCE_URL="https://github.com/libgit2/libgit2/archive/refs/tags/${EFFECTIVE_LIBGIT2_TAG}.tar.gz"

mkdir -p "$BUILD_DIR" "$WORK_DIR/downloads"

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

append_license_file() {
  local title="$1"
  local path="$2"

  if [[ ! -f "$path" ]]; then
    return
  fi

  {
    printf '\n\n===== %s =====\n\n' "$title"
    cat "$path"
  } >>"$NOTICES_PATH"
}

prepare_compliance_assets() {
  local extracted_source="$BUILD_DIR/libgit2-source-for-notices"

  download_file "$SOURCE_URL" "$SOURCE_DOWNLOAD_PATH"
  cp "$SOURCE_DOWNLOAD_PATH" "$SOURCE_ARCHIVE_PATH"

  rm -rf "$extracted_source"
  mkdir -p "$extracted_source"
  tar -xzf "$SOURCE_ARCHIVE_PATH" -C "$extracted_source" --strip-components 1

  cat >"$NOTICES_PATH" <<EOF
Clibgit2.xcframework third-party notices

Artifact: ${ASSET_NAME}
Upstream source: ${SOURCE_URL}
Source release asset: ${SOURCE_ASSET_NAME}

The Clibgit2 binary target is built from upstream libgit2. libgit2 is
distributed under GPL v2 with a linking exception. The linked exception permits
linking libgit2 into applications without applying the GPL to the application
code, but redistribution of this binary target still needs to preserve libgit2
and bundled dependency notices.
EOF

  append_license_file "libgit2 COPYING" "$extracted_source/COPYING"
  append_license_file "PCRE COPYING" "$extracted_source/deps/pcre/COPYING"
  append_license_file "zlib LICENSE" "$extracted_source/deps/zlib/LICENSE"
  append_license_file "llhttp LICENSE-MIT" "$extracted_source/deps/llhttp/LICENSE-MIT"

  rm -rf "$extracted_source"
}

if [[ "$UPLOAD_PACKAGE_ASSET" == "1" ]]; then
  if [[ "$SKIP_BUILD" == "1" && -f "$ZIP_PATH" ]]; then
    echo "Using existing Clibgit2 artifact at ${ZIP_PATH}"
  else
    echo "Building Clibgit2 artifact from libgit2 tag ${EFFECTIVE_LIBGIT2_TAG}"
    LIBGIT2_TAG="$EFFECTIVE_LIBGIT2_TAG" \
      BUILD_DIR="$BUILD_DIR" \
      WORK_DIR="$WORK_DIR" \
      "$BUILD_SCRIPT"
  fi

  if [[ ! -f "$ZIP_PATH" ]]; then
    echo "error: expected artifact not found: ${ZIP_PATH}" >&2
    exit 1
  fi

  CHECKSUM="$(swift package compute-checksum "$ZIP_PATH")"
elif [[ -f "$ZIP_PATH" ]]; then
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
  "checksum": "${CHECKSUM}",
  "libgit2_tag": "${EFFECTIVE_LIBGIT2_TAG}",
  "release_tag": "${RELEASE_TAG}",
  "license": "GPL-2.0-only WITH libgit2-linking-exception",
  "source_release_url": "https://github.com/libgit2/libgit2/releases/tag/${EFFECTIVE_LIBGIT2_TAG}",
  "source_archive_asset_name": "${SOURCE_ASSET_NAME}",
  "notices_asset_name": "${NOTICES_ASSET_NAME}",
  "bundled_dependency_notices": ["pcre", "zlib", "llhttp"],
  "supported_platforms": ["macos", "ios", "ios-simulator", "maccatalyst"],
  "published_at_utc": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

PACKAGE_URL="https://github.com/${GH_REPO}/releases/download/${RELEASE_TAG}/${ASSET_NAME}"
RELEASE_NOTES="Clibgit2.xcframework artifact built from upstream libgit2 ${EFFECTIVE_LIBGIT2_TAG}.

Compliance assets:
- ${SOURCE_ASSET_NAME}: exact upstream libgit2 source archive used for the build
- ${NOTICES_ASSET_NAME}: libgit2 and bundled dependency license notices
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
    "$SOURCE_ARCHIVE_PATH"
    "$NOTICES_PATH"
    --repo "$GH_REPO"
  )

  if [[ "$UPLOAD_PACKAGE_ASSET" == "1" ]]; then
    upload_args=(
      "$RELEASE_TAG"
      "$ZIP_PATH"
      "$CHECKSUM_PATH"
      "$METADATA_PATH"
      "$SOURCE_ARCHIVE_PATH"
      "$NOTICES_PATH"
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
  Repo:       ${GH_REPO}
  Release:    ${RELEASE_TAG}
  libgit2:    ${EFFECTIVE_LIBGIT2_TAG}
  Platforms:  macOS, iOS, iOS Simulator, Mac Catalyst
  Artifact:   ${ZIP_PATH}
  Checksum:   ${CHECKSUM}
  Source:     ${SOURCE_ARCHIVE_PATH}
  Notices:    ${NOTICES_PATH}

Package.swift snippet:
  .binaryTarget(
      name: "Clibgit2",
      url: "${PACKAGE_URL}",
      checksum: "${CHECKSUM}"
  )
EOF

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat >>"$GITHUB_STEP_SUMMARY" <<EOF
## Clibgit2 Artifact

- Release: \`${RELEASE_TAG}\`
- libgit2 tag: \`${EFFECTIVE_LIBGIT2_TAG}\`
- Platforms: \`macOS, iOS, iOS Simulator, Mac Catalyst\`
- Artifact URL: \`${PACKAGE_URL}\`
- Checksum: \`${CHECKSUM}\`
- Source asset: \`${SOURCE_ASSET_NAME}\`
- Notices asset: \`${NOTICES_ASSET_NAME}\`
EOF
fi
