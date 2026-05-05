# libgit2 Apple Runtime

`BashGitFeature` is designed around a single SwiftPM binary target:
`Clibgit2.xcframework.zip`. The artifact is published as a GitHub release asset
and referenced from `Package.swift`.

## Supported Runtime Targets

- macOS
- iOS and iPadOS device builds
- iOS and iPadOS simulator builds
- Mac Catalyst

tvOS and watchOS remain compile-only. `BashGitFeature` can be imported there,
but `git` reports that libgit2 is unavailable at runtime.

## Artifact Layout

The release artifact contains static libgit2 libraries and public headers:

- one static `libgit2.a` slice for macOS
- one static `libgit2.a` slice for iOS devices
- one static `libgit2.a` slice for iOS simulators
- one static `libgit2.a` slice for Mac Catalyst
- public `git2.h` / `git2/*.h` headers
- a `module.modulemap` that exposes the Swift module as `Clibgit2`

The build uses upstream [libgit2](https://github.com/libgit2/libgit2) source.
It builds static libraries with SecureTransport, libgit2's collision-detecting
SHA1 backend, CommonCrypto SHA256, bundled regex, bundled zlib, and SSH
transport disabled. Disabling SSH avoids libgit2 spawning an external `ssh`
process from inside Bash's in-process Git command.

## Build Step

Use [build_libgit2_xcframework.sh](../scripts/build_libgit2_xcframework.sh)
to create the release artifact:

```bash
scripts/build_libgit2_xcframework.sh
```

By default this builds upstream `libgit2` tag `v1.9.2` and writes:

- `build/libgit2/Clibgit2.xcframework`
- `build/libgit2/Clibgit2.xcframework.zip`
- a SwiftPM checksum printed to stdout

To build another upstream tag:

```bash
LIBGIT2_TAG=v1.9.3 scripts/build_libgit2_xcframework.sh
```

## Publish Step

Use [publish_libgit2_release_asset.sh](../scripts/publish_libgit2_release_asset.sh)
to build and upload the SwiftPM artifact:

```bash
GH_REPO=velos/Bash.swift \
RELEASE_TAG=libgit2-1.9.2-r2 \
LIBGIT2_TAG=v1.9.2 \
scripts/publish_libgit2_release_asset.sh
```

The publish script:

- runs the artifact builder
- writes `Clibgit2.xcframework.checksum.txt` and
  `Clibgit2.artifact-metadata.json`
- writes `Clibgit2.third-party-notices.txt`
- copies the exact upstream source archive as
  `libgit2-<tag>-source.tar.gz`
- creates the target GitHub release tag if it does not already exist
- uploads `Clibgit2.xcframework.zip` plus checksum, metadata, source, and
  notice assets
- prints the exact `Package.swift` `binaryTarget` snippet to use

The script expects GitHub CLI auth via `GH_TOKEN` or `GITHUB_TOKEN`.
For local iteration, set `SKIP_BUILD=1` to publish or dry-run against an
existing `build/libgit2/Clibgit2.xcframework.zip`.

To add or refresh only the source and notice assets for an existing release,
without touching the SwiftPM binary zip:

```bash
GH_REPO=velos/Bash.swift \
RELEASE_TAG=libgit2-1.9.2-r2 \
LIBGIT2_TAG=v1.9.2 \
COMPLIANCE_ONLY=1 \
scripts/publish_libgit2_release_asset.sh
```

For CI, use the manual
[`publish-libgit2-artifact.yml`](../.github/workflows/publish-libgit2-artifact.yml)
workflow. Dispatch it with `dry_run=true` first to exercise the full build
without creating or updating a GitHub release. After that passes, dispatch it
again with `dry_run=false` to publish the release asset.

## Validation

Recommended checks after publishing a new artifact:

```bash
GH_REPO=velos/Bash.swift \
RELEASE_TAG=libgit2-1.9.2-r2-local \
LIBGIT2_TAG=v1.9.2 \
DRY_RUN=1 \
scripts/publish_libgit2_release_asset.sh

swift package reset
swift build --traits Git
swift test --traits Git --filter BashGitTests
```

## License

libgit2 is distributed under GPL v2 with a linking exception. The release
assets include the upstream source archive and a third-party notices file for
libgit2 and the bundled dependency code compiled into the static library. Keep
those license and notice requirements in downstream app legal notices when
redistributing the artifact.
