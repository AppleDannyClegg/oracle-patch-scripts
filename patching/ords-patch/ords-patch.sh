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
#   inspect                 ORDS product dir + version, Java, config dir, pools, running?, URL, and the
#                           date of the newest ords-latest.zip on Oracle's site
#   plan                    What WOULD be done: version now, newest known, steps, rollback path
#   latest                  Download ords-latest.zip to ORDS_BASE/downloads and read its version
#   download                Same as latest (kept for symmetry with the other scripts)
#   preflight               Java/ORDS pairing, config dir sane, admin password available, disk, URL
#   backup                  Tar the config dir; create a guaranteed restore point if SQL access exists (fails if it cannot:
#                           --no-restore-point to upgrade without one)
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
OFFLINE="${OFFLINE:-0}"; NET_OK=""   # no internet: put ords-latest.zip (any ords*.zip) in $ORDS_BASE/downloads/ and run "latest" / "run"
net_ok() { [ "$OFFLINE" = 1 ] && return 1; [ -n "$NET_OK" ] || { NET_OK=0; command -v curl >/dev/null 2>&1 && curl -sI -m 5 -A 'Mozilla/5.0' -o /dev/null "$ORDS_DL_URL" >/dev/null 2>&1 && NET_OK=1; }; [ "$NET_OK" = 1 ]; }
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
optchk() { [ $# -ge 2 ] || die "$1 needs a value"; case "$2" in -[!0-9]*) die "$1 needs a value, got '$2'";; esac; }   # option value present and not another option
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
# A run outlives the terminal it was started from (the same rule as lib/oracle-lib.sh; this script stays
# self-contained). HUP is ignored for the rest of the run, so a lost ssh or a closed lid does not stop it between
# steps and never mid-step; and a run started from an INTERACTIVE shell must be detached first, or it is refused.
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

init_run_dir() {
  local new=0; [ -z "$RUN_DIR" ] && { RUN_DIR="$RUN_BASE/$(date '+%Y%m%d-%H%M%S')-${1:-run}"; new=1; }
  mkdir -p "$RUN_DIR" || die "Cannot create $RUN_DIR"
  LOG_FILE="$RUN_DIR/ords-patch.log"; STATE_FILE="$RUN_DIR/state"; ln -sfn "$RUN_DIR" "$RUN_BASE/latest"
  log "ords-patch $VERSION  run dir: $RUN_DIR  dry-run=$DRY_RUN"
  [ "$DRY_RUN" = 1 ] && [ "$new" = 1 ] && state_set dry_run 1   # a dir created by --dry-run: rollback/cleanup refuse it
  return 0
}
latest_run_dir() { [ -L "$RUN_BASE/latest" ] && readlink "$RUN_BASE/latest"; }
reuse_or_init() { [ -n "$RUN_DIR" ] && return 0; RUN_DIR="$(latest_run_dir)"; if [ -n "$RUN_DIR" ] && [ -d "$RUN_DIR" ]; then init_run_dir; else RUN_DIR=""; init_run_dir "$1"; fi; }
refuse_dry_run_dir() { [ "$(state_get dry_run || true)" = 1 ] && [ "$DRY_RUN" = 0 ] && die "$RUN_DIR is a --dry-run run (nothing in it happened): $1 needs the real run's dir (--run-dir)"; return 0; }
load_config() {
  local f
  for f in "$SCRIPT_DIR/../../oracle.conf" "$HOME/.oracle.conf" "$SCRIPT_DIR/ords-patch.conf" ./ords-patch.conf "$HOME/.ords-patch.conf"; do
    if [ -f "$f" ]; then set -a; # shellcheck disable=SC1090
      . "$f"; set +a; fi
  done
  # 'set -a' exported every conf variable: the passwords must not sit in the environment of every child (java, curl, tar, tee)
  local v; for v in $(compgen -A variable | grep -E 'PASSWORD|PASSWD|SECRET|_PASS($|_)|TOKEN|PWD|_CONNECT$' || true); do case "$v" in PWD|OLDPWD) ;; *) export -n "${v?}" 2>/dev/null || true;; esac; done   # same pattern as lib unexport_secrets (keep in sync); the shell's own PWD/OLDPWD stay
}
wait_for_url() {
  local url="$1" t="$2" code; command -v curl >/dev/null || { warn "no curl: cannot check $url"; return 1; }
  while [ "$t" -gt 0 ]; do
    code="$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" || true)"
    case "$code" in 200|30[1-3]|401|403) return 0;; esac
    t=$((t - 5)); [ "$t" -gt 0 ] || return 1; sleep 5
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
  # confirm() answers yes under --dry-run, so this is the guard: no statement that changes anything runs in a dry run
  if [ "$DRY_RUN" = 1 ] && ! printf '%s' "$1" | grep -qiE '^[[:space:]]*(select|with)[[:space:]]'; then log "DRY-RUN SQL: $(printf '%s' "$1" | head -1)"; return 0; fi
  # connect on stdin (/nolog): SQL_CONNECT may be user/pw@tns and must never sit on sqlplus's command line
  out="$(printf 'whenever sqlerror exit 1\nconnect %s\nset heading off feedback off pagesize 0 linesize 32767 trimspool on verify off\n%s\n%s\nexit\n' "${SQL_CONNECT:-/ as sysdba}" "${PDB:+alter session set container=$PDB;}" "$1" | $SQL_CMD -L /nolog 2>&1)" || { printf '%s\n' "$out" >>"${LOG_FILE:-/dev/null}"; return 1; }
  printf '%s\n' "$out" | grep -qE '^ERROR:|SP2-0640|ORA-01017|ORA-12[0-9]{3}|ORA-65011|ORA-65019' && { printf '%s\n' "$out" >>"${LOG_FILE:-/dev/null}"; return 1; }   # a failed connect is not an SQL error for 'whenever'
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
  local creds=() tmp="" rc
  if [ -n "${WLS_USERCONFIG:-}" ] && [ -n "${WLS_USERKEY:-}" ]; then creds=(-userconfigfile "$WLS_USERCONFIG" -userkeyfile "$WLS_USERKEY")
  elif [ -n "${WLS_ADMIN_USER:-}" ] && [ -n "${WLS_ADMIN_PASSWORD:-}" ]; then
    # weblogic.Deployer takes a password only as -password on its command line (visible in ps for the whole run), so the
    # pair is turned into a userconfig/userkey file pair first (WLST storeUserConfig; the password goes to WLST in a
    # 600-mode script, never on argv or in the environment) and removed again after the call
    log "CMD: wlst storeUserConfig for $WLS_ADMIN_USER (temporary userconfig/userkey for weblogic.Deployer)"
    if [ "$DRY_RUN" = 0 ]; then
      tmp="$(mktemp -d "${TMPDIR:-/tmp}/wlsuc.XXXXXX")" || { err "mktemp failed"; return 1; }; chmod 700 "$tmp"
      printf "connect('%s','%s','%s')\nstoreUserConfig('%s/cfg','%s/key')\nexit()\n" "$WLS_ADMIN_USER" "$WLS_ADMIN_PASSWORD" "$WLS_ADMIN_URL" "$tmp" "$tmp" >"$tmp/store.py"; chmod 600 "$tmp/store.py"
      ( # shellcheck disable=SC1091
        . "$WLS_ORACLE_HOME/wlserver/server/bin/setWLSEnv.sh" >/dev/null 2>&1
        echo y | WLST_PROPERTIES="-Dwlst.offline.log=/dev/null" "$WLS_ORACLE_HOME/oracle_common/common/bin/wlst.sh" -skipWLSModuleScanning "$tmp/store.py" ) >>"$LOG_FILE" 2>&1
      rm -f "$tmp/store.py"
      [ -s "$tmp/cfg" ] && [ -s "$tmp/key" ] || { rm -rf "$tmp"; err "WLST storeUserConfig failed (see $LOG_FILE): cannot call weblogic.Deployer without putting the password on its command line"; return 1; }
    fi
    creds=(-userconfigfile "$tmp/cfg" -userkeyfile "$tmp/key")
  else err "WebLogic admin credentials needed: set WLS_USERCONFIG+WLS_USERKEY (preferred) or WLS_ADMIN_USER+WLS_ADMIN_PASSWORD"; return 1; fi
  log "CMD: java weblogic.Deployer -adminurl $WLS_ADMIN_URL $*"
  [ "$DRY_RUN" = 1 ] && return 0
  ( # shellcheck disable=SC1091
    . "$WLS_ORACLE_HOME/wlserver/server/bin/setWLSEnv.sh" >/dev/null 2>&1
    exec java weblogic.Deployer -adminurl "$WLS_ADMIN_URL" "${creds[@]}" -noexit "$@" ) >>"$LOG_FILE" 2>&1; rc=$?
  [ -n "$tmp" ] && rm -rf "$tmp"
  return $rc
}

# ---------------------------------------------------------------------------
detect() {
  if [ -z "${ORDS_HOME:-}" ]; then
    local c; c="$(command -v ords 2>/dev/null)"; [ -n "$c" ] && c="$(readlink -f "$c")" && ORDS_HOME="$(cd "$(dirname "$c")/.." && pwd)"   # the RPM links /usr/local/bin/ords -> /opt/oracle/ords/bin/ords: the home is the target's
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
    ORDS_RUNNING="$(ords_pid)" || die "cannot read the process list (pgrep failed) - cannot tell whether ORDS is running"
  fi
  if [ -n "${ORDS_POOLS:-}" ]; then POOLS="$ORDS_POOLS"
  elif [ -d "${ORDS_CONFIG:-/nonexistent}/databases" ]; then POOLS="$(for d in "$ORDS_CONFIG"/databases/*/; do [ -f "$d/pool.xml" ] && basename "$d"; done 2>/dev/null | tr '\n' ' ')"; fi
  [ -z "${ORDS_URL:-}" ] && ORDS_URL="http://localhost:8080/ords/"
  # not ords.installed_version: as SYS that raises ORA-06598 (INHERIT PRIVILEGES) on 19c+; the version table is readable
  DB_SCHEMA_VER="$(sql_val "(select version from ords_metadata.ords_version where rownum=1)" 2>/dev/null)"
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
Newest on Oracle : $(zip_published)
EOF
  echo; echo "To see what would be done:  ./ords-patch.sh plan"
}

# date Oracle last published ords-latest.zip (cheap HEAD request); the version number is only inside the zip
zip_published() {
  net_ok || { local z; z="$(newest_zip_on_disk)"; if [ -n "$z" ]; then printf '(no internet from here; newest zip on disk: %s = %s)' "$z" "$(zip_version "$z")"; else printf '(no internet from here; put ords-latest.zip in %s/downloads/)' "$ORDS_BASE"; fi; return 0; }
  local h; h="$(curl -sIL --max-time 8 -A 'Mozilla/5.0' "$ORDS_DL_URL" 2>/dev/null | tr -d '\r')" || true
  local lm; lm="$(printf '%s\n' "$h" | sed -n 's/^[Ll]ast-[Mm]odified: *//p' | tail -1)"
  [ -n "$lm" ] && printf 'ords-latest.zip published %s (exact version known after '"'"'latest'"'"' downloads it)' "$lm" || printf '(download.oracle.com not reachable from here)'
}

cmd_plan() {
  setup_env
  reuse_or_init plan
  local nv nd; nv="$(state_get new_version || true)"; nd="$(state_get new_dir || true)"
  [ -d "$nd" ] || { nv=""; nd=""; for d in "$ORDS_BASE"/ords-*/; do [ -d "$d" ] && [ -x "$d/bin/ords" ] && { local v; v="$(basename "$d")"; v="${v#ords-}"; { [ -z "$nv" ] || version_ge "$v" "$nv"; } && { nv="$v"; nd="${d%/}"; }; }; done; }
  [ -n "$nv" ] && [ -n "$ORDS_VER" ] && version_ge "$ORDS_VER" "$nv" && nv=""
  echo
  echo "WOULD DO (nothing has been changed)"
  echo "  Now        : ORDS ${ORDS_VER:-?} $([ "$WLS_MODE" = 1 ] && echo "deployed in WebLogic as '$WLS_ORDS_APP' ($WLS_ORDS_WAR)" || echo "standalone at ${ORDS_HOME:-?}"), schema in DB ${DB_SCHEMA_VER:-?}, Java ${JAVA_VER:-none}, pools: ${POOLS:-none}"
  echo "  Newest     : $([ -n "$nv" ] && echo "$nv (already unpacked at $nd)" || zip_published)"
  if [ -n "$nv" ] && [ -n "$JAVA_VER" ] && ! java_ok_for "$nv"; then echo "  Java       : $JAVA_VER is NOT supported by ORDS $nv (needs $(version_ge "$nv" 25.1 && echo '17 or 21' || echo '11, 17 or 21'))"; fi
  echo "  Steps      : backup config$([ "$WLS_MODE" = 1 ] && echo "+war") + restore point (if SQL access and ARCHIVELOG) > stop $([ "$WLS_MODE" = 1 ] && echo "app '$WLS_ORDS_APP'" || echo ORDS) > for each pool: ords install --db-only (schema upgrade as $ORDS_ADMIN_USER) > $([ "$WLS_MODE" = 1 ] && echo "build new ords.war, replace, weblogic.Deployer -redeploy" || echo "point $ORDS_HOME at the new release") > start > verify (URL, pools, validate_apex)"
  echo "  Rollback   : $([ "$WLS_MODE" = 1 ] && echo "previous ords.war back + redeploy" || echo "symlink back to the previous release + restart"); schema rewind only via 'rollback --allow-flashback'"
  echo "  Next step  : ./ords-patch.sh latest   (downloads the zip and tells you the exact version), then preflight, then run"
  echo
}

# ---------------------------------------------------------------------------
# zip_version <zip>: the ORDS release inside a zip without unpacking it (plugin jar name in the listing, else the war manifest)
zip_version() { local v; v="$(unzip -l "$1" 2>/dev/null | grep -oE 'ords-plugin-api-[0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed 's/ords-plugin-api-//')"
  [ -z "$v" ] && { local w; w="$(mktemp)"; unzip -p "$1" ords.war >"$w" 2>/dev/null && v="$(unzip -p "$w" META-INF/MANIFEST.MF 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"; rm -f "$w"; }; printf '%s' "$v"; }
# newest_zip_on_disk: the ORDS zip in downloads/ with the highest release, not the newest file date (an older release copied later must not win)
newest_zip_on_disk() { local z best="" bv=""; for z in "$ORDS_BASE"/downloads/ords*.zip; do [ -f "$z" ] || continue; local v; v="$(zip_version "$z")"; if [ -z "$best" ] || { [ -n "$v" ] && { [ -z "$bv" ] || version_ge "$v" "$bv"; }; }; then best="$z"; bv="$v"; fi; done; printf '%s' "$best"; }
cmd_latest() {
  setup_env; reuse_or_init latest
  command -v unzip >/dev/null || die "unzip required"
  mkdir -p "$ORDS_BASE/downloads" || die "Cannot write to $ORDS_BASE"
  local zip; zip="$ORDS_BASE/downloads/ords-latest-$(date +%Y%m%d).zip"
  if ! net_ok; then
    zip="$(newest_zip_on_disk)"
    [ -n "$zip" ] || die "No internet from this host and no ORDS zip on disk: download ords-latest.zip (public, no login) elsewhere and copy it to $ORDS_BASE/downloads/"
    log "No internet: using $zip ($(date -r "$zip" '+%Y-%m-%d' 2>/dev/null || stat -c %y "$zip" | cut -c1-10))"
  elif [ ! -f "$zip" ]; then
    command -v curl >/dev/null || die "curl required"
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
  local free_mb; free_mb="$(df -Pm "$ORDS_BASE" 2>/dev/null | awk 'NR==2{print $4}')"
  if [ -z "$free_mb" ]; then err "cannot read the free space under $ORDS_BASE (df failed)"; p=$((p + 1)); elif [ "$free_mb" -lt 1500 ]; then err "Less than 1.5 GB free under $ORDS_BASE"; p=$((p + 1)); fi
  if [ "$WLS_MODE" = 1 ]; then
    [ -n "${WLS_USERCONFIG:-}${WLS_ADMIN_USER:-}" ] || { err "WebLogic mode needs admin credentials for weblogic.Deployer: WLS_USERCONFIG+WLS_USERKEY or WLS_ADMIN_USER+WLS_ADMIN_PASSWORD"; p=$((p + 1)); }
    [ -f "$WLS_ORACLE_HOME/wlserver/server/bin/setWLSEnv.sh" ] || { err "setWLSEnv.sh not found under $WLS_ORACLE_HOME"; p=$((p + 1)); }
    [ -f "$WLS_ORDS_WAR" ] || { err "Deployed war $WLS_ORDS_WAR is missing on disk"; p=$((p + 1)); }
    war_embeds_config; case $? in 0) log "ords.war carries its config dir ($ORDS_CONFIG); the new war will be built with 'ords --config $ORDS_CONFIG war'";; 2) err "cannot read WEB-INF/web.xml of $WLS_ORDS_WAR (unzip failed): cannot tell how the config dir reaches ORDS"; p=$((p + 1));; *) log "config dir comes from -Dconfig.url on the server; the stock ords.war from the new release will be deployed";; esac
  elif [ -n "$ORDS_HOME" ] && [ ! -L "$ORDS_HOME" ]; then warn "ORDS_HOME $ORDS_HOME is a real directory; apply will rename it to ${ORDS_HOME}-$ORDS_VER and make $ORDS_HOME a symlink (start scripts keep working)"; fi
  if [ -n "$ORDS_RUNNING" ]; then wait_for_url "$ORDS_URL" 5 && log "ORDS answers at $ORDS_URL now" || warn "ORDS running but $ORDS_URL does not answer - check ORDS_URL"; fi
  if sql_available; then local lm fra; lm="$(sql_val "(select log_mode from v\$database)" 2>/dev/null)"; fra="$(sql_val "(select nvl(max(value),'') from v\$parameter where name='db_recovery_file_dest')" 2>/dev/null)"
    if [ "$lm" = ARCHIVELOG ] && [ -n "$fra" ]; then log "SQL access, ARCHIVELOG and a recovery area: a guaranteed restore point will protect the ORDS schema upgrade"
    else warn "no restore point possible ($({ [ "$lm" = ARCHIVELOG ] || echo "log_mode $lm"; [ -n "$fra" ] || echo "no db_recovery_file_dest"; } | paste -sd, - | sed 's/,/, /g')): a failed schema upgrade can only be undone from a backup, the binaries can be switched back"; fi
  else warn "No SQL*Plus/SQLcl here: schema-level rollback not possible, only the binaries can be switched back"; fi
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
  # the pool wallets (cwallet.sso, the database password in clear for whoever holds the file) stay out of the tar: --db-only
  # does not touch them, and a run dir is what gets attached to incident packs
  run_cmd tar -czf "$RUN_DIR/ords-config-before.tar.gz" --exclude='*/wallet' --exclude='*/wallet/*' -C "$(dirname "$ORDS_CONFIG")" "$(basename "$ORDS_CONFIG")" || die "config backup failed"
  chmod 600 "$RUN_DIR/ords-config-before.tar.gz" 2>/dev/null || true
  state_set prev_dir "$ORDS_REAL"; state_set prev_version "$ORDS_VER"; state_set prev_was_link "$([ -L "${ORDS_HOME:-/nonexistent}" ] && echo 1 || echo 0)"
  if [ "$WLS_MODE" = 1 ]; then run_cmd cp -p "$WLS_ORDS_WAR" "$RUN_DIR/ords.war.before" || die "could not back up $WLS_ORDS_WAR"; state_set prev_war "$RUN_DIR/ords.war.before"; fi
  if [ "$NO_RP" = 1 ]; then warn "Restore point skipped"
  elif sql_available && [ "$(sql_val "(select log_mode from v\$database)")" = ARCHIVELOG ]; then
    local rp; rp="ORDSPATCH_$(date +%Y%m%d_%H%M)"
    if [ "$DRY_RUN" = 1 ]; then log "DRY-RUN: would create guaranteed restore point $rp"
    elif run_sql "create restore point $rp guarantee flashback database;" >/dev/null; then state_set restore_point "$rp"; log "Guaranteed restore point $rp created ('cleanup' drops it later)"; else err "Could not create restore point $rp (see $LOG_FILE): nothing changed. Fix the cause, or run again with --no-restore-point to upgrade with no way back for the schema"; return 1; fi
  else warn "No restore point (no SQL access or NOARCHIVELOG): the ORDS schema upgrade cannot be undone, only the binaries"; fi
}

ords_stop() {
  detect || true
  [ -n "$ORDS_RUNNING" ] || { log "ORDS not running"; return 0; }
  if [ -n "${ORDS_STOP_CMD:-}" ]; then run_sh "$ORDS_STOP_CMD"
  elif [ "$WLS_MODE" = 1 ]; then wls_deployer -stop -name "$WLS_ORDS_APP" && { ORDS_RUNNING=""; state_set app_stopped 1; log "app $WLS_ORDS_APP stopped"; }; return $?
  elif [ -n "${ORDS_SERVICE:-}" ] || systemctl list-units --type=service 2>/dev/null | grep -q '\bords\.service'; then run_sh "sudo systemctl stop ${ORDS_SERVICE:-ords}"
  else log "Stopping ORDS pid $ORDS_RUNNING"; [ "$DRY_RUN" = 1 ] || kill "$ORDS_RUNNING" || { err "cannot signal ORDS pid $ORDS_RUNNING (owner: $(ps -o user= -p "$ORDS_RUNNING" 2>/dev/null || echo '?')): not stopped"; return 1; }; fi
  [ "$DRY_RUN" = 1 ] && return 0
  # the proof is the process table, not kill -0: kill -0 also fails on a process this user may not signal (EPERM), which read as 'gone'
  # ... and a process table that cannot be read is 'cannot tell', not 'gone' (a ps that fails looks exactly like a pid that left)
  local t=60 st; while [ $t -gt 0 ]; do pid_alive "$ORDS_RUNNING"; st=$?; [ $st = 0 ] || break; sleep 5; t=$((t - 5)); done
  pid_alive "$ORDS_RUNNING"; st=$?
  [ $st = 2 ] && { err "cannot read the process table (ps -p failed) - cannot tell whether ORDS pid $ORDS_RUNNING stopped: not recorded as stopped"; return 1; }
  if [ $st = 0 ]; then
    if [ "$FORCE" = 1 ]; then kill -9 "$ORDS_RUNNING" 2>/dev/null; sleep 2; fi
    pid_alive "$ORDS_RUNNING"; st=$?
    [ $st = 2 ] && { err "cannot read the process table (ps -p failed) after kill -9 - cannot tell whether ORDS pid $ORDS_RUNNING stopped: not recorded as stopped"; return 1; }
    [ $st = 0 ] && { err "ORDS (pid $ORDS_RUNNING) is still running after 60 s$([ "$FORCE" = 1 ] || echo ' (--force sends kill -9)')"; return 1; }
  fi
  ORDS_RUNNING=""; log "ORDS stopped"
}
# ords_pid: the first ORDS pid, empty when none; rc 1 when pgrep itself could not run (rc 2/3) - an unreadable process list is not 'no ORDS'
ords_pid() { local p rc; p="$(pgrep -f 'ords.war|ords serve|ords --config' 2>/dev/null)"; rc=$?; [ $rc -le 1 ] || return 1; printf '%s\n' "$p" | head -1; }
# pid_alive <pid>: 0 alive, 1 gone, 2 the process table cannot be read (ps does not even show this shell) - 2 is never 'gone' (wls-patch 3ab88b8's stop)
pid_alive() { ps -p $$ -o pid= 2>/dev/null | grep -qE "^ *$$\$" || return 2; ps -p "$1" -o pid= 2>/dev/null | grep -qE "^ *$1\$"; }
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
    run_cmd mv "$ORDS_HOME" "$aside" && run_cmd ln -s "$target" "$ORDS_HOME" && { [ "$DRY_RUN" = 1 ] || state_set prev_dir "$aside"; }
  fi
}

# war_embeds_config: 0 = the deployed war's web.xml names config.url, 1 = it does not, 2 = the war could not be read (which is not 'no')
war_embeds_config() {
  local x; x="$(unzip -p "$WLS_ORDS_WAR" WEB-INF/web.xml 2>/dev/null)" || return 2
  printf '%s' "$x" | grep -q 'config.url'
}
cmd_apply() {
  setup_env; reuse_or_init apply
  local nd nv; nd="$(state_get new_dir || true)"; nv="$(state_get new_version || true)"
  [ -d "$nd" ] && [ -x "$nd/bin/ords" ] || die "No unpacked new release recorded (run 'latest' first)"
  [ "$WLS_MODE" = 1 ] && [ "$(state_get app_stopped || true)" = 1 ] && ORDS_RUNNING=""   # stopped via weblogic.Deployer in this run
  [ -z "$ORDS_RUNNING" ] || [ "$DRY_RUN" = 1 ] || die "ORDS still running - 'stop' first"
  local pw="${ORDS_ADMIN_PASSWORD:-}"
  if [ -z "$pw" ] && [ "$DRY_RUN" = 0 ]; then read -r -s -p "$ORDS_ADMIN_USER password for the ORDS schema upgrade: " pw; echo; fi
  local pwfile="$RUN_DIR/.pw"; ( umask 077; printf '%s\n' "$pw" >"$pwfile" ); trap 'rm -f "$RUN_DIR/.pw"' EXIT
  local pool rc=0
  for pool in $POOLS; do
    log "Upgrading ORDS schema in pool '$pool' with ORDS $nv"
    # ords refuses "--db-pool default" ("The default name is not allowed"): the default pool is addressed by leaving the option out
    local poolopt=(); [ "$pool" = default ] || poolopt=(--db-pool "$pool")
    if [ "$DRY_RUN" = 1 ]; then log "CMD: $nd/bin/ords --config $ORDS_CONFIG install ${poolopt[*]} --admin-user $ORDS_ADMIN_USER --db-only --password-stdin"; continue; fi
    if "$nd/bin/ords" --config "$ORDS_CONFIG" install "${poolopt[@]}" --admin-user "$ORDS_ADMIN_USER" --db-only --log-folder "$RUN_DIR" --password-stdin <"$pwfile" >>"$LOG_FILE" 2>&1; then
      log "  pool $pool: schema upgraded"; state_set "pool_$pool" ok
    else err "  pool $pool: ords install failed (see $LOG_FILE and $RUN_DIR/*.log)"; rc=1; break; fi
  done
  rm -f "$pwfile"
  [ $rc = 0 ] || return 1
  if [ "$WLS_MODE" = 1 ]; then
    local war="$nd/ords.war"
    # an unreadable deployed war used to read as 'no embedded config' and the plain war went out without its config dir
    war_embeds_config; local wrc=$?
    [ "$wrc" = 2 ] && { err "cannot read WEB-INF/web.xml of $WLS_ORDS_WAR (unzip failed): cannot tell whether the new war needs the config dir embedded - not deployed"; return 1; }
    if [ "$wrc" = 0 ]; then
      war="$nd/ords-deploy.war"; log "Building war with embedded config dir"
      [ "$DRY_RUN" = 1 ] || "$nd/bin/ords" --config "$ORDS_CONFIG" war "$war" >>"$LOG_FILE" 2>&1 || { err "ords war failed (see log)"; return 1; }
    fi
    log "Replacing $WLS_ORDS_WAR and redeploying '$WLS_ORDS_APP'"
    run_cmd cp -p "$war" "$WLS_ORDS_WAR" || return 1
    wls_deployer -redeploy -name "$WLS_ORDS_APP" || { err "redeploy failed (see log)"; return 1; }
    if [ -n "$ORDS_HOME" ]; then switch_home "$nd" || { err "the war is deployed but $ORDS_HOME was not switched to $nd - applied not recorded; fix the link, then 'verify'"; return 1; }; fi
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
  # the pools are checked with the release's own bin/ords: none recorded (WebLogic, war only) is the documented reliance on URL + schema
  # above; a recorded directory WITHOUT bin/ords is a wrong or half-unpacked release and used to end the loop silently as a pass
  if [ -z "$ob" ]; then warn "no ORDS_HOME and no release directory recorded: pools not verified (URL and schema checks only)"
  elif [ ! -x "$ob/bin/ords" ]; then err "$ob/bin/ords is missing or not executable: the pools ($POOLS) could not be verified"; ok=0
  else for pool in $POOLS; do
    if "$ob/bin/ords" --config "$ORDS_CONFIG" config --db-pool "$pool" verify >>"$LOG_FILE" 2>&1; then log "pool $pool verifies"; else err "pool $pool: 'ords config verify' failed (see log)"; ok=0; fi
  done; fi
  if sql_available && [ "$(sql_val "(select count(*) from dba_registry where comp_id='APEX')")" = 1 ]; then
    log "APEX present: running sys.validate_apex (Oracle requires this after every ORDS upgrade)"
    run_sql "begin sys.validate_apex; end;
/" >/dev/null 2>&1 && log "validate_apex OK" || { warn "validate_apex reported a problem (see log)"; }
  fi
  [ $ok = 1 ] && { log "VERIFY PASSED"; state_set verified 1; } || { err "VERIFY FAILED"; state_set verified 0; }
  [ $ok = 1 ]
}

cmd_rollback() {
  setup_env; reuse_or_init rollback; refuse_dry_run_dir rollback
  local prev pv; prev="$(state_get prev_dir || true)"; pv="$(state_get prev_version || true)"
  local pw; pw="$(state_get prev_war || true)"
  [ -d "$prev" ] || [ -f "$pw" ] || die "No previous ORDS directory/war recorded in $RUN_DIR"
  confirm "Switch ORDS back to ${pv:-the previous release}?" || return 1
  ords_stop || { err "ORDS could not be stopped: binaries NOT switched back (the new release would keep serving)"; return 1; }
  local failed=0
  if [ "$WLS_MODE" = 1 ]; then
    [ -f "$pw" ] && { run_cmd cp -p "$pw" "$WLS_ORDS_WAR" || { err "cannot put the old war back"; return 1; }; wls_deployer -redeploy -name "$WLS_ORDS_APP" || { err "redeploy of the old war failed"; failed=1; }; }
    [ -n "$ORDS_HOME" ] && [ -d "$prev" ] && [ "$(readlink -f "$prev")" != "$(readlink -f "$ORDS_HOME")" ] && { run_cmd ln -sfn "$prev" "$ORDS_HOME" || true; }
  elif [ "$(state_get prev_was_link)" = 0 ] && [ -L "$ORDS_HOME" ]; then run_cmd rm -f "$ORDS_HOME" && run_cmd mv "$prev" "$ORDS_HOME" || true
  elif [ "$(readlink -f "$prev")" = "$(readlink -f "$ORDS_HOME")" ]; then log "$ORDS_HOME already is the previous release (apply did not get to the switch)"
  else run_cmd ln -sfn "$prev" "$ORDS_HOME" || true; fi
  # the proof is what ORDS_HOME is now, not the ln/mv status: a link must resolve to the previous release, a moved-back
  # directory must be a real directory with bin/ords and the aside copy gone - otherwise rolled_back is not recorded
  if [ "$DRY_RUN" = 0 ] && [ -n "$ORDS_HOME" ] && { [ -d "$prev" ] || [ -f "$pw" ]; }; then
    if [ -L "$ORDS_HOME" ]; then
      [ -d "$prev" ] && [ "$(readlink -f "$ORDS_HOME" 2>/dev/null)" != "$(readlink -f "$prev")" ] && { err "$ORDS_HOME still is not the previous release after the switch back ($(ls -ld "$ORDS_HOME" 2>&1)): binaries NOT switched back"; failed=1; }
    elif [ -d "$prev" ] && [ "$(state_get prev_was_link)" = 0 ]; then
      { [ -x "$ORDS_HOME/bin/ords" ] && [ ! -e "$prev" ]; } || { err "$ORDS_HOME is not the previous release put back ($(ls -ld "$ORDS_HOME" 2>&1); $prev $([ -e "$prev" ] && echo 'still there' || echo gone)): binaries NOT switched back"; failed=1; }
    elif [ -d "$prev" ]; then err "$ORDS_HOME is neither a link to $prev nor the directory put back ($(ls -ld "$ORDS_HOME" 2>&1)): binaries NOT switched back"; failed=1; fi
  fi
  local rp; rp="$(state_get restore_point || true)"
  # any pool whose schema was upgraded (pool_<name>=ok) is on the new schema, whether or not 'applied' was reached
  if [ -n "$rp" ] && grep -q '^pool_.*=ok' "$STATE_FILE" 2>/dev/null; then
    warn "The ORDS schema in the database was upgraded; the old binaries may refuse a newer schema."
    if confirm_flashback "Flash the database back to restore point $rp? (ALL changes in it since the upgrade are lost)"; then
      local con; con="$(sql_val "sys_context('userenv','con_name')")"
      if [ -n "$con" ] && [ "$con" != 'CDB$ROOT' ] && [ "$(sql_val "(select cdb from v\$database)")" = YES ]; then
        PDB="" run_sql "alter pluggable database $con close immediate;
flashback pluggable database $con to restore point $rp;
alter pluggable database $con open resetlogs;" >/dev/null && log "Flashed back $con to $rp" || { err "flashback failed - see $LOG_FILE; the ORDS schema is still on the new release"; failed=1; }
      else err "Non-CDB: do it by hand: shutdown immediate; startup mount; flashback database to restore point $rp; alter database open resetlogs;"; failed=1; fi
    else warn "schema(s) upgraded and not flashed back: the old binaries may refuse the newer schema"; fi
  fi
  [ "$failed" = 0 ] || { state_set rolled_back 0; err "rollback incomplete - see $LOG_FILE"; ords_start || true; return 1; }
  state_set rolled_back 1
  ords_start && log "Rollback complete: ORDS $pv" || { err "ORDS did not start after rollback"; return 1; }
}

cmd_cleanup() {
  setup_env; reuse_or_init cleanup; refuse_dry_run_dir cleanup
  local rc=0 rp; rp="$(state_get restore_point || true)"
  if [ -n "$rp" ] && confirm "Drop restore point $rp?"; then
    if [ "$DRY_RUN" = 1 ]; then log "DRY-RUN: would drop restore point $rp"
    elif run_sql "drop restore point $rp;" >/dev/null; then log "$rp dropped"; state_set restore_point ""; else err "drop restore point $rp failed (see $LOG_FILE): it keeps pinning flashback logs in the recovery area"; rc=1; fi
  fi
  if [ "$DRY_RUN" = 1 ]; then find "$ORDS_BASE/downloads" -name 'ords-latest-*.zip' -mtime +30 -print 2>/dev/null | sed 's/^/would remove /' >&2
  else find "$ORDS_BASE/downloads" -name 'ords-latest-*.zip' -mtime +30 -print -delete 2>/dev/null | sed 's/^/removed /' >&2; fi
  return $rc
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
  require_detached run
  init_run_dir run; setup_env
  log "=== 1/7 inspect"; cmd_inspect | tee "$RUN_DIR/inspect.txt"
  log "=== 2/7 latest"; cmd_latest || die "Cannot get the newest ORDS. Nothing changed."
  [ "$(state_get latest || true)" = uptodate ] && { log "Already current. Nothing to do."; return 0; }
  log "=== 3/7 preflight"; cmd_preflight || { err "Preflight failed. Nothing changed."; return 1; }
  confirm "Upgrade ORDS $ORDS_VER -> $(state_get new_version) now? ORDS will be stopped." || return 1
  log "=== 4/7 backup"; cmd_backup || { err "Backup failed. Nothing changed."; return 1; }
  log "=== 5/7 stop"; ords_stop || die "Could not stop ORDS. The schema is untouched; the guaranteed restore point $(state_get restore_point || echo '(none)') stays until 'cleanup'."
  log "=== 6/7 apply"
  if ! cmd_apply; then err "Upgrade failed - rolling back"; ASSUME_YES=1 cmd_rollback || err "Rollback incomplete - see $LOG_FILE"; return 1; fi
  log "=== 7/7 start + verify"; ords_start || true
  if cmd_verify; then log "SUCCESS: ORDS $(state_get applied). Run 'cleanup' when happy. Log: $LOG_FILE"; return 0; fi
  err "Verify failed"; if [ "$FORCE" = 1 ] || confirm "Roll back to $(state_get prev_version)?"; then ASSUME_YES=1 cmd_rollback; fi
  return 1
}

usage() { sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; }
main() {
  local cmd="" args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --ords-base) optchk "$@"; CLI_BASE="$2"; shift 2;; --config) optchk "$@"; CLI_CFG="$2"; shift 2;; --run-dir) optchk "$@"; RUN_DIR="$2"; shift 2;;
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
    inspect) cmd_inspect;; plan) cmd_plan;; latest|download) cmd_latest;; preflight) cmd_preflight;; backup) cmd_backup;;
    stop) cmd_stop;; start) cmd_start;; apply) cmd_apply;; verify) cmd_verify;; rollback) cmd_rollback;;
    cleanup) cmd_cleanup;; heal) cmd_heal;; run) cmd_run;;
    *) die "Unknown command: $cmd";;
  esac
}
main "$@"
