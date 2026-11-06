#!/bin/bash
# run-all.sh [-j N] [--timeout SECS] [gate ...]
# Run the offline gates, at most N at a time, each with a wall-clock limit, and print each one's last line,
# its time and its exit code.
#
#   -j N         how many gates run at once (default $JOBS, else 4). Three seats running this at once on one
#                box is what took it to load 60 on 10 cores, and the runs came back 143 with no tally.
#   --timeout N  kill a gate that runs longer than N seconds (default $GATE_TIMEOUT, else 300), so a gate
#                that hangs reports instead of holding the harness open with nothing printed.
#
# No gates named = every gate below. The docker gates (oracle-free-container, okv-diag) are not here: run those alone.
# Every gate here works in its own mktemp dir, so they can run side by side. Exit 1 if any gate printed FAIL,
# reported "N failed" with N > 0, exited non-zero, or timed out.
cd "$(dirname "$0")/.." || exit 1

JOBS="${JOBS:-4}"
GATE_TIMEOUT="${GATE_TIMEOUT:-300}"
while [ $# -gt 0 ]; do
    case "$1" in
        -j | --timeout)
            [ -n "${2:-}" ] || { echo "run-all.sh: $1 needs a number" >&2; exit 2; }
            if [ "$1" = -j ]; then JOBS="$2"; else GATE_TIMEOUT="$2"; fi
            shift 2 ;;
        -j*)         JOBS="${1#-j}"; shift ;;
        --timeout=*) GATE_TIMEOUT="${1#--timeout=}"; shift ;;
        --)          shift; break ;;
        -*)          echo "run-all.sh: unknown option '$1'" >&2; exit 2 ;;
        *)           break ;;
    esac
done
case "$JOBS" in '' | *[!0-9]* | 0) echo "run-all.sh: -j needs a positive number, not '$JOBS'" >&2; exit 2 ;; esac
case "$GATE_TIMEOUT" in '' | *[!0-9]* | 0) echo "run-all.sh: --timeout needs a positive number of seconds, not '$GATE_TIMEOUT'" >&2; exit 2 ;; esac

GATES=(wls-quarter java-patch-will-stop wls-patch-spb dry-run-gate false-success-gate self-contained-gate
    secret-argv-gate java-patch-cacerts java-patch-inplace java-patch db-patch-opatch-min db-patch-ru-title
    get-download-guard check-parse optchk-gate unreadable-gate patch-manifest patch-status-oracle-home
    patch-status-unknown-level ru-date oem-standby-lag okv-rotate obic-diag ohs-patch wls-patch-conflict wls-patch-discovery db-patch-opatch-kit wls-version file-patterns jdk-version patch-base run-all-harness)
[ $# -gt 0 ] && GATES=("$@")
# the two extra jobs are only added where they can run: a copy of this tree (tests/run-all-harness.sh) has neither
if command -v pwsh >/dev/null 2>&1 && [ -f tests/get-patches.ps1 ]; then GATES+=(get-patches); fi
if command -v shellcheck >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then GATES+=(shellcheck); fi

out="$(mktemp -d)"; trap 'rm -rf "$out"' EXIT
start=$SECONDS
echo "run-all: ${#GATES[@]} gates, at most $JOBS at a time, ${GATE_TIMEOUT}s limit each"

# one gate, killed if it outlives $GATE_TIMEOUT. Killed means: marked, reported, and counted as a failure -
# a gate that prints nothing for that long is hung, or starved by more work than the box can carry
run_limited() {                     # run_limited <name> <command...>
    local name="$1"; shift
    "$@" </dev/null >"$out/$name.log" 2>&1 &
    local pid=$! wd rc i=0
    # the watchdog polls rather than sleeping the full limit, so it exits within a second of the gate ending
    # instead of lingering; its output goes to /dev/null so it cannot hold the caller's pipe open
    ( while [ "$i" -lt "$GATE_TIMEOUT" ]; do
          kill -0 "$pid" 2>/dev/null || exit 0
          sleep 1; i=$((i + 1))
      done
      : >"$out/$name.timedout"
      kill -TERM "$pid" 2>/dev/null
      sleep 5
      kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    wd=$!
    wait "$pid" 2>/dev/null
    rc=$?
    kill "$wd" 2>/dev/null
    wait "$wd" 2>/dev/null
    if [ -f "$out/$name.timedout" ]; then
        echo "gate timed out after ${GATE_TIMEOUT}s - killed (a gate that prints nothing for that long is hung, or the box is overloaded)" >>"$out/$name.log"
    fi
    return $rc
}

# start one gate, first waiting for a free slot when $JOBS are already running
launch() {                          # launch <name> <command...>
    local name="$1"; shift
    ( s=$SECONDS; run_limited "$name" "$@"; echo "$? $((SECONDS - s))" >"$out/$name.rc" ) &
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
for g in "${GATES[@]}"; do
    read -r rc secs <"$out/$g.rc"
    last="$(tail -1 "$out/$g.log")"
    mark=ok
    if [ "$rc" != 0 ] || [ -f "$out/$g.timedout" ] || grep -q '^FAIL' "$out/$g.log" || printf '%s' "$last" | grep -qE '[1-9][0-9]* failed'; then mark=FAIL; bad=1; fi
    printf '%-4s %-26s %4ss rc=%s  %s\n' "$mark" "$g" "$secs" "$rc" "$(printf '%s' "$last" | cut -c1-110)"
    [ "$mark" = FAIL ] && grep -E '^FAIL' "$out/$g.log" | head -5 | sed 's/^/       /'
done
echo "all gates: $((SECONDS - start))s wall"
exit $bad
