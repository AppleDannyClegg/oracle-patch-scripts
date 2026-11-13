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
# SKIP, not FAIL, when the host has no zip/unzip: the two zip-only folder cases (dry-run, plan) build their fixture
# with `zip` and the script reads it with `unzip`. Measured 10 Nov 2026 on both: macOS with a PATH mask holding
# every /usr/bin and /bin entry except those two (Edi, T213 check) and oraclelinux:8, which has neither (the
# container lane). The tally counts ASSERTIONS not run, per case, so ', 2 skipped (7 assertions not run)' is not
# read as two missed assertions. Making those cases RUN rather than skip means installing zip and unzip in the
# image (dnf at build time, needs network) - not done, so the container lane still does not exercise the zip path.
#
# Usage: tests/ohs-patch.sh

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SCRIPT=patching/ohs-patch/ohs-patch.sh
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
# an explicit umask, so the permission assertions below do not depend on who runs the gate. GATE_UMASK=0077 re-runs it tight
umask "${GATE_UMASK:-0022}"
pass=0; fail=0; skipped=0; skipped_asserts=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }
# skip <reason> <assertions-not-run>: a case that CANNOT run here (a fixture tool this image does not have) is not a
# failure and not a pass. It is counted and named, with the number of assertions behind it, so a green summary says
# how much of the gate actually ran and 'skipped 2' is not read as 'two assertions' (T213, T263).
# The count is enforced, not assumed (T303). Measured, because the first account of this was wrong (Puck #13646):
#   skip "reason"        -> "$2: unbound variable" under set -u, rc 1, no summary line. Loud already, but it names a
#                          line number, not the case that forgot its count.
#   skip "reason" 2x     -> error "value too great for base", and the function CARRIES ON with skipped_asserts
#                          unchanged, so the summary says "1 skipped (0 assertions not run)" - the silent under-count.
# This guard names the case and stops the gate before either shape can be read as a tally.
skip() {
  case "${2:-}" in
    '' | *[!0-9]*) echo "FAIL skip(): '$1' needs an assertion count as its second argument"; exit 1 ;;
  esac
  skipped=$((skipped + 1)); skipped_asserts=$((skipped_asserts + $2)); echo "SKIP $1 ($2 assertions not run)";
}
# the zip fixtures need both: zip to build the archive, unzip for the script to read it (oraclelinux:8 has neither)
have_zip() { command -v zip >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; }

OH="$T/ohs"; DOM="$T/domains/ohs_domain"; PD="$T/patches/ohs"; LSP="$T/ohs/inventory/lsp.txt"  # in the home: a restore brings the old list back
# The script starts node manager with 'nohup ... &' and never waits for it (correct: it is a daemon). The stub is
# therefore a child that can run AFTER the script has exited: under suite load its 'startNM' landed in the NEXT
# case's actions ("plan is not read-only: actions [startNM]") or missed its own. So (1) every script run settles:
# it waits for as many finished node-manager stubs as the run logged launches; (2) each case has an id baked into
# the stub, and a stub from an earlier case writes nothing.
CASE=0
settle() {
  local n; n="$(grep -cF 'startNodeManager.sh &' "$T/out" 2>/dev/null | head -1)"
  n=$(( ${n:-0} - $(grep -cF 'would run nohup' "$T/out" 2>/dev/null || true) ))
  [ "$n" -gt 0 ] || return 0
  echo $(( $(cat "$T/nm.launched" 2>/dev/null || echo 0) + n )) >"$T/nm.launched"
  for _ in $(seq 1 100); do
    [ "$(wc -l <"$T/nm.done" 2>/dev/null || echo 0)" -ge "$(cat "$T/nm.launched")" ] && return 0
    sleep 0.1
  done
  echo "WARN settle: node manager stub not finished after 10s" >&2
}
build() {
  CASE=$((CASE + 1)); echo "$CASE" >"$T/case"; rm -f "$T/nm.launched" "$T/nm.done"
  rm -rf "${T:?}/ohs" "${T:?}"/ohs.failed-* "${T:?}/domains" "${T:?}/patches" "${T:?}/home" "${T:?}/stub" "${T:?}/backup" "${T:?}/inv" "${T:?}/runs" "${T:?}"/inv.failed-*
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
  echo "39611663;OHS (NATIVE) DB19C BUNDLE PATCH 12.2.1.4.260624" >"$LSP"
  echo 'Prereq "checkConflictAgainstOHWithDetail" passed.' >"$T/prereq"; echo 0 >"$T/prereq.rc"
  printf 'Invoking prereq "checkapplicable"\n\nPrereq "checkApplicable" passed.\n\nOPatch succeeded.\n' >"$T/applicable"; echo 0 >"$T/applicable.rc"
  cat >"$OH/OPatch/opatch" <<O
#!/bin/sh
echo "\$*" >>"$T/opatch.log"
case "\$1" in
  version) echo "OPatch Version: \$(cut -d' ' -f2 "$T/opv")"; echo; echo "OPatch succeeded.";;
  lspatches) [ -e "$T/lsp.fail" ] && exit 1; cat "$LSP"; echo; echo "OPatch succeeded.";;
  apply) echo "apply" >>"$T/actions"
    [ -e "$T/apply.partial" ] && : >"$OH/ohs/PATCHED"
    [ -e "$T/apply.corrupt" ] && for b in "$T"/backup/*/home.tgz; do : >"\$b"; echo x >"\$b"; done
    [ -e "$T/apply.fail" ] && { echo "OPatch failed with error code 73"; exit 73; }
    : >"$OH/ohs/PATCHED"
    [ -e "$T/apply.noop" ] || echo "40005842;OHS (NATIVE) DB19C BUNDLE PATCH 12.2.1.4.260910" >>"$LSP"
    echo "OPatch succeeded.";;
  prereq) case "\$2" in
      CheckApplicable) cat "$T/applicable"; exit "\$(cat "$T/applicable.rc" 2>/dev/null || echo 0)";;
      *) cat "$T/prereq"; exit "\$(cat "$T/prereq.rc" 2>/dev/null || echo 0)";;
    esac;;
  *) echo "UNEXPECTED opatch \$*" >>"$T/changed"; exit 1;;
esac
O
  chmod +x "$OH/OPatch/opatch"
  # ps: the fake process table, or a failure. A PPID query is answered by the REAL ps, so the script's
  # ancestor walk (T1529) sees the real parent chain while the process table stays fake.
  REAL_PS="$(command -v ps)"
  cat >"$T/stub/ps" <<P
#!/bin/sh
case "\$*" in *ppid*) exec "$REAL_PS" "\$@";; esac
[ -e "$T/ps.fail" ] && exit 1
cat "$T/ps.txt" 2>/dev/null; echo "  1 /sbin/launchd"
P
  chmod +x "$T/stub/ps"
  # node manager and component scripts: log the action and change the fake process table
  cat >"$DOM/bin/stopComponent.sh" <<S
#!/bin/sh
echo "stop \$1" >>"$T/actions"
# a node manager whose credentials are not stored asks for its password on stdin
[ -e "$T/stop.prompt" ] && { printf 'Enter Node Manager password: '; read -r pw || exit 1; echo "password read" >>"$T/actions"; }
[ -e "$T/stop.fail" ] && exit 1
[ -e "$T/stop.stuck" ] || { grep -v "instances/\$1 " "$T/ps.txt" >"$T/ps.new"; mv "$T/ps.new" "$T/ps.txt"; }
[ -e "$T/ps.fail.after-stop" ] && touch "$T/ps.fail"
exit 0
S
  cat >"$DOM/bin/stopNodeManager.sh" <<S
#!/bin/sh
echo "stopNM" >>"$T/actions"; [ -e "$T/nm.down" ] && { echo "Node Manager is not running" >&2; exit 3; }; grep -v "weblogic.NodeManager" "$T/ps.txt" >"$T/ps.new"; mv "$T/ps.new" "$T/ps.txt"; exit 0
S
  cat >"$DOM/bin/startNodeManager.sh" <<S
#!/bin/sh
[ "\$(cat "$T/case")" = "$CASE" ] || exit 0
echo "startNM" >>"$T/actions"; echo " 5151 /jdk/bin/java -cp $OH/oracle_common/x.jar weblogic.NodeManager" >>"$T/ps.txt"; echo done >>"$T/nm.done"; exit 0
S
  cat >"$DOM/bin/startComponent.sh" <<S
#!/bin/sh
echo "start \$1" >>"$T/actions"
# a patched home that will not start (the start-failure case), or a start that always fails
[ -e "$T/start.fail-patched" ] && [ -e "$OH/ohs/PATCHED" ] && exit 1
[ -e "$T/start.fail" ] && exit 1
echo " 6\$\$ $OH/ohs/bin/httpd -d $DOM/config/fmwconfig/components/OHS/instances/\$1 -k start" >>"$T/ps.txt"; exit 0
S
  printf '#!/bin/sh\n[ -e "%s/curl.fail" ] && { printf 000; exit 7; }\nprintf 200\n' "$T" >"$T/stub/curl"
  chmod +x "$DOM/bin/"*.sh "$T/stub/curl"
  : >"$T/ps.txt"; rm -f "$T/nm.down" "$T"/*.fail "$T"/*.fail-patched "$T"/apply.* "$T"/stop.* "$T/ps.fail.after-stop" "$T/nm.down" "$T/changed" "$T/opatch.log" "$T/actions"
}
run() { HOME="$T/home" PATH="$T/stub:$PATH" ORACLE_HOME="" bash "$SCRIPT" preflight "$PD" --oracle-home "$OH" --backup-dir "$T/backup" >"$T/out" 2>&1; echo $?; }

# inspect: read-only, no patch dir needed, and it must not create a run dir or a backup
build
mkdir -p "$T/runs"
rc="$(HOME="$T/home" PATH="$T/stub:$PATH" ORACLE_HOME="" RUN_BASE="$T/runs" bash "$SCRIPT" inspect --oracle-home "$OH" --backup-dir "$T/backup" >"$T/out" 2>&1; echo $?)"
[ "$rc" = 0 ] && ok || bad "inspect on a real-shaped home: exit $rc (want 0): $(tail -3 "$T/out")"
grep -q "home     : $OH (OHS 12.2.1.4.0, standalone)" "$T/out" && ok || bad "inspect does not print the home, release and layout: $(grep 'home ' "$T/out")"
grep -q 'OPatch   : 13.9.4.2.23' "$T/out" && ok || bad "inspect does not print the OPatch version: $(grep OPatch "$T/out")"
grep -q 'component: ohs1' "$T/out" && grep -q 'component: ohs2' "$T/out" && ok || bad "inspect does not list the OHS components"
grep -q 'series    : plain OHS bundle line\|series    : DB19C line\|series    : no OHS bundle installed yet' "$T/out" && ok || bad "inspect does not say which bundle series the home is on"
grep -q 'running  :' "$T/out" && ok || bad "inspect does not report what runs from the home"
[ -z "$(find "$T/runs" -mindepth 1 2>/dev/null)" ] && ok || bad "inspect created a run dir - it must change nothing"
ls "$T/backup"/*.tgz >/dev/null 2>&1 && bad "inspect wrote a backup" || ok

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
# the README's minimum in the other wordings Oracle uses (wls-patch reads "OPatch (utility )?(version )?N"): each one is
# read, so an OPatch below it blocks; a miss would only WARN "check the README by hand" (T1161, Louie #16003)
for w in 'use the OPatch utility version 13.9.4.2.30 or later' 'OPatch 13.9.4.2.30 or higher' 'OPatch version 13.9.4.2.30 or above'; do
  build; printf 'Oracle OHS (Native) DB19C Bundle Patch README\n\n You must %s. To verify\n' "$w" >"$PD/40005842/README.txt"; rc="$(run)"
  [ "$rc" = 1 ] && grep -q 'BLOCKING: OPatch 13.9.4.2.23 is older than the 13.9.4.2.30' "$T/out" && ok || bad "README '$w' not read as the OPatch minimum: rc $rc, $(grep -E 'BLOCK|README' "$T/out" | head -2)"
done
# an OPatch version named without 'or later/higher/above' is not a minimum (a README also names versions it was built
# with): only the minimum line counts, so 13.9.4.2.23 still meets 13.9.4.2.13
build; printf 'Bundle Patch README\n\n tested with OPatch 13.9.4.2.30\n ORACLE_HOME must have OPatch version 13.9.4.2.13 or higher.\n' >"$PD/40005842/README.txt"; rc="$(run)"
grep -q "meets the README minimum 13.9.4.2.13" "$T/out" && ! grep -q 'BLOCKING: OPatch' "$T/out" && ok || bad "a plain OPatch version mention was read as the minimum: rc $rc, $(grep -E 'BLOCK|README|meets' "$T/out" | head -2)"
build; echo "36187026;OHS (NATIVE) BUNDLE PATCH 12.2.1.4.240115" >"$LSP"; rc="$(run)"
[ "$rc" = 1 ] && grep -q 'BLOCKING: .*plain OHS bundle line.*KB585169' "$T/out" && ok || bad "plain-line home given a DB19C bundle: rc $rc"
build; : >"$LSP"; rc="$(run)"
[ "$rc" = 0 ] && grep -q 'WARN .*confirm .*KB585169' "$T/out" && ok || bad "no OHS bundle installed: want a WARN and rc 0, got rc $rc"
build; rm -f "$T/home/.wlst/nm-cfg-ohs_domain.props"; rc="$(run)"
[ "$rc" = 1 ] && grep -q 'BLOCKING: no stored node manager credentials for ohs_domain.*storeUserConfig' "$T/out" && ok || bad "missing NM creds not blocking: rc $rc"
# the real failure shape: the 'Conflicts/Supersets' header must not read as a supersede
build; printf 'Invoking prereq "checkconflictagainstohwithdetail"\nPrereq "checkConflictAgainstOHWithDetail" failed.\nConflicts/Supersets for each patch are:\nPatch : 40005842\n  Conflict with 31000001\n' >"$T/prereq"; rc="$(run)"
[ "$rc" = 1 ] && grep -q 'BLOCKING: conflict check did not pass' "$T/out" && ok || bad "a conflict not blocking: rc $rc"
build; sed -i.bak 's#<component-type>OHS</component-type>#<component-type>X</component-type>#' "$DOM/config/config.xml"; rc="$(run)"
[ "$rc" = 1 ] && grep -q 'BLOCKING: no OHS component' "$T/out" && ok || bad "no OHS component not blocking: rc $rc"

# the Database Client level in the home, from its inventory (KB585169's own check: oracle.rdbms.rsf in comps.xml)
comps() { mkdir -p "$OH/inventory/ContentsXML"; printf '<PRD_LIST>\n<COMP NAME="oracle.ohs2" VER="12.2.1.4.0"/>\n<COMP NAME="oracle.rdbms.rsf" VER="%s" BUILD_NUMBER="0" REP_VER="0.0.0.0.0"/>\n</PRD_LIST>\n' "$1" >"$OH/inventory/ContentsXML/comps.xml"; }
build; comps 12.1.0.2.0; rc="$(run)"
[ "$rc" = 1 ] && grep -q 'BLOCKING: .*Database Client.*oracle.rdbms.rsf is 12.1.0.2.0.*34761383.*KB585169' "$T/out" && ok || bad "a 12c client home given a DB19C bundle was not blocking on the client level: rc $rc, $(grep -E 'BLOCK|WARN.*KB585169|client' "$T/out" | head -3)"
build; comps 19.0.0.0.0; rc="$(run)"
[ "$rc" = 0 ] && grep -q 'DB client : oracle.rdbms.rsf 19.0.0.0.0' "$T/out" && ! grep -q 'WARN .*confirm .*KB585169' "$T/out" && ok || bad "a 19c client home with no bundle: rc $rc (want 0, the client level printed, no 'confirm' warning)"
build; echo "34567890;OHS (NATIVE) BUNDLE PATCH 12.2.1.4.240115" >"$LSP"; comps 12.1.0.2.0; rc="$(run)"
[ "$rc" = 1 ] && grep -q 'oracle.rdbms.rsf is 12.1.0.2.0' "$T/out" && ok || bad "plain-line home with a 12c client: rc $rc"
build; comps 12.1.0.2.0; rc="$(HOME="$T/home" PATH="$T/stub:$PATH" ORACLE_HOME="" RUN_BASE="$T/runs" bash "$SCRIPT" inspect --oracle-home "$OH" >"$T/out" 2>&1; echo $?)"
grep -q 'DB client : oracle.rdbms.rsf 12.1.0.2.0' "$T/out" && ok || bad "inspect does not print the Database Client level: $(grep -i client "$T/out")"
# REP_VER before VER is not read as the version (patch-manifest's comp_version gotcha, Edi 22:04:46)
build; mkdir -p "$OH/inventory/ContentsXML"; printf '<COMP NAME="oracle.rdbms.rsf" REP_VER="19.0.0.0.0" VER="12.1.0.2.0"/>\n' >"$OH/inventory/ContentsXML/comps.xml"; rc="$(run)"
[ "$rc" = 1 ] && grep -q 'oracle.rdbms.rsf is 12.1.0.2.0' "$T/out" && ok || bad "REP_VER was read as the client version: rc $rc, $(grep 'DB client' "$T/out")"
build; rc="$(run)"
grep -q 'DB client : unknown' "$T/out" && ok || bad "no comps.xml: the client level is not reported as unknown"

# the home lacks a component the patch needs (Gen's host: a DB19C bundle on a home whose Database Client is still
# 12c, opatch apply failed with OUI-67073 after the stop and backup): OPatch's CheckApplicable says so, read-only
miss='Invoking prereq "checkapplicable"
Prereq "checkApplicable" failed.
OUI-67073:UtilSession failed: Patch 40005842 requires component(s) that are not installed in OracleHome.  Or don'"'"'t have required patch level. These not-installed components are oracle.rdbms.rsf:19.0.0.0.0:patchlevel-(or higher)
OPatch failed with error code 73'
build; printf '%s\n' "$miss" >"$T/applicable"; echo 73 >"$T/applicable.rc"; rc="$(run)"
[ "$rc" = 1 ] && grep -q 'BLOCKING: .*40005842 needs .*oracle.rdbms.rsf:19.0.0.0.0.*KB585169' "$T/out" && ! grep -q READY "$T/out" && ok || bad "a home missing a required component was not blocking: rc $rc, $(grep -E 'BLOCK|applicable|WARN' "$T/out" | head -3)"

# --client-19c-pending (ohs-quarter.sh passes it when the DB Client 19c installer runs first in the same outage):
# field run 12 Nov 2026, 40005842 on the 12c client refused at 1/7 although the upgrade was the step before it
runp() { HOME="$T/home" PATH="$T/stub:$PATH" ORACLE_HOME="" bash "$SCRIPT" preflight "$PD" --oracle-home "$OH" --backup-dir "$T/backup" --client-19c-pending >"$T/out" 2>&1; echo $?; }
build; comps 12.1.0.2.0; printf '%s\n' "$miss" >"$T/applicable"; echo 73 >"$T/applicable.rc"; rc="$(runp)"
[ "$rc" = 0 ] && ! grep -q BLOCKING "$T/out" && grep -q 'series   : 40005842 is a DB19C bundle; oracle.rdbms.rsf is 12.1.0.2.0 now' "$T/out" && grep -q 'WARN .*components: CheckApplicable did not pass on the 12c client.*deferred' "$T/out" && ok || bad "--client-19c-pending: a DB19C set on a 12c client was not deferred: rc $rc: $(grep -E 'BLOCK|series|components' "$T/out" | head -3)"
build; comps 12.1.0.2.0; printf '%s\n' "$miss" >"$T/applicable"; echo 73 >"$T/applicable.rc"; rc="$(run)"
[ "$rc" = 1 ] && grep -q 'BLOCKING: .*oracle.rdbms.rsf is 12.1.0.2.0' "$T/out" && ok || bad "without --client-19c-pending a 12c client still has to block: rc $rc"
# the deferral is for the 19c client alone (T1167, Louie #16016): any other missing component, a bare "failed", or no
# verdict still stops preflight with the flag, or a patch that can never apply is found after the stop
# blocks19 <label> <CheckApplicable output>: with the flag, that answer must still block and not be deferred
blocks19() {
  build; comps 12.1.0.2.0; printf '%s\n' "$2" >"$T/applicable"; echo 73 >"$T/applicable.rc"; rc="$(runp)"
  [ "$rc" = 1 ] && grep -q 'BLOCKING: .*40005842' "$T/out" && ! grep -q 'deferred' "$T/out" && ok || bad "--client-19c-pending deferred a CheckApplicable that is not the 19c client alone ($1): rc $rc: $(grep -E 'BLOCK|deferred' "$T/out" | head -2)"
}
blocks19 other "$(printf '%s\n' "$miss" | sed 's/oracle.rdbms.rsf:19.0.0.0.0:patchlevel-(or higher)/oracle.webgate.ohs:12.2.1.4.0/')"
blocks19 both "$(printf '%s\n' "$miss" | sed 's/oracle.rdbms.rsf:19.0.0.0.0:patchlevel-(or higher)/oracle.rdbms.rsf:19.0.0.0.0:patchlevel-(or higher),oracle.webgate.ohs:12.2.1.4.0/')"
blocks19 rsf21 "$(printf '%s\n' "$miss" | sed 's/oracle.rdbms.rsf:19.0.0.0.0:/oracle.rdbms.rsf:21.0.0.0.0:/')"
blocks19 bare 'Invoking prereq "checkapplicable"
Prereq "checkApplicable" for patch 40005842 failed.
OPatch failed with error code 73'
build; comps 12.1.0.2.0; printf 'Exception in thread main\n' >"$T/applicable"; echo 1 >"$T/applicable.rc"; rc="$(runp)"
[ "$rc" = 2 ] && grep -q 'UNKNOWN: opatch prereq CheckApplicable gave no verdict' "$T/out" && ok || bad "--client-19c-pending turned no verdict into a pass: rc $rc: $(grep -E 'UNKNOWN|deferred' "$T/out" | head -2)"
build; comps 12.1.0.2.0; rc="$(run)"
grep 'DB client :' "$T/out" | grep -q 'oracle.rdbms.rsf 12.1.0.2.0$' && ok || bad "the client level is printed twice or wrong: $(grep 'DB client' "$T/out")"

# a zip that is not an OPatch patch (no etc/config/inventory.xml inside: an unzip-into-place tool, say) is refused
# by preflight, before the outage (T1067: ohs-quarter.sh applies RDA 39798204 through this script, unverified)
if have_zip; then
  build; rm -rf "${PD:?}/40005842"; mkdir -p "$T/tool/rda"; echo '#!/bin/sh' >"$T/tool/rda/rda.sh"
  (cd "$T/tool" && zip -q -r "$PD/p39798204_122140_Generic.zip" rda); rm -f "$T/opatch.log"; rc="$(run)"
  [ "$rc" = 2 ] && grep -q 'no patch in .*etc/config/inventory.xml' "$T/out" && ! grep -q READY "$T/out" && ! grep -qE '^(apply|prereq)' "$T/opatch.log" 2>/dev/null && ok || bad "a zip that is not an OPatch patch was not refused at preflight: rc $rc, $(tail -2 "$T/out")"
  rm -rf "${T:?}/tool"
else skip "a non-OPatch zip refused at preflight (no zip/unzip)" 1; fi
# CheckApplicable failing for another reason blocks with its own words; one that cannot run is UNKNOWN, never READY
build; printf 'Prereq "checkApplicable" failed.\nPatch 40005842: Platform 46 is not supported\n' >"$T/applicable"; echo 1 >"$T/applicable.rc"; rc="$(run)"
[ "$rc" = 1 ] && grep -q 'BLOCKING: .*not applicable.*Platform 46' "$T/out" && ok || bad "a failed CheckApplicable was not blocking: rc $rc: $(grep BLOCK "$T/out")"
build; printf 'Exception in thread main\n' >"$T/applicable"; echo 1 >"$T/applicable.rc"; rc="$(run)"
[ "$rc" = 2 ] && ! grep -q READY "$T/out" && grep -q 'UNKNOWN: .*CheckApplicable' "$T/out" && ok || bad "an unreadable CheckApplicable was not UNKNOWN: rc $rc"
build; printf 'Invoking prereq "checkapplicable"\nline two\nline three\nPrereq "checkApplicable" is OK.\nOPatch succeeded.\n' >"$T/applicable"; echo 0 >"$T/applicable.rc"; rc="$(run)"
grep 'UNKNOWN: .*CheckApplicable' "$T/out" | grep -q 'Prereq "checkApplicable" is OK. OPatch succeeded.' && ok || bad "an UNKNOWN CheckApplicable does not quote OPatch's last lines: $(grep 'UNKNOWN' "$T/out")"
# field wording (12 Nov 2026, OPatch 13.9.4.2.25): 'Prereq "checkApplicable" for patch <id> passed.' is a pass, and
# 'for patch <id> failed.' a block - the plain 'passed' match read the real pass as no verdict (UNKNOWN)
build; printf 'Oracle Interim Patch Installer version 13.9.4.2.25\nInvoking prereq "checkapplicable"\n\nPrereq "checkApplicable" for patch 39425385 passed.\n\nOPatch succeeded.\n' >"$T/applicable"; echo 0 >"$T/applicable.rc"; rc="$(run)"
! grep -q 'UNKNOWN: .*CheckApplicable' "$T/out" && grep -q 'components: every component' "$T/out" && ok || bad "OPatch 13.9.4.2.25's 'for patch N passed' was not a pass: rc $rc: $(grep -E 'UNKNOWN|components' "$T/out" | head -2)"
build; printf 'Prereq "checkApplicable" for patch 40005842 failed.\nPatch 40005842: Platform 46 is not supported\n' >"$T/applicable"; echo 1 >"$T/applicable.rc"; rc="$(run)"
[ "$rc" = 1 ] && grep -q 'BLOCKING: .*not applicable.*Platform 46' "$T/out" && ok || bad "'for patch N failed' was not blocking: rc $rc: $(grep -E 'BLOCK|UNKNOWN' "$T/out" | head -2)"
build; printf 'OPatch succeeded.\n' >"$T/applicable"; echo 0 >"$T/applicable.rc"; rc="$(run)"
[ "$rc" = 2 ] && grep -q 'UNKNOWN: .*CheckApplicable' "$T/out" && ok || bad "rc 0 without the 'passed' line was taken as a pass: rc $rc"
build; rc="$(run)"
grep -q 'components: every component 40005842 needs is in' "$T/out" && ok || bad "a passing CheckApplicable is not reported"

# a non-zero prereq exit with superset-only wording is a conflict (Jocasta P3); a 'Conflict with' under exit 0 too (Cerebro P3)
build; printf 'Conflicts/Supersets for each patch are:\nPatch : 40005842\n  Bug Superset of 31000001\n' >"$T/prereq"; echo 1 >"$T/prereq.rc"; rc="$(run)"
[ "$rc" = 1 ] && grep -q 'BLOCKING: conflict check did not pass for 40005842 (rc 1)' "$T/out" && ok || bad "a non-zero prereq exit was not blocking: rc $rc"
build; printf 'Prereq "checkConflictAgainstOHWithDetail" passed.\nPatch : 40005842\n  Conflict with 31000001\n' >"$T/prereq"; rc="$(run)"
[ "$rc" = 1 ] && grep -q 'BLOCKING: conflict check did not pass' "$T/out" && ok || bad "a 'Conflict with' under exit 0 was not blocking: rc $rc"
build; printf 'Patch 40005842 is a superset of the patch(es) [ 39611663 ]\nOPatch succeeded.\n' >"$T/prereq"; rc="$(run)"
[ "$rc" = 0 ] && grep -q 'supersedes an installed patch' "$T/out" && ok || bad "a superset with exit 0 and no failure should warn, not block: rc $rc"
# OPatch 13.9.4.2.25 wording for the conflict prereq too (T1162): 'for patch <id> passed.' is no conflict, and
# 'for patch <id> failed.' with only a superset under exit 0 is still a block, not the superset warning
build; printf 'Invoking prereq "checkconflictagainstohwithdetail"\n\nPrereq "checkConflictAgainstOHWithDetail" for patch 40005842 passed.\n\nOPatch succeeded.\n' >"$T/prereq"; rc="$(run)"
[ "$rc" = 0 ] && grep -q 'conflicts: none' "$T/out" && ok || bad "the conflict prereq's 'for patch N passed' was not 'conflicts: none': rc $rc: $(grep -E 'BLOCK|conflict' "$T/out" | head -2)"
build; printf 'Prereq "checkConflictAgainstOHWithDetail" for patch 40005842 failed.\nConflicts/Supersets for each patch are:\nPatch : 40005842\n  Bug Superset of 31000001\n' >"$T/prereq"; rc="$(run)"
[ "$rc" = 1 ] && grep -q 'BLOCKING: conflict check did not pass for 40005842 (rc 0)' "$T/out" && ok || bad "'for patch N failed' with only a superset under exit 0 was not blocking: rc $rc: $(grep -E 'BLOCK|supersedes' "$T/out" | head -2)"

# running from the home: listed, and WebLogic servers named
build; printf ' 4242 %s/ohs/bin/httpd -d %s/config/fmwconfig/components/OHS/instances/ohs1 -k start\n 4343 /jdk/bin/java -cp %s/oracle_common/x.jar weblogic.NodeManager\n' "$OH" "$DOM" "$OH" >"$T/ps.txt"; rc="$(run)"
grep -q 'pid 4242  OHS ohs1' "$T/out" && grep -q 'pid 4343  node manager' "$T/out" && ok || bad "running OHS / NM not listed: $(grep pid "$T/out")"
[ "$rc" = 0 ] && ok || bad "running processes are listed, not blocking (they are stopped in the window): rc $rc"

# the home as a path boundary: a process whose argument IS the home is running from it; a sibling <home>2 is not
# T1541: a startNodeManager.sh launcher left by a failed restart holds the home in its argv but is only the
# supervisor; the Node Manager java is still listed, so the stop proof does not block forever on the wrapper
build; printf ' 4545 /bin/sh %s/bin/startNodeManager.sh\n 4546 /jdk/bin/java -cp %s/oracle_common/x.jar weblogic.NodeManager\n' "$OH" "$OH" >"$T/ps.txt"; rc="$(run)"
! grep -q 'pid 4545' "$T/out" && grep -q 'pid 4546' "$T/out" && ok || bad "the startNodeManager.sh launcher is treated as an occupant, or the Node Manager java is missed (T1541)"
build; printf ' 4545 /bin/sh %s/ohs/bin/x\n' "${OH}2" >"$T/ps.txt"; rc="$(run)"
! grep -q 'pid 4545' "$T/out" && ok || bad "a process under the sibling ${OH}2 was read as running from $OH"
build; printf ' 4646 /usr/bin/java -Dhome=%s weblogic.NodeManager\n' "$OH" >"$T/ps.txt"; rc="$(run)"
grep -q 'pid 4646' "$T/out" && ok || bad "a process naming the home exactly (no trailing slash) was missed"
# T1529: this script's CALLER holds the home in its args; it is an ancestor, not an occupant. RED before the fix,
# which skipped only the script's own name. A non-ancestor that holds the home is still listed.
build
cat >"$T/caller.sh" <<S
#!/bin/bash
echo \$\$ >"$T/caller.pid"
printf ' %s bash %s %s\n' "\$\$" "\$0" "\$*" >>"$T/ps.txt"
PATH="$T/stub:\$PATH" HOME="$T/home" ORACLE_HOME="" bash "$PWD/$SCRIPT" preflight "$PD" --oracle-home "$OH" --backup-dir "$T/backup" >>"$T/out" 2>&1
S
chmod +x "$T/caller.sh"
printf ' 7777 /usr/bin/tail -f %s/logs/x.log\n 8888 bash %s inspect --oracle-home %s\n' "$OH" "$SCRIPT" "$OH" >"$T/ps.txt"
bash "$T/caller.sh" --oracle-home "$OH"; rc=$?
wid="$(cat "$T/caller.pid")"
! grep -q "pid $wid" "$T/out" && ok || bad "T1529: the caller (pid $wid), an ancestor holding the home, was listed as an occupant"
grep -q 'pid 7777' "$T/out" && ok || bad "T1529: a non-ancestor holding the home (pid 7777) was not listed"
! grep -q 'pid 8888' "$T/out" && ok || bad "T1529: this script's own command-substitution subshell (pid 8888) was listed as an occupant"
# an unknown OPatch version is never reported as meeting the README minimum
build; sed -i.bak 's#echo "OPatch Version: .*#echo "OPatch Version: ";;#' "$OH/OPatch/opatch"; rc="$(run)"
[ "$rc" = 2 ] && ! grep -q 'meets the README minimum' "$T/out" && ok || bad "unknown OPatch version: rc $rc, $(grep -E 'meets|OPatch' "$T/out" | head -2)"

# unreadable is never READY
build; touch "$T/ps.fail"; rc="$(run)"
[ "$rc" = 2 ] && ! grep -q READY "$T/out" && grep -q 'UNKNOWN: cannot read the process list' "$T/out" && ok || bad "ps unreadable: rc $rc (want 2, no READY)"
build; touch "$T/lsp.fail"; rc="$(run)"
[ "$rc" = 2 ] && ! grep -q READY "$T/out" && ok || bad "lspatches failed: rc $rc (want 2, no READY)"
build; rc="$(HOME="$T/home" PATH="$T/stub:$PATH" bash "$SCRIPT" preflight "$T/nope" --oracle-home "$OH" >"$T/out" 2>&1; echo $?)"
[ "$rc" = 2 ] && ok || bad "a missing patch dir: rc $rc (want 2)"

# ---- run -------------------------------------------------------------------------------------------------
runr() { HOME="$T/home" PATH="$T/stub:$PATH" ORACLE_HOME="" START_TIMEOUT=1 POLL=1 RUN_BASE="$T/runs" \
  bash "$SCRIPT" run "$PD" --oracle-home "$OH" --backup-dir "$T/backup" "$@" >"$T/out" 2>&1 </dev/null; echo $?; settle; }
acts() { tr '\n' ' ' 2>/dev/null <"$T/actions"; }
running() { printf ' 4242 %s/ohs/bin/httpd -d %s/config/fmwconfig/components/OHS/instances/ohs1 -k start\n 4343 /jdk/bin/java -cp %s/oracle_common/x.jar weblogic.NodeManager\n' "$OH" "$DOM" "$OH" >"$T/ps.txt"; }
nobackup() { [ -z "$(find "$T/backup" -mindepth 1 2>/dev/null)" ]; }
st() { cat "$T"/runs/*/state 2>/dev/null; }

# applied: backup, stop all, apply, start all, verified
build; running; rc="$(runr --yes)"
[ "$rc" = 0 ] && ok || bad "run on a ready home: rc $rc: $(grep -E 'ERROR|BLOCK' "$T/out" | head -3)"
a="$(acts)"
case "$a" in "stop ohs1 stop ohs2 stopNM apply "*"start ohs1"*"start ohs2"*) ok;; *) bad "run order wrong: [$a]";; esac
case "$a" in *startNM*) ok;; *) bad "node manager not started: [$a]";; esac
[ "$(find "$T"/backup/ohs-40005842-* -name '*.tgz' | wc -l | tr -d ' ')" = 3 ] && ok || bad "backup not home + domain + inventory: $(find "$T/backup" -name '*.tgz' | tr '\n' ' ')"
st | grep -q '^applied=40005842$' && st | grep -q '^outcome=applied$' && ok || bad "state does not record the apply: $(st | tr '\n' ' ')"
grep -q 'applied and verified' "$T/out" && ok || bad "no 'applied and verified' line"
# the run dir, its command log and the rollback archives hold wallets and credentials: owner-only whatever umask
# the host hands the script. This gate sets 022 at its top (the common default, and the one that used to leave them
# 755/644); run it again under 'umask 077' and these must read the same.
pm() { ls -ld "$1" 2>/dev/null | cut -c1-10; }
_bk="$(ls -d "$T"/backup/ohs-40005842-* 2>/dev/null | head -1)"; _rl="$(ls "$T"/runs/*/run.log 2>/dev/null | head -1)"
[ "$(pm "$_bk")" = "drwx------" ] && ok || bad "backup dir is $(pm "$_bk"), want drwx------ (umask $(umask))"
_open=""; for _f in "$_bk"/*.tgz; do [ "$(pm "$_f")" = "-rw-------" ] || _open="$_open ${_f##*/}=$(pm "$_f")"; done
[ -z "$_open" ] && ok || bad "rollback archives not owner-only:$_open (umask $(umask))"
[ "$(pm "$_rl")" = "-rw-------" ] && ok || bad "run.log is $(pm "$_rl"), want -rw------- (umask $(umask))"
[ "$(pm "$(dirname "$_rl")")" = "drwx------" ] && ok || bad "run dir is $(pm "$(dirname "$_rl")"), want drwx------ (umask $(umask))"
# ...and the script must NOT have handed its children a private umask: what the patch lays down in the home keeps
# the host's modes (a home restored or patched owner-only stops OHS for every other account)
[ "$(umask)" = "${GATE_UMASK:-0022}" ] && ok || bad "the gate's own umask moved to $(umask)"
# rollback of that run: home back without the patch, started again
: >"$T/actions"; rc="$(HOME="$T/home" PATH="$T/stub:$PATH" START_TIMEOUT=1 POLL=1 RUN_BASE="$T/runs" bash "$SCRIPT" rollback --yes >"$T/out" 2>&1 </dev/null; echo $?; settle)"
[ "$rc" = 0 ] && [ ! -e "$OH/ohs/PATCHED" ] && ! grep -q 40005842 "$LSP" && ok || bad "rollback of a good run: rc $rc, PATCHED $([ -e "$OH/ohs/PATCHED" ] && echo present): $(grep ERROR "$T/out" | head -2)"
case "$(acts)" in *"stop ohs1"*"start ohs1"*) ok;; *) bad "rollback did not stop then start: [$(acts)]";; esac

# T1550 operator-stops: the operator owns every start and stop. No stop/start script may run (normal run and
# rollback), the node manager is not started, and the stop and start commands are printed for the operator.
build; : >"$T/actions"
rc="$(runr --operator-stops --yes)"
[ "$rc" = 0 ] && ok || bad "operator-stops run: rc $rc: $(grep -E 'ERROR|BLOCK|UNKNOWN' "$T/out" | head -2)"
case "$(acts)" in *stop*|*start*) bad "operator-stops ran a start/stop script: [$(acts)]";; *) ok;; esac
! grep -q 'weblogic.NodeManager' "$T/ps.txt" && ok || bad "operator-stops started the node manager"
grep -q 'operator-stops: not running any start or stop script' "$T/out" && ok || bad "operator-stops note missing from the run output"
grep -q 'bin/stopComponent.sh' "$T/out" && grep -q 'bin/startComponent.sh' "$T/out" && ok || bad "operator-stops did not print the stop and start commands"
grep -q 'left STOPPED for the operator to start' "$T/out" && ! grep -q 'every component answers' "$T/out" && ok || bad "operator-stops verify still claims the components answer"
# the standalone start with the option must not claim it started anything (T1550 P2, Louie #18228)
: >"$T/actions"
rc="$(HOME="$T/home" PATH="$T/stub:$PATH" ORACLE_HOME="" bash "$SCRIPT" start --oracle-home "$OH" --backup-dir "$T/backup" --operator-stops --yes >"$T/out" 2>&1 </dev/null; echo $?)"
[ "$rc" = 0 ] && ! grep -q 'started: node manager and every component, ports answering' "$T/out" && grep -q 'nothing was started here' "$T/out" && ok || bad "operator-stops start claims it started: rc $rc: $(grep -E 'started:|nothing was started' "$T/out" | head -2)"
case "$(acts)" in *start*) bad "operator-stops start ran a start script: [$(acts)]";; *) ok;; esac
# the quarter verifies through 'ohs-patch verify <dir>': with the option it must check the patch level only, or a
# GOOD run fails on stopped ports and the composer rolls the whole outage back (Talos [P1] #18210)
touch "$T/curl.fail"
rc="$(HOME="$T/home" PATH="$T/stub:$PATH" ORACLE_HOME="" bash "$SCRIPT" verify "$PD" --oracle-home "$OH" --backup-dir "$T/backup" --operator-stops >"$T/out" 2>&1 </dev/null; echo $?)"
[ "$rc" = 0 ] && grep -q 'ports not checked: the operator starts the components' "$T/out" && ok || bad "operator-stops verify checked stopped ports: rc $rc: $(grep -E 'does not answer|not checked|NOT installed' "$T/out" | head -2)"
rm -f "$T/curl.fail"
: >"$T/actions"
rc="$(HOME="$T/home" PATH="$T/stub:$PATH" START_TIMEOUT=1 POLL=1 RUN_BASE="$T/runs" bash "$SCRIPT" rollback --operator-stops --yes >"$T/out" 2>&1 </dev/null; echo $?; settle)"
[ "$rc" = 0 ] && ok || bad "operator-stops rollback: rc $rc: $(grep -E 'ERROR|BLOCK' "$T/out" | head -2)"
case "$(acts)" in *stop*|*start*) bad "operator-stops rollback ran a start/stop script: [$(acts)]";; *) ok;; esac
# a refused stop with the option says nothing changed and prints no start commands (T1550 P3)
build; running; : >"$T/actions"; rc="$(runr --operator-stops --yes)"
[ "$rc" != 0 ] && case "$(acts)" in *stop*|*start*) bad "operator-stops refused stop ran a script: [$(acts)]";; *) ok;; esac
grep -q 'nothing was changed, it is still running' "$T/out" && ! grep -qE '\[INFO \]   .*startComponent\.sh' "$T/out" && ok || bad "operator-stops refused stop wrong: $(grep -E 'still running|startComponent' "$T/out" | head -2)"

# refused before anything changes: nothing stopped, no backup
build; running; echo "OPatch 13.9.4.2.10" >"$T/opv"; rc="$(runr --yes)"
[ "$rc" = 1 ] && [ -z "$(acts)" ] && nobackup && ok || bad "preflight blocking: rc $rc, actions [$(acts)]"
build; running; touch "$T/lsp.fail"; rc="$(runr --yes)"
[ "$rc" = 2 ] && [ -z "$(acts)" ] && ok || bad "preflight unreadable: rc $rc (want 2), actions [$(acts)]"
build; running; rc="$(runr --yes --no-backup)"
[ "$rc" = 1 ] && [ -z "$(acts)" ] && grep -q 'no-backup refused' "$T/out" && ok || bad "--no-backup: rc $rc, actions [$(acts)]"
build; running; rc="$(runr)"
[ "$rc" = 1 ] && [ -z "$(acts)" ] && nobackup && ok || bad "no --yes and no terminal: rc $rc, actions [$(acts)]"
build; running; printf ' 4444 /jdk/bin/java -Dweblogic.Name=AdminServer -cp %s/wlserver/x.jar weblogic.Server\n' "$OH" >>"$T/ps.txt"; rc="$(runr --yes)"
[ "$rc" = 1 ] && [ -z "$(acts)" ] && nobackup && grep -q 'WebLogic servers run from' "$T/out" && ok || bad "a WebLogic server from the home: rc $rc, actions [$(acts)]"
build; running; rm -rf "$T/backup"; rc="$(runr --yes)"
[ "$rc" != 0 ] && [ -z "$(acts)" ] && ok || bad "missing backup dir: rc $rc, actions [$(acts)]"
build; running; echo "40005842;OHS (NATIVE) DB19C BUNDLE PATCH 12.2.1.4.260910" >>"$LSP"; rc="$(runr --yes)"
[ "$rc" = 0 ] && [ -z "$(acts)" ] && grep -q 'already installed' "$T/out" && ok || bad "already installed: rc $rc, actions [$(acts)]"
build; running; printf '%s\n' "$miss" >"$T/applicable"; echo 73 >"$T/applicable.rc"; rc="$(runr --yes)"
[ "$rc" = 1 ] && [ -z "$(acts)" ] && nobackup && ok || bad "run on a home missing a required component stopped or backed up: rc $rc, actions [$(acts)]"

# a backup that fails (tar cannot write it): refused, nothing stopped, the partial backup removed (Cerebro P3)
build; running; RT="$(command -v tar)"; printf '#!/bin/sh\ncase "$*" in *-czf*) [ -e "%s/tar.fail" ] && exit 2;; esac\nexec "%s" "$@"\n' "$T" "$RT" >"$T/stub/tar"; chmod +x "$T/stub/tar"; touch "$T/tar.fail"
rc="$(runr --yes)"
[ "$rc" = 1 ] && [ -z "$(acts)" ] && nobackup && ! st | grep -q '^applied=' && grep -q 'backup failed - nothing was stopped' "$T/out" && ok || bad "backup failure: rc $rc, actions [$(acts)], backup $(find "$T/backup" -mindepth 1 | head -2 | tr '\n' ' ')"
rm -f "$T/stub/tar" "$T/tar.fail"

# dry run on a folder holding only the zip: nothing stopped, nothing applied, patch folder and backup dir untouched
# (needs zip to build the fixture; without it the folder stays unzipped and the case would pass for the wrong reason)
if have_zip; then
build; running; (cd "$PD" && zip -qr ../p40005842_122140_Linux-x86-64.zip 40005842) && rm -rf "$PD/40005842" && mv "$T/patches/p40005842_122140_Linux-x86-64.zip" "$PD/"
before="$(cd "$PD" && find . | sort)"; rc="$(runr --dry-run --yes)"
[ "$rc" = 0 ] && [ -z "$(acts)" ] && nobackup && [ ! -d "$T/runs" ] && ok || bad "dry-run: rc $rc, actions [$(acts)], runs $([ -d "$T/runs" ] && echo made): $(grep -E 'ERROR|BLOCK' "$T/out" | head -2)"
[ "$before" = "$(cd "$PD" && find . | sort)" ] && ok || bad "dry-run changed the patch folder"
grep -q 'dry-run: would .*opatch apply' "$T/out" && ok || bad "dry-run does not say what it would apply"
else skip "dry-run on a zip-only patch folder: no zip/unzip on this host, the fixture cannot be built" 3; fi

# stop not proved: nothing applied, components started again
build; running; touch "$T/stop.stuck"; rc="$(runr --yes)"
[ "$rc" = 1 ] && ! acts | grep -q apply && acts | grep -q 'start ohs1' && grep -q 'still running from' "$T/out" && ok || bad "a process left after stop: rc $rc, actions [$(acts)]"
build; running; touch "$T/stop.fail"; rc="$(runr --yes)"
[ "$rc" = 1 ] && ! acts | grep -q apply && ok || bad "stopComponent failed: rc $rc, actions [$(acts)]"
# a stop that had nothing to stop (node manager already down) is not a reason to abandon the window: the proof is
# "nothing runs from the home", judged once after every stop has been tried (Gen's host, Weyland 21:14:11)
build; running; grep -v weblogic.NodeManager "$T/ps.txt" >"$T/ps.new"; mv "$T/ps.new" "$T/ps.txt"; touch "$T/nm.down"; rc="$(runr --yes)"
[ "$rc" = 0 ] && acts | grep -q apply && st | grep -q '^outcome=applied$' && ok || bad "node manager already down refused the run: rc $rc, actions [$(acts)]: $(grep -E 'ERROR' "$T/out" | head -3)"
grep -q 'WARN .*stopNodeManager.sh .* returned 3.*nothing runs from' "$T/out" && ok || bad "a non-zero stop on a quiet home is not named in a warning: $(grep -iE 'warn|stopNodeManager' "$T/out" | head -3)"
build; running; touch "$T/ps.fail.after-stop"; rc="$(runr --yes)"
[ "$rc" = 2 ] && ! acts | grep -q apply && ok || bad "ps unreadable after stop: rc $rc (want 2), actions [$(acts)]"

# a change that failed: restored from this run's backup, level proved, started; never 'applied'
build; running; touch "$T/apply.partial" "$T/apply.fail"; rc="$(runr --yes)"
[ "$rc" = 1 ] && [ ! -e "$OH/ohs/PATCHED" ] && ls -d "$T"/ohs.failed-* >/dev/null 2>&1 && grep -q 'ROLLED BACK' "$T/out" && ok || bad "apply failed: rc $rc, PATCHED $([ -e "$OH/ohs/PATCHED" ] && echo present): $(grep ERROR "$T/out" | head -3)"
case "$(acts)" in *apply*"start ohs1"*) ok;; *) bad "not started again after the rollback: [$(acts)]";; esac
! st | grep -q '^applied=' && st | grep -q '^outcome=rolled-back$' && ok || bad "a failed apply recorded as applied: $(st | tr '\n' ' ')"
build; running; touch "$T/apply.noop"; rc="$(runr --yes)"
[ "$rc" = 1 ] && grep -q 'does not show 40005842' "$T/out" && [ ! -e "$OH/ohs/PATCHED" ] && ok || bad "apply rc 0 but level unchanged: rc $rc"
build; running; touch "$T/start.fail-patched"; rc="$(runr --yes)"
[ "$rc" = 1 ] && grep -q 'does not start' "$T/out" && grep -q 'ROLLED BACK' "$T/out" && [ ! -e "$OH/ohs/PATCHED" ] && ok || bad "patched home does not start: rc $rc: $(grep ERROR "$T/out" | head -3)"
build; running; touch "$T/curl.fail"; rc="$(runr --yes)"
[ "$rc" != 0 ] && ! st | grep -q '^applied=' && ok || bad "ports never answer: rc $rc (want non-zero, not applied)"
# no curl on the host (a PATH holding only the tools the script needs): the port check is skipped, the apply stands
build; running; mkdir -p "$T/bin"; rm -f "$T/stub/curl"
for t in chmod bash sh sed awk grep tr cut sort head tail date mkdir rm mv tar gzip find du df dirname basename cat env sleep nohup mktemp unzip wc ls; do
  ln -sf "$(command -v "$t")" "$T/bin/$t"; done
rc="$(HOME="$T/home" PATH="$T/stub:$T/bin" ORACLE_HOME="" START_TIMEOUT=1 POLL=1 RUN_BASE="$T/runs" "$T/bin/bash" "$SCRIPT" run "$PD" --oracle-home "$OH" --backup-dir "$T/backup" --yes >"$T/out" 2>&1 </dev/null; echo $?; settle)"
[ "$rc" = 0 ] && grep -q 'curl not available' "$T/out" && st | grep -q '^applied=40005842$' && ok || bad "no curl: rc $rc (want 0, applied, a warning): $(grep -E 'ERROR|WARN' "$T/out" | head -3)"
rm -rf "${T:?}/bin"
# a harmless 'tail -f' on a file in the home blocks the apply (fail-closed by design): known, not discovered
build; printf ' 4747 tail -f %s/ohs/x.log\n' "$OH" >"$T/ps.txt"; rm -f "$T/stop.stuck"; rc="$(runr --yes)"
[ "$rc" = 1 ] && ! acts | grep -q apply && grep -q 'pid 4747' "$T/out" && ok || bad "a tail -f on the home's log did not block: rc $rc, actions [$(acts)]"

# the restore itself fails: nothing started, servers down, exit 3, the manual restore printed
build; running; touch "$T/apply.fail" "$T/apply.corrupt"; rc="$(runr --yes)"
[ "$rc" = 3 ] && grep -q 'ROLLBACK FAILED' "$T/out" && grep -q 'MANUAL RESTORE' "$T/out" && ok || bad "restore failed: rc $rc (want 3): $(grep ERROR "$T/out" | head -3)"
case "$(acts)" in *apply*start*) bad "started after a failed restore: [$(acts)]";; *) ok;; esac

# an interactive run that is not detached is refused before anything changes (ohs-patch sources no lib, so it must
# define require_detached itself - a call to an undefined one printed 'command not found' and the run went on)
build; running; rc="$(PATCH_INTERACTIVE=1 runr --yes)"
[ "$rc" != 0 ] && [ -z "$(acts)" ] && nobackup && grep -q 'Start it detached' "$T/out" && ! grep -q 'command not found' "$T/out" && ok || bad "an interactive run was not refused: rc $rc, actions [$(acts)]: $(grep -E 'ERROR|not found' "$T/out" | head -2)"
build; running; rc="$(PATCH_INTERACTIVE=1 PATCH_DETACHED=1 runr --yes)"
[ "$rc" = 0 ] && ok || bad "PATCH_DETACHED=1 does not override the refusal: rc $rc"

# ---- the steps as commands: plan, backup, stop, apply, start, verify (run is these, in this order) ---------------
runc() { local c="$1"; shift; HOME="$T/home" PATH="$T/stub:$PATH" ORACLE_HOME="" START_TIMEOUT=1 POLL=1 RUN_BASE="$T/runs" \
  bash "$SCRIPT" "$c" "$@" --oracle-home "$OH" --backup-dir "$T/backup" >"$T/out" 2>&1 </dev/null; echo $?; settle; }
fromhome() { grep -F "$OH/" "$T/ps.txt"; }

# plan: read-only, twice, from a patch dir holding only the zip - no run dir, no backup, no 'extracted' folder
if have_zip; then
build; running; ZD="$T/patches/zipped"; mkdir -p "$ZD"; (cd "$PD" && zip -qr "$ZD/p40005842_122140_Linux-x86-64.zip" 40005842)
before="$(cd "$ZD" && find . | sort; cksum "$ZD"/*.zip)"
rc="$(PATCH_INTERACTIVE=1 runc plan "$ZD")"; rc2="$(PATCH_INTERACTIVE=1 runc plan "$ZD")"
[ "$rc" = 0 ] && [ "$rc2" = 0 ] && [ -z "$(acts)" ] && nobackup && [ ! -d "$T/runs" ] && ok || bad "plan is not read-only: rc $rc/$rc2 (want 0/0), actions [$(acts)] (want empty), backup $([ -n "$(find "$T/backup" -mindepth 1 2>/dev/null | head -1)" ] && echo MADE || echo none), runs $([ -d "$T/runs" ] && echo MADE || echo none): $(grep -E 'ERROR|BLOCK' "$T/out" | head -2)"
[ "$before" = "$(cd "$ZD" && find . | sort; cksum "$ZD"/*.zip)" ] && ok || bad "plan changed the patch folder: $(cd "$ZD" && find . | sort | tr '\n' ' ')"
grep -q "would run $DOM/bin/stopComponent.sh ohs1" "$T/out" && grep -q 'would back up' "$T/out" && grep -q 'opatch apply -silent' "$T/out" && ok || bad "plan does not list the steps: $(grep -c dry-run "$T/out") dry-run lines"
grep -q 'run does all of this' "$T/out" && ok || bad "plan does not say run does these steps for you"
else skip "plan from a zip-only patch folder: no zip/unzip on this host, the fixture cannot be built" 4; fi

# backup: a run dir and the three archives, nothing stopped; refused undetached
build; running; rc="$(PATCH_INTERACTIVE=1 runc backup "$PD" --yes)"
[ "$rc" != 0 ] && nobackup && [ ! -d "$T/runs" ] && grep -q 'ohs-patch backup changes this host' "$T/out" && ok || bad "an interactive backup was not refused: rc $rc"
# --run-dir is HONOURED by backup (T291, Edi #13261): the composer takes one shared backup and then applies with
# --backup-run $SHARED (ohs-quarter.sh:249 then :336), and this script refuses without $SHARED/state. A backup that
# accepts --run-dir and writes its own $RUN_BASE/<stamp>-run leaves the composer's apply with no state at all.
build; running; SH="$T/shared"; rc="$(runc backup "$PD" --run-dir "$SH" --yes)"
[ "$rc" = 0 ] && [ -f "$SH/state" ] && ok || bad "backup ignored --run-dir: rc $rc, $SH/state $([ -f "$SH/state" ] && echo present || echo MISSING), run dirs: $(find "$T/runs" -mindepth 1 -maxdepth 1 2>/dev/null | head -3 | tr '\n' ' ')"

build; running; rc="$(runc backup "$PD" --dry-run --yes)"
[ "$rc" = 0 ] && nobackup && [ ! -d "$T/runs" ] && [ -z "$(acts)" ] && ok || bad "backup --dry-run changed something: rc $rc, actions [$(acts)]"
build; running; rc="$(runc backup "$PD" --yes)"
[ "$rc" = 0 ] && [ -z "$(acts)" ] && [ "$(find "$T"/backup/ohs-40005842-* -name '*.tgz' | wc -l | tr -d ' ')" = 3 ] && ok || bad "backup: rc $rc, actions [$(acts)], $(find "$T/backup" -name '*.tgz' | wc -l) archives: $(grep ERROR "$T/out" | head -2)"
st | grep -q '^backup=ok$' && st | grep -q '^outcome=backed-up$' && ok || bad "backup state: $(st | tr '\n' ' ')"

# stop: components then node manager, proved stopped; refused undetached, for a WebLogic server, and under --dry-run inert
build; running; rc="$(PATCH_INTERACTIVE=1 runc stop --yes)"
[ "$rc" != 0 ] && [ -z "$(acts)" ] && grep -q 'ohs-patch stop changes this host' "$T/out" && ok || bad "an interactive stop was not refused: rc $rc, actions [$(acts)]"
build; running; rc="$(runc stop --dry-run --yes)"
[ "$rc" = 0 ] && [ -z "$(acts)" ] && [ -n "$(fromhome)" ] && ok || bad "stop --dry-run stopped something: rc $rc, actions [$(acts)]"
build; running; printf ' 4444 /jdk/bin/java -Dweblogic.Name=AdminServer -cp %s/wlserver/x.jar weblogic.Server\n' "$OH" >>"$T/ps.txt"; rc="$(runc stop --yes)"
[ "$rc" = 1 ] && [ -z "$(acts)" ] && grep -q 'WebLogic servers run from' "$T/out" && ok || bad "stop with a WebLogic server: rc $rc, actions [$(acts)]"
build; running; rc="$(runc stop)"
[ "$rc" = 1 ] && [ -z "$(acts)" ] && ok || bad "stop with no --yes and no terminal: rc $rc, actions [$(acts)]"
build; running; rc="$(runc stop --yes)"
[ "$rc" = 0 ] && [ "$(acts)" = "stop ohs1 stop ohs2 stopNM " ] && [ -z "$(fromhome)" ] && ok || bad "stop: rc $rc, actions [$(acts)], still running [$(fromhome)]"
build; running; grep -v weblogic.NodeManager "$T/ps.txt" >"$T/ps.new"; mv "$T/ps.new" "$T/ps.txt"; touch "$T/nm.down"; rc="$(runc stop --yes)"
[ "$rc" = 0 ] && [ -z "$(fromhome)" ] && ok || bad "stop with node manager already down: rc $rc (want 0, the home is clear)"
build; running; touch "$T/stop.stuck"; rc="$(runc stop --yes)"
[ "$rc" = 1 ] && grep -q 'still running from' "$T/out" && ok || bad "stop that leaves a process: rc $rc (want 1)"
# a given --run-dir is where stop and start log (ohs-quarter passes its outage's opatch dir), not a new
# $RUN_BASE/<stamp>-stop|start beside it (T1107, Nexus #15824)
build; running; rc="$(runc stop --yes --run-dir "$T/outage")"; rs="$(runc start --yes --run-dir "$T/outage")"
[ "$rc" = 0 ] && [ "$rs" = 0 ] && grep -q 'stopNodeManager' "$T/outage/ohs-patch.log" && grep -q 'startNodeManager' "$T/outage/ohs-patch.log" \
  && [ -z "$(find "$T/runs" -maxdepth 1 \( -name '*-stop' -o -name '*-start' \) 2>/dev/null)" ] \
  && [ "$(stat -c %a "$T/outage" 2>/dev/null || stat -f %Lp "$T/outage")" = 700 ] && ok \
  || bad "stop/start --run-dir: rc $rc/$rs, given dir [$(ls -A "$T/outage" 2>/dev/null | tr '\n' ' ')], runs [$(ls "$T/runs" 2>/dev/null | tr '\n' ' ')]"

# apply: needs a completed backup of this home for this patch, and nothing running from the home
build; rc="$(runc apply "$PD" --yes)"
[ "$rc" = 1 ] && ! acts | grep -q apply && grep -q 'no completed backup' "$T/out" && ok || bad "apply without a backup: rc $rc, actions [$(acts)]"
build; running; runc backup "$PD" --yes >/dev/null; rc="$(runc apply "$PD" --yes)"
[ "$rc" = 1 ] && ! acts | grep -q apply && grep -q 'still running from' "$T/out" && ok || bad "apply with OHS running: rc $rc, actions [$(acts)]"
build; running; runc backup "$PD" --yes >/dev/null; runc stop --yes >/dev/null; : >"$T/actions"; rc="$(PATCH_INTERACTIVE=1 runc apply "$PD" --yes)"
[ "$rc" != 0 ] && [ -z "$(acts)" ] && grep -q 'ohs-patch apply changes this host' "$T/out" && ok || bad "an interactive apply was not refused: rc $rc, actions [$(acts)]"
rc="$(runc apply "$PD" --dry-run --yes)"
[ "$rc" = 0 ] && [ -z "$(acts)" ] && ! grep -q 40005842 "$LSP" && ok || bad "apply --dry-run applied: rc $rc, actions [$(acts)]"
rc="$(runc apply "$PD" --yes)"
[ "$rc" = 0 ] && [ "$(acts)" = "apply " ] && grep -q '^40005842;' "$LSP" && ok || bad "apply after backup + stop: rc $rc, actions [$(acts)]: $(grep ERROR "$T/out" | head -2)"
st | grep -q '^stage=apply$' && ok || bad "apply did not record its stage in the backup's run: $(st | tr '\n' ' ')"


# start: node manager and the components, ports answered; then verify is read-only and says applied
: >"$T/actions"; rc="$(PATCH_INTERACTIVE=1 runc start --yes)"
[ "$rc" != 0 ] && [ -z "$(acts)" ] && grep -q 'ohs-patch start changes this host' "$T/out" && ok || bad "an interactive start was not refused: rc $rc, actions [$(acts)]"
rc="$(runc start --dry-run --yes)"
[ "$rc" = 0 ] && [ -z "$(acts)" ] && ok || bad "start --dry-run started something: rc $rc, actions [$(acts)]"
rc="$(runc start --yes)"
case "$rc|$(acts)" in "0|"*"start ohs1"*"start ohs2"*) ok;; *) bad "start: rc $rc, actions [$(acts)]";; esac
case "$(acts)" in *startNM*) ok;; *) bad "start did not start node manager: [$(acts)]";; esac
: >"$T/actions"; rc="$(runc verify "$PD")"
[ "$rc" = 0 ] && [ -z "$(acts)" ] && grep -q '40005842 is installed' "$T/out" && grep -q 'ohs1 answers on port 7777' "$T/out" && ok || bad "verify after the steps: rc $rc, actions [$(acts)]: $(grep -E 'ERROR|INFO' "$T/out" | tail -3)"
# rollback finds the run the backup command opened
: >"$T/actions"; rc="$(PATCH_INTERACTIVE=1 runc rollback --yes)"
[ "$rc" != 0 ] && [ -z "$(acts)" ] && grep -q 'ohs-patch rollback changes this host' "$T/out" && grep -q '^40005842;' "$LSP" && ok || bad "an interactive rollback was not refused: rc $rc, actions [$(acts)]"
: >"$T/actions"; rc="$(runc rollback --yes)"
[ "$rc" = 0 ] && ! grep -q 40005842 "$LSP" && ok || bad "rollback after the stepwise apply: rc $rc: $(grep ERROR "$T/out" | head -2)"

# apply --backup-run: a composer's ONE backup, taken before its first patch (state patch= another id), is the restore point
shared() { build; running; runc backup "$PD" --yes >/dev/null; runc stop --yes >/dev/null; : >"$T/actions"
  SRD="$(dirname "$(find "$T/runs" -name state | head -1)")"; sed 's/^patch=.*/patch=39425385/' "$SRD/state" >"$SRD/s.new"; mv "$SRD/s.new" "$SRD/state"; }
shared; rc="$(runc apply "$PD" --yes)"
[ "$rc" = 1 ] && [ -z "$(acts)" ] && grep -q 'no completed backup' "$T/out" && ok || bad "without --backup-run another patch's run was used: rc $rc, actions [$(acts)]"
rc="$(runc apply "$PD" --yes --backup-run "$SRD")"
[ "$rc" = 0 ] && [ "$(acts)" = "apply " ] && grep -q '^40005842;' "$LSP" && ok || bad "apply --backup-run a shared run: rc $rc, actions [$(acts)]: $(grep ERROR "$T/out" | head -2)"
# a failure restores to the SHARED run's level: an earlier child's patch (applied after the backup) is undone, and
# the restore is judged against that run's pre_patches, not the level just before this apply (that would be exit 3)
shared; echo "39425385;DB CLIENT 19.31 BUNDLE" >>"$LSP"; touch "$T/apply.fail"; rc="$(runc apply "$PD" --yes --backup-run "$SRD")"
[ "$rc" = 1 ] && ! grep -q '^39425385;' "$LSP" && grep -q 'ROLLED BACK' "$T/out" && ok || bad "a failed apply --backup-run did not restore to the shared level: rc $rc (want 1), lsp [$(tr '\n' ' ' <"$LSP")]: $(grep ERROR "$T/out" | head -2)"
shared; sed 's#^oracle_home=.*#oracle_home=/elsewhere#' "$SRD/state" >"$SRD/s.new"; mv "$SRD/s.new" "$SRD/state"; rc="$(runc apply "$PD" --yes --backup-run "$SRD")"
[ "$rc" = 1 ] && [ -z "$(acts)" ] && grep -q 'is a backup of /elsewhere' "$T/out" && ok || bad "--backup-run of another home: rc $rc, actions [$(acts)]"
shared; sed '/^backup=/d' "$SRD/state" >"$SRD/s.new"; mv "$SRD/s.new" "$SRD/state"; rc="$(runc apply "$PD" --yes --backup-run "$SRD")"
[ "$rc" = 1 ] && [ -z "$(acts)" ] && grep -q 'did not complete its backup' "$T/out" && ok || bad "--backup-run with no completed backup: rc $rc, actions [$(acts)]"
shared; rc="$(runc apply "$PD" --yes --backup-run "$T/nowhere")"
[ "$rc" = 1 ] && [ -z "$(acts)" ] && grep -q 'has no state' "$T/out" && ok || bad "--backup-run with no state: rc $rc, actions [$(acts)]"
shared; rm -f "$(sed -n 's/^backup_dir=//p' "$SRD/state" | tail -1)/home.tgz"; rc="$(runc apply "$PD" --yes --backup-run "$SRD")"
[ "$rc" = 1 ] && [ -z "$(acts)" ] && grep -q 'is not complete' "$T/out" && ok || bad "--backup-run with home.tgz missing: rc $rc, actions [$(acts)]"
# a home with NO patches: a failed apply restores it and that is a restore, not RESTORE FAILED (pipefail + empty grep)
build; running; : >"$LSP"; touch "$T/apply.fail"; rc="$(runr --yes)"
[ "$rc" = 1 ] && grep -q 'ROLLED BACK' "$T/out" && ok || bad "a failed apply on a home with no patches: rc $rc (want 1, not 3): $(grep ERROR "$T/out" | head -2)"

# verify: read-only, and not ready says so
build; running; rc="$(runc verify "$PD")"
[ "$rc" = 1 ] && [ -z "$(acts)" ] && grep -q '40005842 is NOT installed' "$T/out" && ok || bad "verify before the apply: rc $rc (want 1), actions [$(acts)] (want empty), NOT-installed line count $(grep -c '40005842 is NOT installed' "$T/out") (want 1): $(grep -E 'ERROR|WARN' "$T/out" | head -2)"
build; running; echo "40005842;OHS (NATIVE) DB19C BUNDLE PATCH 12.2.1.4.260910" >>"$LSP"; touch "$T/curl.fail"; rc="$(runc verify "$PD")"
[ "$rc" = 1 ] && grep -q 'does not answer on port 7777' "$T/out" && ok || bad "verify with a port down: rc $rc (want 1)"

# every step that changes whether a server runs says so in the positive when it succeeds (Daniel, 21:01)
build; running; rc="$(runr --yes)"
grep -q 'stopped ohs1' "$T/out" && grep -q 'stopped ohs2' "$T/out" && grep -q 'stopped node manager for ohs_domain' "$T/out" && ok || bad "run does not confirm each stop: $(grep -i stopped "$T/out" | tr '\n' '|')"
grep -q "confirmed: nothing runs from $OH" "$T/out" && ok || bad "run does not confirm the home is clear"
grep -q 'started ohs1' "$T/out" && grep -q 'started ohs2' "$T/out" && ok || bad "run does not confirm each start"
[ "$(grep -n 'confirmed: nothing runs' "$T/out" | cut -d: -f1)" -lt "$(grep -n '3/5 opatch apply' "$T/out" | cut -d: -f1)" ] && ok || bad "the home-clear confirmation is not before the apply"
build; running; touch "$T/stop.stuck"; rc="$(runr --yes)"
! grep -q 'confirmed: nothing runs' "$T/out" && ok || bad "a stuck stop still printed 'confirmed: nothing runs'"

# a stop that prompts for a password must fail at once, not wait on (or read) the operator's terminal: its output goes
# to run.log, so in tmux the prompt would be invisible and the run would hang mid-outage
build; running; touch "$T/stop.prompt"
rc="$(printf 'yes\nyes\n' | HOME="$T/home" PATH="$T/stub:$PATH" ORACLE_HOME="" START_TIMEOUT=1 POLL=1 RUN_BASE="$T/runs" bash "$SCRIPT" run "$PD" --oracle-home "$OH" --backup-dir "$T/backup" --yes >"$T/out" 2>&1; echo $?; settle)"
[ "$rc" = 1 ] && ! acts | grep -q 'password read' && ! acts | grep -q apply && grep -q 'stopComponent.sh ohs1 failed' "$T/out" && ok || bad "a stop that prompts read stdin or went on: rc $rc, actions [$(acts)]"
grep -q 'Enter Node Manager password' "$T/out" && grep -q 'startComponent.sh ohs1 storeUserConfig' "$T/out" && ok || bad "a prompting stop does not show the prompt and the storeUserConfig remedy: $(grep -A3 'ohs1 failed' "$T/out")"
build; running; touch "$T/stop.fail"; rc="$(runr --yes)"
grep -q 'stopComponent.sh ohs1 failed' "$T/out" && ! grep -q 'asked for the node manager credentials' "$T/out" && ok || bad "a stop that fails for another reason blamed the credentials"

# the narration is on disk with the children's output, and a failure names every log the operator needs (Weyland 21:23:50)
build; running; rc="$(runr --yes)"; rd="$(find "$T/runs" -maxdepth 1 -name '*-run' -type d | head -1)"
[ -f "$rd/ohs-patch.log" ] && grep -q 'READY: nothing blocking' "$rd/ohs-patch.log" && grep -q '2/5 stop' "$rd/ohs-patch.log" && grep -q '5/5 applied and verified' "$rd/ohs-patch.log" && ok || bad "the run's narration is not in $rd/ohs-patch.log: $(ls "$rd" 2>/dev/null | tr '\n' ' ')"
build; running; touch "$T/apply.fail"; rc="$(runr --yes)"; rd="$(find "$T/runs" -maxdepth 1 -name '*-run' -type d | head -1)"
grep -q "$rd/ohs-patch.log" "$T/out" && grep -q "$rd/run.log" "$T/out" && ok || bad "a failed run does not name its run dir logs: $(grep -i 'logs' "$T/out" | head -2)"
grep -qE "$OH\.failed-[0-9-]+/cfgtoollogs/opatch" "$T/out" && ok || bad "after the rollback renamed the home, opatch's log is not named under the .failed-* copy: $(grep cfgtoollogs "$T/out" | head -2)"
build; running; touch "$T/stop.stuck"; rc="$(runr --yes)"
grep -q 'run.log' "$T/out" && grep -q "$OH/cfgtoollogs/opatch" "$T/out" && ! grep -q 'failed-.*cfgtoollogs' "$T/out" && ok || bad "a refused stop does not name the logs, or names a .failed-* home that was never made"

# the unknown-command message names every command the dispatcher has
build; rc="$(runc frobnicate)"
grep -q 'unknown command frobnicate (inspect, plan, preflight, backup, stop, apply, start, verify, rollback, run)' "$T/out" && ok || bad "unknown command message: $(grep unknown "$T/out")"

# the tail is printed only when something WAS skipped: ${skipped:+...} expands for the string "0" too, so a clean run
# used to say "0 skipped (0 assertions not run: ...)" - a summary claiming a gap it did not have (T316)
skiptail=""; [ "$skipped" -gt 0 ] && skiptail=", $skipped skipped ($skipped_asserts assertions not run: a case this host cannot run - not a pass, not a failure)"
echo "ohs-patch gate: $pass passed, $fail failed$skiptail"
[ "$fail" = 0 ]
