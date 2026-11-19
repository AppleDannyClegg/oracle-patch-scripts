#!/usr/bin/env bash
# java-patch CVE gate: preflight refuses a JDK that does not fix CVE-2026-91403 (the eMudhra CA distrust).
# The proof is the file the JVM reads - the new JDK's own blacklisted.certs (8) / blocked.certs (11+) must hold
# all 16 compromised intermediates as UPPERCASE keys - because Oracle shipped a first fix that was still affected,
# so a version number alone cannot say. 15 of 16, a lowercase copy, no blocklist, or a missing list is refused;
# --no-cve-check lets it through with a warning; a './'-prefixed tarball is read the same; preflight and verify
# both call the check.
#
# Usage: tests/java-patch-cve.sh [repo-root]

set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="$ROOT/patching/java-patch/java-patch.sh"
LIST="$ROOT/patching/java-patch/blocklist/emudhra-16.sha256"
[ -f "$SCRIPT" ] && [ -f "$LIST" ] || { echo "java-patch-cve gate: $SCRIPT or $LIST not found"; exit 2; }

T="$(cd "$(mktemp -d /tmp/jpcve.XXXXXX)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

mkdir -p "$T/tree/patching/java-patch"; ln -s "$ROOT/lib" "$T/tree/lib"
ln -s "$ROOT/patching/java-patch/blocklist" "$T/tree/patching/java-patch/blocklist"
sed '$d' "$SCRIPT" >"$T/tree/patching/java-patch/java-patch.sh"
FPS="$(grep -E '^[0-9A-F]{64}$' "$LIST")"

# mk <name> <top> <blocklist path under top, or ''> <blocklist body> [dot]: a fake JDK tarball
mk() {
  local src="$T/src-$1"; mkdir -p "$src/$2/bin"; : >"$src/$2/bin/java"; chmod +x "$src/$2/bin/java"
  printf 'JAVA_VERSION="17.0.21.0.3"\n' >"$src/$2/release"
  [ -n "$3" ] && { mkdir -p "$(dirname "$src/$2/$3")"; printf 'Algorithm=SHA-256\n%s\n' "$4" >"$src/$2/$3"; }
  if [ "${5:-}" = dot ]; then ( cd "$src" && tar -czf "$T/$1.tar.gz" ./"$2" ); else ( cd "$src" && tar -czf "$T/$1.tar.gz" "$2" ); fi
}
# check <tar> [no-cve]: rc of cve_check_tar, with its messages in $T/out
check() {
  # shellcheck disable=SC2034  # ARGS/TARBALL/JAVA_BASE/NO_CVE_CHECK are read by the sourced script
  ( . "$T/tree/patching/java-patch/java-patch.sh"
    state_set() { :; }; log() { echo "LOG $*"; }; warn() { echo "WARN $*"; }; err() { echo "ERR $*"; }
    ARGS=("$1"); TARBALL=""; JAVA_BASE="$T/base"; NO_CVE_CHECK=0; [ "${2:-}" = no-cve ] && NO_CVE_CHECK=1
    pick_tar >/dev/null 2>&1; cve_check_tar ) >"$T/out" 2>&1
}
mkdir -p "$T/base"

mk j17 jdk-17.0.21.0.3 lib/security/blocked.certs "$FPS"
check "$T/j17.tar.gz"; [ $? = 0 ] && grep -q 'blocks all 16' "$T/out" && ok || bad "Java 17 with all 16 refused: $(cat "$T/out")"
mk j8 jdk1.8.0_511 jre/lib/security/blacklisted.certs "$FPS"
check "$T/j8.tar.gz"; [ $? = 0 ] && ok || bad "Java 8 with all 16 refused: $(cat "$T/out")"
mk dot jdk-17.0.22 lib/security/blocked.certs "$FPS" dot
check "$T/dot.tar.gz"; [ $? = 0 ] && ok || bad "a ./-prefixed tarball with all 16 refused: $(cat "$T/out")"

mk short jdk-17.0.21.0.2 lib/security/blocked.certs "$(printf '%s\n' "$FPS" | sed 1d)"
check "$T/short.tar.gz"; [ $? = 1 ] && grep -q 'blocks 15 of the 16' "$T/out" && ok || bad "15 of 16 not refused: $(cat "$T/out")"
mk lower jdk-17.0.21.0.9 lib/security/blocked.certs "$(printf '%s\n' "$FPS" | tr 'A-F' 'a-f')"
check "$T/lower.tar.gz"; [ $? = 1 ] && grep -q 'blocks 0 of the 16' "$T/out" && ok || bad "a lowercase blocklist (the JDK matches uppercase) not refused: $(cat "$T/out")"
mk none jdk-17.0.19 '' ''
check "$T/none.tar.gz"; [ $? = 1 ] && grep -q 'no blacklisted.certs' "$T/out" && ok || bad "a JDK with no blocklist not refused: $(cat "$T/out")"

check "$T/short.tar.gz" no-cve; [ $? = 0 ] && grep -q '^WARN .*does NOT carry' "$T/out" && ok || bad "--no-cve-check did not let 15/16 through with a warning: $(cat "$T/out")"

# the list missing from the tree (a single script copied) is refused, not read as zero-of-zero
rm "$T/tree/patching/java-patch/blocklist"
check "$T/j17.tar.gz"; [ $? = 1 ] && grep -q 'is missing' "$T/out" && ok || bad "a missing fingerprint list not refused: $(cat "$T/out")"

# wired in: preflight fails on it, verify checks the installed JDK
body() { sed -n "/^$1() *{/,/^}/p" "$SCRIPT"; }
body cmd_preflight | grep -q 'cve_check_tar || fail=1' && ok || bad "cmd_preflight does not fail on cve_check_tar"
body cmd_verify | grep -q 'cve_blocked' && ok || bad "cmd_verify does not check the installed JDK's blocklist"

echo "java-patch-cve: $pass passed, $fail failed"
[ "$fail" = 0 ]
