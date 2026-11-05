#!/usr/bin/env bash
# db-patch-ru-title.sh - behavioural gate for db-patch.sh's "newest Database Release Update" pick.
#
# MOS now titles RUs without the yymmdd the old code required ('DATABASE RELEASE UPDATE 19.33.0.0.0'), so
# no row matched and a home read as having nothing to plan. The pick must accept both title shapes, order
# by the RU version, and still exclude the ' - CMAN' / ' - GSM' variants that are not for the database home.
#
# Sources the real cmd_latest (the script minus its trailing main call) with the MOS lookup stubbed.
#
# Usage: tests/db-patch-ru-title.sh [repo-root]
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="$ROOT/patching/db-patch/db-patch.sh"
[ -f "$SCRIPT" ] || { echo "db-patch ru-title gate: $SCRIPT not found"; exit 2; }

T="$(cd "$(mktemp -d /tmp/dbru.XXXXXX)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

mkdir -p "$T/patching/db-patch" "$T/lib" "$T/run"
sed '$d' "$SCRIPT" >"$T/patching/db-patch/db-patch.sh"
cp "$ROOT/lib/oracle-lib.sh" "$T/lib/oracle-lib.sh"

run_latest() { # <mos rows...>: prints the "newest RU:" line
  local rows; rows="$(printf '%s\n' "$@")"
  HOME="$T" RUN_DIR="$T/run" DB_VERSION=19.0.0.0.0 MOS_ROWS="$rows" bash -c '
    . "$1"
    setup_env(){ :; }; mos_login(){ :; }; init_run_dir(){ :; }
    # only the RU query is answered; the OJVM/GI queries return nothing
    mos_name_search(){ case "$1" in "Database Release Update "*) printf "%s\n" "$MOS_ROWS";; esac; }
    DB_VERSION=19.0.0.0.0; INSTALLED=""; RU_LEVEL=""
    cmd_latest 2>&1 | grep "newest RU:"
  ' _ "$T/patching/db-patch/db-patch.sh"
}

# an undated title newer than a dated one must win, and the CMAN variant must not be picked
out="$(run_latest \
  '39000001|Database Release Update 19.24.0.0.240716 (Patch 39000001)' \
  '39915792|DATABASE RELEASE UPDATE 19.33.0.0.0' \
  '39999999|Database Release Update 19.40.0.0.250101 - CMAN')"
case "$out" in *39915792*) ok;; *) bad "the undated 19.33 title was not picked: [$out]";; esac
case "$out" in *39999999*|*CMAN*) bad "the - CMAN variant was picked: [$out]";; *) ok;; esac

# only dated rows: the higher version still wins
out="$(run_latest \
  '39000001|Database Release Update 19.24.0.0.240716 (Patch 39000001)' \
  '39000002|Database Release Update 19.25.0.0.240716 (Patch 39000002)')"
case "$out" in *39000002*) ok;; *) bad "the higher dated RU was not picked: [$out]";; esac

# no RU rows at all: nothing is reported as newest
out="$(run_latest '39000003|OJVM RELEASE UPDATE 19.24.0.0.240716')"
[ -z "$out" ] && ok || bad "a non-RU row was reported as the newest RU: [$out]"

echo "db-patch ru-title gate: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
