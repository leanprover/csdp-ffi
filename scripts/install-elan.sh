#!/usr/bin/env bash

# Install one audited elan release. Release-producing CI must not execute an
# installer from a moving branch or a moving `latest` URL.

set -euo pipefail

if command -v elan >/dev/null 2>&1; then
  exit 0
fi

version="v4.2.3"
platform="$(uname -s)"
machine="$(uname -m)"

case "$platform:$machine" in
  Linux:x86_64)
    asset="elan-x86_64-unknown-linux-gnu.tar.gz"
    expected="df0b2b3a439961ffcbb3985214365ffe40f49bc871df04dff268c7d8e21ca8b2"
    ;;
  Linux:aarch64|Linux:arm64)
    asset="elan-aarch64-unknown-linux-gnu.tar.gz"
    expected="cb69af0803b04157bc30201c29c12fca882bb3ad8b43476b8d2d3064810bc3ac"
    ;;
  Darwin:x86_64)
    asset="elan-x86_64-apple-darwin.tar.gz"
    expected="10d037a69731c0593723e018130c5f54afde175796b4af8ba1317e561e55598c"
    ;;
  Darwin:arm64|Darwin:aarch64)
    asset="elan-aarch64-apple-darwin.tar.gz"
    expected="7cae4c03b2f0de4053fb04a91359d5804551e6e37a6ddd1b2e0097dc561ae4a9"
    ;;
  MINGW*:x86_64|MSYS*:x86_64|CYGWIN*:x86_64)
    asset="elan-x86_64-pc-windows-msvc.zip"
    expected="be5e92a2dfdd8176099b2db0b810c27237c9054f1e5db1126f4f2a1134773b25"
    ;;
  *)
    echo "unsupported elan installer platform: $platform $machine" >&2
    exit 1
    ;;
esac

installer_dir="$(mktemp -d)"
trap 'rm -rf "$installer_dir"' EXIT
url="https://github.com/leanprover/elan/releases/download/$version/$asset"
curl -fsSL --retry 5 --retry-delay 5 -o "$installer_dir/$asset" "$url"

if command -v sha256sum >/dev/null 2>&1; then
  printf '%s  %s\n' "$expected" "$installer_dir/$asset" | sha256sum -c -
else
  actual="$(shasum -a 256 "$installer_dir/$asset" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "elan installer checksum mismatch: expected $expected, got $actual" >&2
    exit 1
  fi
fi

case "$asset" in
  *.zip)
    unzip -q "$installer_dir/$asset" -d "$installer_dir"
    MSYS2_ARG_CONV_EXCL="*" "$installer_dir/elan-init.exe" \
      -y --default-toolchain none --no-modify-path
    ;;
  *)
    tar -xzf "$installer_dir/$asset" -C "$installer_dir"
    "$installer_dir/elan-init" -y --default-toolchain none --no-modify-path
    ;;
esac
