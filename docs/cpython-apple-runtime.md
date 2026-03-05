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

## Maintainer Script

Use [build_cpython_xcframework.sh](/Users/zac/Projects/collab/Bash.swift/scripts/build_cpython_xcframework.sh)
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

The script also accepts an optional custom Catalyst framework:

```bash
CPYTHON_CATALYST_FRAMEWORK_PATH=/abs/path/to/Python.framework \
REQUIRE_CATALYST=1 \
scripts/build_cpython_xcframework.sh
```

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

1. A published release asset that includes the desired platform slices.
2. `BashCPythonBridge` linker settings updated for the framework name inside the
   new artifact.
3. `Package.swift` platform conditions widened so `CPython` is linked on iOS
   and Mac Catalyst when those slices exist.
4. A resource/install story for mobile and Catalyst builds so the Python
   standard library is available at runtime.
