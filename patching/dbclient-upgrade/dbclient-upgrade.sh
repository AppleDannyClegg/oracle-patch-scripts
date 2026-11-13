#!/usr/bin/env bash
# dbclient-upgrade.sh - upgrade the Database Client in an Oracle HTTP Server 12.2.1.4 home from 12c to 19c with the
# FMW installer in patch 34761383 (KB585169), the step every DB19C bundle (40005842 and the rest) needs first.
# inspect, preflight and verify are read-only. backup, apply, run and rollback change the host, and refuse to start
# from an interactive shell that is not detached (tmux, screen, nohup, or PATCH_DETACHED=1).
#
# Commands
#   inspect                 read-only: home, how it was installed (registry.xml), the Database Client level
#                           (oracle.rdbms.rsf in comps.xml, sqlplus -V), the OS release, the patches installed
#   preflight <dir>         the README's pre-install list, each checked or reported unchecked: installed by the OHS
#                           installer (standalone or collocated; an embedded OHS is refused), client now 12.x, RHEL/OL
#                           7.4+, no patches left that are not rolled back or kept (--keep-patches), unzip on PATH,
#                           the installer zip readable and holding the installer, room for the backup; then what
#                           runs from the home and the node manager credentials the stop needs
#   backup <dir>            preflight must be READY; back up the home, its domains and the central inventory into a
#                           new run dir (tar, each read back). There is no uninstaller: this backup is the rollback
#   apply <dir>             preflight READY, nothing running from the home, and a completed backup of this home (the
#                           latest, or --backup-run <run-dir>); unzip, changePerm.sh, the installer (silent), verify.
#                           A failure restores the home and central inventory from that backup and starts them again
#   verify                  read-only: sqlplus -V is 19.14 or later AND oracle.rdbms.rsf is 19.x - two sources
#   run <dir>               backup, stop, apply, start, verify, in that order, in one go
#   rollback [run-dir]      restore the home and central inventory from a run's backup (default: the latest run)
#
# <dir> holds p34761383_122140_Linux-x86-64.zip (or any p34761383_*.zip).
#
# Options
#   --oracle-home DIR       the OHS home; default: $ORACLE_HOME, then the central inventory
#   --domain-home DIR       the domain holding the OHS components; default: every domain in domain-registry.xml
#   --backup-dir DIR        where the backup goes (default /u01/backup)
#   --run-dir DIR           the run dir to write: backup (a composer's one backup, ohs-quarter.sh) and the run
#                           rollback restores from
#   --backup-run DIR        apply: restore from this run's backup (a composer's one backup) instead of the latest
#   --keep-patches ID,ID    patches you have checked are NOT 12c Database Client patches; every other installed
#                           patch must be rolled back first (README). The script cannot check this for you
#   --remove-patches ID,ID  opt in: run rolls these back itself, after the backup and the stop and before the
#                           installer (the README's 12c client patches). Only the ids named; a failure restores
#   --dry-run  --yes
#
# Environment: START_TIMEOUT, POLL, RUN_BASE (default <output dir>/dbclient-upgrade/runs), OS_RELEASE (default
# /etc/os-release, then /etc/redhat-release).
#
# Exit (preflight): 0 ready; 1 a blocking problem; 2 a check could not be completed, so "ready" cannot be said.
# Exit (run, apply): 0 upgraded and verified, or already 19c; 1 refused or failed (restored if anything had
# changed); 3 failed AND the restore failed - the home needs a hand restore from the backup named in the log.
#
# Why each check (34761383 README, "DB Client 19c Upgrade for FMW 12.2.1.4.0", and KB585169):
#   - only OID/OHS/OTD homes installed with their own installer, standalone or collocated - not an OHS embedded in
#     another FMW product -> registry.xml's 'Oracle HTTP Server (Standalone)' / '(Collocated)'; neither is refused
#   - "only supported on Red Hat / Oracle Linux version 7.4 and higher" -> the OS release, unknown if unreadable
#   - "Rollback or remove any 12c DB client related patches before proceeding" -> every installed patch must be
#     rolled back or named in --keep-patches (lspatches carries no descriptions on such a home, so it cannot tell)
#   - "Backup of the ORACLE_HOME and Central Inventory must be taken as there is no mechanism to rollback" -> the
#     backup is taken and read back before anything stops, and a failure restores from it
#   - "All the processes which are using files from ORACLE_HOME must be stopped" -> proved with the process list
#   - "which unzip" -> unzip on PATH
#   - verify: "sqlplus ... Version 19.14.0.0.0" (README) and oracle.rdbms.rsf VER 19.x in comps.xml (KB585169)

set -uo pipefail
# >>> output-location (the same block in lib/oracle-lib.sh and every script that does not source it; tests/output-dir.sh compares them)
# Where a script puts what it creates. ORACLE_OUTPUT_DIR in the environment wins, then OUTPUT_DIR from oracle.conf or ~/.oracle.conf.
# With neither set, a host that already has $HOME/<tool> keeps it, so an upgrade strands no run state, backup or history; a fresh
# host uses /u01/oracle-patch-scripts (macOS: $HOME/oracle-patch-scripts when /u01 cannot be written). The first write creates it.
OUTPUT_SERVER_BASE="${OUTPUT_SERVER_BASE:-/u01/oracle-patch-scripts}"
# shellcheck disable=SC2034
OUTPUT_HINT="set OUTPUT_DIR in oracle.conf, or ORACLE_OUTPUT_DIR, to choose where this goes"
output_configured() {
  [ -n "${ORACLE_OUTPUT_DIR:-}" ] && { printf '%s' "$ORACLE_OUTPUT_DIR"; return 0; }
  local f v="" d; d="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"
  for f in "$d/../../oracle.conf" "$d/../oracle.conf" "$HOME/.oracle.conf"; do
    [ -f "$f" ] && grep -qE '^[[:space:]]*(export[[:space:]]+)?OUTPUT_DIR=' "$f" || continue
    # shellcheck disable=SC1090
    v="$(unset OUTPUT_DIR; . "$f" >/dev/null 2>&1; printf '%s' "${OUTPUT_DIR:-}")"
  done
  printf '%s' "$v"
}
output_writable() { local d="$1"; while [ ! -e "$d" ] && [ "$d" != / ]; do d="$(dirname "$d")"; done; [ -d "$d" ] && [ -w "$d" ]; }
output_default_base() {
  case "${OSTYPE:-$(uname -s | tr 'A-Z' 'a-z')}" in
    darwin*) if output_writable "$OUTPUT_SERVER_BASE"; then printf '%s' "$OUTPUT_SERVER_BASE"; else printf '%s' "$HOME/oracle-patch-scripts"; fi;;
    msys*|cygwin*|win*) printf '%s' "$HOME/oracle-patch-scripts";;
    *) printf '%s' "$OUTPUT_SERVER_BASE";;
  esac
}
OUTPUT_CONFIGURED="$(output_configured)"
case "$OUTPUT_CONFIGURED" in ''|/*) ;; *) printf 'ERROR: OUTPUT_DIR must be an absolute path, got: %s\n' "$OUTPUT_CONFIGURED" >&2; exit 1;; esac
output_path() { # <tool>: the folder for that tool. Prints it, creates nothing.
  if [ -n "$OUTPUT_CONFIGURED" ]; then printf '%s/%s' "${OUTPUT_CONFIGURED%/}" "$1"
  elif [ -d "$HOME/$1" ]; then printf '%s/%s' "$HOME" "$1"
  else printf '%s/%s' "$(output_default_base)" "$1"; fi
}
# <<< output-location

ORACLE_HOME_ARG=""; DOMAIN_ARG=""; BACKUP_DIR="/u01/backup"; RUN_DIR_ARG=""; BACKUP_RUN=""; KEEP_PATCHES=""; REMOVE_PATCHES=""; REMOVE_IDS=""
DRY_RUN=0; ASSUME_YES=0
START_TIMEOUT="${START_TIMEOUT:-300}"; POLL="${POLL:-10}"; RUN_BASE="${RUN_BASE:-$(output_path dbclient-upgrade)/runs}"
OS_RELEASE="${OS_RELEASE:-}"
problems=0; unknowns=0
OH=""; DOMS=""; INV=""; COMPS=""; PRE_IDS=""; PRE_RSF=""; ZIP=""
RUN_DIR=""; STATE=""; BK=""; STAMP=""
NARR=""; STOP_FAILED=""; FAILED_HOME=""
MIN_SQLPLUS="19.14.0.0.0"

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }
ts()   { date '+%Y-%m-%d %H:%M:%S'; }

say()  { local l; l="$(printf '%s [%s] %s' "$(ts)" "$1" "$2")"; printf '%s\n' "$l" >&2
  if [ -n "${RUN_DIR:-}" ] && [ -d "$RUN_DIR" ]; then printf '%s\n' "$l" >>"$RUN_DIR/dbclient-upgrade.log"; else NARR="$NARR$l"$'\n'; fi; }
log()  { say 'INFO ' "$*"; }
warn() { say 'WARN ' "$*"; }
err()  { say 'ERROR' "$*"; }
die()  { err "$*"; exit 2; }
block()   { err "BLOCKING: $*"; problems=$((problems + 1)); }
unknown() { err "UNKNOWN: $*"; unknowns=$((unknowns + 1)); }
optchk() { [ $# -ge 2 ] || die "$1 needs a value"; case "$2" in -[!0-9]*) die "$1 needs a value, got '$2'";; esac; }

# A run outlives the terminal it was started from (the same rule as lib/oracle-lib.sh; this script sources no lib,
# so it carries its own copy - tests/self-contained-gate.sh fails if a lib-only function is called and not defined
# here). HUP is ignored for the rest of the run, so a lost ssh or a closed lid does not stop it between steps and
# never mid-step; and a run started from an INTERACTIVE shell must be detached first, or it is refused.
require_detached() {
  local what="${1:-run}" tool
  tool="$(basename "${BASH_SOURCE[0]}" .sh)"
  trap '' HUP
  [ "$DRY_RUN" = 1 ] && return 0
  [ -n "${TMUX:-}" ] && return 0
  [ -n "${STY:-}" ] && return 0
  [ "${PATCH_DETACHED:-}" = 1 ] && return 0
  { [ -t 0 ] || [ "${PATCH_INTERACTIVE:-}" = 1 ]; } || return 0
  die "$tool $what changes this host, and a dropped session would stop it (a lost
  ssh, a closed laptop lid). Start it detached and it will run to its next safe point whatever happens:
    tmux new -s $tool        # run the same command inside, then Ctrl-b d to detach
    nohup $0 $what ... >/tmp/$tool.out 2>&1 &    # then: tail -f /tmp/$tool.out
  Refusing rather than risking a stop mid-step. PATCH_DETACHED=1 overrides if you know the session survives."
}

# 1.2.3 >= 1.2 ; numeric, dot by dot
version_ge() {
  local IFS=. i a b
  read -r -a a <<<"$1"; read -r -a b <<<"$2"
  for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
    [ "${a[i]:-0}" -gt "${b[i]:-0}" ] 2>/dev/null && return 0
    [ "${a[i]:-0}" -lt "${b[i]:-0}" ] 2>/dev/null && return 1
  done
  return 0
}

# ---- discovery ------------------------------------------------------------------------------------------
find_home() {
  if [ -n "$ORACLE_HOME_ARG" ]; then printf '%s' "$ORACLE_HOME_ARG"; return; fi
  if [ -n "${ORACLE_HOME:-}" ] && [ -d "$ORACLE_HOME/ohs" ]; then printf '%s' "$ORACLE_HOME"; return; fi
  local inv d h
  for inv in ${ORAINST_LOC:-/etc/oraInst.loc /var/opt/oracle/oraInst.loc}; do
    [ -f "$inv" ] || continue
    d="$(sed -n 's/^inventory_loc=//p' "$inv")"
    for h in $(sed -n '/REMOVED="T"/d; s/.*<HOME NAME="[^"]*" LOC="\([^"]*\)".*/\1/p' "$d/ContentsXML/inventory.xml" 2>/dev/null); do
      [ -d "$h/ohs" ] && { printf '%s' "$h"; return; }
    done
  done
}

ohs_release() {
  sed -n 's/.*name="Oracle HTTP Server[^"]*"[^>]*version="\([0-9.]*\)".*/\1/p' "$1/inventory/registry.xml" 2>/dev/null | head -1
}

domains_of() { # every domain this home knows; --domain-home wins
  if [ -n "$DOMAIN_ARG" ]; then printf '%s\n' "$DOMAIN_ARG"; return; fi
  sed -n 's/.*<domain location="\([^"]*\)".*/\1/p' "$1/domain-registry.xml" 2>/dev/null
}

# OHS component names in a domain's config.xml: <system-component> blocks whose <component-type> is OHS
ohs_components() {
  awk '
    /<system-component>/ {inb=1; n=""; t=""}
    inb && match($0, /<name>[^<]*<\/name>/) && n == "" {n = substr($0, RSTART + 6, RLENGTH - 13)}
    inb && match($0, /<component-type>[^<]*<\/component-type>/) {t = substr($0, RSTART + 16, RLENGTH - 33)}
    inb && /<\/system-component>/ {inb = 0; if (t == "OHS" && n != "") print n}
  ' "$1/config/config.xml"
}

domain_name() { sed -n 's/.*<name>\([^<]*\)<\/name>.*/\1/p' "$1/config/config.xml" 2>/dev/null | head -1; }

# the Listen ports of one OHS instance (httpd.conf + ssl.conf), for the after-start check
instance_ports() {
  local d="$1/config/fmwconfig/components/OHS/instances/$2"
  cat "$d/httpd.conf" "$d/ssl.conf" 2>/dev/null | sed -n 's/^[[:space:]]*Listen[[:space:]]\{1,\}\([^[:space:]#]*\).*/\1/p' | sed 's/.*://' | sort -un | tr '\n' ' '
}

# every process with an argument that is the home or a path under it (also after '=' or ':', as in -cp a:b or
# -Dx=path); a sibling such as <home>2 is not the home. Status 1 = ps could not be read (never 'nothing running').
# Fail-closed by design: any process holding a path in the home is listed, a 'tail -f' on its log included.
# this shell ($$) and every ancestor of it, space-padded so awk can match a whole pid. A caller that runs
# this script holds the home in its args and must not be listed as an occupant (T1529); the old name-match
# skipped only the script's own name, so a wrapper (ohs-quarter.sh, sudo, screen, bash -c) was listed.
# An unreadable ppid walk returns blank, so nothing is dropped (fail-closed).
ancestor_pids() {
  local pid="$$" out=" $$ " ppid
  while [ "$pid" -gt 1 ]; do
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    case "$ppid" in ''|*[!0-9]*) break;; esac
    out="$out$ppid "
    [ "$ppid" -le 1 ] && break
    pid="$ppid"
  done
  printf '%s\n' "$out"
}

from_home() {
  local l anc
  l="$(ps -eo pid,args 2>/dev/null)" && [ -n "$(printf '%s' "$l" | tr -d '[:space:]')" ] || return 1
  anc="$(ancestor_pids)"
  printf '%s\n' "$l" | awk -v oh="$1" -v anc="$anc" '
    { pid=$1; if (index(anc, " " pid " ") > 0) next }
    { n = split($0, f, /[[:space:]=:]+/)
      for (i = 2; i <= n; i++) if (f[i] == oh || index(f[i], oh "/") == 1) { print; next } }'
}

kind_of_proc() {
  case "$1" in
    *weblogic.NodeManager*) echo "node manager" ;;
    *weblogic.Server*) echo "WebLogic server $(printf '%s' "$1" | sed -n 's/.*-Dweblogic\.Name=\([^ ]*\).*/\1/p')" ;;
    */ohs/bin/*) echo "OHS $(printf '%s' "$1" | sed -n 's#.*/OHS/instances/\([^/ ]*\).*#\1#p' | head -1)" ;;
    *) echo "other" ;;
  esac
}

# the Database Client level in the home: oracle.rdbms.rsf's VER in the home's inventory (the check KB585169 gives);
# empty when it cannot be read. A DB19C bundle needs 19.x - the upgrade is patch 34761383, an installer, not opatch
rsf_version() {
  grep -o '<COMP [^>]*NAME="oracle\.rdbms\.rsf"[^>]*>' "$1/inventory/ContentsXML/comps.xml" 2>/dev/null | head -1 | sed -n 's/.* VER="\([^"]*\)".*/\1/p'
}

state() { [ -n "$STATE" ] && printf '%s=%s\n' "$1" "$2" >>"$STATE"; return 0; }

# a command, logged with its output to the run log; its exit status is returned
# under --dry-run it only says so: no caller has to remember to return before it
# stdin is /dev/null: the output goes to run.log, so a child that prompts (a node manager password) would wait on a
# question nobody can see; with no stdin it fails at once and takes the caller's failure path
# The output goes STRAIGHT to the file, not through a filter: a pipe is held open by anything the command leaves
# running, and this runs the stop/start scripts in an outage window - a start that never returns is worse than a
# log line. run.log is owner-only in an owner-only dir (private_log below); that is its protection.
do_cmd() { if [ "$DRY_RUN" = 1 ]; then log "dry-run: would run $*"; return 0; fi; log "  \$ $*"; private_log || return 1; "$@" >>"$RUN_DIR/run.log" 2>&1 </dev/null; }
# the run dir and its command log, owner-only, wherever RUN_DIR came from (open_run, open_log, or a run re-used by
# apply/rollback that an older copy of this script left 755/644). A failure stops the command: nothing is logged
# into a file others can read.
private_log() {
  chmod 700 "$RUN_DIR" 2>/dev/null && ( umask 077; : >>"$RUN_DIR/run.log" ) && chmod 600 "$RUN_DIR/run.log" 2>/dev/null && return 0
  err "cannot make $RUN_DIR and its run.log owner-only (chmod failed) - the command was not run"; return 1
}
# T195: a private-umask wrapper for CREATING the archives only - the rest of the script (tar -x on
# rollback, opatch, unzip, the installer) must keep the host/oracle umask, or the home comes back 0700/0600.
do_cmd_p() { local u; u="$(umask)"; umask 077; do_cmd "$@"; local r=$?; umask "$u"; return $r; }

# after a failed stop/start: the child's last lines from run.log, and the remedy when they read like a credentials prompt
why_failed() {
  local d="$1" c="$2" tailtxt; tailtxt="$(tail -3 "$RUN_DIR/run.log" 2>/dev/null)"
  [ -n "$tailtxt" ] && printf '%s\n' "$tailtxt" | sed 's/^/    /' >&2
  if printf '%s' "$tailtxt" | grep -qiE 'password|user ?name|credential'; then
    err "  it asked for the node manager credentials: none are stored for this user ($(id -un 2>/dev/null), HOME $HOME), or they are stale. With the node manager up, as this user, run once: $d/bin/startComponent.sh ${c:-<component>} storeUserConfig"
  fi
}

installed_ids() { # 'id id ...' sorted; status 1 = lspatches could not be read
  local o; o="$(ORACLE_HOME="$OH" "$OH/OPatch/opatch" lspatches 2>/dev/null)" || return 1
  printf '%s\n' "$o" | tr -d '\r' | { grep -E '^[0-9]+;' || true; } | cut -d';' -f1 | sort -u | tr '\n' ' '
}

confirm() {
  [ "$ASSUME_YES" = 1 ] || [ "$DRY_RUN" = 1 ] && return 0
  [ -t 0 ] || { err "$1 - not confirmed (no terminal; pass --yes)"; return 1; }
  local a; read -r -p "$1 Type yes to go on: " a; [ "$a" = yes ]
}

stop_all() {
  local d c r rc=0; STOP_FAILED=""
  while IFS='|' read -r d c; do [ -n "$c" ] || continue
    if do_cmd "$d/bin/stopComponent.sh" "$c"; then [ "$DRY_RUN" = 1 ] || log "  stopped $c"
    else r=$?; err "stopComponent.sh $c failed (rc $r) - see $RUN_DIR/run.log"; why_failed "$d" "$c"; rc=1; STOP_FAILED="${STOP_FAILED}stopComponent.sh $c returned $r; "; fi
  done <<<"$COMPS"
  while IFS= read -r d; do [ -n "$d" ] || continue
    if do_cmd "$d/bin/stopNodeManager.sh"; then [ "$DRY_RUN" = 1 ] || log "  stopped node manager for $(domain_name "$d")"
    else r=$?; err "stopNodeManager.sh for $d failed (rc $r) - see $RUN_DIR/run.log"; why_failed "$d" ""; rc=1; STOP_FAILED="${STOP_FAILED}stopNodeManager.sh for $(domain_name "$d") returned $r; "; fi
  done <<<"$DOMS"
  return $rc
}

# after stop_all: the proof decides. 0 = nothing runs from the home (a non-zero stop is then a warning naming it);
# 1 = something still runs; 2 = ps unreadable (fail closed)
stopped_proved() {
  local nr; nothing_running; nr=$?
  [ "$nr" = 0 ] && [ -n "$STOP_FAILED" ] && warn "${STOP_FAILED}but nothing runs from $OH, so the home is clear - carrying on (a stop with nothing to stop, e.g. node manager already down)"
  return "$nr"
}

# node manager, then every component (retried until START_TIMEOUT: startComponent fails until node manager listens),
# then every Listen port answers HTTP. 0 = all up.
start_all() {
  local d c t rc=0 havecurl=1
  # no curl on the host: the ports cannot be checked, so they are not - a missing tool must never roll back a good apply
  command -v curl >/dev/null || { havecurl=0; warn "curl not available - skipping the port check; startComponent.sh's own status is the only start check"; }
  while IFS= read -r d; do [ -n "$d" ] || continue
    if [ "$DRY_RUN" = 1 ]; then log "dry-run: would run nohup $d/bin/startNodeManager.sh &"; continue; fi
    log "  \$ nohup $d/bin/startNodeManager.sh &"
    nohup "$d/bin/startNodeManager.sh" >>"$RUN_DIR/nodemanager-$(basename "$d").out" 2>&1 </dev/null &
  done <<<"$DOMS"
  while IFS='|' read -r d c; do [ -n "$c" ] || continue
    t=0; until do_cmd "$d/bin/startComponent.sh" "$c"; do
      t=$((t + POLL)); [ "$t" -le "$START_TIMEOUT" ] || { err "startComponent.sh $c did not succeed in ${START_TIMEOUT}s - see $RUN_DIR/run.log"; why_failed "$d" "$c"; rc=1; continue 2; }
      sleep "$POLL"
    done
    [ "$DRY_RUN" = 1 ] || log "  started $c"
    [ "$havecurl" = 1 ] || continue
    [ "$DRY_RUN" = 1 ] && continue
    ports_answer "$d" "$c" "$START_TIMEOUT" || rc=1
  done <<<"$COMPS"
  return $rc
}

# every Listen port of one component answers HTTP(S) within <wait> seconds; 0 = all answer
ports_answer() {
  local d="$1" c="$2" wait="$3" p t code rc=0
  for p in $(instance_ports "$d" "$c"); do
    t=0; while :; do
      code="$(curl -k -s -o /dev/null -m 10 -w '%{http_code}' "https://localhost:$p/" 2>/dev/null)"
      case "$code" in ''|000) code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://localhost:$p/" 2>/dev/null)";; esac
      case "$code" in ''|000) ;; *) log "  $c answers on port $p (HTTP $code)"; break;; esac
      t=$((t + POLL)); [ "$t" -le "$wait" ] || { err "$c does not answer on port $p after ${wait}s"; rc=1; break; }
      sleep "$POLL"
    done
  done
  return $rc
}

# 0 = nothing runs from the home; 1 = something does (listed); 2 = ps unreadable
nothing_running() {
  local procs; procs="$(from_home "$OH")" || { err "cannot read the process list - cannot prove the home is stopped"; return 2; }
  [ -z "$procs" ] && { log "  confirmed: nothing runs from $OH (0 processes name the home)"; return 0; }
  while read -r pid args; do [ -n "$pid" ] && err "  still running from $OH: pid $pid  $(kind_of_proc "$args")"; done <<<"$procs"
  return 1
}

backup_all() { # into BK; every archive listed back (tar -tzf) and non-empty; all or nothing
  local d f
  ( umask 077; mkdir -p "$BK" ) || { err "cannot create $BK"; return 1; }
  chmod 700 "$BK" 2>/dev/null || { err "cannot make backup dir $BK private (chmod 700 failed) - refusing to write a readable backup"; return 1; }
  do_cmd_p tar -C "$(dirname "$OH")" -czf "$BK/home.tgz" "$(basename "$OH")" || { err "home backup failed"; return 1; }
  while IFS= read -r d; do [ -n "$d" ] || continue
    do_cmd_p tar -C "$(dirname "$d")" --exclude='*/logs/*' --exclude='*/tmp/*' -czf "$BK/domain-$(basename "$d").tgz" "$(basename "$d")" || { err "domain backup of $d failed"; return 1; }
  done <<<"$DOMS"
  if [ -n "$INV" ]; then do_cmd_p tar -C "$(dirname "$INV")" -czf "$BK/oraInventory.tgz" "$(basename "$INV")" || { err "central inventory backup failed"; return 1; }
  else err "no central inventory location (oraInst.loc) - the README's rollback needs it backed up"; return 1; fi
  for f in "$BK"/*.tgz; do
    chmod 600 "$f" 2>/dev/null || { err "cannot make $f private (chmod 600 failed)"; return 1; }
    [ -s "$f" ] && tar -tzf "$f" >/dev/null 2>&1 || { err "backup $f does not read back - not a usable rollback"; return 1; }
  done
  return 0
}

# the README's complete rollback: ORACLE_HOME and the central inventory from THIS run's backup ($BK).
# 0 = restored and lspatches is back at the level recorded before the apply; 1 = not (the home is left stopped)
restore_all() {
  local stamp; stamp="$(date '+%Y%m%d-%H%M%S')"
  [ -s "$BK/home.tgz" ] && [ -s "$BK/oraInventory.tgz" ] || { err "this run's backup is not complete in $BK"; return 1; }
  stop_all || :
  nothing_running || { err "the home is not stopped - not restoring under a live process"; return 1; }
  do_cmd mv "$OH" "$OH.failed-$stamp" || { err "cannot move $OH aside"; return 1; }
  FAILED_HOME="$OH.failed-$stamp"
  do_cmd tar -C "$(dirname "$OH")" -xzf "$BK/home.tgz" || { err "restore of $OH from $BK/home.tgz failed (the patched home is at $OH.failed-$stamp)"; return 1; }
  do_cmd mv "$INV" "$INV.failed-$stamp" || { err "cannot move $INV aside"; return 1; }
  do_cmd tar -C "$(dirname "$INV")" -xzf "$BK/oraInventory.tgz" || { err "restore of $INV from $BK/oraInventory.tgz failed"; return 1; }
  local now; now="$(installed_ids)" || { err "lspatches cannot be read on the restored home"; return 1; }
  [ "$now" = "$PRE_IDS" ] || { err "the restored home's patches [$now] are not the level before the apply [$PRE_IDS]"; return 1; }
  log "restored $OH and $INV from $BK; patches back at [$now]. The domain archives in $BK were not needed."
  return 0
}

where_logs() {
  err "LOGS: this script's narration $RUN_DIR/dbclient-upgrade.log; the commands' own output $RUN_DIR/run.log (and nodemanager-*.out beside it)"
  if [ -n "$FAILED_HOME" ]; then err "      opatch's own log of the failed apply: $FAILED_HOME/cfgtoollogs/opatch/ (the home was renamed by the rollback)"
  else err "      opatch's own log: $OH/cfgtoollogs/opatch/"; fi
}

manual_restore() {
  err "MANUAL RESTORE (the servers are DOWN):"
  err "  mv '$OH' '$OH.bad' && tar -C '$(dirname "$OH")' -xzf '$BK/home.tgz'"
  err "  mv '$INV' '$INV.bad' && tar -C '$(dirname "$INV")' -xzf '$BK/oraInventory.tgz'"
  err "  then start node manager and the components (see 'preflight' for the commands)"
}

# ---- what this script adds -------------------------------------------------------------------------------
# how the home was installed: the OHS installer writes its product into registry.xml as a <distribution>.
# standalone / collocated are in KB585169's scope; anything else is an OHS embedded in another FMW product, which is
# not; no readable registry.xml is unknown. Never guessed from a wlserver/ directory (Gen's standalone home has one).
# A field 12.2.1.4 standalone home (12 Nov 2026) names its distribution plain "Oracle HTTP Server", next to
# "OPatch" only - the "(Standalone)" / "(Collocated)" labels are not what every installer writes. So a plain
# "Oracle HTTP Server" distribution is the OHS installer's: collocated when the home also carries the
# Infrastructure / WebLogic Server distribution it was installed into, standalone when the only other one is OPatch,
# embedded when any other product's distribution is there too.
scope_of() {
  local reg="$1/inventory/registry.xml" names n other="" infra=""
  [ -r "$reg" ] || { echo unknown; return; }
  if grep -q 'name="Oracle HTTP Server (Standalone)"' "$reg"; then echo standalone; return; fi
  if grep -q 'name="Oracle HTTP Server (Collocated)"' "$reg"; then echo collocated; return; fi
  names="$(reg_names "$1")"
  printf '%s\n' "$names" | grep -qx 'Oracle HTTP Server' || { echo embedded; return; }
  while IFS= read -r n; do
    case "$n" in
      ''|'Oracle HTTP Server'|OPatch) ;;
      'Fusion Middleware Infrastructure'|'Oracle Fusion Middleware Infrastructure'|'WebLogic Server') infra=1 ;;
      *) other=1 ;;
    esac
  done <<EOF
$names
EOF
  if [ -n "$other" ]; then echo embedded
  elif [ -n "$infra" ]; then echo collocated
  else echo standalone; fi
}

# every installed <distribution> name in registry.xml, one per line, in file order, deduplicated. The file is read
# whole, so two tags on one line and a tag whose attributes wrap are both seen; a status other than "installed"
# (deinstalled) is not a product of this home. scope_of decides on these names, so each of those shapes matters.
reg_names() {
  awk '{ s = s " " $0 } END {
    while (match(s, /<distribution[ \t][^>]*>/)) {
      tag = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
      if (match(tag, /[ \t]status="[^"]*"/) && substr(tag, RSTART, RLENGTH) !~ /"installed"$/) continue
      if (!match(tag, /[ \t]name="[^"]*"/)) continue
      nm = substr(tag, RSTART + 7, RLENGTH - 8)
      if (!(nm in seen)) { seen[nm] = 1; print nm }
    }
  }' "$1/inventory/registry.xml" 2>/dev/null
}

# the products registry.xml does name, so a refusal shows what is there: at most 8, then a count
reg_products() {
  reg_names "$1" | awk 'NR <= 8 { out = out (NR > 1 ? "; " : "") $0 } END {
    if (NR == 0) out = "no installed <distribution> entries"; else if (NR > 8) out = out "; ... (" (NR - 8) " more)"
    printf "%s", out }'
}

# 'ok <what>' / 'block <what>' / 'unknown <why>': RHEL or Oracle Linux 7.4 or later (the README's only OS)
os_check() {
  local f="$OS_RELEASE" id ver name
  if [ -z "$f" ]; then for f in /etc/os-release /etc/redhat-release ""; do [ -r "$f" ] && break; done; fi
  [ -n "$f" ] && [ -r "$f" ] || { echo "unknown no /etc/os-release or /etc/redhat-release to read"; return; }
  if grep -q '^ID=' "$f"; then
    id="$(sed -n 's/^ID="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$f" | head -1)"
    ver="$(sed -n 's/^VERSION_ID="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$f" | head -1)"
    name="$(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$f" | head -1)"
  else
    name="$(head -1 "$f")"; ver="$(printf '%s' "$name" | sed -n 's/.*release \([0-9][0-9.]*\).*/\1/p')"
    case "$name" in *"Red Hat"*) id=rhel;; *Oracle*) id=ol;; *) id="";; esac
  fi
  [ -n "$ver" ] || { echo "unknown no version in $f"; return; }
  case "$id" in
    rhel|ol) if version_ge "$ver" 7.4; then echo "ok ${name:-$id $ver}"; else echo "block ${name:-$id $ver} is older than 7.4"; fi ;;
    *) echo "block ${name:-$id $ver} is not Red Hat or Oracle Linux" ;;
  esac
}

# the installer's version as sqlplus reports it ('Version 19.14.0.0.0'); empty when it cannot be read
sqlplus_version() {
  [ -x "$1/bin/sqlplus" ] || return 0
  ORACLE_HOME="$1" "$1/bin/sqlplus" -V </dev/null 2>/dev/null | tr -d '\r' | sed -n 's/^Version \([0-9][0-9.]*\).*/\1/p' | head -1
}

find_zip() { local z; for z in "$1"/p34761383_*.zip; do [ -f "$z" ] && { printf '%s' "$z"; return; }; done; }

in_keep() { case ",$KEEP_PATCHES," in *",$1,"*) return 0;; esac; return 1; }
in_remove() { case ",$REMOVE_PATCHES," in *",$1,"*) return 0;; esac; return 1; }

# the home, its domains, the OHS components and the central inventory
discover() {
  OH="$(find_home)"
  [ -n "$OH" ] || die "no Oracle HTTP Server home found (no ohs/ under \$ORACLE_HOME or any inventory home) - pass --oracle-home"
  INV="$(sed -n 's/^inventory_loc=//p' "$OH/oraInst.loc" /etc/oraInst.loc 2>/dev/null | head -1)"
  local d c; DOMS="$(domains_of "$OH")"; COMPS=""
  while IFS= read -r d; do [ -n "$d" ] || continue; for c in $(ohs_components "$d"); do COMPS="$COMPS$d|$c"$'\n'; done; done <<<"$DOMS"
}

cmd_inspect() {
  discover
  local sc rv sv os ids
  sc="$(scope_of "$OH")"; rv="$(rsf_version "$OH")"; sv="$(sqlplus_version "$OH")"; os="$(os_check)"
  log "home      : $OH (installed as: $sc)"
  log "DB client : oracle.rdbms.rsf ${rv:-unknown}; sqlplus -V ${sv:-unreadable}"
  log "OS        : ${os#* } (${os%% *})"
  if ids="$(installed_ids)"; then log "patches   : ${ids:-none}"; else log "patches   : lspatches failed"; fi
  log "domains   : $(printf '%s ' $DOMS)"
  log "components: $(printf '%s\n' "$COMPS" | cut -d'|' -f2 | tr '\n' ' ')"
  return 0
}

ALREADY=0
cmd_preflight() {
  local dir="${1:-}"
  [ -n "$dir" ] || die "preflight needs <dir> (the folder holding p34761383_*.zip)"
  [ -d "$dir" ] || die "dir $dir does not exist"
  discover
  [ -d "$OH/ohs" ] || block "$OH has no ohs/ directory - it is not an OHS home"
  log "home      : $OH"

  # scope (KB585169): installed by the OHS installer, standalone or collocated
  case "$(scope_of "$OH")" in
    standalone) log "scope     : standalone OHS (registry.xml: $(reg_products "$OH")) - in KB585169's scope" ;;
    collocated) log "scope     : collocated OHS (registry.xml: $(reg_products "$OH")) - in KB585169's scope" ;;
    embedded) block "registry.xml in $OH has no OHS installer distribution ('Oracle HTTP Server', '(Standalone)' or '(Collocated)') on its own: an OHS embedded in another FMW product, or a home not installed by the OHS installer - KB585169 puts it out of scope. registry.xml names: $(reg_products "$OH")" ;;
    *) unknown "cannot read $OH/inventory/registry.xml - how the home was installed (KB585169's scope) is unknown" ;;
  esac

  # the client level: 12.x to upgrade, 19.x already done
  PRE_RSF="$(rsf_version "$OH")"
  local sv; sv="$(sqlplus_version "$OH")"
  case "$PRE_RSF" in
    12.*) log "DB client : oracle.rdbms.rsf $PRE_RSF (12c; sqlplus -V ${sv:-unreadable}) - to be upgraded to 19c" ;;
    19.*) log "DB client : oracle.rdbms.rsf $PRE_RSF (sqlplus -V ${sv:-unreadable}) - already 19c, nothing to do"; ALREADY=1 ;;
    "") unknown "no oracle.rdbms.rsf in $OH/inventory/ContentsXML/comps.xml - the client level is unknown" ;;
    *) block "oracle.rdbms.rsf is $PRE_RSF - neither 12c to upgrade nor 19c" ;;
  esac
  [ "$ALREADY" = 1 ] && { echo >&2; log "READY: nothing to do - $OH already has the Database Client 19c."; return 0; }

  # OS (README: RHEL / OL 7.4 and higher only)
  local os; os="$(os_check)"
  case "$os" in
    ok\ *) log "OS        : ${os#ok }" ;;
    block\ *) block "OS ${os#block } - the README supports the upgrade only on Red Hat / Oracle Linux 7.4 and higher" ;;
    *) unknown "OS release unchecked: ${os#unknown } - the README needs Red Hat / Oracle Linux 7.4 or higher" ;;
  esac

  # patches (README: roll back or remove any 12c DB client related patches first). lspatches gives bare ids on such
  # a home, so the script cannot tell which are client patches: each must be rolled back or kept by the operator
  local id left=""
  if PRE_IDS="$(installed_ids)"; then
    REMOVE_IDS=""
    for id in $PRE_IDS; do
      if in_keep "$id" && in_remove "$id"; then block "patch $id is named in both --keep-patches and --remove-patches"
      elif in_keep "$id"; then log "patch     : $id kept (--keep-patches: you checked it is not a 12c Database Client patch)"
      elif in_remove "$id"; then log "patch     : $id to be rolled back (--remove-patches), after the backup and the stop, before the installer"; REMOVE_IDS="$REMOVE_IDS $id"
      else left="$left $id"; fi
    done
    for id in $(printf '%s' "$REMOVE_PATCHES" | tr ',' ' '); do
      case " $PRE_IDS " in *" $id "*) ;; *) log "patch     : $id (--remove-patches) is not installed - nothing to roll back" ;; esac
    done
    if [ -n "$left" ]; then
      block "patches installed in $OH that are neither rolled back nor kept:$left. The README: 'Rollback or remove any 12c DB client related patches before proceeding'. This script cannot tell which are client patches (lspatches gives no descriptions); for each, either roll it back:"
      for id in $left; do err "    cd /tmp && ORACLE_HOME='$OH' '$OH/OPatch/opatch' rollback -id $id -silent -oh '$OH'"; done
      err "  or, once you have checked it is NOT a 12c Database Client patch, pass --keep-patches $(printf '%s' "$left" | sed 's/^ //; s/ /,/g'). The script takes that on your word."
    else log "patches   : ${PRE_IDS:-none} - nothing left to roll back"; fi
  else unknown "opatch lspatches failed - the installed patches are unknown"; fi

  # the installer
  command -v unzip >/dev/null 2>&1 && log "unzip     : $(command -v unzip)" || block "unzip is not on PATH - the README's install unzips the patch"
  ZIP="$(find_zip "$dir")"
  if [ -z "$ZIP" ]; then block "no p34761383_*.zip in $dir"
  else
    local lst; if lst="$(unzip -l "$ZIP" 2>/dev/null)"; then
      printf '%s' "$lst" | grep -qE '(^|[ /])fmw_12\.2\.1\.19\.0_dbclient_linux64\.bin$' && printf '%s' "$lst" | grep -qE '(^|[ /])changePerm\.sh$' \
        && log "installer : $ZIP (fmw_12.2.1.19.0_dbclient_linux64.bin, changePerm.sh)" \
        || block "$ZIP does not hold fmw_12.2.1.19.0_dbclient_linux64.bin and changePerm.sh"
    else block "$ZIP cannot be read by unzip -l"; fi
  fi

  # the backup: the only rollback
  [ -n "$INV" ] && [ -d "$INV" ] || block "no central inventory (inventory_loc in $OH/oraInst.loc) - the README's rollback restores it"
  if [ -d "$BACKUP_DIR" ] && [ -w "$BACKUP_DIR" ]; then
    local need free; need="$(du -sk "$OH" ${INV:+"$INV"} 2>/dev/null | awk '{s+=$1} END {print int(s/1024)}')"; free="$(df -Pk "$BACKUP_DIR" 2>/dev/null | awk 'NR==2 {print int($4/1024)}')"
    if [ -n "$need" ] && [ -n "$free" ]; then
      [ "$free" -gt "$need" ] && log "backup    : $need MB needed, $free MB free on $BACKUP_DIR" || block "backup needs $need MB, $BACKUP_DIR has $free MB free"
    else unknown "cannot measure the backup size or the free space on $BACKUP_DIR"; fi
  else block "backup dir $BACKUP_DIR is missing or not writable"; fi

  # the stop: node manager credentials (the component scripts prompt without them), and what runs now
  local d dn
  [ -n "$COMPS" ] || warn "no OHS component found in $(printf '%s ' $DOMS)- only node manager will be stopped"
  while IFS= read -r d; do [ -n "$d" ] || continue; dn="$(domain_name "$d")"
    if [ -f "$HOME/.wlst/nm-cfg-$dn.props" ] && [ -f "$HOME/.wlst/nm-key-$dn.props" ]; then log "NM creds  : stored for $dn ($HOME/.wlst/nm-cfg-$dn.props, as $(id -un 2>/dev/null))"
    else block "no stored node manager credentials for $dn: stopComponent.sh would prompt mid-outage - with node manager up, as this user, run once: $d/bin/startComponent.sh <component> storeUserConfig"; fi
  done <<<"$DOMS"
  local procs; if procs="$(from_home "$OH")"; then
    if [ -n "$procs" ]; then log "running from $OH (all are stopped before the installer):"; while read -r p a; do [ -n "$p" ] && log "  pid $p  $(kind_of_proc "$a")"; done <<<"$procs"
    else log "running   : nothing from $OH"; fi
  else unknown "cannot read the process list"; fi

  echo >&2
  if [ "$unknowns" -gt 0 ]; then err "preflight could not complete: $unknowns check(s) unreadable, $problems blocking - NOT ready"; return 2; fi
  if [ "$problems" -gt 0 ]; then err "$problems blocking problem(s) - NOT ready"; return 1; fi
  log "READY: nothing blocking. 'run' backs up, stops, installs, verifies and starts; there is no uninstaller - the backup is the rollback."
  return 0
}

# preflight READY, a WebLogic server is not running from the home, the backup dir; sets STAMP, BK. Exits on no.
run_gate() {
  local what="$1" dir="${2:-}" prc
  [ -n "$dir" ] || die "$what needs <dir> (the folder holding p34761383_*.zip)"
  cmd_preflight "$dir"; prc=$?
  [ "$prc" = 0 ] || { err "$what refused: preflight is not READY (exit $prc) - nothing was changed"; exit "$prc"; }
  [ "$ALREADY" = 1 ] && exit 0
  no_weblogic "$what"
  STAMP="$(date '+%Y%m%d-%H%M%S')"; BK="$BACKUP_DIR/dbclient-$STAMP"
}

no_weblogic() {
  local procs; procs="$(from_home "$OH")" || { err "cannot read the process list - refused"; exit 2; }
  if printf '%s\n' "$procs" | grep -q 'weblogic\.Server'; then
    err "$1 refused: WebLogic servers run from $OH - stop them first (wls-patch.sh stop); this script stops only OHS and node manager. Nothing was changed."
    exit 1
  fi
}

open_run() {
  # --run-dir was parsed for EVERY command (:746) and read only by rollback (:720), so a caller that asked for a
  # shared run dir - the composer's one-backup phase, ohs-quarter.sh dshared/oshared - got its backup written to
  # $RUN_BASE/<stamp>-run instead, and the later apply --backup-run $SHARED refused with "has no state" (T291).
  RUN_DIR="${RUN_DIR_ARG:-$RUN_BASE/$STAMP-run}"; ( umask 077; mkdir -p "$RUN_DIR" ) || die "cannot create run dir $RUN_DIR: $OUTPUT_HINT"
  chmod 700 "$RUN_DIR" 2>/dev/null || die "cannot make run dir $RUN_DIR private (chmod 700 failed)"
  ( umask 077; : >>"$RUN_DIR/run.log" ); chmod 600 "$RUN_DIR/run.log" 2>/dev/null || die "cannot make $RUN_DIR/run.log private (chmod 600 failed)"
  STATE="$RUN_DIR/state"; : >"$STATE"; printf '%s' "$NARR" >"$RUN_DIR/dbclient-upgrade.log"; NARR=""
  state oracle_home "$OH"; state inventory "$INV"; state backup_dir "$BK"; state pre_patches "$PRE_IDS"; state pre_rsf "$PRE_RSF"
  log "run dir   : $RUN_DIR"
}

step_backup() {
  state stage backup
  log "1/5 backup to $BK (the only rollback: the installer has none)"
  backup_all || { rm -rf "$BK"; state outcome refused-backup; err "backup failed - nothing was stopped or changed"; exit 1; }
  state backup ok
}

step_stop() {
  state stage stop
  log "2/5 stop OHS components and node manager"
  local nr; stop_all; stopped_proved; nr=$?
  if [ "$nr" != 0 ]; then
    state outcome refused-stop
    err "the home could not be proved stopped - NOT installing; starting the components again"
    start_all || err "and they did not all start again - check them by hand"
    where_logs
    exit "$([ "$nr" = 2 ] && echo 2 || echo 1)"
  fi
}

# unzip into the run dir, changePerm.sh on the home, the installer (silent); any failure restores from the backup
step_install() {
  state stage install
  local pt="$RUN_DIR/patch_top" bin
  log "3/5 install the Database Client 19c into $OH (34761383)"
  local id now
  for id in $REMOVE_IDS; do
    log "  rolling back $id first (--remove-patches)"
    ( cd /tmp && do_cmd env ORACLE_HOME="$OH" "$OH/OPatch/opatch" rollback -id "$id" -silent -oh "$OH" ) || recover "opatch rollback -id $id failed - the installer was not run"
    [ "$DRY_RUN" = 1 ] && continue
    now="$(installed_ids)" || recover "lspatches cannot be read after rolling back $id"
    case " $now " in *" $id "*) recover "$id is still installed after its rollback - the installer was not run" ;; esac
    log "  $id rolled back"
  done
  do_cmd unzip -o -q -d "$pt" "$ZIP" || recover "cannot unzip $ZIP"
  bin="$(find "$pt" -name fmw_12.2.1.19.0_dbclient_linux64.bin -type f 2>/dev/null | head -1)"
  [ -n "$bin" ] || recover "the installer is not in $pt after the unzip"
  ( cd "$(dirname "$bin")" && do_cmd ./changePerm.sh "$OH" ) || recover "changePerm.sh $OH failed"
  ( cd "$(dirname "$bin")" && do_cmd env ORACLE_HOME="$OH" "./$(basename "$bin")" -invPtrLoc "$OH/oraInst.loc" -silent ORACLE_HOME="$OH" ) || recover "the Database Client 19c installer failed"
}

# both sources (README: sqlplus -V; KB585169: oracle.rdbms.rsf); 0 = 19c by both
client_is_19() {
  local sv rv; sv="$(sqlplus_version "$OH")"; rv="$(rsf_version "$OH")"
  log "  sqlplus -V ${sv:-unreadable}; oracle.rdbms.rsf ${rv:-unknown}"
  [ -n "$sv" ] && version_ge "$sv" "$MIN_SQLPLUS" && case "$rv" in 19.*) return 0;; esac
  return 1
}

step_verify() {
  state stage verify
  log "4/5 verify: sqlplus -V $MIN_SQLPLUS or later AND oracle.rdbms.rsf 19.x"
  client_is_19 || recover "the installer returned 0 but the home does not read as Database Client 19c"
}

step_start() {
  state stage start
  log "5/5 start node manager and the components"
  start_all || recover "the upgraded home does not start"
}

recover() {
  err "$1 - restoring from $BK"
  state stage rollback
  if ! restore_all; then state outcome rollback-failed; err "RESTORE FAILED - nothing started"; manual_restore; where_logs; exit 3; fi
  local now; now="$(rsf_version "$OH")"
  [ -z "$PRE_RSF" ] || [ "$now" = "$PRE_RSF" ] || { state outcome rollback-failed; err "the restored home's oracle.rdbms.rsf is ${now:-unreadable}, not $PRE_RSF as before"; where_logs; exit 3; }
  if ! start_all; then state outcome restored-not-started; err "restored, but it does not start - servers DOWN"; where_logs; exit 3; fi
  state outcome rolled-back
  err "RESTORED: $OH is back on the Database Client ${PRE_RSF:-it had} and running. The upgrade is NOT done."
  where_logs
  exit 1
}

plan_steps() {
  log "dry-run: would back up $OH, $(printf '%s ' $DOMS)and $INV to $BK (tar, each read back)"
  log "dry-run: would stop $(printf '%s\n' "$COMPS" | cut -d'|' -f2 | tr '\n' ' ')and node manager, and prove nothing runs from $OH"
  [ -n "$REMOVE_IDS" ] && log "dry-run: would roll back${REMOVE_IDS} (--remove-patches) and prove each gone, before the installer"
  log "dry-run: would unzip $ZIP into <run dir>/patch_top, run ./changePerm.sh $OH and ./fmw_12.2.1.19.0_dbclient_linux64.bin -invPtrLoc $OH/oraInst.loc -silent ORACLE_HOME=$OH"
  log "dry-run: would check sqlplus -V >= $MIN_SQLPLUS and oracle.rdbms.rsf 19.x, then start node manager and the components"
  log "dry-run: on any failure after the backup, would restore $OH and $INV from $BK"
}

cmd_run() {
  require_detached run
  run_gate run "${1:-}"
  if [ "$DRY_RUN" = 1 ]; then plan_steps; exit 0; fi
  confirm "This stops OHS and node manager on this box and upgrades the Database Client in $OH to 19c (no uninstaller: the backup is the rollback)." || { err "not confirmed - nothing was changed"; exit 1; }
  open_run
  step_backup
  step_stop
  step_install
  step_verify
  step_start
  state outcome upgraded
  log "upgraded and verified: $OH has the Database Client 19c and every component answers. Backup kept at $BK."
  log "next (KB585169): the DB19c bundles - 39425385 (DB client 19.31), 39114058 (WebGate), 39567777 (OSS), 40005842 (OHS)"
  exit 0
}

cmd_backup() {
  require_detached backup
  run_gate backup "${1:-}"
  if [ "$DRY_RUN" = 1 ]; then log "dry-run: would back up $OH, $(printf '%s ' $DOMS)and $INV to $BK (tar, each read back)"; exit 0; fi
  confirm "This backs up $OH, its domains and $INV to $BK." || { err "not confirmed - nothing was changed"; exit 1; }
  open_run
  step_backup
  state outcome backed-up
  log "backed up to $BK (run dir $RUN_DIR); apply uses it, and rollback restores from it"
  exit 0
}

# the latest run whose backup completed for this home; empty if none
latest_backup_run() {
  local rd
  for rd in $(find "$RUN_BASE" -maxdepth 1 -name '*-run' -type d 2>/dev/null | sort -r); do
    [ -f "$rd/state" ] || continue
    [ "$(sed -n 's/^oracle_home=//p' "$rd/state" | tail -1)" = "$OH" ] || continue
    [ "$(sed -n 's/^backup=//p' "$rd/state" | tail -1)" = ok ] || continue
    echo "$rd"; return 0
  done
}

cmd_apply() {
  require_detached apply
  local dir="${1:-}" prc rd sv
  [ -n "$dir" ] || die "apply needs <dir> (the folder holding p34761383_*.zip)"
  cmd_preflight "$dir"; prc=$?
  [ "$prc" = 0 ] || { err "apply refused: preflight is not READY (exit $prc) - nothing was changed"; exit "$prc"; }
  [ "$ALREADY" = 1 ] && exit 0
  rd="${BACKUP_RUN:-$(latest_backup_run)}"
  [ -n "$rd" ] && [ -f "$rd/state" ] || { err "apply refused: no completed backup of $OH (pass --backup-run, or run '$0 backup $dir' first) - nothing was changed"; exit 1; }
  sv() { sed -n "s/^$1=//p" "$rd/state" | tail -1; }
  [ "$(sv oracle_home)" = "$OH" ] || { err "apply refused: $rd is a backup of $(sv oracle_home), not $OH - nothing was changed"; exit 1; }
  [ "$(sv backup)" = ok ] || { err "apply refused: $rd never completed its backup - nothing was changed"; exit 1; }
  BK="$(sv backup_dir)"
  [ -s "$BK/home.tgz" ] && [ -s "$BK/oraInventory.tgz" ] || { err "apply refused: the backup in $BK is not complete - nothing was changed"; exit 1; }
  # the level the backup holds: what a restore must prove it is back to
  PRE_IDS="$(sv pre_patches)"; [ -n "$(sv pre_rsf)" ] && PRE_RSF="$(sv pre_rsf)"
  nothing_running || { local n=$?; err "apply refused: stop first ('ohs-patch.sh stop') - nothing was changed"; exit "$([ "$n" = 2 ] && echo 2 || echo 1)"; }
  if [ "$DRY_RUN" = 1 ]; then log "dry-run: would install 34761383 into $OH and verify it; on failure restore from $BK"; exit 0; fi
  confirm "This upgrades the Database Client in $OH to 19c (backup $BK)." || { err "not confirmed - nothing was changed"; exit 1; }
  RUN_DIR="$rd"; STATE="$rd/state"; printf '%s' "$NARR" >>"$RUN_DIR/dbclient-upgrade.log"; NARR=""
  step_install
  step_verify
  state outcome upgraded-not-started
  log "upgraded: $OH has the Database Client 19c; start the components ('ohs-patch.sh start')"
  exit 0
}

cmd_verify() {
  discover
  client_is_19 && { log "verified: $OH has the Database Client 19c (sqlplus -V >= $MIN_SQLPLUS and oracle.rdbms.rsf 19.x)"; exit 0; }
  err "NOT 19c: $OH does not read as the Database Client 19c by both sqlplus -V and oracle.rdbms.rsf"
  exit 1
}

cmd_rollback() {
  require_detached rollback
  local rd="${RUN_DIR_ARG:-${1:-}}"
  [ -n "$rd" ] || rd="$(find "$RUN_BASE" -maxdepth 1 -name '*-run' -type d 2>/dev/null | sort | tail -1)"
  [ -n "$rd" ] && [ -f "$rd/state" ] || die "no run to roll back (pass --run-dir; runs are under $RUN_BASE)"
  sv() { sed -n "s/^$1=//p" "$rd/state" | tail -1; }
  OH="$(sv oracle_home)"; INV="$(sv inventory)"; BK="$(sv backup_dir)"; PRE_IDS="$(sv pre_patches)"; PRE_RSF="$(sv pre_rsf)"
  [ -n "$OH" ] && [ -n "$INV" ] && [ -n "$BK" ] || die "$rd/state does not name the home, inventory and backup"
  [ "$(sv backup)" = ok ] || die "run $rd never completed its backup - nothing to roll back from"
  ORACLE_HOME_ARG="$OH"
  local d c; DOMS="$(domains_of "$OH")"; COMPS=""
  while IFS= read -r d; do [ -n "$d" ] || continue; for c in $(ohs_components "$d"); do COMPS="$COMPS$d|$c"$'\n'; done; done <<<"$DOMS"
  if [ "$DRY_RUN" = 1 ]; then log "dry-run: would stop the components, restore $OH and $INV from $BK, check the patches are [$PRE_IDS], start them"; exit 0; fi
  confirm "This stops OHS on this box and restores $OH and $INV from $BK." || { err "not confirmed - nothing was changed"; exit 1; }
  RUN_DIR="$rd"; STATE="$rd/state"
  restore_all || { state outcome rollback-failed; err "ROLLBACK FAILED - nothing started"; manual_restore; where_logs; exit 3; }
  start_all || { state outcome restored-not-started; err "restored, but it does not start - servers DOWN"; where_logs; exit 3; }
  state outcome rolled-back; log "rolled back: $OH restored from $BK (Database Client ${PRE_RSF:-as before}) and running"
  exit 0
}

main() {
  local cmd="" args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --oracle-home)  optchk "$@"; ORACLE_HOME_ARG="$2"; shift 2 ;;
      --domain-home)  optchk "$@"; DOMAIN_ARG="$2"; shift 2 ;;
      --backup-dir)   optchk "$@"; BACKUP_DIR="$2"; shift 2 ;;
      --run-dir)      optchk "$@"; RUN_DIR_ARG="$2"; shift 2 ;;
      --backup-run)   optchk "$@"; BACKUP_RUN="$2"; shift 2 ;;
      --keep-patches) optchk "$@"; KEEP_PATCHES="$2"; shift 2 ;;
      --remove-patches) optchk "$@"; REMOVE_PATCHES="$2"; shift 2 ;;
      --dry-run)   DRY_RUN=1; shift ;;
      --yes)       ASSUME_YES=1; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) die "unknown option $1" ;;
      *) if [ -z "$cmd" ]; then cmd="$1"; else args+=("$1"); fi; shift ;;
    esac
  done
  case "$cmd" in
    inspect)   cmd_inspect ;;
    preflight) cmd_preflight "${args[@]+"${args[@]}"}" ;;
    backup)    cmd_backup "${args[@]+"${args[@]}"}" ;;
    apply)     cmd_apply "${args[@]+"${args[@]}"}" ;;
    verify)    cmd_verify ;;
    run)       cmd_run "${args[@]+"${args[@]}"}" ;;
    rollback)  cmd_rollback "${args[@]+"${args[@]}"}" ;;
    "") usage; exit 2 ;;
    *) die "unknown command $cmd (inspect, preflight, backup, apply, verify, run, rollback)" ;;
  esac
}

main "$@"
