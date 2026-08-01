#!/usr/bin/env bash
set -euo pipefail

real_cc=${CSDP_REAL_CC:?CSDP_REAL_CC is required}
expected_tmp=${CSDP_EXPECTED_LINK_TMP:?CSDP_EXPECTED_LINK_TMP is required}

is_compile=false
for arg in "$@"; do
  if [[ "$arg" == "-c" ]]; then
    is_compile=true
    break
  fi
done

if [[ "$is_compile" == true ]]; then
  TMPDIR="$expected_tmp" TMP="$expected_tmp" TEMP="$expected_tmp" \
    exec "$real_cc" "$@"
fi

if [[ "${TMPDIR:-}" != "$expected_tmp" ]]; then
  echo "CSDP linker did not receive its package-local TMPDIR" >&2
  echo "expected: $expected_tmp" >&2
  echo "actual:   ${TMPDIR:-<unset>}" >&2
  exit 1
fi

exec "$real_cc" "$@"
