#!/usr/bin/env bash
# T3039 red test: the container lane must RUN the zip cases in both passes.
# On main before this change the summaries are 205/0/3 and 204/1/3 ("no unzip").
# T1529 in hidden mode is pre-existing on oraclelinux:8 and is not this row's scope.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
out="$(bash "$REPO/tests/ohs-patch-container.sh" 2>&1)"
printf '%s\n' "$out" | grep -E '^--- (normal|hidden):|container gate:'
if printf '%s\n' "$out" | grep -q 'no unzip in this image'; then
  echo "FAIL: zip cases were skipped - no unzip in the image"; exit 1
fi
# A zero-skipped pass omits the "skipped" clause entirely, so accept no clause or "0 skipped".
if printf '%s\n' "$out" | grep -E '^--- (normal|hidden):' | grep -qvE '[0-9]+ passed, [0-9]+ failed(, 0 skipped)?'; then
  echo "FAIL: a lane pass still had skips"; exit 1
fi
if ! printf '%s\n' "$out" | grep -qE '^--- normal: ohs-patch gate: [0-9]+ passed, 0 failed(, 0 skipped)?$'; then
  echo "FAIL: normal pass did not run the zip cases green"; exit 1
fi
echo "OK: both lane passes ran every case (no skips); pre-existing hidden T1529 excluded"
