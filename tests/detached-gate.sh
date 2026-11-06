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

# ---- every patch command that changes a host asks first, AND defines the guard it calls ----
# A call with no definition is `command not found`: set -u does not stop it, no -e means the 127 is swallowed,
# and the run goes ahead unrefused. Found on ohs-patch (Gort, 6 Nov) after the call was added without the copy.
libdef=$(grep -c '^require_detached()' lib/oracle-lib.sh)
[ "$libdef" = 1 ] && ok || bad "lib/oracle-lib.sh does not define require_detached"
for f in patching/*/*.sh; do
    grep -q '^cmd_run() {' "$f" || continue
    name=$(basename "$f" .sh)
    grep -q 'require_detached run' "$f" && ok || bad "$f: cmd_run does not call require_detached"
    if grep -q 'oracle-lib.sh' "$f"; then
        ok   # sources lib: it gets the definition from there
    else
        # self-contained: it must carry its own copy, or the call is a no-op
        grep -q '^require_detached()' "$f" && ok || bad "$f: calls require_detached but defines nothing and sources no lib - the call is a no-op"
    fi

    # THE HINT MUST PRINT A COMMAND THAT RUNS. The refusal suggests `nohup <script> <action> ...`; three copies
    # printed `nohup $what ...`, i.e. 'nohup run', which loses the script name and cannot be run at all. Assert
    # the property (the command names the script), not the text of the line.
    msg="$(PATCH_INTERACTIVE=1 bash "$f" run /nonexistent-dir 2>&1)"
    hinted="$(printf '%s\n' "$msg" | sed -n 's/^ *nohup \([^ ]*\).*/\1/p' | head -1)"
    if [ -z "$hinted" ]; then
        ok   # no hint printed: the guard did not fire for this script, which the earlier assertions cover
    elif { case "$hinted" in */*) [ -x "$hinted" ] ;; *) command -v "$hinted" >/dev/null 2>&1 ;; esac; }; then
        ok   # the suggested command RESOLVES, which is the property - a basename that is not on PATH is not runnable
    else
        bad "$f: the detachment hint suggests 'nohup $hinted ...' - that does not resolve to a runnable command"
    fi
done

# ---- a command runner must not inherit a terminal it will not read from ----
# A runner that hands its child the terminal blocks forever on a prompt when the run is unattended (tmux, nohup,
# a cron job) and, in ohs-patch's case, sends the prompt to a log nobody is reading. lib's own run_sh already
# redirects stdin; these four did not. Found by property (Edi), not by name - the grep for 'do_cmd' found one.
while IFS= read -r hit; do
    f="${hit%%:*}"; line="${hit#*:}"
    case "$line" in *'</dev/null'*) ok ;; *) bad "$f: a command runner inherits stdin - an unattended run blocks on a prompt: $line" ;; esac
done < <(grep -rnE '"\$@" 2>&1 \| tee -a|"\$@" >>' --include='*.sh' patching reports lib | grep -v 'tests/')

# ---- HUP is ignored for the rest of the run, even when it goes ahead ----
hup_ignored=$(bash -c '. ./lib/oracle-lib.sh >/dev/null 2>&1; export PATCH_DETACHED=1; require_detached run; trap -p HUP' 2>/dev/null | grep -c "HUP")
[ "$hup_ignored" -ge 1 ] && ok || bad "require_detached leaves SIGHUP ignored"

echo "detached gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
