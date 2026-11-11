#!/usr/bin/env bash
# wls-patch-restore-failure.sh - wls-patch `restore` must not record a restore it did not do.
#
# Why this gate exists: tests/false-success-gate.sh counts a failure only when IT injected one through a stubbed tool,
# and restore's only command is `tar -xzf`, which is not a stub there. So a restore that failed and then wrote
# `restored_from=` was caught by nothing (T245, Gort's route (b)). This gate breaks the archive instead of the tool:
# a truncated `oracle_home.tar.gz` is the failure an operator gets from a partial or interrupted backup, and tar
# fails on it for real, with no stub anywhere.
#
# It asserts, on the real script with the wls-patch fixture from tests/dry-run-env/wls-patch.sh:
#   1. control - a good backup restores, rc 0, and the run records restored_from=<that backup>. Without this the
#      other cases could pass because nothing is ever recorded at all.
#   2. a truncated HOME archive -> rc != 0, "Restore failed", and NO state under that HOME claims restored_from.
#   3. a truncated DOMAIN archive -> the same, and this is the worse one: the home has already been replaced, so a
#      restored_from there would tell the operator the run succeeded when only half the restore happened.
#   4. the error names where the old home was moved, so a failed restore is recoverable by hand.
#
# Red-first, measured by mutating the SCRIPT (a copy, never landed): `run_cmd tar -xzf ... || die` -> `|| true` makes
# case 2 record restored_from after a failed tar and the gate goes RED. Ceiling: a fake home and a fake domain; what
# a real 14.1.1 home does under a truncated archive is the box's answer, not this gate's.
#
# Usage: tests/wls-patch-restore-failure.sh

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "${T:?}"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

SCRIPT=patching/wls-patch/wls-patch.sh
STUB="$T/stub"; mkdir -p "$STUB"
# the fixture the other wls-patch gates use: a 14.1.1 home, one domain, a backup under $T/env/backups/b1
# the fixture is rebuilt before every case: each restore MOVES $ORACLE_HOME aside (that is the point of case 2),
# so the next case would otherwise run against a home that no longer exists
build() {
  # exported: the fixture is sourced, and shellcheck cannot see it read an assignment made here
  export CMD CASE
  CMD=restore; CASE=""
  # shellcheck disable=SC1091
  . tests/dry-run-env/wls-patch.sh
}
build

# restore <home-dir> <backup-dir>: run the real script against a private HOME so two cases cannot see each other's runs
restore() {
  local home="$1" src="$2"
  mkdir -p "$home"
  # wls-patch names the moved-aside home "$ORACLE_HOME.broken-$(date +%Y%m%d-%H%M%S)" - SECOND resolution. Two of these
  # cases run inside the same second, so the second restore finds the first's aside directory already there, mv tries to
  # move the home INTO it, and dies with "mv failed" before touching the archive. Clearing the leftovers is this gate
  # staying about the ARCHIVE; the same-second collision is a separate finding (reported, not fixed here).
  rm -rf "$T"/env/fmw.broken-* "$T"/env/domains/*.broken-*
  HOME="$home" bash "$SCRIPT" restore "$src" --yes >"$T/out" 2>&1
  echo $?
}
# claims <home-dir> <backup-dir>: does any state under that HOME claim this restore happened?
claims() {
  find "$1" -name state -type f -exec grep -l "^restored_from=$2$" {} + 2>/dev/null | head -1
}

# 1. CONTROL: a good backup is restored, and the run says so
build; rc="$(restore "$T/home-ok" "$T/env/backups/b1")"
[ "$rc" = 0 ] && [ -n "$(claims "$T/home-ok" "$T/env/backups/b1")" ] && ok || bad "a good backup did not restore or was not recorded: rc $rc: $(grep -E 'ERROR' "$T/out" | head -2)"

# 2. a truncated HOME archive: tar fails, so nothing was restored and nothing may be recorded
build; BC="$T/env/backups/broken-home"; mkdir -p "$BC"; cp "$T/env/backups/b1/"* "$BC/" 2>/dev/null
head -c 40 "$T/env/backups/b1/oracle_home.tar.gz" >"$BC/oracle_home.tar.gz"
rc="$(restore "$T/home-bad" "$BC")"
[ "$rc" != 0 ] && ok || bad "a truncated home archive restored 'successfully': rc $rc: $(tail -2 "$T/out" | tr '\n' ' ')"
grep -q 'Restore failed' "$T/out" && ok || bad "the failure is not named: $(grep -E 'ERROR' "$T/out" | head -2)"
[ -z "$(claims "$T/home-bad" "$BC")" ] && ok || bad "restored_from=$BC was recorded after a failed restore - a false success"
# 4. the operator is told where the old home went
grep -qE "old home is at $ORACLE_HOME\.broken-" "$T/out" && ok || bad "the failed restore does not name where the old home was moved: $(grep -E 'ERROR|broken' "$T/out" | head -2)"

# 3. a truncated DOMAIN archive: the home has already been replaced, and a restored_from here would read as success
build; BD="$T/env/backups/broken-domain"; mkdir -p "$BD"; cp "$T/env/backups/b1/"* "$BD/" 2>/dev/null
head -c 40 "$T/env/backups/b1/domain-1.tar.gz" >"$BD/domain-1.tar.gz"
rc="$(restore "$T/home-baddom" "$BD")"
[ "$rc" != 0 ] && ok || bad "a truncated domain archive restored 'successfully': rc $rc: $(tail -2 "$T/out" | tr '\n' ' ')"
grep -q 'Domain restore failed' "$T/out" && ok || bad "the domain failure is not named: $(grep -E 'ERROR' "$T/out" | head -2)"
[ -z "$(claims "$T/home-baddom" "$BD")" ] && ok || bad "restored_from=$BD was recorded after a failed domain restore - a false success"

echo "wls-patch restore-failure gate: $pass passed, $fail failed"
[ "$fail" = 0 ]