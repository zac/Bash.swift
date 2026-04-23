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
require_command swift

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
DRY_RUN="${DRY_RUN:-0}"
OVERWRITE_ASSETS="${OVERWRITE_ASSETS:-1}"
INCLUDES_CATALYST=1

if [[ -z "$GH_REPO" ]]; then
  echo "error: GH_REPO or GITHUB_REPOSITORY must be set" >&2
  exit 1
fi

if [[ ! -x "$BUILD_SCRIPT" ]]; then
  echo "error: build script is missing or not executable: ${BUILD_SCRIPT}" >&2
  exit 1
fi

mkdir -p "$BUILD_DIR"

echo "Building CPython artifact from BeeWare tag ${EFFECTIVE_BEEWARE_TAG}"
BEEWARE_TAG="$EFFECTIVE_BEEWARE_TAG" \
  BUILD_DIR="$BUILD_DIR" \
  "$BUILD_SCRIPT"

ZIP_PATH="$BUILD_DIR/$ASSET_NAME"
CHECKSUM_PATH="$BUILD_DIR/$CHECKSUM_ASSET_NAME"
METADATA_PATH="$BUILD_DIR/$METADATA_ASSET_NAME"

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "error: expected artifact not found: ${ZIP_PATH}" >&2
  exit 1
fi

CHECKSUM="$(swift package compute-checksum "$ZIP_PATH")"
printf '%s\n' "$CHECKSUM" > "$CHECKSUM_PATH"

cat >"$METADATA_PATH" <<EOF
{
  "asset_name": "${ASSET_NAME}",
  "beeware_tag": "${EFFECTIVE_BEEWARE_TAG}",
  "checksum": "${CHECKSUM}",
  "includes_catalyst": ${INCLUDES_CATALYST},
  "self_contained": true,
  "release_tag": "${RELEASE_TAG}",
  "source_release_url": "https://github.com/beeware/Python-Apple-support/releases/tag/${EFFECTIVE_BEEWARE_TAG}",
  "published_at_utc": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

PACKAGE_URL="https://github.com/${GH_REPO}/releases/download/${RELEASE_TAG}/${ASSET_NAME}"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "Dry run enabled; skipping GitHub release upload."
else
  if gh release view "$RELEASE_TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
    echo "Updating existing release ${GH_REPO}@${RELEASE_TAG}"
  else
    echo "Creating release ${GH_REPO}@${RELEASE_TAG}"
    gh release create "$RELEASE_TAG" \
      --repo "$GH_REPO" \
      --title "$RELEASE_TITLE" \
      --notes "Self-contained CPython.xcframework artifact built from BeeWare Python-Apple-support metadata ${EFFECTIVE_BEEWARE_TAG}."
  fi

  upload_args=(
    "$RELEASE_TAG"
    "$ZIP_PATH"
    "$CHECKSUM_PATH"
    "$METADATA_PATH"
    --repo "$GH_REPO"
  )

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
EOF
fi
