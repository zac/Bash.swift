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
BUILD_SCRIPT="$ROOT_DIR/scripts/build_libgit2_xcframework.sh"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build/libgit2}"
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
DRY_RUN="${DRY_RUN:-0}"
OVERWRITE_ASSETS="${OVERWRITE_ASSETS:-1}"
SKIP_BUILD="${SKIP_BUILD:-0}"

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

mkdir -p "$BUILD_DIR"

if [[ "$SKIP_BUILD" == "1" && -f "$ZIP_PATH" ]]; then
  echo "Using existing Clibgit2 artifact at ${ZIP_PATH}"
else
  echo "Building Clibgit2 artifact from libgit2 tag ${EFFECTIVE_LIBGIT2_TAG}"
  LIBGIT2_TAG="$EFFECTIVE_LIBGIT2_TAG" \
    BUILD_DIR="$BUILD_DIR" \
    "$BUILD_SCRIPT"
fi

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "error: expected artifact not found: ${ZIP_PATH}" >&2
  exit 1
fi

CHECKSUM="$(swift package compute-checksum "$ZIP_PATH")"
printf '%s\n' "$CHECKSUM" > "$CHECKSUM_PATH"

cat >"$METADATA_PATH" <<EOF
{
  "asset_name": "${ASSET_NAME}",
  "checksum": "${CHECKSUM}",
  "libgit2_tag": "${EFFECTIVE_LIBGIT2_TAG}",
  "release_tag": "${RELEASE_TAG}",
  "source_release_url": "https://github.com/libgit2/libgit2/releases/tag/${EFFECTIVE_LIBGIT2_TAG}",
  "supported_platforms": ["macos", "ios", "ios-simulator", "maccatalyst"],
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
      --notes "Clibgit2.xcframework artifact built from upstream libgit2 ${EFFECTIVE_LIBGIT2_TAG}."
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
  Repo:       ${GH_REPO}
  Release:    ${RELEASE_TAG}
  libgit2:    ${EFFECTIVE_LIBGIT2_TAG}
  Platforms:  macOS, iOS, iOS Simulator, Mac Catalyst
  Artifact:   ${ZIP_PATH}
  Checksum:   ${CHECKSUM}

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
EOF
fi
