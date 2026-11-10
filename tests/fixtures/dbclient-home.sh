# shellcheck shell=bash
# The fake Oracle HTTP Server 12.2.1.4 home with a 12c Database Client, shared by the gates that need to drive the
# REAL patching scripts: tests/dbclient-upgrade.sh (its 78 cases) and the composer case in tests/ohs-quarter.sh, which
# must not invent the one-backup contract with a stub child (T291).
#
# Contract: the caller sets $T (a private temp dir it owns and traps), and $SCRIPT when it runs the child through
# dbc(). Everything inside lives under $T, so two gates can use it side by side. It defines:
#   OH DOM PD LSP                     the home, its domain, the patch dir and the lspatches list
#   comps <ver>  build  stub-copies   the fixture as the child script sees it
#   dbc <verb> [args]                 run the REAL child ($SCRIPT) against it, echo its exit code
#   pre acts nobackup st rsf          the small readers the cases use
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
