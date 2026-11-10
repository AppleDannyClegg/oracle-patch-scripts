#!/usr/bin/env bash
# ohs-quarter-real-children.sh - the composer's one-backup phase, driven against the REAL children.
#
# Why it exists: tests/ohs-quarter.sh stubs both children (its stub writes the shared state and the archives itself),
# so the composer was green over a one-backup link that could not work with the real scripts - the stub invented the
# contract (T291, Edi #13261). This gate points OHS_QUARTER_DBCLIENT / OHS_QUARTER_OHS_PATCH at the real patching
# scripts instead, on the shared fake home from tests/fixtures/dbclient-home.sh, and asserts the link the composer
# depends on: the child's backup lands in the composer's shared run dir, its state file is there, and the apply that
# follows reads it back. A stub cannot carry that contract again without this gate going red.
#
# Red-first, on origin/main 1deaf2e (measured, not asserted in the file): the child ignored --run-dir, so the shared
# dir had no state and the composer stopped at "backup needs <dir>" / the apply refused "no completed backup"; with
# both fixed the composer reaches 7/7. The ohs leg is --skip'd here because its bake needs a different fake home -
# ohs-patch's own gate covers the same fix on that side (tests/ohs-patch.sh, the --run-dir case).
#
# What it cannot prove: the real box. A container or a host is not a-dev-host; this removes the fake-child
# blindness, not the host blindness.
#
# Usage: tests/ohs-quarter-real-children.sh

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "${T:?}"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

SCRIPT=patching/ohs-quarter/ohs-quarter.sh
# shellcheck source=tests/fixtures/dbclient-home.sh
. tests/fixtures/dbclient-home.sh
SCRIPT=patching/ohs-quarter/ohs-quarter.sh

build
# the composer's patch root: a jdk tarball and the dbclient folder IT passes to the child as <patch-dir>
mkdir -p "$T/root/jdk"; : >"$T/root/jdk/jdk.tar.gz"; ln -sfn "$PD" "$T/root/dbclient"
# a java child that only logs: this gate is about the dbclient/shared-backup link, not the JDK bake
printf '#!/bin/sh\necho "javastub $*" >>"%s/calls.log"; exit 0\n' "$T" >"$T/stub-java"; chmod +x "$T/stub-java"
: >"$T/ps.txt"

OHS_QUARTER_JAVA_PATCH="$T/stub-java" OHS_QUARTER_WLS_PATCH="$T/stub-java" \
OHS_QUARTER_DBCLIENT=patching/dbclient-upgrade/dbclient-upgrade.sh \
OHS_QUARTER_OHS_PATCH=patching/ohs-patch/ohs-patch.sh \
HOME="$T/home" PATH="$T/stub:$PATH" RUN_BASE="$T/runs" START_TIMEOUT=1 POLL=1 OS_RELEASE="$T/os-release" \
  bash "$SCRIPT" --patch-root "$T/root" --run-dir "$T/run" --yes --oracle-home "$OH" --backup-dir "$T/backup" \
  --skip wlspsu,dbclientru,webgate,oss,ohs,jdbc,libovd,fmwthirdparty,perl,libdms2,libiau >"$T/out" 2>&1
rc=$?

SHARED="$T/run/backup"
[ "$rc" = 0 ] && ok || bad "the composer did not finish: rc $rc: $(grep -E '\[ERROR\]' "$T/out" | head -3 | tr '\n' ' ')"
grep -q '=== 7/7 OHS QUARTER OK' "$T/out" && ok || bad "no 7/7 OK line: $(tail -3 "$T/out" | tr '\n' ' ')"
# the link itself: the child's backup is IN the composer's shared dir, state and all
[ -f "$SHARED/state" ] && ok || bad "$SHARED/state missing - the child wrote its backup somewhere else: $(grep -E 'run dir|backed up to' "$T/out" | head -3 | tr '\n' ' ')"
grep -q '^pre_rsf=' "$SHARED/state" 2>/dev/null && ok || bad "the shared state does not carry the child's pre_rsf: $(head -5 "$SHARED/state" 2>/dev/null | tr '\n' ' ')"
[ -d "$SHARED/patch_top" ] && ok || bad "$SHARED/patch_top missing - the installer's own backup top is not in the shared run dir"
# the child took the patch dir the composer handed it (without one it exits 'backup needs <dir>')
grep -q 'backup needs <dir>' "$T/out" && bad "the composer called backup with no patch dir (backup needs <dir>)" || ok
# and the apply that follows read that state instead of refusing
grep -qE 'apply refused: (no completed backup|.*has no state)' "$T/out" && bad "the apply refused the shared backup: $(grep -E 'apply refused' "$T/out" | head -2 | tr '\n' ' ')" || ok
grep -q '=== 4/7 apply' "$T/out" && ok || bad "the composer never reached the apply phase"

echo "ohs-quarter real-children gate: $pass passed, $fail failed"
[ "$fail" = 0 ]