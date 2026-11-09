#!/usr/bin/env bash
# incident-pack.sh - everything Oracle Support asks for, in one tarball, for one incident: the oracle-diag
# report, ADR incident packages (adrci ips) or a tfactl diagcollect, the alert/listener/WebLogic/ORDS/GoldenGate
# log windows, the trace files the alert log names, SQL snapshots of the instance (version, parameters, patches,
# sessions, blockers, locks, jobs), pfile, opatch inventory, optional AWR/ASH, optional thread dumps / heap
# histograms, optional hanganalyze + systemstate, host evidence (OSWatcher window, dmesg, journal, sar, messages,
# df, free, sysctl, rpm, ps, ss), Exadata alerts. A MANIFEST.md and FACTS.txt on top (sr-draft reads them).
# Read-only, except: --hang (oradebug dumps), --heap-dump, and a 'create pfile from spfile' into the pack.
# Passwords are redacted from copied config files. Runs as the Oracle software owner.
#
# Usage: incident-pack.sh <SR-number-or-label> [options]
#
#   --since "YYYY-MM-DD HH:MM"   start of the window (default: --hours back from now)
#   --hours N          window length back from now (default 24); --until "YYYY-MM-DD HH:MM" to end earlier
#   --sid SID          only this database (default: every running instance)
#   --component LIST   db,wls,ords,apex,gg,host,exa (default: everything detected; repeatable or comma list)
#   --awr              AWR and ASH text reports for the window (dbms_workload_repository)
#   --threads          3 thread dumps 10 s apart of every WebLogic/ORDS JVM, plus a class histogram
#   --heap-dump        jcmd GC.heap_dump of those JVMs (large, pauses the JVM) - needs --yes
#   --hang             oradebug hanganalyze 3 + systemstate 258 on each instance (minutes on big systems) - needs --yes
#   --no-diag          do not run ../../reports/oracle-diag/oracle-diag.sh first
#   --no-tfa           do not run tfactl diagcollect even when AHF/TFA is installed
#   --split            always split the tarball into 1900 MB parts (automatic above 2 GB: MOS upload limit)
#   --out DIR          where to build (default PACK_OUT or ~/incident-pack)
#   --cap-mb N         max MB kept of any one log/trace file (default 100: the last N MB are kept)
#   --no-redact  --dry-run  --yes  --verbose
#
# Config: incident-pack.conf, ~/.incident-pack.conf or the shared oracle.conf: PACK_OUT, PACK_CAP_MB, PACK_HOURS,
# OSW_ARCHIVE (OSWatcher archive dir when not under AHF), SQL_CONNECT, ORDS_HOME/ORDS_CONFIG/ORDS_SERVICE,
# OGG_HOME, GG_DEPLOY_DIRS, EXTRA_FILES (comma list of more files/dirs to include), EXTRA_LOGS (timestamped logs
# to window: file=alert|listener|wls|iso), TFA_TIMEOUT (1800).
# Output: <out>/<sr>_<host>_<ts>/ and <sr>_<host>_<ts>.tar.gz (+ .partNN when split), sha256 printed.

# shellcheck disable=SC2034
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="incident-pack"; VERSION="1.0.0"
# shellcheck source=../../lib/oracle-lib.sh
. "$SCRIPT_DIR/../../lib/oracle-lib.sh" || { echo "lib/oracle-lib.sh not found" >&2; exit 1; }

SR=""; SINCE=""; UNTIL=""; HOURS="${PACK_HOURS:-24}"; ONLY_SID=""; COMPONENTS=""; DO_AWR=0; DO_THREADS=0; DO_HEAP=0; DO_HANG=0; NO_DIAG=0; NO_TFA=0; DO_SPLIT=0
PACK_OUT="${PACK_OUT:-$(output_path incident-pack)}"; CAP_MB="${PACK_CAP_MB:-100}"; OSW_ARCHIVE="${OSW_ARCHIVE:-}"; EXTRA_FILES="${EXTRA_FILES:-}"; EXTRA_LOGS="${EXTRA_LOGS:-}"; TFA_TIMEOUT="${TFA_TIMEOUT:-1800}"
PACK=""; SINCE_EP=""; UNTIL_EP=""; SINCE_ISO=""; UNTIL_ISO=""; TFA_DONE=0; FACTS=""; NFILES=0; NFAIL=0; FAILED=""

usage() { usage_from_header "$0"; }
parse_opts() {
  while [ $# -gt 0 ]; do case "$1" in
    --since) optchk "$@"; SINCE="$2"; shift 2;; --until) optchk "$@"; UNTIL="$2"; shift 2;; --hours) optchk "$@"; HOURS="$2"; shift 2;; --sid) optchk "$@"; ONLY_SID="$2"; shift 2;; --component) optchk "$@"; COMPONENTS="$COMPONENTS,$2"; shift 2;;
    --awr) DO_AWR=1; shift;; --threads) DO_THREADS=1; shift;; --heap-dump) DO_HEAP=1; shift;; --hang) DO_HANG=1; shift;; --no-diag) NO_DIAG=1; shift;; --no-tfa) NO_TFA=1; shift;; --split) DO_SPLIT=1; shift;;
    --out) optchk "$@"; PACK_OUT="$2"; shift 2;; --cap-mb) optchk "$@"; CAP_MB="$2"; shift 2;; --no-redact) REDACT=0; shift;;
    --dry-run) DRY_RUN=1; shift;; --yes) ASSUME_YES=1; shift;; --verbose) VERBOSE=1; shift;; -h|--help) usage; exit 0;; --*) die "Unknown option: $1";;
    *) [ -z "$SR" ] && SR="$1" || die "unexpected argument $1"; shift;; esac; done
}
want() { [ -z "$COMPONENTS" ] && return 0; case ",$COMPONENTS," in *",$1,"*) return 0;; esac; return 1; }

# ---------------------------------------------------------------------------
# window and file helpers
# ---------------------------------------------------------------------------
set_window() {
  local now; now="$(date +%s)"
  if [ -n "$UNTIL" ]; then UNTIL_EP="$(epoch_of "$UNTIL:00" || epoch_of "$UNTIL")" || die "--until: use YYYY-MM-DD HH:MM"; else UNTIL_EP="$now"; fi
  if [ -n "$SINCE" ]; then SINCE_EP="$(epoch_of "$SINCE:00" || epoch_of "$SINCE")" || die "--since: use YYYY-MM-DD HH:MM"; else SINCE_EP=$((UNTIL_EP - HOURS*3600)); fi
  [ "$SINCE_EP" -lt "$UNTIL_EP" ] || die "window is empty (since >= until)"
  SINCE_ISO="$(iso_of "$SINCE_EP")"; UNTIL_ISO="$(iso_of "$UNTIL_EP")"
}
iso_of() { if [ "$GNU_DATE" = 1 ]; then date -d "@$1" '+%Y-%m-%d %H:%M:%S'; else date -r "$1" '+%Y-%m-%d %H:%M:%S'; fi; }
fact() { FACTS="${FACTS}$1=$2"$'\n'; }
# got <rel> <write-status> [what]: a collector counts a file only when its write succeeded and the file is there; anything else
# is 'could not collect', listed in MANIFEST.md under 'Not collected' and makes the pack INCOMPLETE (exit 1). Before this every
# collector counted what it TRIED to write - a cp that failed on a full disk (the usual reason an incident pack is being made)
# was one of the "N file(s) collected" and the SR went out without it (DeepSeek, 1 Nov 22:20)
got() {
  local rel="$1" st="$2" what="${3:-}"
  if [ "$st" = 0 ] && [ -f "$PACK/$rel" ]; then NFILES=$((NFILES+1)); return 0; fi
  NFAIL=$((NFAIL+1)); FAILED="${FAILED}- $rel${what:+ ($what)}: write status $st$([ -f "$PACK/$rel" ] || echo ', file absent')"$'\n'
  err "could not collect $rel${what:+ ($what)}: write status $st (disk full? $(df -h "$PACK" 2>/dev/null | awk 'NR==2{print $4" free"}'))"; return 1
}
# keep <dest-rel> <file> [redact]: copy a file into the pack, keeping only the last CAP_MB when larger; counts it
keep() {
  local rel="$1" f="$2" red="${3:-0}" d="$PACK/$1"; [ -f "$f" ] && [ -r "$f" ] || { dbg "skip $f (missing/unreadable)"; return 1; }
  local out sz st; out="$d/$(basename "$f")"; sz="$(file_size "$f" || echo 0)"
  [ "$DRY_RUN" = 1 ] && { log "would copy $f ($((sz/1048576)) MB) -> $rel/"; return 0; }
  mkdir -p "$d" || { got "$rel/$(basename "$f")" 1 "mkdir $d"; return 1; }
  if [ "$sz" -gt $((CAP_MB*1048576)) ]; then { printf '### incident-pack: file was %s MB; only the last %s MB are kept ###\n' "$((sz/1048576))" "$CAP_MB"; tail -c $((CAP_MB*1048576)) "$f"; } | { [ "$red" = 1 ] && redact || cat; } >"$out"; st=$?
  elif [ "$red" = 1 ]; then redact <"$f" >"$out"; st=$?
  else cp -p "$f" "$out"; st=$?; fi
  got "$rel/$(basename "$f")" "$st" "$f"
}
# keep_newer <dest-rel> <dir> <glob> [redact] [max files]: files under dir matching glob modified inside the window
keep_newer() {
  local rel="$1" dir="$2" glob="$3" red="${4:-0}" max="${5:-200}" n=0 f; [ -d "$dir" ] || return 0
  while IFS= read -r f; do n=$((n+1)); [ "$n" -gt "$max" ] && { warn "$dir: more than $max matching files, the rest skipped"; break; }; keep "$rel" "$f" "$red"; done < <(find "$dir" -maxdepth 3 -type f -name "$glob" -newer "$PACK/.since" 2>/dev/null | sort)
}
# out <dest-rel/name> <cmd...>: command output into a file of the pack (redacted, timed out)
# the command's own exit status is evidence, not a collection failure (lsnrctl status on a dead listener is exactly what the SR
# wants) - it is appended to the file; a write that failed is; an empty answer is a WARN, since a silent tool is a finding too
out() { local rel="$1"; shift; local f="$PACK/$rel" st rc; [ "$DRY_RUN" = 1 ] && { log "would run: $*"; return 0; }
  mkdir -p "$(dirname "$f")" || { got "$rel" 1 "mkdir"; return 1; }
  { printf '$ %s\n' "$*"; to "$CMD_TIMEOUT" "$@" 2>&1; printf '(exit %s)\n' "$?"; } | redact >"$f"; st=$?
  got "$rel" "$st" "$1" || return 1
  rc="$(tail -n 1 "$f" | sed -n 's/^(exit \([0-9]*\))$/\1/p')"
  [ "$(wc -l <"$f" | tr -d ' ')" -gt 2 ] || warn "$rel: '$*' produced no output (exit ${rc:-?})"; return 0; }
outsh() { local rel="$1"; shift; out "$rel" bash -c "$*"; }
# window_log <dest-rel> <file> <fmt>: the lines of a timestamped log inside the window (fmt alert|listener|wls|iso|syslog)
window_log() {
  local rel="$1" f="$2" fmt="$3"; [ -f "$f" ] && [ -r "$f" ] || return 1; local d="$PACK/$rel"; local o st; o="$d/$(basename "$f").window"
  [ "$DRY_RUN" = 1 ] && { log "would window $f ($fmt)"; return 0; }
  mkdir -p "$d" || { got "$rel/$(basename "$f").window" 1 "mkdir $d"; return 1; }
  tail -c $((CAP_MB*4*1048576)) "$f" | awk -v since="$SINCE_ISO" -v until="$UNTIL_ISO" -v fmt="$fmt" '
    BEGIN{split("JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC",m," "); for(i=1;i<=12;i++) mon[m[i]]=sprintf("%02d",i); p=0}
    function norm(s,   a,h,hh) { return s }
    { ts=""
      if (fmt=="alert"||fmt=="iso") { if (match($0,/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][T ][0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) { ts=substr($0,1,19); sub(/T/," ",ts) } }
      else if (fmt=="listener") { if (match($0,/^[0-9][0-9]-[A-Z][A-Z][A-Z]-[0-9][0-9][0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) { s=substr($0,1,20); ts=substr(s,8,4)"-"mon[substr(s,4,3)]"-"substr(s,1,2)" "substr(s,13,8) } }
      else if (fmt=="wls") { if (match($0,/^####<[A-Z][a-z][a-z] [0-9]+, [0-9][0-9][0-9][0-9],? [0-9]+:[0-9][0-9]:[0-9][0-9]/)) { s=substr($0,6,RLENGTH-5); split(s,a,/[ ,:]+/); mo=mon[toupper(substr(a[1],1,3))]; hh=a[4]+0; rest=substr($0,RLENGTH+1,12); if (rest ~ /PM/ && hh<12) hh+=12; if (rest ~ /AM/ && hh==12) hh=0; ts=sprintf("%s-%s-%02d %02d:%s:%s",a[3],mo,a[2],hh,a[5],a[6]) } }
      else if (fmt=="syslog") { if (match($0,/^[A-Z][a-z][a-z] +[0-9]+ [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) { split(substr($0,1,RLENGTH),a,/ +/); ts=substr(since,1,4)"-"mon[toupper(a[1])]"-"sprintf("%02d",a[2])" "a[3] } }
      if (ts!="") p = (ts>=since && ts<=until)
      if (p) print }' | redact >"$o"; st=$?
  got "$rel/$(basename "$f").window" "$st" "$f" || return 1
  local n; n="$(wc -l <"$o" | tr -d ' ')"; [ "$n" = 0 ] && { printf '(no lines between %s and %s in %s; the file holds %s lines)\n' "$SINCE_ISO" "$UNTIL_ISO" "$f" "$(wc -l <"$f" | tr -d ' ')" >"$o" || got "$rel/$(basename "$f").window" "$?" "rewrite"; }
  log "$(basename "$f"): $n lines in the window"; return 0
}

# ---------------------------------------------------------------------------
# collectors
# ---------------------------------------------------------------------------
collect_diag() {
  [ "$NO_DIAG" = 1 ] && return 0; local d="$SCRIPT_DIR/../../reports/oracle-diag/oracle-diag.sh"; [ -x "$d" ] || { warn "oracle-diag.sh not found next to this script: skipped"; return 0; }
  log "oracle-diag (read-only health report)"; [ "$DRY_RUN" = 1 ] && return 0
  local days=$(( (UNTIL_EP-SINCE_EP)/86400 + 1 ))
  local extra=(); [ -n "$ONLY_SID" ] && extra+=(--sid "$ONLY_SID"); [ "$REDACT" = 0 ] && extra+=(--no-redact)
  to 1800 "$d" --out "$PACK/00_oracle-diag" --days "$days" --no-tar --quiet "${extra[@]}" >>"$LOG_FILE" 2>&1 || warn "oracle-diag exited non-zero (its findings may still be useful; see $LOG_FILE)"
  local r; r="$(find "$PACK/00_oracle-diag" -name REPORT.md 2>/dev/null | head -1)"; [ -n "$r" ] && { log "oracle-diag report: ${r#"$PACK"/}"; NFILES=$((NFILES+1)); grep -E '^# FINDINGS' "$r" | head -1 | sed 's/^# //' | { read -r l; fact DIAG_FINDINGS "$l"; }; } || warn "oracle-diag produced no REPORT.md"
}
tfactl_bin() { command -v tfactl 2>/dev/null || ls /opt/oracle.ahf/bin/tfactl /u01/app/oracle.ahf/bin/tfactl /opt/oracle/tfa/tfa_home/bin/tfactl 2>/dev/null | head -1; }
collect_tfa() {
  [ "$NO_TFA" = 1 ] && return 0; local t; t="$(tfactl_bin)"; [ -n "$t" ] || return 0
  log "tfactl diagcollect -from '$SINCE_ISO' -to '$UNTIL_ISO' (AHF/TFA present: it gathers DB, GI, OS and OSWatcher for the window)"; [ "$DRY_RUN" = 1 ] && return 0
  mkdir -p "$PACK/tfa"; to "$TFA_TIMEOUT" "$t" diagcollect -all -from "$SINCE_ISO" -to "$UNTIL_ISO" -silent -nocopy -z "incident_${SR}" >"$PACK/tfa/diagcollect.out" 2>&1 || { warn "tfactl diagcollect failed or timed out (see tfa/diagcollect.out): collecting the logs directly"; return 0; }
  local z; while IFS= read -r z; do [ -f "$z" ] && { log "tfa: $(basename "$z") ($(du -h "$z" | cut -f1))"; [ "$(file_size "$z")" -gt $((CAP_MB*20*1048576)) ] && warn "tfa collection is large; it is referenced, not copied: $z" || { cp -p "$z" "$PACK/tfa/"; NFILES=$((NFILES+1)); }; }; done < <(grep -oE '/[^ ]+\.zip' "$PACK/tfa/diagcollect.out" | sort -u)
  TFA_DONE=1; fact TFA_COLLECTION "$(grep -oE '/[^ ]+\.zip' "$PACK/tfa/diagcollect.out" | sort -u | tr '\n' ' ')"
}
diag_trace_dir() { sql_val "$1" "(select value from v\$diag_info where name='Diag Trace')" 2>/dev/null; }
adr_home_of() { local b; b="$(sql_val "$1" "(select value from v\$diag_info where name='ADR Home')" 2>/dev/null)"; [ -n "$b" ] && printf '%s' "$b" || ls -d "${ORACLE_BASE:-/u01/app/oracle}"/diag/rdbms/*/"$1" 2>/dev/null | head -1; }
collect_db() {
  local sid="$1" home d="db/$1"; home="$(db_home_of "$sid")"; log "database $sid ($home)"
  fact "DB_HOME_$sid" "$home"
  if sql_ok "$sid"; then
    local v; v="$(sql_val "$sid" "(select version_full from v\$instance)" 2>/dev/null || sql_val "$sid" "(select version from v\$instance)")"; fact "DB_VERSION_$sid" "$v"
    fact "DB_NAME_$sid" "$(sql_val "$sid" "(select name||' role='||database_role||' cdb='||cdb||' platform='||platform_name from v\$database)" 2>/dev/null)"
    fact "DB_PATCHES_$sid" "$(sql_lines "$sid" "select listagg(patch_id||':'||substr(description,1,60),' | ') within group (order by action_time) from (select * from (select patch_id, description, action_time from dba_registry_sqlpatch where status='SUCCESS' order by action_time desc) where rownum<=5);" 2>/dev/null | head -1)"
    sqlf "$sid" instance "select instance_name, host_name, version_full, status, database_status, startup_time, logins, archiver, instance_role from v\$instance;
select name, db_unique_name, database_role, open_mode, log_mode, flashback_on, protection_mode, cdb, platform_name, created from v\$database;
select banner_full from v\$version;
select con_id, name, open_mode, restricted, total_size/1048576/1024 gb from v\$containers order by con_id;"
    sqlf "$sid" parameters "select name, value from v\$parameter where isdefault='FALSE' order by name;
select name, value from v\$spparameter where isspecified='TRUE' and sid<>'*';"
    sqlf "$sid" registry "select comp_id, comp_name, version_full, status, modified from dba_registry order by comp_id;
select patch_id, patch_type, action, status, action_time, substr(description,1,80) description from dba_registry_sqlpatch order by action_time;
select owner, count(*) invalid from dba_objects where status<>'VALID' group by owner order by 2 desc;"
    sqlf "$sid" sessions "select status, type, count(*) from v\$session group by status, type;
select username, machine, program, status, count(*) from v\$session where type='USER' group by username, machine, program, status order by 5 desc fetch first 40 rows only;
select event, count(*), round(avg(seconds_in_wait)) avg_wait from v\$session where wait_class<>'Idle' group by event order by 2 desc fetch first 30 rows only;
select resource_name, current_utilization, max_utilization, limit_value from v\$resource_limit where resource_name in ('processes','sessions','enqueue_locks','transactions','parallel_max_servers');
select sid, serial#, username, sql_id, event, seconds_in_wait, blocking_session, final_blocking_session, last_call_et, program from v\$session where blocking_session is not null or sid in (select blocking_session from v\$session where blocking_session is not null) order by last_call_et desc;"
    sqlf "$sid" locks "select type, lmode, request, count(*) from v\$lock where type not in ('AE','MR','RT','TS','CF','RS','XR','PW','SQ','PS') group by type, lmode, request order by 4 desc;
select l.sid, s.username, l.type, l.lmode, l.request, l.ctime, s.sql_id, s.event from v\$lock l join v\$session s on s.sid=l.sid where l.request>0 or l.block>0 order by l.ctime desc fetch first 50 rows only;
select sid, serial#, opname, target, round(sofar/nullif(totalwork,0)*100) pct, time_remaining, sql_id, start_time from v\$session_longops where time_remaining>0 order by start_time;"
    sqlf "$sid" jobs "select owner, job_name, session_id, running_instance, elapsed_time, cpu_used from dba_scheduler_running_jobs;
select owner, job_name, status, actual_start_date, run_duration, error# , substr(additional_info,1,120) from dba_scheduler_job_run_details where actual_start_date > timestamp '$SINCE_ISO' and status<>'SUCCEEDED' order by actual_start_date;
select job, what, this_date, failures, broken from dba_jobs where failures>0 or this_date is not null;"
    sqlf "$sid" storage "select tablespace_name, round(used_percent) pct, round(tablespace_size*8/1024) size_mb_blocks8k, round(used_space*8/1024) used_mb_blocks8k from dba_tablespace_usage_metrics order by 2 desc;
select name, round(space_limit/1073741824) limit_gb, round(space_used/1073741824) used_gb, round(space_reclaimable/1073741824) reclaimable_gb, number_of_files from v\$recovery_file_dest;
select dest_id, status, error from v\$archive_dest_status where status not in ('INACTIVE','VALID');
select group#, thread#, sequence#, status, archived, round(bytes/1048576) mb from v\$log order by thread#, group#;"
    sqlf "$sid" errors_window "select originating_timestamp, message_text from v\$diag_alert_ext where originating_timestamp > timestamp '$SINCE_ISO' and originating_timestamp <= timestamp '$UNTIL_ISO' and (message_text like '%ORA-%' or message_text like '%TNS-%' or message_level<=2) order by originating_timestamp fetch first 500 rows only;"
    sqlf "$sid" incidents "select problem_id, problem_key, first_incident, last_incident, incident_count, service_name from v\$diag_problem order by last_incident desc fetch first 20 rows only;
select incident_id, problem_key, create_time, error_facility||'-'||error_number err, error_arg1, error_arg2, error_arg3, incident_file from v\$diag_incident where create_time > timestamp '$SINCE_ISO' order by create_time desc fetch first 50 rows only;"
    sqlf "$sid" dataguard "select * from v\$dataguard_stats;
select process, status, thread#, sequence#, block#, delay_mins from v\$managed_standby where process not in ('ARCH','DGRD','LGWR');"
    is_rac && sqlf "$sid" rac "select inst_id, instance_name, host_name, status, startup_time from gv\$instance;
select inst_id, event, count(*) from gv\$session where wait_class<>'Idle' and event like 'gc%' group by inst_id, event order by 3 desc fetch first 20 rows only;"
    if [ "$DRY_RUN" = 0 ]; then mkdir -p "$PACK/$d/pfile"; sql_run "$sid" "create pfile='$PACK/$d/pfile/init_${sid}_from_spfile.ora' from spfile;" >>"$LOG_FILE" 2>&1 && NFILES=$((NFILES+1)) || sqlf "$sid" pfile/spparameter "select sid, name, value from v\$spparameter where isspecified='TRUE' order by name, sid;"; fi
    [ "$DO_AWR" = 1 ] && collect_awr "$sid"
    [ "$DO_HANG" = 1 ] && collect_hang "$sid"
    else warn "$sid: sqlplus / as sysdba does not answer (instance down or SQL_CONNECT wrong): file-based collection only"; fact "DB_SQL_$sid" "unavailable"; fi
  # opatch
  [ -x "$home/OPatch/opatch" ] && { out "$d/opatch/lsinventory.txt" "$home/OPatch/opatch" lsinventory -oh "$home"; out "$d/opatch/lspatches.txt" "$home/OPatch/opatch" lspatches -oh "$home"; fact "OPATCH_$sid" "$(grep -vE '^OPatch|^\$|^$|succeeded' "$PACK/$d/opatch/lspatches.txt" 2>/dev/null | head -5 | cut -c1-70 | tr '\n' '|')"; }
  [ "$TFA_DONE" = 1 ] && { log "$sid: alert/trace windows left to the tfa collection"; collect_adr "$sid"; return 0; }
  # alert log window + the traces it names
  local alert tdir; tdir="$(diag_trace_dir "$sid")"; alert="$tdir/alert_${sid}.log"
  [ -f "$alert" ] || alert="$(find "${ORACLE_BASE:-/u01/app/oracle}/diag/rdbms" /u01/app/oracle/diag/rdbms /opt/oracle/diag/rdbms -name "alert_${sid}.log" 2>/dev/null | head -1)"
  if [ -f "$alert" ]; then
    window_log "$d/alert" "$alert" alert; keep "$d/alert" "$alert"
    local n=0 t; while IFS= read -r t; do n=$((n+1)); [ "$n" -gt 50 ] && { warn "$sid: more than 50 trace files named in the window; the rest are in the ADR package"; break; }; keep "$d/traces" "$t" 1; done < <(grep -aoE 'Errors in file [^:]+\.trc' "$PACK/$d/alert/alert_${sid}.log.window" 2>/dev/null | sed 's/Errors in file //' | sort -u)
    [ "$n" -gt 0 ] && log "$sid: $n trace file(s) named by the alert log"
    [ -d "$tdir" ] && keep_newer "$d/traces_recent" "$tdir" "*.trc" 1 30
    [ -f "$tdir/../log/log.xml" ] && window_log "$d/alert" "$tdir/../log/log.xml" alert
  else warn "$sid: alert log not found"; fi
  collect_adr "$sid"
  fact "ERRORS_$sid" "$(cat "$PACK/$d/sql/errors_window.txt" "$PACK/$d/alert/alert_${sid}.log.window" 2>/dev/null | grep -oE '(ORA|TNS)-[0-9]+' | sort | uniq -c | sort -rn | head -8 | awk '{printf "%s x%s ",$2,$1}')"
}
# sqlf <sid> <name> <sql>: SQL output into db/<sid>/sql/<name>.txt
sqlf() { local sid="$1" name="$2" q="$3" f="$PACK/db/$1/sql/$2.txt" st; [ "$DRY_RUN" = 1 ] && return 0; mkdir -p "$(dirname "$f")" || { got "db/$1/sql/$2.txt" 1 mkdir; return 1; }
  { printf -- '-- %s  (%s)\n%s\n\n' "$name" "$(ts)" "$q"; sql_run "$sid" "$q"; } 2>&1 | redact >"$f"; st=$?; got "db/$1/sql/$2.txt" "$st" "$sid $name"; }
collect_adr() {
  local sid="$1" home d="db/$1/adr"; home="$(db_home_of "$sid")"; [ -x "$home/bin/adrci" ] || { warn "$sid: no adrci in $home"; return 0; }
  local ah; ah="$(adr_home_of "$sid")"; [ -n "$ah" ] || { warn "$sid: ADR home not found"; return 0; }
  local base="${ah%%/diag/*}"; local rel="${ah#"$base"/}"
  mkdir -p "$PACK/$d"; local adrci=(env ORACLE_HOME="$home" ORACLE_SID="$sid" ORACLE_BASE="$base" "$home/bin/adrci")
  out "$d/problems.txt" "${adrci[@]}" exec="set base $base; set home $rel; show problem -last 20; show incident -p \"create_time > timestamp '$SINCE_ISO'\" -last 50"
  [ "$DRY_RUN" = 1 ] && return 0
  local ids; ids="$(awk '/^PROBLEM_ID/{h=1;next} /^INCIDENT_ID|^$/{h=0} h&&/^[0-9]+ +[A-Za-z]/{print $1}' "$PACK/$d/problems.txt" | sort -u | head -5)"
  local since_inc; since_inc="$(awk -v s="$SINCE_ISO" '/^INCIDENT_ID/{h=1;next} h&&/^[0-9]+ /{print}' "$PACK/$d/problems.txt" | grep -c .)"
  [ -z "$ids" ] && { log "$sid: no ADR problems; nothing to ips pack"; return 0; }
  local id n=0; for id in $ids; do
    local last; last="$(awk -v id="$id" '/^PROBLEM_ID/{h=1;next} h&&$1==id{print $NF}' "$PACK/$d/problems.txt" | head -1)"
    log "$sid: adrci ips pack problem $id (last incident $last) -> $d/"
    "${adrci[@]}" exec="set base $base; set home $rel; ips pack problem $id in $PACK/$d" >>"$PACK/$d/ips_pack_$id.out" 2>&1 && n=$((n+1)) || warn "$sid: ips pack problem $id failed (see $d/ips_pack_$id.out)"
  done
  NFILES=$((NFILES+$(ls "$PACK/$d"/*.zip 2>/dev/null | wc -l | tr -d ' '))); log "$sid: $n ADR package(s), $since_inc incident(s) in the window"; fact "ADR_PACKAGES_$sid" "$n (problems: $(printf '%s' "$ids" | tr '\n' ' '))"
}
collect_awr() {
  local sid="$1" d="db/$1/awr"; mkdir -p "$PACK/$d"; log "$sid: AWR/ASH for $SINCE_ISO .. $UNTIL_ISO"; [ "$DRY_RUN" = 1 ] && return 0
  local snaps; snaps="$(sql_lines "$sid" "select min(snap_id)||' '||max(snap_id)||' '||dbid||' '||instance_number from dba_hist_snapshot where end_interval_time >= timestamp '$SINCE_ISO' - interval '1' hour and begin_interval_time <= timestamp '$UNTIL_ISO' and dbid=(select dbid from v\$database) and instance_number=(select instance_number from v\$instance) group by dbid, instance_number;" 2>/dev/null | head -1)"
  local b e dbid inst; read -r b e dbid inst <<<"$snaps"
  if [ -n "$b" ] && [ "$b" != "$e" ]; then
    sql_run "$sid" "set pagesize 0 linesize 1500 long 20000000 longchunksize 20000000 trimspool on\nselect output from table(dbms_workload_repository.awr_report_text($dbid,$inst,$b,$e));" >"$PACK/$d/awrrpt_${sid}_${b}_${e}.txt" 2>&1; got "$d/awrrpt_${sid}_${b}_${e}.txt" "$?" "$sid AWR"
    log "$sid: AWR snapshots $b..$e"
  else warn "$sid: fewer than two AWR snapshots in the window (AWR interval / retention)"; fi
  sql_run "$sid" "set pagesize 0 linesize 1500 long 20000000 longchunksize 20000000 trimspool on\nselect output from table(dbms_workload_repository.ash_report_text((select dbid from v\$database),(select instance_number from v\$instance),to_date('$SINCE_ISO','YYYY-MM-DD HH24:MI:SS'),to_date('$UNTIL_ISO','YYYY-MM-DD HH24:MI:SS')));" >"$PACK/$d/ashrpt_${sid}.txt" 2>&1; got "$d/ashrpt_${sid}.txt" "$?" "$sid ASH"
}
collect_hang() {
  local sid="$1" d="db/$1/hang"; mkdir -p "$PACK/$d"
  confirm "$sid: oradebug hanganalyze 3 + systemstate 258 (can take minutes and write a large trace)?" || { warn "$sid: hang dumps skipped"; return 0; }
  [ "$DRY_RUN" = 1 ] && return 0
  local g=""; is_rac && g="-g all"
  sql_run "$sid" "oradebug setmypid\noradebug unlimit\noradebug $g hanganalyze 3\noradebug tracefile_name\nhost sleep 30\noradebug $g hanganalyze 3\noradebug $g dump systemstate 258\noradebug tracefile_name" >"$PACK/$d/oradebug.out" 2>&1
  local t; while IFS= read -r t; do keep "$d" "$t" 1; done < <(grep -aoE '/[^ ]+\.trc' "$PACK/$d/oradebug.out" | sort -u)
  [ "$(is_rac && echo 1)" = 1 ] && log "$sid: RAC - the other instances' dumps are in their own trace dirs (ADR packages cover them)"
}
collect_listener() {
  local h n lg; while read -r h n; do
    [ -n "$n" ] || continue; fact "LISTENER_$n" "$h"
    lg="$(find "${ORACLE_BASE:-/u01/app/oracle}/diag/tnslsnr" /u01/app/oracle/diag/tnslsnr /opt/oracle/diag/tnslsnr -path "*/$(printf '%s' "$n" | tr 'A-Z' 'a-z')/trace/*.log" 2>/dev/null | head -1)"
    [ -n "$lg" ] && { [ "$TFA_DONE" = 1 ] || window_log "db/listener" "$lg" listener; } || warn "listener $n: trace log not found"
    out "db/listener/status_$n.txt" env ORACLE_HOME="$h" "$h/bin/lsnrctl" status "$n"
    keep "db/listener/admin" "$h/network/admin/listener.ora" 1; keep "db/listener/admin" "$h/network/admin/sqlnet.ora" 1; keep "db/listener/admin" "$h/network/admin/tnsnames.ora" 1
  done < <(listener_homes)
}
collect_wls() {
  local h d s pid dn
  for h in $(wls_homes); do fact WLS_VERSION "$(wls_version "$h") ($h)"; fact WLS_JAVA "$(wls_java_home "$h") $(java_version_of "$(wls_java_home "$h")" 2>/dev/null)"
    [ -x "$h/OPatch/opatch" ] && out "wls/opatch_lspatches.txt" "$h/OPatch/opatch" lspatches -oh "$h"
    for d in $(wls_domains "$h"); do dn="$(basename "$d")"; log "WebLogic domain $dn"
      keep "wls/$dn/config" "$d/config/config.xml" 1; local f; for f in "$d"/config/jdbc/*.xml "$d"/config/jms/*.xml "$d"/config/security/*.xml; do keep "wls/$dn/config/$(basename "$(dirname "$f")")" "$f" 1; done
      keep "wls/$dn/config" "$d/bin/setDomainEnv.sh" 1; keep "wls/$dn/config" "$d/bin/setUserOverrides.sh" 1; keep "wls/$dn/nodemanager" "$d/nodemanager/nodemanager.properties" 1
      keep_newer "wls/$dn/nodemanager" "$d/nodemanager" "*.log" 1 5
      while read -r s _; do
        local sd="$d/servers/$s/logs"; [ -d "$sd" ] || continue
        [ -f "$sd/$s.log" ] && window_log "wls/$dn/$s" "$sd/$s.log" wls; [ -f "$sd/$s.out" ] && keep "wls/$dn/$s" "$sd/$s.out" 1
        keep_newer "wls/$dn/$s/rotated" "$sd" "$s.log0*" 1 3; [ -f "$sd/access.log" ] && keep "wls/$dn/$s" "$sd/access.log"; keep_newer "wls/$dn/$s" "$sd" "*.dmp" 0 3; keep_newer "wls/$dn/$s" "$sd" "*diagnostic*.log" 1 3
        [ -f "$d/servers/$s/data/nodemanager/$s.out" ] && keep "wls/$dn/$s" "$d/servers/$s/data/nodemanager/$s.out" 1
      done < <(wls_servers "$d")
      while read -r s pid; do jvm_dumps "wls/$dn/$s/jvm" "$s" "$pid" "$(wls_java_home "$h")"; done < <(wls_running "$d")
      outsh "wls/$dn/running.txt" "ps -eo pid,etime,pcpu,rss,args | grep -E 'weblogic\.(Server|NodeManager)' | grep -v grep | cut -c1-400"
    done
  done
}
# jvm_dumps <rel> <name> <pid> <java_home>: thread dumps x3 / histogram / heap dump with jcmd when asked
jvm_dumps() {
  local rel="$1" name="$2" pid="$3" jh="$4" jcmd="$4/bin/jcmd"; [ -x "$jcmd" ] || jcmd="$(dirname "$(readlink -f "/proc/$pid/exe" 2>/dev/null || echo /nonexistent)")/jcmd"; [ -x "$jcmd" ] || jcmd="$(command -v jcmd 2>/dev/null)"
  [ -x "$jcmd" ] || { [ "$DO_THREADS" = 1 ] && warn "$name: no jcmd for pid $pid"; return 0; }
  out "$rel/vm_flags.txt" "$jcmd" "$pid" VM.flags; out "$rel/vm_uptime.txt" "$jcmd" "$pid" VM.uptime; out "$rel/gc_heap_info.txt" "$jcmd" "$pid" GC.heap_info
  if [ "$DO_THREADS" = 1 ]; then local i; for i in 1 2 3; do log "$name (pid $pid): thread dump $i/3"; out "$rel/threads_$i.txt" "$jcmd" "$pid" Thread.print -l; [ "$i" -lt 3 ] && [ "$DRY_RUN" = 0 ] && sleep 10; done; out "$rel/class_histogram.txt" "$jcmd" "$pid" GC.class_histogram; fi
  if [ "$DO_HEAP" = 1 ]; then confirm "$name (pid $pid): jcmd GC.heap_dump (the JVM pauses; the file can be many GB)?" && { mkdir -p "$PACK/$rel"; [ "$DRY_RUN" = 1 ] || to 600 "$jcmd" "$pid" GC.heap_dump "$PACK/$rel/heap_$name.hprof" >>"$LOG_FILE" 2>&1 && NFILES=$((NFILES+1)); }; fi
}
collect_ords() {
  ords_detect >/dev/null 2>&1 || return 0; log "ORDS ${ORDS_VER:-?} ($ORDS_HOME, config ${ORDS_CONFIG:-?})"
  # an empty ORDS_PID is 'no process' only if the list was read; ORDS_PS_UNREADABLE (lib 487f88f) makes it unknown
  local pidtxt="${ORDS_PID:-none}"; [ -z "${ORDS_PID:-}" ] && [ "${ORDS_PS_UNREADABLE:-0}" = 1 ] && pidtxt=unknown
  fact ORDS_VERSION "${ORDS_VER:-?} home=$ORDS_HOME config=${ORDS_CONFIG:-?} pid=$pidtxt"
  [ "${ORDS_PS_UNREADABLE:-0}" = 1 ] && warn "cannot read the process list (ps failed, $PROC_DIR unreadable) - ORDS process and JVM details NOT collected"
  local f; if [ -d "${ORDS_CONFIG:-}" ]; then while IFS= read -r f; do keep "ords/config/$(dirname "${f#"$ORDS_CONFIG"/}")" "$f" 1; done < <(find "$ORDS_CONFIG" -type f \( -name '*.xml' -o -name '*.properties' \) 2>/dev/null | grep -v wallet | head -60); fi
  local ld; for ld in "${ORDS_CONFIG:-/nonexistent}/../logs" "${ORDS_CONFIG:-/nonexistent}/logs" "$ORDS_HOME/logs" /var/log/ords "${ORDS_LOG_DIR:-/nonexistent}"; do [ -d "$ld" ] && keep_newer "ords/logs" "$ld" "*.log*" 1 20; done
  local svc; svc="$(ords_service)"; [ -n "$svc" ] && { outsh "ords/journal.txt" "journalctl -u '$svc' --since '$SINCE_ISO' --until '$UNTIL_ISO' --no-pager 2>&1 | tail -n 20000"; outsh "ords/service_status.txt" "systemctl status '$svc' --no-pager -l 2>&1 | head -40"; }
  [ -n "${ORDS_PID:-}" ] && { outsh "ords/process.txt" "ps -o pid,etime,pcpu,rss,args -p $ORDS_PID | cut -c1-400; echo; ls -l /proc/$ORDS_PID/exe 2>/dev/null"; local jh; jh="$(dirname "$(dirname "$(readlink -f "/proc/$ORDS_PID/exe" 2>/dev/null || echo /nonexistent/x/y)")")"; jvm_dumps "ords/jvm" ords "$ORDS_PID" "$jh"; }
  [ -n "${ORDS_URL:-}" ] && outsh "ords/http.txt" "for u in '$ORDS_URL' '${ORDS_URL%/}/_/landing' ; do printf '%s -> ' \"\$u\"; curl -sk -o /dev/null -m 10 -w '%{http_code} %{time_total}s\n' \"\$u\"; done"
}
apex_in() { # <sid>  (PDB_SET exported by caller)
  local sid="$1" c="${PDB_SET:+$(printf '%s' "$PDB_SET" | sed 's/.*container=//; s/;//')}"; c="${c:-CDB}"
  sql_ok "$sid" || return 0; sql_val "$sid" "(select count(*) from dba_registry where comp_id='APEX')" 2>/dev/null | grep -q '^[1-9]' || return 0
  log "APEX in $sid/$c"; fact "APEX_${sid}_$c" "$(sql_val "$sid" "(select version_no||' '||status from dba_registry where comp_id='APEX')" 2>/dev/null)"
  sqlf "$sid" "apex_${c}" "select version_no, status, modified from dba_registry where comp_id='APEX';
select name, value from apex_instance_parameters where name not like '%PASSWORD%' and name not like '%SECRET%' and name not like '%KEY%' order by name;
select workspace, application_id, application_name, page_id, view_date, apex_user, substr(error_message,1,200) error_message from apex_workspace_activity_log where error_message is not null and view_date > timestamp '$SINCE_ISO' and view_date <= timestamp '$UNTIL_ISO' order by view_date desc fetch first 200 rows only;
select workspace, application_id, substr(error_message,1,120) err, count(*) from apex_workspace_activity_log where error_message is not null and view_date > timestamp '$SINCE_ISO' group by workspace, application_id, substr(error_message,1,120) order by 4 desc fetch first 30 rows only;
select username, account_status, expiry_date from dba_users where username in ('APEX_PUBLIC_USER','ORDS_PUBLIC_USER','ORDS_METADATA','APEX_LISTENER','APEX_REST_PUBLIC_USER');
select message_timestamp, session_id, substr(message,1,200) from apex_debug_messages where message_timestamp > timestamp '$SINCE_ISO' and message_level<=2 order by message_timestamp desc fetch first 100 rows only;"
}
collect_apex() { local sid p; for sid in $(db_sids); do if db_is_cdb "$sid"; then for p in $(db_pdbs "$sid"); do with_pdb "$p" apex_in "$sid"; done; else apex_in "$sid"; fi; done; }
collect_gg() {
  ogg_detect >/dev/null 2>&1 || [ -n "${GG_DEPLOY_DIRS:-}" ] || return 0; log "GoldenGate (${OGG_HOME:-MA only})"
  if [ -x "${OGG_HOME:-/nonexistent}/ggsci" ]; then
    fact GG_HOME "$OGG_HOME"; mkdir -p "$PACK/gg"; [ "$DRY_RUN" = 1 ] || { { ggsci "info all\ninfo *, detail\nsend * status\nview ggsevt" 2>&1 | tail -n 3000; } | redact >"$PACK/gg/ggsci_info.txt"; got gg/ggsci_info.txt "$?" ggsci; }
    [ -f "$OGG_HOME/ggserr.log" ] && window_log "gg" "$OGG_HOME/ggserr.log" iso; keep_newer "gg/dirrpt" "$OGG_HOME/dirrpt" "*.rpt" 1 30; keep_newer "gg/dirrpt" "$OGG_HOME/dirrpt" "*.dsc" 1 10
    local f; for f in "$OGG_HOME"/dirprm/*.prm "$OGG_HOME"/GLOBALS; do keep "gg/dirprm" "$f" 1; done
    outsh "gg/dirdat_sizes.txt" "du -sh '$OGG_HOME'/dirdat* 2>/dev/null; ls -lt '$OGG_HOME'/dirdat 2>/dev/null | head -20"
  fi
  local dd; for dd in ${GG_DEPLOY_DIRS//,/ } /u01/app/oracle/gg_deployments /u01/app/ogg/deployments; do [ -d "$dd" ] || continue; keep_newer "gg/ma" "$dd" "*.log" 1 40; done
}
collect_exa() {
  { [ -d /opt/oracle.cellos ] || have dbmcli || have cellcli; } || return 0; log "Exadata"
  outsh "exadata/image.txt" "imageinfo 2>&1; echo; imagehistory 2>&1 | tail -10"
  have dbmcli && outsh "exadata/dbmcli_alerts.txt" "dbmcli -e \"list alerthistory where beginTime > '$(date -d "@$SINCE_EP" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date -r "$SINCE_EP" '+%Y-%m-%dT%H:%M:%S%z')' detail\" 2>&1 | head -500; echo; dbmcli -e list dbserver detail 2>&1"
  have cellcli && outsh "exadata/cellcli_alerts.txt" "cellcli -e list alerthistory detail 2>&1 | tail -500; echo; cellcli -e list cell detail 2>&1"
  [ -f /etc/oracle/cell/network-config/cellip.ora ] && keep exadata /etc/oracle/cell/network-config/cellip.ora
  have dcli && [ -r ~/cell_group ] && outsh "exadata/cells_alerts.txt" "dcli -g ~/cell_group -l celladmin \"cellcli -e list alerthistory where beginTime > '$(date -d "@$SINCE_EP" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date -r "$SINCE_EP" '+%Y-%m-%dT%H:%M:%S%z')'\" 2>&1 | head -300"
  fact EXADATA "$(head -3 "$PACK/exadata/image.txt" 2>/dev/null | grep -i 'image version' | head -1)"
}
collect_host() {
  log "host"; fact OS "$(sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release 2>/dev/null | head -1 || uname -sr) kernel $(uname -r)"; fact UPTIME "$(uptime 2>/dev/null | sed 's/^ *//')"
  outsh "host/system.txt" "uname -a; echo; cat /etc/os-release 2>/dev/null; echo; uptime; echo; lscpu 2>/dev/null | head -25; echo; free -m 2>/dev/null || vm_stat; echo; grep -iE 'HugePages|Memfree|SwapTotal|SwapFree|Committed' /proc/meminfo 2>/dev/null; echo; cat /proc/sys/kernel/shmmax /proc/sys/kernel/shmall /proc/sys/fs/file-max /proc/sys/fs/aio-max-nr 2>/dev/null"
  outsh "host/limits.txt" "ulimit -a; echo; cat /etc/security/limits.conf /etc/security/limits.d/* 2>/dev/null | grep -vE '^#|^$'"
  outsh "host/disk.txt" "df -hP; echo; df -iP 2>/dev/null; echo; mount | grep -E 'ora|u0|nfs|acfs' "
  outsh "host/ps.txt" "ps -eo pid,ppid,user,etime,pcpu,pmem,rss,stat,args --sort=-pcpu 2>/dev/null | head -100 || ps aux | head -100"
  outsh "host/net.txt" "ss -s 2>/dev/null; echo; ss -tanp 2>/dev/null | awk '{print \$1}' | sort | uniq -c; echo; ss -ltnp 2>/dev/null | cut -c1-200 || netstat -an | grep LISTEN; echo; ip -brief addr 2>/dev/null || ifconfig | grep -E 'inet |^[a-z]'"
  outsh "host/sysctl.txt" "sysctl -a 2>/dev/null | grep -E '^(kernel\.(shm|sem|msg|panic|pid_max|threads)|fs\.(file|aio)|vm\.(swappiness|nr_hugepages|dirty|min_free|overcommit)|net\.(core\.(rmem|wmem|somaxconn)|ipv4\.(ip_local_port_range|tcp_(keepalive|fin|tw|syn))))'"
  outsh "host/packages.txt" "rpm -qa 2>/dev/null | sort | grep -iE 'oracle|kernel|glibc|libaio|ksplice|uptrack|compat|java|openssl' ; echo; rpm -qa --last 2>/dev/null | head -40; echo; yum history list 2>/dev/null | head -20"
  outsh "host/dmesg.txt" "dmesg -T 2>/dev/null | tail -n 3000 || $SUDO dmesg -T 2>/dev/null | tail -n 3000 || dmesg 2>/dev/null | tail -n 3000"
  outsh "host/journal.txt" "$SUDO journalctl --since '$SINCE_ISO' --until '$UNTIL_ISO' --no-pager -p warning 2>&1 | tail -n 20000"
  outsh "host/oom_and_errors.txt" "{ $SUDO journalctl --since '$SINCE_ISO' --no-pager 2>/dev/null; cat /var/log/messages 2>/dev/null; } | grep -iE 'oom|out of memory|killed process|segfault|I/O error|nfs: server|link (down|up)|hung task|soft lockup|multipath|dm-.*fail|ECC|Machine check' | tail -n 500"
  [ -r /var/log/messages ] && window_log host /var/log/messages syslog || { $SUDO test -r /var/log/messages 2>/dev/null && { [ "$DRY_RUN" = 1 ] || { $SUDO cat /var/log/messages | awk -v s="$(date -d "@$SINCE_EP" '+%b %e' 2>/dev/null || date -r "$SINCE_EP" '+%b %e')" 'index($0,s)==1{p=1} p' | redact >"$PACK/host/messages.window"; NFILES=$((NFILES+1)); }; }; }
  # sar for each day in the window
  local day ep=$SINCE_EP; mkdir -p "$PACK/host/sar"; while [ "$ep" -le "$UNTIL_EP" ]; do day="$(if [ "$GNU_DATE" = 1 ]; then date -d "@$ep" +%d; else date -r "$ep" +%d; fi)"; local sf; for sf in "/var/log/sa/sa$day" "/var/log/sysstat/sa$day"; do [ -f "$sf" ] && outsh "host/sar/sar_$day.txt" "sar -u -r -b -q -W -f '$sf' 2>&1 | head -2000; echo; sar -d -p -f '$sf' 2>&1 | head -1500; echo; sar -n DEV -f '$sf' 2>&1 | head -800"; done; ep=$((ep+86400)); done
  # OSWatcher archive for the window
  local osw="$OSW_ARCHIVE"; [ -z "$osw" ] && osw="$(ls -d /u01/app/oracle.ahf/data/*/oswbb/archive /opt/oracle.ahf/data/*/oswbb/archive /u01/app/grid/oracle.ahf/data/*/oswbb/archive /opt/oracle.oswatcher/osw/archive /u01/app/oracle/oswbb/archive /opt/oswbb/archive 2>/dev/null | head -1)"
  if [ -n "$osw" ] && [ -d "$osw" ] && [ "$TFA_DONE" = 0 ]; then log "OSWatcher archive $osw"; local sub; for sub in oswvmstat oswmeminfo oswtop oswiostat oswmpstat oswnetstat oswps oswslabinfo oswprvtnet; do keep_newer "host/oswatcher/$sub" "$osw/$sub" "*" 0 60; done
  elif [ -z "$osw" ]; then warn "no OSWatcher archive found (OSW_ARCHIVE=) - MOS will usually ask for it"; fi
  outsh "host/oracle_env.txt" "cat /etc/oratab 2>/dev/null | grep -v '^#'; echo; id; echo; env | grep -E '^(ORACLE|TNS|LD_LIBRARY|JAVA|PATH|NLS)' | redact"
  local f; for f in ${EXTRA_FILES//,/ }; do if [ -d "$f" ]; then keep_newer "extra/$(basename "$f")" "$f" "*" 1 100; else keep extra "$f" 1; fi; done
  local spec; for spec in ${EXTRA_LOGS//,/ }; do window_log extra "${spec%%=*}" "${spec#*=}"; done
}
db_sids() { if [ -n "$ONLY_SID" ]; then echo "$ONLY_SID"; else db_instances; fi; }

# ---------------------------------------------------------------------------
write_manifest() {
  local m="$PACK/MANIFEST.md"
  { printf '# Incident pack %s - %s\n\n' "$SR" "$HOST"
    printf -- '- generated: `%s` by %s %s (lib %s) as `%s`\n- window: `%s` .. `%s`\n- components: %s\n- redaction: %s\n- files: %s, size: %s\n\n' "$(ts)" "$TOOL" "$VERSION" "$ORACLE_LIB_VERSION" "$(id -un)" "$SINCE_ISO" "$UNTIL_ISO" "${COMPONENTS:-all detected}" "$([ "$REDACT" = 1 ] && echo 'passwords redacted in copied config/logs' || echo NONE)" "$(find "$PACK" -type f | wc -l | tr -d ' ')" "$(du -sh "$PACK" | cut -f1)"
    printf '## Facts (FACTS.txt)\n\n```\n'; printf '%s' "$FACTS"; printf '```\n\n'
    printf '## Layout\n\n- `00_oracle-diag/` health report with FINDINGS (start here)\n- `db/<sid>/` sql snapshots, alert window + full alert log, traces named by it, ADR ips packages, pfile, opatch%s%s\n- `db/listener/` listener log window, status, *.ora\n- `wls/<domain>/` config (redacted), per-server log windows, .out, JVM facts%s\n- `ords/` config (redacted), logs, journal, JVM facts\n- `gg/` ggsci info, ggserr window, reports, params\n- `exadata/` image, alert history\n- `host/` system, limits, disk, ps, net, sysctl, packages, dmesg, journal, messages window, sar, OSWatcher window\n- `tfa/` tfactl diagcollect output when AHF/TFA is installed\n- `%s.log` what this script did; `FACTS.txt` for sr-draft\n\n' "$([ "$DO_AWR" = 1 ] && echo ', AWR/ASH')" "$([ "$DO_HANG" = 1 ] && echo ', hang/systemstate dumps')" "$([ "$DO_THREADS" = 1 ] && echo ', thread dumps x3 + class histogram')" "$TOOL"
    printf '## Files\n\n```\n'; (cd "$PACK" && find . -type f -not -name MANIFEST.md | sort | while IFS= read -r f; do printf '%10s  %s\n' "$(du -k "$f" | cut -f1)K" "${f#./}"; done); printf '```\n'
    [ "$NFAIL" = 0 ] || { printf '\n## Not collected (%s) - the pack is INCOMPLETE\n\n%s' "$NFAIL" "$FAILED"; }
  } >"$m"
  printf '%s' "$FACTS" >"$PACK/FACTS.txt"
}
finish_tar() {
  local name; name="$(basename "$PACK")"; local tgz="$PACK_OUT/$name.tar.gz"
  [ "$DRY_RUN" = 1 ] && { log "would tar $PACK"; return 0; }
  (cd "$PACK_OUT" && tar -czf "$name.tar.gz" "$name") || die "tar failed"
  local sz; sz="$(file_size "$tgz")"; log "tarball: $tgz ($(du -h "$tgz" | cut -f1))"
  if [ "$DO_SPLIT" = 1 ] || [ "$sz" -gt 2000000000 ]; then
    (cd "$PACK_OUT" && split -b 1900m -d -a 2 "$name.tar.gz" "$name.tar.gz.part") && rm -f "$tgz" && log "split into $(ls "$PACK_OUT/$name.tar.gz.part"* | wc -l | tr -d ' ') parts of max 1900 MB (MOS upload limit 2 GB per file; reassemble with: cat $name.tar.gz.part* > $name.tar.gz)"
  fi
  (cd "$PACK_OUT" && { command -v sha256sum >/dev/null 2>&1 && sha256sum "$name.tar.gz"* || shasum -a 256 "$name.tar.gz"*; }) | tee "$PACK_OUT/$name.sha256"
  echo; echo "Upload: My Oracle Support > SR $SR > Upload (or the SR's FTP/MOS upload link); paste MANIFEST.md's Facts into the SR update."
  echo "Next:   ../sr-draft/sr-draft.sh --pack $PACK   (draft the SR text from this pack)"
}

main() {
  load_config; refuse_root; parse_opts "$@"
  [ -n "$SR" ] || { usage; exit 1; }
  printf '%s' "$SR" | grep -qE '^[A-Za-z0-9._-]+$' || die "SR label must be letters, digits, . _ - (e.g. 3-12345678901 or ORA600-20261031)"
  set_window; mkdir -p "$PACK_OUT" || die "cannot create $PACK_OUT: $OUTPUT_HINT"; PACK="$PACK_OUT/${SR}_${HOST}_$(date '+%Y%m%d_%H%M%S')"; RUN_DIR="$PACK"; RUN_BASE="$PACK_OUT"; init_run_dir pack
  touch -t "$(if [ "$GNU_DATE" = 1 ]; then date -d "@$SINCE_EP" '+%Y%m%d%H%M.%S'; else date -r "$SINCE_EP" '+%Y%m%d%H%M.%S'; fi)" "$PACK/.since" 2>/dev/null || touch "$PACK/.since"
  log "incident pack for SR $SR on $HOST, window $SINCE_ISO .. $UNTIL_ISO -> $PACK"
  fact SR "$SR"; fact HOST "$HOST"; fact FQDN "$(hostname -f 2>/dev/null || hostname 2>/dev/null || uname -n)"; fact WINDOW "$SINCE_ISO .. $UNTIL_ISO"; fact GENERATED "$(ts)"
  [ "$DO_HANG" = 1 ] && [ "$ASSUME_YES" != 1 ] && [ ! -t 0 ] && die "--hang needs --yes when not interactive"
  [ "$DO_HEAP" = 1 ] && [ "$ASSUME_YES" != 1 ] && [ ! -t 0 ] && die "--heap-dump needs --yes when not interactive"
  want db && collect_tfa
  collect_diag
  local sid; if want db; then for sid in $(db_sids); do collect_db "$sid"; done; collect_listener; fi
  want wls && collect_wls; want ords && collect_ords; want apex && collect_apex; want gg && collect_gg; want exa && collect_exa; want host && collect_host
  [ "$DRY_RUN" = 1 ] && { log "dry-run: nothing written beyond the log"; return 0; }
  write_manifest; log "$NFILES file(s) collected, $NFAIL not collected, $(du -sh "$PACK" | cut -f1); MANIFEST.md written"
  finish_tar
  [ "$NFAIL" = 0 ] || { err "pack INCOMPLETE: $NFAIL file(s) could not be written (MANIFEST.md 'Not collected' names them) - do not upload it as complete"; return 1; }
}
main "$@"
