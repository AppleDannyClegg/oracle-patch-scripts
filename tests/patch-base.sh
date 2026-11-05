#!/usr/bin/env bash
# patch-base.sh - one folder ($PATCH_BASE) holds everything downloaded.
#
# The manifest was written to whatever cwd patch-manifest ran in, get-patches put its patches in
# patches-<host>, and each tool took its download dir from the operator. One base now holds them: the
# manifest, the patch zips (<base>/<kind>) and the get.sh/get.ps1 tree (<base>/scripts). This gate checks
# the default and the two overrides, and that each consumer wired to it.
#
# Usage: tests/patch-base.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

# lib: the default, and PATCH_BASE in the environment
d="$(bash -c 'unset PATCH_BASE; . lib/oracle-lib.sh >/dev/null 2>&1; printf %s "$PATCH_BASE"')"
[ "$d" = '/u01/patches' ] && ok || bad "lib PATCH_BASE default: [$d]"
o="$(PATCH_BASE=/tmp/pb bash -c '. lib/oracle-lib.sh >/dev/null 2>&1; printf %s "$PATCH_BASE"')"
[ "$o" = '/tmp/pb' ] && ok || bad "lib PATCH_BASE override: [$o]"

# lib: PATCH_BASE in oracle.conf reaches the lib-sourcing scripts
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
printf 'PATCH_BASE=%s\n' "$T/conf-base" >"$T/oracle.conf"
c="$(bash -c "unset PATCH_BASE; SCRIPT_DIR='$T'; . lib/oracle-lib.sh >/dev/null 2>&1; load_config '$T/oracle.conf' >/dev/null 2>&1; printf %s \"\$PATCH_BASE\"")"
[ "$c" = "$T/conf-base" ] && ok || bad "oracle.conf PATCH_BASE: [$c]"

# each consumer wired to the base (patch-manifest is self-contained, so it carries its own default)
grep -q 'out_file="$PATCH_BASE/manifest-$host.txt"' patching/patch-manifest.sh && ok || bad "patch-manifest default out is not \$PATCH_BASE/manifest-<host>.txt"
grep -q 'PATCH_BASE/wls' patching/wls-patch/wls-patch.sh && ok || bad "wls-patch download default is not \$PATCH_BASE/wls"
grep -q 'PATCH_BASE/db' patching/db-patch/db-patch.sh && ok || bad "db-patch download default is not \$PATCH_BASE/db"
grep -q 'PATCH_BASE/jdk' patching/java-patch/java-patch.sh && ok || bad "java-patch download default is not \$PATCH_BASE/jdk"
grep -q 'PATCH_BASE/scripts' get.sh && ok || bad "get.sh does not default the tree to \$PATCH_BASE/scripts"
grep -q "Join-Path \$env:PATCH_BASE 'scripts'" get.ps1 && ok || bad "get.ps1 does not default the tree to PATCH_BASE/scripts"
grep -q 'Join-Path \$base \$m.Host' patching/get-patches.ps1 && ok || bad "get-patches.ps1 default Dest is not PATCH_BASE/<host>"

echo "patch-base gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
