#!/bin/bash
# run-all.sh [-j N] [--timeout SECS] [gate ...]
# Run the offline gates, at most N at a time, each with a wall-clock limit, and print each one's last line,
# its time and its exit code.
#
#   -j N         how many gates run at once (default $JOBS, else 4). Three seats running this at once on one
#                box is what took it to load 60 on 10 cores, and the runs came back 143 with no tally.
#   --timeout N  kill a gate that runs longer than N seconds (default $GATE_TIMEOUT, else 300), so a gate
#                that hangs reports instead of holding the harness open with nothing printed. It is sent TERM
#                at N seconds and KILL 5s later, so the wall limit on an unkillable gate is N+5.
#   --log PATH   also write the transcript (header, every gate as it finishes, the summary) to PATH. Without it
#                the transcript lives in the run's temp dir: kept when the run fails, deleted when it passes.
#
# No gates named = every gate below. The docker gates (oracle-free-container, okv-diag) are not here: run those alone.
# Every gate here works in its own mktemp dir, so they can run side by side. Exit 1 if any gate printed FAIL,
# reported "N failed" with N > 0, exited non-zero, or timed out.
cd "$(dirname "$0")/.." || exit 1

JOBS="${JOBS:-4}"
GATE_TIMEOUT="${GATE_TIMEOUT:-300}"
LOG="${LOG:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        -j | --timeout)
            [ -n "${2:-}" ] || { echo "run-all.sh: $1 needs a number" >&2; exit 2; }
            if [ "$1" = -j ]; then JOBS="$2"; else GATE_TIMEOUT="$2"; fi
            shift 2 ;;
        -j*)         JOBS="${1#-j}"; shift ;;
        --timeout=*) GATE_TIMEOUT="${1#--timeout=}"; shift ;;
        --log | -l)  [ -n "${2:-}" ] || { echo "run-all.sh: $1 needs a path" >&2; exit 2; }; LOG="$2"; shift 2 ;;
        --log=*)     LOG="${1#--log=}"; shift ;;
        --)          shift; break ;;
        -*)          echo "run-all.sh: unknown option '$1'" >&2; exit 2 ;;
        *)           break ;;
    esac
done
case "$JOBS" in '' | *[!0-9]* | 0) echo "run-all.sh: -j needs a positive number, not '$JOBS'" >&2; exit 2 ;; esac
case "$GATE_TIMEOUT" in '' | *[!0-9]* | 0) echo "run-all.sh: --timeout needs a positive number of seconds, not '$GATE_TIMEOUT'" >&2; exit 2 ;; esac

GATES=(output-dir wls-quarter ohs-quarter ohs-quarter-stage java-patch-will-stop wls-patch-spb dry-run-gate false-success-gate self-contained-gate
    secret-argv-gate java-patch-cacerts java-patch-inplace java-patch db-patch-opatch-min db-patch-ru-title
    get-download-guard check-parse optchk-gate unreadable-gate patch-manifest patch-status-oracle-home
    patch-status-unknown-level ru-date oem-standby-lag okv-rotate obic-diag ohs-patch dbclient-upgrade wls-patch-conflict wls-patch-discovery db-patch-opatch-kit wls-version file-patterns jdk-version patch-base run-all-harness detached-gate)
# add_gate skips a gate that is already in the list. Every entry goes through it - the typed list as well as the
# two auto-appends - because two entries for one name run it twice over the same log and rc file, and a passing
# copy then overwrites a failing copy's tally. One name, one launch, one file.
add_gate() {
    case " ${GATES[*]} " in *" $1 "*) return ;; esac
    GATES+=("$1")
}
if [ $# -gt 0 ]; then GATES=(); for g in "$@"; do add_gate "$g"; done; fi
# the two extra jobs are only added where they can run: a copy of this tree (tests/run-all-harness.sh) has neither
if command -v pwsh >/dev/null 2>&1 && [ -f tests/get-patches.ps1 ]; then add_gate get-patches; fi
if command -v shellcheck >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then add_gate shellcheck; fi

out="$(mktemp -d)"
transcript="$out/run-all.log"
say() { printf '%s\n' "$*"; printf '%s\n' "$*" >>"$transcript"; }
# a failing run keeps its per-gate logs: the summary shows one line per gate, and a red you cannot re-read is
# half a red. A clean run deletes them as before
# stop_all: the gate the harness can see in `running` is the launch subshell, not the gate itself - the gate
# leads its own process group (set -m inside run_limited), so that pid is recorded to $out/<key>.pid and the
# groups are what get signalled here. Without this, Ctrl-C or a pkill leaves every gate loading the box until
# its own deadline fires - up to --timeout + 5s per gate.
stop_all() {
    local f pid
    for f in "$out"/*.pid; do
        [ -f "$f" ] || continue
        pid="$(cat "$f" 2>/dev/null)"
        [ -n "$pid" ] || continue
        if [ "$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" = "$pid" ]; then kill -TERM -"$pid" 2>/dev/null
        else kill -TERM "$pid" 2>/dev/null; fi
    done
    for pid in "${running[@]:-}"; do [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null; done
}
# report: one row per gate that was launched (a real rc, or "interrupted" when stop_all killed it before its
# .rc was written - never the previous row's rc, which is what `read` leaves behind on a missing file), then the
# gates that never launched. Called from the normal path and from the stop handler, so an aborted run still says
# what it got through.
report() {
    local key g rc secs last mark started names line
    say ''
    say '=== summary ==='
    for key in "${order[@]}"; do
        g="${key#*.}"
        rc=interrupted; secs=-
        read -r rc secs 2>/dev/null <"$out/$key.rc"
        last=''
        [ -f "$out/$key.log" ] && last="$(tail -1 "$out/$key.log" 2>/dev/null)"
        mark=ok
        if [ "$rc" != 0 ] || [ -f "$out/$key.timedout" ] ||
            { [ -f "$out/$key.log" ] && grep -q '^FAIL' "$out/$key.log"; } ||
            printf '%s' "$last" | grep -qE '[1-9][0-9]* failed'; then mark=FAIL; bad=1; fi
        # the mark says who stopped it, the rc says how: a gate the operator stopped did not fail
        [ "$rc" = interrupted ] && { mark=INT; bad=1; }
        if [ "$secs" = - ]; then
            line="$(printf '%-4s %-26s %6s rc=%s  %s' "$mark" "$g" "$secs" "$rc" "$(printf '%s' "$last" | cut -c1-110)")"
        else
            line="$(printf '%-4s %-26s %4ss rc=%s  %s' "$mark" "$g" "$secs" "$rc" "$(printf '%s' "$last" | cut -c1-110)")"
        fi
        say "$line"
        if [ "$mark" = FAIL ] && [ -f "$out/$key.log" ]; then
            grep -E '^FAIL' "$out/$key.log" | head -5 | sed 's/^/       /' | while IFS= read -r l; do say "$l"; done
        fi
    done
    started=''
    for key in "${order[@]}"; do started="$started ${key#*.}"; done
    names=''
    for g in "${GATES[@]}"; do
        case " $started " in *" $g "*) ;; *) names="$names $g" ;; esac
    done
    [ -n "$names" ] && say "not started (stopped before launching):$names"
    say "all gates: $((SECONDS - start))s wall"
    say "finished $(date '+%Y-%m-%d %H:%M:%S')"
    # --log keeps a copy wherever the caller asked; without it the transcript lives in the temp dir, which the
    # EXIT trap keeps on failure and deletes on success
    if [ -n "$LOG" ]; then cp "$transcript" "$LOG" 2>/dev/null && say "transcript: $LOG"; fi
}

# TERM/INT must END the run, not just kill what is already running: stopping the live gates and then falling
# back into the launch loop starts the remaining ones, which is the same "I stopped it and it kept working"
# symptom one layer up. Exit from the handler, and keep the logs since the run did not finish.
on_stop() { stop_all; bad=1; report; exit 1; }
trap 'on_stop' TERM INT
trap 'stop_all; if [ "${bad:-0}" = 1 ]; then echo "logs kept: $out"; else rm -rf "$out"; fi' EXIT
start=$SECONDS
say "run-all: ${#GATES[@]} gates, at most $JOBS at a time, ${GATE_TIMEOUT}s limit each (TERM, then KILL 5s later)"
say "started $(date '+%Y-%m-%d %H:%M:%S')  host $(uname -n)  head $(git rev-parse --short HEAD 2>/dev/null || echo '-')  dir $PWD"
say "gates: ${GATES[*]}"

# one gate, killed if it outlives $GATE_TIMEOUT. Killed means: marked, reported, and counted as a failure -
# a gate that prints nothing for that long is hung, or starved by more work than the box can carry
run_limited() {                     # run_limited <key> <name> <command...>
    local key="$1" name="$2"; shift 2
    # own process group for this gate (bash 3.2 job control; there is no setsid on macOS), so the timeout can
    # kill the GROUP: killing the gate's shell alone leaves whatever the gate started running, which is how
    # last night ended with 34 orphaned gates holding a 10-core box at load 40+ after every harness was dead
    set -m
    "$@" </dev/null >"$out/$key.log" 2>&1 &
    local pid=$! wd rc i=0
    echo "$pid" >"$out/$key.pid"          # the gate, which leads its own group - what stop_all signals
    set +m
    # the watchdog polls rather than sleeping the full limit, so it exits within a second of the gate ending
    # instead of lingering; its output goes to /dev/null so it cannot hold the caller's pipe open
    ( while [ "$i" -lt "$GATE_TIMEOUT" ]; do
          kill -0 "$pid" 2>/dev/null || exit 0
          sleep 1; i=$((i + 1))
      done
      : >"$out/$key.timedout"
      # signal the group only when the gate really leads one; -pid means "process group pid", so a gate that
      # did not get its own group (set -m can decline) must be signalled by pid, not by a group id it does not own
      if [ "$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" = "$pid" ]; then
          kill -TERM -"$pid" 2>/dev/null
          sleep 5
          kill -KILL -"$pid" 2>/dev/null
      else
          kill -TERM "$pid" 2>/dev/null
          sleep 5
          kill -KILL "$pid" 2>/dev/null
      fi ) >/dev/null 2>&1 &
    wd=$!
    wait "$pid" 2>/dev/null
    rc=$?
    rm -f "$out/$key.pid"                 # gone, so stop_all cannot signal a reused pid
    kill "$wd" 2>/dev/null
    wait "$wd" 2>/dev/null
    # say which of the two kills ended it: the tally's rc=137 explains itself then, instead of reading as a crash
    if [ -f "$out/$key.timedout" ]; then
        if [ "$rc" = 137 ]; then
            echo "gate timed out: no output for ${GATE_TIMEOUT}s, then it ignored TERM for 5s and was KILLed - a gate that prints nothing for that long is hung, or the box is overloaded" >>"$out/$key.log"
        else
            echo "gate timed out: no output for ${GATE_TIMEOUT}s, killed with TERM - a gate that prints nothing for that long is hung, or the box is overloaded" >>"$out/$key.log"
        fi
    fi
    return $rc
}

# start one gate, first waiting for a free slot when $JOBS are already running. Each launch gets its own
# numbered log/rc/timedout, so "one launch, one file" holds whatever the gate list contains
launched=0
order=()
launch() {                          # launch <name> <command...>
    local name="$1"; shift
    launched=$((launched + 1))
    local key="$launched.$name"
    order+=("$key")
    ( s=$SECONDS; run_limited "$key" "$name" "$@"; rc=$?
      echo "$rc $((SECONDS - s))" >"$out/$key.rc"
      line="  .. $(printf '%-26s' "$name") $((SECONDS - s))s rc=$rc"
      printf '%s\n' "$line"; printf '%s\n' "$line" >>"$transcript" ) &
    running+=($!)
    while [ "${#running[@]}" -ge "$JOBS" ]; do
        wait "${running[0]}" 2>/dev/null
        running=("${running[@]:1}")
    done
}

running=()
for g in "${GATES[@]}"; do
    case "$g" in
        get-patches) launch "$g" pwsh -NoProfile -File tests/get-patches.ps1 ;;
        shellcheck)  launch "$g" bash -c 'git ls-files -z "*.sh" | xargs -0 shellcheck -S warning && echo "shellcheck clean (tree)"' ;;
        *)           launch "$g" bash "tests/$g.sh" ;;
    esac
done
wait

bad=0
report
exit $bad
