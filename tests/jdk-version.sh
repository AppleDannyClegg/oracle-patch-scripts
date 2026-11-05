#!/usr/bin/env bash
# jdk-version.sh - behaviour gate for java_version_of / java_major_of, the JDK version read from a home.
#
# They were two copies that drifted: patch-manifest's read past a 'Picked up JAVA_TOOL_OPTIONS: ...' first
# line and bounded a hung JVM with a timeout (PM-7, EM-5), while lib's was `head -1` with neither - so
# java-patch's jdk_version (and patch-status) could read the wrong line or hang on the same host. The
# scripts must stay self-contained (tests/self-contained-gate.sh), so each keeps a copy: this gate checks
# the two copies are identical and runs them against a java whose first stderr line is a 'Picked up' notice.
#
# Usage: tests/jdk-version.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

body() { sed -n "/^$2() *{/,/^}/p" "$1"; }
for fn in java_version_of java_major_of; do
  a="$(body lib/oracle-lib.sh "$fn")"; b="$(body patching/patch-manifest.sh "$fn")"
  [ -n "$a" ] && [ "$a" = "$b" ] && ok || bad "the two $fn copies differ (lib / patch-manifest)"
done

# the function under test: lib's copy
eval "$(body lib/oracle-lib.sh java_version_of)"
eval "$(body lib/oracle-lib.sh java_major_of)"

mkjava() { # <home> <first-line> <second-line>
  mkdir -p "$1/bin"
  cat >"$1/bin/java" <<EOF
#!/bin/sh
cat <<'JAVA_EOF' >&2
$2
$3
JAVA_EOF
EOF
  chmod +x "$1/bin/java"
}

# a 'Picked up' notice as the first line must not be read as the version (PM-7/EM-5)
mkjava "$T/h8" 'Picked up JAVA_TOOL_OPTIONS: -Xmx1g' 'openjdk version "1.8.0_511" 2026-01-20'
[ "$(java_version_of "$T/h8")" = '1.8.0_511' ] && ok || bad "a 'Picked up' first line hid the version: got [$(java_version_of "$T/h8")]"
[ "$(java_major_of "$T/h8")" = '8' ] && ok || bad "major of 1.8.0_511: got [$(java_major_of "$T/h8")]"

# the ordinary shapes
mkjava "$T/h17" 'openjdk version "17.0.13" 2026-01-20' ''
[ "$(java_version_of "$T/h17")" = '17.0.13' ] && ok || bad "java_version_of 17: got [$(java_version_of "$T/h17")]"
[ "$(java_major_of "$T/h17")" = '17' ] && ok || bad "major of 17.0.13: got [$(java_major_of "$T/h17")]"
mkjava "$T/h11" 'java version "11.0.21" 2023-10-17 LTS' ''
[ "$(java_major_of "$T/h11")" = '11' ] && ok || bad "major of 11.0.21: got [$(java_major_of "$T/h11")]"

# the timeout branch: a timeout(1) on PATH must be used (drop '-k 5 30' and run the rest)
mkdir -p "$T/bin"; printf '#!/bin/sh\nshift 3; exec "$@"\n' >"$T/bin/timeout"; chmod +x "$T/bin/timeout"
got="$(PATH="$T/bin:$PATH" java_version_of "$T/h8")"
[ "$got" = '1.8.0_511' ] && ok || bad "with a timeout(1) on PATH: got [$got]"

echo "jdk-version gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
