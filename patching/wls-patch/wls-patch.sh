#!/usr/bin/env bash
# wls-patch.sh - version-aware WebLogic / FMW patcher with preflight, backup,
# verification, rollback and self-heal.
#
# Works with any OPatch-based WebLogic (12.1.3, 12.2.1.x, 14.1.1, 14.1.2).
# Detects and refuses BSU-based 10.3.6 / 12.1.1 homes (different tooling).
#
# Usage: wls-patch.sh <command> [args] [options]
#
# Commands
#   inspect [patch-dir]     Detect ORACLE_HOME, version, JDK, OPatch, patches, domains, servers (JSON);
#                           with a patch dir or --latest/--patches it also shows what would be applied
#   plan [patch-dir]        What WOULD be applied: each patch, its description, new/installed, OPatch kit,
#                           JDK advice. Changes nothing (unzips the patch zips only)
#   preflight <patch-dir>   Validate patch zips/dirs, OPatch minimum, conflicts, disk, running servers
#   backup                  Tar ORACLE_HOME + domain homes to BACKUP_DIR
#   stop                    Stop managed servers, admin server, node manager (records what was running)
#   apply <patch-dir>       OPatch-upgrade first if present, then opatch apply each patch
#   start                   Start node manager, admin server, previously-running managed servers
#   verify [patch-dir]      Patches present in inventory, servers up, admin URL answering
#   rollback [id ...]       opatch rollback (last run's patches in reverse, or given ids)
#   restore                 Restore ORACLE_HOME (and optionally domains) from last backup
#   heal                    Diagnose and fix known failure states (stale locks, old OPatch, .lok files...)
#   download <patch-dir> <id ...>
#                           Fetch patches from My Oracle Support into <patch-dir> - only the ones not
#                           already there or already installed; picks the file for this release/platform,
#                           verifies SHA-256, adds the OPatch kit (28186730) if OPatch is too old
#   latest                  Ask My Oracle Support for the newest PSU (and Coherence patch) for THIS
#                           release by name search; prints the patch numbers it would use
#   run <patch-dir>         Full flow: [latest] > [download] > inspect > preflight > backup > stop > apply
#                           > start > verify, automatic rollback (then restore) if apply or verify fails
#
# Options
#   --oracle-home DIR   --domain-home DIR   --java-home DIR   --admin-url URL
#   --backup-dir DIR    --run-dir DIR       --dry-run         --yes
#   --no-backup         --force             --json            --verbose
#   --patches ID,ID,..  (run) download these first if missing      --release 12.2.1.4.0 (download) pick file
#   --latest            (run) look up this quarter's PSU/Coherence numbers on MOS, then download them
#
# Config file (optional): ./wls-patch.conf or ~/.wls-patch.conf, KEY=VALUE lines.
# Every option has an env/config equivalent: ORACLE_HOME, DOMAIN_HOME, JAVA_HOME,
# ADMIN_URL, BACKUP_DIR, RUN_BASE, STOP_CMD, START_CMD, STOP_TIMEOUT, START_TIMEOUT.
# MOS access for latest/download: a bearer token in MOS_TOKEN_FILE (default ~/.mos-token) or MOS_TOKEN, generated at
#   https://updates.oracle.com/Orion/GenToken/get_token while logged in to My Oracle Support (lasts 60 minutes)
# PATCHES=id,id,.. in the config is the default list for 'run --patches'.

set -o pipefail

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Globals / defaults
# ---------------------------------------------------------------------------
DRY_RUN=0
ASSUME_YES=0
NO_BACKUP=0
FORCE=0
JSON_OUT=0
VERBOSE=0
STOP_TIMEOUT="${STOP_TIMEOUT:-180}"
START_TIMEOUT="${START_TIMEOUT:-600}"
RUN_BASE="${RUN_BASE:-$HOME/wls-patch/runs}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/wls-patch/backups}"
RUN_DIR=""
LOG_FILE=""
STATE_FILE=""
MOS_BASE="${MOS_BASE:-https://updates.oracle.com}"
OFFLINE="${OFFLINE:-0}"   # 1: this host has no internet - latest/download refuse at once; stage the zips in the patch dir instead
OPATCH_KIT_BUG="28186730"
PATCHES=""
PICK_RELEASE=""
USE_LATEST=0

WLS_VERSION=""
WLS_FAMILY=""          # opatch | bsu | unknown
OPATCH_VERSION=""
JDK_VERSION=""
PSU_LEVEL=""
INSTALLED_PATCHES=""   # newline separated "id;description"
DOMAINS=""             # newline separated domain homes
ADMIN_SERVER_NAME=""
MANAGED_SERVERS=""     # newline separated "name port"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '%s [INFO ] %s\n' "$(ts)" "$*" | tee -a "${LOG_FILE:-/dev/null}" >&2; }
warn() { printf '%s [WARN ] %s\n' "$(ts)" "$*" | tee -a "${LOG_FILE:-/dev/null}" >&2; }
err()  { printf '%s [ERROR] %s\n' "$(ts)" "$*" | tee -a "${LOG_FILE:-/dev/null}" >&2; }
dbg()  { [ "$VERBOSE" = 1 ] && printf '%s [DEBUG] %s\n' "$(ts)" "$*" >&2; return 0; }
die()  { err "$*"; exit 1; }
optchk() { [ $# -ge 2 ] || die "$1 needs a value"; case "$2" in -[!0-9]*) die "$1 needs a value, got '$2'";; esac; }   # option value present and not another option

# run_cmd: execute (or print under --dry-run), tee output to log, return exit code
run_cmd() {
  log "CMD: $*"
  if [ "$DRY_RUN" = 1 ]; then
    return 0
  fi
  "$@" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"
  return "${PIPESTATUS[0]}"
}

# run_sh: run a shell snippet with stdin/stdout detached, output appended to the log.
# Needed for START_CMD/STOP_CMD and server start scripts: anything they leave running in the
# background must not inherit our pipe, or the script would hang waiting for it.
run_sh() {
  log "CMD: $*"
  [ "$DRY_RUN" = 1 ] && return 0
  bash -c "$*" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1
}

confirm() {
  local prompt="$1"
  if [ "$ASSUME_YES" = 1 ] || [ "$DRY_RUN" = 1 ]; then return 0; fi
  if [ ! -t 0 ]; then
    warn "Non-interactive and --yes not given: refusing '$prompt'"
    return 1
  fi
  read -r -p "$prompt [y/N] " ans
  [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '; }

# version compare: returns 0 if $1 >= $2 (dotted numeric)
version_ge() {
  local a b i
  IFS='.' read -r -a a <<<"$1"
  IFS='.' read -r -a b <<<"$2"
  for ((i = 0; i < ${#b[@]}; i++)); do
    local x="${a[i]:-0}" y="${b[i]:-0}"
    x="${x//[^0-9]/}"; y="${y//[^0-9]/}"
    x="${x:-0}"; y="${y:-0}"
    if ((10#$x > 10#$y)); then return 0; fi
    if ((10#$x < 10#$y)); then return 1; fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# State (so rollback / resume know what happened)
# ---------------------------------------------------------------------------
state_set() {
  [ -z "$STATE_FILE" ] && return 0
  local key="$1" val="$2"
  touch "$STATE_FILE"
  grep -v "^${key}=" "$STATE_FILE" >"$STATE_FILE.tmp" 2>/dev/null || true
  printf '%s=%s\n' "$key" "$val" >>"$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
}
state_get() {
  [ -f "$STATE_FILE" ] || return 1
  sed -n "s/^$1=//p" "$STATE_FILE" | tail -1
}
state_append() { # list values separated by space
  local cur
  cur="$(state_get "$1" || true)"
  state_set "$1" "${cur:+$cur }$2"
}

init_run_dir() {
  local name="${1:-run}"
  if [ -z "$RUN_DIR" ]; then
    RUN_DIR="$RUN_BASE/$(date '+%Y%m%d-%H%M%S')-$name"
  fi
  mkdir -p "$RUN_DIR" || die "Cannot create run dir $RUN_DIR"
  LOG_FILE="$RUN_DIR/wls-patch.log"
  STATE_FILE="$RUN_DIR/state"
  ln -sfn "$RUN_DIR" "$RUN_BASE/latest"
  log "wls-patch $VERSION  run dir: $RUN_DIR  dry-run=$DRY_RUN"
}

latest_run_dir() {
  if [ -L "$RUN_BASE/latest" ]; then readlink "$RUN_BASE/latest"; fi
}

# ---------------------------------------------------------------------------
# Config / discovery
# ---------------------------------------------------------------------------
load_config() {
  local f
  for f in "$SCRIPT_DIR/../../oracle.conf" "$HOME/.oracle.conf" "$SCRIPT_DIR/wls-patch.conf" "./wls-patch.conf" "$HOME/.wls-patch.conf"; do
    if [ -f "$f" ]; then
      dbg "loading config $f"
      set -a
      # shellcheck disable=SC1090
      . "$f"
      set +a
    fi
  done
  # set -a exported every conf variable to every child (java, curl, tar, opatch): a secret in the environment sits in
  # /proc/<pid>/environ and 'ps eww' for the life of each child. Take the secrets back out; the children never read them from there.
  # The name pattern is lib/oracle-lib.sh unexport_secrets, verbatim (one pattern in the tree, not three); the shell's own PWD stays exported
  local v; for v in $(compgen -A variable | grep -E 'PASSWORD|PASSWD|SECRET|_PASS($|_)|TOKEN|PWD|_CONNECT$' | grep -vxE 'PWD|OLDPWD'); do
    # shellcheck disable=SC2163  # the variable NAMED by $v is un-exported, which is the point
    export -n "$v" 2>/dev/null || true
  done
}

discover_oracle_home() {
  [ -n "${ORACLE_HOME:-}" ] && [ -d "$ORACLE_HOME" ] && return 0
  if [ -n "${MW_HOME:-}" ] && [ -d "$MW_HOME" ]; then ORACLE_HOME="$MW_HOME"; return 0; fi
  # central inventory pointer
  local inv_loc inv_dir homes
  for inv_loc in /etc/oraInst.loc /var/opt/oracle/oraInst.loc "$HOME/oraInst.loc"; do
    [ -f "$inv_loc" ] || continue
    inv_dir="$(sed -n 's/^inventory_loc=//p' "$inv_loc")"
    [ -f "$inv_dir/ContentsXML/inventory.xml" ] || continue
    homes="$(sed -n 's/.*<HOME NAME="[^"]*" LOC="\([^"]*\)".*/\1/p' "$inv_dir/ContentsXML/inventory.xml")"
    for h in $homes; do
      if [ -d "$h/wlserver" ] || [ -x "$h/OPatch/opatch" ]; then ORACLE_HOME="$h"; return 0; fi
    done
  done
  # common locations
  local guess
  for guess in /u01/app/oracle/product/*/fmw* /u01/app/oracle/middleware* /u01/oracle/* /opt/oracle/* /opt/oracle/product/* "$HOME"/Oracle/Middleware*; do
    if [ -d "$guess/wlserver" ]; then ORACLE_HOME="$guess"; return 0; fi
  done
  return 1
}

discover_java_home() {
  [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ] && return 0
  local f
  local f="$ORACLE_HOME/oui/.globalEnv.properties"
  if [ -f "$f" ]; then
    JAVA_HOME="$(sed -n 's/^JAVA_HOME=//p' "$f" | head -1)"
    [ -x "${JAVA_HOME:-/nonexistent}/bin/java" ] && return 0
  fi
  if [ -f "$ORACLE_HOME/oracle_common/common/bin/commEnv.sh" ]; then
    JAVA_HOME="$(grep -E '^\s*JAVA_HOME=' "$ORACLE_HOME/oracle_common/common/bin/commEnv.sh" | head -1 | sed 's/.*JAVA_HOME=//; s/"//g')"
    [ -x "${JAVA_HOME:-/nonexistent}/bin/java" ] && return 0
  fi
  if command -v java >/dev/null 2>&1; then
    JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
    return 0
  fi
  JAVA_HOME=""
  return 1
}

detect_versions() {
  WLS_FAMILY="unknown"
  if [ -x "$ORACLE_HOME/OPatch/opatch" ]; then
    WLS_FAMILY="opatch"
  elif [ -x "$ORACLE_HOME/utils/bsu/bsu.sh" ]; then
    WLS_FAMILY="bsu"
  fi

  # WebLogic version from registry.xml (most reliable, no JVM needed)
  if [ -f "$ORACLE_HOME/inventory/registry.xml" ]; then
    WLS_VERSION="$(sed -n 's/.*name="WebLogic Server"[^>]*version="\([0-9.]*\)".*/\1/p' "$ORACLE_HOME/inventory/registry.xml" | head -1)"
    [ -z "$WLS_VERSION" ] && WLS_VERSION="$(grep -o 'version="[0-9.]*"' "$ORACLE_HOME/inventory/registry.xml" | head -1 | cut -d'"' -f2)"
  fi
  if [ -z "$WLS_VERSION" ] && [ -f "$ORACLE_HOME/wlserver/.product.properties" ]; then
    WLS_VERSION="$(sed -n 's/^WLS_PRODUCT_VERSION=//p' "$ORACLE_HOME/wlserver/.product.properties")"
  fi
  if [ -z "$WLS_VERSION" ] && [ -f "$ORACLE_HOME/registry.xml" ]; then # 10.3.6 style
    WLS_VERSION="$(sed -n 's/.*name="WebLogic Server"[^>]*version="\([0-9.]*\)".*/\1/p' "$ORACLE_HOME/registry.xml" | head -1)"
  fi

  if [ "$WLS_FAMILY" = opatch ]; then
    OPATCH_VERSION="$("$ORACLE_HOME/OPatch/opatch" version 2>/dev/null | sed -n 's/^OPatch Version: *//p' | head -1)"
    INSTALLED_PATCHES="$("$ORACLE_HOME/OPatch/opatch" lspatches 2>/dev/null | grep -E '^[0-9]+;' || true)"
    PSU_LEVEL="$(printf '%s\n' "$INSTALLED_PATCHES" | grep -i 'WLS PATCH SET UPDATE' | sed -n 's/.*UPDATE *\([0-9.]*\).*/\1/p' | sort -V | tail -1)"
  fi

  if [ -n "$JAVA_HOME" ] && [ -x "$JAVA_HOME/bin/java" ]; then
    JDK_VERSION="$("$JAVA_HOME/bin/java" -version 2>&1 | head -1 | sed -n 's/.*version "\([^"]*\)".*/\1/p')"
  fi
}

discover_domains() {
  DOMAINS=""
  if [ -n "${DOMAIN_HOME:-}" ] && [ -f "$DOMAIN_HOME/config/config.xml" ]; then
    DOMAINS="$DOMAIN_HOME"
  fi
  if [ -f "$ORACLE_HOME/domain-registry.xml" ]; then
    local d
    while read -r d; do
      [ -z "$d" ] && continue
      [ -f "$d/config/config.xml" ] || continue
      printf '%s\n' "$DOMAINS" | grep -qx "$d" || DOMAINS="${DOMAINS:+$DOMAINS$'\n'}$d"
    done < <(sed -n 's/.*<domain location="\([^"]*\)".*/\1/p' "$ORACLE_HOME/domain-registry.xml")
  fi
  if [ -z "$DOMAINS" ]; then
    local d
    for d in "$ORACLE_HOME"/user_projects/domains/*; do
      [ -f "$d/config/config.xml" ] && DOMAINS="${DOMAINS:+$DOMAINS$'\n'}$d"
    done
  fi
  if [ -z "${DOMAIN_HOME:-}" ]; then DOMAIN_HOME="$(printf '%s\n' "$DOMAINS" | head -1)"; fi
}

# parse servers from config.xml: name + listen port; admin server name
parse_domain_servers() {
  local cfg="$1/config/config.xml"
  [ -f "$cfg" ] || return 1
  ADMIN_SERVER_NAME="$(sed -n 's/.*<admin-server-name>\([^<]*\)<.*/\1/p' "$cfg" | head -1)"
  [ -z "$ADMIN_SERVER_NAME" ] && ADMIN_SERVER_NAME="AdminServer"
  # crude but dependency-free: walk <server> blocks
  MANAGED_SERVERS="$(awk '
    /<server>/ {inblk=1; inssl=0; name=""; port=""}
    inblk && /<ssl>/ {inssl=1}
    inblk && /<\/ssl>/ {inssl=0}
    inblk && name=="" && match($0,/<name>[^<]*<\/name>/) {name=substr($0,RSTART+6,RLENGTH-13)}
    inblk && !inssl && port=="" && match($0,/<listen-port>[^<]*<\/listen-port>/) {port=substr($0,RSTART+13,RLENGTH-27)}
    inblk && /<\/server>/ {inblk=0; if (name!="") print name, (port==""?"7001":port)}
  ' "$cfg")"
}

running_servers() { # prints "name pid" - only real JVMs (first arg ends in java), not shells mentioning the words
  ps -eo pid,args 2>/dev/null | grep -E '^ *[0-9]+ +[^ ]*java .*-Dweblogic\.Name=[^ ]+ .*weblogic\.Server' \
    | sed -n 's/^ *\([0-9]*\) .*-Dweblogic\.Name=\([^ ]*\).*/\2 \1/p'
}
nodemanager_pid() { ps -eo pid,args 2>/dev/null | grep -E '^ *[0-9]+ +[^ ]*java .*weblogic\.NodeManager' | awk '{print $1}' | head -1; }
opatch_running() { pgrep -f 'oracle.opatch.OPatch|OPatch/opatch' >/dev/null 2>&1; }

setup_env() {
  discover_oracle_home || die "Cannot find ORACLE_HOME. Pass --oracle-home or set ORACLE_HOME in wls-patch.conf"
  export ORACLE_HOME
  discover_java_home || warn "No JDK found. OPatch needs one: pass --java-home"
  export JAVA_HOME
  detect_versions
  discover_domains
  [ -n "$DOMAIN_HOME" ] && parse_domain_servers "$DOMAIN_HOME"
  if [ -z "${ADMIN_URL:-}" ] && [ -n "$MANAGED_SERVERS" ]; then
    local aport
    aport="$(printf '%s\n' "$MANAGED_SERVERS" | awk -v a="$ADMIN_SERVER_NAME" '$1==a {print $2}')"
    ADMIN_URL="http://localhost:${aport:-7001}/console"
  fi
}

opatch() {
  local jdk=()
  [ -n "$JAVA_HOME" ] && jdk=(-jdk "$JAVA_HOME")
  run_cmd "$ORACLE_HOME/OPatch/opatch" "$@" "${jdk[@]}" -oh "$ORACLE_HOME"
}

# ---------------------------------------------------------------------------
# inspect
# ---------------------------------------------------------------------------
cmd_inspect() {
  setup_env
  local running nm
  running="$(running_servers)"
  nm="$(nodemanager_pid)"
  local lock="no"
  [ -e "$ORACLE_HOME/.patch_storage/patch_locked" ] && lock="yes"
  local free_kb
  free_kb="$(df -Pk "$ORACLE_HOME" | awk 'NR==2 {print $4}')"

  if [ "$JSON_OUT" = 1 ]; then
    printf '{\n'
    printf '  "oracle_home": "%s",\n' "$(json_escape "$ORACLE_HOME")"
    printf '  "patch_tool": "%s",\n' "$WLS_FAMILY"
    printf '  "wls_version": "%s",\n' "$WLS_VERSION"
    printf '  "psu_level": "%s",\n' "$PSU_LEVEL"
    printf '  "opatch_version": "%s",\n' "$OPATCH_VERSION"
    printf '  "java_home": "%s",\n' "$(json_escape "$JAVA_HOME")"
    printf '  "jdk_version": "%s",\n' "$JDK_VERSION"
    printf '  "opatch_lock_present": %s,\n' "$([ "$lock" = yes ] && echo true || echo false)"
    printf '  "free_kb_oracle_home": %s,\n' "${free_kb:-0}"
    printf '  "domains": ['
    local first=1 d
    while read -r d; do [ -z "$d" ] && continue; [ $first = 1 ] || printf ', '; first=0; printf '"%s"' "$(json_escape "$d")"; done <<<"$DOMAINS"
    printf '],\n'
    printf '  "domain_home": "%s",\n' "$(json_escape "$DOMAIN_HOME")"
    printf '  "admin_server": "%s",\n' "$ADMIN_SERVER_NAME"
    printf '  "admin_url": "%s",\n' "$ADMIN_URL"
    printf '  "servers": ['
    first=1
    while read -r n p; do [ -z "$n" ] && continue; [ $first = 1 ] || printf ', '; first=0; printf '{"name": "%s", "port": %s}' "$n" "${p:-0}"; done <<<"$MANAGED_SERVERS"
    printf '],\n'
    printf '  "running_servers": ['
    first=1
    while read -r n p; do [ -z "$n" ] && continue; [ $first = 1 ] || printf ', '; first=0; printf '{"name": "%s", "pid": %s}' "$n" "$p"; done <<<"$running"
    printf '],\n'
    printf '  "node_manager_pid": %s,\n' "${nm:-null}"
    printf '  "installed_patches": ['
    first=1
    while IFS=';' read -r id desc; do [ -z "$id" ] && continue; [ $first = 1 ] || printf ', '; first=0; printf '{"id": "%s", "description": "%s"}' "$id" "$(json_escape "$desc")"; done <<<"$INSTALLED_PATCHES"
    printf ']\n}\n'
  else
    cat <<EOF
ORACLE_HOME      : $ORACLE_HOME
Patch tool       : $WLS_FAMILY
WebLogic version : ${WLS_VERSION:-unknown}
PSU level        : ${PSU_LEVEL:-none detected}
OPatch version   : ${OPATCH_VERSION:-n/a}
JAVA_HOME        : ${JAVA_HOME:-none}  (${JDK_VERSION:-?})
OPatch lock file : $lock
Free space       : $((free_kb / 1024)) MB on ORACLE_HOME filesystem
Domains          :
$(printf '%s\n' "$DOMAINS" | sed 's/^/  /')
Domain in use    : ${DOMAIN_HOME:-none}
Admin server     : $ADMIN_SERVER_NAME  ($ADMIN_URL)
Configured servers:
$(printf '%s\n' "$MANAGED_SERVERS" | sed 's/^/  /')
Running servers  :
$(printf '%s\n' "${running:-  (none)}" | sed 's/^/  /')
Node manager pid : ${nm:-not running}
Installed patches:
$(printf '%s\n' "${INSTALLED_PATCHES:-  (none)}" | sed 's/^/  /')
EOF
  fi
  [ "$WLS_FAMILY" = bsu ] && warn "This is a BSU-era WebLogic (10.3.x/12.1.1). This script only automates OPatch homes."
  if [ -n "${1:-}" ] || [ "$USE_LATEST" = 1 ] || [ -n "$PATCHES" ]; then cmd_plan "${1:-}"
  elif [ "$JSON_OUT" = 0 ]; then echo; echo "To see what would be applied:  ./wls-patch.sh plan <patch-dir>   or   ./wls-patch.sh plan --latest"; fi
  return 0
}

# ---------------------------------------------------------------------------
# patch directory handling
# ---------------------------------------------------------------------------
# Unzips any *.zip in the patch dir into <patch-dir>/extracted and lists patch dirs
# (dirs that contain etc/config/inventory.xml). Prints: id|path|kind
prepare_patch_dir() {
  local pdir="$1"
  [ -d "$pdir" ] || die "Patch dir not found: $pdir"
  local ext="$pdir/extracted"
  mkdir -p "$ext"
  local z
  for z in "$pdir"/*.zip; do
    [ -f "$z" ] || continue
    local marker
    marker="$ext/.done-$(basename "$z")"
    if [ ! -f "$marker" ]; then
      log "Unzipping $(basename "$z")"
      if [ "$DRY_RUN" = 1 ]; then continue; fi
      unzip -oq "$z" -d "$ext" >>"$LOG_FILE" 2>&1 || die "unzip failed for $z (corrupt download?)"
      touch "$marker"
    fi
  done
  # OPatch upgrade kit
  local j
  for j in "$ext"/*/opatch_generic.jar "$ext"/opatch_generic.jar; do
    [ -f "$j" ] && printf 'OPATCH|%s|opatch-upgrade\n' "$(dirname "$j")"
  done
  # ordinary patches
  local inv
  while read -r inv; do
    [ -z "$inv" ] && continue
    local p
    p="$(cd "$(dirname "$inv")/../.." && pwd)"
    printf '%s|%s|patch\n' "$(basename "$p")" "$p"
  done < <(find "$ext" -maxdepth 4 -path '*/etc/config/inventory.xml' 2>/dev/null | sort)
}

patch_description() {
  local p="$1"
  [ -f "$p/README.txt" ] && grep -m1 -iE 'Patch [0-9]+|BUNDLE|PATCH SET UPDATE' "$p/README.txt" | sed 's/^ *//'
}

patch_min_opatch() {
  local p="$1"
  [ -f "$p/README.txt" ] || return 1
  grep -oE 'OPatch (utility )?(version )?[0-9]+(\.[0-9]+){2,5}' "$p/README.txt" | grep -oE '[0-9]+(\.[0-9]+){2,5}' | sort -V | tail -1
}

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------
cmd_preflight() {
  local pdir="$1"
  [ -n "$pdir" ] || die "preflight needs <patch-dir>"
  setup_env
  [ -n "$RUN_DIR" ] || init_run_dir preflight
  local problems=0

  if [ "$WLS_FAMILY" != opatch ]; then
    err "Not an OPatch home (family=$WLS_FAMILY). Cannot continue."
    return 2
  fi
  [ -n "$JAVA_HOME" ] || { err "No JDK. OPatch cannot run."; problems=$((problems + 1)); }

  local list
  list="$(prepare_patch_dir "$pdir")"
  [ -n "$list" ] || { err "No patches found in $pdir (expected *.zip from My Oracle Support)"; return 2; }
  log "Patches found:"
  printf '%s\n' "$list" | tee -a "$LOG_FILE" >&2

  local has_opatch_upgrade=0 required_opatch=""
  local id path kind
  while IFS='|' read -r id path kind; do
    [ "$kind" = opatch-upgrade ] && has_opatch_upgrade=1
    [ "$kind" = patch ] || continue
    local min
    min="$(patch_min_opatch "$path" || true)"
    [ -n "$min" ] && { [ -z "$required_opatch" ] || version_ge "$min" "$required_opatch"; } && required_opatch="$min"
    # already installed?
    if printf '%s\n' "$INSTALLED_PATCHES" | grep -q "^$id;"; then
      warn "Patch $id is already installed - it will be skipped"
    fi
    # platform/version sanity from README
    if [ -f "$path/README.txt" ] && [ -n "$WLS_VERSION" ]; then
      local short="${WLS_VERSION%.*}"   # 12.2.1.4.0 -> 12.2.1.4
      local mentioned
      mentioned="$(grep -oE '\b(12\.1\.[23]|12\.2\.1\.[0-9]|14\.1\.[12])(\.[0-9])?\b' "$path/README.txt" | sed -E 's/^(12\.2\.1\.[0-9]|12\.1\.[23]|14\.1\.[12])\.[0-9]$/\1/; s/^(12\.1\.[23]|14\.1\.[12])$/&.0/' | sort -u | tr '\n' ' ')"
      if [ -n "$mentioned" ] && ! printf ' %s ' "$mentioned" | grep -q " $short "; then
        err "Patch $id is for WebLogic $mentioned- this home is $short. Wrong download."
        problems=$((problems + 1))
      elif [ -z "$mentioned" ]; then
        warn "Patch $id README names no WebLogic release - make sure it is for $short"
      fi
    fi
  done <<<"$list"

  if [ -n "$required_opatch" ]; then
    log "Highest OPatch required by patch READMEs: $required_opatch (installed: ${OPATCH_VERSION:-?})"
    if [ -n "$OPATCH_VERSION" ] && ! version_ge "$OPATCH_VERSION" "$required_opatch"; then
      if [ $has_opatch_upgrade = 1 ]; then
        warn "OPatch too old but an OPatch upgrade kit is present - apply will install it first"
      else
        err "OPatch $OPATCH_VERSION < required $required_opatch. Download the OPatch 13.9.4.x kit (patch 28186730) into $pdir"
        problems=$((problems + 1))
      fi
    fi
  fi

  # JDK / WebLogic pairing (OPatch runs on the same JDK, so a wrong one breaks the patch itself)
  local jmaj="${JDK_VERSION%%.*}"            # 1.8.0_391 -> 1 ; 17.0.9 -> 17 ; 11.0.21 -> 11
  [ "$jmaj" = 1 ] && jmaj="${JDK_VERSION#1.}" && jmaj="${jmaj%%.*}"   # 1.8.0_391 -> 8
  if [ -n "$jmaj" ]; then
    case "$WLS_VERSION" in
      12.1.3*|12.2.1.[0-3]*) [ "$jmaj" = 8 ] || { err "WebLogic $WLS_VERSION needs JDK 8, found $JDK_VERSION at $JAVA_HOME (use --java-home)"; problems=$((problems + 1)); } ;;
      12.2.1.4*) [ "$jmaj" = 8 ] || { err "WebLogic 12.2.1.4 needs JDK 8, found $JDK_VERSION at $JAVA_HOME (use --java-home)"; problems=$((problems + 1)); } ;;
      14.1.1*)   [ "$jmaj" = 8 ] || [ "$jmaj" = 11 ] || { err "WebLogic 14.1.1 needs JDK 8 or 11, found $JDK_VERSION at $JAVA_HOME (use --java-home)"; problems=$((problems + 1)); } ;;
      14.1.2*)   [ "$jmaj" = 17 ] || [ "$jmaj" = 21 ] || { err "WebLogic 14.1.2 needs JDK 17 or 21, found $JDK_VERSION at $JAVA_HOME (use --java-home)"; problems=$((problems + 1)); } ;;
    esac
  fi

  # lock file
  if [ -e "$ORACLE_HOME/.patch_storage/patch_locked" ]; then
    if opatch_running; then
      err "Another OPatch is running - wait for it"; problems=$((problems + 1))
    else
      warn "Stale OPatch lock file present (no opatch process). 'heal' will remove it."
    fi
  fi

  # disk space: need roughly 3x the patch payload plus 2GB headroom
  local need_kb free_kb
  need_kb="$(du -sk "$pdir" 2>/dev/null | awk '{print $1*3 + 2097152}')"
  free_kb="$(df -Pk "$ORACLE_HOME" | awk 'NR==2 {print $4}')"
  # an unreadable size is a failed check, not a passed one: need_kb empty (du failed on the patch dir) made the comparison '0 -lt 0'
  if [ -z "$need_kb" ] || [ -z "$free_kb" ]; then
    err "cannot run the disk space check: $([ -n "$need_kb" ] || echo "du failed on $pdir; ")$([ -n "$free_kb" ] || echo "df failed on $ORACLE_HOME")"
    problems=$((problems + 1))
  elif [ "$free_kb" -lt "$need_kb" ]; then
    err "Low disk: $((free_kb / 1024)) MB free, want >= $((need_kb / 1024)) MB on ORACLE_HOME filesystem"
    problems=$((problems + 1))
  else
    log "Disk OK: $((free_kb / 1024)) MB free"
  fi

  # inventory pointer
  if [ ! -f /etc/oraInst.loc ] && [ ! -f "$ORACLE_HOME/oraInst.loc" ] && [ ! -f /var/opt/oracle/oraInst.loc ]; then
    warn "No oraInst.loc found - OPatch may fail to locate the central inventory ('heal' can create one)"
  fi

  # running servers
  local running nm
  running="$(running_servers)"
  nm="$(nodemanager_pid)"
  if [ -n "$running" ]; then
    warn "WebLogic servers are running - they must be stopped before apply:"
    printf '%s\n' "$running" | sed 's/^/  /' >&2
  fi

  # conflicts (skip the OPatch kit itself)
  while IFS='|' read -r id path kind; do
    [ "$kind" = patch ] || continue
    printf '%s\n' "$INSTALLED_PATCHES" | grep -q "^$id;" && continue
    log "Conflict check for $id"
    local out rc
    out="$(cd "$path" && "$ORACLE_HOME/OPatch/opatch" prereq CheckConflictAgainstOHWithDetail -ph . ${JAVA_HOME:+-jdk "$JAVA_HOME"} -oh "$ORACLE_HOME" 2>&1)"
    rc=$?
    printf '%s\n' "$out" >>"$LOG_FILE"
    if [ "$DRY_RUN" = 1 ]; then continue; fi
    if printf '%s' "$out" | grep -q 'Prereq "checkConflictAgainstOHWithDetail" passed'; then
      log "  no conflicts"
    elif printf '%s' "$out" | grep -qiE 'subset|superset'; then
      warn "  $id supersedes / is superseded by an installed patch - OPatch will handle the subset rollback automatically:"
      printf '%s\n' "$out" | grep -iE 'subset|superset|Patch [0-9]+' | head -10 | sed 's/^/    /' >&2
    else
      err "  CONFLICT for $id (rc=$rc). Needs a decision (merge patch from Oracle or rollback the conflicting patch):"
      printf '%s\n' "$out" | grep -iE 'conflict|Patch [0-9]+|error' | head -15 | sed 's/^/    /' >&2
      problems=$((problems + 1))
    fi
  done <<<"$list"

  # ---- plain-English plan -------------------------------------------------
  {
    echo
    echo "PLAN"
    echo "  Environment : WebLogic ${WLS_VERSION:-?}  PSU ${PSU_LEVEL:-none}  OPatch ${OPATCH_VERSION:-?}  JDK ${JDK_VERSION:-?}"
    echo "  Will stop   : $(running_servers | awk '{print $1}' | tr '\n' ' ')${nm:+(+ node manager)}"
    echo "  Patches     :"
    while IFS='|' read -r id path kind; do
      if [ "$kind" = opatch-upgrade ]; then echo "    OPatch upgrade kit            [install first]"; continue; fi
      local st="new"
      printf '%s\n' "$INSTALLED_PATCHES" | grep -q "^$id;" && st="already installed, skip"
      echo "    $id  $(patch_description "$path" | cut -c1-70)  [$st]"
    done <<<"$list"
    echo "  Advice      :"
    if ! printf '%s\n' "$list" | grep -qi 'PATCH SET UPDATE' && ! grep -qil 'PATCH SET UPDATE' "$pdir"/extracted/*/README.txt 2>/dev/null; then
      echo "    - No WLS Patch Set Update (PSU) in this folder. A quarterly CPU normally includes one; check you downloaded it."
    fi
    if grep -qi 'coherence' "$ORACLE_HOME/inventory/registry.xml" 2>/dev/null && ! grep -qil 'coherence' "$pdir"/extracted/*/README.txt 2>/dev/null; then
      echo "    - Coherence is installed but no Coherence patch is in the folder. The CPU usually ships one; download it if the advisory lists it."
    fi
    case "$WLS_VERSION" in
      12.2.1.4*) echo "    - 12.2.1.4 runs on JDK 8. Oracle expects the JDK updated to the CPU's JDK 8 release too (separate download, not handled here)." ;;
      14.1.1*)   echo "    - 14.1.1 runs on JDK 8 or 11. Update the JDK to the CPU's release too (separate download, not handled here)." ;;
      14.1.2*)   echo "    - 14.1.2 runs on JDK 17 or 21. Update the JDK to the CPU's release too (separate download, not handled here)." ;;
      12.2.1.3*|12.1.3*) echo "    - $WLS_VERSION is out of error-correction support; patches may no longer be published. Plan an upgrade." ;;
    esac
    if [ "$problems" -gt 0 ]; then
      echo "    - $problems blocking problem(s) above must be fixed before 'run' will do anything."
    else
      echo "    - Nothing blocking. 'run' will: backup -> stop -> apply -> start -> verify, and roll back by itself if anything fails."
    fi
  } | tee -a "$LOG_FILE" >&2
  printf '%s\n' "$list" >"$RUN_DIR/patch-list"
  state_set patch_dir "$pdir"
  state_set preflight_problems "$problems"
  if [ "$problems" -gt 0 ]; then
    err "Preflight found $problems blocking problem(s)"
    return 1
  fi
  log "Preflight passed"
  return 0
}

# ---------------------------------------------------------------------------
# backup / restore
# ---------------------------------------------------------------------------
cmd_backup() {
  setup_env
  [ -n "$RUN_DIR" ] || init_run_dir backup
  local stamp dest
  stamp="$(date '+%Y%m%d-%H%M%S')"
  dest="$BACKUP_DIR/$stamp"
  if [ "$DRY_RUN" = 1 ]; then log "dry-run: would back up $ORACLE_HOME and domains to $dest"; return 0; fi
  mkdir -p "$dest" || die "Cannot create $dest"
  log "Backing up ORACLE_HOME to $dest/oracle_home.tar.gz (this takes a while)"
  run_cmd tar -czf "$dest/oracle_home.tar.gz" -C "$(dirname "$ORACLE_HOME")" \
    --exclude='*/logs/*' --exclude='*.log' "$(basename "$ORACLE_HOME")" \
    || die "ORACLE_HOME backup failed - not safe to continue"
  local d i=0
  while read -r d; do
    [ -z "$d" ] && continue
    i=$((i + 1))
    log "Backing up domain $d"
    run_cmd tar -czf "$dest/domain-$i.tar.gz" -C "$(dirname "$d")" \
      --exclude='*/servers/*/logs/*' --exclude='*/servers/*/tmp/*' --exclude='*/servers/*/cache/*' \
      "$(basename "$d")" || die "Domain backup failed for $d"
    printf '%s\n' "$d" >>"$dest/domains.txt"
  done <<<"$DOMAINS"
  printf '%s\n' "$ORACLE_HOME" >"$dest/oracle_home.txt"
  ln -sfn "$dest" "$BACKUP_DIR/latest"
  state_set backup_dir "$dest"
  log "Backup complete: $dest"
}

cmd_restore() {
  setup_env
  [ -n "$RUN_DIR" ] || { RUN_DIR="$(latest_run_dir)"; [ -n "$RUN_DIR" ] && init_run_dir || init_run_dir restore; }
  local src="${1:-$(state_get backup_dir || readlink "$BACKUP_DIR/latest" 2>/dev/null)}"
  [ -d "$src" ] && [ -f "$src/oracle_home.tar.gz" ] || die "No backup to restore (looked at $src)"
  local oh
  oh="$(cat "$src/oracle_home.txt")"
  [ "$oh" = "$ORACLE_HOME" ] || die "Backup is for $oh but ORACLE_HOME is $ORACLE_HOME"
  if [ -n "$(running_servers)" ]; then
    warn "Servers running - stopping them first"; cmd_stop || die "Could not stop servers"
  fi
  confirm "Replace $ORACLE_HOME with backup $src?" || return 1
  local aside
  aside="$ORACLE_HOME.broken-$(date '+%Y%m%d-%H%M%S')"
  log "Moving $ORACLE_HOME aside to $aside"
  run_cmd mv "$ORACLE_HOME" "$aside" || die "mv failed"
  run_cmd tar -xzf "$src/oracle_home.tar.gz" -C "$(dirname "$ORACLE_HOME")" || die "Restore failed - old home is at $aside"
  log "ORACLE_HOME restored. Broken copy kept at $aside (delete it when happy)"
  if [ -f "$src/domains.txt" ] && confirm "Also restore domain directories from backup?"; then
    local d i=0
    while read -r d; do
      i=$((i + 1))
      run_cmd mv "$d" "$d.broken-$(date '+%Y%m%d-%H%M%S')"
      run_cmd tar -xzf "$src/domain-$i.tar.gz" -C "$(dirname "$d")" || die "Domain restore failed for $d"
    done <"$src/domains.txt"
  fi
  state_set restored_from "$src"
}

# ---------------------------------------------------------------------------
# stop / start
# ---------------------------------------------------------------------------
wait_for_gone() { # name pid timeout
  local pid="$1" t="$2"
  while [ "$t" -gt 0 ] && kill -0 "$pid" 2>/dev/null; do sleep 5; t=$((t - 5)); done
  ! kill -0 "$pid" 2>/dev/null
}

cmd_stop() {
  setup_env
  [ -n "$RUN_DIR" ] || init_run_dir stop
  local running
  running="$(running_servers)"
  local nm
  nm="$(nodemanager_pid)"
  state_set servers_were_running "$(printf '%s\n' "$running" | awk '{print $1}' | tr '\n' ' ')"
  state_set nm_was_running "$([ -n "$nm" ] && echo 1 || echo 0)"
  if [ -z "$running" ] && [ -z "$nm" ]; then log "Nothing running"; return 0; fi

  if [ -n "${STOP_CMD:-}" ]; then
    log "Using STOP_CMD"
    run_sh "$STOP_CMD" || warn "STOP_CMD returned non-zero"
  else
    local bin="$DOMAIN_HOME/bin"
    local n p
    # managed servers first
    while read -r n p; do
      [ -z "$n" ] || [ "$n" = "$ADMIN_SERVER_NAME" ] && continue
      if [ -x "$bin/stopManagedWebLogic.sh" ]; then
        log "Stopping managed server $n"
        run_sh "cd '$bin' && ./stopManagedWebLogic.sh '$n' '${ADMIN_URL%/console}'" || warn "stopManagedWebLogic $n returned non-zero"
      fi
    done <<<"$running"
    # admin
    if printf '%s\n' "$running" | awk '{print $1}' | grep -qx "$ADMIN_SERVER_NAME" && [ -x "$bin/stopWebLogic.sh" ]; then
      log "Stopping admin server $ADMIN_SERVER_NAME"
      run_sh "cd '$bin' && ./stopWebLogic.sh" || warn "stopWebLogic returned non-zero"
    fi
    if [ -n "$nm" ] && [ -x "$bin/stopNodeManager.sh" ]; then
      log "Stopping node manager"
      run_sh "cd '$bin' && ./stopNodeManager.sh" || true
    fi
  fi
  [ "$DRY_RUN" = 1 ] && return 0

  # wait, then escalate
  local n p ok=1
  while read -r n p; do
    [ -z "$n" ] && continue
    if ! wait_for_gone "$p" "$STOP_TIMEOUT"; then
      warn "$n (pid $p) did not stop in ${STOP_TIMEOUT}s"
      if [ "$FORCE" = 1 ]; then warn "Killing $n"; kill "$p" 2>/dev/null; sleep 10; kill -9 "$p" 2>/dev/null; else ok=0; fi
    fi
  done <<<"$running"
  if [ -n "$nm" ] && ! wait_for_gone "$nm" 60; then
    if [ "$FORCE" = 1 ]; then kill "$nm" 2>/dev/null; else warn "Node manager still running"; ok=0; fi
  fi
  # second proof, from ps by name: a server the NodeManager restarted under a new pid while we waited, or a stop script that
  # returned with its server still up, is not stopped even though the pid we noted is gone
  local still; still="$(running_servers | awk '{print $1}' | tr '\n' ' ')"
  [ -n "$still" ] && { err "still running after stop: $still"; ok=0; }
  if [ $ok = 0 ]; then err "Some processes still running. Re-run with --force to kill them."; return 1; fi
  log "All WebLogic processes stopped"
}

wait_for_url() { # url timeout
  local url="$1" t="$2" code
  command -v curl >/dev/null || { warn "curl not available, skipping URL wait"; return 0; }
  while [ "$t" -gt 0 ]; do
    code="$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" || true)"
    case "$code" in 200|302|301|401|403) return 0 ;; esac
    sleep 10; t=$((t - 10))
  done
  return 1
}

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

cmd_start() {
  setup_env
  [ -n "$RUN_DIR" ] || { RUN_DIR="$(latest_run_dir)"; [ -n "$RUN_DIR" ] && init_run_dir || init_run_dir start; }
  local want nm_want
  want="$(state_get servers_were_running || true)"
  nm_want="$(state_get nm_was_running || echo 0)"
  if [ -z "$want" ]; then
    want="$ADMIN_SERVER_NAME $(printf '%s\n' "$MANAGED_SERVERS" | awk -v a="$ADMIN_SERVER_NAME" '$1!=a {print $1}' | tr '\n' ' ')"
    warn "No record of what was running; starting everything in the domain: $want"
  fi

  if [ -n "${START_CMD:-}" ]; then
    log "Using START_CMD"
    run_sh "$START_CMD" || warn "START_CMD returned non-zero"
  else
    local bin="$DOMAIN_HOME/bin"
    if [ "$nm_want" = 1 ] && [ -x "$bin/startNodeManager.sh" ] && [ -z "$(nodemanager_pid)" ]; then
      log "Starting node manager"
      run_sh "cd '$bin' && nohup ./startNodeManager.sh >'$DOMAIN_HOME/nodemanager.out' 2>&1 &"
    fi
    if printf ' %s ' "$want" | grep -q " $ADMIN_SERVER_NAME "; then
      log "Starting admin server $ADMIN_SERVER_NAME"
      run_sh "cd '$bin' && nohup ./startWebLogic.sh >'$DOMAIN_HOME/${ADMIN_SERVER_NAME}.out' 2>&1 &"
      [ "$DRY_RUN" = 1 ] || wait_for_url "$ADMIN_URL" "$START_TIMEOUT" || { err "Admin server not answering at $ADMIN_URL after ${START_TIMEOUT}s"; return 1; }
      log "Admin server is up"
    fi
    local n
    for n in $want; do
      [ "$n" = "$ADMIN_SERVER_NAME" ] && continue
      log "Starting managed server $n"
      run_sh "cd '$bin' && nohup ./startManagedWebLogic.sh '$n' '${ADMIN_URL%/console}' >'$DOMAIN_HOME/$n.out' 2>&1 &"
    done
  fi
  [ "$DRY_RUN" = 1 ] && return 0
  # wait for ports
  local n port t ok=1
  for n in $want; do
    port="$(printf '%s\n' "$MANAGED_SERVERS" | awk -v s="$n" '$1==s {print $2}')"
    [ -n "$port" ] || continue
    t="$START_TIMEOUT"
    while [ "$t" -gt 0 ] && ! port_open "$port"; do sleep 10; t=$((t - 10)); done
    if port_open "$port"; then log "$n listening on $port"; else err "$n not listening on $port after ${START_TIMEOUT}s"; ok=0; fi
  done
  [ $ok = 1 ]
}

# ---------------------------------------------------------------------------
# apply
# ---------------------------------------------------------------------------
cmd_apply() {
  local pdir="$1"
  [ -n "$pdir" ] || die "apply needs <patch-dir>"
  setup_env
  [ -n "$RUN_DIR" ] || init_run_dir apply
  [ "$WLS_FAMILY" = opatch ] || die "Not an OPatch home"
  if [ -n "$(running_servers)" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      warn "dry-run: servers are running; a real run stops them before this point"
    else
      err "WebLogic servers are running. Run 'stop' first (or 'run' for the full flow)."
      return 1
    fi
  fi
  local list
  list="$(prepare_patch_dir "$pdir")"
  [ -n "$list" ] || die "No patches in $pdir"

  local id path kind
  # 1. OPatch upgrade kit first
  while IFS='|' read -r id path kind; do
    [ "$kind" = opatch-upgrade ] || continue
    log "Installing OPatch upgrade from $path"
    run_cmd cp -a "$ORACLE_HOME/OPatch" "$RUN_DIR/OPatch.before" || warn "could not snapshot old OPatch"
    run_cmd "$JAVA_HOME/bin/java" -jar "$path/opatch_generic.jar" -silent oracle_home="$ORACLE_HOME" \
      || die "OPatch upgrade failed"
    OPATCH_VERSION="$("$ORACLE_HOME/OPatch/opatch" version 2>/dev/null | sed -n 's/^OPatch Version: *//p')"
    log "OPatch now $OPATCH_VERSION"
    state_set opatch_upgraded 1
  done <<<"$list"

  # 2. patches, in directory order (sort patch-list by id so PSU (lower? no) - we keep README-agnostic order)
  while IFS='|' read -r id path kind; do
    [ "$kind" = patch ] || continue
    if printf '%s\n' "$INSTALLED_PATCHES" | grep -q "^$id;"; then
      log "Skipping $id (already installed)"; continue
    fi
    log "Applying $id : $(patch_description "$path")"
    if (cd "$path" && opatch apply -silent); then
      # opatch's exit status is not the outcome: the inventory is re-read and must name the patch before it is recorded as applied
      if [ "$DRY_RUN" != 1 ]; then
        INSTALLED_PATCHES="$("$ORACLE_HOME/OPatch/opatch" lspatches 2>/dev/null | grep -E '^[0-9]+;' || true)"
        printf '%s\n' "$INSTALLED_PATCHES" | grep -q "^$id;" || { err "opatch apply exited 0 but $id is not in 'opatch lspatches' - not recorded as applied. See $ORACLE_HOME/cfgtoollogs/opatch/"; state_set failed_patch "$id"; return 1; }
      fi
      state_append applied "$id"
      log "Applied $id"
    else
      err "opatch apply FAILED for $id. See $ORACLE_HOME/cfgtoollogs/opatch/"
      state_set failed_patch "$id"
      return 1
    fi
  done <<<"$list"
  log "All patches applied: $(state_get applied || echo none)"
}

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------
cmd_verify() {
  local pdir="${1:-}"
  setup_env
  [ -n "$RUN_DIR" ] || { RUN_DIR="$(latest_run_dir)"; [ -n "$RUN_DIR" ] && init_run_dir || init_run_dir verify; }
  if [ "$DRY_RUN" = 1 ]; then log "dry-run: skipping verification"; return 0; fi
  local ok=1
  local expected
  expected="$(state_get applied || true)"
  if [ -z "$expected" ] && [ -n "$pdir" ]; then
    expected="$(prepare_patch_dir "$pdir" | awk -F'|' '$3=="patch" {print $1}' | tr '\n' ' ')"
  fi
  local id
  for id in $expected; do
    if printf '%s\n' "$INSTALLED_PATCHES" | grep -q "^$id;"; then log "inventory has $id"; else err "inventory MISSING $id"; ok=0; fi
  done
  # servers
  local want n port
  want="$(state_get servers_were_running || true)"
  [ -z "$want" ] && want="$(running_servers | awk '{print $1}' | tr '\n' ' ')"
  for n in $want; do
    if running_servers | awk '{print $1}' | grep -qx "$n"; then
      port="$(printf '%s\n' "$MANAGED_SERVERS" | awk -v s="$n" '$1==s {print $2}')"
      if [ -n "$port" ] && ! port_open "$port"; then err "$n process exists but port $port closed"; ok=0; else log "$n running"; fi
    else
      err "$n not running"; ok=0
    fi
  done
  if [ -n "$ADMIN_URL" ] && printf ' %s ' "$want" | grep -q " $ADMIN_SERVER_NAME "; then
    if wait_for_url "$ADMIN_URL" 30; then log "admin console answers at $ADMIN_URL"; else err "admin console not answering at $ADMIN_URL"; ok=0; fi
  fi
  # look for fresh errors in server logs since the run started
  local d l
  for d in $want; do
    l="$DOMAIN_HOME/servers/$d/logs/$d.log"
    [ -f "$l" ] || continue
    local bad
    bad="$(find "$l" -newer "$STATE_FILE" 2>/dev/null | head -1)"
    if [ -n "$bad" ] && grep -qE '<(Critical|Emergency)>' "$l"; then
      warn "$d.log has Critical/Emergency entries - check it"
    fi
  done
  if [ $ok = 1 ]; then log "VERIFY PASSED"; state_set verified 1; else err "VERIFY FAILED"; state_set verified 0; fi
  [ $ok = 1 ]
}

# ---------------------------------------------------------------------------
# rollback
# ---------------------------------------------------------------------------
cmd_rollback() {
  setup_env
  [ -n "$RUN_DIR" ] || { RUN_DIR="$(latest_run_dir)"; [ -n "$RUN_DIR" ] && init_run_dir || init_run_dir rollback; }
  local ids="$*"
  if [ -z "$ids" ]; then
    ids="$(state_get applied || true)"
    # reverse order
    ids="$(printf '%s\n' $ids | tac 2>/dev/null || printf '%s\n' $ids | tail -r)"
  fi
  [ -n "$ids" ] || { warn "Nothing to roll back"; return 0; }
  if [ -n "$(running_servers)" ]; then
    warn "Servers running - stopping"; cmd_stop || die "Cannot stop servers for rollback"
  fi
  confirm "Roll back patches: $(echo $ids)?" || return 1
  local id fail=0
  for id in $ids; do
    log "Rolling back $id"
    if opatch rollback -silent -id "$id"; then
      # as for apply: the inventory says whether the patch is gone, not the exit status
      if [ "$DRY_RUN" != 1 ] && "$ORACLE_HOME/OPatch/opatch" lspatches 2>/dev/null | grep -q "^$id;"; then
        err "opatch rollback exited 0 but $id is still in 'opatch lspatches' - not recorded as rolled back. See $ORACLE_HOME/cfgtoollogs/opatch/"; fail=1
      else state_append rolled_back "$id"; fi
    else
      err "opatch rollback FAILED for $id"; fail=1
    fi
  done
  if [ $fail = 1 ]; then
    err "Rollback incomplete. 'restore' will put the backup copy of ORACLE_HOME back."
    return 1
  fi
  # OPatch upgrade is left in place (newer OPatch is harmless); note it
  [ "$(state_get opatch_upgraded)" = 1 ] && log "Note: upgraded OPatch left in place (old copy in $RUN_DIR/OPatch.before)"
  log "Rollback complete"
}

# ---------------------------------------------------------------------------
# heal
# ---------------------------------------------------------------------------
cmd_heal() {
  setup_env
  [ -n "$RUN_DIR" ] || init_run_dir heal
  local fixed=0 found=0

  # 1. stale OPatch lock
  if [ -e "$ORACLE_HOME/.patch_storage/patch_locked" ]; then
    found=$((found + 1))
    if opatch_running; then
      warn "OPatch lock present and an OPatch process is running - leaving it alone"
    else
      log "Removing stale OPatch lock (no opatch process)"
      run_cmd rm -f "$ORACLE_HOME/.patch_storage/patch_locked" && fixed=$((fixed + 1))
    fi
  fi

  # 2. inventory pointer
  if [ ! -f /etc/oraInst.loc ] && [ ! -f "$ORACLE_HOME/oraInst.loc" ] && [ ! -f /var/opt/oracle/oraInst.loc ]; then
    found=$((found + 1))
    local inv
    inv="$(dirname "$ORACLE_HOME")/oraInventory"
    [ -d "$inv" ] || inv="$HOME/oraInventory"
    if [ -d "$inv" ]; then
      log "Creating $ORACLE_HOME/oraInst.loc pointing at $inv"
      [ "$DRY_RUN" = 1 ] || printf 'inventory_loc=%s\ninst_group=%s\n' "$inv" "$(id -gn)" >"$ORACLE_HOME/oraInst.loc"
      fixed=$((fixed + 1))
    else
      warn "No oraInventory directory found near $ORACLE_HOME - cannot create oraInst.loc automatically"
    fi
  fi

  # 3. orphaned .lok files from a crashed server (block restart)
  local lok n
  while read -r lok; do
    [ -z "$lok" ] && continue
    n="$(printf '%s' "$lok" | sed -n 's#.*/servers/\([^/]*\)/.*#\1#p')"
    if [ -n "$n" ] && running_servers | awk '{print $1}' | grep -qx "$n"; then continue; fi
    found=$((found + 1))
    log "Removing orphaned lock $lok (server $n not running)"
    run_cmd rm -f "$lok" && fixed=$((fixed + 1))
  done < <([ -n "$DOMAIN_HOME" ] && find "$DOMAIN_HOME/servers" -name '*.lok' 2>/dev/null)

  # 4. old OPatch (only reports; apply handles the upgrade if kit present)
  if [ -n "$OPATCH_VERSION" ] && ! version_ge "$OPATCH_VERSION" "13.9.4.2.0"; then
    found=$((found + 1))
    warn "OPatch $OPATCH_VERSION is older than 13.9.4.2.x - recent PSUs will refuse. Download patch 28186730 (OPatch 13.9.4.x) into the patch dir."
  fi

  # 5. .patch_storage bloat
  if [ -d "$ORACLE_HOME/.patch_storage" ]; then
    local sz
    sz="$(du -sm "$ORACLE_HOME/.patch_storage" 2>/dev/null | awk '{print $1}')"
    if [ "${sz:-0}" -gt 5000 ]; then
      found=$((found + 1))
      warn ".patch_storage is ${sz} MB. 'opatch util cleanup' can reclaim space (keeps rollback data for installed patches)."
      if confirm "Run opatch util cleanup now?"; then opatch util cleanup -silent && fixed=$((fixed + 1)); fi
    fi
  fi

  # 6. half-applied run from a previous crash
  local last
  last="$(latest_run_dir)"
  if [ -n "$last" ] && [ -f "$last/state" ] && [ "$last" != "$RUN_DIR" ]; then
    local fp
    fp="$(sed -n 's/^failed_patch=//p' "$last/state")"
    if [ -n "$fp" ] && ! sed -n 's/^rolled_back=//p' "$last/state" | grep -q "$fp"; then
      found=$((found + 1))
      warn "Previous run $last failed on patch $fp and was not rolled back. Run: $0 rollback --run-dir $last"
    fi
  fi

  log "heal: $found issue(s) found, $fixed fixed"
}

# ---------------------------------------------------------------------------
# download : My Oracle Support (the ARU services on updates.oracle.com). Since 2026 they take an OAuth2 bearer
# token, not the account password: generate one (valid 60 minutes) while logged in to MOS at
# https://updates.oracle.com/Orion/GenToken/get_token and keep it in MOS_TOKEN_FILE (default ~/.mos-token,
# mode 600) or MOS_TOKEN. The old name search is gone; latest reads the Recommended list for the WebLogic /
# Coherence release instead. Same code as lib/oracle-lib.sh (this script stays self-contained).
# ---------------------------------------------------------------------------
MOS_TOKEN_FILE="${MOS_TOKEN_FILE:-$HOME/.mos-token}"; MOS_CFG=""; MOS_CURL=(); MOS_REL=""
mos_cleanup() { [ -n "$MOS_CFG" ] && rm -f "$MOS_CFG"; return 0; }
mos_token_hint() { printf 'log in to My Oracle Support in a browser, open %s/Orion/GenToken/get_token, press Generate token (it lasts 60 minutes) and save it as %s (chmod 600) or in MOS_TOKEN' "$MOS_BASE" "$MOS_TOKEN_FILE"; }
epoch_hm() { date -d "@$1" '+%H:%M' 2>/dev/null || date -r "$1" '+%H:%M' 2>/dev/null || echo "$1"; }
mos_login() {
  [ "$OFFLINE" = 1 ] && die "My Oracle Support is not reachable from this host (OFFLINE=1): download the patch zips (p<ID>_*.zip) on a machine with MOS access and copy them into the patch directory, then run without --latest/download"
  command -v curl >/dev/null || die "curl is required for download"
  trap mos_cleanup EXIT
  local tok="${MOS_TOKEN:-}"
  [ -z "$tok" ] && [ -f "$MOS_TOKEN_FILE" ] && tok="$(grep -vE '^[[:space:]]*(#|$)' "$MOS_TOKEN_FILE" | head -1 | tr -d '[:space:]')"
  [ -z "$tok" ] && [ -t 0 ] && { read -r -s -p "My Oracle Support access token: " tok; echo; }
  if [ -z "$tok" ]; then
    { [ -n "${MOS_USER:-}" ] || grep -qs 'updates.oracle.com' "$HOME/.netrc"; } && die "MOS_USER/~/.netrc are no use any more: updates.oracle.com stopped taking the account password - $(mos_token_hint)"
    die "No MOS token: $(mos_token_hint)"
  fi
  # the token goes into a curl config file (mode 600), never on a command line
  MOS_CFG="$RUN_DIR/.mos-curl"; ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$tok" >"$MOS_CFG" )
  MOS_CURL=(curl -sS -L --fail --compressed --retry 3 --retry-delay 5 -K "$MOS_CFG")   # --compressed: a patch record can be 9 MB raw; --fail not --fail-with-body: OL8 has curl 7.61
  local exp pay; pay="$(printf '%s' "$tok" | cut -d. -f2 | tr '_-' '/+')"; case $(( ${#pay} % 4 )) in 2) pay="$pay==";; 3) pay="$pay=";; esac
  exp="$(printf '%s' "$pay" | base64 -d 2>/dev/null | tr -d '\n' | sed -n 's/.*"exp": *\([0-9]*\).*/\1/p')"
  [ -n "$exp" ] && [ "$exp" -le "$(date +%s)" ] && die "the MOS token expired at $(epoch_hm "$exp") - $(mos_token_hint)"
  local code; code="$("${MOS_CURL[@]}" -o /dev/null -w '%{http_code}' "$MOS_BASE/Orion/Services/search?bug=$OPATCH_KIT_BUG" || true)"
  case "$code" in
    200) log "MOS token accepted${exp:+ (valid until $(epoch_hm "$exp"))}" ;;
    401|403) die "MOS rejected the token (HTTP $code): expired or mis-pasted - $(mos_token_hint)" ;;
    *) die "Cannot reach $MOS_BASE (HTTP ${code:-none}). Proxy? Set HTTPS_PROXY=http://proxy:port if the server needs one." ;;
  esac
}
# mos_release_ids "<label prefix>": "label|name|id" rows of the ARU release table whose label starts so, e.g. "Oracle WebLogic Server 14.1.2.0.0"
mos_release_ids() {
  if [ -z "$MOS_REL" ]; then
    # the table is 4 MB and changes rarely: kept for the day per user (no secrets in it)
    local cache raw; cache="${TMPDIR:-/tmp}/aru-releases-$(id -u)-$(date +%Y%m%d).txt"; raw="$RUN_DIR/.aru-releases.xml"
    if [ -s "$cache" ]; then MOS_REL="$cache"; else
      "${MOS_CURL[@]}" -o "$raw" "$MOS_BASE/Orion/Services/metadata?table=aru_releases" || { rm -f "$raw"; err "could not fetch the MOS release table"; return 1; }
      tail -c 200 "$raw" | grep -q '</results>' || { rm -f "$raw"; err "the MOS release table arrived incomplete: try again"; return 1; }
      tr -d '\n\r' <"$raw" | sed 's/<release /\n<release /g' | sed -nE 's/^<release id="([0-9]+)"[^>]*name="([^"]*)"><!\[CDATA\[([^]]*)\]\]>.*/\3|\2|\1/p' >"$cache.$$" && mv "$cache.$$" "$cache"; rm -f "$raw"
      [ -s "$cache" ] || { err "MOS returned an empty release table"; rm -f "$cache"; return 1; }
      MOS_REL="$cache"
    fi
  fi
  awk -F'|' -v p="$1" 'index($1,p)==1' "$MOS_REL" | sort -u
}
# mos_patch_rows <product> <release id> <platform> [recommended]: "number|abstract (yymmdd)" per patch filed there
mos_patch_rows() {
  local xml p; xml="$("${MOS_CURL[@]}" "$MOS_BASE/Orion/Services/search?product=$1&release=$2&platform=$3&patch_type=all${4:+&classification=$4}" | tr -d '\n\r')" || return 1
  printf '%s' "$xml" | sed 's/<patch /\n<patch /g' | grep '<patch ' | while read -r p; do
    # first <number> and <abstract> only: the record goes on to list every bug the patch fixes, each with its own
    local n a d; n="$(printf '%s' "$p" | grep -oE '<number>[0-9]+' | head -1 | cut -c9-)"; a="$(printf '%s' "$p" | grep -oE '<abstract><!\[CDATA\[[^]]*' | head -1 | cut -c20-)"
    d="$(printf '%s' "$p" | grep -oE '<released_date[^>]*>[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 | sed 's/.*>//; s/-//g' | cut -c3-8)"
    [ -n "$n" ] && printf '%s|%s%s\n' "$n" "$a" "${d:+ ($d)}"
  done
}
pad5() { local v="$1"; while [ "$(printf '%s' "$v" | tr -cd . | wc -c)" -lt 4 ]; do v="$v.0"; done; printf '%s' "$v"; }
# mos_name_search <text>: "number|description" rows as the old MOS name search gave them, now from the Recommended
# list (product WebLogic Server 15991 / Coherence 13964, platform Generic 2000) for "WLS PATCH SET UPDATE 14.1.2" and
# "Coherence 14.1.2 Cumulative Patch". The description ends with the release date as (yymmdd); rows sorted by it.
mos_name_search() {
  local q="$1" prod label ids rows
  case "$q" in
    WLS\ PATCH\ SET\ UPDATE*) prod=15991; label="Oracle WebLogic Server $(pad5 "$(printf '%s' "$q" | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)")";;
    Coherence*) prod=13964; label="Oracle Coherence $(pad5 "$(printf '%s' "$q" | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)")";;
    *) err "MOS has no patch name search any more: '$q' cannot be looked up, pass the patch number (--patches)"; return 1;;
  esac
  ids="$(mos_release_ids "$label")" || return 1
  ids="$(printf '%s\n' "$ids" | awk -F'|' -v l="$label" '$1==l {print $3; exit}')"
  [ -n "$ids" ] || { err "release '$label' not in the MOS release table (product $prod)"; return 1; }
  rows="$(mos_patch_rows "$prod" "$ids" 2000 recommended)" || return 1
  [ -n "$rows" ] || { err "MOS lists no Recommended patch for $label (Generic)"; return 1; }
  printf '%s\n' "$rows" | awk -F'[()]' '{print $(NF-1) "|" $0}' | sort -t'|' -k1,1 | cut -d'|' -f2-
}

# mos_pick_file <bug>: prints "filename|url|sha256|release" for the file matching this home, or lists choices
mos_pick_file() {
  local bug="$1" xml
  xml="$("${MOS_CURL[@]}" "$MOS_BASE/Orion/Services/search?bug=$bug" | tr -d '\n\r')" || return 1
  if printf '%s' "$xml" | grep -qi '<html'; then
    err "MOS returned a web page instead of patch data for $bug - the token was not accepted"; return 1
  fi
  [ -n "$xml" ] || { err "No metadata returned for patch $bug"; return 1; }
  # one line per <patch ...>...</patch>; then one per <file>; the URL is wrapped in CDATA
  local cands=""
  local p
  while read -r p; do
    [ -z "$p" ] && continue
    local rel plat
    rel="$(printf '%s' "$p" | sed -n 's/.*<release[^>]*name="\([^"]*\)".*/\1/p')"
    plat="$(printf '%s' "$p" | sed 's/<!\[CDATA\[//g; s/\]\]>//g' | grep -oE '<platform id="[0-9]+"[^>]*>[^<]*' | head -1 | sed 's/.*>//')"   # the name is in CDATA
    local f
    while read -r f; do
      [ -z "$f" ] && continue; f="$(printf '%s' "$f" | sed 's/<!\[CDATA\[//g; s/\]\]>//g')"
      local name url sha
      name="$(printf '%s' "$f" | sed -n 's/.*<name>\([^<]*\)<\/name>.*/\1/p')"
      url="$(printf '%s' "$f" | sed -n 's/.*<download_url[^>]*host="\([^"]*\)"[^>]*>\([^<]*\)<\/download_url>.*/\1\2/p' | sed 's/&amp;/\&/g')"
      sha="$(printf '%s' "$f" | sed -n 's/.*<digest type="SHA-256">\([^<]*\)<\/digest>.*/\1/p')"
      [ -n "$name" ] && [ -n "$url" ] && cands="${cands:+$cands$'\n'}$name|$url|$sha|$rel|$plat"
    done < <(printf '%s' "$p" | sed 's/<file>/\n<file>/g' | grep '<file>')
  done < <(printf '%s' "$xml" | sed 's/<patch /\n<patch /g' | grep '<patch ')
  [ -n "$cands" ] || { err "Patch $bug: no downloadable files listed (not entitled, or the number is wrong)"; return 1; }

  # platform: WebLogic patches are Generic; otherwise prefer the OS we are on
  local os="Linux x86-64"
  case "$(uname -s)/$(uname -m)" in Linux/aarch64) os="Linux ARM 64-bit";; SunOS/*) os="Solaris";; AIX/*) os="IBM AIX";; esac
  local byplat
  byplat="$(printf '%s\n' "$cands" | grep -iE '\|(Generic Platform|'"$os"')$' || printf '%s\n' "$cands")"

  # release: explicit --release > this home's WebLogic release > OPatch stream for the OPatch kit
  local want="${PICK_RELEASE:-$WLS_VERSION}" tok pick
  if [ "$bug" = "$OPATCH_KIT_BUG" ] && [ -z "$PICK_RELEASE" ]; then
    want="$(printf '%s' "$OPATCH_VERSION" | cut -d. -f1-3)"     # 13.9.4.2.5 -> 13.9.4
  fi
  tok="$(printf '%s' "$want" | tr -d .)"
  pick="$(printf '%s\n' "$byplat" | awk -F'|' -v r="$want" -v t="_$tok" 'index($4,r)==1 || index($1,t) {print; exit}')"
  [ -z "$pick" ] && [ "$(printf '%s\n' "$byplat" | wc -l)" -eq 1 ] && pick="$byplat"
  if [ -z "$pick" ]; then
    err "Patch $bug has several files and none is marked for release $want. Re-run with --release <one of these>:"
    printf '%s\n' "$byplat" | awk -F'|' '{printf "    %-45s release %-14s %s\n", $1, $4, $5}' >&2
    return 1
  fi
  printf '%s\n' "$pick"
}

# cmd_latest: work out this quarter's patch numbers for the detected release.
# Sets PATCHES; prints what it found. Returns 1 if nothing usable came back.
cmd_latest() {
  setup_env
  [ -n "$RUN_DIR" ] || init_run_dir latest
  [ "$WLS_FAMILY" = opatch ] || die "Not an OPatch home"
  local short="${WLS_VERSION%.*}"      # 12.2.1.4.0 -> 12.2.1.4 ; 14.1.2.0.0 -> 14.1.2.0
  case "$WLS_VERSION" in 14.1.*) short="${short%.*}";; esac   # 14.1.2.0 -> 14.1.2 (names use 14.1.2.0.0, both match)
  mos_login
  local found="" rows

  # 1. WLS PSU: names are "WLS PATCH SET UPDATE <release>.<yymmdd>"; newest = highest date suffix
  log "Searching MOS for the newest WLS PSU for $short"
  # exact PSU rows only: no merge/backport/one-off look-alikes ("(BLR)", "MERGE", "OVERLAY")
  rows="$(mos_name_search "WLS PATCH SET UPDATE $short" | grep -E "^[0-9]{8}\|WLS PATCH SET UPDATE $short(\.0)?\.[0-9]{6} *$" || true)"
  if [ -n "$rows" ]; then
    local psu psu_desc psu_level
    psu="$(printf '%s\n' "$rows" | awk -F'|' '{match($2,/[0-9]{6}\)?$/); d=substr($2,RSTART,6); print d "|" $0}' | sort -t'|' -k1,1 -r | head -1 | cut -d'|' -f2-)"
    psu_desc="${psu#*|}"; psu="${psu%%|*}"
    psu_level="$(printf '%s' "$psu_desc" | grep -oE "$short(\.0)?\.[0-9]{6}" | head -1)"
    if [ -n "$PSU_LEVEL" ] && version_ge "$PSU_LEVEL" "$psu_level"; then
      log "  newest PSU is $psu ($psu_desc) - already at $PSU_LEVEL, nothing newer"
    else
      log "  newest PSU: $psu  $psu_desc  (installed: ${PSU_LEVEL:-none})"
      found="$psu"
    fi
  else
    warn "  MOS name search returned no WLS PSU rows for $short"
  fi

  # 2. Coherence cumulative patch, only if Coherence is installed
  if grep -qi 'coherence' "$ORACLE_HOME/inventory/registry.xml" 2>/dev/null; then
    log "Searching MOS for the newest Coherence patch for $short"
    rows="$(mos_name_search "Coherence $short Cumulative Patch" | grep -iE "Coherence $short.* Cumulative Patch" || true)"
    if [ -n "$rows" ]; then
      local coh coh_desc coh_n installed_coh
      coh="$(printf '%s\n' "$rows" | awk -F'|' '{match($2,/Cumulative Patch [0-9]+/); n=substr($2,RSTART+17,RLENGTH-17); printf "%05d|%s\n", n, $0}' | sort -r | head -1 | cut -d'|' -f2-)"
      coh_desc="${coh#*|}"; coh="${coh%%|*}"
      coh_n="$(printf '%s' "$coh_desc" | grep -oE 'Cumulative Patch [0-9]+' | grep -oE '[0-9]+$')"
      installed_coh="$(printf '%s\n' "$INSTALLED_PATCHES" | grep -i 'Coherence' | grep -oE 'Cumulative Patch [0-9]+' | grep -oE '[0-9]+$' | sort -n | tail -1)"
      if [ -n "$installed_coh" ] && [ "${installed_coh:-0}" -ge "${coh_n:-0}" ]; then
        log "  newest Coherence patch is $coh ($coh_desc) - already have Cumulative Patch $installed_coh"
      else
        log "  newest Coherence: $coh  $coh_desc  (installed: ${installed_coh:-none})"
        found="${found:+$found,}$coh"
      fi
    else
      warn "  MOS name search returned no Coherence rows for $short"
    fi
  fi
  mos_cleanup

  if [ -z "$found" ]; then
    if [ -n "$rows$psu" ]; then log "Nothing newer than what is installed."; state_set latest "uptodate"; return 0; fi
    err "Could not work out patch numbers automatically. Get them from the CPU Patch Advisor for Fusion Middleware on MOS and pass --patches N,N"
    return 1
  fi
  echo
  echo "  Patches MOS says are current for WebLogic $short: $found"
  echo "  (only the PSU and Coherence are looked up; other product bundles such as ADF/OPSS/OWSM"
  echo "   still come from the CPU Patch Advisor document - add them with --patches)"
  echo
  PATCHES="${found}${PATCHES:+,$PATCHES}"
  state_set latest "$found"
  return 0
}

cmd_download() {
  local pdir="$1"; shift
  [ -n "$pdir" ] || die "download needs <patch-dir> <patch-number ...>"
  local ids="$*"
  [ -n "$ids" ] || ids="$(printf '%s' "$PATCHES" | tr ',' ' ')"
  setup_env
  [ -n "$RUN_DIR" ] || init_run_dir download
  mkdir -p "$pdir" || die "Cannot create $pdir"

  # add the OPatch kit when the installed OPatch is older than modern PSUs demand
  if [ "$WLS_FAMILY" = opatch ] && [ -n "$OPATCH_VERSION" ] && ! version_ge "$OPATCH_VERSION" "13.9.4.2.0" \
     && ! printf ' %s ' "$ids" | grep -q " $OPATCH_KIT_BUG "; then
    log "OPatch $OPATCH_VERSION is old - adding the OPatch kit ($OPATCH_KIT_BUG) to the download list"
    ids="$OPATCH_KIT_BUG $ids"
  fi
  [ -n "$ids" ] || die "download needs patch numbers (arguments, or PATCHES=.. in wls-patch.conf)"

  # what is already here / already installed
  local todo="" id
  for id in $ids; do
    [[ "$id" =~ ^[0-9]{6,10}$ ]] || { warn "'$id' is not a patch number - skipped"; continue; }
    if ls "$pdir"/p"$id"_*.zip >/dev/null 2>&1; then log "$id already in $pdir - skip"; continue; fi
    if [ "$id" != "$OPATCH_KIT_BUG" ] && printf '%s\n' "$INSTALLED_PATCHES" | grep -q "^$id;"; then log "$id already installed - skip"; continue; fi
    todo="${todo:+$todo }$id"
  done
  if [ -z "$todo" ]; then log "Nothing to download"; return 0; fi
  log "To download: $todo"
  if [ "$DRY_RUN" = 1 ]; then log "dry-run: would download $todo into $pdir"; return 0; fi

  mos_login
  local fail=0
  for id in $todo; do
    local pick name url sha rel plat
    pick="$(mos_pick_file "$id")" || { fail=$((fail + 1)); continue; }
    IFS='|' read -r name url sha rel plat <<<"$pick"
    log "Downloading $name (release $rel, $plat)"
    if ! "${MOS_CURL[@]}" -o "$pdir/$name.part" "$url"; then
      err "Download failed for $name"; rm -f "$pdir/$name.part"; fail=$((fail + 1)); continue
    fi
    if head -c 300 "$pdir/$name.part" | grep -qi '<html'; then
      err "$name came back as a web page (login/entitlement problem), not a zip"; rm -f "$pdir/$name.part"; fail=$((fail + 1)); continue
    fi
    if [ -n "$sha" ] && command -v sha256sum >/dev/null; then
      local got
      got="$(sha256sum "$pdir/$name.part" | awk '{print toupper($1)}')"
      if [ "$got" != "$(printf '%s' "$sha" | tr 'a-f' 'A-F')" ]; then
        err "$name SHA-256 mismatch (corrupt download) - deleted"; rm -f "$pdir/$name.part"; fail=$((fail + 1)); continue
      fi
      log "  SHA-256 OK"
    fi
    # the rename was unchecked and downloaded=<id> recorded whatever it did (DeepSeek, 1 Nov 22:17): a failed mv is a failed download
    if ! mv "$pdir/$name.part" "$pdir/$name" || [ ! -s "$pdir/$name" ]; then
      err "could not move $name.part into place as $name - download not recorded"; rm -f "$pdir/$name.part"; fail=$((fail + 1)); continue
    fi
    state_append downloaded "$id"
  done
  mos_cleanup
  if [ "$fail" -gt 0 ]; then err "$fail download(s) failed"; return 1; fi
  log "Downloads complete: $(ls "$pdir"/*.zip | wc -l | tr -d ' ') zip(s) in $pdir"
}

# ---------------------------------------------------------------------------
# plan : what would be applied, nothing changed
# ---------------------------------------------------------------------------
cmd_plan() {
  local pdir="${1:-}"
  [ -n "$ORACLE_HOME" ] && [ -n "$WLS_FAMILY" ] || setup_env
  [ -n "$RUN_DIR" ] || init_run_dir plan
  echo
  echo "WOULD APPLY (nothing has been changed)"
  echo "  Now        : WebLogic ${WLS_VERSION:-?}  PSU ${PSU_LEVEL:-none}  OPatch ${OPATCH_VERSION:-?}  JDK ${JDK_VERSION:-?}"
  local any=0
  if [ "$USE_LATEST" = 1 ]; then
    if cmd_latest; then
      [ "$(state_get latest)" = uptodate ] && echo "  MOS        : nothing newer than the installed PSU/Coherence level"
    else echo "  MOS        : lookup failed (see messages above)"; fi
  fi
  if [ -n "$PATCHES" ]; then
    local id
    for id in $(printf '%s' "$PATCHES" | tr ',' ' '); do
      any=1
      if printf '%s\n' "$INSTALLED_PATCHES" | grep -q "^$id;"; then echo "  Patch $id : already installed - skip"
      elif ls "${pdir:-/nonexistent}"/p"$id"_*.zip >/dev/null 2>&1; then echo "  Patch $id : in $pdir, will be applied"
      else echo "  Patch $id : will be downloaded from MOS, then applied"; fi
    done
    if [ -n "$OPATCH_VERSION" ] && ! version_ge "$OPATCH_VERSION" "13.9.4.2.0"; then echo "  OPatch kit : $OPATCH_KIT_BUG will be downloaded and installed first (OPatch $OPATCH_VERSION is too old)"; fi
  fi
  if [ -n "$pdir" ] && [ -d "$pdir" ]; then
    local list id path kind
    list="$(prepare_patch_dir "$pdir")"
    while IFS='|' read -r id path kind; do
      [ -z "$id" ] && continue; any=1
      if [ "$kind" = opatch-upgrade ]; then echo "  OPatch kit : present in $pdir - installed first"; continue; fi
      local st="will be applied" min
      printf '%s\n' "$INSTALLED_PATCHES" | grep -q "^$id;" && st="already installed - skip"
      min="$(patch_min_opatch "$path" || true)"
      [ -n "$min" ] && [ -n "$OPATCH_VERSION" ] && ! version_ge "$OPATCH_VERSION" "$min" && st="$st (needs OPatch $min, have $OPATCH_VERSION)"
      printf '  Patch %s : %-60s %s\n' "$id" "$(patch_description "$path" | cut -c1-60)" "$st"
    done <<<"$list"
    [ -z "$list" ] && echo "  Folder $pdir holds no patch zips"
  fi
  [ $any = 0 ] && echo "  No patch folder or numbers given. Use:  plan <patch-dir>   or   plan --latest   or   plan --patches N,N"
  case "$WLS_VERSION" in
    12.2.1.4*) echo "  JDK        : 12.2.1.4 runs on JDK 8; Oracle expects the CPU's JDK 8 update installed too (not done by this script)";;
    14.1.1*)   echo "  JDK        : 14.1.1 runs on JDK 8 or 11; update the JDK to the CPU's release too (not done by this script)";;
    14.1.2*)   echo "  JDK        : 14.1.2 runs on JDK 17 or 21; update the JDK to the CPU's release too (not done by this script)";;
  esac
  echo "  Then       : backup ORACLE_HOME + domain > stop $(printf '%s\n' "$MANAGED_SERVERS" | awk '{print $1}' | tr '\n' ' ')> opatch apply > start > verify; automatic rollback if anything fails"
  echo "  Next step  : ./wls-patch.sh preflight ${pdir:-<patch-dir>}   (adds Oracle's conflict check, disk, JDK pairing)"
  echo
  return 0
}

# ---------------------------------------------------------------------------
# run : the orchestrated flow with automatic rollback
# ---------------------------------------------------------------------------
cmd_run() {
  local pdir="$1"
  [ -n "$pdir" ] || die "run needs <patch-dir>"
  init_run_dir run
  setup_env

  if [ "$USE_LATEST" = 1 ]; then
    log "=== 0/7 look up this quarter's patches on MOS"
    cmd_latest || die "Cannot determine patches. Nothing was changed on the server."
    if [ "$(state_get latest)" = uptodate ] && [ -z "$PATCHES" ]; then log "Already up to date. Nothing to do."; return 0; fi
    confirm "Download and apply these?" || return 1
  fi
  if [ -n "$PATCHES" ]; then
    log "=== 0/7 download (missing patches only)"
    cmd_download "$pdir" || die "Download failed. Nothing was changed on the server."
    if ! ls "$pdir"/*.zip >/dev/null 2>&1 && [ ! -d "$pdir/extracted" ]; then
      if [ "$DRY_RUN" = 1 ]; then log "dry-run: nothing downloaded, so stopping here"; else log "Every requested patch is already installed. Nothing to do."; fi
      return 0
    fi
  fi

  log "=== 1/7 inspect"
  cmd_inspect >"$RUN_DIR/inspect.txt"
  cat "$RUN_DIR/inspect.txt"
  [ "$WLS_FAMILY" = opatch ] || die "Only OPatch-based WebLogic is supported (this is '$WLS_FAMILY')"

  log "=== 2/7 heal (pre)"
  cmd_heal || true

  log "=== 3/7 preflight"
  if ! cmd_preflight "$pdir"; then
    err "Preflight failed. Fix the problems above and re-run. Nothing was changed."
    return 1
  fi
  if ! confirm "Preflight OK. Stop WebLogic, back up, and apply patches now?"; then return 1; fi

  if [ "$NO_BACKUP" = 1 ]; then
    warn "=== 4/7 backup SKIPPED (--no-backup): rollback will rely on OPatch only"
  else
    log "=== 4/7 backup"
    cmd_backup || die "Backup failed; stopping before any change"
  fi

  log "=== 5/7 stop"
  cmd_stop || die "Could not stop WebLogic cleanly. Nothing patched. Re-run with --force to kill stuck processes."

  log "=== 6/7 apply"
  if ! cmd_apply "$pdir"; then
    err "Apply failed - rolling back"
    ASSUME_YES=1 cmd_rollback || { err "Rollback failed too - restoring from backup"; ASSUME_YES=1 cmd_restore; }
    log "Starting servers on the pre-patch home"
    cmd_start || err "Servers did not start after rollback - manual attention needed. Log: $LOG_FILE"
    return 1
  fi

  log "=== 7/7 start + verify"
  detect_versions   # refresh inventory
  if cmd_start && cmd_verify "$pdir"; then
    log "SUCCESS. Applied: $(state_get applied). PSU level now: $PSU_LEVEL. Log: $LOG_FILE"
    return 0
  fi

  err "Start/verify failed after patching"
  if [ "$FORCE" = 1 ] || confirm "Roll back the patches and restart on the old binaries?"; then
    cmd_stop || true
    ASSUME_YES=1 cmd_rollback || { err "Rollback failed - restoring from backup"; ASSUME_YES=1 cmd_restore; }
    cmd_start || err "Servers did not start after rollback - manual attention needed. Log: $LOG_FILE"
  fi
  return 1
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
usage() { sed -n '2,47p' "$0" | sed 's/^# \{0,1\}//'; }

main() {
  local cmd="" args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --oracle-home) optchk "$@"; CLI_ORACLE_HOME="$2"; shift 2 ;;
      --domain-home) optchk "$@"; CLI_DOMAIN_HOME="$2"; shift 2 ;;
      --java-home) optchk "$@";  optchk "$@";  optchk "$@"; CLI_JAVA_HOME="$2"; shift 2 ;;
      --admin-url) optchk "$@";  optchk "$@";  optchk "$@"; CLI_ADMIN_URL="$2"; shift 2 ;;
      --backup-dir) optchk "$@";  optchk "$@"; CLI_BACKUP_DIR="$2"; shift 2 ;;
      --run-dir)   optchk "$@";  optchk "$@";  optchk "$@"; RUN_DIR="$2"; shift 2 ;;
      --dry-run)     DRY_RUN=1; shift ;;
      --yes|-y)      ASSUME_YES=1; shift ;;
      --no-backup)   NO_BACKUP=1; shift ;;
      --force)       FORCE=1; shift ;;
      --patches)   optchk "$@";  optchk "$@";  optchk "$@"; CLI_PATCHES="$2"; shift 2 ;;
      --release)   optchk "$@";  optchk "$@";  optchk "$@"; PICK_RELEASE="$2"; shift 2 ;;
      --latest)      USE_LATEST=1; shift ;;
      --json)        JSON_OUT=1; shift ;;
      --verbose|-v)  VERBOSE=1; shift ;;
      -h|--help|help) usage; exit 0 ;;
      --version)     echo "$VERSION"; exit 0 ;;
      -*)            die "Unknown option $1" ;;
      *) if [ -z "$cmd" ]; then cmd="$1"; else args+=("$1"); fi; shift ;;
    esac
  done
  [ -n "$cmd" ] || { usage; exit 1; }
  load_config   # before any run dir is created, so RUN_BASE/BACKUP_DIR from the config apply
  [ -n "${CLI_ORACLE_HOME:-}" ] && ORACLE_HOME="$CLI_ORACLE_HOME"
  [ -n "${CLI_DOMAIN_HOME:-}" ] && DOMAIN_HOME="$CLI_DOMAIN_HOME"
  [ -n "${CLI_JAVA_HOME:-}" ]   && JAVA_HOME="$CLI_JAVA_HOME"
  [ -n "${CLI_ADMIN_URL:-}" ]   && ADMIN_URL="$CLI_ADMIN_URL"
  [ -n "${CLI_BACKUP_DIR:-}" ]  && BACKUP_DIR="$CLI_BACKUP_DIR"
  [ -n "${CLI_PATCHES:-}" ]     && PATCHES="$CLI_PATCHES"
  [ "$PATCHES" = latest ] && { PATCHES=""; USE_LATEST=1; }
  export ORACLE_HOME DOMAIN_HOME JAVA_HOME ADMIN_URL
  case "$cmd" in
    inspect)   cmd_inspect "${args[0]:-}" ;;
    plan)      cmd_plan "${args[0]:-}" ;;
    preflight) cmd_preflight "${args[0]:-}" ;;
    backup)    cmd_backup ;;
    restore)   cmd_restore "${args[0]:-}" ;;
    stop)      cmd_stop ;;
    start)     cmd_start ;;
    apply)     cmd_apply "${args[0]:-}" ;;
    verify)    cmd_verify "${args[0]:-}" ;;
    rollback)  cmd_rollback "${args[@]}" ;;
    heal)      cmd_heal ;;
    latest)    cmd_latest ;;
    download)  cmd_download "${args[@]}" ;;
    run)       cmd_run "${args[0]:-}" ;;
    *)         die "Unknown command: $cmd" ;;
  esac
}

main "$@"
