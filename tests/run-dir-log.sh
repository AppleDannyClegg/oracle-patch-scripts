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
# And the other way (Nexus #15877): a LOG_FILE inherited from the environment with no --run-dir is not a run. The
# command must still make its own run dir under RUN_BASE, with its log and state there, not write to that file.
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

# probe <given|inherited> <script> <command> <the call after the run-dir set-up, stubbed> [args...]: prints
# "RUN=<dir> LOG=<file> STATE=<file>" as the command saw them at that call
probe() {
  local how="$1" s="$2" cmd="$3" next="$4"; shift 4
  (
    export ORACLE_OUTPUT_DIR="$T/out" RUN_BASE="$T/base/$s"
    if [ "$how" = inherited ]; then export LOG_FILE="$T/inherited.log"; unset RUN_DIR; fi
    # shellcheck disable=SC1090
    . "$T/patching/$s/$s.sh" >/dev/null 2>&1
    setup_env() { :; }
    eval "$next() { printf 'RUN=%s LOG=%s STATE=%s\n' \"\$RUN_DIR\" \"\$LOG_FILE\" \"\$STATE_FILE\"; exit 0; }"
    if [ "$how" = given ]; then RUN_DIR="$T/runs/$s-$cmd"; LOG_FILE=""; fi
    ARGS=("$@")
    "cmd_$cmd" 2>&1
  ) | sed -n 's/^RUN=/RUN=/p' | tail -1
}
case_() { # <script> <command> <next> [args...]: given --run-dir, then an inherited LOG_FILE
  local s="$1" cmd="$2" got want; shift 2
  want="RUN=$T/runs/$s-$cmd LOG=$T/runs/$s-$cmd/$s.log STATE=$T/runs/$s-$cmd/state"
  got="$(probe given "$s" "$cmd" "$@")"
  [ "$got" = "$want" ] && [ -f "$T/runs/$s-$cmd/$s.log" ] && ok || bad "$s $cmd --run-dir: [$got], want [$want] and the log file"
  got="$(probe inherited "$s" "$cmd" "$@")"
  local run="${got#RUN=}"; run="${run%% LOG=*}"
  case "$run" in "$T/base/$s/"*-"$cmd") r=0 ;; *) r=1 ;; esac
  [ "$r" = 0 ] && [ "$got" = "RUN=$run LOG=$run/$s.log STATE=$run/state" ] && [ -f "$run/$s.log" ] && ok \
    || bad "$s $cmd with LOG_FILE inherited and no --run-dir: [$got], want a fresh run under $T/base/$s with its own log and state"
}
case_ db-patch latest mos_login
case_ db-patch download die "$T/dl"
case_ db-patch preflight prepare_patch_dir "$T/p"
for c in plan preflight backup apply; do case_ cert-renew "$c" find_tools listener; done
r=0; [ ! -s "$T/inherited.log" ] || r=1; [ "$r" = 0 ] && ok || bad "a command wrote to the inherited LOG_FILE: $(head -2 "$T/inherited.log")"

echo "run-dir-log gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
