#!/usr/bin/env bash
# db-patch-opatch-kit.sh - behavioural gate for db-patch.sh's OPatch kit (p6880880) install, install_opatch_kit.
#
# The audit (5 Nov 2026) found the kit install moved <home>/OPatch aside BEFORE unzipping the kit, so any unzip
# failure (no unzip, disk full, a corrupt kit) left the home with no OPatch; and an unreadable kit version forced
# the upgrade. Runs the real function on a fake home: a good kit is swapped in and the old one kept; with no unzip
# on PATH, or a kit that unzips to no runnable opatch, the home keeps its working OPatch and nothing is moved;
# a kit that is not newer is left alone.
#
# Usage: tests/db-patch-opatch-kit.sh [repo-root]
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="$ROOT/patching/db-patch/db-patch.sh"
[ -f "$SCRIPT" ] || { echo "db-patch opatch-kit gate: $SCRIPT not found"; exit 2; }
command -v zip >/dev/null || { echo "db-patch opatch-kit gate: zip not installed"; exit 2; }
T="$(cd "$(mktemp -d /tmp/dbkit.XXXXXX)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

mkdir -p "$T/patching/db-patch" "$T/lib"
sed '$d' "$SCRIPT" >"$T/patching/db-patch/db-patch.sh"
cp "$ROOT/lib/oracle-lib.sh" "$T/lib/oracle-lib.sh"

kit() { # <zip> <version> [no-opatch]
  rm -rf "$T/k"; mkdir -p "$T/k/OPatch"; printf 'OPATCH_VERSION:%s\n' "$2" >"$T/k/OPatch/version.txt"
  [ "${3:-}" = no-opatch ] || { printf '#!/bin/sh\necho "OPatch Version: %s"\n' "$2" >"$T/k/OPatch/opatch"; chmod +x "$T/k/OPatch/opatch"; }
  (cd "$T/k" && zip -qr "$1" OPatch); }
home() { rm -rf "${T:?}/home" "${T:?}/run"; mkdir -p "$T/home/OPatch" "$T/run"; printf '#!/bin/sh\necho "OPatch Version: 12.2.0.1.40"\n' >"$T/home/OPatch/opatch"; chmod +x "$T/home/OPatch/opatch"; }
# one call in a subshell (die exits): PATH may be narrowed by the caller
call() { ( . "$T/patching/db-patch/db-patch.sh"; RUN_DIR="$T/run"; LOG_FILE="$T/run/log"; OPATCH_VERSION=12.2.0.1.40; DRY_RUN=0; ASSUME_YES=1
  install_opatch_kit "$T/home" "$1" ) >"$T/out" 2>&1; echo $?; }
works() { "$T/home/OPatch/opatch" version 2>/dev/null | grep -q "$1"; }

# a newer kit: swapped in, the old OPatch kept under the run dir
home; kit "$T/kit47.zip" 12.2.0.1.47; rc="$(call "$T/kit47.zip")"
[ "$rc" = 0 ] && works 12.2.0.1.47 && ok || bad "a good kit: rc $rc, home opatch: $("$T/home/OPatch/opatch" version 2>&1): $(tail -2 "$T/out")"
o="$(find "$T/run" -maxdepth 1 -name 'OPatch.old.*' | head -1)"
[ -n "$o" ] && "$o/opatch" version | grep -q 12.2.0.1.40 && ok || bad "the old OPatch was not kept in the run dir"
[ -z "$(find "$T/home" -maxdepth 1 -name '.opatch-kit*')" ] && ok || bad "the scratch unzip was left in the home"

# no unzip on PATH: refused, the home's OPatch untouched
home; kit "$T/kit47.zip" 12.2.0.1.47; mkdir -p "$T/bin"
for t in bash sh sed awk grep tr cut sort head tail date mkdir rm mv cat dirname basename env ls find chmod; do ln -sf "$(command -v "$t")" "$T/bin/$t"; done
rc="$(PATH="$T/bin" call "$T/kit47.zip")"
[ "$rc" != 0 ] && works 12.2.0.1.40 && ok || bad "no unzip: rc $rc (want non-zero), home opatch works: $(works 12.2.0.1.40 && echo yes || echo NO): $(tail -2 "$T/out")"
[ -z "$(find "$T/run" -name 'OPatch.old.*')" ] && ok || bad "no unzip: the old OPatch was moved"

# a kit that unzips but holds no runnable opatch: refused, the home's OPatch untouched
home; kit "$T/kitbad.zip" 12.2.0.1.47 no-opatch; rc="$(call "$T/kitbad.zip")"
[ "$rc" != 0 ] && works 12.2.0.1.40 && grep -q 'left as it is' "$T/out" && ok || bad "a kit with no opatch: rc $rc, home works: $(works 12.2.0.1.40 && echo yes || echo NO): $(tail -2 "$T/out")"

# a kit that is not newer: left alone
home; kit "$T/kit30.zip" 12.2.0.1.30; rc="$(call "$T/kit30.zip")"
[ "$rc" = 0 ] && works 12.2.0.1.40 && [ -z "$(find "$T/run" -name 'OPatch.old.*')" ] && ok || bad "an older kit: rc $rc, should be left alone"

echo "db-patch opatch-kit gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
