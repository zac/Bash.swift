# CPython Apple Runtime

This repository currently ships a macOS-only embedded CPython runtime. The
goal of the next iteration is to move to a broader Apple artifact that can
cover:

- macOS
- iOS and iPadOS
- Mac Catalyst

## What Exists Upstream

- CPython officially documents building an iOS `Python.xcframework`.
- BeeWare's `Python-Apple-support` publishes prebuilt support packages for
  macOS and iOS, and those packages already contain mergeable
  `Python.xcframework` bundles.

Relevant upstream references:

- `https://docs.python.org/3.14/using/ios.html`
- `https://github.com/beeware/Python-Apple-support`
- `https://github.com/beeware/Python-Apple-support/blob/main/README.md`

## Build Script

Use [build_cpython_xcframework.sh](../scripts/build_cpython_xcframework.sh)
to assemble a release asset from BeeWare's published support packages:

```bash
scripts/build_cpython_xcframework.sh
```

By default the script:

- downloads BeeWare's macOS support package for `BEEWARE_TAG`
- downloads BeeWare's iOS support package for `BEEWARE_TAG`
- merges those frameworks into `build/cpython/CPython.xcframework`
- packages `build/cpython/CPython.xcframework.zip`
- prints the SwiftPM checksum

To auto-build and include a Mac Catalyst framework slice in the same pass:

```bash
BUILD_CATALYST=1 \
scripts/build_cpython_xcframework.sh
```

This repo also includes a dedicated helper,
[build_cpython_catalyst_framework.sh](../scripts/build_cpython_catalyst_framework.sh),
which builds a fat `arm64` + `x86_64` `Python.framework` for
`*-apple-ios-macabi` from official CPython sources plus BeeWare's published
`macabi` dependency archives. The builder defaults to a Mac Catalyst
deployment target of `13.1`, which is the first Xcode-accepted `macabi`
triple:

```bash
scripts/build_cpython_catalyst_framework.sh
```

If you already have a Catalyst framework, the XCFramework build still accepts a
manual path override:

```bash
CPYTHON_CATALYST_FRAMEWORK_PATH=/abs/path/to/Python.framework \
REQUIRE_CATALYST=1 \
scripts/build_cpython_xcframework.sh
```

## Publish Step

Use [publish_cpython_release_asset.sh](../scripts/publish_cpython_release_asset.sh)
to build the SwiftPM artifact and upload it to a GitHub release:

```bash
GH_REPO=velos/Bash.swift \
RELEASE_TAG=cpython-3.13-b13 \
BEEWARE_TAG=3.13-b13 \
BUILD_CATALYST=1 \
scripts/publish_cpython_release_asset.sh
```

The publish script:

- runs `build_cpython_xcframework.sh`
- writes `CPython.xcframework.checksum.txt` and `CPython.artifact-metadata.json`
- creates the target GitHub release tag if it does not already exist
- uploads `CPython.xcframework.zip` plus checksum/metadata assets
- prints the exact `Package.swift` `binaryTarget` snippet to use

The script expects GitHub CLI auth via `GH_TOKEN`/`GITHUB_TOKEN`.

For maintainers who prefer a manual UI entry point, this repo also includes
[`publish-cpython-artifact.yml`](../.github/workflows/publish-cpython-artifact.yml),
which exposes a `workflow_dispatch` action with `beeware_tag`, optional
`release_tag`, and an `include_catalyst` toggle.

## Important Constraints

Producing a broader `CPython.xcframework` is only one part of iOS/Catalyst
support.

The official iOS packaging flow also requires:

- copying Python runtime files into the app bundle
- setting `PYTHONHOME`
- setting `PYTHONPATH`
- post-processing binary modules for App Store compliant framework layout

That means Bash.swift should not enable iOS or Mac Catalyst runtime support
until the app-bundle packaging story is implemented as well.

## Follow-up Work

To actually turn on runtime support beyond macOS, the package still needs:

1. A packaging decision for SwiftPM linkage beyond macOS. SwiftPM can gate on
   `.iOS`, but not specifically on Mac Catalyst, so widening the manifest would
   also pull CPython into plain iOS builds before the runtime bundle story is
   ready.
2. A resource/install story for mobile and Catalyst builds so the Python
   standard library is available at runtime.
