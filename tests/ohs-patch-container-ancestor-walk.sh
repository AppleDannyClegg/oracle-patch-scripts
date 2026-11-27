#!/usr/bin/env bash
# The no-curl/no-ps container pass must still run the ancestor-walk assertions.
# Before the fix its summary is 212 passed, 1 failed on oraclelinux:8.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
out="$(bash "$REPO/tests/ohs-patch-container.sh" 2>&1)"
printf '%s\n' "$out" | grep -E '^--- (normal|hidden):|container gate:'
summary="$(printf '%s\n' "$out" | grep -E '^--- hidden: ohs-patch gate:' | tail -1)"
printf '%s\n' "$summary" | grep -qE '[0-9]+ passed, 0 failed' || { echo "FAIL: hidden pass did not run the ancestor walk green"; exit 1; }
echo "OK: hidden pass ran the ancestor walk green"
