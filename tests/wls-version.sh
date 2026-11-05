#!/usr/bin/env bash
# wls-version.sh - behavioural gate for wls_version, the WebLogic release read from a home.
#
# A real host (5 Nov 2026) got 'could not read the WebLogic release of <home> - get-patches.ps1 will skip its
# patches' from patch-manifest, whose copy read only 'name="WebLogic Server" ... version=' on one line, then
# wlserver/.product.properties; wls-patch had a longer chain, lib the short one. The three scripts must stay
# self-contained (tests/self-contained-gate.sh), so each keeps a copy: this gate checks the three copies are
# identical and runs one against registry.xml shapes - version before the name, a tag over several lines, an FMW
# Infrastructure distribution, .product.properties only, the 10.3.6 <home>/registry.xml, and a registry naming only
# another product (OPatch 13.9 must not be read as a WebLogic release).
#
# Usage: tests/wls-version.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

body() { awk '/^wls_version\(\) *\{/{p=1} p{print} p&&/^}/{exit}' "$1"; }
b1="$(body patching/patch-manifest.sh)"; b2="$(body patching/wls-patch/wls-patch.sh)"; b3="$(body lib/oracle-lib.sh)"
[ -n "$b1" ] && [ "$b1" = "$b2" ] && [ "$b1" = "$b3" ] && ok || bad "the three wls_version copies differ (patch-manifest / wls-patch / lib): $(printf '%s' "$b1" | wc -l) $(printf '%s' "$b2" | wc -l) $(printf '%s' "$b3" | wc -l) lines"

# the function under test: patch-manifest's copy (the one that read empty on the real host)
eval "$(body patching/patch-manifest.sh)"
case_() { # <name> <want> ; the home is $T/h
  local got; got="$(wls_version "$T/h")"
  [ "$got" = "$2" ] && ok || bad "$1: want [$2], got [$got]"; }
fresh() { rm -rf "$T/h"; mkdir -p "$T/h/inventory" "$T/h/wlserver"; }

fresh; echo '<distribution status="installed" name="WebLogic Server" version="12.2.1.4.0"/>' >"$T/h/inventory/registry.xml"; case_ "name then version on one tag" 12.2.1.4.0
fresh; echo '<distribution version="12.2.1.4.0" status="installed" name="WebLogic Server"/>' >"$T/h/inventory/registry.xml"; case_ "version before the name" 12.2.1.4.0
fresh; printf '<registry>\n  <distribution status="installed"\n      name="WebLogic Server"\n      version="14.1.1.0.0">\n  </distribution>\n</registry>\n' >"$T/h/inventory/registry.xml"; case_ "the tag over several lines" 14.1.1.0.0
fresh; printf '<distribution status="installed" name="Fusion Middleware Infrastructure" version="12.2.1.4.0">\n <feature name="WebLogic Server"/>\n</distribution>\n' >"$T/h/inventory/registry.xml"; case_ "an FMW Infrastructure distribution" 12.2.1.4.0
# the name tag over two lines, with another product's version on the line where it starts (Cerebro 19:34 P3):
# only flattening the file reads 12.2.1.4.0; line by line the fallback would take Coherence's 12.2.1.3.0
fresh; printf '<distribution name="Oracle Coherence" version="12.2.1.3.0"/><distribution status="installed"\n    name="WebLogic Server" version="12.2.1.4.0"/>\n' >"$T/h/inventory/registry.xml"; case_ "the name tag split after another product's version" 12.2.1.4.0
fresh; echo 'WLS_PRODUCT_VERSION=12.1.3.0.0' >"$T/h/wlserver/.product.properties"; case_ ".product.properties only" 12.1.3.0.0
fresh; rm -rf "$T/h/inventory"; echo '<component name="WebLogic Server" version="10.3.6.0" InstallDir="/x/wlserver_10.3"/>' >"$T/h/registry.xml"; case_ "the 10.3.6 <home>/registry.xml" 10.3.6.0
fresh; printf '<distribution name="Oracle Coherence" version="12.2.1.4.0"/>\n' >"$T/h/inventory/registry.xml"; case_ "only a co-installed 12.2.1.4 product" 12.2.1.4.0
fresh; printf '<component name="OPatch" version="13.9.4.2.23"/>\n' >"$T/h/inventory/registry.xml"; case_ "only OPatch 13.9 in the registry (not a WebLogic release)" ""
fresh; case_ "nothing to read" ""

echo "wls-version gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
