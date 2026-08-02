# Third-party notices

## CSDP 6.2.0

The native libraries distributed by this repository include CSDP 6.2.0.

- Upstream repository: <https://github.com/coin-or/Csdp>
- Upstream revision: `e1586e0413ef236b19abe5202f7e8392f3dd4614`
- Licence: Common Public License Version 1.0
- Licence text: `vendored/csdp/LICENSE` in the source tree and
  `share/licenses/csdp-ffi/CSDP-CPL-1.0.txt` in native release archives
- Corresponding source: the `vendored/csdp/` directory at the exact
  `csdp-ffi` release tag from which an archive was built

The CSDP sources are built without semantic modifications. The packaging
repository supplies a small portable implementation of the BLAS/LAPACK
surface CSDP uses; that implementation and the Lean/C bridge remain covered
by this repository's Apache License 2.0.
