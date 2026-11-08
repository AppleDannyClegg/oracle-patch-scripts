#!/usr/bin/env bash
# dbclient-upgrade.sh - behavioural gate for patching/dbclient-upgrade/dbclient-upgrade.sh.
#
# Builds a fake standalone OHS 12.2.1.4 home whose Database Client is 12c (oracle.rdbms.rsf 12.1.0.2.0 in
# comps.xml, a sqlplus stub that says 12.1), one domain with two OHS components, a node manager, and a 34761383 zip
# whose installer stub writes the 19c level INTO the home (so a restore of the home brings 12c back, as on a host).
# Checks every preflight gate on its own, the run order, the restore after each failure point, and that a restore
# that fails is exit 3. What it cannot prove: what the real installer writes, or how long it takes - a host is that.
#
# Usage: tests/dbclient-upgrade.sh

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SCRIPT=patching/dbclient-upgrade/dbclient-upgrade.sh
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "${T:?}"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

OH="$T/ohs"; DOM="$T/domains/ohs_domain"; PD="$T/patches/dbclient"; LSP="$OH/inventory/lsp.txt"
comps() { mkdir -p "$OH/inventory/ContentsXML"; printf '<PRD_LIST>\n<COMP NAME="oracle.ohs2" VER="12.2.1.4.0"/>\n<COMP NAME="oracle.rdbms.rsf" VER="%s" BUILD_NUMBER="0"/>\n</PRD_LIST>\n' "$1" >"$OH/inventory/ContentsXML/comps.xml"; }
build() {
  rm -rf "${T:?}/ohs" "${T:?}"/ohs.failed-* "${T:?}/domains" "${T:?}/patches" "${T:?}/home" "${T:?}/stub" "${T:?}/backup" "${T:?}/inv" "${T:?}/runs" "${T:?}"/inv.failed-* "${T:?}/zipsrc"
  rm -f "${T:?}"/*.fail "${T:?}"/inst.* "${T:?}"/perm.* "${T:?}"/stop.* "${T:?}"/start.* "${T:?}/changed" "${T:?}/actions" "${T:?}/rollbacks" "${T:?}"/rb.*
  mkdir -p "$OH/ohs/bin" "$OH/OPatch" "$OH/bin" "$OH/inventory" "$DOM/config/fmwconfig/components/OHS/instances/ohs1" "$DOM/bin" \
    "$PD" "$T/home/.wlst" "$T/stub" "$T/backup" "$T/inv/ContentsXML" "$T/zipsrc"
  echo '<registry><distribution status="installed" name="Oracle HTTP Server (Standalone)" version="12.2.1.4.0"/></registry>' >"$OH/inventory/registry.xml"
  printf 'inventory_loc=%s/inv\n' "$T" >"$OH/oraInst.loc"
  echo "<domain-registry><domain location=\"$DOM\"/></domain-registry>" >"$OH/domain-registry.xml"
  printf '<domain>\n  <name>ohs_domain</name>\n  <system-component>\n    <name>ohs1</name>\n    <component-type>OHS</component-type>\n  </system-component>\n  <system-component>\n    <name>ohs2</name>\n    <component-type>OHS</component-type>\n  </system-component>\n</domain>\n' >"$DOM/config/config.xml"
  printf 'Listen 7777\n' >"$DOM/config/fmwconfig/components/OHS/instances/ohs1/httpd.conf"
  : >"$T/home/.wlst/nm-cfg-ohs_domain.props"; : >"$T/home/.wlst/nm-key-ohs_domain.props"
  comps 12.1.0.2.0; echo 12.1.0.2.0 >"$OH/.sqlv"; : >"$LSP"
  printf 'NAME="Oracle Linux Server"\nID="ol"\nVERSION_ID="7.9"\nPRETTY_NAME="Oracle Linux Server 7.9"\n' >"$T/os-release"
  # the client as sqlplus reports it: the level lives in the home, so a restore brings the old one back
  cat >"$OH/bin/sqlplus" <<S
#!/bin/sh
v="\$(cat "$OH/.sqlv")"; echo; echo "SQL*Plus: Release \${v%%.*}.0.0.0.0 - Production"; echo "Version \$v"
S
  cat >"$OH/OPatch/opatch" <<O
#!/bin/sh
case "\$1" in
  lspatches) [ -e "$T/lsp.fail" ] && exit 1; cat "$LSP"; echo; echo "OPatch succeeded.";;
  rollback) id=""; while [ \$# -gt 0 ]; do [ "\$1" = -id ] && id="\$2"; shift; done
    echo "rollback \$id" >>"$T/actions"; [ -e "$T/rb.fail" ] && exit 1; [ -e "$T/rb.lie" ] && exit 0
    grep -v "^\$id;" "$LSP" >"$LSP.new"; mv "$LSP.new" "$LSP"; [ -e "$T/rb.fail-after" ] && exit 1; echo "OPatch succeeded.";;
  *) echo "UNEXPECTED opatch \$*" >>"$T/changed"; exit 1;;
esac
O
  # the installer zip: changePerm.sh and the installer; the installer writes the 19c level into the home
  cat >"$T/zipsrc/changePerm.sh" <<S
#!/bin/sh
echo "changePerm \$1" >>"$T/actions"; [ -e "$T/perm.fail" ] && exit 1; exit 0
S
  cat >"$T/zipsrc/fmw_12.2.1.19.0_dbclient_linux64.bin" <<S
#!/bin/sh
echo "install \$*" >>"$T/actions"
[ -e "$T/inst.corrupt" ] && for b in "$T"/backup/*/home.tgz; do echo x >"\$b"; done
[ -e "$T/inst.fail" ] && { : >"$OH/ohs/HALF"; echo "INS-0001 failed"; exit 1; }
[ -e "$T/inst.noop" ] && exit 0
sed 's/oracle.rdbms.rsf" VER="[^"]*"/oracle.rdbms.rsf" VER="19.0.0.0.0"/' "$OH/inventory/ContentsXML/comps.xml" >"$OH/c.new" && mv "$OH/c.new" "$OH/inventory/ContentsXML/comps.xml"
[ -e "$T/inst.halfway" ] || echo 19.14.0.0.0 >"$OH/.sqlv"
exit 0
S
  chmod +x "$OH/bin/sqlplus" "$OH/OPatch/opatch" "$T/zipsrc/"*
  (cd "$T/zipsrc" && zip -q "$PD/p34761383_122140_Linux-x86-64.zip" changePerm.sh fmw_12.2.1.19.0_dbclient_linux64.bin)
  cat >"$T/stub/ps" <<P
#!/bin/sh
[ -e "$T/ps.fail" ] && exit 1
cat "$T/ps.txt" 2>/dev/null; echo "  1 /sbin/launchd"
P
  cat >"$DOM/bin/stopComponent.sh" <<S
#!/bin/sh
echo "stop \$1" >>"$T/actions"
[ -e "$T/stop.stuck" ] || { grep -v "instances/\$1 " "$T/ps.txt" >"$T/ps.new"; mv "$T/ps.new" "$T/ps.txt"; }
exit 0
S
  cat >"$DOM/bin/stopNodeManager.sh" <<S
#!/bin/sh
echo "stopNM" >>"$T/actions"; grep -v "weblogic.NodeManager" "$T/ps.txt" >"$T/ps.new"; mv "$T/ps.new" "$T/ps.txt"; exit 0
S
  cat >"$DOM/bin/startNodeManager.sh" <<S
#!/bin/sh
echo " 5151 /jdk/bin/java -cp $OH/oracle_common/x.jar weblogic.NodeManager" >>"$T/ps.txt"; exit 0
S
  cat >"$DOM/bin/startComponent.sh" <<S
#!/bin/sh
echo "start \$1" >>"$T/actions"
[ -e "$T/start.fail-upgraded" ] && grep -q 'rsf" VER="19' "$OH/inventory/ContentsXML/comps.xml" && exit 1
echo " 6\$\$ $OH/ohs/bin/httpd -d $DOM/config/fmwconfig/components/OHS/instances/\$1 -k start" >>"$T/ps.txt"; exit 0
S
  printf '#!/bin/sh\nprintf 200\n' >"$T/stub/curl"
  chmod +x "$DOM/bin/"*.sh "$T/stub/ps" "$T/stub/curl"
  printf ' 4242 %s/ohs/bin/httpd -d %s/config/fmwconfig/components/OHS/instances/ohs1 -k start\n 4343 /jdk/bin/java -cp %s/oracle_common/x.jar weblogic.NodeManager\n' "$OH" "$DOM" "$OH" >"$T/ps.txt"
}
dbc() { local c="$1"; shift; HOME="$T/home" PATH="$T/stub:$PATH" ORACLE_HOME="" START_TIMEOUT=1 POLL=1 RUN_BASE="$T/runs" OS_RELEASE="${OSR-$T/os-release}" \
  bash "$SCRIPT" "$c" "$@" --oracle-home "$OH" --backup-dir "$T/backup" >"$T/out" 2>&1 </dev/null; echo $?; }
pre() { dbc preflight "$PD" "$@"; }
acts() { tr '\n' ' ' 2>/dev/null <"$T/actions"; }
nobackup() { [ -z "$(find "$T/backup" -mindepth 1 2>/dev/null)" ]; }
st() { cat "$T"/runs/*/state 2>/dev/null; }
rsf() { sed -n 's/.*oracle.rdbms.rsf" VER="\([^"]*\)".*/\1/p' "$OH/inventory/ContentsXML/comps.xml"; }

# ---- preflight ------------------------------------------------------------------------------------------
build; rc="$(pre)"
[ "$rc" = 0 ] && grep -q 'READY: nothing blocking' "$T/out" && ok || bad "a ready 12c home: rc $rc: $(grep -E 'BLOCK|UNKNOWN' "$T/out" | head -3)"
grep -q 'scope     : standalone OHS' "$T/out" && grep -q 'oracle.rdbms.rsf 12.1.0.2.0' "$T/out" && grep -q 'OS        : .*7.9' "$T/out" && ok || bad "preflight does not report scope, client and OS: $(grep -E 'scope|DB client|OS  ' "$T/out" | head -3)"
[ -z "$(acts)" ] && [ ! -d "$T/runs" ] && nobackup && ok || bad "preflight changed something: actions [$(acts)]"

# scope: three outcomes, never guessed from wlserver/
build; mkdir -p "$OH/wlserver"; rc="$(pre)"
[ "$rc" = 0 ] && grep -q 'scope     : standalone' "$T/out" && ok || bad "a standalone home with a wlserver/ dir was not read as standalone: rc $rc"
build; echo '<registry><distribution status="installed" name="Oracle HTTP Server (Collocated)" version="12.2.1.4.0"/></registry>' >"$OH/inventory/registry.xml"; rc="$(pre)"
[ "$rc" = 0 ] && grep -q 'scope     : collocated' "$T/out" && ok || bad "a collocated home: rc $rc"
build; mkdir -p "$OH/wlserver"; echo '<registry><distribution status="installed" name="WebLogic Server" version="12.2.1.4.0"/></registry>' >"$OH/inventory/registry.xml"; rc="$(pre)"
[ "$rc" = 1 ] && grep -q 'BLOCKING: .*embedded in another FMW product' "$T/out" && ok || bad "an embedded OHS (WebLogic Server, no OHS product) was not refused: rc $rc"
build; rm -f "$OH/inventory/registry.xml"; rc="$(pre)"
[ "$rc" = 2 ] && grep -q 'UNKNOWN: .*registry.xml' "$T/out" && ! grep -q READY "$T/out" && ok || bad "no registry.xml was not UNKNOWN: rc $rc"

# the client level
build; comps 19.0.0.0.0; rc="$(pre)"
[ "$rc" = 0 ] && grep -q 'already 19c, nothing to do' "$T/out" && ok || bad "a 19c home: rc $rc"
build; rm -f "$OH/inventory/ContentsXML/comps.xml"; rc="$(pre)"
[ "$rc" = 2 ] && grep -q 'UNKNOWN: .*oracle.rdbms.rsf' "$T/out" && ok || bad "no comps.xml: rc $rc (want 2)"

# OS: RHEL / OL 7.4+, unreadable is unknown
build; printf 'ID="ol"\nVERSION_ID="7.3"\n' >"$T/os-release"; rc="$(pre)"
[ "$rc" = 1 ] && grep -q 'BLOCKING: .*older than 7.4' "$T/out" && ok || bad "OL 7.3: rc $rc"
build; printf 'ID="ubuntu"\nVERSION_ID="22.04"\n' >"$T/os-release"; rc="$(pre)"
[ "$rc" = 1 ] && grep -q 'not Red Hat or Oracle Linux' "$T/out" && ok || bad "ubuntu: rc $rc"
build; printf 'Red Hat Enterprise Linux Server release 7.9 (Maipo)\n' >"$T/os-release"; rc="$(pre)"
[ "$rc" = 0 ] && ok || bad "a redhat-release file with 7.9: rc $rc: $(grep -E 'OS|BLOCK|UNKNOWN' "$T/out" | head -2)"
build; rc="$(OSR="$T/nonexistent" pre)"
[ "$rc" = 2 ] && grep -q 'UNKNOWN: .*OS' "$T/out" && ok || bad "an unreadable OS release was not UNKNOWN: rc $rc"

# patches: bare ids (no descriptions, as on Gen's home) are blocked until rolled back or kept
build; printf '27516009;\n27293599;\n25549931;\n' >"$LSP"; rc="$(pre)"
[ "$rc" = 1 ] && grep -q 'BLOCKING: patches installed .* 25549931 27293599 27516009' "$T/out" && [ "$(grep -c 'opatch.* rollback -id' "$T/out")" = 3 ] && grep -q 'takes that on your word' "$T/out" && ok || bad "bare-id patches were not blocked with a rollback line each: rc $rc"
build; printf '27516009;\n27293599;\n25549931;\n' >"$LSP"; rc="$(pre --keep-patches 27516009,25549931)"
[ "$rc" = 1 ] && grep -q 'neither rolled back nor kept: 27293599\.' "$T/out" && grep -q '27516009 kept' "$T/out" && ok || bad "--keep-patches did not keep exactly the named ids: rc $rc, $(grep -E 'kept|neither' "$T/out" | head -2)"
build; printf '27516009;\n' >"$LSP"; rc="$(pre --keep-patches 27516009)"
[ "$rc" = 0 ] && ok || bad "every patch kept: rc $rc (want 0)"
build; touch "$T/lsp.fail"; rc="$(pre)"
[ "$rc" = 2 ] && ok || bad "lspatches failed: rc $rc (want 2)"

# the installer zip
build; rm -f "$PD"/*.zip; rc="$(pre)"
[ "$rc" = 1 ] && grep -q 'no p34761383_\*.zip' "$T/out" && ok || bad "no zip: rc $rc"
build; rm -f "$PD"/*.zip; (cd "$T/zipsrc" && zip -q "$PD/p34761383_122140_Linux-x86-64.zip" changePerm.sh); rc="$(pre)"
[ "$rc" = 1 ] && grep -q 'does not hold fmw_12.2.1.19.0_dbclient_linux64.bin' "$T/out" && ok || bad "a zip without the installer: rc $rc"
build; rm -rf "${T:?}/backup"; rc="$(pre)"
[ "$rc" = 1 ] && grep -q 'backup dir .* missing or not writable' "$T/out" && ok || bad "no backup dir: rc $rc"
build; rm -f "$T/home/.wlst/"*; rc="$(pre)"
[ "$rc" = 1 ] && grep -q 'no stored node manager credentials' "$T/out" && ok || bad "no NM creds: rc $rc"

# ---- run ------------------------------------------------------------------------------------------------
build; rc="$(dbc run "$PD" --yes)"
[ "$rc" = 0 ] && [ "$(rsf)" = 19.0.0.0.0 ] && [ "$(cat "$OH/.sqlv")" = 19.14.0.0.0 ] && ok || bad "run on a ready home: rc $rc, rsf $(rsf): $(grep -E 'ERROR|BLOCK' "$T/out" | head -3)"
case "$(acts)" in "stop ohs1 stop ohs2 stopNM changePerm $OH install -invPtrLoc $OH/oraInst.loc -silent ORACLE_HOME=$OH start ohs1 start ohs2 ") ok;; *) bad "run order wrong: [$(acts)]";; esac
[ "$(find "$T"/backup -name '*.tgz' | wc -l | tr -d ' ')" = 3 ] && ok || bad "backup is not home + domain + inventory: $(find "$T"/backup -name '*.tgz')"
st | grep -q '^outcome=upgraded$' && st | grep -q '^pre_rsf=12.1.0.2.0$' && st | grep -q '^backup=ok$' && ok || bad "state: $(st | tr '\n' ' ')"
[ "$(grep -n '1/5 backup' "$T/out" | cut -d: -f1)" -lt "$(grep -n '2/5 stop' "$T/out" | cut -d: -f1)" ] && ok || bad "the backup is not taken before the stop"
# rollback of that run: the 12c client back, started again
: >"$T/actions"; rc="$(dbc rollback --yes)"
[ "$rc" = 0 ] && [ "$(rsf)" = 12.1.0.2.0 ] && [ "$(cat "$OH/.sqlv")" = 12.1.0.2.0 ] && ok || bad "rollback of a good run: rc $rc, rsf $(rsf): $(grep ERROR "$T/out" | head -2)"
# an already-19c home: nothing done
build; comps 19.0.0.0.0; rc="$(dbc run "$PD" --yes)"
[ "$rc" = 0 ] && [ -z "$(acts)" ] && nobackup && ok || bad "run on a 19c home did something: rc $rc, actions [$(acts)]"
# refusals: nothing stopped, nothing backed up
build; printf '27516009;\n' >"$LSP"; rc="$(dbc run "$PD" --yes)"
[ "$rc" = 1 ] && [ -z "$(acts)" ] && nobackup && ok || bad "run with an un-kept patch: rc $rc, actions [$(acts)]"
build; rc="$(dbc run "$PD")"
[ "$rc" != 0 ] && [ -z "$(acts)" ] && nobackup && ok || bad "run with no --yes and no terminal: rc $rc"
build; printf ' 4444 /jdk/bin/java -Dweblogic.Name=AdminServer -cp %s/wlserver/x.jar weblogic.Server\n' "$OH" >>"$T/ps.txt"; rc="$(dbc run "$PD" --yes)"
[ "$rc" = 1 ] && [ -z "$(acts)" ] && nobackup && grep -q 'WebLogic servers run from' "$T/out" && ok || bad "a WebLogic server from the home: rc $rc"
build; rc="$(PATCH_INTERACTIVE=1 dbc run "$PD" --yes)"
[ "$rc" != 0 ] && [ -z "$(acts)" ] && nobackup && grep -q 'dbclient-upgrade run changes this host' "$T/out" && ok || bad "an interactive run was not refused: rc $rc"
build; before="$(cd "$PD" && find . | sort)"; rc="$(dbc run "$PD" --dry-run --yes)"
[ "$rc" = 0 ] && [ -z "$(acts)" ] && nobackup && [ ! -d "$T/runs" ] && [ "$before" = "$(cd "$PD" && find . | sort)" ] && grep -q 'dry-run: would unzip' "$T/out" && ok || bad "dry-run changed something: rc $rc, actions [$(acts)]"
build; touch "$T/stop.stuck"; rc="$(dbc run "$PD" --yes)"
[ "$rc" = 1 ] && ! acts | grep -q install && acts | grep -q 'start ohs1' && [ "$(rsf)" = 12.1.0.2.0 ] && ok || bad "a stuck stop: rc $rc, actions [$(acts)]"

# every failure after the stop restores the 12c home and starts it; the level is proved before it starts
for mode in perm.fail inst.fail inst.noop inst.halfway start.fail-upgraded; do
  build; touch "$T/$mode"; rc="$(dbc run "$PD" --yes)"
  [ "$rc" = 1 ] && [ "$(rsf)" = 12.1.0.2.0 ] && [ "$(cat "$OH/.sqlv")" = 12.1.0.2.0 ] && [ ! -e "$OH/ohs/HALF" ] && st | grep -q '^outcome=rolled-back$' && grep -q 'RESTORED' "$T/out" && ok || bad "$mode: rc $rc (want 1, 12c restored), rsf $(rsf), $(st | grep outcome): $(grep ERROR "$T/out" | head -2)"
  case "$(acts)" in *"start ohs1"*) ok;; *) bad "$mode: not started again after the restore: [$(acts)]";; esac
  grep -q 'LOGS: ' "$T/out" && ok || bad "$mode: the logs are not named"
done
# the restore itself fails: exit 3, nothing started after the install, the manual restore printed
build; touch "$T/inst.fail" "$T/inst.corrupt"; rc="$(dbc run "$PD" --yes)"
[ "$rc" = 3 ] && grep -q 'RESTORE FAILED' "$T/out" && grep -q 'MANUAL RESTORE' "$T/out" && ok || bad "restore failed: rc $rc (want 3)"
case "$(acts)" in *install*start*) bad "started after a failed restore: [$(acts)]";; *) ok;; esac

# ---- case C: --remove-patches rolls back the named 12c patches itself, after the backup and stop ----------
three() { printf '27516009;\n27293599;\n25549931;\n' >"$LSP"; }
build; three; rc="$(pre --remove-patches 27516009,27293599,25549931)"
[ "$rc" = 0 ] && [ "$(grep -c 'to be rolled back (--remove-patches)' "$T/out")" = 3 ] && [ -z "$(acts)" ] && ok || bad "preflight with --remove-patches: rc $rc, actions [$(acts)]"
build; three; rc="$(dbc run "$PD" --yes --remove-patches 27516009,27293599,25549931)"
[ "$rc" = 0 ] && [ "$(rsf)" = 19.0.0.0.0 ] && [ ! -s "$LSP" ] && ok || bad "run with --remove-patches: rc $rc, lsp [$(tr '\n' ' ' <"$LSP")]: $(grep ERROR "$T/out" | head -2)"
case "$(acts)" in "stop ohs1 stop ohs2 stopNM rollback 25549931 rollback 27293599 rollback 27516009 changePerm "*) ok;; *) bad "removal is not after the stop and before the installer: [$(acts)]";; esac
[ "$(grep -c 'rolled back$' "$T/out")" = 3 ] && ok || bad "the removal is not visible in the run log"
build; three; printf '11111111;\n' >>"$LSP"; rc="$(pre --remove-patches 27516009,27293599,25549931)"
[ "$rc" = 1 ] && grep -q 'neither rolled back nor kept: 11111111\.' "$T/out" && ok || bad "a fourth, unnamed patch did not still block: rc $rc"
build; three; printf '11111111;\n' >>"$LSP"; rc="$(dbc run "$PD" --yes --remove-patches 27516009,27293599,25549931 --keep-patches 11111111)"
[ "$rc" = 0 ] && [ "$(tr -d '\n' <"$LSP")" = '11111111;' ] && ok || bad "a kept fourth patch was touched: rc $rc, lsp [$(tr '\n' ' ' <"$LSP")]"
build; three; touch "$T/rb.fail"; rc="$(dbc run "$PD" --yes --remove-patches 27516009,27293599,25549931)"
[ "$rc" = 1 ] && ! acts | grep -q install && [ "$(tr '\n' ' ' <"$LSP")" = '27516009; 27293599; 25549931; ' ] && acts | grep -q 'start ohs1' && grep -q 'RESTORED' "$T/out" && ok || bad "a failed rollback: rc $rc (want 1, no installer, restored), actions [$(acts)]"
for mode in rb.lie rb.fail-after; do   # each caught by one check alone: rc 0 with the patch still there; rc 1 with it gone
  build; three; touch "$T/$mode"; rc="$(dbc run "$PD" --yes --remove-patches 27516009,27293599,25549931)"
  [ "$rc" = 1 ] && ! acts | grep -q install && [ "$(tr '\n' ' ' <"$LSP")" = '27516009; 27293599; 25549931; ' ] && ok || bad "$mode: rc $rc (want 1, no installer, restored), actions [$(acts)]"
done
build; rc="$(dbc run "$PD" --yes --remove-patches 27516009,27293599,25549931)"
[ "$rc" = 0 ] && ! acts | grep -q rollback && [ "$(grep -c 'is not installed - nothing to roll back' "$T/out")" = 3 ] && ok || bad "a home with none of the three: rc $rc, actions [$(acts)]"
build; three; rc="$(pre --remove-patches 27516009 --keep-patches 27516009,27293599,25549931)"
[ "$rc" = 1 ] && grep -q 'named in both' "$T/out" && ok || bad "an id both kept and removed: rc $rc"
build; three; rc="$(dbc run "$PD" --yes --dry-run --remove-patches 27516009,27293599,25549931)"
[ "$rc" = 0 ] && [ -z "$(acts)" ] && grep -q 'would roll back 25549931 27293599 27516009' "$T/out" && ok || bad "dry-run with --remove-patches: rc $rc, actions [$(acts)]"

# ---- the steps as commands, for a composer: backup, apply --backup-run, verify ---------------------------
build; rc="$(dbc backup "$PD" --yes)"; rd="$(dirname "$(find "$T/runs" -name state | head -1)")"
[ "$rc" = 0 ] && [ -z "$(acts)" ] && st | grep -q '^backup=ok$' && ok || bad "backup: rc $rc, actions [$(acts)]: $(grep ERROR "$T/out" | head -2)"
rc="$(dbc apply "$PD" --yes)"
[ "$rc" = 1 ] && ! acts | grep -q install && grep -q 'stop first' "$T/out" && ok || bad "apply with OHS running: rc $rc, actions [$(acts)]"
: >"$T/ps.txt"; rc="$(PATCH_INTERACTIVE=1 dbc apply "$PD" --yes --backup-run "$rd")"
[ "$rc" != 0 ] && ! acts | grep -q install && grep -q 'dbclient-upgrade apply changes this host' "$T/out" && ok || bad "an interactive apply was not refused: rc $rc"
rc="$(dbc apply "$PD" --yes --backup-run "$rd")"
[ "$rc" = 0 ] && acts | grep -q install && [ "$(rsf)" = 19.0.0.0.0 ] && ok || bad "apply --backup-run: rc $rc, actions [$(acts)]: $(grep ERROR "$T/out" | head -2)"
rc="$(dbc verify)"
[ "$rc" = 0 ] && grep -q 'verified: .*Database Client 19c' "$T/out" && ok || bad "verify after apply: rc $rc"
build; rc="$(dbc backup "$PD" --yes)"; rd="$(dirname "$(find "$T/runs" -name state | head -1)")"; : >"$T/ps.txt"; touch "$T/inst.fail"
rc="$(dbc apply "$PD" --yes --backup-run "$rd")"
[ "$rc" = 1 ] && [ "$(rsf)" = 12.1.0.2.0 ] && [ ! -e "$OH/ohs/HALF" ] && ok || bad "a failed apply did not restore from the --backup-run backup: rc $rc, rsf $(rsf)"
build; : >"$T/ps.txt"; rc="$(dbc apply "$PD" --yes)"
[ "$rc" = 1 ] && ! acts | grep -q install && grep -q 'no completed backup' "$T/out" && ok || bad "apply with no backup: rc $rc"
build; mkdir -p "$T/runs/x-run"; printf 'oracle_home=/elsewhere\nbackup=ok\n' >"$T/runs/x-run/state"; : >"$T/ps.txt"; rc="$(dbc apply "$PD" --yes --backup-run "$T/runs/x-run")"
[ "$rc" = 1 ] && ! acts | grep -q install && grep -q 'is a backup of /elsewhere' "$T/out" && ok || bad "apply with another home's backup: rc $rc"
build; rc="$(dbc verify)"
[ "$rc" = 1 ] && grep -q 'NOT 19c' "$T/out" && ok || bad "verify on a 12c home: rc $rc"
build; comps 19.0.0.0.0; rc="$(dbc verify)"
[ "$rc" = 1 ] && ok || bad "verify with rsf 19 but sqlplus 12.1 (one source only): rc $rc (want 1)"
build; echo 19.14.0.0.0 >"$OH/.sqlv"; rc="$(dbc verify)"
[ "$rc" = 1 ] && grep -q 'NOT 19c' "$T/out" && ok || bad "verify with sqlplus 19.14 but rsf 12.1 (the other source only): rc $rc (want 1)"

build; rc="$(dbc frobnicate)"
grep -q 'unknown command frobnicate (inspect, preflight, backup, apply, verify, run, rollback)' "$T/out" && ok || bad "unknown command message: $(head -2 "$T/out")"
build; rc="$(dbc inspect)"
[ "$rc" = 0 ] && grep -q 'installed as: standalone' "$T/out" && grep -q 'oracle.rdbms.rsf 12.1.0.2.0; sqlplus -V 12.1.0.2.0' "$T/out" && ok || bad "inspect: rc $rc: $(head -5 "$T/out")"

echo "dbclient-upgrade gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
