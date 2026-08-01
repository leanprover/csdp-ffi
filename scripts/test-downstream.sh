#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
consumer="$repo_root/tests/downstream"

if grep -Eq 'moreLink(Args|Libs)|blas|lapack|gfortran|Accelerate' \
    "$consumer/lakefile.lean"; then
  echo "downstream fixture must not contain native link configuration"
  exit 1
fi

cd "$consumer"
lake update
lake build DownstreamPlain DownstreamPrecompiled:shared
lake test
lake build downstream
lake exe downstream

# On Windows, `csdp_bridge.dll` is the interpreter artifact. Native
# executables must consume the same-named static archive instead; importing
# the DLL would introduce a second Lean runtime and a separate C heap.
if [[ "$(uname -s)" == MINGW* ]]; then
  exe="$consumer/.lake/build/bin/downstream.exe"
  if objdump -p "$exe" | grep -Eiq 'csdp_bridge\.dll|libInit_shared\.dll'; then
    echo "Windows native executable imported the interpreter runtime"
    objdump -p "$exe" | grep -i 'DLL Name' || true
    exit 1
  fi
fi

# A direct Lean invocation is valid when it consumes the setup data Lake made
# for the module. This is the same native-loading path used by Lake's driver.
lake env lean DownstreamTest.lean \
  --setup=.lake/build/ir/DownstreamTest.setup.json

# Model restoring platform-independent consumer oleans without a provider
# native artifact. Lake must recreate CSDP's platform artifact while leaving
# the already valid consumer module untouched.
dynlib="$(find "$repo_root/.lake/build/lib" -maxdepth 1 -type f \
  \( -name 'libcsdp.so' -o -name 'libcsdp.dylib' \
     -o -name 'csdp_bridge.dll' \) \
  -print -quit)"
if [[ -z "$dynlib" ]]; then
  echo "could not find the CSDP provider's native artifact"
  exit 1
fi
rm -f "$dynlib"
rebuild_log="$(lake build DownstreamPlain 2>&1)"
printf '%s\n' "$rebuild_log"
if [[ ! -f "$dynlib" ]]; then
  echo "Lake did not restore the missing platform-specific CSDP artifact"
  exit 1
fi
if grep -Eq 'Built DownstreamPlain|Building DownstreamPlain' \
    <<<"$rebuild_log"; then
  echo "platform-specific CSDP restoration unnecessarily rebuilt the portable consumer olean"
  exit 1
fi

echo "PASS: downstream consumers need no native flags, and CSDP's platform artifact restores independently."
