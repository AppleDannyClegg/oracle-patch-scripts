#!/usr/bin/env bash
# gg-ops.sh - GoldenGate day-2: what every extract/pump/replicat is doing (status, lag, checkpoints, trail files,
# TCP stats, latest stats, discards), what the database side says (integrated capture/apply, apply errors, GGADMIN,
# supplemental logging, enable_goldengate_replication, the archivelogs the extract still needs and whether they are
# on disk, long open transactions, heartbeat lag), the ggserr/report errors, and the usual fixes: start/stop/restart,
# skip a transaction (after showing it), resync a replicat to a trail position, handlecollisions, trail cleanup,
# add trandata, and heal for the common abends (manager down, duplicate rows, missing archivelog -> the RMAN
# restore, missing privileges, lag growing). Classic (ggsci) and Microservices (adminclient, password on stdin).
# Credentials only through useridalias / the MA user. Runs as the GoldenGate owner.
#
# Usage: gg-ops.sh <command> [args] [options]
#
# Commands
#   inspect              Everything above; --report writes REPORT.md with FINDINGS (exit 2 CRIT, 1 WARN, 0 clean); --json
#   start|stop|restart <group|all>   Processes (all = every extract/replicat; the manager only with --mgr); --force kills a stuck stop
#   skip-transaction <replicat>      Show the failing transaction (report, discard, position), then start ... skiptransaction
#   resync <replicat> --from SEQNO [--rba N | --atcsn SCN]   alter replicat to a trail position (or start atcsn) and start it
#   handlecollisions <replicat> on|off   send replicat ..., handlecollisions / nohandlecollisions (runtime; param file shown)
#   trail-cleanup [--apply]          Trail files no reader still needs (checkpoints) and the PURGEOLDEXTRACTS setting; --apply deletes
#   trandata <schema[.table]> [--schema]   dblogin useridalias + add trandata (or add schematrandata with --schema)
#   plan                 What heal would do, read-only
#   heal | run           Manager down -> start; abended processes -> read the error and act: missing archivelog -> RMAN
#                        restore command (run with --yes), ORA-01031 -> grants shown, OGG-01296/01154 duplicate/missing row ->
#                        shown with skip/handlecollisions options (never automatic), other -> start again; lag growing -> status
#
# Options
#   --group NAME   limit inspect/heal to one process     --sid SID    database for the SQL checks (default: GG_SID or every instance)
#   --from N  --rba N  --atcsn SCN  --schema  --mgr  --apply  --report  --out DIR  --dry-run  --yes  --force  --json  --verbose
#
# Config: gg-ops.conf, ~/.gg-ops.conf or the shared oracle.conf: OGG_HOME, GG_ALIAS (useridalias for dblogin), GG_DOMAIN,
# GG_SCHEMA (GGADMIN), GG_SID, GG_MA_URL (https://host:port), GG_MA_DEPLOYMENT, GG_MA_USER, GG_MA_PASSWORD (or prompted),
# GG_RPT_DIR / GG_PRM_DIR (report and param dirs; MA: <deployment>/var/lib/report, <deployment>/etc/conf/ogg),
# GG_MAX_LAG_MIN (10), GG_MAX_TXN_HOURS (4), GG_TRAIL_KEEP (3 files beyond the oldest read), GG_EXPECTED_STOPPED (comma
# list of groups allowed to be stopped), GG_ERR_HOURS (24), GG_OUT (reports), RMAN_CMD.

# shellcheck disable=SC2034
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="gg-ops"; VERSION="1.0.0"
# shellcheck source=../lib/oracle-lib.sh
. "$SCRIPT_DIR/../lib/oracle-lib.sh" || { echo "lib/oracle-lib.sh not found" >&2; exit 1; }

GROUP=""; SID_OPT="${GG_SID:-}"; FROM=""; RBA="0"; ATCSN=""; SCHEMA_MODE=0; WITH_MGR=0; APPLY=0; REPORT_OUT=0
GG_ALIAS="${GG_ALIAS:-}"; GG_DOMAIN="${GG_DOMAIN:-}"; GG_SCHEMA="${GG_SCHEMA:-GGADMIN}"; GG_MA_URL="${GG_MA_URL:-}"; GG_MA_DEPLOYMENT="${GG_MA_DEPLOYMENT:-}"; GG_MA_USER="${GG_MA_USER:-}"
GG_RPT_DIR="${GG_RPT_DIR:-}"; GG_PRM_DIR="${GG_PRM_DIR:-}"
GG_MAX_LAG_MIN="${GG_MAX_LAG_MIN:-10}"; GG_MAX_TXN_HOURS="${GG_MAX_TXN_HOURS:-4}"; GG_TRAIL_KEEP="${GG_TRAIL_KEEP:-3}"; GG_EXPECTED_STOPPED="${GG_EXPECTED_STOPPED:-}"; GG_ERR_HOURS="${GG_ERR_HOURS:-24}"; GG_OUT="${GG_OUT:-$HOME/gg-ops}"
PROCS=""   # rows: program|status|group|lag_min|since_min
GG_MODE=""  # classic | ma

usage() { usage_from_header "$0"; }
parse_opts() {
  ARGS=()
  while [ $# -gt 0 ]; do case "$1" in
    --group) GROUP="$2"; shift 2;; --sid) SID_OPT="$2"; shift 2;; --from) FROM="$2"; shift 2;; --rba) RBA="$2"; shift 2;; --atcsn) ATCSN="$2"; shift 2;; --schema) SCHEMA_MODE=1; shift;; --mgr) WITH_MGR=1; shift;; --apply) APPLY=1; shift;;
    --report) REPORT_OUT=1; shift;; --out) GG_OUT="$2"; shift 2;; --dry-run) DRY_RUN=1; shift;; --yes) ASSUME_YES=1; shift;; --force) FORCE=1; shift;; --json) JSON_OUT=1; shift;; --verbose) VERBOSE=1; shift;; --run-dir) RUN_DIR="$2"; shift 2;;
    -h|--help) usage; exit 0;; --*) die "Unknown option: $1";; *) ARGS+=("$1"); shift;; esac; done
}

# ---------------------------------------------------------------------------
# command channel: ggsci (classic) or adminclient (Microservices)
# ---------------------------------------------------------------------------
gg_detect() {
  ogg_detect >/dev/null 2>&1 || [ -n "$GG_MA_URL" ] || die "no GoldenGate found: set OGG_HOME (classic) or GG_MA_URL + GG_MA_DEPLOYMENT (Microservices)"
  if [ -n "$GG_MA_URL" ]; then GG_MODE=ma; [ -n "$GG_MA_DEPLOYMENT" ] || die "GG_MA_DEPLOYMENT is required with GG_MA_URL"; ADMINCLIENT="${ADMINCLIENT:-$(command -v adminclient 2>/dev/null || ls "${OGG_HOME:-/nonexistent}"/bin/adminclient /u01/app/oracle/product/*/ogg*/bin/adminclient 2>/dev/null | head -1)}"; [ -x "${ADMINCLIENT:-}" ] || die "adminclient not found (ADMINCLIENT=)"
  else GG_MODE=classic; [ -x "$OGG_HOME/ggsci" ] || die "$OGG_HOME/ggsci not found"; fi
  GG_RPT_DIR="${GG_RPT_DIR:-${OGG_HOME:-/nonexistent}/dirrpt}"; GG_PRM_DIR="${GG_PRM_DIR:-${OGG_HOME:-/nonexistent}/dirprm}"
}
# gg <commands...>: run commands ("\n"-separated) and print the output without the prompts
gg() {
  if [ "$GG_MODE" = ma ]; then
    [ -n "$GG_MA_USER" ] || die "GG_MA_USER is required for Microservices"; read_secret GG_MA_PASSWORD "GoldenGate MA password for $GG_MA_USER"
    local nl q; nl=$'\n'; q="${*//\\n/$nl}"
    printf 'connect %s deployment %s as %s\n%s\n%s\nexit\n' "$GG_MA_URL" "$GG_MA_DEPLOYMENT" "$GG_MA_USER" "$GG_MA_PASSWORD" "$q" | to "$CMD_TIMEOUT" "$ADMINCLIENT" 2>&1 | grep -vE '^OGG \(|^Password|^$' | redact
  else ggsci "$@"; fi
}
# gg_change <what> <commands>: logged, dry-run aware
gg_change() { log "GG: ${2//\\n/; }"; [ "$DRY_RUN" = 1 ] && return 0; local o; o="$(gg "$2")"; printf '%s\n' "$o" >>"$LOG_FILE"; printf '%s\n' "$o" | grep -E 'OGG-|ERROR|error' | head -3 | sed 's/^/  /' >&2; ! printf '%s' "$o" | grep -qE '^ERROR|OGG-0[0-9]{4}.*(ERROR|error)'; }
dblogin() { [ -n "$GG_ALIAS" ] || die "GG_ALIAS (useridalias) is required for database commands"; printf 'dblogin useridalias %s%s' "$GG_ALIAS" "${GG_DOMAIN:+ domain $GG_DOMAIN}"; }
hms_to_min() { local h m s; IFS=: read -r h m s <<<"${1:-0:0:0}"; echo $(( 10#${h:-0}*60 + 10#${m:-0} + (10#${s:-0}>=30 ? 1 : 0) )); }
# load_procs: PROCS from info all
load_procs() {
  local raw; raw="$(gg "info all")"; printf '%s\n' "$raw" >"$RUN_DIR/info_all.txt"
  PROCS="$(printf '%s\n' "$raw" | awk 'BEGIN{OFS="|"} $1~/^(MANAGER|EXTRACT|REPLICAT|JAGENT|PMSRVR|ADMINSRVR|DISTSRVR|RECVSRVR)$/ { lag=""; since=""; for (i=4;i<=NF;i++) if ($i~/^[0-9]+:[0-9]+:[0-9]+$/) { if (lag=="") lag=$i; else if (since=="") since=$i }; print $1, $2, ($1=="MANAGER")?"MANAGER":(($3==""||$3~/^[0-9]+:/)?"-":$3), lag, since }')"
  [ -n "$PROCS" ] || die "could not parse 'info all' (see $RUN_DIR/info_all.txt)"
}
print_procs() { printf '%-9s %-8s %-12s %-8s %s\n' PROGRAM STATUS GROUP LAG SINCE_CHKPT; proc_rows | awk -F'|' '{printf "%-9s %-8s %-12s %-8s %s\n",$1,$2,$3,$4,$5}'; }
proc_rows() { printf '%s\n' "$PROCS" | grep . | { if [ -n "$GROUP" ]; then grep -iE "\|$GROUP\|" || true; else cat; fi; }; }
proc_status() { printf '%s\n' "$PROCS" | awk -F'|' -v g="$1" 'toupper($3)==toupper(g){print $2; exit}'; }
proc_program() { printf '%s\n' "$PROCS" | awk -F'|' -v g="$1" 'toupper($3)==toupper(g){print tolower($1); exit}'; }
expected_stopped() { case ",$(printf '%s' "$GG_EXPECTED_STOPPED" | tr 'a-z' 'A-Z')," in *",$(printf '%s' "$1" | tr 'a-z' 'A-Z'),"*) return 0;; esac; return 1; }
report_file() { local g="$1"; ls -t "$GG_RPT_DIR/$g.rpt" 2>/dev/null | head -1; }
last_error_of() { # <group>: the last OGG-xxxxx ERROR lines of the report (and the ORA- it wraps)
  local r; r="$(report_file "$1")"; [ -f "$r" ] || return 0
  grep -aE 'ERROR +OGG-|ORA-[0-9]+|OGG-0[0-9]{4}' "$r" | tail -6
}

# ---------------------------------------------------------------------------
# inspect
# ---------------------------------------------------------------------------
sids_for_sql() { if [ -n "$SID_OPT" ]; then echo "$SID_OPT"; else db_instances; fi; }
inspect_processes() {
  h2 "Processes (info all)"; fence_start; cat "$RUN_DIR/info_all.txt" >>"$REPORT"; fence_end
  local prog st g lag since
  while IFS='|' read -r prog st g lag since; do
    [ "$prog" = MANAGER ] && { [ "$st" = RUNNING ] || finding CRIT gg "MANAGER is $st: nothing restarts, no purge, no new connections"; continue; }
    case "$prog" in EXTRACT|REPLICAT) ;; *) [ "$st" = RUNNING ] || finding WARN gg "$prog is $st"; continue;; esac
    case "$st" in
      ABENDED) finding CRIT gg "$prog $g ABENDED: $(last_error_of "$g" | grep -v 'OGG-01668' | tail -1 | sed -E 's/^[0-9: -]+(ERROR|WARNING) +//' | cut -c1-160)";;
      STOPPED) expected_stopped "$g" || finding WARN gg "$prog $g is STOPPED (GG_EXPECTED_STOPPED to silence)";;
      RUNNING) local lm sm; lm="$(hms_to_min "$lag")"; sm="$(hms_to_min "$since")"
        [ "$lm" -ge $((GG_MAX_LAG_MIN*3)) ] && finding CRIT gg "$prog $g lag at checkpoint ${lag} (> 3x GG_MAX_LAG_MIN=$GG_MAX_LAG_MIN)" || { [ "$lm" -ge "$GG_MAX_LAG_MIN" ] && finding WARN gg "$prog $g lag at checkpoint $lag (> GG_MAX_LAG_MIN=$GG_MAX_LAG_MIN min)"; }
        [ "$sm" -ge "$GG_MAX_LAG_MIN" ] && finding WARN gg "$prog $g has not checkpointed for $since (hung? waiting on a long transaction?)";;
      *) finding WARN gg "$prog $g status $st";;
    esac
  done < <(proc_rows)
  h2 "Details, status, statistics"
  while IFS='|' read -r prog st g lag since; do
    case "$prog" in EXTRACT|REPLICAT) ;; *) continue;; esac
    h3 "$prog $g ($st)"
    local det; det="$(gg "info $g, detail")"; printf '%s\n' "$det" >"$RAW/info_${g}_detail.txt"; fence_start; printf '%s\n' "$det" | head -60 >>"$REPORT"; fence_end
    if [ "$st" = RUNNING ]; then
      local s; s="$(gg "send $g, status")"; printf '%s\n' "$s" >"$RAW/send_${g}_status.txt"; fence_start; printf '%s\n' "$s" | head -25 >>"$REPORT"; fence_end
      printf '%s' "$s" | grep -qiE 'Current status: *(Waiting|At EOF|Processing data)|In recovery' && { printf '%s' "$s" | grep -qi 'In recovery' && finding WARN gg "$prog $g is in recovery (re-reading the trail/redo since the last checkpoint)"; }
      [ "$prog" = EXTRACT ] && { local tcp; tcp="$(gg "send $g, gettcpstats" 2>/dev/null)"; printf '%s\n' "$tcp" | grep -qiE 'RMTHOST|bytes' && { printf '%s\n' "$tcp" >"$RAW/tcp_${g}.txt"; para "TCP (pump): $(printf '%s\n' "$tcp" | grep -iE 'RMTHOST|Round trip|Bytes' | head -4 | tr '\n' ';' | cut -c1-300)"; }; }
      local stt; stt="$(gg "stats $g, latest, reportrate min" 2>/dev/null | grep -vE '^$' | head -40)"; printf '%s\n' "$stt" >"$RAW/stats_${g}.txt"; para "stats latest (per minute): $(printf '%s\n' "$stt" | grep -E 'Total (inserts|updates|deletes|discards|operations)' | awk '{print $2": "$NF}' | tr '\n' ' ' | cut -c1-300)"
      printf '%s\n' "$stt" | grep -E 'Total discards' | awk '{if ($NF+0 > 0) exit 1}' || finding WARN gg "$prog $g has discards in the latest stats"
      [ "$prog" = EXTRACT ] && ! grep -q 'Log Read Checkpoint  File' "$RAW/info_${g}_detail.txt" && { local tr; tr="$(gg "send $g, showtrans duration $GG_MAX_TXN_HOURS hour" 2>/dev/null)"; printf '%s\n' "$tr" >"$RAW/showtrans_${g}.txt"; printf '%s' "$tr" | grep -qiE 'XID|Start Time' && finding WARN gg "$prog $g: open transaction(s) older than $GG_MAX_TXN_HOURS h (send $g, showtrans): the extract cannot move its recovery checkpoint past them: $(printf '%s\n' "$tr" | grep -iE 'XID|Items' | head -2 | tr '\n' ' ' | cut -c1-160)"; }
    else
      local err; err="$(last_error_of "$g")"; [ -n "$err" ] && { para "last errors in $(report_file "$g"):"; fence_start; printf '%s\n' "$err" >>"$REPORT"; fence_end; }
    fi
    local dsc="$GG_RPT_DIR/$g.dsc"; [ -f "$dsc" ] && [ "$(file_size "$dsc")" -gt 0 ] && { para "discard file $dsc: $(du -h "$dsc" | cut -f1), modified $(file_mtime "$dsc")"; [ -n "$(find "$dsc" -newer "$RUN_DIR/.err_since" 2>/dev/null)" ] && finding WARN gg "$prog $g discard file grew in the last $GG_ERR_HOURS h ($dsc, $(du -h "$dsc" | cut -f1)): rows are being rejected"; }
  done < <(proc_rows)
}
trail_readers() { # group|trailfile|seq for every reader (pump reads a local trail, replicat reads its trail)
  local prog st g lag since; while IFS='|' read -r prog st g lag since; do
    [ "$prog" = REPLICAT ] || [ "$prog" = EXTRACT ] || continue
    awk -v g="$g" '/Log Read Checkpoint +File/{f=$NF; s=f; sub(/.*[^0-9]/,"",s); print g"|"f"|"(s+0)}' "$RAW/info_${g}_detail.txt" 2>/dev/null
  done < <(proc_rows) | grep -E '\|.*dirdat'
}
inspect_trails() {
  h2 "Trail directories"
  local d; for d in "$OGG_HOME"/dirdat "$OGG_HOME"/dirdat_*; do [ -d "$d" ] || continue
    local use; use="$(df -P "$d" | awk 'NR==2{print $5}' | tr -d '%')"
    kv "$d" "$(du -sh "$d" 2>/dev/null | cut -f1), $(find "$d" -type f | wc -l | tr -d ' ') files, filesystem ${use}% used, oldest $(find "$d" -type f -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | tail -1 | sed 's#.*/##')"
    [ "${use:-0}" -ge 95 ] && finding CRIT gg "trail filesystem of $d is ${use}% full: extracts abend when it fills" || { [ "${use:-0}" -ge 85 ] && finding WARN gg "trail filesystem of $d is ${use}% full"; }
  done; kv_end
  para "readers (checkpoint positions): $(trail_readers | tr '\n' ' ' | cut -c1-400)"
  grep -iE '^ *PURGEOLDEXTRACTS' "$GG_PRM_DIR/mgr.prm" 2>/dev/null | head -3 | sed 's/^/mgr.prm: /' | while IFS= read -r l; do para "$l"; done
  grep -qiE '^ *PURGEOLDEXTRACTS' "$GG_PRM_DIR/mgr.prm" 2>/dev/null || finding WARN gg "mgr.prm has no PURGEOLDEXTRACTS: trail files are never purged (trail-cleanup shows what can go)"
  grep -qiE '^ *AUTORESTART' "$GG_PRM_DIR/mgr.prm" 2>/dev/null || finding INFO gg "mgr.prm has no AUTORESTART: abended processes stay down until someone starts them"
}
inspect_errors() {
  h2 "ggserr.log (last $GG_ERR_HOURS h)"
  local f="$OGG_HOME/ggserr.log"; [ -f "$f" ] || { para "_no ggserr.log_"; return 0; }
  local since; since="$(if [ "$GNU_DATE" = 1 ]; then date -d "-$GG_ERR_HOURS hours" '+%Y-%m-%d %H:%M:%S'; else date -v-"$GG_ERR_HOURS"H '+%Y-%m-%d %H:%M:%S'; fi)"
  tail -n 100000 "$f" | awk -v s="$since" '{ts=substr($0,1,19); if (ts>=s) p=1} p' >"$RAW/ggserr_window.txt"
  local n; n="$(grep -cE ' ERROR +OGG-' "$RAW/ggserr_window.txt")"; local w; w="$(grep -cE ' WARNING +OGG-' "$RAW/ggserr_window.txt")"
  kv "lines in window" "$(wc -l <"$RAW/ggserr_window.txt" | tr -d ' ')"; kv "errors" "$n"; kv "warnings" "$w"; kv_end
  fence_start; grep -E ' (ERROR|WARNING) +OGG-' "$RAW/ggserr_window.txt" | sed -E 's/^[0-9: -]+//' | cut -c1-160 | sort | uniq -c | sort -rn | head -20 >>"$REPORT"; fence_end
  [ "$n" -gt 0 ] && finding WARN gg "$n ERROR line(s) in ggserr.log in the last $GG_ERR_HOURS h: $(grep -E ' ERROR +OGG-' "$RAW/ggserr_window.txt" | tail -1 | grep -oE 'OGG-[0-9]+.*' | cut -c1-120)"
  return 0
}
inspect_db() {
  local sid="$1"; sql_ok "$sid" || { para "_$sid: sqlplus does not answer_"; return 0; }
  h2 "Database $sid"
  sqlsec "$sid" ggparams "GoldenGate parameters, supplemental logging, GGADMIN" "select name, value from v\$parameter where name in ('enable_goldengate_replication','streams_pool_size','compatible','log_mode');
select log_mode, supplemental_log_data_min, supplemental_log_data_pk, supplemental_log_data_ui, supplemental_log_data_all, force_logging from v\$database;
select username, account_status, expiry_date, profile from dba_users where username in ('$GG_SCHEMA','C##$GG_SCHEMA','GGADMIN','C##GGADMIN');"
  sql_checks "$sid" "gg" "select 'CHECK|CRIT|enable_goldengate_replication is '||value||' (must be TRUE)' from v\$parameter where name='enable_goldengate_replication' and upper(value)<>'TRUE';
select 'CHECK|CRIT|minimal supplemental logging is OFF (add supplemental log data)' from v\$database where supplemental_log_data_min='NO';
select 'CHECK|WARN|force_logging is NO: NOLOGGING operations are not captured' from v\$database where force_logging='NO';
select 'CHECK|CRIT|'||username||' is '||account_status||' - extracts/replicats will fail to log in' from dba_users where username in ('$GG_SCHEMA','C##$GG_SCHEMA') and account_status<>'OPEN';
select 'CHECK|WARN|'||username||' password expires '||to_char(expiry_date,'YYYY-MM-DD') from dba_users where username in ('$GG_SCHEMA','C##$GG_SCHEMA') and expiry_date < sysdate+14;
select 'CHECK|CRIT|integrated capture '||capture_name||' is '||status||' '||nvl(error_message,'') from dba_capture where status<>'ENABLED';
select 'CHECK|CRIT|integrated apply '||apply_name||' is '||status||' '||nvl(error_message,'') from dba_apply where status<>'ENABLED' and purpose like '%GoldenGate%';
select 'CHECK|CRIT|'||count(*)||' apply error(s) in dba_apply_error for '||apply_name||' (first: '||min(error_message)||')' from dba_apply_error group by apply_name;
select 'CHECK|WARN|integrated capture '||capture_name||' lag '||round((sysdate-capture_message_create_time)*1440)||' min' from v\$goldengate_capture where (sysdate-capture_message_create_time)*1440 > $GG_MAX_LAG_MIN;
select 'CHECK|WARN|streams_pool_size is '||round(value/1048576)||' MB (integrated extract wants >= 1 GB per extract)' from v\$parameter where name='streams_pool_size' and value < 1073741824 and exists (select 1 from dba_capture);
select 'CHECK|WARN|transaction open for '||round((sysdate-to_date(start_time,'MM/DD/YY HH24:MI:SS'))*24,1)||' h by sid '||s.sid||' ('||s.username||' '||s.program||'): extract recovery checkpoint cannot pass it' from v\$transaction t join v\$session s on s.saddr=t.ses_addr where (sysdate-to_date(start_time,'MM/DD/YY HH24:MI:SS'))*24 > $GG_MAX_TXN_HOURS;"
  sqlsec "$sid" ggcapture "Integrated capture / apply" "select capture_name, status, capture_type, required_checkpoint_scn, captured_scn, applied_scn, error_message from dba_capture;
select capture_name, state, startup_time, capture_message_create_time, round((sysdate-capture_message_create_time)*1440) lag_min, total_messages_captured from v\$goldengate_capture;
select apply_name, status, purpose, error_message from dba_apply;
select apply_name, count(*) errors, min(source_commit_scn) first_scn, max(error_number) error_number, substr(min(error_message),1,120) first_message from dba_apply_error group by apply_name;"
  # archivelogs the integrated extract still needs
  sqlsec "$sid" ggarchive "Archivelogs needed by the capture (required_checkpoint_scn) and whether they are on disk" "select c.capture_name, c.required_checkpoint_scn, min(l.sequence#) first_needed_seq, max(l.sequence#) last_seq, sum(case when l.deleted='YES' or l.name is null then 1 else 0 end) missing_on_disk, sum(case when l.backup_count>0 then 1 else 0 end) backed_up from dba_capture c join v\$archived_log l on l.next_change# > c.required_checkpoint_scn and l.dest_id=1 and l.standby_dest='NO' group by c.capture_name, c.required_checkpoint_scn;"
  sql_checks "$sid" "gg" "select 'CHECK|CRIT|capture '||c.capture_name||' needs archivelog sequences from '||min(l.sequence#)||' but '||sum(case when l.deleted='YES' or l.name is null then 1 else 0 end)||' of them are no longer on disk (RMAN: restore archivelog from logseq '||min(l.sequence#)||' until logseq '||max(case when l.deleted='YES' or l.name is null then l.sequence# end)||' thread '||min(l.thread#)||';)' from dba_capture c join v\$archived_log l on l.next_change# > c.required_checkpoint_scn and l.dest_id=1 and l.standby_dest='NO' group by c.capture_name having sum(case when l.deleted='YES' or l.name is null then 1 else 0 end) > 0;"
  if [ "$(sql_val "$sid" "count(*) from dba_views where owner='$GG_SCHEMA' and view_name='GG_LAG'" 2>/dev/null)" = 1 ]; then
  sqlsec "$sid" ggheartbeat "Heartbeat lag ($GG_SCHEMA.gg_lag)" "select local_database, remote_database, incoming_path, round(incoming_lag) incoming_lag_sec, incoming_heartbeat_age, outgoing_path, round(outgoing_lag) outgoing_lag_sec from $GG_SCHEMA.gg_lag;"
  sql_checks "$sid" "gg" "select 'CHECK|WARN|heartbeat lag from '||remote_database||' is '||round(incoming_lag/60)||' min ('||incoming_path||')' from $GG_SCHEMA.gg_lag where incoming_lag/60 > $GG_MAX_LAG_MIN;
select 'CHECK|WARN|heartbeat from '||remote_database||' is '||round(incoming_heartbeat_age/60)||' min old: nothing arriving' from $GG_SCHEMA.gg_lag where incoming_heartbeat_age/60 > $GG_MAX_LAG_MIN*3;"
  else finding INFO gg "$sid: no heartbeat table ($GG_SCHEMA.gg_lag): ggsci> dblogin useridalias $GG_ALIAS; add heartbeattable - end-to-end lag is not measured"; fi
  # trandata for the schemas the extracts capture
  local schemas; schemas="$(cat "$GG_PRM_DIR"/*.prm 2>/dev/null | grep -iE '^ *TABLE +' | awk '{print $2}' | sed 's/[;,].*//; s/\..*//' | tr -d '"' | tr 'a-z' 'A-Z' | sort -u | grep -vE '^\*|^$' | head -20 | sed "s/.*/'&'/" | paste -sd, -)"
  [ -n "$schemas" ] && { sqlsec "$sid" ggtrandata "Tables without supplemental log groups (trandata) in the captured schemas" "select owner, count(*) tables_without_trandata from dba_tables t where owner in ($schemas) and temporary='N' and not exists (select 1 from dba_log_groups g where g.owner=t.owner and g.table_name=t.table_name) and not exists (select 1 from v\$database d where d.supplemental_log_data_all='YES') group by owner order by 2 desc;"
    sql_checks "$sid" "gg" "select 'CHECK|WARN|'||count(*)||' table(s) in '||owner||' have no supplemental log group (add trandata / schematrandata)' from dba_tables t where owner in ($schemas) and temporary='N' and not exists (select 1 from dba_log_groups g where g.owner=t.owner and g.table_name=t.table_name) and not exists (select 1 from v\$database d where d.supplemental_log_data_all='YES') group by owner having count(*)>0;"; }
  return 0
}
cmd_inspect() {
  init_run_dir inspect; gg_detect; load_procs
  touch -t "$(if [ "$GNU_DATE" = 1 ]; then date -d "-$GG_ERR_HOURS hours" '+%Y%m%d%H%M'; else date -v-"$GG_ERR_HOURS"H '+%Y%m%d%H%M'; fi)" "$RUN_DIR/.err_since" 2>/dev/null || touch "$RUN_DIR/.err_since"
  report_init "$([ "$REPORT_OUT" = 1 ] && echo "$GG_OUT/${HOST}_gg_$(date '+%Y%m%d_%H%M%S')" || echo "$RUN_DIR/report")"
  h1 "GoldenGate on $HOST ($GG_MODE, ${OGG_HOME:-$GG_MA_URL})"; kv "mode" "$GG_MODE"; kv "home" "${OGG_HOME:-$GG_MA_DEPLOYMENT@$GG_MA_URL}"; kv "version" "$(gg "versions" 2>/dev/null | grep -iE 'Oracle GoldenGate|Version' | head -2 | tr '\n' ' ' | cut -c1-120)"; kv_end
  inspect_processes; [ "$GG_MODE" = classic ] && { inspect_trails; inspect_errors; }
  local sid; for sid in $(sids_for_sql); do inspect_db "$sid"; done
  findings_sync
  if [ "$JSON_OUT" = 1 ]; then
    printf '{"host":"%s","mode":"%s","processes":[' "$HOST" "$GG_MODE"; local first=1 prog st g lag since
    while IFS='|' read -r prog st g lag since; do printf '%s{"program":"%s","status":"%s","group":"%s","lag_min":%s,"since_chkpt_min":%s}' "$([ $first = 1 ] || echo ,)" "$prog" "$st" "$g" "$(hms_to_min "$lag")" "$(hms_to_min "$since")"; first=0; done < <(proc_rows)
    printf '],"findings":['; first=1; awk '!seen[$0]++' "$FINDINGS_FILE" | while IFS='|' read -r sev area txt; do printf '%s{"severity":"%s","area":"%s","text":"%s"}' "$([ $first = 1 ] || echo ,)" "$sev" "$area" "$(json_escape "$txt")"; first=0; done; echo ']}'; return 0
  fi
  print_procs; echo
  print_findings 'CRIT|WARN|INFO'
  if [ "$REPORT_OUT" = 1 ]; then report_finish "gg-ops inspect: $HOST" 0 >/dev/null; findings_rc; return $?; fi
  return 0
}

# ---------------------------------------------------------------------------
# changes
# ---------------------------------------------------------------------------
targets_of() { # <group|all> -> groups (extracts first for start, replicats first for stop handled by caller)
  if [ "$(printf '%s' "$1" | tr 'a-z' 'A-Z')" = ALL ]; then printf '%s\n' "$PROCS" | awk -F'|' '$1=="EXTRACT"||$1=="REPLICAT"{print $3}'; [ "$WITH_MGR" = 1 ] && echo MANAGER
  else printf '%s' "$1"; fi
}
start_one() { local g="$1" p; p="$(proc_program "$g")"; [ -n "$p" ] || die "unknown group $g"; [ "$p" = manager ] && { gg_change start "start mgr"; return; }
  [ "$(proc_status "$g")" = RUNNING ] && { log "$g already running"; return 0; }; gg_change start "start $p $g"; }
stop_one() { local g="$1" p; p="$(proc_program "$g")"; [ -n "$p" ] || die "unknown group $g"; [ "$p" = manager ] && { gg_change stop "stop mgr !"; return; }
  [ "$(proc_status "$g")" = RUNNING ] || { log "$g is not running ($(proc_status "$g"))"; return 0; }
  gg_change stop "stop $p $g"; [ "$DRY_RUN" = 1 ] && return 0; sleep 3; load_procs; [ "$(proc_status "$g")" = RUNNING ] || return 0
  [ "$FORCE" = 1 ] && { warn "$g still running: kill $p $g (--force)"; gg_change kill "kill $p $g"; return; }; warn "$g still running (a long transaction is being rolled back / applied); wait, or --force to kill"; return 1; }
cmd_start() { local t="${ARGS[0]:-}"; [ -n "$t" ] || die "start <group|all>"; init_run_dir start; gg_detect; load_procs; local g; for g in $(targets_of "$t"); do confirm "start $g?" || continue; start_one "$g"; done; sleep 2; load_procs; print_procs; }
cmd_stop() { local t="${ARGS[0]:-}"; [ -n "$t" ] || die "stop <group|all>"; init_run_dir stop; gg_detect; load_procs; local g; for g in $(targets_of "$t" | sort -r); do confirm "stop $g?" || continue; stop_one "$g" || true; done; load_procs; print_procs; }
cmd_restart() { local t="${ARGS[0]:-}"; [ -n "$t" ] || die "restart <group|all>"; init_run_dir restart; gg_detect; load_procs; local g; for g in $(targets_of "$t"); do confirm "restart $g?" || continue; stop_one "$g" || { warn "$g not stopped: not started again"; continue; }; start_one "$g"; done; sleep 2; load_procs; print_procs; }
show_failing_txn() { # <replicat>
  local g="$1" r; r="$(report_file "$g")"
  echo "--- last errors in ${r:-no report}:"; last_error_of "$g" | cut -c1-200
  [ -f "$r" ] && { echo "--- position / mapping in the report:"; grep -aE 'Last log location|Seqno|RBA|Mapping problem|Error mapping|Operation|Logdump|Table ' "$r" | tail -8 | cut -c1-200; }
  local d="$GG_RPT_DIR/$g.dsc"; [ -f "$d" ] && { echo "--- discard file $d (tail):"; tail -40 "$d" | cut -c1-200; }
  echo "--- checkpoint:"; gg "info $g, detail" | grep -aE 'Log Read Checkpoint|Sequence|RBA|Timestamp' | head -4
}
cmd_skip() {
  local g="${ARGS[0]:-}"; [ -n "$g" ] || die "skip-transaction <replicat>"; init_run_dir skip; gg_detect; load_procs
  [ "$(proc_program "$g")" = replicat ] || die "$g is not a replicat"
  echo "The transaction that $g will skip (it is NOT applied on the target; the rows stay different until you fix them):"; show_failing_txn "$g" | tee "$RUN_DIR/skipped_txn.txt"
  echo; echo "Alternatives: fix the target row and start normally; REPERROR (DEFAULT, DISCARD) for a rule; handlecollisions for an initial-load overlap."
  confirm_typed "Skip this transaction on $g" "$g" || die "aborted"
  gg_change skip "start replicat $g skiptransaction" || die "start ... skiptransaction failed (see $LOG_FILE)"; sleep 3; load_procs; GROUP="$g" print_procs; state_set skipped "$g"
}
cmd_resync() {
  local g="${ARGS[0]:-}"; [ -n "$g" ] || die "resync <replicat> --from SEQNO [--rba N | --atcsn SCN]"; [ -n "$FROM" ] || [ -n "$ATCSN" ] || die "--from SEQNO (trail sequence) or --atcsn SCN is required"
  init_run_dir resync; gg_detect; load_procs; [ "$(proc_program "$g")" = replicat ] || die "$g is not a replicat"
  echo "current position:"; gg "info $g, detail" | grep -aE 'Log Read Checkpoint|Sequence|RBA|Timestamp' | head -4 | tee "$RUN_DIR/position_before.txt"
  [ "$(proc_status "$g")" = RUNNING ] && { confirm "$g is running: stop it first?" || die "aborted"; stop_one "$g" || die "could not stop $g"; }
  if [ -n "$FROM" ]; then confirm_typed "alter replicat $g, extseqno $FROM, extrba ${RBA:-0} (every transaction between the old and the new position is applied twice or never)" "$g" || die "aborted"
    gg_change alter "alter replicat $g, extseqno $FROM, extrba ${RBA:-0}" || die "alter failed"; gg_change start "start replicat $g"
  else confirm_typed "start replicat $g atcsn $ATCSN (transactions committed before that CSN are skipped)" "$g" || die "aborted"; gg_change start "start replicat $g atcsn $ATCSN"; fi
  sleep 3; load_procs; GROUP="$g" print_procs; gg "info $g, detail" | grep -aE 'Log Read Checkpoint|Sequence|RBA' | head -3
}
cmd_handlecollisions() {
  local g="${ARGS[0]:-}" onoff="${ARGS[1]:-}"; [ -n "$g" ] && [[ "$onoff" =~ ^(on|off)$ ]] || die "handlecollisions <replicat> on|off"
  init_run_dir handlecollisions; gg_detect; load_procs; [ "$(proc_program "$g")" = replicat ] || die "$g is not a replicat"
  local prm; prm="$GG_PRM_DIR/$(printf '%s' "$g" | tr 'A-Z' 'a-z').prm"; grep -iE 'HANDLECOLLISIONS' "$prm" 2>/dev/null | sed "s#^#$prm: #" || echo "$prm: no HANDLECOLLISIONS line (runtime setting only lasts until the next start)"
  [ "$onoff" = on ] && warn "handlecollisions makes the replicat overwrite/ignore conflicting rows: for an initial-load overlap only; turn it OFF when the load is applied"
  confirm "send replicat $g, $([ "$onoff" = on ] && echo handlecollisions || echo nohandlecollisions)?" || die "aborted"
  gg_change hc "send replicat $g, $([ "$onoff" = on ] && echo handlecollisions || echo nohandlecollisions)"
}
cmd_trail_cleanup() {
  init_run_dir trail-cleanup; gg_detect; load_procs; local g; for g in $(printf '%s\n' "$PROCS" | awk -F'|' '$1=="EXTRACT"||$1=="REPLICAT"{print $3}'); do gg "info $g, detail" >"$RUN_DIR/info_${g}_detail.txt"; done
  RAW="$RUN_DIR"; local readers; readers="$(trail_readers)"; echo "readers: "; printf '%s\n' "$readers" | sed 's/^/  /'
  grep -iE '^ *PURGEOLDEXTRACTS' "$GG_PRM_DIR/mgr.prm" 2>/dev/null | sed 's/^/mgr.prm: /' || echo "mgr.prm: no PURGEOLDEXTRACTS (suggest: PURGEOLDEXTRACTS ./dirdat/*, USECHECKPOINTS, MINKEEPHOURS 48)"
  local n=0 total=0 f prefix minseq
  for prefix in $(printf '%s\n' "$readers" | cut -d'|' -f2 | sed -E 's/[0-9]+$//' | sort -u); do
    minseq="$(printf '%s\n' "$readers" | awk -F'|' -v p="$prefix" 'index($2,p)==1{print $3+0}' | sort -n | head -1)"; [ -n "$minseq" ] || continue
    local keep=$((minseq - GG_TRAIL_KEEP)); echo "trail $prefix: oldest read sequence $minseq, files below $keep are not needed by any checkpoint"
    for f in "$OGG_HOME"/"${prefix#./}"[0-9]*; do [ -f "$f" ] || continue; local s; s="$(printf '%s' "$f" | grep -oE '[0-9]+$')"; [ "$((10#$s))" -lt "$keep" ] || continue
      n=$((n+1)); total=$((total + $(file_size "$f")/1048576)); if [ "$APPLY" = 1 ]; then log "rm $f"; [ "$DRY_RUN" = 1 ] || rm -f "$f"; else echo "  would remove $f ($(du -h "$f" | cut -f1))"; fi; done
  done
  echo "$n file(s), ${total} MB $([ "$APPLY" = 1 ] && echo removed || echo 'removable (--apply)')"
  [ "$APPLY" = 0 ] && [ "$n" -gt 0 ] && echo "Better long-term: PURGEOLDEXTRACTS in mgr.prm so the manager does this with the checkpoints."
  return 0
}
cmd_trandata() {
  local t="${ARGS[0]:-}"; [ -n "$t" ] || die "trandata <schema[.table]> [--schema]"; init_run_dir trandata; gg_detect
  local cmd; if [ "$SCHEMA_MODE" = 1 ]; then cmd="add schematrandata ${t%%.*}"; else cmd="add trandata $t$([ "${t#*.}" = "$t" ] && echo '.*')"; fi
  echo "before:"; gg "$(dblogin)\ninfo $([ "$SCHEMA_MODE" = 1 ] && echo "schematrandata ${t%%.*}" || echo "trandata $t$([ "${t#*.}" = "$t" ] && echo '.*')")" | grep -viE '^Successfully logged|^$' | head -20
  confirm "$cmd (as $GG_ALIAS)?" || die "aborted"; gg_change trandata "$(dblogin)\n$cmd" || die "add trandata failed (see $LOG_FILE)"
  echo "after:"; gg "$(dblogin)\ninfo $([ "$SCHEMA_MODE" = 1 ] && echo "schematrandata ${t%%.*}" || echo "trandata $t$([ "${t#*.}" = "$t" ] && echo '.*')")" | grep -viE '^Successfully logged|^$' | head -20
}

# ---------------------------------------------------------------------------
# heal
# ---------------------------------------------------------------------------
heal_one() { # <group> <status>: decide from the report's last error
  local g="$1" st="$2" p err; p="$(proc_program "$g")"; err="$(last_error_of "$g")"
  echo; echo "== $p $g is $st"; printf '%s\n' "$err" | cut -c1-200 | sed 's/^/   /'
  case "$err" in
    *OGG-00446*|*OGG-02028*|*OGG-01028*"archive"*|*"Could not find archived log"*)
      local seq thr; seq="$(printf '%s' "$err" | grep -oE 'sequence[^0-9]*[0-9]+' | grep -oE '[0-9]+' | head -1)"; thr="$(printf '%s' "$err" | grep -oE 'thread[^0-9]*[0-9]+' | grep -oE '[0-9]+' | head -1)"
      local cur; cur="$(for s in $(sids_for_sql); do sql_val "$s" "(select max(sequence#) from v\$archived_log where thread#=${thr:-1} and dest_id=1)" 2>/dev/null; done | head -1)"
      local rman="restore archivelog from logseq ${seq:-N} until logseq ${cur:-M} thread ${thr:-1};"
      echo "   -> missing archivelog(s): the extract needs sequence ${seq:-?} (thread ${thr:-?}) which RMAN deleted. Restore them, then start: RMAN> $rman"
      [ -n "$seq" ] && confirm "run RMAN '$rman' on $(sids_for_sql | head -1) now?" && { if rman_restore "$(sids_for_sql | head -1)" "$rman"; then confirm "start $p $g?" && start_one "$g"; else err "RMAN restore failed (see $LOG_FILE)"; fi; };;
    *ORA-01031*|*OGG-00665*"insufficient privileges"*|*ORA-01017*)
      echo "   -> database privileges / login: as SYSDBA: exec dbms_goldengate_auth.grant_admin_privilege('$GG_SCHEMA'); grant select any dictionary, select any transaction to $GG_SCHEMA; alter system set enable_goldengate_replication=true;"
      echo "      and check the credential store: ggsci> info credentialstore / alter credentialstore replace user ... alias $GG_ALIAS (account-ops.sh reset --user $GG_SCHEMA propagates a password change)";;
    *OGG-01296*|*OGG-01154*|*ORA-00001*|*ORA-01403*|*OGG-01403*)
      echo "   -> data conflict (duplicate / missing row) on the target: not restarted automatically."; show_failing_txn "$g" | sed 's/^/      /' | head -30
      echo "      options: fix the target row, then start $p $g | gg-ops.sh skip-transaction $g (loses that transaction) | handlecollisions $g on for an initial-load overlap | REPERROR in the param file";;
    *OGG-01668*|*OGG-00868*|*OGG-00516*|*ORA-03113*|*ORA-03135*|*ORA-12541*|*ORA-12514*|*TNS-*)
      echo "   -> database/network connection lost; start again (and check the listener / RAC services if it recurs)"; confirm "start $p $g?" && start_one "$g";;
    *OGG-01161*|*OGG-00919*|*OGG-00212*)
      echo "   -> parameter / mapping error: fix the param file first: $OGG_HOME/dirprm/$(printf '%s' "$g" | tr 'A-Z' 'a-z').prm, then start";;
    "")
      echo "   -> no error in the report (stopped on purpose?)"; expected_stopped "$g" && echo "      listed in GG_EXPECTED_STOPPED: left alone" || { confirm "start $p $g?" && start_one "$g"; };;
    *) echo "   -> not a pattern this script knows; the report is $(report_file "$g")"; confirm "start $p $g anyway?" && start_one "$g";;
  esac
}
rman_restore() { # <sid> <rman command>
  local sid="$1" home; home="$(db_home_of "$sid")"; log "RMAN ($sid): $2"; [ "$DRY_RUN" = 1 ] && return 0
  printf 'connect target /\n%s\nexit\n' "$2" | ORACLE_SID="$sid" ORACLE_HOME="$home" PATH="$home/bin:$PATH" to 3600 "${RMAN_CMD:-$home/bin/rman}" >>"$LOG_FILE" 2>&1 && log "RMAN restore done"
}
cmd_heal() {
  init_run_dir heal; gg_detect; load_procs; local prog st g lag since any=0
  [ "$(proc_status MANAGER)" = RUNNING ] || [ "$GG_MODE" = ma ] || { echo "== MANAGER is $(proc_status MANAGER)"; confirm "start mgr?" && { start_one MANAGER; sleep 3; load_procs; }; any=1; }
  while IFS='|' read -r prog st g lag since; do
    case "$prog" in EXTRACT|REPLICAT) ;; *) continue;; esac
    case "$st" in ABENDED|STOPPED) [ "$st" = STOPPED ] && expected_stopped "$g" && continue; any=1; heal_one "$g" "$st";;
      RUNNING) local lm; lm="$(hms_to_min "$lag")"; [ "$lm" -ge "$GG_MAX_LAG_MIN" ] && { any=1; echo; echo "== $prog $g lag $lag"; gg "send $g, status" | head -12 | sed 's/^/   /'; [ "$prog" = REPLICAT ] && echo "   -> replicat lag: check apply throughput (stats $g, latest), target waits (blocking sessions, indexes), BATCHSQL / parallel (integrated: PARALLELISM) in the param file" || echo "   -> extract lag: a long-running transaction (send $g, showtrans), redo volume, or a pump that cannot reach the target (send $g, gettcpstats)"; };;
    esac
  done < <(proc_rows)
  [ "$any" = 0 ] && echo "nothing to heal: every process is RUNNING within GG_MAX_LAG_MIN=$GG_MAX_LAG_MIN min"
  sleep 2; load_procs; echo; proc_rows | awk -F'|' '{printf "%-9s %-8s %-12s %-8s %s\n",$1,$2,$3,$4,$5}'
  printf '%s\n' "$PROCS" | grep -qE '\|(ABENDED|STOPPED)\|' && { echo "still down: $(printf '%s\n' "$PROCS" | awk -F'|' '$2=="ABENDED"||$2=="STOPPED"{print $3}' | tr '\n' ' ') - see the reports and gg-ops.sh inspect --report"; return 1; }
  return 0
}
cmd_plan() { DRY_RUN=1; ASSUME_YES=1; cmd_heal; }

main() {
  load_config; refuse_root
  local cmd="${1:-}"; shift || true; parse_opts "$@"; [ -n "$SID_OPT" ] || SID_OPT="${GG_SID:-}"
  case "$cmd" in
    inspect) cmd_inspect;; start) cmd_start;; stop) cmd_stop;; restart) cmd_restart;; skip-transaction) cmd_skip;; resync) cmd_resync;; handlecollisions) cmd_handlecollisions;;
    trail-cleanup) cmd_trail_cleanup;; trandata) cmd_trandata;; plan) cmd_plan;; heal|run) cmd_heal;; ""|-h|--help|help) usage;; *) die "Unknown command: $cmd";;
  esac
}
main "$@"
