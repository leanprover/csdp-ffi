# CSDP source provenance

This directory vendors the [CSDP](https://github.com/coin-or/Csdp)
solver source code so that `lean-csdp` can be consumed via `require
... from git` in downstream Lake packages without depending on git
submodule semantics (Lake doesn't pass `--recursive` when cloning
dependencies).

- **Source**: https://github.com/coin-or/Csdp
- **Commit**: `e1586e0413ef236b19abe5202f7e8392f3dd4614` (release 6.2.0).
- **License**: Common Public License 1.0 (see `LICENSE` in this
  directory).

To bump the upstream version:

1. Replace the contents of this directory (except `UPSTREAM.md`)
   with the new upstream sources.
2. Update the commit hash above.
3. Re-test on Linux + macOS + Windows.
4. Commit with a clear message naming the bumped version.
