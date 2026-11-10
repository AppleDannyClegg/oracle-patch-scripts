# shellcheck shell=bash disable=SC2034,SC2016   # sourced by tests/dry-run-gate.sh and tests/false-success-gate.sh: ARGS*, FAIL_*, OK* are read there
# wls-patch: a WebLogic 14.1.1 home under $T/env/fmw with a fake OPatch, a JDK 11 whose java answers -version itself, one domain
# (AdminServer 7001, ms1 7101) whose stop/start scripts run the gate's wlst.sh stub - the change the gates can see - and the PSU
# 37000001 waiting, already unzipped, in $T/env/patches. The servers are in the gate's ps ($T/ps.txt) for the commands that must
# find them up (stop, backup, preflight, run); apply refuses a running domain, so for it and the rest the domain is down.
OH="$T/env/fmw"; DOM="$T/env/domains/base_domain"; JH="$T/env/jdk"
mkdir -p "$OH/OPatch" "$OH/inventory" "$OH/wlserver" "$JH/bin" "$DOM/config" "$DOM/bin" "$DOM/servers/ms1/tmp" "$T/env/patches/extracted/37000001/etc/config" "$T/env/backups"
# opatch: version/lspatches/prereq answer here; apply and rollback go to the stub, and only a stub that SUCCEEDED moves the patch in
# or out of the inventory ($T/env/installed) - a failed apply is not in lspatches, a failed rollback still is, as on a real home
cat >"$OH/OPatch/opatch" <<O
#!/bin/sh
case "\$1" in
  version) echo "OPatch Version: 13.9.4.2.17"; exit 0;;
  lspatches) [ -e "$T/env/installed" ] && echo "37000001;WLS PATCH SET UPDATE 14.1.1.0.241015"; echo "35000000;WLS PATCH SET UPDATE 14.1.1.0.240716"; exit 0;;
  prereq) echo 'Prereq "checkConflictAgainstOHWithDetail" passed.'; exit 0;;
  apply) "$STUB/opatch" "\$@" && touch "$T/env/installed"; exit \$?;;
  rollback) "$STUB/opatch" "\$@" && rm -f "$T/env/installed"; exit \$?;;
esac
exec "$STUB/opatch" "\$@"
O
chmod +x "$OH/OPatch/opatch"
printf '<registry><distribution status="installed" name="WebLogic Server" version="14.1.1.0.0"/></registry>\n' >"$OH/inventory/registry.xml"
printf 'inventory_loc=%s/env/oraInventory\ninst_group=staff\n' "$T" >"$OH/oraInst.loc"; mkdir -p "$T/env/oraInventory"
printf '#!/bin/sh\n[ "$1" = -version ] && { echo '"'"'openjdk version "11.0.21" 2023-10-17'"'"' >&2; exit 0; }\nexec "%s/java" "$@"\n' "$STUB" >"$JH/bin/java"; chmod +x "$JH/bin/java"
# the domain: one tag per line, which is how parse_domain_servers reads config.xml
cat >"$DOM/config/config.xml" <<'X'
<domain>
  <name>base_domain</name>
  <server>
    <name>AdminServer</name>
    <listen-port>7001</listen-port>
  </server>
  <server>
    <name>ms1</name>
    <ssl>
      <enabled>true</enabled>
      <listen-port>7102</listen-port>
    </ssl>
    <listen-port>7101</listen-port>
  </server>
  <admin-server-name>AdminServer</admin-server-name>
</domain>
X
# the servers as ps shows them: pids that no process has, so kill -0 says 'gone' at once and only ps (which the stop scripts edit) can say
# whether a server is still up - the second proof cmd_stop takes. The stop/start scripts run the gate's wlst.sh stub (a real domain's
# scripts run WLST too) and, on its success, take the server out of ps or put it back
printf '999901 %s/bin/java -Dweblogic.Name=AdminServer -Xmx512m weblogic.Server\n999902 %s/bin/java -Dweblogic.Name=ms1 -Xmx512m weblogic.Server\n' "$JH" "$JH" >"$T/env/ps.all"
cat >"$DOM/bin/stopManagedWebLogic.sh" <<S
#!/bin/sh
wlst.sh stopManaged.py "\$1" "\$2" || exit 1
grep -v -- "-Dweblogic.Name=\$1 " "$T/ps.txt" >"$T/ps.new" 2>/dev/null; mv "$T/ps.new" "$T/ps.txt"
S
cat >"$DOM/bin/stopWebLogic.sh" <<S
#!/bin/sh
wlst.sh stopAdmin.py || exit 1
grep -v -- "-Dweblogic.Name=AdminServer " "$T/ps.txt" >"$T/ps.new" 2>/dev/null; mv "$T/ps.new" "$T/ps.txt"
S
cat >"$DOM/bin/startWebLogic.sh" <<S
#!/bin/sh
wlst.sh startAdmin.py || exit 1
grep -- "-Dweblogic.Name=AdminServer " "$T/env/ps.all" >>"$T/ps.txt"
S
cat >"$DOM/bin/startManagedWebLogic.sh" <<S
#!/bin/sh
wlst.sh startManaged.py "\$1" "\$2" || exit 1
grep -- "-Dweblogic.Name=\$1 " "$T/env/ps.all" >>"$T/ps.txt"
S
chmod +x "$DOM"/bin/*.sh
case "$CMD" in stop|backup|preflight|run) cp "$T/env/ps.all" "$T/ps.txt";; *) rm -f "$T/ps.txt";; esac
# the patch, already unzipped where prepare_patch_dir looks (pdir/extracted/<id>/etc/config/inventory.xml), README naming the release
printf '<oneoffs><oneoff ref_id="37000001"><description>WLS PATCH SET UPDATE 14.1.1.0.241015</description></oneoff></oneoffs>\n' >"$T/env/patches/extracted/37000001/etc/config/inventory.xml"
printf 'Patch 37000001: WLS PATCH SET UPDATE 14.1.1.0.241015\nThis patch is for Oracle WebLogic Server 14.1.1.0.0\nOPatch 13.9.4.2.0 or later is required\n' >"$T/env/patches/extracted/37000001/README.txt"
# installed for the commands that come after apply (rollback must have something to roll back; verify sees it in the inventory)
case "$CMD" in rollback|verify|restore|start) touch "$T/env/installed";; esac
export ORACLE_HOME="$OH" DOMAIN_HOME="$DOM" JAVA_HOME="$JH" BACKUP_DIR="$T/env/backups" STOP_TIMEOUT=1 START_TIMEOUT=1
# an empty ARGS_<cmd> falls back to ARGS in the gates (${!a:-$ARGS}), so rollback names its id: without it the patch DIR arrived as the id
ARGS="$T/env/patches"; ARGS_rollback="37000001"; ARGS_download="$T/env/patches 37000001"; ARGS_restore="$T/env/backups/latest"   # restore takes the backup dir: with the fallback it looked in the patch dir and never ran
# a run dir as 'apply' left it, and the backup it took: for rollback, restore, start and verify
B="$T/env/backups/b1"; mkdir -p "$B"; tar -czf "$B/oracle_home.tar.gz" -C "$T/env" fmw; tar -czf "$B/domain-1.tar.gz" -C "$T/env/domains" base_domain
printf '%s\n' "$OH" >"$B/oracle_home.txt"; printf '%s\n' "$DOM" >"$B/domains.txt"; ln -sfn "$B" "$T/env/backups/latest"
R="$T/home/wls-patch/runs/r1"; mkdir -p "$R"
printf 'patch_dir=%s/env/patches\npreflight_problems=0\nbackup_dir=%s\nservers_were_running=AdminServer ms1 \nnm_was_running=0\napplied=37000001\n' "$T" "$B" >"$R/state"
ln -sfn "$R" "$T/home/wls-patch/runs/latest"
# rollback: the change is 'opatch rollback' (the domain is down for it); run: the change is 'opatch apply' - backup (tar) and stop
# (wlst.sh, the servers leave ps) before it are real, the fake opatch leaves the failed PSU out of lspatches (failed_patch=37000001),
# nothing is recorded as applied so rollback has nothing to do, and start's wlst.sh succeeds but no port answers, rc 1
FAIL_rollback='^opatch rollback'; FAIL_run='^opatch apply'
# <cmd>:ps_unreadable - ps cannot run (the gate's $T/ps.fail; needs the gate that honours it). Every command that acts on 'nothing
# running' must stop with rc 1 and no state line, not go on as if the domain were down (Durandal 2 Nov 00:21 / Fable-4 00:31: before,
# restore replaced the home, apply and rollback ran OPatch, heal removed the .lok, inspect/preflight said nothing was running). No
# stub call is meant to fail in these cases, so FAIL_* matches nothing and the ps stub's own FAILED line is what the gate counts. Not
# here: inspect/preflight/verify (read-only commands the gates do not run; the commit's hand harness covers them), start (its node manager branch is reached only with nm_was_running=1 and a startNodeManager.sh; rc is 1 either way because
# no port answers, so the gate could not see the second node manager - the hand harness in the commit does) and stop (3ab88b8).
for c in apply rollback restore heal; do eval "CASES_$c='ps_unreadable'; FAIL_${c}__ps_unreadable='^never matches\$'"; done
case "${CASE:-}" in ps_unreadable) : >"$T/ps.fail"; [ "$CMD" = heal ] && touch "$DOM/servers/ms1/tmp/ms1.lok";; esac
# T264: heal deletes an orphaned .lok and reports "0 issue(s) found, 0 fixed" when the delete FAILS. The ps list is
# READABLE here (no ps.fail) and no server is up, so the .lok is orphaned by the script's own rule and the rm is the
# change it claims: FAIL_heal__rm_fails makes only that call fail, so the case is about the delete, not about ps.
CASES_heal="$CASES_heal rm_fails"
FAIL_heal__rm_fails='^rm -f .*/servers/ms1/.*\.lok'
case "${CASE:-}" in rm_fails) [ "$CMD" = heal ] && : >"$DOM/servers/ms1/tmp/ms1.lok";; esac
