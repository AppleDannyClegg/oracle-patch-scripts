#!/usr/bin/env bash
# get-mos-token gate: run the script's own -SelfTest, which pins Test-TokenShape and Get-JwtExpiry against
# fixed inputs with no network. Skipped with a notice when pwsh is absent (the repo's tests are bash-first),
# and a skip is not counted as a pass.
#
# Usage: tests/get-mos-token.sh [repo-root]

set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
S="$ROOT/patching/get-mos-token.ps1"
[ -f "$S" ] || { echo "get-mos-token gate: $S not found"; exit 2; }

pwsh="$(command -v pwsh || command -v powershell || true)"
if [ -z "$pwsh" ]; then
  echo "get-mos-token gate: skip - pwsh/powershell not installed, -SelfTest not run (not a pass)"
  exit 0
fi

out="$("$pwsh" -NoProfile -File "$S" -SelfTest 2>&1)"; rc=$?
printf '%s\n' "$out"
if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q 'get-mos-token selftest ok'; then
  echo "get-mos-token gate: ok"
else
  echo "get-mos-token gate: FAILED (rc $rc)"
  exit 1
fi
