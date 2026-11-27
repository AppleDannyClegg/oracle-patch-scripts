#!/usr/bin/env bash
# A run state saved with old_jh ending in "/" must roll back to the SAME JDK,
# not try to park the new build inside the directory it is moving. The
# comparison happens before any rename, so a different home is still refused.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/tree/patching/java-patch" "$T/home/java-patch/runs/r1" "$T/home/bin" "$T/jdk/bin"
ln -s "$ROOT/lib" "$T/tree/lib"
sed '$d' "$ROOT/patching/java-patch/java-patch.sh" >"$T/tree/patching/java-patch/java-patch.sh"
printf '#!/bin/sh\necho "openjdk version \\"1.8.0_471\\" 2024-07-16" >&2\n' >"$T/home/bin/java"
printf '#!/bin/sh\necho "openjdk version \\"1.8.0_471\\" 2024-07-16" >&2\n' >"$T/jdk/bin/java"
chmod +x "$T/home/bin/java" "$T/jdk/bin/java"
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

rollback() { # <saved old_jh> -> $RC and $T/out
  mkdir -p "$T/home/java-patch/runs/r1"
  printf 'preflight=ok\nbackup=ok\napply=ok\nin_place=1\nold_jh=%s\nold_real=%s\nold_jdk=%s\nlink_target=\nbacked_files=\n' \
    "$1" "$T/home" "$T/jdk" >"$T/home/java-patch/runs/r1/state"
  {
    printf '. "%s/tree/patching/java-patch/java-patch.sh" >/dev/null 2>&1 || exit 99\n' "$T"
    printf 'export T="%s" RUN_DIR="%s/home/java-patch/runs/r1" DRY_RUN=0 ASSUME_YES=1\n' "$T" "$T"
    printf 'reuse_or_init() { :; }\ndiscover() { :; }\nstate_get() { sed -n "s/^$1=//p" \"$T/home/java-patch/runs/r1/state\" | tail -1; }\n'
    printf 'running_on() { :; }\nconfirm() { :; }\n'
    printf 'cmd_rollback\n'
  } >"$T/probe.sh"
  (cd "$T" && bash "$T/probe.sh") >"$T/out" 2>&1
  RC=$?
}

# control: exact path rolls back, with a sibling aside path
rollback "$T/home"
[ "$RC" = 0 ] && ! grep -q "$T/home/.failed-" "$T/out" && ok || bad "exact saved home failed: rc $RC: $(grep -E 'mv failed|ERROR' "$T/out" | head -1)"

# the real shape: older state saved with a trailing slash
rollback "$T/home/"
[ "$RC" = 0 ] && ! grep -q "$T/home/.failed-" "$T/out" && ok || bad "same home with saved slash failed: rc $RC: $(grep -E 'mv failed|ERROR|cannot move' "$T/out" | head -1)"

# control: a genuinely different home is still refused
rollback "$T/other/"
[ "$RC" != 0 ] && ok || bad "a different saved home was accepted"

echo "java saved old_jh slash gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
