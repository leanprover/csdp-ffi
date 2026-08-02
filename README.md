# csdp-ffi

[![CI](https://github.com/leanprover/csdp-ffi/actions/workflows/ci.yml/badge.svg)](https://github.com/leanprover/csdp-ffi/actions/workflows/ci.yml)

Lean 4 FFI bindings for the [CSDP](https://github.com/coin-or/Csdp)
semidefinite-programming solver. Wraps the high-level `easy_sdp` entry
point so Lean code can solve standard-form SDPs

```
maximise     tr(C · X)
subject to   tr(Aᵢ · X) = bᵢ        for i = 1, …, k
             X ⪰ 0  with block-diagonal structure
```

CSDP itself (release 6.2.0) is vendored under `vendored/csdp/`; this
package builds it from source against the system BLAS/LAPACK runtime when one
is available. A bundled reference implementation of the small BLAS/LAPACK
surface used by CSDP is also available on every supported platform and is used
for dependency release archives.

## Using

```lean
import CSDP
open CSDP

-- Block sizes: positive => SDP block of that order;
-- negative => LP-style diagonal block of order |size|.
def problem : Problem := {
  blockSizes := #[2, -3],
  b := #[1.0, 2.0],
  c := #[
    ⟨1, 1, 1, 2.0⟩, ⟨1, 1, 2, 1.0⟩, ⟨1, 2, 2, 2.0⟩,
    -- ... (block, row, col, value), 1-indexed, upper triangle only
  ],
  a := #[
    ⟨1, 1, 1, 1, 3.0⟩, ⟨1, 1, 1, 2, 1.0⟩,
    -- ... (constraint, block, row, col, value)
  ]
}

#eval do
  let sol := solve problem
  IO.println s!"primal = {sol.pobj}, dual = {sol.dobj}"
```

`Solution.X` and `Solution.Z` come back split into per-block `Block`
values (`.sdp n entries` for column-major SDP blocks, `.diag n entries`
for diagonal blocks); `Solution.y` is a flat `FloatArray` of length `k`.

A worked example reproducing the canonical CSDP problem (objective
`2.75`) lives in [`Main.lean`](Main.lean) and is exercised in CI on
each platform.

## Building locally

```
git clone https://github.com/leanprover/csdp-ffi
cd csdp-ffi
lake build
lake exe csdp-example   # Lean runs the SDP and prints the result
```

If the native dependency setup is unclear, run the preflight check:

```
lake script run checkNativeDeps
```

The same check also runs before compiling CSDP's C sources. On Linux it reports
whether the system libraries or the portable fallback will be used; on macOS
and Windows it fails with platform-specific install instructions when the
native dependency is unavailable unless the portable backend is configured.

System dependencies (matching what CI installs):

| Platform | What you need                                       |
|----------|-----------------------------------------------------|
| Linux    | Optional: `liblapack-dev libblas-dev gfortran`; `zstd` for the toolchain fallback |
| macOS    | Apple Command Line Tools (Accelerate framework)     |
| Windows  | MSYS2 mingw-w64 with `mingw-w64-x86_64-openblas`    |

On Windows the lakefile expects the OpenBLAS import library at
`vendor/mingw-libs/`; the CI workflow stages it from `$MINGW_PREFIX/lib`
and you can do the same locally before `lake build`.

For a non-standard installation (for example Nix), set
`CSDP_NATIVE_LIB_DIRS` to the platform-separated list of directories
containing BLAS, LAPACK, and the gfortran runtime. This affects only the
provider-owned CSDP build; consumers still do not add link flags.
Set `CSDP_FORCE_PORTABLE_LINALG=1` to exercise the bundled fallback even when
system libraries are available. Dependencies that need a stable, system-library
free build can set the Lake configuration `csdpPortable` to `true`.

The package directs compiler and linker temporary files to its own
`.lake/build/tmp` directory. This keeps native builds working in downstream
sandboxes where the system temporary directory is read-only.

## Using `csdp-ffi` as a Lake dependency

Add the package normally and import `CSDP`:

```lean
import Lake
open Lake DSL

require CSDP from git
  "https://github.com/leanprover/csdp-ffi" @ "<release-tag>"
  with NameMap.empty.insert `csdpPortable "true"

lean_lib MyLibrary
```

Consumers do not repeat BLAS/LAPACK, Fortran, or Accelerate linker flags. On
macOS and Linux, the package builds and exports a resolved solver shared
library. On Windows, it exports a combined CSDP/bridge archive plus the
OpenBLAS DLL, avoiding unsafe allocation across different C
runtimes. Lake propagates these provider-owned artifacts through ordinary
imports to downstream libraries, executables, tests, and module setup data.
Tagged releases provide relocatable archives for Linux x64/ARM64, macOS
x64/ARM64, and Windows x64. Lake fetches the archive matching the current
target instead of compiling CSDP when the build directory is initially absent.
The archives use the portable backend, so the system-library prerequisites in
the table above apply only when building the package from source without
`csdpPortable`.

On Windows, the MinGW OpenBLAS and Fortran runtime DLLs must be discoverable by
the process loading CSDP (normally by keeping `$MINGW_PREFIX/bin` on `PATH`).
The csdp-ffi shared library itself is located through Lake's generated setup
and runtime paths. Run produced executables with `lake exe <target>` so Lake
adds package shared-library directories to `PATH`.

The package's cross-platform CI includes a `platformIndependent := true`
downstream fixture with no native configuration. It exercises plain and
precompiled Lean libraries, the test driver, a native executable, an explicit
Lean `--setup` invocation, and regeneration of a missing platform CSDP artifact
without rebuilding the portable consumer olean.

## Repository layout

```
vendored/csdp/         # CSDP 6.2.0 vendored source (was a submodule; see vendored/csdp/UPSTREAM.md)
ffi/lean_csdp.c        # C glue translating flat sparse data to CSDP structs
ffi/lean_csdp_bridge.c # Lean-callable entry points
CSDP/Basic.lean        # Lean-side types + opaque FFI declarations
Main.lean              # Worked example exercised in CI
lakefile.lean          # Build configuration
scripts/install-toolchain.sh  # Lean toolchain installer with GitHub-release fallback
scripts/cc-link-temp-probe.sh # CI check for package-local linker temporaries
scripts/test-downstream.sh     # Flag-free downstream and cache-boundary checks
scripts/test-lsp.py            # `lake serve` native-loading smoke test
tests/downstream/              # Platform-independent consumer fixture
```

## Licence

Apache License 2.0 (see [LICENSE](LICENSE)). CSDP itself is distributed
under the [Eclipse Public License 1.0](vendored/csdp/LICENSE).
