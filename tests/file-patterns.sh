#!/usr/bin/env bash
# file-patterns.sh - lib/file-patterns is the one place the recognised file globs live.
#
# The JDK tarball java-patch accepts and the artifacts the updaters must not delete were hardcoded in
# java-patch ('jdk*.tar.gz' ...), get.sh ('patches-*' '*.zip' ...) and get.ps1 (the same -like list). One
# data file now holds them; this gate checks the keys, that lib's bash reader returns them, that get.sh
# and get.ps1 read the file rather than a hardcoded list, and runs get.ps1's own reader over the file.
#
# Usage: tests/file-patterns.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

PAT=lib/file-patterns
[ -f "$PAT" ] && ok || bad "$PAT is missing"
grep -qE '^jdk:' "$PAT" && ok || bad "$PAT has no jdk: line"
grep -qE '^staged:' "$PAT" && ok || bad "$PAT has no staged: line"

# lib's bash reader
jdk="$(bash -c '. lib/oracle-lib.sh >/dev/null 2>&1; file_patterns jdk' | tr '\n' ' ')"
staged="$(bash -c '. lib/oracle-lib.sh >/dev/null 2>&1; file_patterns staged' | tr '\n' ' ')"
[ "$jdk" = 'jdk*.tar.gz jdk*.tgz server-jre*.tar.gz jre*.tar.gz ' ] && ok || bad "file_patterns jdk: [$jdk]"
[ "$staged" = 'patches-* *.zip *.tar.gz *.tgz ' ] && ok || bad "file_patterns staged: [$staged]"
bash -c '. lib/oracle-lib.sh >/dev/null 2>&1; ! file_patterns nope 2>/dev/null' && ok || bad "an unknown key did not fail"

# the consumers read the file, not their own hardcoded list
grep -q 'file-patterns' get.sh && ok || bad "get.sh does not read lib/file-patterns"
grep -qE "(^|[^a-z])-name 'patches-|--name patches-" get.sh && bad "get.sh still hardcodes the staged globs" || ok
grep -q 'file-patterns' get.ps1 && ok || bad "get.ps1 does not read lib/file-patterns"
grep -qE "like 'patches-" get.ps1 && bad "get.ps1 still hardcodes the staged globs" || ok
grep -q 'file_patterns jdk' patching/java-patch/java-patch.sh && ok || bad "java-patch does not read file_patterns jdk"
grep -qE "iname 'jdk" patching/java-patch/java-patch.sh && bad "java-patch still hardcodes the jdk globs" || ok

# get.ps1's reader, run as it stands in the file, produces the staged set
if command -v pwsh >/dev/null 2>&1; then
  sed -n '/\$stagedGlobs = @(/,/Where-Object { \$_ })/p' get.ps1 | sed 's/^ *//' >"$T/reader.ps1"
  [ -s "$T/reader.ps1" ] && ok || bad "could not lift get.ps1's staged reader"
  got="$(FILE_PATTERNS_FILE="$PWD/$PAT" READER="$T/reader.ps1" pwsh -NoProfile -Command '
    $patternsFile = $env:FILE_PATTERNS_FILE; . $env:READER; $stagedGlobs -join "|"' 2>/dev/null)"
  [ "$got" = 'patches-*|*.zip|*.tar.gz|*.tgz' ] && ok || bad "get.ps1's reader gave [$got]"
fi

echo "file-patterns gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
