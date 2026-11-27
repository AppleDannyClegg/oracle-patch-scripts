#!/usr/bin/env bash
# The container lane must RUN the zip fixture cases in both passes.
# Before the fix the summaries are 205/0/3 and 204/1/3 ("no unzip"), so this fails.
# The hidden-mode T1529 failure is pre-existing on oraclelinux:8 and out of scope.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
out="$(bash "$REPO/tests/ohs-patch-container.sh" 2>&1)"
printf '%s\n' "$out" | grep -E '^--- (normal|hidden):|container gate:'
if printf '%s\n' "$out" | grep -q 'no unzip in this image'; then
  echo "FAIL: zip cases were skipped - no unzip in the image"; exit 1
fi
if printf '%s\n' "$out" | grep -E '^--- (normal|hidden):' | grep -qvE '[0-9]+ passed, [0-9]+ failed(, 0 skipped)?'; then
  echo "FAIL: a lane pass still had skips"; exit 1
fi
if ! printf '%s\n' "$out" | grep -qE '^--- normal: ohs-patch gate: [0-9]+ passed, 0 failed(, 0 skipped)?$'; then
  echo "FAIL: normal pass did not run the zip cases green"; exit 1
fi
echo "OK: both lane passes ran every case (no skips); pre-existing hidden T1529 excluded"
