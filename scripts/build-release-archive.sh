#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 OUTPUT-DIRECTORY" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="$1"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
producer="$(mktemp -d)"
source_rev="$(git -C "$repo_root" rev-parse HEAD)"

# A release build must not inherit traces or configuration from an ordinary
# system-BLAS build made earlier in the same CI job. Build from the committed
# tree in a fresh directory, exactly as a release consumer sees it.
git -C "$repo_root" archive HEAD | tar -x -C "$producer"
(
  cd "$producer"
  lake -KcsdpPortable=true build CSDP csdp-example
  license_dir=".lake/build/share/licenses/csdp-ffi"
  mkdir -p "$license_dir"
  cp LICENSE "$license_dir/Apache-2.0.txt"
  cp vendored/csdp/LICENSE "$license_dir/CSDP-CPL-1.0.txt"
  cp THIRD_PARTY_NOTICES.md "$license_dir/THIRD_PARTY_NOTICES.md"
  {
    printf 'csdp-ffi source revision: %s\n' "$source_rev"
    printf 'CSDP upstream revision: %s\n' \
      'e1586e0413ef236b19abe5202f7e8392f3dd4614'
    printf 'Lean toolchain: %s\n' "$(tr -d '\r\n' < lean-toolchain)"
    printf 'Lean version: '
    lean --version | sed -n '1p'
    printf 'Build host: %s\n' "$(uname -sm)"
    printf 'C compiler:\n'
    cc --version | sed -n '1,2p'
  } > .lake/build/BUILD-PROVENANCE.txt
  lake pack
  CSDP_RELEASE_SOURCE_ROOT="$repo_root" \
    "$repo_root/scripts/test-release-archive.sh" .lake/CSDP-*.tar.gz
  cp .lake/CSDP-*.tar.gz "$output_dir/"
)
