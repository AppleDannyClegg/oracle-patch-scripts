#!/usr/bin/env bash
# ohs-patch.sh - check an Oracle HTTP Server home is ready for its bundle patch, and print the exact commands.
# Read-only: it stops nothing, applies nothing and starts nothing. It may unzip the patch into <patch-dir>/extracted.
#
# Commands
#   preflight <patch-dir>   home, layout, domains and OHS components, what runs from the home, OPatch and series
#                           checks, a conflict check, disk for the backup, the node manager credentials; then the
#                           stop / backup / apply / start / verify / rollback commands for this box
#
# Options
#   --oracle-home DIR       the OHS (or WebLogic) home; default: $ORACLE_HOME, then the central inventory
#   --domain-home DIR       the domain holding the OHS components; default: every domain in domain-registry.xml
#   --backup-dir DIR        where the backup goes, for the free-space check (default /u01/backup)
#   --dry-run               accepted for the gates; preflight changes nothing anyway
#   --yes                   accepted for the gates; preflight asks nothing
#
# Exit: 0 ready (warnings may be printed); 1 a blocking problem was found; 2 the check could not be completed
# (a read failed - ps, opatch, config.xml), so "ready" cannot be said.
#
# Why each check (40005842 README, OHS (Native) DB19C Bundle Patch 12.2.1.4.260910):
#   - "Stop all processes associated with ORACLE_HOME, including WLS AdminServer, NodeManager, Managed Server
#     instances, and OHS server instances" -> every process whose command line names the home is listed
#   - "must be applied only to an Oracle Fusion Middleware home where the Oracle Database Client 12c has been
#     upgraded to 19c" (KB585169) -> a DB19C bundle on a home still on the plain bundle line is refused
#   - "ORACLE_HOME must have OPatch version 13.9.4.2.13 or higher" -> the README's minimum against opatch version
#   - "For a complete rollback, restore ORACLE_HOME and CENTRAL INVENTORY from the backups" -> the backup is the
#     rollback, so there must be room for it
#   - startComponent.sh / stopComponent.sh go through the domain's node manager and prompt for its password unless
#     it was stored with 'startComponent.sh <name> storeUserConfig' -> a missing stored config is a blocking problem,
#     because a prompt in the middle of an outage is a hang

set -uo pipefail

ORACLE_HOME_ARG=""; DOMAIN_ARG=""; BACKUP_DIR="/u01/backup"
problems=0; unknowns=0

ts()   { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '%s [INFO ] %s\n' "$(ts)" "$*" >&2; }
warn() { printf '%s [WARN ] %s\n' "$(ts)" "$*" >&2; }
err()  { printf '%s [ERROR] %s\n' "$(ts)" "$*" >&2; }
die()  { err "$*"; exit 2; }
block()   { err "BLOCKING: $*"; problems=$((problems + 1)); }
unknown() { err "UNKNOWN: $*"; unknowns=$((unknowns + 1)); }
optchk() { [ $# -ge 2 ] || die "$1 needs a value"; case "$2" in -[!0-9]*) die "$1 needs a value, got '$2'";; esac; }
usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

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

# every process whose command line names the home; status 1 = ps could not be read (never 'nothing running')
from_home() {
  local l
  l="$(ps -eo pid,args 2>/dev/null)" && [ -n "$(printf '%s' "$l" | tr -d '[:space:]')" ] || return 1
  printf '%s\n' "$l" | grep -F -- "$1/" | grep -v -e 'grep -F' -e 'ohs-patch.sh' || :
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
patch_dirs() {
  local dir="$1" z
  for z in "$dir"/*.zip; do
    [ -f "$z" ] || continue
    mkdir -p "$dir/extracted" || return 1
    unzip -o -q "$z" -d "$dir/extracted" || { err "cannot unzip $z"; return 1; }
  done
  find "$dir" -path '*/etc/config/inventory.xml' 2>/dev/null | sed 's#/etc/config/inventory.xml$##' | sort -u
}

readme_title() { head -5 "$1/README.txt" 2>/dev/null | tr -d '\r' | LC_ALL=C sed 's/[^[:print:]]//g' | grep -m1 -iE 'bundle patch|patch' ; }
readme_min_opatch() {
  LC_ALL=C grep -aoE 'OPatch version 13\.9(\.[0-9]+)+ or (higher|later)' "$1/README.txt" 2>/dev/null | grep -oE '13\.9(\.[0-9]+)+' | sort -V | tail -1
}

# ---- preflight ------------------------------------------------------------------------------------------
cmd_preflight() {
  local pdir="${1:-}"
  [ -n "$pdir" ] || die "preflight needs <patch-dir> (the folder holding the OHS bundle zip)"
  [ -d "$pdir" ] || die "patch dir $pdir does not exist"

  local OH; OH="$(find_home)"
  [ -n "$OH" ] || die "no Oracle HTTP Server home found (no ohs/ under \$ORACLE_HOME or any inventory home) - pass --oracle-home"
  [ -d "$OH/ohs" ] || block "$OH has no ohs/ directory - it is not an OHS home"
  local layout rel; layout="$(layout_of "$OH")"; rel="$(ohs_release "$OH")"
  log "home     : $OH (OHS ${rel:-release unknown}, $layout)"
  [ -n "$rel" ] || warn "the OHS release is not in $OH/inventory/registry.xml - check it by hand"

  # OPatch
  local opv; opv="$(ORACLE_HOME="$OH" "$OH/OPatch/opatch" version 2>/dev/null | sed -n 's/^OPatch Version: *//p' | head -1)"
  [ -n "$opv" ] || unknown "could not read the OPatch version ($OH/OPatch/opatch version)"
  local lsp; if ! lsp="$(ORACLE_HOME="$OH" "$OH/OPatch/opatch" lspatches 2>/dev/null)"; then unknown "opatch lspatches failed - installed patches unknown"; lsp=""; fi
  lsp="$(printf '%s\n' "$lsp" | tr -d '\r' | grep -E '^[0-9]+;' || :)"
  log "OPatch   : ${opv:-unknown}; installed OHS bundle: $(printf '%s\n' "$lsp" | grep -i 'OHS (NATIVE)' | cut -d';' -f2 | head -1)"

  # the patch
  local pds pd id title min
  pds="$(patch_dirs "$pdir")" || die "could not unzip the patch in $pdir"
  [ -n "$pds" ] || die "no patch in $pdir (no p*.zip and no unzipped patch with etc/config/inventory.xml)"
  [ "$(printf '%s\n' "$pds" | grep -c .)" = 1 ] || block "more than one patch in $pdir - put only the OHS bundle there: $(printf '%s ' $pds)"
  pd="$(printf '%s\n' "$pds" | head -1)"; id="$(basename "$pd")"
  title="$(readme_title "$pd")"; min="$(readme_min_opatch "$pd")"
  log "patch    : $id ${title:+- $title}"
  if printf '%s\n' "$lsp" | grep -q "^$id;"; then warn "$id is already installed in $OH - nothing to apply"; fi
  if [ -z "$min" ]; then warn "no 'OPatch version ... or higher' line in $pd/README.txt - check the README by hand"
  elif [ -n "$opv" ] && ! version_ge "$opv" "$min"; then block "OPatch $opv is older than the $min $id's README asks for - apply OPatch 28186730 first"
  else log "OPatch   : $opv meets the README minimum $min"; fi

  # DB19C series (KB585169)
  if printf '%s' "$title" | grep -qi 'DB19C'; then
    if printf '%s\n' "$lsp" | grep -qiE 'OHS \(NATIVE\) DB19C BUNDLE PATCH|DB CLIENT 19C UPGRADE'; then log "series   : home is on the DB19C line"
    elif printf '%s\n' "$lsp" | grep -qi 'OHS (NATIVE) BUNDLE PATCH'; then block "$id is a DB19C bundle but $OH is on the plain OHS bundle line - the Database Client 19c upgrade (KB585169) comes first"
    else warn "no OHS bundle installed yet: confirm $OH had the Database Client 19c upgrade (KB585169) before applying the DB19C bundle $id"; fi
  fi

  # conflicts (read-only OPatch prereq)
  local pre prc
  pre="$(cd "$pd" && ORACLE_HOME="$OH" "$OH/OPatch/opatch" prereq CheckConflictAgainstOHWithDetail -ph . -oh "$OH" 2>&1)"; prc=$?
  # only the 'passed' line is a pass: OPatch prints the header 'Conflicts/Supersets for each patch are:' for a real
  # conflict too, so a 'superset' word in the output is no proof of anything (a superset of an installed bundle passes)
  # the exit status first (Jocasta P3): non-zero is a conflict whatever the wording says
  if [ "$prc" = 0 ] && printf '%s' "$pre" | grep -q 'Prereq "checkConflictAgainstOHWithDetail" passed' && ! printf '%s' "$pre" | grep -qi 'Conflict with'; then
    log "conflicts: none"
    printf '%s' "$pre" | grep -qiE 'superset|subset' && log "  ($id supersedes an installed patch - OPatch rolls the older one back itself)"
  elif [ "$prc" = 0 ] && ! printf '%s' "$pre" | grep -qiE 'Prereq "checkConflictAgainstOHWithDetail" failed|Conflict with' && printf '%s' "$pre" | grep -qiE 'superset|subset'; then
    warn "$id supersedes an installed patch - OPatch rolls the older one back itself"
  else block "conflict check did not pass for $id (rc $prc): $(printf '%s\n' "$pre" | grep -iE 'conflict|error|fail' | head -3 | tr '\n' ' ')"; fi

  # domains, components, node manager credentials
  local doms d comps c dn bin ports cmds_stop="" cmds_start="" cmds_verify="" nmstart=""
  doms="$(domains_of "$OH")"
  [ -n "$doms" ] || block "no domain found for $OH (domain-registry.xml empty or missing) - pass --domain-home"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ -f "$d/config/config.xml" ] || { unknown "$d/config/config.xml is not readable"; continue; }
    comps="$(ohs_components "$d" | tr '\n' ' ' | sed 's/ *$//')"
    dn="$(domain_name "$d")"; bin="$d/bin"
    log "domain   : $d ($dn) - OHS components: ${comps:-none}"
    [ -n "$comps" ] || continue
    for c in $comps; do
      ports="$(instance_ports "$d" "$c")"
      cmds_stop="$cmds_stop  $bin/stopComponent.sh $c"$'\n'
      cmds_start="$cmds_start  $bin/startComponent.sh $c"$'\n'
      for p in $ports; do cmds_verify="$cmds_verify  curl -k -s -o /dev/null -w '%{http_code}\\n' https://localhost:$p/ || curl -s -o /dev/null -w '%{http_code}\\n' http://localhost:$p/   # $c"$'\n'; done
      [ -n "$ports" ] || warn "$c: no Listen port read from its httpd.conf/ssl.conf - check it answers by hand after the start"
    done
    nmstart="$nmstart  nohup $bin/startNodeManager.sh > $d/nodemanager.out 2>&1 &"$'\n'
    if [ -f "$HOME/.wlst/nm-cfg-$dn.props" ] && [ -f "$HOME/.wlst/nm-key-$dn.props" ]; then log "NM creds : stored for $dn"
    else block "no stored node manager credentials for $dn (~/.wlst/nm-cfg-$dn.props): startComponent.sh would prompt mid-outage. Before the window run once, with the node manager up: $bin/startComponent.sh $(printf '%s' "$comps" | head -1) storeUserConfig"; fi
  done <<<"$doms"
  [ -n "$cmds_stop" ] || [ -z "$doms" ] || block "no OHS component (<system-component> with component-type OHS) in any domain of $OH"

  # what runs from the home now
  local procs
  if procs="$(from_home "$OH")"; then
    if [ -n "$procs" ]; then
      log "running from $OH (all must be stopped before the apply):"
      while read -r pid args; do [ -n "$pid" ] && log "  pid $pid  $(kind_of_proc "$args")"; done <<<"$procs"
      if printf '%s\n' "$procs" | grep -q 'weblogic.Server'; then
        warn "WebLogic servers run from this home ($layout): stop them first (wls-patch.sh stop) - this script's commands stop only OHS and node manager"
      fi
    else log "running  : nothing from $OH"; fi
  else unknown "cannot read the process list (ps failed) - cannot say what runs from $OH"; fi

  # disk for the backup: the home + the domains + the central inventory
  local inv need=0 k free
  inv="$(sed -n 's/^inventory_loc=//p' "$OH/oraInst.loc" /etc/oraInst.loc 2>/dev/null | head -1)"
  for k in "$OH" $doms ${inv:+"$inv"}; do
    local s; s="$(du -sk "$k" 2>/dev/null | awk '{print $1}')"
    [ -n "$s" ] || { unknown "cannot size $k for the backup"; continue; }
    need=$((need + s))
  done
  free="$(df -Pk "$BACKUP_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
  if [ -z "$free" ]; then unknown "cannot read free space on $BACKUP_DIR (does it exist?) - pass --backup-dir"
  elif [ "$free" -lt $((need + need / 10)) ]; then block "$BACKUP_DIR has $((free / 1024)) MB free, the backup needs about $((need / 1024)) MB (+10%)"
  else log "backup   : $((need / 1024)) MB needed, $((free / 1024)) MB free on $BACKUP_DIR"; fi

  # ---- the commands for this box ----------------------------------------------------------------------
  local stamp; stamp="$(date '+%Y%m%d-%H%M')"
  {
    echo
    echo "COMMANDS for $OH (as the user that owns it). Run them in order; stop at the first that fails."
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
  } >&2

  echo >&2
  if [ "$unknowns" -gt 0 ]; then err "preflight could not complete: $unknowns check(s) unreadable, $problems blocking - NOT ready"; return 2; fi
  if [ "$problems" -gt 0 ]; then err "$problems blocking problem(s) - NOT ready"; return 1; fi
  log "READY: nothing blocking. Run the commands above in the window."
  return 0
}

main() {
  local cmd="" args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --oracle-home) optchk "$@"; ORACLE_HOME_ARG="$2"; shift 2 ;;
      --domain-home) optchk "$@"; DOMAIN_ARG="$2"; shift 2 ;;
      --backup-dir)  optchk "$@"; BACKUP_DIR="$2"; shift 2 ;;
      --dry-run|--yes) shift ;;
      -h|--help) usage; exit 0 ;;
      -*) die "unknown option $1" ;;
      *) if [ -z "$cmd" ]; then cmd="$1"; else args+=("$1"); fi; shift ;;
    esac
  done
  case "$cmd" in
    preflight) cmd_preflight "${args[@]+"${args[@]}"}" ;;
    "") usage; exit 2 ;;
    *) die "unknown command $cmd (only 'preflight' exists yet)" ;;
  esac
}

main "$@"
