#!/usr/bin/env bash
# ohs-quarter-explain: read what a stopped ohs-quarter.sh run printed, and say what state the home is in and the next
# commands to run by hand, with this run's own paths filled in. It only reads: it writes nothing and runs nothing.
#
# Usage: ohs-quarter-explain.sh <console-log> [<run-dir>]
#   <console-log>  everything ohs-quarter.sh printed. It logs to stderr only, so keep it with
#                  ohs-quarter.sh <options> 2>&1 | tee ohs-quarter.log
#   <run-dir>      the run's --run-dir (or the one it made), to fill in the real paths. A run that stopped before it
#                  made one has none.
#   --keys         print the message fragments it knows, one per line (the test checks them against ohs-quarter.sh)
# Exit: 0 explained; 2 cannot say (no log, or no ohs-quarter stop message in it). It never guesses a path.

set -uo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P="$(cd "$SD/.." && pwd)"
TEE_HINT='Next time keep the log: ohs-quarter.sh <options> 2>&1 | tee ohs-quarter-$(date +%Y%m%d-%H%M%S).log'

# One row per message ohs-quarter.sh stops with: <fixed fragment of the message>|<path>. Rows are in precedence order:
# the first row whose fragment is in the log decides, so a recovery's outcome beats the failure that started it.
ROWS='Could not stop the components to recover|E1
the restore failed - restore this home by hand from the backup|E2
wls-patch restore failed|E2
java-patch rollback failed|E2
Recovery incomplete - components NOT started|E2
the components did not start after recovery|E3
nothing was patched, and NOT everything started again|C3
nothing was patched; the components are started again|C1
Starting them again|C3
Could not stop the components cleanly|C3
recovering: stopping the components first|D
apply failed|D
verify failed|D
the patched home does not start|D
interrupted after the stop|D
interrupted during the stop|C3
a backup failed - nothing changed|B
OUTPUT_DIR must be an absolute path|A
needs a value|A
Unknown option|A
Unknown argument|A
not found or not executable|A
patch root is not a directory|A
which is not a folder of this runbook|A
that is a get-patches.ps1 download tree|A
more than one JDK tarball in|A
is not readable|A
nothing to apply under|A
has content for it. Remove it from --skip|A
Not applying a partial runbook without being told to|A
Cannot create the run dir|A
preflight failed|A
Non-interactive and --yes not given|A
aborted - nothing changed|A
interrupted - nothing changed|A'

case "${1:-}" in
  --keys) printf '%s\n' "$ROWS" | cut -d'|' -f1; exit 0;;
  -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
esac
[ $# -ge 1 ] && [ $# -le 2 ] || { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
LOG="$1"; RD="${2:-}"
[ -s "$LOG" ] || { echo "No console log at $LOG, so where the run stopped is unknown, and this will not guess from the run dir alone."; echo "$TEE_HINT"; exit 2; }

has() { grep -qF -- "$1" "$LOG"; }
path=""
while IFS='|' read -r key p; do has "$key" && { path="$p"; break; }; done <<<"$ROWS"
[ -n "$path" ] || { echo "No ohs-quarter.sh stop message in $LOG: it is not this script's output, or it was cut before the end."; echo "$TEE_HINT"; exit 2; }

# ---- this run's own values, where the run dir has them ----------------------------------------------------------
sv() { [ -n "$RD" ] && [ -f "$1" ] && sed -n "s/^$2=//p" "$1" | tail -1; }
RUN="${RD:-<RUN_DIR>}"
SHARED="$(sv "$RD/state" shared_backup)"; SHARED="${SHARED:-$RUN/backup}"
OH="$(sv "$SHARED/state" oracle_home)"; [ -n "$OH" ] || OH="$(sv "$RD/opatch/state" oracle_home)"; OH="${OH:-<ORACLE_HOME>}"
ARCH="$(sv "$SHARED/state" backup_dir)"; ARCH="${ARCH:-<backup_dir= in $SHARED/state>}"
WLSBK="$(sv "$RD/wls/state" backup_dir)"; WLSBK="${WLSBK:-<backup_dir= in $RUN/wls/state>}"

# the cause: the first ERROR before recovery began (a child's own ERROR comes before ohs-quarter's line about it)
cause="$(awk '/recovering: stopping the components first/ { exit } /\[ERROR\]|^ERROR:/ { print; exit }' "$LOG")"

START="$P/ohs-patch/ohs-patch.sh start --oracle-home $OH --run-dir $RUN/opatch"
VERIFY="$P/ohs-patch/ohs-patch.sh verify --oracle-home $OH"
n=0; step() { n=$((n + 1)); printf '  %d. %s\n' "$n" "$*"; }
restores() { # the by-hand restore for each set recovery tried or should have, newest first (recover's own order)
  local sh=0 wl=0 jv=0
  if has 'recovering: dbclient-upgrade rollback' || has 'recovering: ohs-patch rollback' || has 'recovering: wls-patch restore' || has 'recovering: java-patch rollback'; then
    # recover logs one "recovering:" line per set it restores, so when it got that far those lines are the list
    { has 'recovering: dbclient-upgrade rollback' || has 'recovering: ohs-patch rollback'; } && sh=1
    has 'recovering: wls-patch restore' && wl=1; has 'recovering: java-patch rollback' && jv=1
  else
    # recover stopped before them (E1): the sets that applied, and the one whose apply failed
    { grep -F ': applied ' "$LOG" | grep -vqE 'jdk: applied|wlspsu: applied' || has 'dbclient-upgrade apply failed' || has 'ohs-patch apply failed'; } && sh=1
    { has 'wlspsu: applied' || has 'wls-patch apply failed'; } && wl=1
    { has 'jdk: applied' || has 'java-patch apply failed'; } && jv=1
    if has 'interrupted after the stop'; then
      # an apply logs nothing until it succeeds, so the set it was in when the signal came is not in the log. Every
      # other set that passed its preflight is listed as 2: check it, and restore it only if it changed
      step "the set being applied when the run was interrupted is not in the log, so each set below marked CHECK FIRST may or may not have been touched"
      [ "$sh" = 0 ] && grep -F ' preflight OK' "$LOG" | grep -vqE 'jdk: |wlspsu: ' && sh=2
      [ "$wl" = 0 ] && has 'wlspsu: ' && wl=2; [ "$jv" = 0 ] && has 'jdk: ' && jv=2
    fi
  fi
  if [ "$sh" != 0 ]; then
    [ "$sh" = 2 ] && step "CHECK FIRST, home + inventory: compare $OH/OPatch/opatch lspatches with pre_patches= in $SHARED/state. Only if they differ:"
    if has 'dbclient: ' || has 'recovering: dbclient-upgrade rollback'; then
      step "home + inventory (DB Client installer): $P/dbclient-upgrade/dbclient-upgrade.sh rollback --oracle-home $OH --run-dir $SHARED (add the --backup-dir you gave ohs-quarter, if any). If that fails too: mv $OH $OH.failed-\$(date +%Y%m%d%H%M%S), then untar home.tgz, oraInventory.tgz and each domain-<name>.tgz from $ARCH into their parent dirs."
    else
      step "home + inventory (opatch): $P/ohs-patch/ohs-patch.sh rollback --oracle-home $OH --run-dir $SHARED. If that fails too, run the tar restore its preflight printed under \"ROLLBACK (complete)\": opatch rollback -id alone does not bring back a bundle a patch replaced."
    fi
  fi
  if [ "$wl" != 0 ]; then
    [ "$wl" = 2 ] && step "CHECK FIRST, WLS: compare $OH/OPatch/opatch lspatches with the WLS level before the run. Only if it changed:"
    step "WLS home + domains: $P/wls-patch/wls-patch.sh restore $WLSBK --oracle-home $OH --run-dir $RUN/wls"
  fi
  if [ "$jv" != 0 ]; then
    [ "$jv" = 2 ] && step "CHECK FIRST, JDK: is the JAVA_HOME the products use still the old JDK? Only if not:"
    step "JDK: $P/java-patch/java-patch.sh rollback --run-dir $RUN/java, then check the JAVA_HOME the products use points at the old JDK again"
  fi
}

case "$path" in
  A)  echo "PATH A: stopped before any change. Nothing is stopped, backed up or patched."
      echo "HOME: unchanged and running."; echo "CAUSE: ${cause:-see the last lines of the log}"; echo "NEXT, by hand:"
      step "fix the cause above (for a preflight failure, the child's own ERROR lines say why)"
      step "rerun with --dry-run first, then for real";;
  B)  echo "PATH B: a backup failed. Nothing is stopped or patched."
      echo "HOME: unchanged and running."; echo "CAUSE: ${cause:-see the last lines of the log}"; echo "NEXT, by hand:"
      step "free the space or fix what the child's ERROR names (usually disk under --backup-dir), then rerun"
      step "the backups that finished before the failing one ($RUN/java, $RUN/wls, $SHARED) are not reused: remove them once the rerun has its own";;
  C1) echo "PATH C1: the stop could not be proved, so nothing was patched, and the components were started again."
      echo "HOME: unpatched; started again, but check it."; echo "CAUSE: ${cause:-see the last lines of the log}"; echo "NEXT, by hand:"
      step "check every component answers: $VERIFY"
      step "find what would not stop: ps -ef | grep $OH"
      step "fix that, then rerun";;
  C3) echo "PATH C3: nothing was patched, but the components may NOT all be running: the stop or the start again did not finish."
      echo "HOME: unpatched; some or all of OHS and node manager may be DOWN."; echo "CAUSE: ${cause:-see the last lines of the log}"; echo "NEXT, by hand:"
      step "see what runs from the home: ps -ef | grep $OH (the port check in the log, if any, says which answer)"
      step "start them: $START (or the domain's startNodeManager.sh, then startComponent.sh <c>)"
      step "check: $VERIFY";;
  D)  echo "PATH D: a step failed after the stop, and recovery restored and started the home."
      echo "HOME: back at its pre-run level and running. (If ohs-quarter exited 3, the log is cut short: treat it as E.)"
      echo "CAUSE: ${cause:-see the first ERROR above \"recovering:\" in the log}"; echo "NEXT, by hand:"
      step "check every component answers: $VERIFY (and sqlplus -V if this run had a dbclient/ set)"
      step "fix the cause above, dry-run, then rerun"
      step "keep $RUN and its backups until the rerun is good";;
  E1) echo "PATH E1: a step failed after the stop, and recovery could not stop the components. NOTHING is restored, and they are NOT started."
      echo "HOME: may be part-patched, and not started."; echo "CAUSE: ${cause:-see the first ERROR in the log}"; echo "NEXT, by hand:"
      step "stop everything from the home (stopComponent.sh for each, stopNodeManager.sh) and check: ps -ef | grep $OH"
      restores
      step "start: $START"
      step "check: $VERIFY";;
  E2) echo "PATH E2: a step failed after the stop, and a restore failed. The components are NOT started."
      echo "HOME: may be part-patched, and not started."; echo "CAUSE: ${cause:-see the first ERROR in the log}"
      echo "FAILED IN RECOVERY:"; grep -E 'the restore failed|wls-patch restore failed|java-patch rollback failed' "$LOG" | sed 's/^/  /'
      echo "NEXT, by hand (retry each restore; a set already restored is done again harmlessly):"
      restores
      step "start: $START"
      step "check: $VERIFY";;
  E3) echo "PATH E3: a step failed after the stop. Every restore worked, but the components did not start."
      echo "HOME: back at its pre-run level, NOT running."; echo "CAUSE: ${cause:-see the first ERROR in the log}"; echo "NEXT, by hand:"
      step "start: $START (or startNodeManager.sh, then startComponent.sh <c>)"
      step "if it will not start, read <domain>/servers/<c>/logs and nodemanager.out"
      step "check: $VERIFY";;
esac
echo "RUN_DIR: $RUN"
