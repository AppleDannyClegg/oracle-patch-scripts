#!/usr/bin/env bash
# RUN_DIR/LOG_FILE/ARGS are read by the sourced script, which also calls the stubs
# shellcheck disable=SC2034,SC2329,SC2015
# run-dir-log.sh - a --run-dir given to db-patch.sh or cert-renew.sh still sets up that run's log (T1106).
#
# wls-patch.sh set up the run dir, and with it LOG_FILE, only when RUN_DIR was empty, so with --run-dir the log
# stayed "" and the first >>"$LOG_FILE" failed: 'line 536: : No such file or directory' on a field run (708eaae).
# db-patch.sh and cert-renew.sh had the same guard (Nexus #15824): db-patch preflight writes >>"$LOG_FILE" and
# cert-renew apply 2>>"$LOG_FILE". Each command here is run as given --run-dir, up to the first call after its
# run-dir set-up, which is stubbed to report LOG_FILE and stop: the log must be <run-dir>/<tool>.log, and exist.
#
# Sources the real scripts (less their trailing main call) in a copy of the tree, as db-patch-opatch-min.sh does.
# Usage: tests/run-dir-log.sh [repo-root]
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/rdlog.XXXXXX")" && pwd -P)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

mkdir -p "$T/lib"; cp "$ROOT/lib/oracle-lib.sh" "$T/lib/"
for s in db-patch cert-renew; do mkdir -p "$T/patching/$s"; sed '$d' "$ROOT/patching/$s/$s.sh" >"$T/patching/$s/$s.sh"; done

# case <script> <command> <the call after the run-dir set-up, stubbed> [args...]
case_() {
  local s="$1" cmd="$2" next="$3"; shift 3
  local given="$T/runs/$s-$cmd" out
  out="$(
    export OUTPUT_DIR="$T/out"
    # shellcheck disable=SC1090
    . "$T/patching/$s/$s.sh" >/dev/null 2>&1
    setup_env() { :; }
    eval "$next() { printf 'LOG=%s\n' \"\$LOG_FILE\"; exit 0; }"
    RUN_DIR="$given"; LOG_FILE=""; ARGS=("$@")
    "cmd_$cmd" 2>&1
  )"
  local log; log="$(printf '%s\n' "$out" | sed -n 's/^LOG=//p' | tail -1)"
  [ "$log" = "$given/$s.log" ] && [ -f "$log" ] && ok || bad "$s $cmd --run-dir: LOG_FILE [$log], want $given/$s.log (and the file): $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
}
case_ db-patch latest mos_login
case_ db-patch download die "$T/dl"
case_ db-patch preflight prepare_patch_dir "$T/p"
for c in plan preflight backup apply; do case_ cert-renew "$c" find_tools listener; done

echo "run-dir-log gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
