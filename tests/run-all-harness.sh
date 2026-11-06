#!/bin/bash
# run-all-harness.sh - the harness's own limits, tested against fake gates in a copy of the tree.
#
# Tonight three seats ran run-all at once, each spawning every gate at once, and the box went to load 60
# on 10 cores; the runs came back 143 with no tally. So the harness has to be able to share a machine:
#   -j N        at most N gates at a time
#   --timeout N a gate that outlives N seconds is killed and reported, not left holding the harness
# This gate copies run-all.sh into a temp tree with its own fake gates (run-all resolves tests/<gate>.sh
# relative to its own location, so the copy runs the fakes), and asserts both limits and the exit code.
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
check "$(printf '%s\n' "$out" | grep -q 'timed out after 1s' && echo 1)" "--timeout 1 says the gate timed out"
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
