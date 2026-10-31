#!/usr/bin/env bash
# ords-patch.sh - upgrade Oracle REST Data Services (ORDS) to the newest release: download
# (public, no login), preflight, backup, upgrade the ORDS schema in every database pool, switch
# the binaries, restart, verify, roll back on failure. Handles ORDS running standalone AND ORDS
# deployed inside WebLogic as ords.war (detected from the domain's config.xml: the war is rebuilt
# with the new release and redeployed with weblogic.Deployer). Runs on the ORDS/WebLogic host.
#
# Usage: ords-patch.sh <command> [args] [options]
#
# Commands
#   inspect                 ORDS product dir + version, Java, config dir, pools, running?, URL
#   latest                  Download ords-latest.zip to ORDS_BASE/downloads and read its version
#   download                Same as latest (kept for symmetry with the other scripts)
#   preflight               Java/ORDS pairing, config dir sane, admin password available, disk, URL
#   backup                  Tar the config dir; create a guaranteed restore point if SQL access exists
#   stop | start            Stop / start ORDS (systemd unit, ORDS_STOP_CMD/ORDS_START_CMD, or direct)
#   apply                   For each pool: ords install --db-only (schema upgrade); switch ORDS_HOME
#                           symlink to the new release
#   verify                  ords --version is the new one, URL answers, pools verify, validate_apex
#   rollback                Switch ORDS_HOME back to the previous release and restart; offer flashback
#   cleanup                 Drop the restore point, remove downloads older than the previous release
#   heal                    Stale pid, config permissions, missing symlink, Java on PATH, start ORDS
#   run                     latest > inspect > preflight > backup > stop > apply > start > verify,
#                           automatic rollback if apply or verify fails
#
# Options
#   --ords-base DIR   releases live here (default: parent of ORDS_HOME)   --config DIR  ORDS config dir
#   --dry-run  --yes  --force  --json  --verbose  --no-restore-point  --run-dir DIR
#   --allow-flashback   let 'rollback' flash the database container back to the restore point
#
# Config file (optional): ./ords-patch.conf or ~/.ords-patch.conf, KEY=VALUE lines:
#   ORDS_HOME (symlink or dir with bin/ords), ORDS_CONFIG, ORDS_BASE, JAVA_HOME, ORDS_ADMIN_USER (SYS),
#   ORDS_ADMIN_PASSWORD (or a prompt), ORDS_POOLS ("default pool2", default: all under config/databases),
#   ORDS_SERVICE (systemd unit), ORDS_STOP_CMD, ORDS_START_CMD, ORDS_URL, SQL_CMD, SQL_CONNECT, PDB,
#   RUN_BASE, START_TIMEOUT
#   WebLogic mode: WLS_ORACLE_HOME, WLS_DOMAIN_HOME, WLS_ORDS_APP (deployment name, default auto),
#   WLS_ADMIN_URL (t3://host:7001), WLS_USERCONFIG + WLS_USERKEY (from WLST storeUserConfig, preferred)
#   or WLS_ADMIN_USER + WLS_ADMIN_PASSWORD

set -o pipefail
VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0; ASSUME_YES=0; FORCE=0; JSON_OUT=0; VERBOSE=0; NO_RP=0; ALLOW_FLASHBACK=0
RUN_BASE="${RUN_BASE:-$HOME/ords-patch/runs}"
ORDS_DL_URL="${ORDS_DL_URL:-https://download.oracle.com/otn_software/java/ords/ords-latest.zip}"
ORDS_ADMIN_USER="${ORDS_ADMIN_USER:-SYS}"
START_TIMEOUT="${START_TIMEOUT:-300}"
RUN_DIR=""; LOG_FILE=""; STATE_FILE=""
ORDS_VER=""; ORDS_REAL=""; JAVA_VER=""; ORDS_RUNNING=""; POOLS=""; NEW_DIR=""; NEW_VER=""; DB_SCHEMA_VER=""

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
  LOG_FILE="$RUN_DIR/ords-patch.log"; STATE_FILE="$RUN_DIR/state"; ln -sfn "$RUN_DIR" "$RUN_BASE/latest"
  log "ords-patch $VERSION  run dir: $RUN_DIR  dry-run=$DRY_RUN"
}
latest_run_dir() { [ -L "$RUN_BASE/latest" ] && readlink "$RUN_BASE/latest"; }
reuse_or_init() { [ -n "$RUN_DIR" ] && return 0; RUN_DIR="$(latest_run_dir)"; [ -n "$RUN_DIR" ] && init_run_dir || init_run_dir "$1"; }
load_config() {
  local f
  for f in "$SCRIPT_DIR/ords-patch.conf" ./ords-patch.conf "$HOME/.ords-patch.conf"; do
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
sql_available() {
  [ -n "${SQL_CMD:-}" ] && return 0
  if [ -n "${ORACLE_HOME:-}" ] && [ -x "$ORACLE_HOME/bin/sqlplus" ]; then SQL_CMD="$ORACLE_HOME/bin/sqlplus -S"
  elif command -v sqlplus >/dev/null; then SQL_CMD="sqlplus -S"; elif command -v sql >/dev/null; then SQL_CMD="sql -S"; else return 1; fi
}
run_sql() {
  sql_available || return 1
  local out
  out="$(printf 'set heading off feedback off pagesize 0 linesize 32767 trimspool on verify off\nwhenever sqlerror exit 1\n%s\n%s\nexit\n' "${PDB:+alter session set container=$PDB;}" "$1" | $SQL_CMD "${SQL_CONNECT:-/ as sysdba}" 2>&1)" || { printf '%s\n' "$out" >>"${LOG_FILE:-/dev/null}"; return 1; }
  printf '%s\n' "$out" | sed '/^[[:space:]]*$/d'
}
sql_val() { run_sql "select $1 from dual;" 2>/dev/null | head -1 | sed 's/^ *//;s/ *$//'; }


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
detect() {
  if [ -z "${ORDS_HOME:-}" ]; then
    local c; c="$(command -v ords 2>/dev/null)"; [ -n "$c" ] && ORDS_HOME="$(cd "$(dirname "$c")/.." && pwd)"
  fi
  [ -z "${ORDS_HOME:-}" ] && for d in /opt/oracle/ords /opt/ords /u01/ords "$HOME/ords"; do [ -x "$d/bin/ords" ] && { ORDS_HOME="$d"; break; }; done
  wls_discover || true
  if [ -n "${ORDS_HOME:-}" ] && [ -x "$ORDS_HOME/bin/ords" ]; then
    ORDS_REAL="$(cd "$(readlink -f "$ORDS_HOME")" && pwd)"
    [ -z "${ORDS_BASE:-}" ] && ORDS_BASE="$(dirname "$ORDS_REAL")"
  elif [ "$WLS_MODE" = 1 ]; then
    ORDS_HOME=""; ORDS_REAL=""
    [ -z "${ORDS_BASE:-}" ] && ORDS_BASE="$(dirname "$WLS_ORDS_WAR")/ords-releases"
  else return 1; fi
  [ -z "${ORDS_CONFIG:-}" ] && for d in /etc/ords/config /opt/oracle/ords/config "$ORDS_HOME/config" "$ORDS_BASE/config"; do [ -f "$d/global/settings.xml" ] && { ORDS_CONFIG="$d"; break; }; done
  if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then JAVA_VER="$("$JAVA_HOME/bin/java" -version 2>&1 | head -1 | sed -n 's/.*version "\([^"]*\)".*/\1/p')"
  elif command -v java >/dev/null; then JAVA_VER="$(java -version 2>&1 | head -1 | sed -n 's/.*version "\([^"]*\)".*/\1/p')"; fi
  ORDS_VER=""
  [ -n "$ORDS_HOME" ] && ORDS_VER="$("$ORDS_HOME/bin/ords" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [ "$WLS_MODE" = 1 ]; then
    [ -z "$ORDS_VER" ] && ORDS_VER="$(unzip -p "$WLS_ORDS_WAR" META-INF/MANIFEST.MF 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    ORDS_RUNNING="$(wait_for_url "${ORDS_URL:-http://localhost:7001/ords/}" 1 && echo wls)"
  else
    ORDS_RUNNING="$(pgrep -f 'ords.war|ords serve|ords --config' 2>/dev/null | head -1)"
  fi
  if [ -n "${ORDS_POOLS:-}" ]; then POOLS="$ORDS_POOLS"
  elif [ -d "${ORDS_CONFIG:-/nonexistent}/databases" ]; then POOLS="$(ls "$ORDS_CONFIG/databases" 2>/dev/null | tr '\n' ' ')"; fi
  [ -z "${ORDS_URL:-}" ] && ORDS_URL="http://localhost:8080/ords/"
  DB_SCHEMA_VER="$(sql_val "ords.installed_version" 2>/dev/null)"
  return 0
}
setup_env() { export JAVA_HOME; detect || die "ORDS not found: no bin/ords directory and no ords.war deployed in a WebLogic domain here. Set ORDS_HOME (standalone) or WLS_DOMAIN_HOME (WebLogic) in ords-patch.conf"; }
java_major() { local j="${JAVA_VER%%.*}"; [ "$j" = 1 ] && { j="${JAVA_VER#1.}"; j="${j%%.*}"; }; printf '%s' "$j"; }
java_ok_for() { # ords version -> required java majors
  local v="$1" j; j="$(java_major)"; [ -n "$j" ] || return 1
  if version_ge "$v" 25.1; then [ "$j" = 17 ] || [ "$j" = 21 ]
  else [ "$j" = 11 ] || [ "$j" = 17 ] || [ "$j" = 21 ]; fi
}

cmd_inspect() {
  setup_env
  if [ "$JSON_OUT" = 1 ]; then
    printf '{"ords_home":"%s","real_dir":"%s","version":"%s","db_schema_version":"%s","java":"%s","config":"%s","pools":"%s","running":%s,"url":"%s"}\n' \
      "$ORDS_HOME" "$ORDS_REAL" "$ORDS_VER" "$DB_SCHEMA_VER" "$JAVA_VER" "${ORDS_CONFIG:-}" "$POOLS" "$([ -n "$ORDS_RUNNING" ] && echo true || echo false)" "$ORDS_URL"; return 0
  fi
  cat <<EOF
Mode             : $([ "$WLS_MODE" = 1 ] && echo "deployed in WebLogic: app '$WLS_ORDS_APP' = $WLS_ORDS_WAR on $WLS_TARGET (domain $WLS_DOMAIN_HOME)" || echo "standalone")
ORDS_HOME        : ${ORDS_HOME:-none} $([ -L "${ORDS_HOME:-/nonexistent}" ] && echo "-> $ORDS_REAL" || { [ -n "$ORDS_HOME" ] && echo "(real directory, not a symlink)"; })
ORDS version     : ${ORDS_VER:-?}   schema in DB: ${DB_SCHEMA_VER:-unknown (no SQL access)}
Java             : ${JAVA_VER:-none}  (JAVA_HOME=${JAVA_HOME:-unset})
Config dir       : ${ORDS_CONFIG:-not found}
Pools            : ${POOLS:-none}
Running          : $([ -n "$ORDS_RUNNING" ] && echo "yes (pid $ORDS_RUNNING)" || echo no)   URL $ORDS_URL
Releases on disk : $(for d in "$ORDS_BASE"/ords-*/; do [ -d "$d" ] && basename "$d"; done | tr '\n' ' ')
EOF
}

# ---------------------------------------------------------------------------
cmd_latest() {
  setup_env; reuse_or_init latest
  command -v curl >/dev/null || die "curl required"; command -v unzip >/dev/null || die "unzip required"
  mkdir -p "$ORDS_BASE/downloads" || die "Cannot write to $ORDS_BASE"
  local zip; zip="$ORDS_BASE/downloads/ords-latest-$(date +%Y%m%d).zip"
  if [ ! -f "$zip" ]; then
    log "Downloading $ORDS_DL_URL (about 200 MB)"
    if [ "$DRY_RUN" = 1 ]; then NEW_VER="(dry-run)"; return 0; fi
    curl -sS -L --fail --retry 3 -A 'Mozilla/5.0' -o "$zip.part" "$ORDS_DL_URL" || { rm -f "$zip.part"; die "Download failed (offline? proxy? HTTPS_PROXY)"; }
    mv "$zip.part" "$zip"
  fi
  unzip -tq "$zip" >/dev/null || { rm -f "$zip"; die "Downloaded zip is corrupt - deleted, run again"; }
  local tmp="$RUN_DIR/unpack"; rm -rf "$tmp"; mkdir -p "$tmp"; unzip -oq "$zip" -d "$tmp" || die "unzip failed"
  [ -x "$tmp/bin/ords" ] || chmod +x "$tmp/bin/ords" 2>/dev/null
  NEW_VER="$("$tmp/bin/ords" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  [ -n "$NEW_VER" ] || NEW_VER="$(unzip -p "$tmp/ords.war" META-INF/MANIFEST.MF 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  [ -n "$NEW_VER" ] || die "Cannot read the version of the downloaded ORDS (is Java working? $JAVA_VER)"
  NEW_DIR="$ORDS_BASE/ords-$NEW_VER"
  if [ -n "$ORDS_VER" ] && version_ge "$ORDS_VER" "$NEW_VER"; then
    log "Newest ORDS is $NEW_VER; installed $ORDS_VER is already current."; rm -rf "$tmp"; state_set latest uptodate; NEW_DIR=""; return 0
  fi
  if [ ! -d "$NEW_DIR" ]; then mv "$tmp" "$NEW_DIR" || die "Cannot create $NEW_DIR"; else rm -rf "$tmp"; fi
  log "Newest ORDS: $NEW_VER unpacked at $NEW_DIR  (installed: ${ORDS_VER:-?})"
  state_set new_version "$NEW_VER"; state_set new_dir "$NEW_DIR"
}

cmd_preflight() {
  setup_env; reuse_or_init preflight
  local p=0 nv; nv="$(state_get new_version || true)"
  [ -n "${ORDS_CONFIG:-}" ] || { err "ORDS config dir not found (set ORDS_CONFIG)"; p=$((p + 1)); }
  [ -n "$POOLS" ] || { err "No database pools under $ORDS_CONFIG/databases"; p=$((p + 1)); }
  [ -n "$JAVA_VER" ] || { err "No Java found"; p=$((p + 1)); }
  if [ -n "$nv" ] && [ -n "$JAVA_VER" ] && ! java_ok_for "$nv"; then
    err "ORDS $nv needs Java $(version_ge "$nv" 25.1 && echo '17 or 21' || echo '11, 17 or 21'); found $JAVA_VER (set JAVA_HOME)"; p=$((p + 1))
  fi
  if [ -z "${ORDS_ADMIN_PASSWORD:-}" ] && [ ! -t 0 ] && [ "$DRY_RUN" = 0 ]; then err "ORDS_ADMIN_PASSWORD not set and not interactive (needed to upgrade the ORDS schema as $ORDS_ADMIN_USER)"; p=$((p + 1)); fi
  if [ -n "$ORDS_VER" ] && ! version_ge "$ORDS_VER" 22.1; then warn "ORDS $ORDS_VER is pre-22.1 (java -jar ords.war era): the config must be migrated first with 'ords --config NEW install --legacy-config OLD'; this script does not automate that"; p=$((p + 1)); fi
  local free_mb; free_mb="$(df -Pm "$ORDS_BASE" | awk 'NR==2{print $4}')"; [ "${free_mb:-0}" -ge 1500 ] || { err "Less than 1.5 GB free under $ORDS_BASE"; p=$((p + 1)); }
  if [ "$WLS_MODE" = 1 ]; then
    [ -n "${WLS_USERCONFIG:-}${WLS_ADMIN_USER:-}" ] || { err "WebLogic mode needs admin credentials for weblogic.Deployer: WLS_USERCONFIG+WLS_USERKEY or WLS_ADMIN_USER+WLS_ADMIN_PASSWORD"; p=$((p + 1)); }
    [ -f "$WLS_ORACLE_HOME/wlserver/server/bin/setWLSEnv.sh" ] || { err "setWLSEnv.sh not found under $WLS_ORACLE_HOME"; p=$((p + 1)); }
    [ -f "$WLS_ORDS_WAR" ] || { err "Deployed war $WLS_ORDS_WAR is missing on disk"; p=$((p + 1)); }
    unzip -p "$WLS_ORDS_WAR" WEB-INF/web.xml 2>/dev/null | grep -q 'config.url' && log "ords.war carries its config dir ($ORDS_CONFIG); the new war will be built with 'ords --config $ORDS_CONFIG war'" || log "config dir comes from -Dconfig.url on the server; the stock ords.war from the new release will be deployed"
  elif [ -n "$ORDS_HOME" ] && [ ! -L "$ORDS_HOME" ]; then warn "ORDS_HOME $ORDS_HOME is a real directory; apply will rename it to ${ORDS_HOME}-$ORDS_VER and make $ORDS_HOME a symlink (start scripts keep working)"; fi
  if [ -n "$ORDS_RUNNING" ]; then wait_for_url "$ORDS_URL" 5 && log "ORDS answers at $ORDS_URL now" || warn "ORDS running but $ORDS_URL does not answer - check ORDS_URL"; fi
  sql_available && log "SQL access available: a restore point will protect the ORDS schema upgrade (if ARCHIVELOG)" || warn "No SQL*Plus/SQLcl here: schema-level rollback not possible, only the binaries can be switched back"
  {
    echo; echo "PLAN"; echo "  ORDS $ORDS_VER -> ${nv:-?}  pools: $POOLS  Java $JAVA_VER"
    if [ "$WLS_MODE" = 1 ]; then echo "  Steps: backup config+war > stop app '$WLS_ORDS_APP' > ords install --db-only per pool > build+replace war > redeploy > verify"
    else echo "  Steps: backup config > stop > ords install --db-only per pool > switch $ORDS_HOME > start > verify"; fi
    [ "$p" -gt 0 ] && echo "  BLOCKED: $p problem(s)" || echo "  Nothing blocking."
  } | tee -a "$LOG_FILE" >&2
  state_set preflight_problems "$p"; [ "$p" -eq 0 ]
}

cmd_backup() {
  setup_env; reuse_or_init backup
  log "Backing up config $ORDS_CONFIG"
  run_cmd tar -czf "$RUN_DIR/ords-config-before.tar.gz" -C "$(dirname "$ORDS_CONFIG")" "$(basename "$ORDS_CONFIG")" || die "config backup failed"
  state_set prev_dir "$ORDS_REAL"; state_set prev_version "$ORDS_VER"; state_set prev_was_link "$([ -L "${ORDS_HOME:-/nonexistent}" ] && echo 1 || echo 0)"
  if [ "$WLS_MODE" = 1 ]; then run_cmd cp -p "$WLS_ORDS_WAR" "$RUN_DIR/ords.war.before" || die "could not back up $WLS_ORDS_WAR"; state_set prev_war "$RUN_DIR/ords.war.before"; fi
  if [ "$NO_RP" = 1 ]; then warn "Restore point skipped"
  elif sql_available && [ "$(sql_val "(select log_mode from v\$database)")" = ARCHIVELOG ]; then
    local rp; rp="ORDSPATCH_$(date +%Y%m%d_%H%M)"
    if [ "$DRY_RUN" = 1 ] || run_sql "create restore point $rp guarantee flashback database;" >/dev/null; then state_set restore_point "$rp"; log "Guaranteed restore point $rp created ('cleanup' drops it later)"; else warn "Could not create restore point (see log)"; fi
  else warn "No restore point (no SQL access or NOARCHIVELOG): the ORDS schema upgrade cannot be undone, only the binaries"; fi
}

ords_stop() {
  detect || true
  [ -n "$ORDS_RUNNING" ] || { log "ORDS not running"; return 0; }
  if [ -n "${ORDS_STOP_CMD:-}" ]; then run_sh "$ORDS_STOP_CMD"
  elif [ "$WLS_MODE" = 1 ]; then wls_deployer -stop -name "$WLS_ORDS_APP" && { ORDS_RUNNING=""; state_set app_stopped 1; log "app $WLS_ORDS_APP stopped"; }; return $?
  elif [ -n "${ORDS_SERVICE:-}" ] || systemctl list-units --type=service 2>/dev/null | grep -q '\bords\.service'; then run_sh "sudo systemctl stop ${ORDS_SERVICE:-ords}"
  else log "Stopping ORDS pid $ORDS_RUNNING"; [ "$DRY_RUN" = 1 ] || kill "$ORDS_RUNNING"; fi
  [ "$DRY_RUN" = 1 ] && return 0
  local t=60; while [ $t -gt 0 ] && kill -0 "$ORDS_RUNNING" 2>/dev/null; do sleep 5; t=$((t - 5)); done
  if kill -0 "$ORDS_RUNNING" 2>/dev/null; then [ "$FORCE" = 1 ] && kill -9 "$ORDS_RUNNING" || { err "ORDS did not stop (use --force)"; return 1; }; fi
  ORDS_RUNNING=""; log "ORDS stopped"
}
ords_start() {
  detect || true
  [ -z "$ORDS_RUNNING" ] || { log "ORDS already running"; return 0; }
  if [ -n "${ORDS_START_CMD:-}" ]; then run_sh "$ORDS_START_CMD"
  elif [ "$WLS_MODE" = 1 ]; then wls_deployer -start -name "$WLS_ORDS_APP" || return 1; state_set app_stopped 0
  elif [ -n "${ORDS_SERVICE:-}" ] || systemctl list-units --type=service --all 2>/dev/null | grep -q '\bords\.service'; then run_sh "sudo systemctl start ${ORDS_SERVICE:-ords}"
  else run_sh "nohup '$ORDS_HOME/bin/ords' --config '$ORDS_CONFIG' serve >'$RUN_DIR/ords.out' 2>&1 &"; fi
  [ "$DRY_RUN" = 1 ] && return 0
  wait_for_url "$ORDS_URL" "$START_TIMEOUT" && log "ORDS answers at $ORDS_URL" || { err "ORDS not answering at $ORDS_URL after ${START_TIMEOUT}s (see $RUN_DIR/ords.out or the service log)"; return 1; }
}
cmd_stop()  { reuse_or_init stop; setup_env; ords_stop; }
cmd_start() { reuse_or_init start; setup_env; ords_start; }

switch_home() { # point ORDS_HOME at <dir>
  local target="$1"
  if [ -L "$ORDS_HOME" ]; then run_cmd ln -sfn "$target" "$ORDS_HOME"
  else
    local aside="${ORDS_HOME}-${ORDS_VER:-old}"
    log "Converting $ORDS_HOME into a symlink (old files kept at $aside)"
    run_cmd mv "$ORDS_HOME" "$aside" && run_cmd ln -s "$target" "$ORDS_HOME" && state_set prev_dir "$aside"
  fi
}

cmd_apply() {
  setup_env; reuse_or_init apply
  local nd nv; nd="$(state_get new_dir || true)"; nv="$(state_get new_version || true)"
  [ -d "$nd" ] && [ -x "$nd/bin/ords" ] || die "No unpacked new release recorded (run 'latest' first)"
  [ "$WLS_MODE" = 1 ] && [ "$(state_get app_stopped || true)" = 1 ] && ORDS_RUNNING=""   # stopped via weblogic.Deployer in this run
  [ -z "$ORDS_RUNNING" ] || [ "$DRY_RUN" = 1 ] || die "ORDS still running - 'stop' first"
  local pw="${ORDS_ADMIN_PASSWORD:-}"
  if [ -z "$pw" ] && [ "$DRY_RUN" = 0 ]; then read -r -s -p "$ORDS_ADMIN_USER password for the ORDS schema upgrade: " pw; echo; fi
  local pwfile="$RUN_DIR/.pw"; ( umask 077; printf '%s\n' "$pw" >"$pwfile" )
  local pool rc=0
  for pool in $POOLS; do
    log "Upgrading ORDS schema in pool '$pool' with ORDS $nv"
    if [ "$DRY_RUN" = 1 ]; then log "CMD: $nd/bin/ords --config $ORDS_CONFIG install --db-pool $pool --admin-user $ORDS_ADMIN_USER --db-only --password-stdin"; continue; fi
    if "$nd/bin/ords" --config "$ORDS_CONFIG" install --db-pool "$pool" --admin-user "$ORDS_ADMIN_USER" --db-only --log-folder "$RUN_DIR" --password-stdin <"$pwfile" >>"$LOG_FILE" 2>&1; then
      log "  pool $pool: schema upgraded"; state_set "pool_$pool" ok
    else err "  pool $pool: ords install failed (see $LOG_FILE and $RUN_DIR/*.log)"; rc=1; break; fi
  done
  rm -f "$pwfile"
  [ $rc = 0 ] || return 1
  if [ "$WLS_MODE" = 1 ]; then
    local war="$nd/ords.war"
    if unzip -p "$WLS_ORDS_WAR" WEB-INF/web.xml 2>/dev/null | grep -q 'config.url'; then
      war="$nd/ords-deploy.war"; log "Building war with embedded config dir"
      [ "$DRY_RUN" = 1 ] || "$nd/bin/ords" --config "$ORDS_CONFIG" war "$war" >>"$LOG_FILE" 2>&1 || { err "ords war failed (see log)"; return 1; }
    fi
    log "Replacing $WLS_ORDS_WAR and redeploying '$WLS_ORDS_APP'"
    run_cmd cp -p "$war" "$WLS_ORDS_WAR" || return 1
    wls_deployer -redeploy -name "$WLS_ORDS_APP" || { err "redeploy failed (see log)"; return 1; }
    [ -n "$ORDS_HOME" ] && switch_home "$nd"
  else
    switch_home "$nd" || return 1
    log "ORDS_HOME now -> $nd"
  fi
  state_set applied "$nv"
}

cmd_verify() {
  setup_env; reuse_or_init verify
  [ "$DRY_RUN" = 1 ] && { log "dry-run: skipping verification"; return 0; }
  local ok=1 want; want="$(state_get applied || state_get new_version || true)"
  if [ -z "$want" ] || [ "$ORDS_VER" = "$want" ]; then log "ORDS version: $ORDS_VER"
  elif [ "$WLS_MODE" = 1 ] && [ -z "$ORDS_HOME" ]; then warn "cannot read the deployed war's version ($ORDS_VER); relying on URL + schema checks"
  else err "ORDS version is $ORDS_VER, expected $want"; ok=0; fi
  wait_for_url "$ORDS_URL" 30 && log "URL answers: $ORDS_URL" || { err "$ORDS_URL not answering"; ok=0; }
  local pool
  local ob="${ORDS_HOME:-$(state_get new_dir || true)}"
  for pool in $POOLS; do
    [ -x "$ob/bin/ords" ] || break
    if "$ob/bin/ords" --config "$ORDS_CONFIG" config --db-pool "$pool" verify >>"$LOG_FILE" 2>&1; then log "pool $pool verifies"; else warn "pool $pool: 'ords config verify' not OK or unsupported on this version (see log)"; fi
  done
  if sql_available && [ "$(sql_val "(select count(*) from dba_registry where comp_id='APEX')")" = 1 ]; then
    log "APEX present: running sys.validate_apex (Oracle requires this after every ORDS upgrade)"
    run_sql "begin sys.validate_apex; end;
/" >/dev/null 2>&1 && log "validate_apex OK" || { warn "validate_apex reported a problem (see log)"; }
  fi
  [ $ok = 1 ] && { log "VERIFY PASSED"; state_set verified 1; } || { err "VERIFY FAILED"; state_set verified 0; }
  [ $ok = 1 ]
}

cmd_rollback() {
  setup_env; reuse_or_init rollback
  local prev pv; prev="$(state_get prev_dir || true)"; pv="$(state_get prev_version || true)"
  local pw; pw="$(state_get prev_war || true)"
  [ -d "$prev" ] || [ -f "$pw" ] || die "No previous ORDS directory/war recorded in $RUN_DIR"
  confirm "Switch ORDS back to ${pv:-the previous release}?" || return 1
  ords_stop || true
  if [ "$WLS_MODE" = 1 ]; then
    [ -f "$pw" ] && { run_cmd cp -p "$pw" "$WLS_ORDS_WAR"; wls_deployer -redeploy -name "$WLS_ORDS_APP" || err "redeploy of the old war failed"; }
    [ -n "$ORDS_HOME" ] && [ -d "$prev" ] && run_cmd ln -sfn "$prev" "$ORDS_HOME"
  elif [ "$(state_get prev_was_link)" = 0 ] && [ -L "$ORDS_HOME" ]; then run_cmd rm -f "$ORDS_HOME" && run_cmd mv "$prev" "$ORDS_HOME"
  else run_cmd ln -sfn "$prev" "$ORDS_HOME"; fi
  local rp; rp="$(state_get restore_point || true)"
  if [ -n "$rp" ] && [ -n "$(state_get applied || true)" ]; then
    warn "The ORDS schema in the database was upgraded; the old binaries may refuse a newer schema."
    if confirm_flashback "Flash the database back to restore point $rp? (ALL changes in it since the upgrade are lost)"; then
      local con; con="$(sql_val "sys_context('userenv','con_name')")"
      if [ -n "$con" ] && [ "$con" != 'CDB$ROOT' ] && [ "$(sql_val "(select cdb from v\$database)")" = YES ]; then
        PDB="" run_sql "alter pluggable database $con close immediate;
flashback pluggable database $con to restore point $rp;
alter pluggable database $con open resetlogs;" >/dev/null && log "Flashed back $con to $rp" || err "flashback failed - see $LOG_FILE"
      else err "Non-CDB: do it by hand: shutdown immediate; startup mount; flashback database to restore point $rp; alter database open resetlogs;"; fi
    fi
  fi
  state_set rolled_back 1
  ords_start && log "Rollback complete: ORDS $pv" || { err "ORDS did not start after rollback"; return 1; }
}

cmd_cleanup() {
  setup_env; reuse_or_init cleanup
  local rp; rp="$(state_get restore_point || true)"
  [ -n "$rp" ] && confirm "Drop restore point $rp?" && run_sql "drop restore point $rp;" >/dev/null && log "$rp dropped"
  find "$ORDS_BASE/downloads" -name 'ords-latest-*.zip' -mtime +30 -print -delete 2>/dev/null | sed 's/^/removed /' >&2
  return 0
}

cmd_heal() {
  setup_env; reuse_or_init heal
  local found=0 fixed=0
  if [ -n "$ORDS_RUNNING" ] && ! wait_for_url "$ORDS_URL" 5; then found=$((found + 1)); warn "ORDS process $ORDS_RUNNING exists but $ORDS_URL does not answer"; confirm "Restart ORDS?" && { ords_stop; ords_start && fixed=$((fixed + 1)); }; fi
  if [ -z "$ORDS_RUNNING" ]; then found=$((found + 1)); confirm "ORDS is not running. Start it?" && ords_start && fixed=$((fixed + 1)); fi
  if [ -n "${ORDS_CONFIG:-}" ] && [ ! -w "$ORDS_CONFIG/global/settings.xml" ]; then found=$((found + 1)); warn "$ORDS_CONFIG is not writable by $(id -un)"; fi
  if [ -n "$JAVA_VER" ] && [ -n "$ORDS_VER" ] && ! java_ok_for "$ORDS_VER"; then found=$((found + 1)); warn "Java $JAVA_VER is not supported by ORDS $ORDS_VER"; fi
  if [ -n "$ORDS_HOME" ] && [ -L "$ORDS_HOME" ] && [ ! -x "$ORDS_REAL/bin/ords" ]; then found=$((found + 1)); err "$ORDS_HOME points at $ORDS_REAL which has no bin/ords"; fi
  log "heal: $found issue(s), $fixed fixed"
}

cmd_run() {
  init_run_dir run; setup_env
  log "=== 1/7 inspect"; cmd_inspect | tee "$RUN_DIR/inspect.txt"
  log "=== 2/7 latest"; cmd_latest || die "Cannot get the newest ORDS. Nothing changed."
  [ "$(state_get latest || true)" = uptodate ] && { log "Already current. Nothing to do."; return 0; }
  log "=== 3/7 preflight"; cmd_preflight || { err "Preflight failed. Nothing changed."; return 1; }
  confirm "Upgrade ORDS $ORDS_VER -> $(state_get new_version) now? ORDS will be stopped." || return 1
  log "=== 4/7 backup"; cmd_backup
  log "=== 5/7 stop"; ords_stop || die "Could not stop ORDS. Nothing changed."
  log "=== 6/7 apply"
  if ! cmd_apply; then err "Upgrade failed - rolling back"; ASSUME_YES=1 cmd_rollback || err "Rollback incomplete - see $LOG_FILE"; return 1; fi
  log "=== 7/7 start + verify"; ords_start || true
  if cmd_verify; then log "SUCCESS: ORDS $(state_get applied). Run 'cleanup' when happy. Log: $LOG_FILE"; return 0; fi
  err "Verify failed"; if [ "$FORCE" = 1 ] || confirm "Roll back to $(state_get prev_version)?"; then ASSUME_YES=1 cmd_rollback; fi
  return 1
}

usage() { sed -n '2,39p' "$0" | sed 's/^# \{0,1\}//'; }
main() {
  local cmd="" args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --ords-base) CLI_BASE="$2"; shift 2;; --config) CLI_CFG="$2"; shift 2;; --run-dir) RUN_DIR="$2"; shift 2;;
      --dry-run) DRY_RUN=1; shift;; --yes|-y) ASSUME_YES=1; shift;; --force) FORCE=1; shift;; --json) JSON_OUT=1; shift;;
      --verbose|-v) VERBOSE=1; shift;; --no-restore-point) NO_RP=1; shift;; --allow-flashback) ALLOW_FLASHBACK=1; shift;;
      -h|--help|help) usage; exit 0;; --version) echo "$VERSION"; exit 0;;
      -*) die "Unknown option $1";;
      *) [ -z "$cmd" ] && cmd="$1" || args+=("$1"); shift;;
    esac
  done
  [ -n "$cmd" ] || { usage; exit 1; }
  load_config
  [ -n "${CLI_BASE:-}" ] && ORDS_BASE="$CLI_BASE"; [ -n "${CLI_CFG:-}" ] && ORDS_CONFIG="$CLI_CFG"
  case "$cmd" in
    inspect) cmd_inspect;; latest|download) cmd_latest;; preflight) cmd_preflight;; backup) cmd_backup;;
    stop) cmd_stop;; start) cmd_start;; apply) cmd_apply;; verify) cmd_verify;; rollback) cmd_rollback;;
    cleanup) cmd_cleanup;; heal) cmd_heal;; run) cmd_run;;
    *) die "Unknown command: $cmd";;
  esac
}
main "$@"
