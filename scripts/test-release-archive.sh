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
# A GitHub release is fetched only after Lake has loaded the dependency's
# configuration in its downstream location. Mirror that ordering here so the
# test exercises archive relocation rather than reusing producer-side config.
(
  cd "$trial"
  lake -KcsdpPortable=true check-build
)
mkdir -p "$trial/.lake/build"
tar -xzf "$archive" -C "$trial/.lake/build"

(
  cd "$trial"
  lake -KcsdpPortable=true --no-build --rehash build CSDP csdp-example
  lake -KcsdpPortable=true exe csdp-example
)

echo "PASS: $(basename "$archive") is relocatable and complete."
