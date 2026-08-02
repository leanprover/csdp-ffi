#!/usr/bin/env bash

# Write a checksum manifest that remains valid after GitHub flattens the
# uploaded release assets into one download directory.

set -euo pipefail

assets_dir="${1:?usage: write-release-checksums.sh ASSETS_DIR}"

(
  cd "$assets_dir"
  archives=(CSDP-*.tar.gz)
  if [[ ! -e "${archives[0]}" ]]; then
    echo "no CSDP release archives found in $assets_dir" >&2
    exit 1
  fi
  sha256sum -- "${archives[@]}" > SHA256SUMS
  sha256sum -c SHA256SUMS
)
