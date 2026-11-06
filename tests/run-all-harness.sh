#!/bin/bash
# run-all-harness.sh - the harness's own limits, tested against fake gates in a copy of the tree.
#
# Tonight three seats ran run-all at once, each spawning every gate at once, and the box went to load 60
# on 10 cores; the runs came back 143 with no tally. So the harness has to be able to share a machine:
#   -j N        at most N gates at a time
#   --timeout N a gate that outlives N seconds is killed and reported, not left holding the harness
# This gate copies run-all.sh into a temp tree with its own fake gates (run-all resolves tests/<gate>.sh
# relative to its own location, so the copy runs the fakes), and asserts both limits and the exit code.
#
# Run it with BOTH shells: /bin/bash is 3.2 on macOS and `bash` on PATH is 5.x. Everything here has to work on
# 3.2 (no `wait -n`, no associative arrays), so `bash tests/run-all-harness.sh` alone is only half the check.
#
# The harness's own temp dir cannot be isolated with TMPDIR: bash's mktemp on macOS ignores it (BSD mktemp uses
# confstr), so "logs kept: /var/folders/..." is where it always lands. To count temp dirs, shim mktemp on PATH.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0; fail=0
check() { if [ "$1" = 1 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $2"; fi }

mkdir -p "$tmp/tests"
cp "$root/tests/run-all.sh" "$tmp/tests/run-all.sh"
order="$tmp/order.txt"
: >"$order"
for n in a b c; do
    printf '#!/bin/bash\necho "start %s" >>"%s"; sleep 0.3; echo "end %s" >>"%s"\n' "$n" "$order" "$n" "$order" \
        >"$tmp/tests/gate-$n.sh"
    chmod +x "$tmp/tests/gate-$n.sh"
done
# 'exec sleep' so the gate pid IS the sleep, and the harness's kill lands on the process that is hanging
printf '#!/bin/bash\nexec sleep 60\n' >"$tmp/tests/gate-hang.sh"

run() { ( cd "$tmp" && bash tests/run-all.sh "$@" ); }

# ---- -j 1: gates must not overlap ----
out=$(run -j 1 gate-a gate-b gate-c 2>&1); rc=$?
check "$([ "$rc" = 0 ] && echo 1)" "-j 1 exits 0 (rc=$rc)"
check "$(printf '%s\n' "$out" | grep -q '3 gates, at most 1 at a time' && echo 1)" "-j 1 reports the cap in its header"
check "$([ "$(wc -l <"$order" | tr -d ' ')" = 6 ] && echo 1)" "-j 1 ran all three fake gates (got $(wc -l <"$order" | tr -d ' ') lines)"
interleaved=$(awk '$1 == "start" { if (prev == "start") bad = 1 } { prev = $1 } END { print bad + 0 }' "$order")
check "$([ "$interleaved" = 0 ] && echo 1)" "-j 1 did not overlap two gates (order: $(tr '\n' ' ' <"$order"))"

# ---- default: still runs every gate named ----
: >"$order"
out=$(run gate-a gate-b gate-c 2>&1); rc=$?
check "$([ "$rc" = 0 ] && echo 1)" "no -j exits 0 (rc=$rc)"
check "$([ "$(wc -l <"$order" | tr -d ' ')" = 6 ] && echo 1)" "no -j ran all three fake gates"

# ---- --timeout: a hung gate is killed, reported, and fails the run ----
before=$SECONDS
out=$(run --timeout 1 gate-hang 2>&1); rc=$?
took=$((SECONDS - before))
check "$([ "$rc" != 0 ] && echo 1)" "--timeout 1 with a hung gate exits non-zero (rc=$rc)"
check "$(printf '%s\n' "$out" | grep -q 'timed out: no output for 1s' && echo 1)" "--timeout 1 says the gate timed out, and how it was killed"
check "$(printf '%s\n' "$out" | grep -qE '^FAIL .*gate-hang' && echo 1)" "--timeout 1 marks the gate FAIL in the summary"
check "$([ "$took" -lt 30 ] && echo 1)" "--timeout 1 did not wait for the 60s gate (took ${took}s)"

# ---- --timeout kills the gate's CHILDREN too: one gate shell killed is how last night left 34 orphans ----
cat >"$tmp/tests/child-marker.sh" <<EOF
#!/bin/bash
echo \$\$ >"$tmp/child.pid"
sleep 600
EOF
cat >"$tmp/tests/gate-hang-children.sh" <<EOF
#!/bin/bash
bash "$tmp/tests/child-marker.sh" &
exec sleep 600
EOF
run --timeout 1 gate-hang-children >/dev/null 2>&1
sleep 2
child=$(cat "$tmp/child.pid" 2>/dev/null)
check "$([ -n "$child" ] && echo 1)" "the hang fixture started a child (pid '$child')"
check "$(kill -0 "$child" 2>/dev/null || echo 1)" "--timeout killed the gate's child (pid $child)"
survivors=$(pgrep -f "$tmp/tests/child-marker.sh" | wc -l | tr -d ' ')
check "$([ "$survivors" = 0 ] && echo 1)" "--timeout left no process of the gate's (survivors: $survivors)"
rm -f "$tmp/child.pid"

# ---- --timeout when the gate ignores TERM: the kill must not depend on the gate cooperating ----
cat >"$tmp/tests/child-stubborn.sh" <<EOF
#!/bin/bash
trap '' TERM
echo \$\$ >"$tmp/stubborn.pid"
sleep 600
EOF
cat >"$tmp/tests/gate-stubborn.sh" <<EOF
#!/bin/bash
trap '' TERM
bash "$tmp/tests/child-stubborn.sh" &
exec sleep 600
EOF
out=$(run --timeout 1 gate-stubborn 2>&1); rc=$?
hard=$(cat "$tmp/stubborn.pid" 2>/dev/null)
check "$([ "$rc" != 0 ] && echo 1)" "a gate that ignores TERM still fails the run (rc=$rc)"
check "$(printf '%s\n' "$out" | grep -q 'KILLed' && echo 1)" "the timeout message says it was KILLed, so rc=137 explains itself"
check "$(kill -0 "$hard" 2>/dev/null || echo 1)" "the TERM-ignoring child was KILLed too (pid $hard)"
rm -f "$tmp/stubborn.pid"

# ---- TERM to the harness stops its gates, not just the harness: otherwise a Ctrl-C leaves every gate ----
# ---- loading the box until its own deadline fires (up to --timeout + 5s each)                        ----
cat >"$tmp/tests/child-slow.sh" <<EOF
#!/bin/bash
echo \$\$ >"$tmp/slow.pid"
sleep 600
EOF
cat >"$tmp/tests/gate-slow.sh" <<EOF
#!/bin/bash
bash "$tmp/tests/child-slow.sh" &
wait
EOF
rm -f "$tmp/slow.pid"
( bash "$tmp/tests/run-all.sh" --timeout 600 gate-slow >/dev/null 2>&1 ) &
harness=$!
sleep 2
kill -TERM "$harness" 2>/dev/null
sleep 2
slow=$(cat "$tmp/slow.pid" 2>/dev/null)
check "$([ -n "$slow" ] && echo 1)" "the slow fixture started a child (pid '$slow')"
check "$(kill -0 "$slow" 2>/dev/null || echo 1)" "TERM to the harness killed the gate's child (pid $slow)"
kill -KILL "$slow" 2>/dev/null

# ---- TERM with gates still QUEUED: it must stop the run, not just the gate that is running ----
for q in gate-queue gate-queue2 gate-queue3; do
    cat >"$tmp/tests/$q.sh" <<EOF
#!/bin/bash
echo \$\$ >>"$tmp/queued.pids"
exec sleep 600
EOF
done
rm -f "$tmp/queued.pids"
( bash "$tmp/tests/run-all.sh" -j 1 --timeout 600 gate-queue gate-queue2 gate-queue3 >"$tmp/queued.out" 2>&1 ) &
harness=$!
sleep 2
kill -TERM "$harness" 2>/dev/null
sleep 3
out=$(cat "$tmp/queued.out" 2>/dev/null)
check "$(printf '%s\n' "$out" | grep -qE '^INT +gate-queue ' && echo 1)" "a stopped gate is marked INT, not FAIL: $(printf '%s' "$out" | grep -E '^(INT|FAIL)' | head -1)"
check "$(printf '%s\n' "$out" | grep -q 'not started (stopped before launching)' && echo 1)" "the tally names the gates that never launched"
still=$(ps -p "$harness" >/dev/null 2>&1 && echo yes || echo no)
started=$([ -f "$tmp/queued.pids" ] && wc -l <"$tmp/queued.pids" | tr -d ' ' || echo 0)
alive=0
for p in $(cat "$tmp/queued.pids" 2>/dev/null); do kill -0 "$p" 2>/dev/null && alive=$((alive + 1)); done
check "$([ "$still" = no ] && echo 1)" "TERM ends the harness (still running: $still)"
check "$([ "$started" = 1 ] && echo 1)" "TERM did not launch the queued gates (started: $started)"
check "$([ "$alive" = 0 ] && echo 1)" "no gate process survives TERM (alive: $alive)"
for p in $(cat "$tmp/queued.pids" 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done

# ---- a gate typed twice on the command line runs once, not twice over the same log ----
: >"$tmp/invocations.txt"
cat >"$tmp/tests/gate-count.sh" <<EOF
#!/bin/bash
echo run >>"$tmp/invocations.txt"
EOF
out=$(run -j 1 gate-count gate-count 2>&1); rc=$?
rows=$(printf '%s\n' "$out" | grep -c '^ok\|^FAIL')
ran=$(wc -l <"$tmp/invocations.txt" | tr -d ' ')
check "$([ "$rc" = 0 ] && echo 1)" "a repeated gate exits 0 (rc=$rc)"
check "$([ "$rows" = 1 ] && echo 1)" "a gate typed twice gives one row (rows: $rows)"
check "$([ "$ran" = 1 ] && echo 1)" "a gate typed twice is launched once (invocations: $ran)"

# ---- a gate named on the command line is not also run by the auto-append ----
git -C "$tmp" init -q                        # the auto-added gate only exists inside a git tree
out=$(run shellcheck 2>&1)
rows=$(printf '%s\n' "$out" | grep -c '^ok\|^FAIL')
check "$([ "$rows" = 1 ] && echo 1)" "naming an auto-added gate runs it once (rows: $rows): $(printf '%s' "$out" | head -2 | tr '\n' ' ')"

# ---- bad options are refused, not silently defaulted ----
run -j 0 gate-a >/dev/null 2>&1; check "$([ "$?" = 2 ] && echo 1)" "-j 0 is refused with exit 2"
run --timeout nope gate-a >/dev/null 2>&1; check "$([ "$?" = 2 ] && echo 1)" "--timeout nope is refused with exit 2"
run -j >/dev/null 2>&1; check "$([ "$?" = 2 ] && echo 1)" "-j with no number is refused with exit 2"

echo "run-all harness gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
