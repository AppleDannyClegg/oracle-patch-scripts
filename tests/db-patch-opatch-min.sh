#!/usr/bin/env bash
# db-patch-opatch-min.sh - behavioural gate for db-patch.sh's patch_min_opatch.
#
# The README of a real Database Release Update names several five-part numbers: the OPatch it needs
# ("OPatch 12.2.0.1.37", "OPatch utility version 12.2.0.1.52") and the database version itself
# ("select OPatch for DB 19.0.0.0.0"). The old pattern matched all three and 'sort -V | tail -1' took
# the database version, so the server refused a correct OPatch. Only OPatch-shaped numbers may count.
#
# Sources the real function (the script minus its trailing main call) and runs it on fixture READMEs.
#
# Usage: tests/db-patch-opatch-min.sh [repo-root]
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="$ROOT/patching/db-patch/db-patch.sh"
[ -f "$SCRIPT" ] || { echo "db-patch opatch-min gate: $SCRIPT not found"; exit 2; }

T="$(cd "$(mktemp -d /tmp/dbopm.XXXXXX)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

# a copy of the tree two levels up from the script, with the trailing main call dropped: the script
# sources ../../lib/oracle-lib.sh, so it has to sit at the same depth
mkdir -p "$T/patching/db-patch" "$T/lib"
sed '$d' "$SCRIPT" >"$T/patching/db-patch/db-patch.sh"
cp "$ROOT/lib/oracle-lib.sh" "$T/lib/oracle-lib.sh"
# shellcheck disable=SC1090
. "$T/patching/db-patch/db-patch.sh"

mk() { # <name> <README body>
  mkdir -p "$T/$1"; printf '%s\n' "$2" >"$T/$1/README.txt"; printf '%s' "$1"; }

p="$(mk real 'This patch requires OPatch 12.2.0.1.37 or later.
select OPatch for DB 19.0.0.0.0 from v$instance;
OPatch utility version 12.2.0.1.52')"
out="$(patch_min_opatch "$T/$p")"
[ "$out" = 12.2.0.1.52 ] && ok || bad "the real README shape: want 12.2.0.1.52, got [$out]"

p="$(mk paren 'Download and install OPatch (patch 6880880) 12.2.0.1.52 or later first.')"
out="$(patch_min_opatch "$T/$p")"
[ "$out" = 12.2.0.1.52 ] && ok || bad "a patch parenthetical between OPatch and the version: want 12.2.0.1.52, got [$out]"

p="$(mk psu 'OPatch 12.2.0.1.52 or later. The PSU is 13.9.4.2.260522.')"
out="$(patch_min_opatch "$T/$p")"
[ "$out" = 12.2.0.1.52 ] && ok || bad "a PSU build number later on the line must not become the minimum: want 12.2.0.1.52, got [$out]"

p="$(mk onlydb 'Use OPatch for DB 19.0.0.0.0 to check this database.')"
out="$(patch_min_opatch "$T/$p")"
[ -z "$out" ] && ok || bad "a database version with no OPatch number must not be the minimum: got [$out]"

p="$(mk wls 'This PSU needs OPatch 13.9.4.2.30 or later.')"
out="$(patch_min_opatch "$T/$p")"
[ "$out" = 13.9.4.2.30 ] && ok || bad "a 13.9.x OPatch minimum: want 13.9.4.2.30, got [$out]"

p="$(mk lower 'you must use opatch 12.2.0.1.50 or later')"
out="$(patch_min_opatch "$T/$p")"
[ -z "$out" ] && ok || bad "a lowercase 'opatch' command line is not an OPatch minimum: got [$out]"

p="$(mk none 'There are no Interim patches installed in this Oracle Home.')"
out="$(patch_min_opatch "$T/$p")"
[ -z "$out" ] && ok || bad "a README with no OPatch line: got [$out]"

echo "db-patch opatch-min gate: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
