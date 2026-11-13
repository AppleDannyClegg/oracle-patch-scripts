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
# SCRIPT is the child the fixture's dbc() runs, so shellcheck cannot see the use from here
# shellcheck disable=SC2034
SCRIPT=patching/dbclient-upgrade/dbclient-upgrade.sh
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "${T:?}"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

. "$(dirname "$0")/fixtures/dbclient-home.sh"
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
grep -q 'registry.xml names: WebLogic Server$' "$T/out" && ok || bad "the refusal does not show what registry.xml names: $(grep BLOCKING "$T/out" | head -1)"
build; printf '<registry>\n <distribution status="installed" name="Fusion Middleware Infrastructure" version="12.2.1.4.0">\n  <feature-set name="ohs"/>\n </distribution>\n <distribution status="installed" name="Oracle HTTP Server Web Tier" version="12.2.1.4.0"/>\n</registry>\n' >"$OH/inventory/registry.xml"; rc="$(pre)"
[ "$rc" = 1 ] && grep -q 'registry.xml names: Fusion Middleware Infrastructure; Oracle HTTP Server Web Tier$' "$T/out" && ok || bad "two distributions not both named: $(grep BLOCKING "$T/out" | head -1)"
# the names listed (T1118, Nexus #15849): two tags on one line, a deinstalled entry, more than 8, a wrapped tag
regnames() { printf "$1" >"$OH/inventory/registry.xml"; rc="$(pre)"; [ "$rc" = 1 ] && grep -q "registry.xml names: $2\$" "$T/out" && ok || bad "$3: rc $rc: $(grep BLOCKING "$T/out" | sed 's/.*registry.xml names: //' | head -1)"; }
build; regnames '<registry><distribution status="installed" name="A"/><distribution status="installed" name="B"/></registry>\n' 'A; B' "two distributions on one line"
build; regnames '<distribution status="deinstalled" name="Old"/>\n<distribution status="installed" name="New"/>\n' 'New' "a deinstalled distribution was listed"
build; regnames "$(for i in 1 2 3 4 5 6 7 8 9 10; do printf '<distribution status="installed" name="P%s"/>\\n' $i; done)" 'P1; P2; P3; P4; P5; P6; P7; P8; ... (2 more)' "more than 8 names"
build; regnames '<distribution status="installed"\n    name="Wrapped" version="1"/>\n' 'Wrapped' "a tag with name= on the next line"
build; regnames '<distribution status="installed"\nname="NoIndent" version="1"/>\n' 'NoIndent' "a tag with name= at the start of the next line (the lines are joined with a space)"
build; regnames '<distribution status="installed" name="Dup"/>\n<distribution status="installed" name="Other"/>\n<distribution status="installed" name="Dup"/>\n' 'Dup; Other' "a name given twice is listed once, at its first place"
build; regnames '<distribution status="deinstalled" name="Old"/>\n' 'no installed <distribution> entries' "only a deinstalled entry"
# the field shape (12 Nov 2026): a multi-line registry.xml whose distribution is plain "Oracle HTTP Server", plus OPatch
field_reg() { printf '<registry>\n   <distributions>\n      <distribution status="installed" name="Oracle HTTP Server" version="12.2.1.4.0">\n         <feature-set name="WebLogic Server"/>\n      </distribution>\n%b      <distribution status="installed" name="OPatch" version="13.9.4.2.25">\n      </distribution>\n   </distributions>\n</registry>\n' "$1" >"$OH/inventory/registry.xml"; }
build; mkdir -p "$OH/wlserver"; field_reg ""; rc="$(pre)"
[ "$rc" = 0 ] && grep -q 'scope     : standalone OHS (registry.xml: Oracle HTTP Server; OPatch)' "$T/out" && ok || bad "the field standalone shape (plain 'Oracle HTTP Server' + OPatch) was not standalone: rc $rc: $(grep -E 'scope|BLOCK' "$T/out" | head -2)"
build; field_reg '      <distribution status="installed" name="Fusion Middleware Infrastructure" version="12.2.1.4.0">\n      </distribution>\n'; rc="$(pre)"
[ "$rc" = 0 ] && grep -q 'scope     : collocated OHS' "$T/out" && ok || bad "plain OHS + Infrastructure was not collocated: rc $rc: $(grep -E 'scope|BLOCK' "$T/out" | head -2)"
build; field_reg '      <distribution status="installed" name="Oracle Forms and Reports" version="12.2.1.4.0">\n      </distribution>\n'; rc="$(pre)"
[ "$rc" = 1 ] && grep -q 'BLOCKING: .*embedded in another FMW product.*Oracle Forms and Reports' "$T/out" && ok || bad "plain OHS inside a Forms home was not refused as embedded: rc $rc: $(grep -E 'scope|BLOCK' "$T/out" | head -2)"
build; printf '<registry>\n <distribution status="installed" name="Oracle HTTP Server Plugins" version="12.2.1.4.0"/>\n</registry>\n' >"$OH/inventory/registry.xml"; rc="$(pre)"
[ "$rc" = 1 ] && ok || bad "a distribution only starting with 'Oracle HTTP Server' passed as the OHS installer's: rc $rc"
# scope rests on reg_names (Nexus #15865): a non-OHS tag sharing a line, a lone deinstalled OHS, a wrapped OHS tag
build; printf '<registry><distribution status="installed" name="Oracle Forms and Reports"/><distribution status="installed" name="Oracle HTTP Server"/></registry>\n' >"$OH/inventory/registry.xml"; rc="$(pre)"
[ "$rc" = 1 ] && grep -q 'BLOCKING: .*embedded in another FMW product' "$T/out" && ok || bad "Forms then OHS on one line was not embedded: rc $rc: $(grep -E 'scope|BLOCK' "$T/out" | head -1)"
build; printf '<registry>\n <distribution status="deinstalled" name="Oracle HTTP Server" version="12.2.1.4.0"/>\n</registry>\n' >"$OH/inventory/registry.xml"; rc="$(pre)"
[ "$rc" = 1 ] && grep -q 'BLOCKING: .*embedded in another FMW product' "$T/out" && ok || bad "a lone deinstalled OHS was not refused: rc $rc: $(grep -E 'scope|BLOCK' "$T/out" | head -1)"
build; printf '<registry>\n <distribution status="installed"\n    name="Oracle HTTP Server" version="12.2.1.4.0">\n </distribution>\n <distribution status="installed" name="OPatch" version="13.9.4.2.25"/>\n</registry>\n' >"$OH/inventory/registry.xml"; rc="$(pre)"
[ "$rc" = 0 ] && grep -q 'scope     : standalone OHS (registry.xml: Oracle HTTP Server; OPatch)' "$T/out" && ok || bad "a wrapped OHS tag + OPatch was not standalone: rc $rc: $(grep -E 'scope|BLOCK' "$T/out" | head -1)"
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

# --run-dir is HONOURED by backup (T291, Edi #13261): the composer takes one shared backup and then applies with
# --backup-run $SHARED (ohs-quarter.sh:249 then :336), and the child refuses without $SHARED/state. A backup that
# accepts --run-dir and writes its own $RUN_BASE/<stamp>-run instead leaves the composer's apply with no state at all.
build; SH="$T/shared"; rc="$(dbc backup "$PD" --run-dir "$SH" --yes)"
# the composer's SEQUENCE, not just the option: backup with --run-dir, then apply with --backup-run on THAT dir,
# with nothing running (the composer stops before it applies). rc 0 here; on the pre-fix bytes the apply is rc 1 with
# "apply refused: no completed backup" - the outage already started. T291/Edi #13313.
build; rc="$(dbc backup "$PD" --run-dir "$SH" --yes)"; : >"$T/ps.txt"; rc2="$(dbc apply "$PD" --backup-run "$SH" --yes)"
[ "$rc" = 0 ] && [ "$rc2" = 0 ] && ok || bad "the composer's backup -> apply link: backup rc $rc, $SH/state $([ -f "$SH/state" ] && echo present || echo MISSING), apply rc $rc2: $(grep -E 'ERROR' "$T/out" | head -2)"
[ "$rc" = 0 ] && [ -f "$SH/state" ] && ok || bad "backup ignored --run-dir: rc $rc, $SH/state $([ -f "$SH/state" ] && echo present || echo MISSING), run dirs: $(find "$T/runs" -mindepth 1 -maxdepth 1 2>/dev/null | head -3 | tr '\n' ' ')"

# ---- run ------------------------------------------------------------------------------------------------
build; rc="$(dbc run "$PD" --yes)"
[ "$rc" = 0 ] && [ "$(rsf)" = 19.0.0.0.0 ] && [ "$(cat "$OH/.sqlv")" = 19.14.0.0.0 ] && ok || bad "run on a ready home: rc $rc, rsf $(rsf): $(grep -E 'ERROR|BLOCK' "$T/out" | head -3)"
case "$(acts)" in "stop ohs1 stop ohs2 stopNM changePerm $OH install -invPtrLoc $OH/oraInst.loc -silent ORACLE_HOME=$OH start ohs1 start ohs2 ") ok;; *) bad "run order wrong: [$(acts)]";; esac
# T1550 operator-stops: the operator owns every start and stop; no stop/start script runs and the commands print
build; : >"$T/ps.txt"; : >"$T/actions"
rc="$(dbc run "$PD" --operator-stops --yes)"
[ "$rc" = 0 ] && ok || bad "operator-stops run: rc $rc: $(grep -E 'ERROR|BLOCK' "$T/out" | head -2)"
case "$(acts)" in *stop*|*start*) bad "operator-stops ran a stop/start script: [$(acts)]";; *) ok;; esac
grep -q 'the operator starts node manager and the components now' "$T/out" && ok || bad "operator-stops does not hand the start to the operator"
grep -q 'left STOPPED for the operator to start' "$T/out" && ! grep -q 'every component answers' "$T/out" && ok || bad "operator-stops dbclient still claims every component answers"
grep -q 'bin/stopComponent.sh' "$T/out" && grep -q 'bin/startComponent.sh' "$T/out" && ok || bad "operator-stops did not print the stop and start commands"
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
