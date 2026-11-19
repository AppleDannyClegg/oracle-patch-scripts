#!/usr/bin/env bash
# java-blocklist gate: patching/java-patch/blocklist/java-blocklist.sh against fake Java 8, JRE and Java 17 layouts.
# A dry run changes nothing; --apply adds exactly the fingerprints the file lacks (case-insensitive) with a backup;
# a second --apply adds none; --with-alternates adds the 32 more; a file whose first line is not Algorithm=SHA-256,
# or a home with no blocklist file, is refused (exit 1) and left byte-identical; --rollback restores the backup.
#
# Usage: tests/java-blocklist.sh [repo-root]

set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
S="$ROOT/patching/java-patch/blocklist/java-blocklist.sh"
[ -f "$S" ] || { echo "java-blocklist gate: $S not found"; exit 2; }

T="$(cd "$(mktemp -d /tmp/jblk.XXXXXX)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }
fp() { grep -cE '^[0-9A-Fa-f]{64}' "$1"; }
ONE=42C4ACCD12C4F59597925E1A08A7A90102608543809308D50EC427E118BA1493

j8="$T/j8/jre/lib/security/blacklisted.certs"; jre="$T/jre/lib/security/blacklisted.certs"; j17="$T/j17/lib/security/blocked.certs"
mkdir -p "$(dirname "$j8")" "$(dirname "$jre")" "$(dirname "$j17")" "$T/bad/lib/security" "$T/none/lib/security"
# Java 8 already holds one of the 16, in lower case, plus an unrelated entry
printf 'Algorithm=SHA-256\n%s\n%s\n' "$(printf %064d 1)" "$(printf '%s' "$ONE" | tr 'A-F' 'a-f')" >"$j8"
printf 'Algorithm=SHA-256\n' >"$jre"; printf 'Algorithm=SHA-256\n' >"$j17"
printf 'Algorithm=MD5\n' >"$T/bad/lib/security/blocked.certs"

# dry run: no change, no backup, says 15 to add
cp "$j8" "$T/j8.orig"
out="$("$S" "$T/j8" 2>&1)"; rc=$?
[ $rc = 0 ] && cmp -s "$j8" "$T/j8.orig" && ! ls "$j8".bak.* >/dev/null 2>&1 && ok || bad "dry run changed the file or made a backup (rc=$rc)"
case "$out" in *"15 to add"*) ok;; *) bad "dry run did not count 15 to add: $out";; esac

# apply: +15, backup equals the original, the 16 are all present once
"$S" "$T/j8" --apply >/dev/null 2>&1; rc=$?
[ $rc = 0 ] && [ "$(fp "$j8")" = 17 ] && ok || bad "apply on Java 8: rc=$rc, $(fp "$j8") fingerprints, want 17"
b="$(ls "$j8".bak.* 2>/dev/null | head -1)"; [ -n "$b" ] && cmp -s "$b" "$T/j8.orig" && ok || bad "no backup equal to the original"
[ "$(tr 'a-f' 'A-F' <"$j8" | grep -c "^$ONE")" = 1 ] && ok || bad "a fingerprint already present (lower case) was added again"
[ "$(head -1 "$j8")" = "Algorithm=SHA-256" ] && ok || bad "header line moved"

# a second apply adds nothing
before="$(cksum <"$j8")"; "$S" "$T/j8" --apply >/dev/null 2>&1; rc=$?
[ $rc = 0 ] && [ "$(cksum <"$j8")" = "$before" ] && ok || bad "second apply changed the file (rc=$rc)"

# a bare JRE home and Java 17 are found; --with-alternates adds 48
"$S" "$T/jre" --apply >/dev/null 2>&1 && [ "$(fp "$jre")" = 16 ] && ok || bad "JRE home: $(fp "$jre") fingerprints, want 16"
"$S" "$T/j17" --apply --with-alternates >/dev/null 2>&1 && [ "$(fp "$j17")" = 48 ] && ok || bad "Java 17 with alternates: $(fp "$j17"), want 48"

# refusals: wrong header, no file, unknown option - exit non-zero, file untouched
cp "$T/bad/lib/security/blocked.certs" "$T/bad.orig"
"$S" "$T/bad" --apply >/dev/null 2>&1; rc=$?
[ $rc = 1 ] && cmp -s "$T/bad/lib/security/blocked.certs" "$T/bad.orig" && ok || bad "wrong header not refused untouched (rc=$rc)"
"$S" "$T/none" --apply >/dev/null 2>&1; rc=$?; [ $rc = 1 ] && ok || bad "home with no blocklist file: rc=$rc, want 1"
"$S" "$T/j8" --aply >/dev/null 2>&1; rc=$?; [ $rc = 2 ] && ok || bad "unknown option: rc=$rc, want 2"

# rollback restores the original
"$S" "$T/j8" --rollback >/dev/null 2>&1; rc=$?
[ $rc = 0 ] && cmp -s "$j8" "$T/j8.orig" && ok || bad "rollback did not restore the original (rc=$rc)"

# the shipped lists: 16 and 32 well-formed, no line that is neither a comment nor a fingerprint, no duplicates
D="$(dirname "$S")"
[ "$(grep -cE '^[0-9A-F]{64}$' "$D/emudhra-16.sha256")" = 16 ] && ok || bad "emudhra-16.sha256 does not hold 16 fingerprints"
[ "$(grep -cE '^[0-9A-F]{64}$' "$D/emudhra-32-alternates.sha256")" = 32 ] && ok || bad "emudhra-32-alternates.sha256 does not hold 32"
[ -z "$(grep -hvE '^#|^[0-9A-F]{64}$' "$D"/*.sha256)" ] && ok || bad "a list holds a malformed line"
[ -z "$(grep -hE '^[0-9A-F]{64}$' "$D"/*.sha256 | sort | uniq -d)" ] && ok || bad "a fingerprint is listed twice"

echo "java-blocklist: $pass passed, $fail failed"
[ "$fail" = 0 ]
