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

OH="$T/ohs"; DOM="$T/domains/ohs_domain"; PD="$T/patches/ohs"; LSP="$T/ohs/inventory/lsp.txt"  # in the home: a restore brings the old list back
build() {
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
  # node manager and component scripts: log the action and change the fake process table
  cat >"$DOM/bin/stopComponent.sh" <<S
#!/bin/sh
echo "stop \$1" >>"$T/actions"
[ -e "$T/stop.fail" ] && exit 1
[ -e "$T/stop.stuck" ] || { grep -v "instances/\$1 " "$T/ps.txt" >"$T/ps.new"; mv "$T/ps.new" "$T/ps.txt"; }
[ -e "$T/ps.fail.after-stop" ] && touch "$T/ps.fail"
exit 0
S
  cat >"$DOM/bin/stopNodeManager.sh" <<S
#!/bin/sh
echo "stopNM" >>"$T/actions"; grep -v "weblogic.NodeManager" "$T/ps.txt" >"$T/ps.new"; mv "$T/ps.new" "$T/ps.txt"; exit 0
S
  cat >"$DOM/bin/startNodeManager.sh" <<S
#!/bin/sh
echo "startNM" >>"$T/actions"; echo " 5151 /jdk/bin/java -cp $OH/oracle_common/x.jar weblogic.NodeManager" >>"$T/ps.txt"; exit 0
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
  : >"$T/ps.txt"; rm -f "$T"/*.fail "$T"/*.fail-patched "$T"/apply.* "$T"/stop.* "$T/ps.fail.after-stop" "$T/changed" "$T/opatch.log" "$T/actions"
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

# the home as a path boundary: a process whose argument IS the home is running from it; a sibling <home>2 is not
build; printf ' 4545 /bin/sh %s/ohs/bin/x\n' "${OH}2" >"$T/ps.txt"; rc="$(run)"
! grep -q 'pid 4545' "$T/out" && ok || bad "a process under the sibling ${OH}2 was read as running from $OH"
build; printf ' 4646 /usr/bin/java -Dhome=%s weblogic.NodeManager\n' "$OH" >"$T/ps.txt"; rc="$(run)"
grep -q 'pid 4646' "$T/out" && ok || bad "a process naming the home exactly (no trailing slash) was missed"
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
  bash "$SCRIPT" run "$PD" --oracle-home "$OH" --backup-dir "$T/backup" "$@" >"$T/out" 2>&1 </dev/null; echo $?; }
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
# rollback of that run: home back without the patch, started again
: >"$T/actions"; rc="$(HOME="$T/home" PATH="$T/stub:$PATH" START_TIMEOUT=1 POLL=1 RUN_BASE="$T/runs" bash "$SCRIPT" rollback --yes >"$T/out" 2>&1 </dev/null; echo $?)"
[ "$rc" = 0 ] && [ ! -e "$OH/ohs/PATCHED" ] && ! grep -q 40005842 "$LSP" && ok || bad "rollback of a good run: rc $rc, PATCHED $([ -e "$OH/ohs/PATCHED" ] && echo present): $(grep ERROR "$T/out" | head -2)"
case "$(acts)" in *"stop ohs1"*"start ohs1"*) ok;; *) bad "rollback did not stop then start: [$(acts)]";; esac

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

# a backup that fails (tar cannot write it): refused, nothing stopped, the partial backup removed (Cerebro P3)
build; running; RT="$(command -v tar)"; printf '#!/bin/sh\ncase "$*" in *-czf*) [ -e "%s/tar.fail" ] && exit 2;; esac\nexec "%s" "$@"\n' "$T" "$RT" >"$T/stub/tar"; chmod +x "$T/stub/tar"; touch "$T/tar.fail"
rc="$(runr --yes)"
[ "$rc" = 1 ] && [ -z "$(acts)" ] && nobackup && ! st | grep -q '^applied=' && grep -q 'backup failed - nothing was stopped' "$T/out" && ok || bad "backup failure: rc $rc, actions [$(acts)], backup $(find "$T/backup" -mindepth 1 | head -2 | tr '\n' ' ')"
rm -f "$T/stub/tar" "$T/tar.fail"

# dry run on a folder holding only the zip: nothing stopped, nothing applied, patch folder and backup dir untouched
build; running; (cd "$PD" && zip -qr ../p40005842_122140_Linux-x86-64.zip 40005842) && rm -rf "$PD/40005842" && mv "$T/patches/p40005842_122140_Linux-x86-64.zip" "$PD/"
before="$(cd "$PD" && find . | sort)"; rc="$(runr --dry-run --yes)"
[ "$rc" = 0 ] && [ -z "$(acts)" ] && nobackup && [ ! -d "$T/runs" ] && ok || bad "dry-run: rc $rc, actions [$(acts)], runs $([ -d "$T/runs" ] && echo made): $(grep -E 'ERROR|BLOCK' "$T/out" | head -2)"
[ "$before" = "$(cd "$PD" && find . | sort)" ] && ok || bad "dry-run changed the patch folder"
grep -q 'dry-run: would .*opatch apply' "$T/out" && ok || bad "dry-run does not say what it would apply"

# stop not proved: nothing applied, components started again
build; running; touch "$T/stop.stuck"; rc="$(runr --yes)"
[ "$rc" = 1 ] && ! acts | grep -q apply && acts | grep -q 'start ohs1' && grep -q 'still running from' "$T/out" && ok || bad "a process left after stop: rc $rc, actions [$(acts)]"
build; running; touch "$T/stop.fail"; rc="$(runr --yes)"
[ "$rc" = 1 ] && ! acts | grep -q apply && ok || bad "stopComponent failed: rc $rc, actions [$(acts)]"
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
for t in bash sh sed awk grep tr cut sort head tail date mkdir rm mv tar gzip find du df dirname basename cat env sleep nohup mktemp unzip wc ls; do
  ln -sf "$(command -v "$t")" "$T/bin/$t"; done
rc="$(HOME="$T/home" PATH="$T/stub:$T/bin" ORACLE_HOME="" START_TIMEOUT=1 POLL=1 RUN_BASE="$T/runs" "$T/bin/bash" "$SCRIPT" run "$PD" --oracle-home "$OH" --backup-dir "$T/backup" --yes >"$T/out" 2>&1 </dev/null; echo $?)"
[ "$rc" = 0 ] && grep -q 'curl not available' "$T/out" && st | grep -q '^applied=40005842$' && ok || bad "no curl: rc $rc (want 0, applied, a warning): $(grep -E 'ERROR|WARN' "$T/out" | head -3)"
rm -rf "${T:?}/bin"
# a harmless 'tail -f' on a file in the home blocks the apply (fail-closed by design): known, not discovered
build; printf ' 4747 tail -f %s/ohs/x.log\n' "$OH" >"$T/ps.txt"; rm -f "$T/stop.stuck"; rc="$(runr --yes)"
[ "$rc" = 1 ] && ! acts | grep -q apply && grep -q 'pid 4747' "$T/out" && ok || bad "a tail -f on the home's log did not block: rc $rc, actions [$(acts)]"

# the restore itself fails: nothing started, servers down, exit 3, the manual restore printed
build; running; touch "$T/apply.fail" "$T/apply.corrupt"; rc="$(runr --yes)"
[ "$rc" = 3 ] && grep -q 'ROLLBACK FAILED' "$T/out" && grep -q 'MANUAL RESTORE' "$T/out" && ok || bad "restore failed: rc $rc (want 3): $(grep ERROR "$T/out" | head -3)"
case "$(acts)" in *apply*start*) bad "started after a failed restore: [$(acts)]";; *) ok;; esac

echo "ohs-patch gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
