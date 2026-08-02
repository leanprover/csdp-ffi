#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 CSDP-<target>.tar.gz" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive_dir="$(cd "$(dirname "$1")" && pwd)"
archive="$archive_dir/$(basename "$1")"
trial="$(mktemp -d)"

git -C "$repo_root" archive HEAD | tar -x -C "$trial"
mkdir -p "$trial/.lake/build"
tar -xzf "$archive" -C "$trial/.lake/build"

(
  cd "$trial"
  lake build --no-build --rehash CSDP csdp-example -- -KcsdpPortable=true
  lake exe csdp-example -- -KcsdpPortable=true
)

echo "PASS: $(basename "$archive") is relocatable and complete."
