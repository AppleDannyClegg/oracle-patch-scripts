#!/usr/bin/env bash
# ohs-patch.sh - behavioural gate for patching/ohs-patch/ohs-patch.sh preflight.
#
# Builds a fake standalone OHS 12.2.1.4 home (registry.xml, an opatch stub, domain-registry.xml), one domain with two
# OHS components (ohs1 with Listen ports, ohs2) and a non-OHS system component, the DB19C bundle 40005842 waiting
# unzipped with the real README's OPatch line, and a ps stub. Checks: READY when everything is in order, and each
# blocking problem on its own: an old OPatch, a home on the plain bundle line, no stored node manager credentials,
# a conflict, no OHS component; and that an unreadable ps or a failed lspatches is exit 2 (never READY).
# What it cannot prove: that a real 12.2.1.4 home lays these files out the same way - a real host's preflight is that.
#
# Usage: tests/ohs-patch.sh

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SCRIPT=patching/ohs-patch/ohs-patch.sh
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

OH="$T/ohs"; DOM="$T/domains/ohs_domain"; PD="$T/patches/ohs"
build() {
  rm -rf "${T:?}/ohs" "${T:?}/domains" "${T:?}/patches" "${T:?}/home" "${T:?}/stub" "${T:?}/backup" "${T:?}/inv"
  mkdir -p "$OH/ohs/bin" "$OH/OPatch" "$OH/inventory" "$DOM/config/fmwconfig/components/OHS/instances/ohs1" "$DOM/bin" \
    "$PD/40005842/etc/config" "$T/home/.wlst" "$T/stub" "$T/backup" "$T/inv/ContentsXML"
  echo '<registry><distribution status="installed" name="Oracle HTTP Server (Standalone)" version="12.2.1.4.0"/></registry>' >"$OH/inventory/registry.xml"
  printf 'inventory_loc=%s/inv\n' "$T" >"$OH/oraInst.loc"
  echo "<domain-registry><domain location=\"$DOM\"/></domain-registry>" >"$OH/domain-registry.xml"
  cat >"$DOM/config/config.xml" <<'X'
<domain>
  <name>ohs_domain</name>
  <system-component>
    <name>ohs1</name>
    <component-type>OHS</component-type>
  </system-component>
  <system-component>
    <name>ohs2</name>
    <component-type>OHS</component-type>
  </system-component>
  <system-component>
    <name>otd1</name>
    <component-type>OTD</component-type>
  </system-component>
</domain>
X
  printf 'Listen 7777\n' >"$DOM/config/fmwconfig/components/OHS/instances/ohs1/httpd.conf"
  printf 'Listen 4443\n' >"$DOM/config/fmwconfig/components/OHS/instances/ohs1/ssl.conf"
  : >"$T/home/.wlst/nm-cfg-ohs_domain.props"; : >"$T/home/.wlst/nm-key-ohs_domain.props"
  : >"$PD/40005842/etc/config/inventory.xml"
  printf 'Oracle OHS (Native) DB19C Bundle Patch 12.2.1.4.260910 README\n\n ORACLE_HOME must have OPatch version 13.9.4.2.13 or higher. To verify\n' >"$PD/40005842/README.txt"
  echo "OPatch 13.9.4.2.23" >"$T/opv"
  echo "39611663;OHS (NATIVE) DB19C BUNDLE PATCH 12.2.1.4.260624" >"$T/lsp"
  echo 'Prereq "checkConflictAgainstOHWithDetail" passed.' >"$T/prereq"; echo 0 >"$T/prereq.rc"
  cat >"$OH/OPatch/opatch" <<O
#!/bin/sh
echo "\$*" >>"$T/opatch.log"
case "\$1" in
  version) echo "OPatch Version: \$(cut -d' ' -f2 "$T/opv")"; echo; echo "OPatch succeeded.";;
  lspatches) [ -e "$T/lsp.fail" ] && exit 1; cat "$T/lsp"; echo; echo "OPatch succeeded.";;
  prereq) cat "$T/prereq"; exit "\$(cat "$T/prereq.rc" 2>/dev/null || echo 0)";;
  *) echo "UNEXPECTED opatch \$*" >>"$T/changed"; exit 1;;
esac
O
  chmod +x "$OH/OPatch/opatch"
  # ps: the fake process table, or a failure
  cat >"$T/stub/ps" <<P
#!/bin/sh
[ -e "$T/ps.fail" ] && exit 1
cat "$T/ps.txt" 2>/dev/null; echo "  1 /sbin/launchd"
P
  chmod +x "$T/stub/ps"
  : >"$T/ps.txt"; rm -f "$T/ps.fail" "$T/lsp.fail" "$T/changed" "$T/opatch.log"
}
run() { HOME="$T/home" PATH="$T/stub:$PATH" ORACLE_HOME="" bash "$SCRIPT" preflight "$PD" --oracle-home "$OH" --backup-dir "$T/backup" >"$T/out" 2>&1; echo $?; }

# ready
build
rc="$(run)"
[ "$rc" = 0 ] && ok || bad "a ready home: exit $rc (want 0): $(grep -E 'BLOCKING|UNKNOWN' "$T/out" | head -3)"
grep -q 'READY: nothing blocking' "$T/out" && ok || bad "no READY line on a ready home"
grep -q 'OHS components: ohs1 ohs2$' "$T/out" && ok || bad "components not read as 'ohs1 ohs2' (OTD must be skipped): $(grep components "$T/out")"
grep -q "standalone" "$T/out" && ok || bad "layout not read as standalone"
grep -q "stopComponent.sh ohs1" "$T/out" && grep -q "stopComponent.sh ohs2" "$T/out" && ok || bad "stop commands missing for a component"
grep -q "startComponent.sh ohs2" "$T/out" && ok || bad "start command missing for ohs2"
grep -q "stopNodeManager.sh" "$T/out" && grep -q "startNodeManager.sh" "$T/out" && ok || bad "node manager stop/start not in the commands"
grep -q "localhost:7777" "$T/out" && grep -q "localhost:4443" "$T/out" && ok || bad "ohs1's Listen ports not in the verify commands"
grep -q "opatch' apply -silent -oh '$OH'" "$T/out" && ok || bad "the apply command is missing or not scoped to the home"
grep -q "oraInventory-" "$T/out" && ok || bad "the central inventory is not in the backup commands"
grep -q "meets the README minimum 13.9.4.2.13" "$T/out" && ok || bad "README OPatch minimum not read"
[ ! -e "$T/changed" ] && ok || bad "preflight called a changing opatch verb: $(cat "$T/changed")"

# each blocking problem on its own
build; echo "OPatch 13.9.4.2.10" >"$T/opv"; rc="$(run)"
[ "$rc" = 1 ] && grep -q 'BLOCKING: OPatch 13.9.4.2.10 is older than the 13.9.4.2.13' "$T/out" && ok || bad "old OPatch: rc $rc, $(grep BLOCK "$T/out" | head -2)"
build; echo "36187026;OHS (NATIVE) BUNDLE PATCH 12.2.1.4.240115" >"$T/lsp"; rc="$(run)"
[ "$rc" = 1 ] && grep -q 'BLOCKING: .*plain OHS bundle line.*KB585169' "$T/out" && ok || bad "plain-line home given a DB19C bundle: rc $rc"
build; : >"$T/lsp"; rc="$(run)"
[ "$rc" = 0 ] && grep -q 'WARN .*confirm .*KB585169' "$T/out" && ok || bad "no OHS bundle installed: want a WARN and rc 0, got rc $rc"
build; rm -f "$T/home/.wlst/nm-cfg-ohs_domain.props"; rc="$(run)"
[ "$rc" = 1 ] && grep -q 'BLOCKING: no stored node manager credentials for ohs_domain.*storeUserConfig' "$T/out" && ok || bad "missing NM creds not blocking: rc $rc"
# the real failure shape: the 'Conflicts/Supersets' header must not read as a supersede
build; printf 'Invoking prereq "checkconflictagainstohwithdetail"\nPrereq "checkConflictAgainstOHWithDetail" failed.\nConflicts/Supersets for each patch are:\nPatch : 40005842\n  Conflict with 31000001\n' >"$T/prereq"; rc="$(run)"
[ "$rc" = 1 ] && grep -q 'BLOCKING: conflict check did not pass' "$T/out" && ok || bad "a conflict not blocking: rc $rc"
build; sed -i.bak 's#<component-type>OHS</component-type>#<component-type>X</component-type>#' "$DOM/config/config.xml"; rc="$(run)"
[ "$rc" = 1 ] && grep -q 'BLOCKING: no OHS component' "$T/out" && ok || bad "no OHS component not blocking: rc $rc"

# a non-zero prereq exit with superset-only wording is a conflict (Jocasta P3); a 'Conflict with' under exit 0 too (Cerebro P3)
build; printf 'Conflicts/Supersets for each patch are:\nPatch : 40005842\n  Bug Superset of 31000001\n' >"$T/prereq"; echo 1 >"$T/prereq.rc"; rc="$(run)"
[ "$rc" = 1 ] && grep -q 'BLOCKING: conflict check did not pass for 40005842 (rc 1)' "$T/out" && ok || bad "a non-zero prereq exit was not blocking: rc $rc"
build; printf 'Prereq "checkConflictAgainstOHWithDetail" passed.\nPatch : 40005842\n  Conflict with 31000001\n' >"$T/prereq"; rc="$(run)"
[ "$rc" = 1 ] && grep -q 'BLOCKING: conflict check did not pass' "$T/out" && ok || bad "a 'Conflict with' under exit 0 was not blocking: rc $rc"
build; printf 'Patch 40005842 is a superset of the patch(es) [ 39611663 ]\nOPatch succeeded.\n' >"$T/prereq"; rc="$(run)"
[ "$rc" = 0 ] && grep -q 'supersedes an installed patch' "$T/out" && ok || bad "a superset with exit 0 and no failure should warn, not block: rc $rc"

# running from the home: listed, and WebLogic servers named
build; printf ' 4242 %s/ohs/bin/httpd -d %s/config/fmwconfig/components/OHS/instances/ohs1 -k start\n 4343 /jdk/bin/java -cp %s/oracle_common/x.jar weblogic.NodeManager\n' "$OH" "$DOM" "$OH" >"$T/ps.txt"; rc="$(run)"
grep -q 'pid 4242  OHS ohs1' "$T/out" && grep -q 'pid 4343  node manager' "$T/out" && ok || bad "running OHS / NM not listed: $(grep pid "$T/out")"
[ "$rc" = 0 ] && ok || bad "running processes are listed, not blocking (they are stopped in the window): rc $rc"

# unreadable is never READY
build; touch "$T/ps.fail"; rc="$(run)"
[ "$rc" = 2 ] && ! grep -q READY "$T/out" && grep -q 'UNKNOWN: cannot read the process list' "$T/out" && ok || bad "ps unreadable: rc $rc (want 2, no READY)"
build; touch "$T/lsp.fail"; rc="$(run)"
[ "$rc" = 2 ] && ! grep -q READY "$T/out" && ok || bad "lspatches failed: rc $rc (want 2, no READY)"
build; rc="$(HOME="$T/home" PATH="$T/stub:$PATH" bash "$SCRIPT" preflight "$T/nope" --oracle-home "$OH" >"$T/out" 2>&1; echo $?)"
[ "$rc" = 2 ] && ok || bad "a missing patch dir: rc $rc (want 2)"

echo "ohs-patch gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
