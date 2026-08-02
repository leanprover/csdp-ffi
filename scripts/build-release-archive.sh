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

# A release build must not inherit traces or configuration from an ordinary
# system-BLAS build made earlier in the same CI job. Build from the committed
# tree in a fresh directory, exactly as a release consumer sees it.
git -C "$repo_root" archive HEAD | tar -x -C "$producer"
(
  cd "$producer"
  lake -KcsdpPortable=true build CSDP csdp-example
  lake pack
  CSDP_RELEASE_SOURCE_ROOT="$repo_root" \
    "$repo_root/scripts/test-release-archive.sh" .lake/CSDP-*.tar.gz
  cp .lake/CSDP-*.tar.gz "$output_dir/"
)
