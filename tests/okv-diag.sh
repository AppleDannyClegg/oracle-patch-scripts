#!/usr/bin/env bash
# okv-diag.sh - behavioural + portability gate for reports/okv-diag/okv-diag.sh.
#
# Three ways the OKV client check can lie, none of which tests/oracle-free-container.sh can see (the image runs
# Oracle Linux / GNU sed, and a container is never signalled):
#  - a named port must be probed. BSD sed has no BRE '\+', so 'sed -n ...\([0-9]\+\).*' silently fails there,
#    the port falls through to the 5696 default and a healthy endpoint is reported unreachable (TARS/Jocasta/
#    Vision, 3 Nov). The failure is invisible on GNU sed, so it is guarded statically as well as behaviourally.
#  - a config with no SERVER= must be a CRIT (nothing was probed), never a clean exit 0 (Vision, 3 Nov).
#  - a signal must STOP the run: INT -> 130, TERM -> 143. A handler that runs the cleanup but does not exit
#    swallows the signal and the script finishes as if it had succeeded (Cortex, 3 Nov).
#
# No database, no docker: local temp OKV homes. The server probe is real (a refused/hung TCP connect), so the
# reachability line's port is the script's own, not something the gate substituted.
#
# Usage: tests/okv-diag.sh [repo-root]
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SH="$ROOT/reports/okv-diag/okv-diag.sh"
[ -f "$SH" ] || { echo "okv-diag gate: $SH not found"; exit 2; }
pass=0; fail=0
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ok() { pass=$((pass + 1)); }
no() { fail=$((fail + 1)); echo "FAIL $*"; }

# mkfixture <dir> <SERVER= line>: a minimal OKV home; the okvutil stub fails the way an unenrolled client does.
mkfixture() {
  mkdir -p "$1/conf" "$1/ssl" "$1/bin"
  { printf 'SSL_WALLET_LOC=%s/ssl\n' "$1"; [ -n "$2" ] && printf '%s\n' "$2"; } >"$1/conf/okvclient.ora"
  : >"$1/ssl/ewallet.p12"
  printf '#!/bin/sh\necho "OKV-00001: Cannot connect to the Oracle Key Vault server"\n' >"$1/bin/okvutil"
  chmod +x "$1/bin/okvutil"
}

# 1. an explicit SERVER=host:PORT is probed on PORT (5999), not the 5696 default. Accept OK or UNREACHABLE: the
#    assertion is the port, so the gate needs no listener. Port 1 would be instant-refused on any host.
mkfixture "$T/a" 'SERVER=127.0.0.1:5999'
OKV_OUT="$T/out-a" bash "$SH" --okv-home "$T/a" --no-tar --quiet >/dev/null 2>&1
reach="$(cat "$T"/out-a/*/raw/okv_reach_*.txt 2>/dev/null)"
if printf '%s\n' "$reach" | grep -qE '^  127\.0\.0\.1:5999 (OK|UNREACHABLE)$'; then ok
else no "named port: reachability did not probe 127.0.0.1:5999 (the 5696 default means the port parse failed):"; printf '%s\n' "$reach" | sed 's/^/    /'; fi

# 1b. portability guard: the failure above is invisible on GNU sed, so forbid the construct outright in CODE
#     (comment lines may name it - line 55 does, to explain this gate).
if grep -v '^[[:space:]]*#' "$SH" | grep 'sed' | grep -qF '\+'; then no "portability: a sed BRE '\+' in ${SH#"$ROOT"/} is GNU-only (BSD sed never matches; use sed -nE)"; else ok; fi

# 2. no SERVER= is a CRIT and rc=2, not the WARN-and-return-0 that let an unprobed config look clean.
mkfixture "$T/b" ''
OKV_OUT="$T/out-b" bash "$SH" --okv-home "$T/b" --no-tar --quiet >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ] && grep -q 'has no usable SERVER= line' "$T"/out-b/*/REPORT.md 2>/dev/null; then ok
else no "no-SERVER=: rc=$rc (want 2) and/or no 'has no usable SERVER= line' CRIT in REPORT.md"; fi

# 2b. if --okv-home was given, the no-okvclient.ora message names the path, not a flag already passed.
OKV_OUT="$T/out-b2" bash "$SH" --okv-home "$T/absent" --no-tar --quiet >/dev/null 2>&1
grep -q "no okvclient.ora under --okv-home $T/absent" "$T"/out-b2/*/REPORT.md 2>/dev/null && ok || no "okv-home message does not name $T/absent"

# 3. TERM stops the run (rc=143) instead of falling through. The okvutil stub sleeps, so the signal lands in a
#    deterministic window rather than racing the probe's 5s timeout.
mkfixture "$T/c" 'SERVER=127.0.0.1:1'
printf '#!/bin/sh\nsleep 10\n' >"$T/c/bin/okvutil"; chmod +x "$T/c/bin/okvutil"
OKV_OUT="$T/out-c" bash "$SH" --okv-home "$T/c" --no-tar --quiet >/dev/null 2>&1 &
pid=$!; sleep 1; kill -TERM "$pid" 2>/dev/null; wait "$pid"; rc=$?
[ "$rc" = 143 ] && ok || no "signal: TERM gave rc=$rc (want 143) - the handler swallowed the signal and the run continued"

echo "okv-diag gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
