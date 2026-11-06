#!/usr/bin/env bash
# wls-patch-discovery.sh - behavioural gate for wls-patch.sh's patch discovery from zips (prepare_patch_dir).
#
# The first real-host run (5 Nov 2026) unzipped the SPB zip and then reported 'holds no patch zips'. Builds real
# zips and runs 'plan' on them: an SPB and an ordinary patch one directory deeper than the bare layout (the old
# find -maxdepth cut them off); 'plan --dry-run' on a folder holding only the zip (discovery must not depend on an
# earlier real run having unzipped it, and must leave the patch folder untouched); and a zip with no patch layout
# at all, which must say so and show what it holds rather than claim the folder has no zips.
# What it cannot prove: the real zip's layout - Gen's find on the box is that.
#
# Usage: tests/wls-patch-discovery.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SCRIPT=patching/wls-patch/wls-patch.sh
command -v zip >/dev/null || { echo "wls-patch discovery gate: zip not installed"; exit 2; }
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

OH="$T/oh"; mkdir -p "$OH/wlserver" "$OH/inventory" "$OH/OPatch" "$OH/oui" "$T/jdk/bin"
echo '<component name="WebLogic Server" version="12.2.1.4.0"/>' >"$OH/inventory/registry.xml"
echo "JAVA_HOME=$T/jdk" >"$OH/oui/.globalEnv.properties"
printf '#!/bin/sh\ncase "$1" in version) echo "OPatch Version: 13.9.4.2.23";; lspatches) echo "39372515;WLS PATCH SET UPDATE 12.2.1.4.260514";; esac\nexit 0\n' >"$OH/OPatch/opatch"
printf '#!/bin/sh\necho "java version \\"1.8.0_471\\"" >&2\nexit 0\n' >"$T/jdk/bin/java"
chmod +x "$OH/OPatch/opatch" "$T/jdk/bin/java"

# mkzip <zip> <tree root>: zip the tree's contents (paths relative to the root)
mkzip() { (cd "$2" && zip -qr "$1" .); }
spb_tree() { # <root> <prefix>
  local s="$1/$2WLS_SPB_12.2.1.4.990101"
  mkdir -p "$s/tools/spbat/generic/SPBAT" "$s/binary_patches/wls/p39000009/etc/config"
  printf '#!/bin/sh\nexit 0\n' >"$s/tools/spbat/generic/SPBAT/spbat.sh"
  echo '<inventory/>' >"$s/binary_patches/wls/p39000009/etc/config/inventory.xml"
}
patch_tree() { # <root> <prefix>
  mkdir -p "$1/$2"39000002/etc/config; echo '<inventory/>' >"$1/$2"39000002/etc/config/inventory.xml
  printf 'Oracle WebLogic Server Patch 39000002 README\n' >"$1/$2"39000002/README.txt
}
plan() { HOME="$T" ORACLE_HOME="$OH" JAVA_HOME="$T/jdk" bash "$SCRIPT" plan "$@" --oracle-home "$OH" --java-home "$T/jdk" >"$T/out" 2>&1; echo $?; }
fresh() { rm -rf "$T/src" "$T/pd"; mkdir -p "$T/src" "$T/pd"; }

# an SPB one directory deeper than WLS_SPB_*/ at the zip root
fresh; spb_tree "$T/src" "wrap/"; mkzip "$T/pd/p49000001_122140_Generic.zip" "$T/src"
plan "$T/pd" >/dev/null
grep -q 'SPB        : .*WLS_SPB_12.2.1.4.990101' "$T/out" && ok || bad "SPB under a wrapper dir not found: $(grep -E 'SPB|Folder|Patch ' "$T/out" | head -3)"
grep -q 'Patch 39000009\|p39000009' "$T/out" && bad "the SPB's own binary patch was listed as an individual patch" || ok

# an ordinary patch one directory deeper than <id>/ at the zip root
fresh; patch_tree "$T/src" "wrap/"; mkzip "$T/pd/p39000002_122140_Generic.zip" "$T/src"
plan "$T/pd" >/dev/null
grep -q 'Patch 39000002 ' "$T/out" && ok || bad "patch under a wrapper dir not found: $(grep -E 'Folder|Patch ' "$T/out" | head -3)"

# the bare layouts still work
fresh; spb_tree "$T/src" ""; mkzip "$T/pd/p49000001_122140_Generic.zip" "$T/src"
plan "$T/pd" >/dev/null
grep -q 'SPB        : ' "$T/out" && ok || bad "bare SPB layout not found"

# --dry-run on a folder holding only the zip: still listed, and the patch folder is left as it was
fresh; spb_tree "$T/src" ""; mkzip "$T/pd/p49000001_122140_Generic.zip" "$T/src"
before="$(cd "$T/pd" && find . | sort)"
plan "$T/pd" --dry-run >/dev/null
grep -q 'SPB        : ' "$T/out" && ok || bad "dry-run plan on an unzipped-never folder did not list the SPB: $(grep -E 'SPB|Folder' "$T/out" | head -3)"
[ "$before" = "$(cd "$T/pd" && find . | sort)" ] && ok || bad "dry-run changed the patch folder: $(cd "$T/pd" && find . | sort | head -5 | tr '\n' ' ')"

# a zip with no patch layout: say so and show it, never 'holds no patch zips'
fresh; mkdir -p "$T/src/junk/docs"; echo x >"$T/src/junk/docs/a.txt"; mkzip "$T/pd/p40000000_122140_Generic.zip" "$T/src"
plan "$T/pd" >/dev/null
grep -q 'holds no patch zips' "$T/out" && bad "a folder that held a zip was reported as holding none" || ok
grep -q 'no SPB or patch layout' "$T/out" && grep -q 'junk' "$T/out" && ok || bad "an unrecognised zip was not reported with its top levels: $(grep -A3 -i 'folder\|layout' "$T/out" | head -4)"

# an empty folder still says it holds no zips
fresh; plan "$T/pd" >/dev/null
grep -q 'holds no patch zips' "$T/out" && ok || bad "an empty folder lost its 'holds no patch zips' line"

echo "wls-patch discovery gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
