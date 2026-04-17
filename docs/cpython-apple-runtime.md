# CPython Apple Runtime

`BashPython` is designed around a single SwiftPM binary target:
`CPython.xcframework.zip`. The artifact is published as a GitHub release asset
and referenced from `Package.swift`.

## Supported Runtime Targets

- macOS
- iOS and iPadOS device builds
- iOS and iPadOS simulator builds
- Mac Catalyst

tvOS and watchOS remain compile-only. `BashPython` can be imported there, but
`BashPython.isCPythonRuntimeAvailable()` returns `false` and `python3` reports
that embedded CPython is unavailable.

## Artifact Layout

The release artifact should be self-contained for BashPython's standard
library needs:

- each supported slice contains `Python.framework`
- iOS and Mac Catalyst slices statically link the selected native stdlib
  modules into `Python.framework`
- pure-Python stdlib files live under `Python.framework/lib/python3.13`
  for iOS and Mac Catalyst slices, and under the versioned framework resources
  for macOS
- the resource stdlib excludes bulky or unsupported packages such as
  `test`, `idlelib`, `tkinter`, `ensurepip`, and `venv`

This avoids requiring consumer app targets to run CPython's normal iOS
post-processing step for BashPython's bundled stdlib. Third-party Python
packages with native binaries are still out of scope for this artifact and
would need their own packaging story.

## Build Step

Use [build_cpython_xcframework.sh](../scripts/build_cpython_xcframework.sh)
to create the self-contained release artifact:

```bash
scripts/build_cpython_xcframework.sh
```

By default this delegates to
[build_cpython_selfcontained_xcframework.sh](../scripts/build_cpython_selfcontained_xcframework.sh),
which:

- reads Python and dependency versions from BeeWare's `Python-Apple-support`
  metadata for `BEEWARE_TAG`
- uses BeeWare's macOS framework slice
- source-builds iOS device, iOS simulator, and Mac Catalyst slices
- writes `Modules/Setup.local` so selected native stdlib modules are built
  statically
- copies the pure-Python stdlib into framework resources
- packages `build/cpython/CPython.xcframework.zip`
- prints the SwiftPM checksum to paste into `Package.swift`

The old BeeWare repackaging path is still available for comparison:

```bash
SELF_CONTAINED=0 scripts/build_cpython_xcframework.sh
```

## Publish Step

Use [publish_cpython_release_asset.sh](../scripts/publish_cpython_release_asset.sh)
to build and upload the SwiftPM artifact:

```bash
GH_REPO=velos/Bash.swift \
RELEASE_TAG=cpython-3.13-b13-selfcontained-r3 \
BEEWARE_TAG=3.13-b13 \
scripts/publish_cpython_release_asset.sh
```

The publish script:

- runs the self-contained artifact builder
- writes `CPython.xcframework.checksum.txt` and
  `CPython.artifact-metadata.json`
- creates the target GitHub release tag if it does not already exist
- uploads `CPython.xcframework.zip` plus checksum/metadata assets
- prints the exact `Package.swift` `binaryTarget` snippet to use

The script expects GitHub CLI auth via `GH_TOKEN` or `GITHUB_TOKEN`.

For CI, use the manual
[`publish-cpython-artifact.yml`](../.github/workflows/publish-cpython-artifact.yml)
workflow. It installs Python 3.13 as the CPython build host, runs the same
publisher, and uploads the generated zip/checksum/metadata as a workflow
artifact. Dispatch it with `dry_run=true` first to exercise the full build
without creating or updating a GitHub release. After that passes, dispatch it
again with `dry_run=false` to publish the release asset.

## Runtime Initialization

`CPythonRuntime` locates the embedded `org.python.python` framework bundle and
uses its bundled Python home when initializing CPython. For debugging a custom
runtime, set `BASHSWIFT_PYTHONHOME` to a directory containing
`lib/python3.13`.

The shell integration still owns BashPython's security model:

- file access routes through the configured shell `FileSystem`
- socket attempts route through the shell network policy/callback path
- `subprocess`, `ctypes`, and `os.system` remain blocked by strict shims

## Validation

Recommended checks after publishing a new artifact:

```bash
HOST_PYTHON=python3.13 \
GH_REPO=velos/Bash.swift \
RELEASE_TAG=cpython-3.13-b13-selfcontained-r3-local \
BEEWARE_TAG=3.13-b13 \
DRY_RUN=1 \
scripts/publish_cpython_release_asset.sh

swift test --filter BashPythonTests
swift build --target BashPython \
  --triple arm64-apple-ios16.0-simulator \
  --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)"
swift build --target BashPython \
  --triple arm64-apple-tvos16.0-simulator \
  --sdk "$(xcrun --sdk appletvsimulator --show-sdk-path)"
swift build --target BashPython \
  --triple arm64-apple-watchos9.0-simulator \
  --sdk "$(xcrun --sdk watchsimulator --show-sdk-path)"
```

Also validate an iOS simulator host app that imports `BashPython` from SwiftPM
and runs `python3 --version`, `python3 -c`, stdlib imports, filesystem interop,
strict escape blocking, and network policy checks.
