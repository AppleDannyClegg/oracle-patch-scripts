#!/usr/bin/env bash
# dg-switchover.sh - Data Guard role transitions through the broker (DGMGRL): switchover, failover and
# reinstate, with preflight, a config/pfile backup, verification, reverse switchover as rollback, and
# healing of the usual broker warning states. Runs on a database server of the configuration as oracle.
#
# Usage: dg-switchover.sh <command> [args] [options]
#
# Commands
#   inspect                 Configuration, roles, protection mode, FSFO, lags, SRLs, services per role, role
#                           triggers, static DGMGRL listener entries, whether the client TNS aliases cover both sites
#   plan [target]           What run would do, touching nothing
#   preflight [target]      validate database, lags zero, no gap, no ORA- in v$dataguard_status for an hour, temp
#                           files, SRLs, flashback, no RMAN/datapatch, long transactions, switchover_status, FSFO target
#   backup                  Broker config and properties dump, pfile, controlfile trace, tnsnames/listener copies,
#                           guaranteed restore point on the primary with --restore-point
#   switchover [target]     dgmgrl switchover to <target>; starts what the broker could not restart; role services
#   failover [target]       dgmgrl failover to <target> (--immediate discards unapplied redo); the target's name must
#                           be typed back; refuses while the primary still runs unless --force; prints reinstate steps
#   reinstate [old-primary] Mount the old primary (if local) and dgmgrl reinstate it as a standby (needs flashback on)
#   verify                  Configuration SUCCESS, roles as intended, apply on, lags back to zero, services, app TNS test
#   rollback                Switchover back to the database that was primary before this run
#   cleanup                 Drop this run's restore point
#   heal                    ORA-16810/16820/16853/16857/16826/16766/16764/16661 and friends: cause plus fix, with confirmation
#   run [target]            inspect > preflight > backup > switchover > verify (offers rollback when verify fails)
#
# Options
#   --sid SID            local instance to talk to (default: ORACLE_SID or the only running instance)
#   --target DBUN        db_unique_name of the standby to switch or fail over to (default: the only physical standby)
#   --tns ALIAS[,ALIAS]  client TNS aliases the applications use (checked for both sites, tested after the switch)
#   --connect STR        DGMGRL connection for role changes: sys@TNS (password prompted once), /@TNS (wallet) or /
#   --restore-point      guaranteed restore point DGSWITCH_<ts> on the primary before switching
#   --immediate          failover immediate (do not wait for the remaining redo to be applied)
#   --wait SECS          how long verify waits for the lags to reach zero (default 300)
#   --dry-run  --yes  --force  --json  --verbose  --run-dir DIR
#
# Config: dg-switchover.conf, ~/.dg-switchover.conf or the shared oracle.conf: ORACLE_SID, DG_TARGET, DG_CONNECT,
# DG_PASSWORD (600-mode file only), APP_TNS, APP_TEST_CONNECT (user/pw@alias for the post-switch test),
# PRIMARY_SERVICES (names that must be up on the primary afterwards), DG_MAX_LAG_SEC, DG_VERIFY_WAIT, DG_SWITCH_TIMEOUT.

# shellcheck disable=SC2034
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="dg-switchover"; VERSION="1.0.0"
# shellcheck source=../../lib/oracle-lib.sh
. "$SCRIPT_DIR/../../lib/oracle-lib.sh" || { echo "lib/oracle-lib.sh not found" >&2; exit 1; }

SID="${ORACLE_SID:-}"; TARGET="${DG_TARGET:-}"; APP_TNS="${APP_TNS:-}"; DG_CONNECT="${DG_CONNECT:-}"
DG_MAX_LAG_SEC="${DG_MAX_LAG_SEC:-60}"; DG_VERIFY_WAIT="${DG_VERIFY_WAIT:-300}"; DG_SWITCH_TIMEOUT="${DG_SWITCH_TIMEOUT:-1800}"
PRIMARY_SERVICES="${PRIMARY_SERVICES:-}"; WANT_RP=0; IMMEDIATE=0
# detected
LOCAL_DBUN=""; LOCAL_ROLE=""; LOCAL_OPEN=""; LOCAL_NAME=""; DB_HOME=""; GRID_HOME=""; BROKER_ON=""
CFG=""; CFG_NAME=""; CFG_STATUS=""; MEMBERS=""; PRIMARY=""; STANDBYS=""; PROT_MODE=""; FSFO=""; FSFO_TARGET=""

usage() { usage_from_header "$0"; }
parse_opts() {
  ARGS=()
  while [ $# -gt 0 ]; do case "$1" in
    --sid) optchk "$@"; SID="$2"; shift 2;; --target) optchk "$@"; TARGET="$2"; shift 2;; --tns) optchk "$@"; APP_TNS="$2"; shift 2;; --connect) optchk "$@"; DG_CONNECT="$2"; shift 2;;
    --restore-point) WANT_RP=1; shift;; --immediate) IMMEDIATE=1; shift;; --wait) optchk "$@"; DG_VERIFY_WAIT="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;; --yes) ASSUME_YES=1; shift;; --force) FORCE=1; shift;; --json) JSON_OUT=1; shift;; --verbose) VERBOSE=1; shift;; --run-dir) optchk "$@"; RUN_DIR="$2"; shift 2;;
    -h|--help) usage; exit 0;; --*) die "Unknown option: $1";; *) ARGS+=("$1"); shift;; esac; done
}

# ---------------------------------------------------------------------------
# DGMGRL
# ---------------------------------------------------------------------------
lc() { tr '[:upper:]' '[:lower:]'; }
same_db() { [ "$(printf '%s' "$1" | lc)" = "$(printf '%s' "$2" | lc)" ]; }
dgmgrl_bin() { if [ -n "${DGMGRL_CMD:-}" ]; then printf '%s' "$DGMGRL_CMD"; elif [ -x "$DB_HOME/bin/dgmgrl" ]; then printf '%s/bin/dgmgrl' "$DB_HOME"; elif have dgmgrl; then printf 'dgmgrl'; fi; }
# dgm_as <connect> <secs> <commands>: "\n"-separated commands on stdin; the connect string never reaches a command line
dgm_as() {
  local conn="$1" secs="$2"; shift 2
  local nl q bin; nl=$'\n'; q="${*//\\n/$nl}"; bin="$(dgmgrl_bin)"
  [ -n "$bin" ] || { echo "no dgmgrl for $SID"; return 1; }
  dbg "DGMGRL as ${conn%%/*}@${conn##*@}: $q"
  printf 'connect %s\n%s\nexit\n' "$conn" "$q" | ORACLE_SID="$SID" ORACLE_HOME="$DB_HOME" LD_LIBRARY_PATH="$DB_HOME/lib:${LD_LIBRARY_PATH:-}" PATH="$DB_HOME/bin:$PATH" to "$secs" "$bin" -silent 2>&1 | grep -vE '^DGMGRL>|^Connected (to|as)|^$'
}
dgm() { dgm_as / "$SQL_TIMEOUT" "$@"; }
showdb() { dgm "show database $1"; }
# dbfield <text> <label>: value of "  Label:   value (computed ...)"
dbfield() { printf '%s\n' "$1" | sed -n "s/^ *$2: *//p" | head -1 | sed 's/ *(computed.*//; s/ *$//'; }
dbstatus() { printf '%s\n' "$1" | awk '/^Database Status:/{getline; print $1; exit}'; }
# lag_secs "2 minutes 3 seconds" -> 123; unknown/empty -> -1
lag_secs() {
  local s="$1"; { [ -z "$s" ] || [[ "${s,,}" == *unknown* ]] || ! [[ "$s" =~ [0-9] ]]; } && { echo -1; return; }   # "(unknown)", "UNKNOWN", no number: -1, never 0
  printf '%s\n' "$s" | awk '{t=0; for(i=1;i<NF;i++){ if($(i+1)~/^day/)t+=$i*86400; else if($(i+1)~/^hour/)t+=$i*3600; else if($(i+1)~/^minute/)t+=$i*60; else if($(i+1)~/^second/)t+=$i } print t}'
}
# dg_conn <database the command targets>: connection for a role change. Local database: OS auth. Remote: sys@<name>
# unless DG_CONNECT says otherwise; the password is prompted once and only ever travels on dgmgrl's stdin.
dg_conn() {
  local c="${DG_CONNECT:-}"
  [ -z "$c" ] && { if same_db "$1" "$LOCAL_DBUN"; then c="/"; else c="sys@$1"; fi; }
  case "$c" in
    /|/@*) printf '%s' "$c";;
    *@*) [ "$DRY_RUN" = 1 ] && { printf '%s' "$c"; return 0; }; local u="${c%%@*}" t="${c#*@}"; read_secret DG_PASSWORD "Password for $u on $t"; printf '%s/"%s"@%s' "$u" "$DG_PASSWORD" "$t";;
    *) die "DG_CONNECT must be /, /@TNS or user@TNS (got '$c')";;
  esac
}
conn_shown() { case "$1" in /) echo "/ (OS authentication, local)";; /@*) echo "$1 (wallet)";; */*) echo "${1%%/*}@${1##*@} (password on stdin)";; *) echo "$1 (password prompted)";; esac; }

# ---------------------------------------------------------------------------
# discovery
# ---------------------------------------------------------------------------
discover() {
  [ -n "$CFG" ] && return 0
  if [ -z "$SID" ]; then local n; n="$(db_instances | grep -c .)"; [ "$n" = 1 ] && SID="$(db_instances)"; fi
  [ -z "$SID" ] && die "Which instance? --sid SID (running: $(db_instances | tr '\n' ' '))"
  DB_HOME="$(db_home_of "$SID")"; GRID_HOME="$(grid_home)"
  sql_ok "$SID" || die "cannot connect to $SID as sysdba (ORACLE_HOME $DB_HOME)"
  IFS='|' read -r LOCAL_DBUN LOCAL_ROLE LOCAL_OPEN LOCAL_NAME <<<"$(sql_lines "$SID" "select db_unique_name||'|'||database_role||'|'||open_mode||'|'||name from v\$database;" | head -1)"
  BROKER_ON="$(sql_val "$SID" "(select upper(value) from v\$parameter where name='dg_broker_start')")"
  CFG="$(dgm "show configuration")" || true
  if printf '%s' "$CFG" | grep -qE 'ORA-165(01|25|32)|ORA-16596|ORA-01034|not available'; then
    die "Broker not usable on $SID (dg_broker_start=$BROKER_ON): $(printf '%s\n' "$CFG" | grep -E 'ORA-' | head -1)"
  fi
  CFG_NAME="$(printf '%s\n' "$CFG" | sed -n 's/^Configuration - *//p' | head -1)"
  MEMBERS="$(printf '%s\n' "$CFG" | sed -E 's/\(\*\) //' | sed -nE 's/^ *([A-Za-z0-9_$.-]+) +- +(Primary database|Physical standby database|Logical standby database|Snapshot standby database|Far sync instance).*/\1|\2/p')"
  [ -n "$MEMBERS" ] || die "could not read the members from 'show configuration':$(printf '\n%s' "$CFG" | head -20)"
  PRIMARY="$(printf '%s\n' "$MEMBERS" | awk -F'|' '$2=="Primary database"{print $1; exit}')"
  STANDBYS="$(printf '%s\n' "$MEMBERS" | awk -F'|' '$2 ~ /standby/{print $1}' | tr '\n' ' ')"
  PROT_MODE="$(printf '%s\n' "$CFG" | sed -n 's/^ *Protection Mode: *//p' | head -1)"
  FSFO="$(printf '%s\n' "$CFG" | sed -n 's/^Fast-Start Failover: *//p' | head -1 | awk '{print $1}')"
  FSFO_TARGET="$(printf '%s\n' "$CFG" | sed -nE 's/^ *([A-Za-z0-9_$.-]+) +- +\(\*\) .*/\1/p' | head -1)"
  CFG_STATUS="$(printf '%s\n' "$CFG" | awk '/^Configuration Status:/{getline; print $1; exit}')"
  if [ -z "$TARGET" ]; then local phys; phys="$(printf '%s\n' "$MEMBERS" | awk -F'|' '$2=="Physical standby database"{print $1}')"; [ "$(printf '%s\n' "$phys" | grep -c .)" = 1 ] && TARGET="$phys"; fi
}
members() { printf '%s\n' "$MEMBERS" | cut -d'|' -f1; }
role_of() { printf '%s\n' "$MEMBERS" | awk -F'|' -v n="$(printf '%s' "$1" | lc)" 'tolower($1)==n{print $2}'; }
need_target() {
  [ -n "${ARGS[0]:-}" ] && TARGET="${ARGS[0]}"
  [ -n "$TARGET" ] || die "Which standby? --target DBUN (standbys: ${STANDBYS:-none})"
  same_db "$TARGET" "$PRIMARY" && die "$TARGET is already the primary"
  [ -n "$(role_of "$TARGET")" ] || die "$TARGET is not in the configuration (members: $(members | tr '\n' ' '))"
}
is_local() { same_db "$1" "$LOCAL_DBUN"; }
# static_id <member>: StaticConnectIdentifier property
static_id() { dgm "show database $1 StaticConnectIdentifier" | sed -n "s/.*StaticConnectIdentifier *= *'\(.*\)'.*/\1/p" | head -1; }
desc_hosts() { printf '%s' "$1" | grep -oiE 'HOST *= *[^)]+' | sed 's/.*= *//; s/ *$//' | lc | sort -u | tr '\n' ' ' | sed 's/ $//'; }
desc_port() { printf '%s' "$1" | grep -oiE 'PORT *= *[0-9]+' | head -1 | grep -oE '[0-9]+'; }
desc_service() { printf '%s' "$1" | grep -oiE 'SERVICE_NAME *= *[^)]+' | head -1 | sed 's/.*= *//; s/ *$//'; }
tnsping_desc() { ORACLE_HOME="$DB_HOME" to 30 "$DB_HOME/bin/tnsping" "$1" 2>/dev/null | sed -n 's/^Attempting to contact //p' | head -1; }
listener_oras() { local d; for d in "${TNS_ADMIN:-}" "$GRID_HOME/network/admin" "$DB_HOME/network/admin"; do [ -n "$d" ] && [ -f "$d/listener.ora" ] && echo "$d/listener.ora"; done | sort -u; }
tnsnames_dir() { local d; for d in "${TNS_ADMIN:-}" "$DB_HOME/network/admin" "$GRID_HOME/network/admin"; do [ -n "$d" ] && [ -f "$d/tnsnames.ora" ] && { echo "$d"; return; }; done; }
srvctl_services() { [ -n "$GRID_HOME" ] || return 0; "$GRID_HOME/bin/srvctl" config service -d "$1" 2>/dev/null | awk -F': *' '/^Service name:/{n=$2} /^Service role:/{print n, $2}'; }

# ---------------------------------------------------------------------------
# inspect
# ---------------------------------------------------------------------------
cmd_inspect() {
  discover
  local m rows="" sid_line
  for m in $(members); do
    local sd st role tl al is rtq; sd="$(showdb "$m")"; st="$(dbstatus "$sd")"; role="$(dbfield "$sd" Role)"; is="$(dbfield "$sd" 'Intended State')"; tl="$(dbfield "$sd" 'Transport Lag')"; al="$(dbfield "$sd" 'Apply Lag')"; rtq="$(dbfield "$sd" 'Real Time Query')"
    rows="${rows}$m|$role|$is|${st:-?}|${tl:--}|${al:--}|${rtq:--}|$(printf '%s\n' "$sd" | grep -oE 'ORA-[0-9]+: [^(]*' | head -2 | tr '\n' ';')"$'\n'
  done
  local val; val="$([ -n "$TARGET" ] && dgm "validate database $TARGET")"
  local srl; srl="$(printf '%s\n' "$val" | grep -ciE 'Insufficient SRLs')"
  local fb; fb="$(printf '%s\n' "$val" | awk '/Flashback Database Status:/{f=1; next} f&&/^ *[A-Za-z0-9_$.-]+: +/{gsub(/^ +/,""); printf "%s ", $0; next} f&&NF==0{f=0}')"
  local active; active="$(sql_lines "$SID" "select listagg(name,',') within group (order by name) from v\$active_services where name not like 'SYS%' and name not like '%XDB';" 2>/dev/null | head -1)"
  local trg; trg="$(sql_lines "$SID" "select listagg(owner||'.'||trigger_name||'['||status||']',' ') within group (order by 1) from dba_triggers where triggering_event like '%DB_ROLE_CHANGE%' or triggering_event like '%STARTUP%';" 2>/dev/null | head -1)"
  local rps; rps="$(sql_lines "$SID" "select listagg(name||'('||decode(guarantee_flashback_database,'YES','guaranteed','normal')||')',' ') within group (order by time) from v\$restore_point;" 2>/dev/null | head -1)"
  local statics="" lo found; for m in $(members); do local sidd; sidd="$(static_id "$m")"; local h p ok="?"; h="$(desc_hosts "$sidd")"; p="$(desc_port "$sidd")"; [ -n "$h" ] && [ -n "$p" ] && { port_open "$p" "${h%% *}" && ok=open || ok=CLOSED; }; statics="${statics}$m: $(desc_service "$sidd") on ${h:-?}:${p:-?} ($ok)"$'\n'; done
  found=0; for lo in $(listener_oras); do grep -qiE "GLOBAL_DBNAME *= *${LOCAL_DBUN}_DGMGRL" "$lo" && found=1; done
  local tns_lines="" a; for a in ${APP_TNS//,/ }; do local d; d="$(tnsping_desc "$a")"; if [ -z "$d" ]; then tns_lines="${tns_lines}$a: does not resolve (tnsping)"$'\n'; else local hs; hs="$(desc_hosts "$d")"; local nh; nh="$(printf '%s' "$hs" | wc -w | tr -d ' ')"; tns_lines="${tns_lines}$a: service $(desc_service "$d") hosts [$hs] ($nh host$([ "$nh" = 1 ] && echo ' - ONE SITE ONLY' || echo 's'))"$'\n'; fi; done
  if [ "$JSON_OUT" = 1 ]; then
    printf '{"sid":"%s","local":{"db_unique_name":"%s","role":"%s","open_mode":"%s"},"configuration":"%s","status":"%s","protection_mode":"%s","fsfo":"%s","fsfo_target":"%s","primary":"%s","target":"%s","insufficient_srls":%s,"static_dgmgrl_entry":%s,"active_services":"%s","members":[' \
      "$(json_escape "$SID")" "$(json_escape "$LOCAL_DBUN")" "$(json_escape "$LOCAL_ROLE")" "$(json_escape "$LOCAL_OPEN")" "$(json_escape "$CFG_NAME")" "$(json_escape "$CFG_STATUS")" "$(json_escape "$PROT_MODE")" "$(json_escape "$FSFO")" "$(json_escape "$FSFO_TARGET")" "$(json_escape "$PRIMARY")" "$(json_escape "$TARGET")" "$srl" "$found" "$(json_escape "$active")"
    # broker text (status, errors) can carry quotes and backslashes: escape every string field
    printf '%s' "$rows" | awk -F'|' 'function j(s){gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); return s} NF>1{printf "%s{\"name\":\"%s\",\"role\":\"%s\",\"intended_state\":\"%s\",\"status\":\"%s\",\"transport_lag\":\"%s\",\"apply_lag\":\"%s\",\"errors\":\"%s\"}", (NR>1?",":""), j($1), j($2), j($3), j($4), j($5), j($6), j($8)}'; echo ']}'; return
  fi
  sid_line="$SID ($LOCAL_DBUN) $LOCAL_ROLE, $LOCAL_OPEN, home $DB_HOME$([ -n "$GRID_HOME" ] && echo ", grid $GRID_HOME")"
  echo "Local instance  : $sid_line"
  echo "Configuration   : ${CFG_NAME:-?}  status: ${CFG_STATUS:-?}  protection: ${PROT_MODE:-?}  FSFO: ${FSFO:-?}${FSFO_TARGET:+ (target $FSFO_TARGET)}  broker: $BROKER_ON"
  echo "Members         :"; printf '%s' "$rows" | awk -F'|' 'NF>1{printf "  %-16s %-18s %-10s %-8s transport %-12s apply %-12s rtq %-4s %s\n", $1, $2, $3, $4, $5, $6, $7, $8}'
  printf '%s\n' "$CFG" | grep -E 'ORA-|Warning|Error' | grep -v '^ *ORA-16810' | sed 's/^ */  /' | sort -u
  echo "Target          : ${TARGET:-none (pass --target)}"
  [ -n "$val" ] && echo "Validate        : switchover: $(dbfield "$val" 'Ready for Switchover')  failover: $(dbfield "$val" 'Ready for Failover')  flashback: ${fb:-?}  $([ "$srl" != 0 ] && echo 'INSUFFICIENT SRLs' || echo 'SRLs ok')  temp files: $(printf '%s\n' "$val" | sed -n 's/^ *\([^ ]*\) TEMP Files: *\([0-9]*\).*/\1=\2/p' | tr '\n' ' ')"
  echo "Services        : active here: ${active:-none}"
  local svc; svc="$(srvctl_services "$LOCAL_DBUN")"; [ -n "$svc" ] && printf '%s\n' "$svc" | sed 's/^/                  srvctl: /'
  [ -n "$PRIMARY_SERVICES" ] && echo "                  expected on the primary: $PRIMARY_SERVICES"
  echo "Role triggers   : ${trg:-none}"
  echo "Static DGMGRL   : ${LOCAL_DBUN}_DGMGRL in listener.ora: $([ "$found" = 1 ] && echo yes || echo "NO ($(listener_oras | tr '\n' ' '))")"
  printf '%s' "$statics" | sed 's/^/                  /'
  if [ -n "$tns_lines" ]; then echo "Client TNS      :"; printf '%s' "$tns_lines" | sed 's/^/                  /'; else echo "Client TNS      : none given (--tns ALIAS or APP_TNS=)"; fi
  echo "Restore points  : ${rps:-none}"
  echo "Sessions here   : $(sql_val "$SID" "(select count(*) from v\$session where type='USER' and username is not null)")"
}

# ---------------------------------------------------------------------------
# preflight / plan
# ---------------------------------------------------------------------------
cmd_preflight() {
  discover; [ -n "$RUN_DIR" ] || init_run_dir preflight; need_target
  local fail=0 m
  log "Preflight: switchover $PRIMARY -> $TARGET (config $CFG_NAME, $PROT_MODE, status $CFG_STATUS); local $LOCAL_DBUN is $LOCAL_ROLE"
  [ "$BROKER_ON" = TRUE ] || { err "dg_broker_start is $BROKER_ON on $SID"; fail=1; }
  case "$CFG_STATUS" in SUCCESS) log "configuration status SUCCESS";; WARNING) warn "configuration status WARNING: $(printf '%s\n' "$CFG" | grep -E 'ORA-' | grep -v 16810 | head -3 | tr -s ' ' | tr '\n' ';')";; *) err "configuration status ${CFG_STATUS:-?}: $(printf '%s\n' "$CFG" | grep -E 'ORA-' | head -3 | tr -s ' ' | tr '\n' ';')"; fail=1;; esac
  [ "$(role_of "$TARGET")" = "Physical standby database" ] || warn "$TARGET is a $(role_of "$TARGET"), not a physical standby"
  [ "$FSFO" = Enabled ] && ! same_db "$FSFO_TARGET" "$TARGET" && { err "Fast-Start Failover is enabled with target $FSFO_TARGET; the broker only allows a switchover to that target"; fail=1; }
  # every member healthy, apply on at the target, lags
  for m in $(members); do
    local sd st; sd="$(showdb "$m")"; st="$(dbstatus "$sd")"
    case "$st" in SUCCESS) log "$m: $(dbfield "$sd" Role), status SUCCESS";; WARNING) warn "$m: status WARNING: $(printf '%s\n' "$sd" | grep -E 'ORA-' | head -2 | tr -s ' ' | tr '\n' ';')";; *) err "$m: status ${st:-?}: $(printf '%s\n' "$sd" | grep -E 'ORA-' | head -2 | tr -s ' ' | tr '\n' ';')"; fail=1;; esac
    if same_db "$m" "$TARGET"; then
      [ "$(dbfield "$sd" 'Intended State')" = APPLY-ON ] || { err "$m: intended state is $(dbfield "$sd" 'Intended State'), not APPLY-ON"; fail=1; }
      local tl al; tl="$(lag_secs "$(dbfield "$sd" 'Transport Lag')")"; al="$(lag_secs "$(dbfield "$sd" 'Apply Lag')")"
      [ "$tl" = -1 ] && { err "$m: transport lag unknown (redo transport not working?)"; fail=1; }; [ "$tl" -gt 0 ] && { err "$m: transport lag $(dbfield "$sd" 'Transport Lag') - must be 0"; fail=1; }
      [ "$al" = -1 ] && { err "$m: apply lag unknown (apply not running?)"; fail=1; }
      [ "$al" -gt "$DG_MAX_LAG_SEC" ] && { err "$m: apply lag $(dbfield "$sd" 'Apply Lag') exceeds DG_MAX_LAG_SEC=$DG_MAX_LAG_SEC"; fail=1; }
      [ "$al" -gt 0 ] && [ "$al" -le "$DG_MAX_LAG_SEC" ] && warn "$m: apply lag $(dbfield "$sd" 'Apply Lag') - the switchover waits for it"
      [ "$tl" = 0 ] && [ "$al" = 0 ] && log "$m: transport lag 0, apply lag 0"
    fi
  done
  # broker's own verdict
  local val; val="$(dgm "validate database $TARGET")"; printf '%s\n' "$val" >"$RUN_DIR/validate_$TARGET.txt"
  local ready; ready="$(dbfield "$val" 'Ready for Switchover')"
  if [ "$ready" = Yes ]; then log "validate database $TARGET: Ready for Switchover: Yes"; else err "validate database $TARGET: Ready for Switchover: ${ready:-?} (full output in $RUN_DIR/validate_$TARGET.txt)"; printf '%s\n' "$val" | grep -E '^[[:space:]]+(Warning|Error|ORA-)' | head -5 | sed 's/^/    /' >&2; fail=1; fi
  printf '%s\n' "$val" | grep -qiE 'Insufficient SRLs' && { err "standby redo logs insufficient: $(printf '%s\n' "$val" | grep -iE 'Insufficient SRLs' | tr -s ' ' | head -2 | tr '\n' ';') - add SRLs (one more group per thread than online logs, same size) on BOTH databases"; fail=1; }
  local temps; temps="$(printf '%s\n' "$val" | sed -n 's/^ *[^ ]* TEMP Files: *\([0-9]*\).*/\1/p' | sort -u | grep -c .)"; [ "$temps" -gt 1 ] && warn "temp file counts differ between the databases ($(printf '%s\n' "$val" | sed -n 's/^ *\([^ ]*\) TEMP Files: *\([0-9]*\).*/\1=\2/p' | tr '\n' ' ')) - add the missing tempfiles on the new primary afterwards"
  printf '%s\n' "$val" | grep -qiE "^ *$PRIMARY: *Off" && warn "flashback database is OFF on $PRIMARY: after a failover it could not be reinstated, only rebuilt (switchover is unaffected)"
  printf '%s\n' "$val" | grep -qiE "^ *$TARGET: *Off" && warn "flashback database is OFF on $TARGET"
  # local checks (SQL): gap, recent errors, RMAN, long transactions, switchover_status
  local gap; if [ "$LOCAL_ROLE" = PRIMARY ]; then gap="$(sql_val "$SID" "(select count(*) from v\$archive_dest_status where status not in ('INACTIVE','DEFERRED') and gap_status is not null and gap_status<>'NO GAP')")"; else gap="$(sql_val "$SID" "(select count(*) from v\$archive_gap)")"; fi
  # an unreadable count is unknown, not zero: the gap check is a hard gate, so empty fails it; the advisory counts say so
  if [ -z "$gap" ]; then err "$LOCAL_DBUN: could not read the archive gap status (query failed) - not assuming NO GAP"; fail=1; elif [ "$gap" != 0 ]; then err "$LOCAL_DBUN: archive log gap reported ($gap)"; fail=1; fi
  local derr; derr="$(sql_val "$SID" "(select count(*) from v\$dataguard_status where severity in ('Error','Fatal') and timestamp>sysdate-1/24)")"
  [ -z "$derr" ] && warn "$LOCAL_DBUN: could not read v\$dataguard_status (query failed)"
  [ "${derr:-0}" != 0 ] && { warn "$LOCAL_DBUN: $derr Error/Fatal rows in v\$dataguard_status in the last hour:"; sql_lines "$SID" "select to_char(timestamp,'HH24:MI')||' '||substr(message,1,120) from (select * from v\$dataguard_status where severity in ('Error','Fatal') and timestamp>sysdate-1/24 order by timestamp desc) where rownum<=5;" | sed 's/^/    /' >&2; }
  local rb; rb="$(sql_val "$SID" "(select count(*) from v\$rman_backup_job_details where status='RUNNING')")"
  if [ -z "$rb" ]; then err "$LOCAL_DBUN: could not read v\$rman_backup_job_details (query failed)"; fail=1; elif [ "$rb" != 0 ]; then err "$LOCAL_DBUN: an RMAN backup is running"; fail=1; fi
  pgrep -f 'OPatch/datapatch|datapatc[h]' >/dev/null 2>&1 && { err "datapatch is running on this host"; fail=1; }
  local hb; hb="$(sql_val "$SID" "(select count(*) from v\$backup where status='ACTIVE')")"
  if [ -z "$hb" ]; then err "$LOCAL_DBUN: could not read v\$backup (query failed)"; fail=1; elif [ "$hb" != 0 ]; then err "$LOCAL_DBUN: datafiles in hot backup mode"; fail=1; fi
  if [ "$LOCAL_ROLE" = PRIMARY ]; then
    local so; so="$(sql_val "$SID" "(select switchover_status from v\$database)")"
    case "$so" in "TO STANDBY"|"SESSIONS ACTIVE") log "$LOCAL_DBUN: switchover_status $so";; *) err "$LOCAL_DBUN: switchover_status '$so' (expected TO STANDBY or SESSIONS ACTIVE)"; fail=1;; esac
    local ltx; ltx="$(sql_val "$SID" "(select count(*) from v\$transaction where start_date<sysdate-10/1440)")"; [ -z "$ltx" ] && warn "$LOCAL_DBUN: could not read v\$transaction (query failed)"; [ "${ltx:-0}" != 0 ] && warn "$LOCAL_DBUN: $ltx transaction(s) open for more than 10 minutes - they will be rolled back by the switchover (users disconnected)"
    local jobs; jobs="$(sql_val "$SID" "(select count(*) from dba_scheduler_running_jobs)")"; [ -z "$jobs" ] && warn "$LOCAL_DBUN: could not read dba_scheduler_running_jobs (query failed)"; [ "${jobs:-0}" != 0 ] && warn "$LOCAL_DBUN: $jobs scheduler job(s) running"
    log "$LOCAL_DBUN: $(sql_val "$SID" "(select count(*) from v\$session where type='USER' and username is not null)") user sessions will be disconnected"
    [ "$(sql_val "$SID" "(select count(*) from v\$pdbs where open_mode<>'READ WRITE' and name<>'PDB\$SEED')" 2>/dev/null)" != 0 ] && warn "$LOCAL_DBUN: some PDBs are not READ WRITE (note what should be open on the new primary; the broker opens what the state says)"
  else
    log "$LOCAL_DBUN: $LOCAL_ROLE, $LOCAL_OPEN (running the switchover from the standby side is fine)"
  fi
  # static entries and client TNS
  local lo found=0; for lo in $(listener_oras); do grep -qiE "GLOBAL_DBNAME *= *${LOCAL_DBUN}_DGMGRL" "$lo" && found=1; done
  [ "$found" = 0 ] && warn "no static ${LOCAL_DBUN}_DGMGRL entry in $(listener_oras | tr '\n' ' ' | sed 's/ $//'); the broker may not be able to restart $LOCAL_DBUN (it then tells you to start it by hand; switchover finishes it)"
  for m in $(members); do local sidd h p; sidd="$(static_id "$m")"; h="$(desc_hosts "$sidd")"; p="$(desc_port "$sidd")"; [ -n "$h" ] && [ -n "$p" ] && { port_open "$p" "${h%% *}" || { warn "$m: StaticConnectIdentifier ${h%% *}:$p not reachable from here"; }; }; done
  local a; for a in ${APP_TNS//,/ }; do
    local d; d="$(tnsping_desc "$a")"; [ -z "$d" ] && { err "client TNS alias $a does not resolve"; fail=1; continue; }
    local nh; nh="$(desc_hosts "$d" | wc -w | tr -d ' ')"
    [ "$nh" -lt 2 ] && warn "client TNS alias $a lists one host ($(desc_hosts "$d")) - clients will not follow the primary unless that is a SCAN/VIP shared by both sites; the usual fix is an ADDRESS_LIST with both sites and a role-based service"
    local sv; sv="$(desc_service "$d")"; [ -n "$sv" ] && [ -n "$PRIMARY_SERVICES" ] && ! printf ',%s,' "$PRIMARY_SERVICES" | grep -qiF ",$sv," && warn "alias $a uses service $sv, which is not in PRIMARY_SERVICES ($PRIMARY_SERVICES)"
  done
  case "${DG_CONNECT:-}" in /) is_local "$TARGET" || warn "DG_CONNECT=/ with a remote target: the broker cannot restart $PRIMARY after the switchover without a password; you will be told to start it by hand";; esac
  state_set target "$TARGET"; state_set old_primary "$PRIMARY"
  state_set preflight "$([ "$fail" = 0 ] && echo ok || echo failed)"
  [ "$fail" = 0 ] && { log "Preflight OK"; return 0; } || { err "Preflight FAILED - see $LOG_FILE"; return 1; }
}

cmd_plan() {
  discover; need_target
  echo "PLAN: switchover $PRIMARY -> $TARGET  (configuration $CFG_NAME, $PROT_MODE, FSFO $FSFO; from $LOCAL_DBUN/$LOCAL_ROLE on $HOST)"
  echo "  1. preflight    broker SUCCESS, validate database $TARGET ready, lags 0, no gap, SRLs, temp files, no RMAN/datapatch, switchover_status"
  echo "  2. backup       show configuration verbose + every database's properties -> run dir; pfile; controlfile trace; tnsnames/listener copies$([ "$WANT_RP" = 1 ] && echo '; guaranteed restore point DGSWITCH_<ts> on the primary')"
  echo "  3. switchover   dgmgrl connect $(conn_shown "$([ -n "$DG_CONNECT" ] && echo "$DG_CONNECT" || { is_local "$TARGET" && echo / || echo "sys@$TARGET"; })"); switchover to $TARGET  (timeout ${DG_SWITCH_TIMEOUT}s)"
  echo "                  then: start anything the broker could not restart, open PDBs, srvctl start service on the new primary"
  echo "  4. verify       roles swapped, configuration SUCCESS, $PRIMARY APPLY-ON with lags back to 0 (waits up to ${DG_VERIFY_WAIT}s), services${PRIMARY_SERVICES:+ [$PRIMARY_SERVICES]}${APP_TNS:+, app TNS $APP_TNS answers from $TARGET}"
  echo "  rollback        switchover back to $PRIMARY (same checks); failover is NOT part of run (separate command, typed confirmation)"
  echo "  dry-run         $DRY_RUN   yes: $ASSUME_YES   force: $FORCE"
}

# ---------------------------------------------------------------------------
# backup / switchover / failover / reinstate / verify / rollback / cleanup
# ---------------------------------------------------------------------------
cmd_backup() {
  discover; reuse_or_init backup
  log "backing up broker configuration and local files into $RUN_DIR"
  # --dry-run writes nothing on the server (pfile, controlfile trace, restore point) and records no backup=ok
  if [ "$DRY_RUN" = 1 ]; then log "dry-run: would dump the broker configuration, write init$SID.ora.bak and control.trc, copy tnsnames/sqlnet/listener.ora and the broker config file$([ "$WANT_RP" = 1 ] && echo ', and create a guaranteed restore point')"; state_set old_primary "$PRIMARY"; [ -n "$TARGET" ] && state_set target "$TARGET"; return 0; fi
  # every write is checked: a backup that exited 0 with an ORA- in the log claimed a copy it does not have (false-success gate)
  local fail=0 out
  bk_dgm() { local f="$RUN_DIR/$1"; shift; dgm "$@" >"$f" 2>&1; grep -qE 'ORA-|DGM-' "$f" && { err "backup: dgmgrl $*: $(grep -E 'ORA-|DGM-' "$f" | head -1)"; return 1; }; [ -s "$f" ] || { err "backup: dgmgrl $* gave no output"; return 1; }; return 0; }
  bk_sql() { out="$(sql_run "$SID" "whenever sqlerror exit 1\n$1")"; printf '%s\n' "$out" >>"$LOG_FILE"; printf '%s' "$out" | grep -qE 'ORA-[0-9]+|SP2-[0-9]+' && { err "backup: $(printf '%s' "$out" | grep -E 'ORA-|SP2-' | head -1)"; return 1; }; return 0; }
  bk_dgm dg_configuration.txt "show configuration verbose" || fail=1
  local m; for m in $(members); do bk_dgm "dg_database_$m.txt" "show database verbose $m" || fail=1; done
  bk_dgm dg_fsfo.txt "show fast_start failover" || fail=1
  bk_sql "create pfile='$RUN_DIR/init$SID.ora.bak' from spfile;" || fail=1
  bk_sql "alter database backup controlfile to trace as '$RUN_DIR/control.trc' reuse;" || fail=1
  sql_run "$SID" "select name, value from v\$parameter where name in ('log_archive_config','log_archive_dest_1','log_archive_dest_2','log_archive_dest_3','fal_server','fal_client','standby_file_management','db_file_name_convert','log_file_name_convert','dg_broker_config_file1','dg_broker_config_file2') order by 1;" >"$RUN_DIR/dg_parameters.txt" 2>&1
  sql_run "$SID" "select name, network_name, pdb from dba_services order by 1;" >"$RUN_DIR/services.txt" 2>&1
  local d; d="$(tnsnames_dir)"; [ -n "$d" ] && cp -p "$d"/tnsnames.ora "$d"/sqlnet.ora "$RUN_DIR"/ 2>/dev/null
  local lo; for lo in $(listener_oras); do cp -p "$lo" "$RUN_DIR/listener.ora.$(basename "$(dirname "$(dirname "$(dirname "$lo")")")")" 2>/dev/null; done
  local cf1; cf1="$(sql_val "$SID" "(select value from v\$parameter where name='dg_broker_config_file1')")"; [ -f "$cf1" ] && cp -p "$cf1" "$RUN_DIR/" 2>/dev/null
  if [ "$WANT_RP" = 1 ]; then
    if [ "$LOCAL_ROLE" = PRIMARY ] && [ "$(sql_val "$SID" "(select log_mode from v\$database)")" = ARCHIVELOG ]; then
      local rp; rp="DGSWITCH_$(date +%Y%m%d%H%M%S)"; log "$LOCAL_DBUN: creating guaranteed restore point $rp (drop it with cleanup; it is also on the standby if flashback is on there)"
      if sql_run "$SID" "create restore point $rp guarantee flashback database;" | grep -q 'ORA-'; then err "restore point $rp failed (asked for with --restore-point)"; fail=1; else state_append restore_points "$SID:$rp"; fi
    else warn "--restore-point: only done on an ARCHIVELOG primary (this is $LOCAL_ROLE)"; fi
  fi
  state_set old_primary "$PRIMARY"; [ -n "$TARGET" ] && state_set target "$TARGET"
  [ "$fail" = 0 ] || { state_set backup failed; err "backup incomplete (see $LOG_FILE): nothing changed on the databases"; return 1; }
  state_set backup ok
}

# finish_restarts: after a role change, start members the broker reports as down (local ones), tell about remote ones
finish_restarts() {
  local m; for m in $(members); do
    local sd; sd="$(showdb "$m")"
    printf '%s\n' "$sd" | grep -qE 'ORA-1034|ORA-01034|ORA-16541|ORA-12514|ORA-12541|Unable to connect|not started' || continue
    if is_local "$m"; then
      log "$m is not running - starting it (mount; the broker opens it if the role says so)"
      if [ "$DRY_RUN" = 0 ]; then
        # srvctl first (CRS keeps the resource state right); when it fails (database not registered, CRS down) fall back
        # to sqlplus, and in every case check that the instance is actually up afterwards instead of assuming it
        if [ -n "$GRID_HOME" ]; then run_cmd "$GRID_HOME/bin/srvctl" start database -d "$m" || { warn "srvctl start database -d $m failed (see $LOG_FILE): trying sqlplus startup mount"; ORACLE_SID="$SID" ORACLE_HOME="$DB_HOME" to 600 "$DB_HOME/bin/sqlplus" -S / as sysdba <<<"startup mount" >>"$LOG_FILE" 2>&1; }
        else ORACLE_SID="$SID" ORACLE_HOME="$DB_HOME" to 600 "$DB_HOME/bin/sqlplus" -S / as sysdba <<<"startup mount" >>"$LOG_FILE" 2>&1; fi
        sleep 10
        sql_ok "$SID" || err "$m ($SID) is still not up after the start attempt - start it by hand (startup mount), then 'verify'; the broker finishes the role change once it is up"
      fi
    else
      warn "$m is not running and is not on this host: start it there (srvctl start database -d $m, or sqlplus 'startup mount'); the broker finishes the role change once it is up"
    fi
  done
}
# after_role_change <new primary>: open PDBs and start services where this host is the new primary
after_role_change() {
  local newp="$1"
  if is_local "$newp"; then
    [ "$DRY_RUN" = 1 ] || sql_run "$SID" "alter pluggable database all open;" >>"$LOG_FILE" 2>&1
    if [ -n "$GRID_HOME" ]; then run_cmd "$GRID_HOME/bin/srvctl" start service -d "$newp" || warn "srvctl start service reported errors (role-based services may already be up)"; fi
    local s; for s in ${PRIMARY_SERVICES//,/ }; do [ "$DRY_RUN" = 1 ] && continue; sql_lines "$SID" "select name from v\$active_services where upper(name)=upper('$s');" 2>/dev/null | grep -q . || { log "starting service $s"; sql_run "$SID" "exec dbms_service.start_service('$s')" >>"$LOG_FILE" 2>&1 || true; }; done
  else
    log "the new primary $newp is not on this host: role services start there (srvctl start service -d $newp / the role trigger)"
  fi
}
wait_roles() { # <expected primary> <secs>: until show configuration says so
  local want="$1" t="${2:-180}" start now; start="$(date +%s)"
  while :; do CFG=""; discover; same_db "$PRIMARY" "$want" && return 0; now="$(date +%s)"; [ $((now-start)) -ge "$t" ] && return 1; sleep 10; done
}

cmd_switchover() {
  discover; reuse_or_init switchover; need_target
  [ "$(state_get preflight || true)" = ok ] || [ "$FORCE" = 1 ] || warn "preflight has not passed in this run dir (run 'preflight' first, or --force to skip the reminder)"
  state_set old_primary "$PRIMARY"; state_set target "$TARGET"
  local conn; conn="$(dg_conn "$TARGET")" || die "no credentials for $TARGET (DG_PASSWORD unset and no terminal to ask): nothing changed"
  log "switchover $PRIMARY -> $TARGET via dgmgrl $(conn_shown "$conn") (protection $PROT_MODE, timeout ${DG_SWITCH_TIMEOUT}s)"
  confirm "Switch over now? $PRIMARY becomes a physical standby, $TARGET becomes primary; user sessions on $PRIMARY are disconnected." || die "aborted"
  if [ "$DRY_RUN" = 1 ]; then log "DRY-RUN: dgmgrl> switchover to $TARGET"; state_set switchover ok; return 0; fi
  local out; out="$(dgm_as "$conn" "$DG_SWITCH_TIMEOUT" "switchover to $TARGET")"; printf '%s\n' "$out" | redact >>"$LOG_FILE"
  printf '%s\n' "$out" | redact | grep -vE '^[[:space:]]*$' | tail -15 | sed 's/^/  dgmgrl: /' >&2
  if printf '%s' "$out" | grep -q 'Switchover succeeded'; then log "broker: Switchover succeeded"
  elif printf '%s' "$out" | grep -qiE 'Please complete the following steps|must be restarted|Unable to connect|ORA-16541|ORA-12514|ORA-12541|ORA-01017'; then
    warn "the broker could not restart every database itself; finishing"; CFG=""; discover; finish_restarts
  else err "switchover did not report success (see $LOG_FILE)"; state_set switchover failed; return 1; fi
  if wait_roles "$TARGET" 300; then log "roles: $TARGET is primary, $(printf '%s\n' "$MEMBERS" | awk -F'|' -v n="$(printf '%s' "$PRIMARY" | lc)" 'tolower($1)!=n{printf "%s=%s ", $1, $2}')"
  else err "after the switchover the broker still reports $PRIMARY as primary"; state_set switchover failed; return 1; fi
  after_role_change "$TARGET"
  state_set switchover ok
}

cmd_failover() {
  discover; reuse_or_init failover; need_target
  local val; val="$(dgm "validate database $TARGET")"; printf '%s\n' "$val" >"$RUN_DIR/validate_$TARGET.txt"
  local ready; ready="$(dbfield "$val" 'Ready for Failover')"
  log "FAILOVER $PRIMARY -> $TARGET: validate says 'Ready for Failover: ${ready:-?}'"
  case "$ready" in Yes*) ;; *) [ "$FORCE" = 1 ] || die "validate database $TARGET: Ready for Failover: ${ready:-?}. Read $RUN_DIR/validate_$TARGET.txt; --force to try anyway";; esac
  if [[ "$ready" == *"Primary Running"* ]]; then [ "$FORCE" = 1 ] && warn "the primary $PRIMARY is still running - a SWITCHOVER would lose nothing; --force given" || die "the primary $PRIMARY is still running: use 'switchover' (no data loss). --force if the primary really is unusable"; fi
  printf '%s\n' "$val" | grep -qiE "^ *$PRIMARY: *Off" && warn "flashback database is OFF on $PRIMARY: it cannot be reinstated afterwards, only rebuilt (RMAN duplicate for standby)"
  local sd; sd="$(showdb "$TARGET")"
  log "$TARGET: transport lag $(dbfield "$sd" 'Transport Lag'), apply lag $(dbfield "$sd" 'Apply Lag'); $PROT_MODE. $([ "$IMMEDIATE" = 1 ] && echo 'IMMEDIATE: redo received but not yet applied is DISCARDED' || echo 'the broker applies what it received first; data loss = the transport lag')"
  [ -n "$FSFO" ] && [ "$FSFO" = Enabled ] && warn "Fast-Start Failover is enabled: the observer may already have failed over or may fight this; check 'show fast_start failover'"
  local oldp="$PRIMARY"; state_set old_primary "$oldp"; state_set target "$TARGET"
  local conn; conn="$(dg_conn "$TARGET")" || die "no credentials for $TARGET (DG_PASSWORD unset and no terminal to ask): nothing changed"
  confirm_typed "FAILOVER to $TARGET: $PRIMARY becomes a failed primary that must be reinstated or rebuilt; possible data loss" "$TARGET" || die "aborted (no typed confirmation)"
  if [ "$DRY_RUN" = 1 ]; then log "DRY-RUN: dgmgrl> failover to $TARGET$([ "$IMMEDIATE" = 1 ] && echo ' immediate')"; state_set failover ok; return 0; fi
  local out; out="$(dgm_as "$conn" "$DG_SWITCH_TIMEOUT" "failover to $TARGET$([ "$IMMEDIATE" = 1 ] && echo ' immediate')")"; printf '%s\n' "$out" | redact >>"$LOG_FILE"
  printf '%s\n' "$out" | redact | grep -vE '^[[:space:]]*$' | tail -15 | sed 's/^/  dgmgrl: /' >&2
  printf '%s' "$out" | grep -q 'Failover succeeded' || { err "failover did not report success (see $LOG_FILE)"; state_set failover failed; return 1; }
  wait_roles "$TARGET" 180 || warn "the broker does not yet show $TARGET as primary"
  after_role_change "$TARGET"
  state_set failover ok
  echo; echo "FAILOVER done: $TARGET is primary. $oldp is now a disabled, failed primary. When its host is back:"
  echo "  1. start it mounted there:  srvctl start database -d $oldp -o mount   (or sqlplus: startup mount)"
  echo "  2. from any host of the configuration:  ./dg-switchover.sh reinstate $oldp     (needs flashback database ON there)"
  echo "  3. if reinstate fails with ORA-16795/ORA-38729: rebuild it as a standby (RMAN duplicate ... for standby from active database), then 'enable database $oldp'"
  echo "  Back up $TARGET now (the old backups belong to another incarnation), check the application TNS and the observer if FSFO was on."
}

cmd_reinstate() {
  discover; reuse_or_init reinstate
  local old="${ARGS[0]:-$(state_get old_primary || true)}"; [ -n "$old" ] || die "which database? reinstate <old-primary>"
  same_db "$old" "$PRIMARY" && die "$old is the current primary"
  if is_local "$old"; then
    [ "$LOCAL_OPEN" = MOUNTED ] || { log "$old must be MOUNTED for reinstate (now: $LOCAL_OPEN) - restarting it mounted"; confirm "shutdown abort / startup mount $old now?" || die "aborted"
      [ "$DRY_RUN" = 1 ] || { if [ -n "$GRID_HOME" ]; then run_cmd "$GRID_HOME/bin/srvctl" stop database -d "$old" -o abort; run_cmd "$GRID_HOME/bin/srvctl" start database -d "$old" -o mount; else ORACLE_SID="$SID" ORACLE_HOME="$DB_HOME" to 600 "$DB_HOME/bin/sqlplus" -S / as sysdba <<<$'shutdown abort\nstartup mount' >>"$LOG_FILE" 2>&1; fi; }; }
  else
    log "$old is not on this host: it must be started MOUNTED there before reinstate (srvctl start database -d $old -o mount)"; confirm "Is $old mounted on its host now?" || die "aborted"
  fi
  local conn; conn="$(dg_conn "$PRIMARY")" || die "no credentials for $PRIMARY (DG_PASSWORD unset and no terminal to ask): nothing changed"
  log "reinstate database $old via dgmgrl $(conn_shown "$conn") (the broker flashes it back to the failover SCN and converts it to a physical standby)"
  confirm "Reinstate $old as a standby of $PRIMARY?" || die "aborted"
  [ "$DRY_RUN" = 1 ] && { log "DRY-RUN: dgmgrl> reinstate database $old"; return 0; }
  local out; out="$(dgm_as "$conn" "$DG_SWITCH_TIMEOUT" "reinstate database $old")"; printf '%s\n' "$out" | redact >>"$LOG_FILE"; printf '%s\n' "$out" | redact | grep -vE '^[[:space:]]*$' | tail -10 | sed 's/^/  dgmgrl: /' >&2
  if printf '%s' "$out" | grep -qiE 'Reinstatement of database .* succeeded|succeeded'; then log "reinstated: $old is a standby again; run verify"; state_set reinstate ok
  else err "reinstate failed. ORA-16795 / ORA-38729 = no flashback data back to the failover SCN: rebuild $old with RMAN duplicate for standby, then 'enable database $old'"; state_set reinstate failed; return 1; fi
}

cmd_verify() {
  discover; reuse_or_init verify
  local want old fail=0; want="$(state_get target || echo "$PRIMARY")"; old="$(state_get old_primary || true)"
  same_db "$PRIMARY" "$want" && log "primary is $PRIMARY as intended" || { err "primary is $PRIMARY, expected $want"; fail=1; }
  local start now m; start="$(date +%s)"
  while :; do
    local pending=0; CFG=""; discover
    [ "$CFG_STATUS" = SUCCESS ] || pending=1
    for m in $(members); do
      same_db "$m" "$PRIMARY" && continue
      local sd; sd="$(showdb "$m")"
      [ "$(dbstatus "$sd")" = SUCCESS ] || pending=1
      [ "$(role_of "$m")" = "Physical standby database" ] && [ "$(dbfield "$sd" 'Intended State')" != APPLY-ON ] && pending=1
      [ "$(lag_secs "$(dbfield "$sd" 'Transport Lag')")" = 0 ] || pending=1; [ "$(lag_secs "$(dbfield "$sd" 'Apply Lag')")" = 0 ] || pending=1
    done
    [ "$pending" = 0 ] && break
    now="$(date +%s)"; [ $((now-start)) -ge "$DG_VERIFY_WAIT" ] && break
    [ "$DRY_RUN" = 1 ] && break
    log "waiting for the standby to catch up (status $CFG_STATUS; $((now-start))s of ${DG_VERIFY_WAIT}s)"; sleep 15
  done
  [ "$CFG_STATUS" = SUCCESS ] && log "configuration status SUCCESS" || { err "configuration status ${CFG_STATUS:-?}: $(printf '%s\n' "$CFG" | grep -E 'ORA-' | head -3 | tr -s ' ' | tr '\n' ';')"; fail=1; }
  for m in $(members); do
    local sd; sd="$(showdb "$m")"; local st; st="$(dbstatus "$sd")"
    if same_db "$m" "$PRIMARY"; then [ "$st" = SUCCESS ] && log "$m: primary, status SUCCESS" || { err "$m: primary, status ${st:-?}"; fail=1; }; continue; fi
    local tl al; tl="$(dbfield "$sd" 'Transport Lag')"; al="$(dbfield "$sd" 'Apply Lag')"
    if [ "$(lag_secs "$tl")" = 0 ] && [ "$(lag_secs "$al")" = 0 ] && [ "$st" = SUCCESS ]; then log "$m: $(dbfield "$sd" Role), $(dbfield "$sd" 'Intended State'), lags 0/0, status SUCCESS"
    else err "$m: $(dbfield "$sd" Role), $(dbfield "$sd" 'Intended State'), transport $tl, apply $al, status ${st:-?} $(printf '%s\n' "$sd" | grep -E 'ORA-' | head -2 | tr -s ' ' | tr '\n' ';')"; fail=1; fi
    [ -n "$old" ] && same_db "$m" "$old" && [ "$(role_of "$m")" != "Physical standby database" ] && { err "$old is a '$(role_of "$m")', expected Physical standby database"; fail=1; }
  done
  # local role, open mode, services
  CFG=""; discover
  if [ "$LOCAL_ROLE" = PRIMARY ]; then
    [ "$LOCAL_OPEN" = "READ WRITE" ] || { err "$LOCAL_DBUN is primary but $LOCAL_OPEN"; fail=1; }
    local closed; closed="$(sql_val "$SID" "(select count(*) from v\$pdbs where open_mode<>'READ WRITE' and name<>'PDB\$SEED')" 2>/dev/null)"; [ -z "$closed" ] && warn "$LOCAL_DBUN: could not read v\$pdbs (query failed)"; [ "${closed:-0}" != 0 ] && warn "$LOCAL_DBUN: $closed PDB(s) not READ WRITE"
    local active; active="$(sql_lines "$SID" "select listagg(name,',') within group (order by name) from v\$active_services where name not like 'SYS%' and name not like '%XDB';" | head -1)"; log "$LOCAL_DBUN: active services: ${active:-none}"
    local s; for s in ${PRIMARY_SERVICES//,/ }; do printf ',%s,' "$active" | grep -qiF ",$s," || { err "service $s is not running on the primary"; fail=1; }; done
  else
    [ "$(sql_val "$SID" "(select count(*) from v\$managed_standby where process like 'MRP%')" 2>/dev/null)" = 0 ] && [ "$(sql_val "$SID" "(select count(*) from v\$dataguard_process where name like 'MRP%' or role like '%apply%')" 2>/dev/null)" = 0 ] && { err "$LOCAL_DBUN: no redo apply process (MRP) running"; fail=1; }
    local s; for s in ${PRIMARY_SERVICES//,/ }; do sql_lines "$SID" "select name from v\$active_services where upper(name)=upper('$s');" 2>/dev/null | grep -q . && warn "primary service $s is running on the standby $LOCAL_DBUN"; done
  fi
  # application TNS
  local a; for a in ${APP_TNS//,/ }; do
    local d; d="$(tnsping_desc "$a")"; [ -z "$d" ] && { err "app TNS $a does not resolve"; fail=1; continue; }
    if [ -n "${APP_TEST_CONNECT:-}" ] && [ "$DRY_RUN" = 0 ]; then
      # connect on stdin (/nolog): user/password@alias on sqlplus's command line would sit in the process list for 30 s
      local got; got="$(printf "connect %s@%s\nset heading off feedback off\nselect sys_context('USERENV','DB_UNIQUE_NAME') from dual;\nexit\n" "${APP_TEST_CONNECT%@*}" "$a" | ORACLE_HOME="$DB_HOME" PATH="$DB_HOME/bin:$PATH" to 30 "$DB_HOME/bin/sqlplus" -S -L /nolog 2>&1 | grep -vE '^[[:space:]]*$' | tail -1 | tr -d ' ')"
      if same_db "$got" "$PRIMARY"; then log "app TNS $a: connected, answered by $got (the primary)"; else err "app TNS $a: expected the primary $PRIMARY, got '$got'"; fail=1; fi
    else log "app TNS $a resolves to [$(desc_hosts "$d")] service $(desc_service "$d") (set APP_TEST_CONNECT=user/pw@x to test a real login)"; fi
  done
  state_set verify "$([ "$fail" = 0 ] && echo ok || echo failed)"; [ "$fail" = 0 ] && log "Verify OK" || err "Verify FAILED"; return "$fail"
}

cmd_rollback() {
  discover; reuse_or_init rollback
  [ "$(state_get failover || true)" = ok ] && die "this run was a failover: there is no switchover back. Use 'reinstate $(state_get old_primary)' and then, if wanted, a switchover"
  local old; old="$(state_get old_primary || true)"; [ -n "$old" ] || die "no old primary recorded in $RUN_DIR"
  same_db "$old" "$PRIMARY" && die "$old is already the primary - nothing to roll back"
  log "rollback = switchover back to $old"
  state_set rollback_from "$PRIMARY"; TARGET="$old"; ARGS=(); 
  cmd_preflight || { [ "$FORCE" = 1 ] || die "preflight for the switchover back failed; fix it or --force"; }
  cmd_switchover || die "switchover back failed - see $LOG_FILE"
  if cmd_verify; then state_set rollback ok; else state_set rollback failed; die "rolled back (switchover to $old done) but verify FAILED - see $LOG_FILE"; fi
}

cmd_cleanup() {
  discover; reuse_or_init cleanup
  local rp fail=0 out; for rp in $(state_get restore_points || true); do local s="${rp%%:*}" name="${rp#*:}"; confirm "Drop restore point $name in $s?" || continue
    if [ "$DRY_RUN" = 1 ]; then log "dry-run: would drop restore point $name in $s"; continue; fi
    # a failed drop is reported, not logged as 'dropped' (false-success gate)
    out="$(sql_run "$s" "whenever sqlerror exit 1\ndrop restore point $name;")"; printf '%s\n' "$out" >>"$LOG_FILE"
    if printf '%s' "$out" | grep -qE 'ORA-[0-9]+|SP2-[0-9]+'; then err "$s: drop restore point $name failed: $(printf '%s' "$out" | grep -E 'ORA-|SP2-' | head -1)"; fail=1; else log "$s: dropped $name"; fi
  done
  local others; others="$(sql_lines "$SID" "select name from v\$restore_point where name like 'DGSWITCH_%';" 2>/dev/null | tr '\n' ' ')"; [ -n "$others" ] && log "other DGSWITCH restore points still present: $others"
  [ "$fail" = 0 ] || { state_set cleanup failed; return 1; }
  [ "$DRY_RUN" = 1 ] || state_set cleanup ok; return 0
}

# ---------------------------------------------------------------------------
# heal
# ---------------------------------------------------------------------------
dg_edit() { # <database> <state>: with confirmation
  confirm "dgmgrl> edit database $1 set state='$2' ?" || return 1
  [ "$DRY_RUN" = 1 ] && return 0; dgm "edit database $1 set state='$2'" | tee -a "$LOG_FILE" | sed 's/^/  dgmgrl: /' >&2
}
cmd_heal() {
  discover; reuse_or_init heal; local did=0 m all
  all="$(printf '%s\n' "$CFG"; for m in $(members); do printf '\n== %s ==\n' "$m"; showdb "$m"; done)"; printf '%s\n' "$all" >"$RUN_DIR/heal_status.txt"
  local codes; codes="$(printf '%s\n' "$all" | grep -oE 'ORA-[0-9]+' | sort -u | tr '\n' ' ')"
  [ -z "$codes" ] && [ "$CFG_STATUS" = SUCCESS ] && { log "configuration SUCCESS, no errors or warnings: nothing to heal"; return 0; }
  log "status $CFG_STATUS; codes: ${codes:-none}"
  for m in $(members); do printf '%s\n' "$all" | awk -v m="== $m ==" '$0==m{f=1} f' | grep -E 'ORA-' | sed "s/^ */  $m: /" | head -5 >&2; done
  # disabled members
  for m in $(members); do printf '%s\n' "$all" | awk -v m="== $m ==" '$0==m{f=1} f' | grep -qE '^DISABLED' && { warn "$m is DISABLED in the broker"; confirm "dgmgrl> enable database $m ?" && { [ "$DRY_RUN" = 1 ] || dgm "enable database $m" >>"$LOG_FILE"; did=1; }; }; done
  local c; for c in $codes; do case "$c" in
    ORA-16810|ORA-16809) log "$c: summary code, the real ones are listed per database above";;
    ORA-16820) warn "$c: Fast-Start Failover enabled but no observer is observing. Start it on the observer host:  dgmgrl sys@$PRIMARY \"start observer\"  (or 'start observer in background'); if FSFO is not wanted: dgmgrl> disable fast_start failover"
      dgm "show fast_start failover" | sed 's/^/    /' >&2;;
    ORA-16853|ORA-16855) warn "$c: apply lag over the ApplyLagThreshold"
      for m in $STANDBYS; do local sd; sd="$(showdb "$m")"; local is; is="$(dbfield "$sd" 'Intended State')"
        if [ "$is" != APPLY-ON ]; then log "  $m intended state is $is"; dg_edit "$m" APPLY-ON && did=1
        elif is_local "$m" && [ "$(sql_val "$SID" "(select count(*) from v\$managed_standby where process like 'MRP%')" 2>/dev/null)" = 0 ]; then warn "  $m: APPLY-ON but no MRP process; look at the alert log for the ORA- that stopped it (often a missing archivelog/ORA-01111 datafile or a stuck recovery), then:"; log "    dgmgrl> edit database $m set state='APPLY-OFF'; edit database $m set state='APPLY-ON'"; confirm "  toggle apply off/on for $m now?" && { dg_edit "$m" APPLY-OFF; dg_edit "$m" APPLY-ON; did=1; }
        else log "  $m: apply running, lag $(dbfield "$sd" 'Apply Lag') (apply rate $(dbfield "$sd" 'Average Apply Rate')); if it keeps growing: more apply parallelism (recovery parallelism), faster standby storage, check 'Insufficient SRLs' in validate database"; fi; done;;
    ORA-16857|ORA-16854) warn "$c: transport lag over the TransportLagThreshold (redo not reaching the standby fast enough)"
      dgm "show database $PRIMARY LogXptStatus" | grep -vE '^[[:space:]]*$' | sed 's/^/    /' >&2
      if [ "$LOCAL_ROLE" = PRIMARY ]; then sql_lines "$SID" "select dest_id||' '||status||' '||nvl(error,'-')||' '||destination from v\$archive_dest where target='STANDBY' and status<>'INACTIVE';" | sed 's/^/    dest: /' >&2; fi
      local sd; sd="$(showdb "$PRIMARY")"; [ "$(dbfield "$sd" 'Intended State')" != TRANSPORT-ON ] && dg_edit "$PRIMARY" TRANSPORT-ON && did=1
      log "  usual causes: network/bandwidth, listener on the standby down (tnsping its StaticConnectIdentifier), password file out of sync (ORA-01017/16191), SRLs missing on the standby, a huge transaction/nologging";;
    ORA-16826|ORA-16766) warn "$c: redo apply is stopped / state inconsistent"
      for m in $STANDBYS; do dg_edit "$m" APPLY-ON && did=1; done;;
    ORA-16764|ORA-16778) warn "$c: redo transport to a standby is not running"
      dgm "show database $PRIMARY LogXptStatus" | grep -vE '^[[:space:]]*$' | sed 's/^/    /' >&2
      dg_edit "$PRIMARY" TRANSPORT-ON && did=1
      log "  if a destination shows an error: check the listener on that standby, tnsping from the primary host, orapw files identical (copy the primary's), log_archive_dest_state_n";;
    ORA-16661|ORA-16795|ORA-16816) warn "$c: a database needs reinstatement (failed primary / incorrect role)"
      log "  mount it (srvctl start database -d <name> -o mount) then: ./dg-switchover.sh reinstate <name>   (ORA-16795: flashback data gone -> rebuild with RMAN duplicate for standby)";;
    ORA-16783|ORA-16724|ORA-16811|ORA-16817) warn "$c: gap / cannot resolve redo / FSFO unsynchronized"
      [ "$LOCAL_ROLE" != PRIMARY ] && sql_lines "$SID" "select thread#||' gap '||low_sequence#||'-'||high_sequence# from v\$archive_gap;" | sed 's/^/    /' >&2
      log "  if the archivelogs still exist on the primary (or in a backup), register them / let FAL fetch them; if they are gone: roll the standby forward:  rman target sys@$PRIMARY auxiliary sys@<standby>  'recover database from service <primary_service> noredo using compressed backupset'  (Doc 2850185.1 style), then restart apply";;
    ORA-16625|ORA-16662|ORA-16501|ORA-16525|ORA-16532) warn "$c: the broker cannot reach a member or is not running"
      log "  check: dg_broker_start=TRUE on every member ($LOCAL_DBUN: $BROKER_ON), DMON process alive, listeners up, StaticConnectIdentifier of each member reachable (see inspect), the broker config files shared/readable on RAC"
      [ "$BROKER_ON" != TRUE ] && confirm "alter system set dg_broker_start=true on $SID ?" && { [ "$DRY_RUN" = 1 ] || sql_run "$SID" "alter system set dg_broker_start=true scope=both;" >>"$LOG_FILE"; did=1; };;
    ORA-16629|ORA-16627|ORA-16653) warn "$c: protection mode/level mismatch or operation disallowed in this mode"
      log "  with MaxAvailability/MaxProtection the standby must have SRLs and SYNC transport; see: dgmgrl> show database $TARGET LogXptMode; fix the mode or the LogXptMode, or downgrade: edit configuration set protection mode as maxperformance";;
    ORA-16789|ORA-16714|ORA-16715|ORA-16792) warn "$c: standby redo logs / property inconsistency between the broker and the database"
      log "  dgmgrl> show database <name> InconsistentProperties ; then edit database <name> set property <Prop>=<value> to realign (or fix the init parameter)"
      for m in $(members); do dgm "show database $m InconsistentProperties" | grep -vE '^[[:space:]]*$' | sed "s/^/    $m: /" >&2; done;;
    *) warn "$c: $(printf '%s\n' "$all" | grep -m1 "$c" | tr -s ' ')  (dgmgrl> show database <name> for detail; MOS 'Data Guard Broker error $c')";;
  esac; done
  [ "$did" = 1 ] && { sleep 5; CFG=""; discover; log "after healing: configuration status $CFG_STATUS"; } || log "nothing changed (diagnosis only)"; return 0
}

cmd_run() {
  discover; init_run_dir run; need_target
  cmd_inspect; echo
  cmd_preflight || die "preflight failed - nothing changed"
  cmd_plan; confirm "Proceed with backup > switchover to $TARGET > verify?" || die "aborted"
  cmd_backup
  cmd_switchover || die "FAILED: switchover. The broker state is in 'show configuration'; log: $LOG_FILE. If roles are half-changed, 'heal' shows what to start; nothing is undone automatically."
  if ! cmd_verify; then
    err "verify failed after the switchover"
    if confirm "Switch back to $(state_get old_primary) now (rollback)? [no = leave it, investigate with inspect/heal]"; then cmd_rollback; fi
    die "FAILED: verify. Log: $LOG_FILE"
  fi
  echo "SUCCESS: $TARGET is primary, $(state_get old_primary) is a physical standby with apply on. Restore points: $(state_get restore_points || echo none). Log: $LOG_FILE"
}

main() {
  load_config; refuse_root
  local cmd="${1:-}"; shift || true; parse_opts "$@"
  case "$cmd" in
    inspect) cmd_inspect;; plan) cmd_plan;; preflight) cmd_preflight;; backup) cmd_backup;; switchover) cmd_switchover;; failover) cmd_failover;;
    reinstate) cmd_reinstate;; verify) cmd_verify;; rollback) cmd_rollback;; cleanup) cmd_cleanup;; heal) cmd_heal;; run) cmd_run;;
    ""|-h|--help|help) usage;; *) die "Unknown command: $cmd";;
  esac
}
main "$@"
