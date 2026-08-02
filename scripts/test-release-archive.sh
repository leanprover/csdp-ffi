#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 CSDP-<target>.tar.gz" >&2
  exit 2
fi

repo_root="${CSDP_RELEASE_SOURCE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
archive_dir="$(cd "$(dirname "$1")" && pwd)"
archive="$archive_dir/$(basename "$1")"
trial="$(mktemp -d)"

for required in \
    './BUILD-PROVENANCE.txt' \
    './share/licenses/csdp-ffi/Apache-2.0.txt' \
    './share/licenses/csdp-ffi/CSDP-CPL-1.0.txt' \
    './share/licenses/csdp-ffi/THIRD_PARTY_NOTICES.md'; do
  if ! tar -tzf "$archive" | grep -Fxq "$required"; then
    echo "release archive is missing $required" >&2
    exit 1
  fi
done

if tar -tzf "$archive" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
  echo "release archive contains an absolute or parent-traversing path" >&2
  exit 1
fi

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

grep -Fq 'Common Public License Version 1.0' \
  "$trial/.lake/build/share/licenses/csdp-ffi/CSDP-CPL-1.0.txt"
grep -Fq 'e1586e0413ef236b19abe5202f7e8392f3dd4614' \
  "$trial/.lake/build/BUILD-PROVENANCE.txt"

(
  cd "$trial"
  lake -KcsdpPortable=true --no-build --rehash build CSDP csdp-example
  lake -KcsdpPortable=true exe csdp-example
)

echo "PASS: $(basename "$archive") is relocatable and complete."
