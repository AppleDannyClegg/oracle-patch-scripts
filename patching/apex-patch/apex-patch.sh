#!/usr/bin/env bash
# apex-patch.sh - upgrade Oracle APEX in a database to the newest release, with
# preflight, documented rollback (apxdwngrd.sql), flashback restore point, verification
# and self-heal. Runs on a host that can reach the database with SQL*Plus or SQLcl
# (normally the database server, as the oracle user) and that runs ORDS, if ORDS is local.
#
# Usage: apex-patch.sh <command> [args] [options]
#
# Commands
#   inspect                 Installed APEX version/schema/type, DB, ORDS, images dir, restore points,
#                           and the newest release Oracle offers (if the download site is reachable)
#   plan                    What WOULD be done: from -> to, scripts, images dir, ORDS handling, rollback path
#   latest                  Probe Oracle's public download site for the newest APEX release
#   download [version]      Fetch apex_<version>.zip (public, no login) and unpack it under APEX_BASE
#   preflight [version]     Checks: SQL access, DB/ORDS versions, upgrade path, invalid objects,
#                           tablespaces, previous-release source for rollback, restore-point ability
#   backup                  Keep previous-release source, guaranteed restore point (if ARCHIVELOG),
#                           tar of the images directory
#   stop | start            Stop / start ORDS (systemd unit, ORDS_STOP_CMD/ORDS_START_CMD, or direct)
#   apply [version]         Run apexins.sql / apxrtins.sql from the new source; switch the images dir
#   verify                  apex_release matches, registry VALID, no invalid objects, ORDS answers
#   rollback                apxdwngrd.sql from the previous source, images back, then offer
#                           flashback to the restore point if that fails
#   cleanup                 After you are happy: drop the restore point and the old APEX schema
#   heal                    Recompile invalids, fix images mismatch, start ORDS, report stale restore points
#   run [version]           latest > download > inspect > preflight > backup > stop > apply > start
#                           > verify, automatic rollback if apply or verify fails
#
# Options
#   --apex-base DIR    where releases are unpacked (default /opt/oracle/apex-releases)
#   --images-dir DIR   the directory ORDS serves as /i/ (auto-detected from ORDS settings.xml)
#   --pdb NAME         pluggable database holding APEX      --runtime  install runtime-only
#   --dry-run  --yes  --force  --json  --verbose  --no-restore-point  --run-dir DIR
#   --allow-flashback   let 'rollback' flash the database container back to the restore point
#
# Config file (optional): ./apex-patch.conf or ~/.apex-patch.conf, KEY=VALUE lines:
#   SQL_CMD ("sqlplus -S" or "sql -S"), SQL_CONNECT ("/ as sysdba" or "sys/pw@//host/svc as sysdba"),
#   ORACLE_HOME, ORACLE_SID, PDB, APEX_BASE, APEX_IMAGES_DIR, APEX_TS, APEX_FILES_TS, APEX_TEMP_TS,
#   APEX_INSTALL_TYPE (full|runtime), ORDS_HOME, ORDS_CONFIG, ORDS_SERVICE, ORDS_STOP_CMD,
#   ORDS_START_CMD, ORDS_URL, RUN_BASE, START_TIMEOUT. ORDS inside WebLogic is detected from the domain
#   (images dir read from i.war, app stopped/started with weblogic.Deployer): WLS_ORACLE_HOME,
#   WLS_DOMAIN_HOME, WLS_ADMIN_URL, WLS_USERCONFIG+WLS_USERKEY or WLS_ADMIN_USER+WLS_ADMIN_PASSWORD

set -o pipefail
VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0; ASSUME_YES=0; FORCE=0; JSON_OUT=0; VERBOSE=0; NO_RP=0; ALLOW_FLASHBACK=0
RUN_BASE="${RUN_BASE:-$HOME/apex-patch/runs}"
APEX_BASE="${APEX_BASE:-/opt/oracle/apex-releases}"
OFFLINE="${OFFLINE:-0}"; NET_OK=""   # no internet: put apex_<ver>.zip in $APEX_BASE/downloads/ and run "run <ver>"
net_ok() { [ "$OFFLINE" = 1 ] && return 1; [ -n "$NET_OK" ] || { NET_OK=0; command -v curl >/dev/null 2>&1 && curl -sI -m 5 -A 'Mozilla/5.0' -o /dev/null "$APEX_DL_BASE/" >/dev/null 2>&1 && NET_OK=1; }; [ "$NET_OK" = 1 ]; }
# newest release on disk (zip in downloads/ or already unpacked)
local_latest() { local best="" z v; for z in "$APEX_BASE"/downloads/apex_*.zip "$APEX_BASE"/apex_*/apex/apexins.sql; do [ -e "$z" ] || continue; v="$(printf '%s' "$z" | sed -E 's#.*/apex_([0-9.]+)(\.zip|/apex/apexins\.sql)$#\1#')"; [[ "$v" =~ ^[0-9]+\.[0-9]+ ]] || continue; { [ -z "$best" ] || version_ge "$v" "$best"; } && best="$v"; done; printf '%s' "$best"; }
APEX_TS="${APEX_TS:-SYSAUX}"; APEX_FILES_TS="${APEX_FILES_TS:-SYSAUX}"; APEX_TEMP_TS="${APEX_TEMP_TS:-TEMP}"
APEX_DL_BASE="${APEX_DL_BASE:-https://download.oracle.com/otn_software/apex}"
START_TIMEOUT="${START_TIMEOUT:-300}"
RUN_DIR=""; LOG_FILE=""; STATE_FILE=""; TARGET=""

# detected
APEX_VER=""; APEX_SCHEMA=""; APEX_STATUS=""; APEX_TYPE=""; APEX_PATCHES=""
DB_VER=""; DB_LOG_MODE=""; DB_CON=""; DB_IS_CDB=""; RESTORE_POINTS=""
ORDS_VER=""; ORDS_RUNNING=""; IMAGES_VER=""

# ---------------------------------------------------------------------------
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '%s [INFO ] %s\n' "$(ts)" "$*" | tee -a "${LOG_FILE:-/dev/null}" >&2; }
warn() { printf '%s [WARN ] %s\n' "$(ts)" "$*" | tee -a "${LOG_FILE:-/dev/null}" >&2; }
err()  { printf '%s [ERROR] %s\n' "$(ts)" "$*" | tee -a "${LOG_FILE:-/dev/null}" >&2; }
dbg()  { [ "$VERBOSE" = 1 ] && printf '%s [DEBUG] %s\n' "$(ts)" "$*" >&2; return 0; }
die()  { err "$*"; exit 1; }
run_cmd() { log "CMD: $*"; [ "$DRY_RUN" = 1 ] && return 0; "$@" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; return "${PIPESTATUS[0]}"; }
run_sh()  { log "CMD: $*"; [ "$DRY_RUN" = 1 ] && return 0; bash -c "$*" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1; }
confirm() {
  [ "$ASSUME_YES" = 1 ] || [ "$DRY_RUN" = 1 ] && return 0
  [ -t 0 ] || { warn "Non-interactive and --yes not given: refusing '$1'"; return 1; }
  read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[Yy]([Ee][Ss])?$ ]]
}
# flashback discards EVERY change in the container since the restore point, so it never happens on
# --yes alone: only on an interactive yes or an explicit --allow-flashback.
confirm_flashback() {
  [ "$ALLOW_FLASHBACK" = 1 ] && return 0
  if [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ]; then
    warn "NOT flashing back automatically: it would discard every change in the database container since the restore point."
    warn "If that is acceptable, run:  $0 rollback --allow-flashback"
    return 1
  fi
  confirm "$1"
}
version_ge() {
  local a b i; IFS='.' read -r -a a <<<"$1"; IFS='.' read -r -a b <<<"$2"
  for ((i = 0; i < ${#b[@]}; i++)); do
    local x="${a[i]:-0}" y="${b[i]:-0}"; x="${x//[^0-9]/}"; y="${y//[^0-9]/}"
    ((10#${x:-0} > 10#${y:-0})) && return 0; ((10#${x:-0} < 10#${y:-0})) && return 1
  done; return 0
}
state_set() { [ -z "$STATE_FILE" ] && return 0; touch "$STATE_FILE"; grep -v "^$1=" "$STATE_FILE" >"$STATE_FILE.tmp" 2>/dev/null || true; printf '%s=%s\n' "$1" "$2" >>"$STATE_FILE.tmp"; mv "$STATE_FILE.tmp" "$STATE_FILE"; }
state_get() { [ -f "$STATE_FILE" ] || return 1; sed -n "s/^$1=//p" "$STATE_FILE" | tail -1 | grep . ; }
init_run_dir() {
  [ -z "$RUN_DIR" ] && RUN_DIR="$RUN_BASE/$(date '+%Y%m%d-%H%M%S')-${1:-run}"
  mkdir -p "$RUN_DIR" || die "Cannot create $RUN_DIR"
  LOG_FILE="$RUN_DIR/apex-patch.log"; STATE_FILE="$RUN_DIR/state"; ln -sfn "$RUN_DIR" "$RUN_BASE/latest"
  log "apex-patch $VERSION  run dir: $RUN_DIR  dry-run=$DRY_RUN"
}
latest_run_dir() { [ -L "$RUN_BASE/latest" ] && readlink "$RUN_BASE/latest"; }
reuse_or_init() { [ -n "$RUN_DIR" ] && return 0; RUN_DIR="$(latest_run_dir)"; [ -n "$RUN_DIR" ] && init_run_dir || init_run_dir "$1"; }
load_config() {
  local f
  for f in "$SCRIPT_DIR/../../oracle.conf" "$HOME/.oracle.conf" "$SCRIPT_DIR/apex-patch.conf" ./apex-patch.conf "$HOME/.apex-patch.conf"; do
    if [ -f "$f" ]; then set -a; # shellcheck disable=SC1090
      . "$f"; set +a; fi
  done
}
wait_for_url() {
  local url="$1" t="$2" code; command -v curl >/dev/null || return 0
  while [ "$t" -gt 0 ]; do
    code="$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" || true)"
    case "$code" in 200|30[1-3]|401|403) return 0;; esac; sleep 10; t=$((t - 10))
  done; return 1
}

# ---------------------------------------------------------------------------
# SQL access
# ---------------------------------------------------------------------------
sql_detect() {
  [ -n "${SQL_CMD:-}" ] && return 0
  if [ -n "${ORACLE_HOME:-}" ] && [ -x "$ORACLE_HOME/bin/sqlplus" ]; then SQL_CMD="$ORACLE_HOME/bin/sqlplus -S"
  elif command -v sqlplus >/dev/null; then SQL_CMD="sqlplus -S"
  elif command -v sql >/dev/null; then SQL_CMD="sql -S"
  else return 1; fi
}
# run_sql <statements>: prints result rows, no headers. Fails on ORA- errors.
run_sql() {
  local out
  out="$(printf 'set heading off feedback off pagesize 0 linesize 32767 trimspool on verify off echo off\nwhenever sqlerror exit 1\n%s\n%s\nexit\n' \
          "${PDB:+alter session set container=$PDB;}" "$1" | $SQL_CMD "${SQL_CONNECT:-/ as sysdba}" 2>&1)" || { dbg "SQL failed: $out"; printf '%s\n' "$out" >>"${LOG_FILE:-/dev/null}"; return 1; }
  printf '%s\n' "$out" | sed '/^[[:space:]]*$/d'
}
sql_val() { run_sql "select $1 from dual;" 2>/dev/null | head -1 | sed 's/^ *//;s/ *$//'; }
# run_sql_script <dir> <script> [args]: runs @script with the APEX session settings, output to log
run_sql_script() {
  local dir="$1" script="$2"; shift 2
  log "SQL: cd $dir && @$script $*  (this can take a long time; tail -f $LOG_FILE in another window)"
  [ "$DRY_RUN" = 1 ] && return 0
  (cd "$dir" && printf '%s\nalter session set "_ORACLE_SCRIPT"=true;\nset echo off\n@%s %s\nexit\n' \
     "${PDB:+alter session set container=$PDB;}" "$script" "$*" | $SQL_CMD "${SQL_CONNECT:-/ as sysdba}") >>"$LOG_FILE" 2>&1
}


# ---------------------------------------------------------------------------
# ORDS deployed inside WebLogic (ords.war + i.war) - detected from the domain's config.xml
# ---------------------------------------------------------------------------
WLS_MODE=0; WLS_ORDS_APP=""; WLS_ORDS_WAR=""; WLS_I_WAR=""; WLS_DOMAIN_HOME=""; WLS_ORACLE_HOME=""; WLS_TARGET_PORT=""
wls_discover() {
  [ -n "${WLS_ORACLE_HOME:-}" ] || WLS_ORACLE_HOME="${MW_HOME:-}"
  if [ -z "$WLS_ORACLE_HOME" ]; then
    local inv h
    for inv in /etc/oraInst.loc /var/opt/oracle/oraInst.loc; do
      [ -f "$inv" ] || continue
      inv="$(sed -n 's/^inventory_loc=//p' "$inv")/ContentsXML/inventory.xml"; [ -f "$inv" ] || continue
      for h in $(sed -n 's/.*<HOME NAME="[^"]*" LOC="\([^"]*\)".*/\1/p' "$inv"); do [ -d "$h/wlserver" ] && { WLS_ORACLE_HOME="$h"; break; }; done
    done
  fi
  [ -z "$WLS_ORACLE_HOME" ] && for h in /u01/app/oracle/product/*/fmw* /u01/app/oracle/middleware* /u01/oracle/* /opt/oracle/*; do [ -d "$h/wlserver" ] && { WLS_ORACLE_HOME="$h"; break; }; done
  if [ -z "${WLS_DOMAIN_HOME:-}" ]; then
    [ -f "$WLS_ORACLE_HOME/domain-registry.xml" ] && WLS_DOMAIN_HOME="$(sed -n 's/.*<domain location="\([^"]*\)".*/\1/p' "$WLS_ORACLE_HOME/domain-registry.xml" | head -1)"
    [ -z "$WLS_DOMAIN_HOME" ] && for d in "$WLS_ORACLE_HOME"/user_projects/domains/*; do [ -f "$d/config/config.xml" ] && { WLS_DOMAIN_HOME="$d"; break; }; done
  fi
  local cfg="$WLS_DOMAIN_HOME/config/config.xml"; [ -f "$cfg" ] || return 1
  # app-deployment blocks: name + source-path + target
  local blocks; blocks="$(awk '/<app-deployment>/{b="";ina=1} ina{b=b $0} /<\/app-deployment>/{ina=0; print b}' "$cfg")"
  local line name src tgt
  while read -r line; do
    name="$(printf '%s' "$line" | sed -n 's/.*<name>\([^<]*\)<\/name>.*/\1/p')"; src="$(printf '%s' "$line" | sed -n 's/.*<source-path>\([^<]*\)<\/source-path>.*/\1/p')"; tgt="$(printf '%s' "$line" | sed -n 's/.*<target>\([^<]*\)<\/target>.*/\1/p')"
    [ "${src:0:1}" = / ] || src="$WLS_DOMAIN_HOME/$src"
    case "$src" in *ords.war|*apex.war) [ -n "${WLS_ORDS_APP:-}" ] && [ "$WLS_ORDS_APP" != "$name" ] && continue; WLS_MODE=1; WLS_ORDS_APP="$name"; WLS_ORDS_WAR="$src"; WLS_TARGET="${tgt%%,*}";; esac
    case "$src" in *i.war) WLS_I_WAR="$src";; esac
  done <<<"$blocks"
  [ "$WLS_MODE" = 1 ] || return 1
  # config dir: embedded in the war (ords --config X war) or -Dconfig.url on the managed server
  if [ -z "${ORDS_CONFIG:-}" ]; then
    ORDS_CONFIG="$(unzip -p "$WLS_ORDS_WAR" WEB-INF/web.xml 2>/dev/null | tr -d '\n' | sed -n 's/.*config\.url<\/param-name>[^<]*<param-value>\([^<]*\)<.*/\1/p')"
    [ -z "$ORDS_CONFIG" ] && ORDS_CONFIG="$(grep -rhoE 'config\.url=[^ "<]+' "$WLS_DOMAIN_HOME/bin" "$cfg" 2>/dev/null | head -1 | cut -d= -f2)"
  fi
  # images dir from i.war's weblogic.xml
  if [ -z "${APEX_IMAGES_DIR:-}" ] && [ -f "$WLS_I_WAR" ]; then
    APEX_IMAGES_DIR="$(unzip -p "$WLS_I_WAR" WEB-INF/weblogic.xml 2>/dev/null | sed -n 's/.*<local-path>\([^<]*\)<.*/\1/p' | head -1)"
  fi
  # admin url + the target's listen port, for defaults
  local aport; aport="$(awk -v a="$(sed -n 's/.*<admin-server-name>\([^<]*\)<.*/\1/p' "$cfg" | head -1)" '
    /<server>/{inb=1;inssl=0;n="";p=""} inb&&/<ssl>/{inssl=1} inb&&/<\/ssl>/{inssl=0}
    inb&&n==""&&match($0,/<name>[^<]*<\/name>/){n=substr($0,RSTART+6,RLENGTH-13)}
    inb&&!inssl&&p==""&&match($0,/<listen-port>[^<]*<\/listen-port>/){p=substr($0,RSTART+13,RLENGTH-27)}
    inb&&/<\/server>/{inb=0; if(n==a) print (p==""?"7001":p); if(n==T) print "T=" (p==""?"7001":p)}' T="${WLS_TARGET:-}" "$cfg")"
  WLS_TARGET_PORT="$(printf '%s\n' "$aport" | sed -n 's/^T=//p')"; aport="$(printf '%s\n' "$aport" | grep -v '^T=' | head -1)"
  [ -z "${WLS_ADMIN_URL:-}" ] && WLS_ADMIN_URL="t3://localhost:${aport:-7001}"
  [ -z "${ORDS_URL:-}" ] && ORDS_URL="http://localhost:${WLS_TARGET_PORT:-${aport:-7001}}/${WLS_ORDS_APP}/"
  return 0
}
# wls_deployer <args>: java weblogic.Deployer with the domain's environment and admin credentials
wls_deployer() {
  local creds=()
  if [ -n "${WLS_USERCONFIG:-}" ] && [ -n "${WLS_USERKEY:-}" ]; then creds=(-userconfigfile "$WLS_USERCONFIG" -userkeyfile "$WLS_USERKEY")
  elif [ -n "${WLS_ADMIN_USER:-}" ] && [ -n "${WLS_ADMIN_PASSWORD:-}" ]; then creds=(-username "$WLS_ADMIN_USER" -password "$WLS_ADMIN_PASSWORD")
  else err "WebLogic admin credentials needed: set WLS_USERCONFIG+WLS_USERKEY (preferred) or WLS_ADMIN_USER+WLS_ADMIN_PASSWORD"; return 1; fi
  log "CMD: java weblogic.Deployer -adminurl $WLS_ADMIN_URL $*"
  [ "$DRY_RUN" = 1 ] && return 0
  ( # shellcheck disable=SC1091
    . "$WLS_ORACLE_HOME/wlserver/server/bin/setWLSEnv.sh" >/dev/null 2>&1
    exec java weblogic.Deployer -adminurl "$WLS_ADMIN_URL" "${creds[@]}" -noexit "$@" ) >>"$LOG_FILE" 2>&1
}

# ---------------------------------------------------------------------------
# discovery
# ---------------------------------------------------------------------------
ords_detect() {
  wls_discover || true
  if [ -z "${ORDS_HOME:-}" ]; then
    local c; c="$(command -v ords 2>/dev/null)"; [ -n "$c" ] && ORDS_HOME="$(cd "$(dirname "$(readlink -f "$c")")/.." && pwd)"
  fi
  [ -z "${ORDS_HOME:-}" ] && for d in /opt/oracle/ords /opt/ords /u01/ords "$HOME/ords"; do [ -x "$d/bin/ords" ] && { ORDS_HOME="$d"; break; }; done
  [ -z "${ORDS_CONFIG:-}" ] && for d in /etc/ords/config /opt/oracle/ords/config "${ORDS_HOME:-/nonexistent}/config"; do [ -f "$d/global/settings.xml" ] && { ORDS_CONFIG="$d"; break; }; done
  if [ -n "${ORDS_HOME:-}" ] && [ -x "$ORDS_HOME/bin/ords" ]; then
    ORDS_VER="$("$ORDS_HOME/bin/ords" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  elif [ "$WLS_MODE" = 1 ]; then
    ORDS_VER="$(unzip -p "$WLS_ORDS_WAR" META-INF/MANIFEST.MF 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  fi
  if [ -z "${APEX_IMAGES_DIR:-}" ] && [ -f "${ORDS_CONFIG:-/nonexistent}/global/settings.xml" ]; then
    APEX_IMAGES_DIR="$(sed -n 's/.*key="standalone.static.path">\([^<]*\)<.*/\1/p' "$ORDS_CONFIG/global/settings.xml" | head -1)"
  fi
  [ -z "${ORDS_URL:-}" ] && ORDS_URL="http://localhost:8080/ords/"
  if [ "$WLS_MODE" = 1 ]; then ORDS_RUNNING="$(wait_for_url "$ORDS_URL" 1 && echo wls)"; else ORDS_RUNNING="$(pgrep -f 'ords.war|ords serve|ords --config' 2>/dev/null | head -1)"; fi
  [ -n "${APEX_IMAGES_DIR:-}" ] && [ -f "$APEX_IMAGES_DIR/apex_version.txt" ] && IMAGES_VER="$(grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' "$APEX_IMAGES_DIR/apex_version.txt" | head -1)"
}

db_detect() {
  sql_detect || return 1
  DB_VER="$(sql_val "(select version_full from v\$instance)" 2>/dev/null)"; [ -z "$DB_VER" ] && DB_VER="$(sql_val "(select version from v\$instance)")"
  [ -n "$DB_VER" ] || return 1
  DB_LOG_MODE="$(sql_val "(select log_mode from v\$database)")"
  DB_IS_CDB="$(sql_val "(select cdb from v\$database)")"
  DB_CON="$(sql_val "sys_context('userenv','con_name')")"
  APEX_SCHEMA="$(sql_val "(select schema from dba_registry where comp_id='APEX')")"
  APEX_STATUS="$(sql_val "(select status from dba_registry where comp_id='APEX')")"
  APEX_VER="$(sql_val "(select version_no from apex_release)" 2>/dev/null)"
  if [ -n "$APEX_SCHEMA" ]; then
    local n; n="$(sql_val "(select count(*) from dba_objects where owner='$APEX_SCHEMA' and object_name='WWV_FLOW_F4000_PLUGINS' and object_type='PACKAGE')" 2>/dev/null)"
    # the App Builder (app 4000) packages exist only in a full development install
    [ -z "$n" ] && n="$(sql_val "(select count(*) from dba_objects where owner='$APEX_SCHEMA' and object_name like 'WWV_FLOW_F4000%')" 2>/dev/null)"
    if [ "${n:-0}" -gt 0 ]; then APEX_TYPE="full"; else APEX_TYPE="runtime"; fi
    [ -n "${APEX_INSTALL_TYPE:-}" ] && APEX_TYPE="$APEX_INSTALL_TYPE"
    APEX_PATCHES="$(run_sql "select patch_number||' '||patch_version from apex_patches order by 1;" 2>/dev/null)"
  fi
  RESTORE_POINTS="$(run_sql "select name||' '||to_char(time,'YYYY-MM-DD')||' '||guarantee_flashback_database from v\$restore_point where name like 'APEXPATCH%' order by time;" 2>/dev/null)"
  return 0
}

setup_env() {
  export ORACLE_HOME ORACLE_SID
  ords_detect
  db_detect || warn "Cannot query the database (SQL_CMD='${SQL_CMD:-none}', SQL_CONNECT='${SQL_CONNECT:-/ as sysdba}'). Set ORACLE_HOME/ORACLE_SID or SQL_CONNECT in apex-patch.conf"
}

apex_schema_for() { # 26.2 -> APEX_260200 ; 24.2.3 -> APEX_240203
  local v="$1" a b c; IFS='.' read -r a b c <<<"$v"; printf 'APEX_%02d%02d%02d' "${a:-0}" "${b:-0}" "${c:-0}"
}
src_dir_for() { printf '%s/apex_%s/apex' "$APEX_BASE" "$1"; }   # where a release's unzipped 'apex' folder lives

# ---------------------------------------------------------------------------
cmd_inspect() {
  setup_env
  if [ "$JSON_OUT" = 1 ]; then
    printf '{"apex_version":"%s","apex_schema":"%s","apex_status":"%s","install_type":"%s","db_version":"%s","log_mode":"%s","container":"%s","is_cdb":"%s","ords_home":"%s","ords_version":"%s","ords_running":%s,"images_dir":"%s","images_version":"%s","restore_points":"%s"}\n' \
      "$APEX_VER" "$APEX_SCHEMA" "$APEX_STATUS" "$APEX_TYPE" "$DB_VER" "$DB_LOG_MODE" "$DB_CON" "$DB_IS_CDB" "${ORDS_HOME:-}" "$ORDS_VER" "$([ -n "$ORDS_RUNNING" ] && echo true || echo false)" "${APEX_IMAGES_DIR:-}" "$IMAGES_VER" "$(printf '%s' "$RESTORE_POINTS" | tr '\n' ';')"
    return 0
  fi
  cat <<EOF
Database         : ${DB_VER:-unreachable}  log mode ${DB_LOG_MODE:-?}  container ${DB_CON:-?}  cdb=${DB_IS_CDB:-?}
APEX version     : ${APEX_VER:-not installed}  schema ${APEX_SCHEMA:-?}  registry ${APEX_STATUS:-?}  type ${APEX_TYPE:-?}
APEX patches     :
$(printf '%s\n' "${APEX_PATCHES:-  (none)}" | sed 's/^/  /')
Releases on disk : $(ls -d "$APEX_BASE"/apex_*/apex 2>/dev/null | sed 's#.*/apex_\([^/]*\)/apex#\1#' | tr '\n' ' ')
ORDS             : $([ "$WLS_MODE" = 1 ] && echo "in WebLogic (app '$WLS_ORDS_APP', $WLS_ORDS_WAR)" || echo "${ORDS_HOME:-not found}")  version ${ORDS_VER:-?}  config ${ORDS_CONFIG:-?}  $([ -n "$ORDS_RUNNING" ] && echo running || echo stopped)  $ORDS_URL
Images dir       : ${APEX_IMAGES_DIR:-unknown}  (images version ${IMAGES_VER:-unknown})
Restore points   :
$(printf '%s\n' "${RESTORE_POINTS:-  (none)}" | sed 's/^/  /')
EOF
  [ "$DB_IS_CDB" = YES ] && [ "$DB_CON" = 'CDB$ROOT' ] && warn "Connected to CDB\$ROOT. APEX should be upgraded inside the PDB: set PDB=<name> (or SQL_CONNECT to the PDB service)."
  if net_ok; then
    cmd_latest >/dev/null 2>&1 || true
    if [ -n "$TARGET" ]; then echo "Newest release   : $TARGET available on download.oracle.com  ->  ./apex-patch.sh plan"
    else echo "Newest release   : none newer than $APEX_VER on download.oracle.com"; fi
  else echo "Newest release   : (no internet from here; newest on disk: $(local_latest | grep . || echo none) - put apex_<ver>.zip in $APEX_BASE/downloads/)"; fi
  return 0
}

cmd_plan() {
  [ -n "$DB_VER$APEX_VER" ] || setup_env
  reuse_or_init plan
  local ver="${1:-}"
  [ -n "$ver" ] || { cmd_latest >/dev/null 2>&1 || true; ver="$TARGET"; }
  echo
  echo "WOULD DO (nothing has been changed)"
  echo "  Now        : APEX ${APEX_VER:-?} ($APEX_TYPE, $APEX_SCHEMA) in ${DB_CON:-?} on DB ${DB_VER:-?}, $DB_LOG_MODE"
  if [ -z "$ver" ]; then echo "  Upgrade    : none - already on the newest release"; echo; return 0; fi
  echo "  Upgrade to : APEX $ver (schema $(apex_schema_for "$ver"))  from $APEX_DL_BASE/apex_$ver.zip (~300 MB, public)"
  echo "  Rollback   : apxdwngrd.sql from the ${APEX_VER%.*} source$([ -f "$(src_dir_for "${APEX_VER%.*}")/apxdwngrd.sql" ] && echo " (on disk)" || echo " (will be downloaded first)")$([ "$DB_LOG_MODE" = ARCHIVELOG ] && echo ", plus a guaranteed restore point" || echo "; NO restore point (NOARCHIVELOG)")"
  echo "  ORDS       : $([ "$WLS_MODE" = 1 ] && echo "app '$WLS_ORDS_APP' in WebLogic stopped/started with weblogic.Deployer" || echo "${ORDS_HOME:-not found here}${ORDS_SERVICE:+ (systemd $ORDS_SERVICE)}") - version ${ORDS_VER:-?} $([ -n "$ORDS_VER" ] && { version_ge "$ORDS_VER" 23.3 && echo OK || echo "TOO OLD, needs 23.3+"; })"
  echo "  Script     : $([ "$APEX_TYPE" = runtime ] && echo apxrtins.sql || echo apexins.sql) $APEX_TS $APEX_FILES_TS $APEX_TEMP_TS /i/   (APEX unavailable while it runs, typically 15-60 min)"
  echo "  Images     : ${APEX_IMAGES_DIR:-UNKNOWN - set APEX_IMAGES_DIR} (now ${IMAGES_VER:-?}) -> $ver"
  echo "  Afterwards : verify version/registry/invalid objects/ORDS URL; 'cleanup' later drops the restore point and $APEX_SCHEMA"
  echo "  Next step  : ./apex-patch.sh preflight $ver   (after 'download $ver', or just 'run')"
  echo
}

# ---------------------------------------------------------------------------
# latest / download
# ---------------------------------------------------------------------------
url_exists() { [ "$(curl -sIL -o /dev/null -w '%{http_code}' --max-time 20 -A 'Mozilla/5.0' "$1" || true)" = 200 ]; }

cmd_latest() {
  setup_env >/dev/null 2>&1 || true
  local from="${APEX_VER%%.*}" y m best=""
  if ! net_ok; then
    best="$(local_latest)"; [ -n "$best" ] || { err "No internet from this host and no release on disk: copy apex_<version>.zip (public download, no login) to $APEX_BASE/downloads/ and run again"; return 1; }
    log "No internet: newest release on disk is $best"
    if [ -n "$APEX_VER" ] && version_ge "$APEX_VER" "$best"; then log "Installed $APEX_VER is already at or above it."; TARGET=""; state_set latest uptodate; return 0; fi
    TARGET="$best"; state_set latest "$best"; return 0
  fi
  command -v curl >/dev/null || die "curl is required"
  [ -z "$from" ] || [ "$from" -lt 18 ] 2>/dev/null && from=18
  local to; to=$(( $(date +%y) + 1 ))
  log "Probing $APEX_DL_BASE for releases $from.x .. $to.x"
  for ((y = from; y <= to; y++)); do
    for m in 1 2 3; do
      if url_exists "$APEX_DL_BASE/apex_$y.$m.zip"; then best="$y.$m"; dbg "exists: $y.$m"; fi
    done
  done
  [ -n "$best" ] || { err "No APEX release found on $APEX_DL_BASE (offline? proxy? set HTTPS_PROXY)"; return 1; }
  if [ -n "$APEX_VER" ] && version_ge "$APEX_VER" "$best"; then
    log "Newest release is $best; installed $APEX_VER is already current."; TARGET=""; state_set latest uptodate; return 0
  fi
  log "Newest release: $best  (installed: ${APEX_VER:-none})"
  TARGET="$best"; state_set latest "$best"
}

cmd_download() {
  local ver="${1:-$TARGET}"
  [ -n "$ver" ] || { cmd_latest || return 1; ver="$TARGET"; [ -n "$ver" ] || return 0; }
  reuse_or_init download
  local dest="$APEX_BASE/apex_$ver"
  if [ -d "$dest/apex" ] && [ -f "$dest/apex/apexins.sql" ]; then log "APEX $ver already unpacked at $dest"; TARGET="$ver"; return 0; fi
  mkdir -p "$APEX_BASE/downloads" "$dest" || die "Cannot create $APEX_BASE (set APEX_BASE to a writable directory)"
  local zip="$APEX_BASE/downloads/apex_$ver.zip"
  if [ ! -f "$zip" ]; then
    net_ok || die "apex_$ver.zip is not at $zip and this host has no internet: download it (public, no login) on a machine that has and copy it there"
    log "Downloading apex_$ver.zip (about 300 MB)"
    [ "$DRY_RUN" = 1 ] || curl -sS -L --fail --retry 3 -A 'Mozilla/5.0' -o "$zip.part" "$APEX_DL_BASE/apex_$ver.zip" || { rm -f "$zip.part"; die "Download failed"; }
    [ "$DRY_RUN" = 1 ] || mv "$zip.part" "$zip"
  fi
  [ "$DRY_RUN" = 1 ] && { TARGET="$ver"; return 0; }
  unzip -tq "$zip" >/dev/null || { rm -f "$zip"; die "apex_$ver.zip is corrupt - deleted, run again"; }
  log "Unpacking to $dest"
  unzip -oq "$zip" -d "$dest" || die "unzip failed"
  [ -f "$dest/apex/apexins.sql" ] || die "Unexpected zip layout (no apex/apexins.sql)"
  TARGET="$ver"
}

# ---------------------------------------------------------------------------
cmd_preflight() {
  local ver="${1:-$TARGET}"
  setup_env; reuse_or_init preflight
  [ -n "$ver" ] || die "preflight needs a target version (run 'latest' or pass one)"
  local p=0
  [ -n "$DB_VER" ] || { err "No database access"; return 1; }
  [ -n "$APEX_VER" ] || { err "APEX is not installed in this database (fresh installs are not automated here)"; p=$((p + 1)); }
  if [ "$DB_IS_CDB" = YES ] && [ "$DB_CON" = 'CDB$ROOT' ]; then err "Connected to CDB\$ROOT - set PDB=<name>"; p=$((p + 1)); fi
  version_ge "$DB_VER" 19 || { err "Database $DB_VER is older than 19c; current APEX releases need 19c or later"; p=$((p + 1)); }
  if [ -n "$APEX_VER" ]; then
    version_ge "$APEX_VER" 18.1 || { err "APEX $APEX_VER cannot upgrade directly; Oracle requires 18.1 or later first"; p=$((p + 1)); }
    version_ge "$ver" "$APEX_VER" || { err "Target $ver is older than installed $APEX_VER"; p=$((p + 1)); }
    [ "$ver" = "${APEX_VER%.*}" ] || [ "$ver" = "$APEX_VER" ] && { log "APEX $APEX_VER already installed"; state_set uptodate 1; }
  fi
  [ "$APEX_STATUS" = VALID ] || warn "APEX registry status is '${APEX_STATUS:-?}' (expected VALID)"
  local inv; inv="$(sql_val "(select count(*) from dba_objects where owner='$APEX_SCHEMA' and status='INVALID')")"
  [ "${inv:-0}" -eq 0 ] || { warn "$inv invalid objects in $APEX_SCHEMA - 'heal' recompiles them (utlrp)"; }
  local t
  for t in "$APEX_TS" "$APEX_FILES_TS"; do
    [ "$(sql_val "(select count(*) from dba_tablespaces where tablespace_name=upper('$t'))")" = 1 ] || { err "Tablespace $t does not exist"; p=$((p + 1)); }
  done
  [ "$(sql_val "(select count(*) from dba_tablespaces where tablespace_name=upper('$APEX_TEMP_TS') and contents='TEMPORARY')")" = 1 ] || { err "Temp tablespace $APEX_TEMP_TS not found"; p=$((p + 1)); }
  if [ -n "$ORDS_VER" ]; then
    version_ge "$ORDS_VER" 23.3 || { err "ORDS $ORDS_VER is too old; APEX $ver needs ORDS 23.3 or later - upgrade ORDS first (ords-patch.sh)"; p=$((p + 1)); }
  else warn "ORDS not found on this host; make sure the ORDS that serves APEX is 23.3+ and that its images directory gets updated"; fi
  [ -n "${APEX_IMAGES_DIR:-}" ] || warn "Images directory unknown; set APEX_IMAGES_DIR so the /i/ files get updated (otherwise APEX will show 'files are not up-to-date')"
  local src; src="$(src_dir_for "$ver")"
  [ -f "$src/apexins.sql" ] || { err "Source for $ver not unpacked yet (run download)"; p=$((p + 1)); }
  # rollback readiness
  local prev_src; prev_src="$(src_dir_for "${APEX_VER%.*}")"
  if [ -f "$prev_src/apxdwngrd.sql" ]; then log "Rollback ready: previous release source at $prev_src"
  elif net_ok && url_exists "$APEX_DL_BASE/apex_${APEX_VER%.*}.zip"; then log "Previous release ${APEX_VER%.*} is downloadable; 'backup' fetches it so apxdwngrd.sql is on hand"
  else warn "Previous release ${APEX_VER%.*} source is not on disk or downloadable; rollback would rely on the restore point only"; fi
  if [ "$DB_LOG_MODE" = ARCHIVELOG ]; then log "ARCHIVELOG: a guaranteed restore point will be created (whole-database rollback possible)"
  else warn "NOARCHIVELOG: no restore point possible; rollback = apxdwngrd.sql only"; fi
  local free_mb; free_mb="$(df -Pm "$APEX_BASE" 2>/dev/null | awk 'NR==2{print $4}')"
  [ "${free_mb:-0}" -ge 2000 ] || { err "Less than 2 GB free under $APEX_BASE"; p=$((p + 1)); }
  {
    echo; echo "PLAN"
    echo "  Database   : $DB_VER ($DB_CON), APEX $APEX_VER ($APEX_TYPE, $APEX_SCHEMA) -> $ver ($(apex_schema_for "$ver"))"
    echo "  Steps      : backup (prev source + restore point + images tar) > stop ORDS > $([ "$APEX_TYPE" = runtime ] && echo apxrtins.sql || echo apexins.sql) $APEX_TS $APEX_FILES_TS $APEX_TEMP_TS /i/ > images > start ORDS > verify"
    echo "  Rollback   : apxdwngrd.sql from the ${APEX_VER%.*} source (Oracle's documented revert); flashback to restore point if that fails"
    echo "  Downtime   : APEX unavailable while apexins runs (typically 15-60 min)"
    [ "$p" -gt 0 ] && echo "  BLOCKED    : $p problem(s) above" || echo "  Nothing blocking."
  } | tee -a "$LOG_FILE" >&2
  state_set target "$ver"; state_set preflight_problems "$p"
  [ "$p" -eq 0 ]
}

# ---------------------------------------------------------------------------
cmd_backup() {
  setup_env; reuse_or_init backup
  local prev="${APEX_VER%.*}" prev_src; prev_src="$(src_dir_for "$prev")"
  if [ ! -f "$prev_src/apxdwngrd.sql" ]; then
    log "Fetching previous release $prev so its apxdwngrd.sql is available for rollback"
    TARGET="" ; cmd_download "$prev" || warn "Could not fetch previous release source; rollback will depend on the restore point"
  fi
  state_set prev_version "$APEX_VER"; state_set prev_schema "$APEX_SCHEMA"; state_set prev_type "$APEX_TYPE"
  if [ -n "${APEX_IMAGES_DIR:-}" ] && [ -d "$APEX_IMAGES_DIR" ]; then
    log "Backing up images dir $APEX_IMAGES_DIR"
    run_cmd tar -czf "$RUN_DIR/images-before.tar.gz" -C "$(dirname "$APEX_IMAGES_DIR")" "$(basename "$APEX_IMAGES_DIR")" || warn "images backup failed"
  fi
  if [ "$NO_RP" = 1 ]; then warn "Restore point skipped (--no-restore-point)"
  elif [ "$DB_LOG_MODE" = ARCHIVELOG ]; then
    local rp; rp="APEXPATCH_$(date +%Y%m%d_%H%M)"
    log "Creating guaranteed restore point $rp"
    if [ "$DRY_RUN" = 1 ] || run_sql "create restore point $rp guarantee flashback database;" >/dev/null; then state_set restore_point "$rp"; log "Restore point $rp created (remember 'cleanup' afterwards, it holds flashback logs)"
    else warn "Could not create a restore point (see log); continuing with apxdwngrd.sql as the rollback"; fi
  else warn "NOARCHIVELOG - no restore point"; fi
}

# ---------------------------------------------------------------------------
ords_stop() {
  ords_detect
  [ -n "$ORDS_RUNNING" ] || { log "ORDS not running on this host"; return 0; }
  if [ -n "${ORDS_STOP_CMD:-}" ]; then run_sh "$ORDS_STOP_CMD"
  elif [ "$WLS_MODE" = 1 ]; then wls_deployer -stop -name "$WLS_ORDS_APP" && { ORDS_RUNNING=""; state_set app_stopped 1; log "app $WLS_ORDS_APP stopped"; }; return $?
  elif [ -n "${ORDS_SERVICE:-}" ] || systemctl list-units --type=service 2>/dev/null | grep -q '\bords\.service'; then run_sh "sudo systemctl stop ${ORDS_SERVICE:-ords}"
  else log "Stopping ORDS pid $ORDS_RUNNING"; [ "$DRY_RUN" = 1 ] || kill "$ORDS_RUNNING"; fi
  local t=60; while [ "$DRY_RUN" = 0 ] && [ $t -gt 0 ] && kill -0 "$ORDS_RUNNING" 2>/dev/null; do sleep 5; t=$((t - 5)); done
  [ "$DRY_RUN" = 1 ] || ! kill -0 "$ORDS_RUNNING" 2>/dev/null || { [ "$FORCE" = 1 ] && kill -9 "$ORDS_RUNNING"; }
  ORDS_RUNNING=""
}
ords_start() {
  ords_detect
  [ -z "$ORDS_RUNNING" ] || { log "ORDS already running"; return 0; }
  if [ -n "${ORDS_START_CMD:-}" ]; then run_sh "$ORDS_START_CMD"
  elif [ "$WLS_MODE" = 1 ]; then wls_deployer -start -name "$WLS_ORDS_APP" || return 1; state_set app_stopped 0
  elif [ -n "${ORDS_SERVICE:-}" ] || systemctl list-units --type=service --all 2>/dev/null | grep -q '\bords\.service'; then run_sh "sudo systemctl start ${ORDS_SERVICE:-ords}"
  elif [ -n "${ORDS_HOME:-}" ] && [ -n "${ORDS_CONFIG:-}" ]; then run_sh "nohup '$ORDS_HOME/bin/ords' --config '$ORDS_CONFIG' serve >'$RUN_DIR/ords.out' 2>&1 &"
  else warn "Do not know how to start ORDS here (set ORDS_START_CMD or ORDS_SERVICE)"; return 0; fi
  [ "$DRY_RUN" = 1 ] && return 0
  wait_for_url "$ORDS_URL" "$START_TIMEOUT" && log "ORDS answers at $ORDS_URL" || { err "ORDS not answering at $ORDS_URL after ${START_TIMEOUT}s"; return 1; }
}
cmd_stop()  { reuse_or_init stop;  ords_stop; }
cmd_start() { reuse_or_init start; ords_start; }

# switch the directory ORDS serves as /i/ to <src>/images; remembers how, for rollback
images_switch() {
  local newimg="$1"
  [ -n "${APEX_IMAGES_DIR:-}" ] || { warn "No images dir configured; skipping (set APEX_IMAGES_DIR)"; return 0; }
  [ -d "$newimg" ] || { err "New images folder $newimg missing"; return 1; }
  if [ -L "$APEX_IMAGES_DIR" ]; then
    state_set images_prev_target "$(readlink "$APEX_IMAGES_DIR")"; state_set images_mode link
    log "Repointing symlink $APEX_IMAGES_DIR -> $newimg"
    run_cmd ln -sfn "$newimg" "$APEX_IMAGES_DIR"
  else
    local aside; aside="$APEX_IMAGES_DIR.before-$(date +%Y%m%d%H%M)"
    state_set images_prev_target "$aside"; state_set images_mode copy
    log "Moving $APEX_IMAGES_DIR aside to $aside and copying new images in"
    run_cmd mv "$APEX_IMAGES_DIR" "$aside" && run_cmd cp -a "$newimg" "$APEX_IMAGES_DIR"
  fi
}
images_revert() {
  local prev; prev="$(state_get images_prev_target)" || return 0
  [ -n "${APEX_IMAGES_DIR:-}" ] || return 0
  if [ "$(state_get images_mode)" = link ]; then run_cmd ln -sfn "$prev" "$APEX_IMAGES_DIR"
  elif [ -d "$prev" ]; then run_cmd rm -rf "$APEX_IMAGES_DIR" && run_cmd mv "$prev" "$APEX_IMAGES_DIR"; fi
}

# ---------------------------------------------------------------------------
cmd_apply() {
  local ver="${1:-$(state_get target)}"; [ -z "$ver" ] && ver="$TARGET"
  setup_env; reuse_or_init apply
  [ -n "$ver" ] || die "apply needs a version"
  local src; src="$(src_dir_for "$ver")"
  [ -f "$src/apexins.sql" ] || die "Source for $ver not found at $src (run download)"
  [ "$WLS_MODE" = 1 ] && [ "$(state_get app_stopped || true)" = 1 ] && ORDS_RUNNING=""   # stopped via weblogic.Deployer in this run
  [ -z "$ORDS_RUNNING" ] || { [ "$DRY_RUN" = 1 ] || die "ORDS is still running - run 'stop' first (or use 'run')"; }
  local script="apexins.sql"; [ "$APEX_TYPE" = runtime ] && script="apxrtins.sql"
  state_set apply_started "$ver"
  run_sql_script "$src" "$script" "$APEX_TS" "$APEX_FILES_TS" "$APEX_TEMP_TS" "/i/" || true   # the script's own exit code is unreliable; verify by querying
  [ "$DRY_RUN" = 1 ] && { state_set applied "$ver"; return 0; }
  if grep -q 'Thank you for installing Oracle APEX' "$LOG_FILE" && [ "$(sql_val "(select version_no from apex_release)" | cut -d. -f1,2)" = "$ver" ]; then
    log "APEX $ver installed in the database"
    state_set applied "$ver"
  else
    err "APEX install did not complete. Last errors:"; grep -E 'ORA-|SP2-|PLS-' "$LOG_FILE" | tail -10 >&2
    return 1
  fi
  images_switch "$src/images"
}

# ---------------------------------------------------------------------------
cmd_verify() {
  setup_env; reuse_or_init verify
  [ "$DRY_RUN" = 1 ] && { log "dry-run: skipping verification"; return 0; }
  local want ok=1; want="$(state_get target || state_get applied || true)"
  [ -n "$want" ] && { [ "$(printf '%s' "$APEX_VER" | cut -d. -f1,2)" = "$want" ] && log "apex_release says $APEX_VER" || { err "apex_release says '$APEX_VER', expected $want"; ok=0; }; }
  [ "$APEX_STATUS" = VALID ] && log "registry VALID" || { err "registry status '$APEX_STATUS'"; ok=0; }
  local inv; inv="$(sql_val "(select count(*) from dba_objects where owner='$APEX_SCHEMA' and status='INVALID')")"
  if [ "${inv:-0}" -gt 0 ]; then warn "$inv invalid objects in $APEX_SCHEMA - recompiling"; run_sql "exec sys.utl_recomp.recomp_parallel(4,'$APEX_SCHEMA')" >/dev/null 2>&1 || true
    inv="$(sql_val "(select count(*) from dba_objects where owner='$APEX_SCHEMA' and status='INVALID')")"; [ "${inv:-0}" -eq 0 ] || { err "$inv objects still invalid"; ok=0; }
  fi
  if [ -n "${APEX_IMAGES_DIR:-}" ] && [ -n "$want" ]; then
    [ -f "$APEX_IMAGES_DIR/apex_version.txt" ] && ! grep -q "$want" "$APEX_IMAGES_DIR/apex_version.txt" && { err "images dir still holds $IMAGES_VER, not $want"; ok=0; }
  fi
  if [ -n "${ORDS_HOME:-}" ] || [ -n "${ORDS_START_CMD:-}" ] || [ "$WLS_MODE" = 1 ]; then
    wait_for_url "$ORDS_URL" 30 && log "ORDS answers at $ORDS_URL" || { err "ORDS not answering at $ORDS_URL"; ok=0; }
  fi
  [ $ok = 1 ] && { log "VERIFY PASSED"; state_set verified 1; } || { err "VERIFY FAILED"; state_set verified 0; }
  [ $ok = 1 ]
}

# ---------------------------------------------------------------------------
cmd_rollback() {
  setup_env; reuse_or_init rollback
  local prev prev_schema new_schema; prev="$(state_get prev_version || true)"; prev_schema="$(state_get prev_schema || true)"
  [ -n "$prev" ] || die "No record of the previous version in $RUN_DIR (use --run-dir <dir of the upgrade run>)"
  new_schema="$(apex_schema_for "$(state_get target || state_get applied)")"
  local prev_src; prev_src="$(src_dir_for "${prev%.*}")"
  confirm "Revert APEX from $APEX_VER back to $prev (Oracle's apxdwngrd.sql)? Changes made in APEX since the upgrade are lost." || return 1
  ords_stop
  local done=0
  if [ -f "$prev_src/apxdwngrd.sql" ]; then
    log "Running apxdwngrd.sql from $prev_src"
    run_sql_script "$prev_src" apxdwngrd.sql || true
    if grep -q 'ORA-20001.*validate_apex\|WWV_FLOW_GLOBAL is in an invalid state' "$LOG_FILE"; then
      log "Finishing the downgrade as the Oracle docs describe"
      run_sql "begin $prev_schema.wwv_flow_db_env_detection.generate_wwv_flow_db_version; sys.validate_apex; end;
/" >/dev/null 2>&1 || true
    fi
    db_detect
    if [ "$DRY_RUN" = 1 ] || [ "$APEX_SCHEMA" = "$prev_schema" ]; then log "Database is back on $prev ($prev_schema)"; done=1
    else err "apxdwngrd.sql did not switch back (registry says $APEX_SCHEMA)"; fi
  else warn "Previous source $prev_src not available"; fi
  if [ $done = 0 ]; then
    local rp; rp="$(state_get restore_point || true)"
    if [ -n "$rp" ] && confirm_flashback "Flash the whole ${DB_CON:-database} back to restore point $rp? (everything in it since then is lost)"; then
      if [ "$DB_IS_CDB" = YES ] && [ -n "${PDB:-$DB_CON}" ] && [ "$DB_CON" != 'CDB$ROOT' ]; then
        local pdb="${PDB:-$DB_CON}"
        PDB="" run_sql "alter pluggable database $pdb close immediate;
flashback pluggable database $pdb to restore point $rp;
alter pluggable database $pdb open resetlogs;" >/dev/null && { done=1; log "Flashed $pdb back to $rp"; } || err "flashback failed - see $LOG_FILE"
      else
        err "Non-CDB flashback needs the whole instance restarted in MOUNT state; do it by hand: shutdown immediate; startup mount; flashback database to restore point $rp; alter database open resetlogs;"
      fi
    fi
  fi
  [ $done = 1 ] || { err "Rollback not completed: database is still on $APEX_VER ($APEX_SCHEMA). See Oracle's 'Reverting to a Previous Release After a Failed Upgrade Installation'."; ords_start || true; return 1; }
  images_revert
  state_set rolled_back 1
  ords_start || true
  if [ "$DRY_RUN" = 0 ] && [ "$(sql_val "(select count(*) from dba_users where username='$new_schema')")" = 1 ] && confirm "Drop the abandoned schema $new_schema now? (Oracle docs: 'DROP USER $new_schema CASCADE')"; then
    run_sql "drop user $new_schema cascade;" >/dev/null && log "$new_schema dropped" || warn "drop failed (see log); drop it later with 'cleanup'"
  fi
  log "Rollback complete: APEX $prev"
}

cmd_cleanup() {
  setup_env; reuse_or_init cleanup
  local rp; rp="$(state_get restore_point || true)"
  [ -n "$rp" ] && confirm "Drop restore point $rp (no more whole-database rollback)?" && run_sql "drop restore point $rp;" >/dev/null && log "$rp dropped"
  local old; old="$(state_get prev_schema || true)"
  if [ -n "$old" ] && [ "$old" != "$APEX_SCHEMA" ] && [ "$(sql_val "(select count(*) from dba_users where username='$old')")" = 1 ]; then
    confirm "Drop old APEX schema $old (Oracle suggests keeping it a few weeks first)?" && run_sql "drop user $old cascade;" >/dev/null && log "$old dropped"
  fi
  return 0
}

cmd_heal() {
  setup_env; reuse_or_init heal
  local found=0 fixed=0 inv
  if [ -n "$APEX_SCHEMA" ]; then
    inv="$(sql_val "(select count(*) from dba_objects where owner='$APEX_SCHEMA' and status='INVALID')")"
    if [ "${inv:-0}" -gt 0 ]; then found=$((found + 1)); log "Recompiling $inv invalid objects in $APEX_SCHEMA"; run_sql "exec sys.utl_recomp.recomp_parallel(4,'$APEX_SCHEMA')" >/dev/null 2>&1 && fixed=$((fixed + 1)); fi
  fi
  if [ -n "${APEX_IMAGES_DIR:-}" ] && [ -n "$IMAGES_VER" ] && [ -n "$APEX_VER" ] && [ "${IMAGES_VER%.*}" != "${APEX_VER%.*}" ]; then
    found=$((found + 1)); local src; src="$(src_dir_for "${APEX_VER%.*}")"
    if [ -d "$src/images" ]; then log "Images dir is $IMAGES_VER but APEX is $APEX_VER - switching"; images_switch "$src/images" && fixed=$((fixed + 1)); else warn "Images mismatch ($IMAGES_VER vs $APEX_VER) and no $src/images on disk: run 'download ${APEX_VER%.*}' then heal"; fi
  fi
  if [ -n "${ORDS_HOME:-}" ] && [ -z "$ORDS_RUNNING" ]; then found=$((found + 1)); warn "ORDS is not running"; confirm "Start ORDS?" && ords_start && fixed=$((fixed + 1)); fi
  if [ -n "$RESTORE_POINTS" ]; then found=$((found + 1)); warn "Guaranteed restore points exist (they fill the recovery area over time): $(printf '%s' "$RESTORE_POINTS" | tr '\n' ';')  -> 'cleanup' drops them"; fi
  log "heal: $found issue(s), $fixed fixed"
}

# ---------------------------------------------------------------------------
cmd_run() {
  init_run_dir run; setup_env
  local ver="${1:-}"
  log "=== 1/8 inspect"; cmd_inspect >"$RUN_DIR/inspect.txt"; cat "$RUN_DIR/inspect.txt"
  [ -n "$DB_VER" ] || die "No database access. Nothing changed."
  if [ -z "$ver" ]; then log "=== 2/8 latest"; cmd_latest || die "Cannot determine the newest release"; ver="$TARGET"; [ -n "$ver" ] || { log "Already current. Nothing to do."; return 0; }; fi
  log "=== 3/8 download"; cmd_download "$ver" || die "Download failed. Nothing changed."
  log "=== 4/8 preflight"; cmd_preflight "$ver" || { err "Preflight failed. Nothing changed."; return 1; }
  confirm "Upgrade APEX $APEX_VER -> $ver now? ORDS will be stopped and APEX unavailable while it runs." || return 1
  log "=== 5/8 backup"; cmd_backup
  log "=== 6/8 stop ORDS"; ords_stop
  log "=== 7/8 apply"
  if ! cmd_apply "$ver"; then
    err "Upgrade failed - reverting"; ASSUME_YES=1 cmd_rollback || err "Rollback incomplete - see $LOG_FILE and Oracle's 'Reverting after a failed upgrade' doc"
    return 1
  fi
  log "=== 8/8 start + verify"; ords_start || true
  if cmd_verify; then log "SUCCESS: APEX $ver. Run 'cleanup' in a week or two to drop the restore point and old schema. Log: $LOG_FILE"; return 0; fi
  err "Verify failed after upgrade"
  if [ "$FORCE" = 1 ] || confirm "Revert to $(state_get prev_version)?"; then ASSUME_YES=1 cmd_rollback; fi
  return 1
}

usage() { sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; }
main() {
  local cmd="" args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --apex-base) CLI_APEX_BASE="$2"; shift 2;; --images-dir) CLI_IMG="$2"; shift 2;; --pdb) CLI_PDB="$2"; shift 2;;
      --runtime) CLI_TYPE=runtime; shift;; --run-dir) RUN_DIR="$2"; shift 2;;
      --dry-run) DRY_RUN=1; shift;; --yes|-y) ASSUME_YES=1; shift;; --force) FORCE=1; shift;; --json) JSON_OUT=1; shift;;
      --verbose|-v) VERBOSE=1; shift;; --no-restore-point) NO_RP=1; shift;; --allow-flashback) ALLOW_FLASHBACK=1; shift;;
      -h|--help|help) usage; exit 0;; --version) echo "$VERSION"; exit 0;;
      -*) die "Unknown option $1";;
      *) [ -z "$cmd" ] && cmd="$1" || args+=("$1"); shift;;
    esac
  done
  [ -n "$cmd" ] || { usage; exit 1; }
  load_config
  [ -n "${CLI_APEX_BASE:-}" ] && APEX_BASE="$CLI_APEX_BASE"; [ -n "${CLI_IMG:-}" ] && APEX_IMAGES_DIR="$CLI_IMG"
  [ -n "${CLI_PDB:-}" ] && PDB="$CLI_PDB"; [ -n "${CLI_TYPE:-}" ] && APEX_INSTALL_TYPE="$CLI_TYPE"
  case "$cmd" in
    inspect) cmd_inspect;; plan) cmd_plan "${args[0]:-}";; latest) cmd_latest;; download) cmd_download "${args[0]:-}";; preflight) cmd_preflight "${args[0]:-}";;
    backup) cmd_backup;; stop) cmd_stop;; start) cmd_start;; apply) cmd_apply "${args[0]:-}";; verify) cmd_verify;;
    rollback) cmd_rollback;; cleanup) cmd_cleanup;; heal) cmd_heal;; run) cmd_run "${args[0]:-}";;
    *) die "Unknown command: $cmd";;
  esac
}
main "$@"
