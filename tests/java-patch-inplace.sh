#!/usr/bin/env bash
# java-patch in-place gate: a REAL-directory --java-home (not a symlink) must be replaced in place - the
# path ends up on the new build, the old one is renamed to a sibling, a SEPARATE 'verify' passes, and
# rollback puts the old build back. The dry-run env stages a symlink target, so this is the only
# mechanical cover for the in-place branch.
#
# Usage: tests/java-patch-inplace.sh [repo-root]

set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
S="$ROOT/patching/java-patch/java-patch.sh"
[ -f "$S" ] || { echo "java-patch in-place gate: $S not found"; exit 2; }

T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

# a fake JDK whose bin/java answers -version, so jdk_version() works
jdk() { mkdir -p "$1/bin"; printf '#!/bin/sh\necho "openjdk version \\"%s\\" 2024-07-16" >&2\n' "$2" >"$1/bin/java"; chmod +x "$1/bin/java"; }
jdk "$T/java" 1.8.0_471
mkdir -p "$T/src/jdk-1.8.0_511"; jdk "$T/src/jdk-1.8.0_511" 1.8.0_511
printf 'JAVA_VERSION="1.8.0_511"\n' >"$T/src/jdk-1.8.0_511/release"
tar -czf "$T/jdk-1.8.0_511_linux-x64_bin.tar.gz" -C "$T/src" jdk-1.8.0_511

R="$T/run"; OUT="$T/out.log"
run() { bash "$S" "$@" --java-home "$T/java" --no-cacerts --run-dir "$R" >>"$OUT" 2>&1; }
ver() { "$T/java/bin/java" -version 2>&1 | head -1; }

run preflight "$T/jdk-1.8.0_511_linux-x64_bin.tar.gz" && ok || bad "preflight failed: $(tail -2 "$OUT")"
grep -q '^preflight=ok' "$R/state" 2>/dev/null && ok || bad "preflight verdict not recorded with --run-dir (state: $(cat "$R/state" 2>/dev/null | tr '\n' ' '))"

run apply "$T/jdk-1.8.0_511_linux-x64_bin.tar.gz" --yes && ok || bad "apply failed: $(tail -2 "$OUT")"
[ "$(ver)" = 'openjdk version "1.8.0_511" 2024-07-16' ] && ok || bad "the path does not run the new build (got: $(ver))"
ls -d "$T"/java.old-* >/dev/null 2>&1 && ok || bad "the old JDK was not renamed to a sibling"
grep -q '^new_ver=1.8.0_511' "$R/state" 2>/dev/null && ok || bad "apply did not record new_ver"

run verify && ok || bad "a separate 'verify --run-dir' failed: $(tail -3 "$OUT")"

run rollback --yes && ok || bad "rollback failed: $(tail -2 "$OUT")"
[ "$(ver)" = 'openjdk version "1.8.0_471" 2024-07-16' ] && ok || bad "rollback did not restore the old build (got: $(ver))"
[ -e "$T/java/old-jdk" ] && bad "rollback nested the old JDK inside the path" || ok

echo "java-patch in-place gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
