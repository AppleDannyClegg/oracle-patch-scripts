#!/usr/bin/env bash
# ohs-patch.sh - check an Oracle HTTP Server home is ready for its bundle patch, apply it, and roll it back.
# inspect, plan, preflight and verify are read-only (preflight may unzip the patch into <patch-dir>/extracted; plan
# unzips to a scratch dir). backup, stop, apply, start, rollback and run change the host, and refuse to start from an
# interactive shell that is not detached (tmux, screen, nohup, or PATCH_DETACHED=1).
#
# Commands
#   inspect                 read-only: home, release, OPatch, the bundle and series installed, the domains and their
#                           OHS components and ports, and what runs from the home. No patch dir, no run dir, no change
#   plan <patch-dir>        read-only: preflight, then the steps run would take, in run's order. No run dir, no backup
#   preflight <patch-dir>   home, layout, domains and OHS components, what runs from the home, OPatch and series
#                           checks, a conflict check, disk for the backup, the node manager credentials. It prints
#                           no commands to run by hand (ohs-quarter's dry run shows it - T1842)
#   commands <patch-dir>    read-only: preflight, then, only when READY, the stop / backup / apply / start / verify /
#                           rollback commands for this box, for a window where run cannot be used. Refused under
#                           --client-19c-pending
#   backup <patch-dir>      preflight must be READY; back up the home, the domains and the central inventory (tar,
#                           each read back) into a new run dir, stopping nothing. apply and rollback use it
#   stop                    stop the OHS components, then each domain's node manager, and prove nothing runs from the
#                           home. A WebLogic server running from the home is refused
#   apply <patch-dir>       preflight must be READY, a completed backup of this home for this patch must exist, and
#                           nothing may run from the home; opatch apply, then lspatches must show it. A failure
#                           restores the home and central inventory from that backup and starts them again
#   start                   start node manager, then the components, and wait for their ports
#   verify [patch-dir]      read-only: what lspatches shows (and whether the patch in <patch-dir> is installed), and
#                           whether every component's ports answer now
#   run <patch-dir>         backup, stop, apply, start, verify, in that order, in one go: preflight must be READY;
#                           the backup is taken before the outage (a backup failure stops nothing). Any failure after
#                           the backup restores the home and central inventory from it and starts them again
#   rollback [run-dir]      restore the home and central inventory from a run's backup (default: the latest run)
#   prune-failed            delete the stamped failed copies a restore leaves (<home>.failed-<stamp>, and the
#                           inventory's): the newest of each is kept unless --all; nothing is deleted while a patch
#                           script runs, or if any copy is a symlink, another user's, or the live home. Asks unless --yes
#
# Options
#   --oracle-home DIR       the OHS (or WebLogic) home; default: $ORACLE_HOME, then the central inventory
#   --domain-home DIR       the domain holding the OHS components; default: every domain in domain-registry.xml
#   --backup-dir DIR        where the backup goes, for the free-space check (default /u01/backup)
#   --run-dir DIR           the run dir to write: backup (a composer's one backup, ohs-quarter.sh), stop and start
#                           (their log), and the run rollback restores from (default: the latest under
#                           <output dir>/ohs-patch/runs)
#   --backup-run DIR        apply: use this run's backup as the restore point (a composer's one backup, taken before
#                           its first patch) instead of the latest one taken for this patch; the home must match
#   --operator-stops        never stop or start a component or the node manager: print the commands
#                           instead (the operator stops/starts, then re-runs the step). Default unchanged
#   --no-backup             refused: the backup is the README's rollback
#   --client-19c-pending    preflight only: the DB Client 19c upgrade (34761383) runs BEFORE this patch in the same
#                           outage (ohs-quarter.sh passes it), so a 12c client and a CheckApplicable that cannot pass
#                           on 12c are reported, not blocking; apply runs its own preflight without it, on the 19c home
#   --dry-run               the changing commands: say what would be done, change nothing (the zip goes to a scratch dir)
#   --all                   prune-failed: remove the newest failed copy too
#   --yes                   the changing commands: do not ask for confirmation (without it a terminal must answer 'yes')
#
# Environment: START_TIMEOUT (seconds to wait for node manager, each component and its ports; default 300),
# POLL (seconds between checks; default 10), RUN_BASE (default <output dir>/ohs-patch/runs).
#
# Exit (preflight): 0 ready (warnings may be printed); 1 a blocking problem was found; 2 the check could not be
# completed (a read failed - ps, opatch, config.xml), so "ready" cannot be said.
# Exit (run, apply): 0 applied (and for run verified), or nothing to do; 1 refused or failed (rolled back if anything had
# changed); 3 failed AND the automatic rollback failed - the home needs a hand restore from the backup named in the log.
#
# Why each check (40005842 README, OHS (Native) DB19C Bundle Patch 12.2.1.4.260910):
#   - "Stop all processes associated with ORACLE_HOME, including WLS AdminServer, NodeManager, Managed Server
#     instances, and OHS server instances" -> every process whose command line names the home is listed
#   - "must be applied only to an Oracle Fusion Middleware home where the Oracle Database Client 12c has been
#     upgraded to 19c" (KB585169) -> a DB19C bundle on a home still on the plain bundle line is refused
#   - opatch apply refuses a patch whose required components are not in the home (OUI-67073, e.g. a DB19C bundle
#     needing oracle.rdbms.rsf 19c on a home whose Database Client is 12c) - but only after the stop and backup ->
#     'opatch prereq CheckApplicable' asks the same question read-only; a missing component is blocking
#   - "ORACLE_HOME must have OPatch version 13.9.4.2.13 or higher" -> the README's minimum against opatch version
#   - "For a complete rollback, restore ORACLE_HOME and CENTRAL INVENTORY from the backups" -> the backup is the
#     rollback, so there must be room for it
#   - startComponent.sh / stopComponent.sh go through the domain's node manager and prompt for its password unless
#     it was stored with 'startComponent.sh <name> storeUserConfig' -> a missing stored config is a blocking problem,
#     because a prompt in the middle of an outage is a hang

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

ORACLE_HOME_ARG=""; DOMAIN_ARG=""; BACKUP_DIR="/u01/backup"; RUN_DIR_ARG=""; BACKUP_RUN_ARG=""
DRY_RUN=0; CLIENT19_PENDING=0; OPATCH_PENDING=""; ASSUME_YES=0; NO_BACKUP=0; PRINT_CMDS=0; PRUNE_ALL=0; DRY_EXT=""; OPERATOR_STOPS=0
START_TIMEOUT="${START_TIMEOUT:-300}"; POLL="${POLL:-10}"; RUN_BASE="${RUN_BASE:-$(output_path ohs-patch)/runs}"
problems=0; unknowns=0
# what preflight found, for run: the home, the patch dir and id, the domains, the central inventory, 'domain|component'
OH=""; PD=""; PID=""; DOMS=""; INV=""; COMPS=""; PRE_IDS=""

ts()   { date '+%Y-%m-%d %H:%M:%S'; }
# the narration also goes to <run dir>/ohs-patch.log once a run dir exists; the lines before it (preflight) are
# held in NARR and written there when the run dir is opened, so the file is the whole story beside run.log
NARR=""
say()  { local l; l="$(printf '%s [%s] %s' "$(ts)" "$1" "$2")"; printf '%s\n' "$l" >&2
  if [ -n "${RUN_DIR:-}" ] && [ -d "$RUN_DIR" ]; then printf '%s\n' "$l" >>"$RUN_DIR/ohs-patch.log"; else NARR="$NARR$l"$'\n'; fi; }
log()  { say 'INFO ' "$*"; }
warn() { say 'WARN ' "$*"; }
err()  { say 'ERROR' "$*"; }
die()  { err "$*"; exit 2; }
block()   { err "BLOCKING: $*"; problems=$((problems + 1)); }
unknown() { err "UNKNOWN: $*"; unknowns=$((unknowns + 1)); }
optchk() { [ $# -ge 2 ] || die "$1 needs a value"; case "$2" in -[!0-9]*) die "$1 needs a value, got '$2'";; esac; }
usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

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

# standalone / collocated: the installer writes it into registry.xml; wlserver/ is the fallback
layout_of() {
  local reg="$1/inventory/registry.xml"
  if grep -q 'name="Oracle HTTP Server (Collocated)"' "$reg" 2>/dev/null; then echo collocated
  elif grep -q 'name="Oracle HTTP Server (Standalone)"' "$reg" 2>/dev/null; then echo standalone
  elif [ -d "$1/wlserver" ] && grep -q 'name="WebLogic Server"' "$reg" 2>/dev/null; then echo collocated
  else echo standalone; fi
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
# this shell ($$) and every ancestor of it, space-padded so awk can match a whole pid. A caller such as
# ohs-quarter.sh runs this script, so its argv carries the home and it was listed as an occupant, which made the
# stop unprovable (T1529). Two skips together: the name match below still drops THIS script and its
# command-substitution subshells (forked copies whose argv carries the home), and this ancestor walk drops the
# callers (ohs-quarter.sh, sudo, screen, bash -c) that hold the home. An unreadable ppid walk returns a blank
# string, so nothing is dropped - fail-closed, the caller may then be listed.
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
    /ohs-patch\.sh/ {next}
    /\/startNodeManager\.sh([[:space:]]|$)/ {next}   # the launcher, not the Node Manager (T1541)
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

# the patch: zips unzipped once into <dir>/extracted; the patch dir is the one with etc/config/inventory.xml
# a dry run unzips into DRY_EXT (a scratch dir, removed on exit), so the patch folder is not touched
patch_dirs() {
  local dir="$1" z to="$1/extracted"
  [ "$DRY_RUN" = 1 ] && [ -n "$DRY_EXT" ] && to="$DRY_EXT"
  for z in "$dir"/*.zip; do
    [ -f "$z" ] || continue
    [ -f "$dir/extracted/.done-$(basename "$z")" ] && continue
    mkdir -p "$to" || return 1
    unzip -o -q "$z" -d "$to" || { err "cannot unzip $z"; return 1; }
    [ "$to" = "$dir/extracted" ] && : >"$to/.done-$(basename "$z")"
  done
  find "$dir" ${DRY_EXT:+"$DRY_EXT"} -path '*/etc/config/inventory.xml' 2>/dev/null | sed 's#/etc/config/inventory.xml$##' | sort -u
}

# the Database Client level in the home: oracle.rdbms.rsf's VER in the home's inventory (the check KB585169 gives);
# empty when it cannot be read. A DB19C bundle needs 19.x - the upgrade is patch 34761383, an installer, not opatch
# T1845 field run 16 Nov 2026: after the 19c installer, comps.xml keeps the 12.1.0.2.0 oracle.rdbms.rsf entry
# beside the new 19.x one; the FIRST match read 12c and the verify restored a good upgrade. Take the HIGHEST VER.
rsf_version() {
  grep -o '<COMP [^>]*NAME="oracle\.rdbms\.rsf"[^>]*>' "$1/inventory/ContentsXML/comps.xml" 2>/dev/null | sed -n 's/.* VER="\([^"]*\)".*/\1/p' | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n | tail -1
}

readme_title() { head -5 "$1/README.txt" 2>/dev/null | tr -d '\r' | LC_ALL=C sed 's/[^[:print:]]//g' | grep -m1 -iE 'bundle patch|patch' ; }
# the minimum is only a version with 'or higher/later/above' after it: a README also names versions it was built with
readme_min_opatch() {
  { LC_ALL=C grep -aoE 'OPatch (utility )?(version )?13\.9(\.[0-9]+)+ or (higher|later|above)' "$1/README.txt" 2>/dev/null
    LC_ALL=C grep -aoE 'OPatch version must be atleast 13\.9(\.[0-9]+)+' "$1/README.txt" 2>/dev/null; } \
    | grep -oE '13\.9(\.[0-9]+)+' | sort -V | tail -1
}

# ---- preflight ------------------------------------------------------------------------------------------
# ---- inspect: what is here, without changing anything ------------------------------------------------
# The read-only first look the other patch scripts have (wls-patch inspect, db-patch inspect): home, release,
# OPatch, the bundle already installed, the domains and their components and ports, and what runs from the home.
# No patch dir, no run dir, no opatch apply - safe on a production host at any time.
cmd_inspect() {
  OH="$(find_home)"
  [ -n "$OH" ] || die "no Oracle HTTP Server home found (no ohs/ under \$ORACLE_HOME or any inventory home) - pass --oracle-home"
  local layout rel
  layout="$(layout_of "$OH")"; rel="$(ohs_release "$OH")"
  log "home     : $OH (OHS ${rel:-release unknown}, $layout)"
  [ -d "$OH/ohs" ] || warn "$OH has no ohs/ directory - it may not be an OHS home"

  local opv; opv="$(ORACLE_HOME="$OH" "$OH/OPatch/opatch" version 2>/dev/null | sed -n 's/^OPatch Version: *//p' | head -1)"
  log "OPatch   : ${opv:-unknown}"

  local lsp
  if lsp="$(ORACLE_HOME="$OH" "$OH/OPatch/opatch" lspatches 2>/dev/null)"; then
    lsp="$(printf '%s\n' "$lsp" | tr -d '\r' | grep -E '^[0-9]+;' || :)"
    local n; n="$(printf '%s\n' "$lsp" | grep -c . || true)"
    log "patches  : ${n:-0} installed"
    local b; b="$(printf '%s\n' "$lsp" | grep -i 'OHS (NATIVE)' | cut -d';' -f2 | head -1)"
    log "  OHS bundle: ${b:-none}"
    local rv; rv="$(rsf_version "$OH")"
    log "  DB client : $([ -n "$rv" ] && printf "oracle.rdbms.rsf %s" "$rv" || printf "unknown (no oracle.rdbms.rsf in %s)" "$OH/inventory/ContentsXML/comps.xml")"
    if printf '%s\n' "$lsp" | grep -i 'OHS (NATIVE) DB19C BUNDLE PATCH' >/dev/null; then log "  series    : DB19C line"
    elif printf '%s\n' "$lsp" | grep -i 'OHS (NATIVE) BUNDLE PATCH' >/dev/null; then log "  series    : plain OHS bundle line"
    else log "  series    : no OHS bundle installed yet"; fi
  else
    unknown "opatch lspatches failed - installed patches unknown"
  fi

  local doms d comps c ports
  doms="$(domains_of "$OH")"
  if [ -z "$doms" ]; then warn "no domain found for $OH (domain-registry.xml empty or missing) - pass --domain-home"; fi
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    log "domain   : $d ($(domain_name "$d")${comps:+})"
    comps="$(ohs_components "$d" | tr '\n' ' ' | sed 's/ *$//')"
    [ -n "$comps" ] || { log "  components: none"; continue; }
    for c in $comps; do
      ports="$(instance_ports "$d" "$c")"
      log "  component: $c${ports:+  ports $ports}"
    done
  done <<<"$doms"

  local procs
  if procs="$(from_home "$OH")"; then
    if [ -n "$procs" ]; then
      log "running  : processes holding a path in the home"
      printf '%s\n' "$procs" | while IFS= read -r l; do log "  $(kind_of_proc "$l"): $l"; done
    else
      log "running  : nothing runs from this home"
    fi
  else
    unknown "ps could not be read - cannot tell what runs from the home"
  fi
  [ "$unknowns" -gt 0 ] && { err "inspect could not complete: $unknowns check(s) unreadable"; return 2; }
  return 0
}

# ---- disk on each filesystem, and the failed copies a restore leaves (T1843) ------------------------------
# DISK is one "mount|free KB|need KB|what" line per need; disk_verdict sums the needs that share a mount, because a
# backup dir and a home on one filesystem (the default /u01/backup and a home under /u01) fill it together
DISK=""
disk_need() { # <path> <need KB, +10% already in> <what>
  local l f m; l="$(df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4 "|" $NF}')"; f="${l%%|*}"; m="${l#*|}"
  case "$f" in ''|*[!0-9]*) unknown "cannot read free space on $1 (does it exist?)"; return 0 ;; esac
  DISK="$DISK$m|$f|$2|$3"$'\n'
}
disk_verdict() { # <homes...>: one line per mount; a short one names the failed copies of these homes
  local m f n what held
  held="$(failed_held "$@")"
  while IFS='|' read -r m f n what; do
    [ -n "$m" ] || continue
    if [ "$f" -lt "$n" ]; then block "$m has $((f / 1024)) MB free; $what need about $((n / 1024)) MB (+10%)${held:+ - $held}"
    else log "disk     : $m has $((f / 1024)) MB free; $what need about $((n / 1024)) MB"; fi
  done < <(printf '%s' "$DISK" | awk -F'|' 'NF >= 4 { if (!($1 in f)) { o[++k] = $1; f[$1] = $2 }
      n[$1] += $3; w[$1] = (w[$1] == "" ? $4 : w[$1] " and " $4) }
    END { for (i = 1; i <= k; i++) print o[i] "|" f[o[i]] "|" n[o[i]] "|" w[o[i]] }')
  failed_report "$@"
}
# the stamped copies of each home: <home>.failed-<stamp> in the three forms the scripts write (restore_all's
# %Y%m%d-%H%M%S, the old printed line's %Y%m%d-%H%M, explain's %Y%m%d%H%M%S), nothing else
failed_copies() {
  local p c
  for p in "$@"; do
    for c in "$p".failed-*; do
      [ -e "$c" ] || [ -L "$c" ] || continue
      printf '%s\n' "${c#"$p"}" | grep -E '^\.failed-[0-9]{8}-?[0-9]{4,6}$' >/dev/null&& printf '%s\n' "$c"
    done
  done
  return 0
}
failed_held() { # "N MB is held by K failed copies (...)", or nothing
  local c k=0 t=0 s
  while IFS= read -r c; do [ -n "$c" ] || continue; s="$(du -sk "$c" 2>/dev/null | awk '{print $1}')"; k=$((k + 1)); t=$((t + ${s:-0})); done \
    < <(failed_copies "$@"; for c in "$@"; do [ -e "$c.bad" ] && printf '%s\n' "$c.bad"; done)
  [ "$k" -gt 0 ] && printf '%s MB is held by %s failed cop%s (prune-failed removes the stamped ones)' "$((t / 1024))" "$k" "$([ "$k" = 1 ] && echo y || echo ies)"
  return 0
}
failed_report() {
  local c
  while IFS= read -r c; do [ -n "$c" ] && warn "failed copy: $c ($(( $(du -sk "$c" 2>/dev/null | awk '{print $1}') / 1024 )) MB) - prune-failed removes it"; done < <(failed_copies "$@")
  for c in "$@"; do [ -e "$c.bad" ] && warn "failed copy: $c.bad, from a by-hand restore ($(( $(du -sk "$c.bad" 2>/dev/null | awk '{print $1}') / 1024 )) MB) - it has no stamp, so prune-failed leaves it: remove it by hand once $c is good"; done
  return 0
}

cmd_preflight() {
  local pdir="${1:-}"
  [ -n "$pdir" ] || die "preflight needs <patch-dir> (the folder holding the OHS bundle zip)"
  [ -d "$pdir" ] || die "patch dir $pdir does not exist"

  OH="$(find_home)"
  [ -n "$OH" ] || die "no Oracle HTTP Server home found (no ohs/ under \$ORACLE_HOME or any inventory home) - pass --oracle-home"
  [ -d "$OH/ohs" ] || block "$OH has no ohs/ directory - it is not an OHS home"
  local layout rel; layout="$(layout_of "$OH")"; rel="$(ohs_release "$OH")"
  log "home     : $OH (OHS ${rel:-release unknown}, $layout)"
  [ -n "$rel" ] || warn "the OHS release is not in $OH/inventory/registry.xml - check it by hand"

  # OPatch
  local opv; opv="$(ORACLE_HOME="$OH" "$OH/OPatch/opatch" version 2>/dev/null | sed -n 's/^OPatch Version: *//p' | head -1)"
  [ -n "$opv" ] || unknown "could not read the OPatch version ($OH/OPatch/opatch version)"
  local lsp; if ! lsp="$(ORACLE_HOME="$OH" "$OH/OPatch/opatch" lspatches 2>/dev/null)"; then unknown "opatch lspatches failed - installed patches unknown"; lsp=""; fi
  lsp="$(printf '%s\n' "$lsp" | tr -d '\r' | grep -E '^[0-9]+;' || :)"; PRE_IDS="$(printf '%s\n' "$lsp" | cut -d';' -f1 | grep . | sort -u | tr '\n' ' ')"
  log "OPatch   : ${opv:-unknown}; installed OHS bundle: $(printf '%s\n' "$lsp" | grep -i 'OHS (NATIVE)' | cut -d';' -f2 | head -1)"

  # the patch
  local pds pd id title min; PD=""; PID=""
  pds="$(patch_dirs "$pdir")" || die "could not unzip the patch in $pdir"
  [ -n "$pds" ] || die "no patch in $pdir (no p*.zip and no unzipped patch with etc/config/inventory.xml)"
  [ "$(printf '%s\n' "$pds" | grep -c .)" = 1 ] || block "more than one patch in $pdir - put only the OHS bundle there: $(printf '%s ' $pds)"
  pd="$(printf '%s\n' "$pds" | head -1)"; id="$(basename "$pd")"; PD="$pd"; PID="$id"
  title="$(readme_title "$pd")"; min="$(readme_min_opatch "$pd")"
  log "patch    : $id ${title:+- $title}"
  if printf '%s\n' "$lsp" | grep "^$id;" >/dev/null; then warn "$id is already installed in $OH - nothing to apply"; fi
  if [ -z "$min" ]; then warn "no 'OPatch version ... or higher' line in $pd/README.txt - check the README by hand"
  elif [ -z "$opv" ]; then :   # unknown OPatch version: already UNKNOWN above, never a pass
  elif ! version_ge "$opv" "$min"; then
    # A later opatch set can be reached on an older OPatch when wls-patch installs the OPatch kit
    # earlier in this same outage. Defer ONLY when the staged kit itself meets the later README's
    # minimum; an old or unreadable kit still blocks before the stop, as it always did.
    # The kit's version is the release in its file name (p28186730_1394220 -> 13.9.4.2.20),
    # the same number wls-patch uses to decide the kit is present. Its README's 'or later'
    # line says what the kit REQUIRES on the home, not what it installs.
    local kit_version="" kit_zip="" base="" rel=""
    if [ -n "$OPATCH_PENDING" ]; then
      for kit_zip in "$OPATCH_PENDING"/p28186730_*.zip; do
        [ -f "$kit_zip" ] || continue
        base="$(basename "$kit_zip")"; rel="${base#p28186730_}"; rel="${rel%%_*}"
        case "$rel" in
          13[0-9][0-9][0-9][0-9][0-9]) kit_version="${rel:0:2}.${rel:2:1}.${rel:3:1}.${rel:4:1}.${rel:5:2}" ;;
        esac
        break
      done
    fi
    if [ -n "$kit_version" ] && version_ge "$kit_version" "$min"; then
      warn "OPatch $opv is older than the $min $id's README asks for, but the OPatch kit in $OPATCH_PENDING is $kit_version and wls-patch installs it first in this outage - apply checks again after the upgrade"
    else
      block "OPatch $opv is older than the $min $id's README asks for - apply OPatch 28186730 first"
    fi
  else log "OPatch   : $opv meets the README minimum $min"; fi

  # DB19C series (KB585169)
  local rsf; rsf="$(rsf_version "$OH")"
  log "DB client : $([ -n "$rsf" ] && printf "oracle.rdbms.rsf %s" "$rsf" || printf "unknown (no oracle.rdbms.rsf in %s)" "$OH/inventory/ContentsXML/comps.xml")"
  if grep -qi <<<"$title" 'DB19C'; then
    # the client level, when the inventory shows it, decides; the bundle titles are only the fallback
    if [ -n "$rsf" ]; then
      case "$rsf" in
        19.*) log "series   : the home has the Database Client 19c (oracle.rdbms.rsf $rsf) - a DB19C bundle fits" ;;
        *) if [ "$CLIENT19_PENDING" = 1 ]; then
             log "series   : $id is a DB19C bundle; oracle.rdbms.rsf is $rsf now and the DB Client 19c upgrade runs before it in this outage - apply checks it again on the 19c home"
           else block "$id is a DB19C bundle and needs the Database Client 19c in $OH, but oracle.rdbms.rsf is $rsf - install the DB Client 19c Upgrade (patch 34761383, an FMW installer with no rollback but the backup; KB585169) first"; fi ;;
      esac
    elif printf '%s\n' "$lsp" | grep -i 'OHS (NATIVE) DB19C BUNDLE PATCH' >/dev/null; then log "series   : home is on the DB19C line"
    elif printf '%s\n' "$lsp" | grep -i 'OHS (NATIVE) BUNDLE PATCH' >/dev/null; then block "$id is a DB19C bundle but $OH is on the plain OHS bundle line - the Database Client 19c upgrade (KB585169) comes first"
    else warn "no OHS bundle installed yet: confirm $OH had the Database Client 19c upgrade (KB585169) before applying the DB19C bundle $id"; fi
  fi

  # required components (read-only OPatch prereq): opatch apply checks that the home has every component the patch
  # needs (CheckMissingComps) only AFTER the stop and the backup. A DB19C bundle on a home whose Database Client is
  # still 12c fails there with OUI-67073 naming oracle.rdbms.rsf:19.0.0.0.0 (Gen's host, 6 Nov) - ask now instead
  local app arc miss
  app="$(cd "$pd" && ORACLE_HOME="$OH" "$OH/OPatch/opatch" prereq CheckApplicable -ph . -oh "$OH" 2>&1)"; arc=$?
  # every oracle.<component>:<version> OPatch names in its answer (an empty list is not "the 19c client alone")
  local need; need="$(printf '%s\n' "$app" | grep -oE 'oracle\.[A-Za-z0-9_.]+:[0-9][0-9.]*' | sort -u)"
  if [ "$arc" = 0 ] && grep -qiE <<<"$app" 'Prereq "checkApplicable" (for patch [0-9]+ )?passed'; then
    log "components: every component $id needs is in $OH (opatch prereq CheckApplicable)"
  elif [ "$CLIENT19_PENDING" = 1 ] && ! printf '%s\n' "$need" | grep -v '^oracle\.rdbms\.rsf:19\.' >/dev/null; then
    # on a 12c client a DB19C patch cannot pass CheckApplicable yet (it needs oracle.rdbms.rsf 19); apply's own
    # preflight asks again once the upgrade earlier in the outage has run, and a failure there restores. Only when
    # the 19c client is ALL OPatch says is missing: anything else still stops here, before the stop (T1167)
    warn "components: CheckApplicable did not pass on the 12c client (rc $arc) - deferred: the DB Client 19c upgrade runs first in this outage and apply checks again. OPatch said: $(printf '%s\n' "$app" | grep -viE '^(oracle interim patch installer|copyright|invoking prereq|opatch (failed|succeeded))' | grep . | head -3 | tr '\n' ' ')"
  elif [ "$CLIENT19_PENDING" = 1 ] \
       && grep -qi <<<"$title" 'DB19C' \
       && [ -n "$rsf" ] && ! grep -q <<<"$rsf" '^19\.' \
       && [ -z "$need" ] \
       && grep -qiE <<<"$app" 'ZOP-45|Version Mismatch of Component'; then
    # 16 Nov field answer, OPatch 13.9.4.2.25 on the 12c client (T1808): ZOP-45 + "Version Mismatch of Component"
    # with NO oracle.<component>:<version> named at all. Deferred like the rsf:19 case above - the DB Client 19c
    # upgrade runs first in this outage and apply's own preflight asks again (a failure there restores). If rsf is
    # already 19.* the mismatch is real, and any component other than rsf:19 is still named, so both block here
    warn "components: CheckApplicable did not pass on the 12c client (rc $arc) - deferred: the DB Client 19c upgrade runs first in this outage and apply checks again. OPatch said: $(printf '%s\n' "$app" | grep -iE 'ZOP-45|Version Mismatch of Component|The details are|Prereq "checkApplicable" (for patch [0-9]+ )?failed' | tr '\n' ' ')"
  elif grep -qi <<<"$app" 'requires component(s) that are not installed'; then
    miss="$(printf '%s' "$app" | sed -n 's/.*These not-installed components are \([^ ]*\).*/\1/p' | head -1)"
    block "$id needs ${miss:-a component} that is not installed in $OH (OUI-67073) - opatch apply would refuse after the stop. For a DB19C bundle that is the Database Client 19c upgrade (KB585169), which comes first"
  elif grep -qiE <<<"$app" 'Prereq "checkApplicable" (for patch [0-9]+ )?failed'; then
    block "$id is not applicable to $OH (opatch prereq CheckApplicable, rc $arc): $(printf '%s\n' "$app" | grep -viE '^(invoking prereq|prereq "checkapplicable" (for patch [0-9]+ )?failed|opatch failed)' | grep . | head -3 | tr '\n' ' ')"
  else
    unknown "opatch prereq CheckApplicable gave no verdict (rc $arc) - whether $OH has every component $id needs is unknown: first: $(printf '%s\n' "$app" | grep . | head -2 | tr '\n' ' ')... last: $(printf '%s\n' "$app" | grep . | tail -2 | tr '\n' ' ')"
  fi

  # conflicts (read-only OPatch prereq)
  local pre prc
  pre="$(cd "$pd" && ORACLE_HOME="$OH" "$OH/OPatch/opatch" prereq CheckConflictAgainstOHWithDetail -ph . -oh "$OH" 2>&1)"; prc=$?
  # only the 'passed' line is a pass: OPatch prints the header 'Conflicts/Supersets for each patch are:' for a real
  # conflict too, so a 'superset' word in the output is no proof of anything (a superset of an installed bundle passes)
  # the exit status first (Jocasta P3): non-zero is a conflict whatever the wording says
  if [ "$prc" = 0 ] && grep -qE <<<"$pre" 'Prereq "checkConflictAgainstOHWithDetail" (for patch [0-9]+ )?passed' && ! grep -qi <<<"$pre" 'Conflict with'; then
    log "conflicts: none"
    grep -qiE <<<"$pre" 'superset|subset' && log "  ($id supersedes an installed patch - OPatch rolls the older one back itself)"
  elif [ "$prc" = 0 ] && ! grep -qiE <<<"$pre" 'Prereq "checkConflictAgainstOHWithDetail" (for patch [0-9]+ )?failed|Conflict with' && grep -qiE <<<"$pre" 'superset|subset'; then
    warn "$id supersedes an installed patch - OPatch rolls the older one back itself"
  else block "conflict check did not pass for $id (rc $prc): $(printf '%s\n' "$pre" | grep -iE 'conflict|error|fail' | head -3 | tr '\n' ' ')"; fi

  # domains, components, node manager credentials
  local doms d comps c dn bin ports cmds_stop="" cmds_start="" cmds_verify="" nmstart=""
  doms="$(domains_of "$OH")"; DOMS="$doms"; COMPS=""
  [ -n "$doms" ] || block "no domain found for $OH (domain-registry.xml empty or missing) - pass --domain-home"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ -f "$d/config/config.xml" ] || { unknown "$d/config/config.xml is not readable"; continue; }
    comps="$(ohs_components "$d" | tr '\n' ' ' | sed 's/ *$//')"
    dn="$(domain_name "$d")"; bin="$d/bin"
    log "domain   : $d ($dn) - OHS components: ${comps:-none}"
    [ -n "$comps" ] || continue
    for c in $comps; do
      COMPS="$COMPS$d|$c"$'\n'
      ports="$(instance_ports "$d" "$c")"
      cmds_stop="$cmds_stop  $bin/stopComponent.sh $c"$'\n'
      cmds_start="$cmds_start  $bin/startComponent.sh $c"$'\n'
      for p in $ports; do cmds_verify="$cmds_verify  curl -k -s -o /dev/null -w '%{http_code}\\n' https://localhost:$p/ || curl -s -o /dev/null -w '%{http_code}\\n' http://localhost:$p/   # $c"$'\n'; done
      [ -n "$ports" ] || warn "$c: no Listen port read from its httpd.conf/ssl.conf - check it answers by hand after the start"
    done
    nmstart="$nmstart  nohup $bin/startNodeManager.sh > $d/nodemanager.out 2>&1 &"$'\n'
    if [ -f "$HOME/.wlst/nm-cfg-$dn.props" ] && [ -f "$HOME/.wlst/nm-key-$dn.props" ]; then log "NM creds : stored for $dn ($HOME/.wlst/nm-cfg-$dn.props, as $(id -un 2>/dev/null)) - run as this user, or startComponent.sh asks for the password"
    else block "no stored node manager credentials for $dn (~/.wlst/nm-cfg-$dn.props): startComponent.sh would prompt mid-outage. Before the window run once, with the node manager up: $bin/startComponent.sh $(printf '%s' "$comps" | head -1) storeUserConfig"; fi
  done <<<"$doms"
  [ -n "$cmds_stop" ] || [ -z "$doms" ] || block "no OHS component (<system-component> with component-type OHS) in any domain of $OH"

  # what runs from the home now
  local procs
  if procs="$(from_home "$OH")"; then
    if [ -n "$procs" ]; then
      log "running from $OH (all must be stopped before the apply):"
      while read -r pid args; do [ -n "$pid" ] && log "  pid $pid  $(kind_of_proc "$args")"; done <<<"$procs"
      if printf '%s\n' "$procs" | grep 'weblogic.Server' >/dev/null; then
        warn "WebLogic servers run from this home ($layout): stop them first (wls-patch.sh stop) - this script's commands stop only OHS and node manager"
      fi
    else log "running  : nothing from $OH"; fi
  else unknown "cannot read the process list (ps failed) - cannot say what runs from $OH"; fi

  # disk (T1843): the backup (home + domains + inventory) on $BACKUP_DIR, and a restore - the home and the inventory
  # untarred beside their failed copies, the home plus the patch's growth (.patch_storage) - on their own filesystems.
  # Needs on one filesystem are summed: in a failed run the backup and the restored home are there together
  local inv need=0 k s hk="" ik="" pk
  inv="$(sed -n 's/^inventory_loc=//p' "$OH/oraInst.loc" /etc/oraInst.loc 2>/dev/null | head -1)"; INV="$inv"
  for k in "$OH" $doms ${inv:+"$inv"}; do
    s="$(du -sk "$k" 2>/dev/null | awk '{print $1}')"
    [ -n "$s" ] || { unknown "cannot size $k for the backup"; continue; }
    need=$((need + s)); [ "$k" = "$OH" ] && hk="$s"; [ "$k" = "$inv" ] && ik="$s"
  done
  pk="$(du -sk "$pd" 2>/dev/null | awk '{print $1}')"; pk="${pk:-0}"
  DISK=""
  disk_need "$BACKUP_DIR" $((need + need / 10)) "the backup"
  [ -n "$hk" ] && disk_need "$(dirname "$OH")" $(( (hk + pk) + (hk + pk) / 10 )) "a restore of the home, plus the patch"
  [ -n "$ik" ] && disk_need "$(dirname "$inv")" $((ik + ik / 10)) "a restore of the inventory"
  disk_verdict "$OH" ${inv:+"$inv"}

  # ---- the commands for this box ----------------------------------------------------------------------
  # Printed only by `commands`, and only when READY (T1842): preflight is what ohs-quarter's dry run shows, and on
  # 16 Nov 2026 a dry run's printed opatch apply was run by hand, out of the composer's order and its backup
  local stamp hand=""; stamp="$(date '+%Y%m%d-%H%M')"
  [ "$PRINT_CMDS" = 1 ] && hand="$({
    echo
    echo "COMMANDS for $OH (as the user that owns it). These bypass run's gates: its backup check, and its restore"
    echo "when a step fails. Prefer: $0 run $pdir. Run them in order; stop at the first that fails."
    echo "1. stop the OHS components, then the node manager"
    printf '%s' "$cmds_stop"
    while IFS= read -r d; do [ -n "$d" ] && echo "  $d/bin/stopNodeManager.sh"; done <<<"$doms"
    echo "2. prove nothing runs from the home (must print nothing)"
    echo "  ps -eo pid,args | grep -F '$OH/' | grep -v grep"
    echo "3. backup - this IS the rollback (README: restore ORACLE_HOME and CENTRAL INVENTORY)"
    echo "  tar -C '$(dirname "$OH")' -czf '$BACKUP_DIR/ohs-home-$stamp.tgz' '$(basename "$OH")'"
    while IFS= read -r d; do [ -n "$d" ] && echo "  tar -C '$(dirname "$d")' -czf '$BACKUP_DIR/ohs-domain-$(basename "$d")-$stamp.tgz' '$(basename "$d")'"; done <<<"$doms"
    [ -n "$inv" ] && echo "  tar -C '$(dirname "$inv")' -czf '$BACKUP_DIR/oraInventory-$stamp.tgz' '$(basename "$inv")'"
    echo "4. apply"
    echo "  cd '$pd' && ORACLE_HOME='$OH' '$OH/OPatch/opatch' apply -silent -oh '$OH'"
    echo "  ORACLE_HOME='$OH' '$OH/OPatch/opatch' lspatches | grep '^$id;'    # must print the bundle"
    echo "5. start the node manager, wait for it, then the components"
    printf '%s' "$nmstart"
    echo "  sleep 30"
    printf '%s' "$cmds_start"
    echo "6. verify"
    printf '%s' "${cmds_verify:-  (no ports read - check each OHS URL by hand)
}"
    echo "  tail the component logs under <domain>/servers/<component>/logs/ for errors"
    echo "7. post-install: check KB187736 for collaborative patches this bundle needs"
    echo "ROLLBACK (complete): stop as in 1, then"
    echo "  mv '$OH' '$OH.failed-$stamp' && tar -C '$(dirname "$OH")' -xzf '$BACKUP_DIR/ohs-home-$stamp.tgz'"
    [ -n "$inv" ] && echo "  mv '$inv' '$inv.failed-$stamp' && tar -C '$(dirname "$inv")' -xzf '$BACKUP_DIR/oraInventory-$stamp.tgz'"
    echo "  then start as in 5. (opatch rollback -id $id alone does not bring back the bundle it replaced)"
  })"

  echo >&2
  if [ "$unknowns" -gt 0 ]; then err "preflight could not complete: $unknowns check(s) unreadable, $problems blocking - NOT ready"; return 2; fi
  if [ "$problems" -gt 0 ]; then err "$problems blocking problem(s) - NOT ready"; return 1; fi
  if [ -n "$hand" ]; then printf '%s\n\n' "$hand" >&2; log "READY: nothing blocking. The commands above are for a window without run."
  else log "READY: nothing blocking. Apply with: $0 run $pdir (or ohs-quarter.sh for the quarter)"; fi
  return 0
}

# ---- run ------------------------------------------------------------------------------------------------
RUN_DIR=""; STATE=""; BK=""
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
  if grep -qiE <<<"$tailtxt" 'password|user ?name|credential'; then
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

# every OHS component, then each domain's node manager, each tried whatever the one before returned; 0 = all
# returned 0. A non-zero stop is evidence, not the verdict: the callers judge on nothing_running, once, after this
# (a node manager that was already down returns non-zero with nothing to stop). STOP_FAILED names each one.
STOP_FAILED=""
operator_stop_commands() {
  local d c
  while IFS='|' read -r d c; do [ -n "$c" ] || continue; printf '%s/bin/stopComponent.sh %s\n' "$d" "$c"; done <<<"$COMPS"
  while IFS= read -r d; do [ -n "$d" ] || continue; printf '%s/bin/stopNodeManager.sh\n' "$d"; done <<<"$DOMS"
}

operator_start_commands() {
  local d c
  while IFS= read -r d; do [ -n "$d" ] || continue; printf 'nohup %s/bin/startNodeManager.sh &\n' "$d"; done <<<"$DOMS"
  while IFS='|' read -r d c; do [ -n "$c" ] || continue; printf '%s/bin/startComponent.sh %s\n' "$d" "$c"; done <<<"$COMPS"
}

# --operator-stops: the operator owns every start and stop. Print the commands and change no process.
operator_stops_note() {
  local l
  log "operator-stops: not running any start or stop script; the operator does that:"
  "$1" | while IFS= read -r l; do [ -n "$l" ] && log "  $l"; done
}

stop_all() {
  if [ "$OPERATOR_STOPS" = 1 ]; then operator_stops_note operator_stop_commands; return 0; fi
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
  if [ "$OPERATOR_STOPS" = 1 ]; then operator_stops_note operator_start_commands; return 0; fi
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

# every log a failed run leaves, by the path it has NOW: after a restore the patched home (and opatch's own log
# in it) is the .failed-* copy, not the home the operator knows
FAILED_HOME=""
where_logs() {
  err "LOGS: this script's narration $RUN_DIR/ohs-patch.log; the commands' own output $RUN_DIR/run.log (and nodemanager-*.out beside it)"
  if [ -n "$FAILED_HOME" ]; then err "      opatch's own log of the failed apply: $FAILED_HOME/cfgtoollogs/opatch/ (the home was renamed by the rollback)"
  else err "      opatch's own log: $OH/cfgtoollogs/opatch/"; fi
}

manual_restore() {
  err "MANUAL RESTORE (the servers are DOWN):"
  err "  mv '$OH' '$OH.bad' && tar -C '$(dirname "$OH")' -xzf '$BK/home.tgz'"
  err "  mv '$INV' '$INV.bad' && tar -C '$(dirname "$INV")' -xzf '$BK/oraInventory.tgz'"
  err "  then: $0 start --oracle-home $OH"
}

# after a change failed: restore, prove the level, start. Never opatch rollback (README). exit 1 or 3.
recover() {
  err "$1 - rolling back from $BK"
  state stage rollback
  if ! restore_all; then state outcome rollback-failed; err "ROLLBACK FAILED - nothing started"; manual_restore; where_logs; exit 3; fi
  if ! start_all; then state outcome restored-not-started; err "restored, but it does not start - servers DOWN, no second rollback"; where_logs; exit 3; fi
  state outcome rolled-back
  err "ROLLED BACK: $OH is back at its level before the apply and running. $PID is NOT applied."
  where_logs
  exit 1
}

# ---- the steps; run is these in order, and each is also a command of its own ----------------------------
# the gate before anything changes: preflight READY, not already installed, no WebLogic server from the home,
# a writable backup dir; sets BK. Exits (never returns) when the answer is no.
run_gate() {
  local what="$1" pdir="${2:-}"
  [ -n "$pdir" ] || die "$what needs <patch-dir>"
  [ "$NO_BACKUP" = 1 ] && { err "--no-backup refused: the README's rollback is the backup of ORACLE_HOME and the central inventory"; exit 1; }
  [ "$DRY_RUN" = 1 ] && { DRY_EXT="$(mktemp -d)"; trap 'rm -rf "$DRY_EXT"' EXIT; }
  local prc; cmd_preflight "$pdir"; prc=$?
  [ "$prc" = 0 ] || { err "$what refused: preflight is not READY (exit $prc) - nothing was changed"; exit "$prc"; }
  if printf ' %s ' "$PRE_IDS" | grep " $PID " >/dev/null; then log "$PID is already installed in $OH - nothing to do"; exit 0; fi
  no_weblogic "$what"
  [ -d "$BACKUP_DIR" ] && [ -w "$BACKUP_DIR" ] || { err "$what refused: backup dir $BACKUP_DIR is missing or not writable - nothing was changed"; exit 1; }
  STAMP="$(date '+%Y%m%d-%H%M%S')"
  BK="$BACKUP_DIR/ohs-$PID-$STAMP"
}

# this script stops only OHS components and node manager: a WebLogic server running from the home is refused
no_weblogic() {
  local procs; procs="$(from_home "$OH")" || { err "cannot read the process list - refused"; exit 2; }
  if printf '%s\n' "$procs" | grep 'weblogic\.Server' >/dev/null; then
    err "$1 refused: WebLogic servers run from $OH - stop them first (wls-patch.sh stop); this script stops only OHS and node manager. Nothing was changed."
    exit 1
  fi
}

plan_steps() {
  log "dry-run: would back up $OH, $(printf '%s ' $DOMS)and $INV to $BK (tar, each read back)"
  while IFS='|' read -r d c; do [ -n "$c" ] && log "dry-run: would run $d/bin/stopComponent.sh $c"; done <<<"$COMPS"
  while IFS= read -r d; do [ -n "$d" ] && log "dry-run: would run $d/bin/stopNodeManager.sh"; done <<<"$DOMS"
  log "dry-run: would check nothing runs from $OH, then: cd $PD && opatch apply -silent -oh $OH"
  log "dry-run: would check lspatches shows $PID, start node manager and $(printf '%s\n' "$COMPS" | cut -d'|' -f2 | tr '\n' ' ')and wait for their ports"
  log "dry-run: on any failure, would restore $OH and $INV from $BK"
}

# a new run dir and its state: what rollback reads
open_run() {
  # --run-dir was parsed for EVERY command (:746) and read only by rollback (:720), so a caller that asked for a
  # shared run dir - the composer's one-backup phase, ohs-quarter.sh dshared/oshared - got its backup written to
  # $RUN_BASE/<stamp>-run instead, and the later apply --backup-run $SHARED refused with "has no state" (T291).
  RUN_DIR="${RUN_DIR_ARG:-$RUN_BASE/$STAMP-run}"; ( umask 077; mkdir -p "$RUN_DIR" ) || die "cannot create run dir $RUN_DIR: $OUTPUT_HINT"
  chmod 700 "$RUN_DIR" 2>/dev/null || die "cannot make run dir $RUN_DIR private (chmod 700 failed)"
  ( umask 077; : >>"$RUN_DIR/run.log" ); chmod 600 "$RUN_DIR/run.log" 2>/dev/null || die "cannot make $RUN_DIR/run.log private (chmod 600 failed)"
  STATE="$RUN_DIR/state"; : >"$STATE"; printf '%s' "$NARR" >"$RUN_DIR/ohs-patch.log"; NARR=""
  state oracle_home "$OH"; state inventory "$INV"; state patch "$PID"; state backup_dir "$BK"; state pre_patches "$PRE_IDS"
  log "run dir  : $RUN_DIR"
}

# 1 backup (before the outage: a backup failure stops nothing)
step_backup() {
  state stage backup
  log "1/5 backup to $BK"
  backup_all || { rm -rf "$BK"; state outcome refused-backup; err "backup failed - nothing was stopped or changed"; exit 1; }
  state backup ok
}

# 2 stop, then prove nothing runs from the home; a failure here changed nothing in the home: start again
step_stop() {
  state stage stop
  log "2/5 stop OHS components and node manager"
  local nr
  stop_all; stopped_proved; nr=$?
  if [ "$nr" != 0 ]; then
    state outcome refused-stop
    if [ "$OPERATOR_STOPS" = 1 ]; then
      err "the home could not be proved stopped - NOT applying; nothing was changed, it is still running"
      where_logs
    else
      err "the home could not be proved stopped - NOT applying; starting the components again"
      start_all || err "and they did not all start again - check them by hand"
      where_logs
    fi
    exit "$([ "$nr" = 2 ] && echo 2 || echo 1)"
  fi
}

# 3 apply; from here the home may have changed, so every failure restores from the backup
step_apply() {
  state stage apply
  log "3/5 opatch apply $PID"
  ( cd "$PD" && do_cmd env ORACLE_HOME="$OH" "$OH/OPatch/opatch" apply -silent -oh "$OH" ) || recover "opatch apply failed"
  local now; now="$(installed_ids)" || recover "lspatches cannot be read after the apply"
  printf ' %s ' "$now" | grep " $PID " >/dev/null|| recover "opatch apply returned 0 but lspatches does not show $PID"
}

# 4 start
step_start() {
  state stage start
  if [ "$OPERATOR_STOPS" = 1 ]; then log "4/5 the operator starts node manager and the components now"
  else log "4/5 start node manager and the components"; fi
  start_all || recover "the patched home does not start"
}

# 5 verify: the level moved and stays moved
step_verify() {
  local now; now="$(installed_ids)" || recover "lspatches cannot be read after the start"
  printf ' %s ' "$now" | grep " $PID " >/dev/null|| recover "lspatches does not show $PID after the start"
  state applied "$PID"; state outcome applied
  if [ "$OPERATOR_STOPS" = 1 ]; then
    log "5/5 applied: $PID is installed in $OH. The home is left STOPPED for the operator to start; nothing was checked as answering. Backup kept at $BK."
  else
    log "5/5 applied and verified: $PID is installed in $OH and every component answers. Backup kept at $BK."
  fi
  log "post-install: check KB187736 for collaborative patches this bundle needs"
}

cmd_run() {
  require_detached run
  run_gate run "${1:-}"
  if [ "$DRY_RUN" = 1 ]; then plan_steps; exit 0; fi
  confirm "This stops OHS ($(printf '%s\n' "$COMPS" | cut -d'|' -f2 | tr '\n' ' ' | sed 's/ $//') and node manager) on this box and applies $PID to $OH." || { err "not confirmed - nothing was changed"; exit 1; }
  open_run
  step_backup
  step_stop
  step_apply
  step_start
  step_verify
  exit 0
}

# commands: preflight, then the hand-run block for a window run cannot be used in (T1842). Read-only; ohs-quarter
# never calls it. A home waiting on the 19c client upgrade gets no block: the upgrade comes first in the same outage
cmd_commands() {
  [ "$CLIENT19_PENDING" = 1 ] && { err "commands refused under --client-19c-pending: the 19c client upgrade must run first, so hand commands for this 12c home would patch it out of order - use ohs-quarter.sh"; exit 1; }
  PRINT_CMDS=1
  cmd_preflight "$@"; exit $?
}

# read-only: what run would do, in run's order, from the same checks run makes
cmd_plan() {
  DRY_RUN=1
  run_gate plan "${1:-}"
  plan_steps
  log "run does all of this for you, in this order, and restores from the backup if a step after the backup fails: $0 run ${1:-<patch-dir>} --oracle-home $OH --backup-dir $BACKUP_DIR"
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
  log "backed up to $BK (run dir $RUN_DIR); apply $PD uses it, and rollback restores from it"
  exit 0
}

# the home, its domains, the OHS components and the central inventory, without a patch dir
discover() {
  OH="$(find_home)"
  [ -n "$OH" ] || die "no Oracle HTTP Server home found (no ohs/ under \$ORACLE_HOME or any inventory home) - pass --oracle-home"
  INV="$(sed -n 's/^inventory_loc=//p' "$OH/oraInst.loc" /etc/oraInst.loc 2>/dev/null | head -1)"
  local d c; DOMS="$(domains_of "$OH")"; COMPS=""
  while IFS= read -r d; do [ -n "$d" ] || continue; for c in $(ohs_components "$d"); do COMPS="$COMPS$d|$c"$'\n'; done; done <<<"$DOMS"
  [ -n "$COMPS" ] || die "no OHS component in any domain of $OH - pass --domain-home"
}

# a run dir for a command that changes the services but is not part of a run (its log only). A given --run-dir is
# used as it is: ohs-quarter.sh passes its outage's dir, so stop and start log there, not beside it (T1107)
open_log() { RUN_DIR="${RUN_DIR_ARG:-$RUN_BASE/$(date '+%Y%m%d-%H%M%S')-$1}"; [ "$DRY_RUN" = 1 ] && return 0; mkdir -p "$RUN_DIR" || die "cannot create run dir $RUN_DIR: $OUTPUT_HINT"; }

cmd_stop() {
  require_detached stop
  discover; no_weblogic stop
  confirm "This stops OHS ($(printf '%s\n' "$COMPS" | cut -d'|' -f2 | tr '\n' ' ' | sed 's/ $//') and node manager) on this box." || { err "not confirmed - nothing was changed"; exit 1; }
  open_log stop
  stop_all
  [ "$DRY_RUN" = 1 ] && exit 0
  stopped_proved || { local n=$?; err "the home could not be proved stopped"; exit "$([ "$n" = 2 ] && echo 2 || echo 1)"; }
  log "stopped: nothing runs from $OH"
  exit 0
}

cmd_start() {
  require_detached start
  discover
  confirm "This starts node manager and OHS ($(printf '%s\n' "$COMPS" | cut -d'|' -f2 | tr '\n' ' ' | sed 's/ $//')) on this box." || { err "not confirmed - nothing was changed"; exit 1; }
  open_log start
  start_all || { err "not everything started - see above"; exit 1; }
  if [ "$DRY_RUN" = 1 ]; then :
  elif [ "$OPERATOR_STOPS" = 1 ]; then log "the operator starts node manager and the components; nothing was started here"
  else log "started: node manager and every component, ports answering"; fi
  exit 0
}

# the latest run whose backup completed for this home and this patch; empty if none
latest_backup_run() {
  local rd
  for rd in $(find "$RUN_BASE" -maxdepth 1 -name '*-run' -type d 2>/dev/null | sort -r); do
    [ -f "$rd/state" ] || continue
    [ "$(sed -n 's/^oracle_home=//p' "$rd/state" | tail -1)" = "$OH" ] || continue
    [ "$(sed -n 's/^patch=//p' "$rd/state" | tail -1)" = "$PID" ] || continue
    [ "$(sed -n 's/^backup=//p' "$rd/state" | tail -1)" = ok ] || continue
    echo "$rd"; return 0
  done
}

cmd_apply() {
  require_detached apply
  local pdir="${1:-}"
  [ -n "$pdir" ] || die "apply needs <patch-dir>"
  [ "$DRY_RUN" = 1 ] && { DRY_EXT="$(mktemp -d)"; trap 'rm -rf "$DRY_EXT"' EXIT; }
  local prc; cmd_preflight "$pdir"; prc=$?
  [ "$prc" = 0 ] || { err "apply refused: preflight is not READY (exit $prc) - nothing was changed"; exit "$prc"; }
  if printf ' %s ' "$PRE_IDS" | grep " $PID " >/dev/null; then log "$PID is already installed in $OH - nothing to do"; exit 0; fi
  local rd
  if [ -n "$BACKUP_RUN_ARG" ]; then
    rd="$BACKUP_RUN_ARG"
    [ -f "$rd/state" ] || { err "apply refused: --backup-run $rd has no state - nothing was changed"; exit 1; }
    [ "$(sed -n 's/^oracle_home=//p' "$rd/state" | tail -1)" = "$OH" ] || { err "apply refused: --backup-run $rd is a backup of $(sed -n 's/^oracle_home=//p' "$rd/state" | tail -1), not $OH - nothing was changed"; exit 1; }
    [ "$(sed -n 's/^backup=//p' "$rd/state" | tail -1)" = ok ] || { err "apply refused: --backup-run $rd did not complete its backup - nothing was changed"; exit 1; }
  else
    rd="$(latest_backup_run)"
    [ -n "$rd" ] || { err "apply refused: no completed backup of $OH for $PID under $RUN_BASE - run '$0 backup $pdir' first. Nothing was changed."; exit 1; }
  fi
  BK="$(sed -n 's/^backup_dir=//p' "$rd/state" | tail -1)"
  [ -s "$BK/home.tgz" ] && [ -s "$BK/oraInventory.tgz" ] || { err "apply refused: the backup in $BK is not complete - nothing was changed"; exit 1; }
  # the backup's own record of the level before, so a recover proves the home is back where the backup was taken
  PRE_IDS="$(sed -n 's/^pre_patches=//p' "$rd/state" | tail -1)"
  nothing_running || { local n=$?; err "apply refused: stop first ('$0 stop') - nothing was changed"; exit "$([ "$n" = 2 ] && echo 2 || echo 1)"; }
  if [ "$DRY_RUN" = 1 ]; then log "dry-run: would run cd $PD && opatch apply -silent -oh $OH, check lspatches shows $PID; on failure restore from $BK"; exit 0; fi
  confirm "This applies $PID to $OH (backup $BK)." || { err "not confirmed - nothing was changed"; exit 1; }
  RUN_DIR="$rd"; STATE="$rd/state"
  step_apply
  log "applied: $PID is installed in $OH; start the components ('$0 start'), then '$0 verify $pdir'"
  exit 0
}

# read-only: the patch is installed (when a patch dir is given) and every component's ports answer now
cmd_verify() {
  local pdir="${1:-}" rc=0 d c now
  discover
  now="$(installed_ids)" || { err "lspatches cannot be read on $OH"; exit 2; }
  log "installed in $OH: [$now]"
  if [ -n "$pdir" ]; then
    DRY_RUN=1; DRY_EXT="$(mktemp -d)"; trap 'rm -rf "$DRY_EXT"' EXIT
    local pd; pd="$(patch_dirs "$pdir" | head -1)"
    PID="$(basename "${pd:-}")"
    [ -n "$PID" ] || die "no patch found in $pdir"
    if printf ' %s ' "$now" | grep " $PID " >/dev/null; then log "$PID is installed"; else err "$PID is NOT installed in $OH"; rc=1; fi
  fi
  if [ "$OPERATOR_STOPS" = 1 ]; then
    log "ports not checked: the operator starts the components (--operator-stops)"
  else
    while IFS='|' read -r d c; do [ -n "$c" ] || continue; ports_answer "$d" "$c" 0 || rc=1; done <<<"$COMPS"
  fi
  exit "$rc"
}

# prune-failed: delete the stamped failed copies of the home and the central inventory (T1843). Each is listed with
# its size. The newest of each is kept unless --all (it may be the evidence for the last failure); it asks unless
# --yes; --dry-run lists only. It deletes NOTHING when a patch script runs on this box, or when any candidate is a
# symlink, is not owned by the user running it, resolves to the live home or inventory (or under one), or has a
# process running from it. <home>.bad (manual_restore) has no stamp and is never touched
cmd_prune_failed() {
  OH="$(find_home)"; [ -n "$OH" ] || die "no Oracle HTTP Server home found - pass --oracle-home"
  INV="$(sed -n 's/^inventory_loc=//p' "$OH/oraInst.loc" /etc/oraInst.loc 2>/dev/null | head -1)"
  local me busy p c r run ohr invr="" bad=0 keep="" list="" first
  me="$(id -un)"
  # this script's own forks carry its argv too: the $(...) subshell (ppid $$) and its children before they exec
  # (ppid = that subshell), so both are dropped with the ancestors (T1843, Quark #19854). BASHPID needs bash 4+
  # (RHEL/OL); on 3.2 the $$ fallback misses the pre-exec forks, and prune may refuse itself - never the reverse
  local anc; anc="$(ancestor_pids)"
  busy="$(spid="${BASHPID:-$$}"; set -o pipefail; ps -eo pid,ppid,args 2>/dev/null | awk -v anc=" $anc " -v me="$$" -v spid="$spid" '
    /(ohs-patch|ohs-quarter|dbclient-upgrade|wls-patch|java-patch)\.sh/ && !/ awk / {
      if (index(anc, " " $1 " ") == 0 && $2 != me && $2 != spid && $1 != spid) print }')" \
    || { err "cannot read the process list, so cannot say no patch script is running - prune-failed removed nothing"; exit 1; }
  [ -z "$busy" ] || { err "a patch script is running on this box - prune-failed removed nothing:"; printf '  %s\n' "$busy" >&2; exit 1; }
  ohr="$(cd -P "$OH" && pwd -P)"; [ -n "$INV" ] && invr="$(cd -P "$INV" 2>/dev/null && pwd -P)"
  for p in "$OH" ${INV:+"$INV"}; do
    first=1
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      if [ -L "$c" ]; then err "refused: $c is a symlink"; bad=1; continue; fi
      [ -O "$c" ] || { err "refused: $c is not owned by $me"; bad=1; continue; }
      r="$(cd -P "$c" 2>/dev/null && pwd -P)" || { err "refused: cannot resolve $c"; bad=1; continue; }
      case "$r/" in "$ohr/"*) err "refused: $c resolves to $r, the live home"; bad=1; continue ;; esac
      if [ -n "$invr" ]; then case "$r/" in "$invr/"*) err "refused: $c resolves to $r, the live inventory"; bad=1; continue ;; esac; fi
      run="$(from_home "$c")" || { err "refused: cannot read the process list, so cannot say nothing runs from $c"; bad=1; continue; }
      [ -z "$run" ] || { err "refused: something runs from $c"; bad=1; continue; }
      if [ "$first" = 1 ] && [ "$PRUNE_ALL" != 1 ]; then keep="$keep$c"$'\n'; first=0; continue; fi
      first=0; list="$list$c"$'\n'
    done < <(failed_copies "$p" | awk -v n="$(( ${#p} + 9 ))" '{ k = substr($0, n); gsub(/-/, "", k); while (length(k) < 14) k = k "0"; print k "\t" $0 }' | sort -r | cut -f2-)
  done
  [ "$bad" = 0 ] || { err "prune-failed removed nothing: fix the refusals above"; exit 1; }
  while IFS= read -r c; do [ -n "$c" ] && log "keep     : $c (the newest; --all removes it too)"; done <<<"$keep"
  [ -n "$list" ] || { log "nothing to remove"; exit 0; }
  while IFS= read -r c; do [ -n "$c" ] && log "remove   : $c ($(( $(du -sk "$c" 2>/dev/null | awk '{print $1}') / 1024 )) MB)"; done <<<"$list"
  [ "$DRY_RUN" = 1 ] && { log "dry-run: nothing removed"; exit 0; }
  confirm "This deletes the failed copies listed above." || { err "not confirmed - nothing removed"; exit 1; }
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    rm -rf -- "$c" || { err "could not remove $c"; exit 1; }
    log "removed  : $c"
  done <<<"$list"
  exit 0
}

cmd_rollback() {
  require_detached rollback
  local rd="${RUN_DIR_ARG:-${1:-}}"
  [ -n "$rd" ] || rd="$(find "$RUN_BASE" -maxdepth 1 -name '*-run' -type d 2>/dev/null | sort | tail -1)"
  [ -n "$rd" ] && [ -f "$rd/state" ] || die "no run to roll back (pass --run-dir; runs are under $RUN_BASE)"
  sv() { sed -n "s/^$1=//p" "$rd/state" | tail -1; }
  OH="$(sv oracle_home)"; INV="$(sv inventory)"; BK="$(sv backup_dir)"; PID="$(sv patch)"; PRE_IDS="$(sv pre_patches)"
  [ -n "$OH" ] && [ -n "$INV" ] && [ -n "$BK" ] || die "$rd/state does not name the home, inventory and backup"
  [ "$(sv backup)" = ok ] || die "run $rd never completed its backup - nothing to roll back from"
  ORACLE_HOME_ARG="$OH"
  local d c; DOMS="$(domains_of "$OH")"; COMPS=""
  while IFS= read -r d; do [ -n "$d" ] || continue; for c in $(ohs_components "$d"); do COMPS="$COMPS$d|$c"$'\n'; done; done <<<"$DOMS"
  if [ "$DRY_RUN" = 1 ]; then log "dry-run: would stop the components, restore $OH and $INV from $BK, check the patches are [$PRE_IDS], start them"; exit 0; fi
  confirm "This stops OHS on this box and restores $OH and $INV from $BK." || { err "not confirmed - nothing was changed"; exit 1; }
  RUN_DIR="$rd"; STATE="$rd/state"
  restore_all || { state outcome rollback-failed; err "ROLLBACK FAILED - nothing started"; manual_restore; exit 3; }
  start_all || { state outcome restored-not-started; err "restored, but it does not start - servers DOWN"; exit 3; }
  state outcome rolled-back; log "rolled back: $OH restored from $BK and running"
  exit 0
}

main() {
  local cmd="" args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --oracle-home) optchk "$@"; ORACLE_HOME_ARG="$2"; shift 2 ;;
      --domain-home) optchk "$@"; DOMAIN_ARG="$2"; shift 2 ;;
      --backup-dir)  optchk "$@"; BACKUP_DIR="$2"; shift 2 ;;
      --run-dir)     optchk "$@"; RUN_DIR_ARG="$2"; shift 2 ;;
      --backup-run)  optchk "$@"; BACKUP_RUN_ARG="$2"; shift 2 ;;
      --dry-run)   DRY_RUN=1; shift ;;
      --all)       PRUNE_ALL=1; shift ;;
      --client-19c-pending) CLIENT19_PENDING=1; shift ;;
      --opatch-upgrade-pending) optchk "$@"; OPATCH_PENDING="$2"; shift 2 ;;
      --yes)       ASSUME_YES=1; shift ;;
      --no-backup) NO_BACKUP=1; shift ;;
      --operator-stops) OPERATOR_STOPS=1; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) die "unknown option $1" ;;
      *) if [ -z "$cmd" ]; then cmd="$1"; else args+=("$1"); fi; shift ;;
    esac
  done
  case "$cmd" in
    inspect)   cmd_inspect ;;
    preflight) cmd_preflight "${args[@]+"${args[@]}"}" ;;
    commands)  cmd_commands "${args[@]+"${args[@]}"}" ;;
    "") usage; exit 2 ;;
    plan)      cmd_plan "${args[@]+"${args[@]}"}" ;;
    backup)    cmd_backup "${args[@]+"${args[@]}"}" ;;
    stop)      cmd_stop ;;
    apply)     cmd_apply "${args[@]+"${args[@]}"}" ;;
    start)     cmd_start ;;
    verify)    cmd_verify "${args[@]+"${args[@]}"}" ;;
    run)       cmd_run "${args[@]+"${args[@]}"}" ;;
    rollback)  cmd_rollback "${args[@]+"${args[@]}"}" ;;
    prune-failed) cmd_prune_failed ;;
    *) die "unknown command $cmd (inspect, plan, preflight, commands, backup, stop, apply, start, verify, rollback, run, prune-failed)" ;;
  esac
}

main "$@"
