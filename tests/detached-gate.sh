#!/usr/bin/env bash
# detached-gate.sh - a patch run must not die with the terminal it was started from.
#
# Measured 6 Nov 2026: a run was stopped when the operator left the machine, luckily between steps. So
# require_detached() (lib/oracle-lib.sh) ignores SIGHUP for the rest of the run, and refuses to start a
# change-making run from an interactive shell unless it is detached (tmux/screen/nohup).
#
# Usage: tests/detached-gate.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

# rc of require_detached run, in a subshell, with the environment the case wants
try() { ( . ./lib/oracle-lib.sh >/dev/null 2>&1; eval "$1"; require_detached run ) >/dev/null 2>&1; echo $?; }

# ---- the decision ----
[ "$(try 'export TMUX=x')" = 0 ] && ok || bad "a tmux session is accepted"
[ "$(try 'export STY=x')" = 0 ] && ok || bad "a screen session is accepted"
[ "$(try 'export PATCH_DETACHED=1')" = 0 ] && ok || bad "PATCH_DETACHED=1 is accepted"
[ "$(try 'export DRY_RUN=1 PATCH_INTERACTIVE=1')" = 0 ] && ok || bad "a dry run is always allowed - it changes nothing"
[ "$(try 'true')" = 0 ] && ok || bad "a non-interactive caller (a gate, cron, nohup) is left alone"
[ "$(try 'export PATCH_INTERACTIVE=1')" != 0 ] && ok || bad "an interactive shell without tmux/screen/nohup is REFUSED"

# ---- the refusal has to teach ----
msg="$( ( . ./lib/oracle-lib.sh >/dev/null 2>&1; export PATCH_INTERACTIVE=1; require_detached run ) 2>&1 )"
printf '%s' "$msg" | grep -q 'tmux' && ok || bad "the refusal names tmux"
printf '%s' "$msg" | grep -q 'nohup' && ok || bad "the refusal names nohup"
printf '%s' "$msg" | grep -q 'mid-step' && ok || bad "the refusal says what the risk is"

# ---- every patch command that changes a host asks first ----
for f in patching/*/*.sh; do
    grep -q '^cmd_run() {' "$f" || continue
    grep -q 'require_detached run' "$f" && ok || bad "$f: cmd_run does not call require_detached"
done

# ---- HUP is ignored for the rest of the run, even when it goes ahead ----
hup_ignored=$(bash -c '. ./lib/oracle-lib.sh >/dev/null 2>&1; export PATCH_DETACHED=1; require_detached run; trap -p HUP' 2>/dev/null | grep -c "HUP")
[ "$hup_ignored" -ge 1 ] && ok || bad "require_detached leaves SIGHUP ignored"

echo "detached gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
