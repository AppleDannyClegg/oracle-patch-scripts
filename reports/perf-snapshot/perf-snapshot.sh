#!/usr/bin/env bash
# perf-snapshot.sh - performance evidence for a time window, in one report. Read-only.
# "It was slow between 09:00 and 10:30": this collects what a tuning DBA (or Claude) needs to say
# why: top SQL, plan changes, waits, blocking, I/O latency, memory, OS stats, and - with the
# Diagnostics Pack - the AWR, ASH and ADDM reports for the window.
# Exit: 2 with a CRIT finding, 1 with a WARN, 0 clean. A read that failed (a sample that got ORA-00020, a dba_hist view this
# edition lacks, a section whose SQL errored) is a finding that says NOT measured / NOT collected - never a quiet 0.
#
# Usage: perf-snapshot.sh [options]
#   --from "YYYY-MM-DD HH:MI" --to "YYYY-MM-DD HH:MI"   the window (default: the last 60 minutes)
#   --last 2h | 30m | 1d       window ending now
#   --sid SID                  one database (default: every running instance)
#   --pdb NAME                 run the per-container queries in this PDB (open PDBs otherwise)
#   --sql-id ID                deep-dive one statement: text, plans over time, binds, stats of its tables
#   --awr                      AWR + ASH + ADDM text reports for the window  (Diagnostics Pack licence!)
#   --no-pack                  never touch dba_hist_* / ASH (v$ views and live sampling only)
#   --threads                  thread dumps of running WebLogic / ORDS JVMs (jcmd), 3 x 10 s apart
#   --samples N                live v$session samples (default 10, 2 s apart)
#   --out DIR  --lines N  --quiet  --no-tar
#
# Config: perf-snapshot.conf, ~/.perf-snapshot.conf, or the shared oracle.conf: SQL_CONNECT, PDB,
# PERF_OUT, PERF_TOP (default 20), PERF_PACK=yes|no (default: ask the database's control_management_pack_access).
# Output: PERF_OUT/<host>_<ts>/REPORT.md (FINDINGS first) + raw/ (full AWR/ASH/ADDM text, samples, CSVs) + tar.gz.

# shellcheck disable=SC2034  # QUIET/VERBOSE/FORCE are read by the lib
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="perf-snapshot"; VERSION="1.0.0"
# shellcheck source=../../lib/oracle-lib.sh
. "$SCRIPT_DIR/../../lib/oracle-lib.sh" || { echo "lib/oracle-lib.sh not found" >&2; exit 1; }

PERF_OUT="${PERF_OUT:-$HOME/perf-snapshot}"; PERF_TOP="${PERF_TOP:-20}"; PERF_PACK="${PERF_PACK:-}"
FROM=""; TO=""; LAST=""; ONLY_SID=""; SQL_ID=""; WANT_AWR=0; NO_PACK=0; THREADS=0; SAMPLES=10; MAKE_TAR=1
PACK_OK=0

usage() { usage_from_header "$0"; }
parse_args() {
  while [ $# -gt 0 ]; do case "$1" in
    --from) optchk "$@"; FROM="$2"; shift 2;; --to) optchk "$@"; TO="$2"; shift 2;; --last) optchk "$@"; LAST="$2"; shift 2;;
    --sid) optchk "$@"; ONLY_SID="$2"; shift 2;; --pdb) optchk "$@"; PDB="$2"; shift 2;; --sql-id) optchk "$@"; SQL_ID="$2"; shift 2;;
    --awr) WANT_AWR=1; shift;; --no-pack) NO_PACK=1; shift;; --threads) THREADS=1; shift;; --samples) optchk "$@"; SAMPLES="$2"; shift 2;;
    --out) optchk "$@"; PERF_OUT="$2"; shift 2;; --lines) optchk "$@"; DIAG_LINES="$2"; shift 2;; --quiet) QUIET=1; shift;; --no-tar) MAKE_TAR=0; shift;; --verbose) VERBOSE=1; shift;;
    -h|--help) usage; exit 0;; *) die "Unknown option: $1";; esac; done
}
# window: FROM/TO as 'YYYY-MM-DD HH24:MI'
set_window() {
  local now; now="$(date '+%Y-%m-%d %H:%M')"
  if [ -n "$LAST" ]; then
    local n="${LAST%[mhd]}" u="${LAST##*[0-9]}" mins
    case "$u" in m) mins="$n";; h) mins=$((n*60));; d) mins=$((n*1440));; *) die "--last wants 30m / 2h / 1d";; esac
    TO="$now"; if [ "$GNU_DATE" = 1 ]; then FROM="$(date -d "-$mins minutes" '+%Y-%m-%d %H:%M')"; else FROM="$(date -v-"${mins}"M '+%Y-%m-%d %H:%M')"; fi
  fi
  [ -z "$TO" ] && TO="$now"
  [ -z "$FROM" ] && { if [ "$GNU_DATE" = 1 ]; then FROM="$(date -d "-60 minutes" '+%Y-%m-%d %H:%M')"; else FROM="$(date -v-60M '+%Y-%m-%d %H:%M')"; fi; }
  [[ "$FROM" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]] || die "--from must be 'YYYY-MM-DD HH:MI'"
  [[ "$TO" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]] || die "--to must be 'YYYY-MM-DD HH:MI'"
  WFROM="to_date('$FROM','YYYY-MM-DD HH24:MI')"; WTO="to_date('$TO','YYYY-MM-DD HH24:MI')"
}
pack_check() { # per database: may we read dba_hist / ASH?
  local sid="$1" v
  [ "$NO_PACK" = 1 ] && { PACK_OK=0; return; }
  case "${PERF_PACK,,}" in yes) PACK_OK=1; return;; no) PACK_OK=0; return;; esac
  # a read that failed used to be 'no pack' and the AWR sections were skipped without a word. sql_lines, not sql_val: sql_val
  # drops stderr itself, so a '2>&1' at this call site captured nothing and the ORA- code never reached the finding (Ultron 00:29)
  local err="$RAW/db_${sid}_pack.err" e
  v="$(sql_lines "$sid" "select upper(value) from v\$parameter where name='control_management_pack_access';" 2>"$err" | head -1)"
  if [ -n "$v" ] && ! [ -s "$err" ]; then
    case "$v" in *DIAGNOSTIC*) PACK_OK=1;; *) PACK_OK=0;; esac
  else PACK_OK=0; e="$(grep -m1 -oE '(ORA|SP2)-[0-9]+[^|]*' "$err" 2>/dev/null | cut -c1-80)"
    finding WARN db "$sid: control_management_pack_access could not be read (${e:-no answer}) - AWR/ASH/ADDM sections NOT collected; PERF_PACK=yes forces them"; fi
}

# ---------------------------------------------------------------------------
host_stats() {
  h1 "Host during collection"
  section_sh host_now "uptime; echo; nproc 2>/dev/null; free -m 2>/dev/null; echo; cat /proc/loadavg 2>/dev/null"
  h3 "vmstat / iostat (10 samples, 2 s)"
  section_sh host_vmstat "vmstat 2 10 2>/dev/null"
  section_sh host_iostat "iostat -x 2 5 2>/dev/null | awk 'NR<5 || \$1 ~ /^(sd|nvme|dm|md|xvd|vd|emcpower|asm)/' | head -120"
  section_sh host_top "ps -eo pid,user,pcpu,pmem,rss,etime,args --sort=-pcpu 2>/dev/null | head -20 | cut -c1-180"
  section_sh host_hugepages "grep -E 'Huge|MemFree|MemAvailable|SwapFree|Dirty' /proc/meminfo 2>/dev/null; cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null"
  local osw; osw="$(ls -d /opt/oracle.ahf/data/*/oswbb/archive /u01/app/*/oswbb/archive /opt/oswbb/archive 2>/dev/null | head -1)"
  if [ -n "$osw" ]; then
    h3 "OSWatcher archive for the window"
    local d="${FROM:0:10}"; local hh="${FROM:11:2}"
    section_sh host_osw "ls '$osw'; echo; for f in '$osw'/oswvmstat/*${d//-/.}*${hh}00*.dat*; do [ -f \"\$f\" ] && { echo \"== \$f\"; zcat -f \"\$f\" | head -80; }; done"
  fi
  local idle; idle="$(vmstat 1 2 2>/dev/null | tail -1 | awk '{print $15}')"; [ -n "$idle" ] && [ "$idle" -lt 10 ] && finding CRIT host "CPU nearly saturated now (idle ${idle}%)"
  local swp; swp="$(vmstat 1 2 2>/dev/null | tail -1 | awk '{print $7+$8}')"; [ -n "$swp" ] && [ "$swp" -gt 100 ] && finding CRIT host "swapping now (si+so ${swp} blocks/s)"
  awk '/^(sd|nvme|dm|md)/ && $NF+0 > 0' "$RAW/host_iostat.txt" 2>/dev/null | awk '{ if ($(NF-0)+0 >= 90) print $1, $NF }' | head -3 | while read -r dev util; do finding WARN host "device $dev at ${util}% utilisation"; done
}

live_samples() { # sample v$session N times: who is active, on what, waiting for what
  local sid="$1" i f failed=0 ferr=""; f="$RAW/db_${sid}_samples.txt"; : >"$f"
  for ((i=1; i<=SAMPLES; i++)); do
    # each sample's outcome is kept: 'sql_run | grep ^HH:' counted a sample that got ORA-00020 / ORA-01034 / a timeout as an idle
    # one, so a database too busy to answer read as 'avg active sessions ~ 0.0' with no finding (Bishop 23:39)
    local out; if ! out="$(sql_run "$sid" "set heading off\nselect to_char(sysdate,'HH24:MI:SS')||'|'||sid||'|'||nvl(username,'bg')||'|'||nvl(sql_id,'-')||'|'||event||'|'||wait_class||'|'||nvl(blocking_session,0)||'|'||substr(nvl(module,'-'),1,30)||'|'||seconds_in_wait from v\$session where status='ACTIVE' and type='USER' and (wait_class<>'Idle' or sql_id is not null);" 2>&1)" || printf '%s\n' "$out" | grep -qE 'ORA-|SP2-'; then
      failed=$((failed+1)); [ -n "$ferr" ] || ferr="$(printf '%s\n' "$out" | grep -oE '(ORA|SP2)-[0-9]+[^|]*' | head -1 | cut -c1-80)"; printf '%s\n' "$out" >>"$RAW/db_${sid}_samples.err"
    else printf '%s\n' "$out" | grep -E '^[0-9]{2}:' >>"$f"; fi
    sleep 2
  done
  [ "$failed" = 0 ] || finding CRIT db "$sid: $failed of $SAMPLES live samples failed (${ferr:-no ORA- line, see raw/db_${sid}_samples.err}) - live activity NOT measured; the averages below are from the $((SAMPLES-failed)) that answered"
  h3 "Live sampling of v\$session ($SAMPLES samples, 2 s apart) - ASH without the pack"
  fence_start
  { echo "samples: $SAMPLES ($failed failed)   active-session lines: $(wc -l <"$f" | tr -d ' ')   (avg active sessions ~ $(awk -v s="$SAMPLES" 'END{printf "%.1f", NR/s}' "$f"))"; echo
    echo "top sql_id (samples):"; cut -d'|' -f4 "$f" | sort | uniq -c | sort -rn | head -10; echo
    echo "top events:"; cut -d'|' -f5 "$f" | sort | uniq -c | sort -rn | head -10; echo
    echo "top wait classes:"; cut -d'|' -f6 "$f" | sort | uniq -c | sort -rn; echo
    echo "top modules:"; cut -d'|' -f8 "$f" | sort | uniq -c | sort -rn | head -8; echo
    echo "blocked (blocker sid, count):"; awk -F'|' '$7>0 {print $7}' "$f" | sort | uniq -c | sort -rn | head -5; } >>"$REPORT"
  fence_end
  local cpu; cpu="$(cut -d'|' -f6 "$f" | grep -c 'ON CPU\|^$' 2>/dev/null)"; local tot; tot="$(wc -l <"$f" | tr -d ' ')"
  local cls; cls="$(cut -d'|' -f6 "$f" | sort | uniq -c | sort -rn | head -1 | awk '{print $2, $1}')"
  [ "$tot" -gt 0 ] && [ -n "$cls" ] && awk -v c="${cls#* }" -v t="$tot" 'BEGIN{exit !(c*100/t > 60)}' && [ "${cls% *}" != "" ] && finding WARN db "$sid: live samples dominated by wait class '${cls% *}' ($(pct_of "${cls#* }" "$tot")%)"
  local blk; blk="$(awk -F'|' '$7>0' "$f" | wc -l | tr -d ' ')"; [ "$blk" -gt "$((tot/4))" ] && [ "$blk" -gt 2 ] && finding CRIT db "$sid: $blk of $tot sampled active sessions were blocked"
}

# sql_section_audit <sid>: lib's sqlsec writes a section's SQL output verbatim, errors included, and adds no finding - so a report
# whose every section is 'ORA-00942: table or view does not exist' read as a clean report with odd content (unreadable gate
# statement mode, f7d2f83). Count the sections that hold an error and say they are not evidence.
sql_section_audit() {
  local sid="$1" f bad=0 n=0 first=""
  for f in "$RAW"/db_"${sid}"_*.txt; do [ -f "$f" ] || continue; case "$f" in *_samples.txt) continue;; esac; n=$((n+1))
    if grep -qE '^(ORA|SP2)-[0-9]+' "$f"; then bad=$((bad+1)); [ -n "$first" ] || first="$(basename "$f" .txt | sed "s/^db_${sid}_//"): $(grep -m1 -oE '(ORA|SP2)-[0-9]+[^|]*' "$f" | cut -c1-70)"; fi
  done
  [ "$bad" = 0 ] || finding WARN db "$sid: $bad of $n SQL sections hold an ORA-/SP2- error (first: $first) - those sections are NOT evidence, the query did not complete"
}

db_live() { # v$ only - always available
  local sid="$1"
  sqlsec "$sid" overview "$sid: instance, memory, resource limits" "select instance_name, host_name, version_full, to_char(startup_time,'YYYY-MM-DD HH24:MI') started, (select value from v\$parameter where name='cpu_count') cpu_count, (select value from v\$parameter where name='control_management_pack_access') pack from v\$instance;
select name, round(value/1048576) mb from v\$sga;
select name, round(value/1048576) mb from v\$pgastat where name in ('aggregate PGA target parameter','total PGA allocated','total PGA inuse','maximum PGA allocated','over allocation count','cache hit percentage');
select resource_name, current_utilization, max_utilization, limit_value from v\$resource_limit where resource_name in ('processes','sessions','parallel_max_servers');
select 'temp in use MB: '||round(nvl(sum(blocks),0)*8/1024) from v\$sort_usage;
select 'PGA spills now: '||count(*) from v\$sql_workarea_active where tempseg_size>0;"
  sqlsec "$sid" waits "$sid: wait profile since startup (v\$system_wait_class / v\$system_event)" "select wait_class, round(time_waited_micro/1e6) secs, total_waits, round(time_waited_micro/greatest(total_waits,1)/1000,2) avg_ms from v\$system_wait_class where wait_class<>'Idle' order by 2 desc;
select * from (select event, wait_class, total_waits, round(time_waited_micro/1e6) secs, round(average_wait*10,2) avg_ms from v\$system_event where wait_class<>'Idle' order by time_waited_micro desc) where rownum<=15;
select name, value from v\$sysstat where name in ('DB time','CPU used by this session','user commits','user rollbacks','parse count (hard)','parse count (total)','execute count','physical reads','physical writes','redo size','session logical reads','sorts (disk)','table scans (long tables)');
select 'latency single block read (ms, since startup): '||round(average_wait*10,2) from v\$system_event where event='db file sequential read';
select 'log file sync avg ms: '||round(average_wait*10,2) from v\$system_event where event='log file sync';
select 'log file parallel write avg ms: '||round(average_wait*10,2) from v\$system_event where event='log file parallel write';"
  sqlsec "$sid" topsql_live "$sid: top SQL in the cursor cache now (v\$sqlstats, by elapsed)" "col sql_text for a60
select * from (select sql_id, plan_hash_value, executions, round(elapsed_time/1e6) elapsed_s, round(cpu_time/1e6) cpu_s, round(elapsed_time/greatest(executions,1)/1000) avg_ms, buffer_gets, disk_reads, rows_processed, substr(regexp_replace(sql_text,'\s+',' '),1,60) sql_text from v\$sqlstats order by elapsed_time desc) where rownum<=$PERF_TOP;
select * from (select sql_id, plan_hash_value, executions, round(elapsed_time/greatest(executions,1)/1000) avg_ms, buffer_gets, substr(regexp_replace(sql_text,'\s+',' '),1,60) sql_text from v\$sqlstats where executions>0 order by buffer_gets desc) where rownum<=10;
select sql_id, count(distinct plan_hash_value) plans, listagg(plan_hash_value, ',') within group (order by plan_hash_value) plan_hashes from v\$sql where plan_hash_value>0 group by sql_id having count(distinct plan_hash_value)>1 order by 2 desc fetch first 15 rows only;
select 'hard parses/sec since startup: '||round(h.value/((sysdate-i.startup_time)*86400),2) from v\$sysstat h, v\$instance i where h.name='parse count (hard)';
select 'cursor cache: '||count(*)||' child cursors, '||count(distinct sql_id)||' statements; versions>50: '||sum(case when c>50 then 1 else 0 end) from (select sql_id, count(*) c from v\$sql group by sql_id) ;"
  sqlsec "$sid" blocking "$sid: blocking, long ops, long transactions now" "select s.sid||','||s.serial# blocker, s.username, s.event, s.seconds_in_wait blocker_wait, s.sql_id, (select count(*) from v\$session w where w.blocking_session=s.sid) blocking from v\$session s where s.sid in (select blocking_session from v\$session where blocking_session is not null);
select sid, substr(opname,1,30) opname, round(sofar*100/totalwork) pct, time_remaining, elapsed_seconds, sql_id from v\$session_longops where totalwork>0 and sofar<totalwork;
select 'long transaction: sid '||s.sid||' '||s.username||' since '||t.start_time||' undo blocks '||t.used_ublk from v\$transaction t join v\$session s on s.taddr=t.addr where t.start_date<sysdate-1/24;
select type, count(*) from v\$lock where block=1 group by type;
select 'library cache / latch waits now: '||count(*) from v\$session where event like 'library cache%' or event like 'latch%' or event like 'cursor:%';"
  sqlsec "$sid" io "$sid: I/O by file (v\$filestat since startup)" "select * from (select f.file#, substr(d.name,1,60) name, f.phyrds, f.phywrts, round(f.readtim*10/greatest(f.phyrds,1),2) avg_read_ms, round(f.singleblkrdtim*10/greatest(f.singleblkrds,1),2) sb_read_ms from v\$filestat f join v\$datafile d on d.file#=f.file# order by f.phyrds desc) where rownum<=15;
select to_char(first_time,'YYYY-MM-DD HH24') hour, count(*) switches, round(sum(blocks*block_size)/1048576) redo_mb from v\$archived_log where first_time>sysdate-1 and dest_id=1 group by to_char(first_time,'YYYY-MM-DD HH24') order by 1;
select 'redo log size MB: '||round(max(bytes)/1048576)||', groups '||count(*) from v\$log;"
  sqlsec "$sid" sessions "$sid: sessions by machine / module / program" "select * from (select nvl(username,'bg') username, substr(machine,1,25) machine, substr(module,1,25) module, count(*) sessions, sum(decode(status,'ACTIVE',1,0)) active from v\$session where type='USER' group by nvl(username,'bg'), substr(machine,1,25), substr(module,1,25) order by 4 desc) where rownum<=20;
select 'logons/sec since startup: '||round(l.value/((sysdate-i.startup_time)*86400),2) from v\$sysstat l, v\$instance i where l.name='logons cumulative';"
  sql_checks "$sid" "$sid" "select 'CHECK|WARN|single-block read latency '||round(average_wait*10,2)||' ms since startup (>10 ms on flash is slow storage)' from v\$system_event where event='db file sequential read' and average_wait*10>10;
select 'CHECK|WARN|log file sync '||round(average_wait*10,2)||' ms since startup' from v\$system_event where event='log file sync' and average_wait*10>10;
select 'CHECK|WARN|PGA over-allocation count '||value||' - PGA too small' from v\$pgastat where name='over allocation count' and value>0;
select 'CHECK|WARN|'||count(*)||' statement(s) with more than one execution plan in the cursor cache' from (select sql_id from v\$sql where plan_hash_value>0 group by sql_id having count(distinct plan_hash_value)>2) having count(*)>5;
select 'CHECK|WARN|'||sql_id||' has '||count(*)||' child cursors (bind mismatch / version count)' from v\$sql group by sql_id having count(*)>100;
select 'CHECK|CRIT|'||count(*)||' sessions blocked right now, longest '||max(seconds_in_wait)||'s' from v\$session where blocking_session is not null and seconds_in_wait>30 having count(*)>0;
select 'CHECK|WARN|processes at '||current_utilization||' of '||limit_value from v\$resource_limit where resource_name='processes' and current_utilization*100/to_number(limit_value)>=80;
select 'CHECK|WARN|'||count(*)||' active work areas spilling to temp now' from v\$sql_workarea_active where tempseg_size>0 having count(*)>5;
select 'CHECK|WARN|redo switching '||max(c)||'/hour in the last day' from (select count(*) c from v\$archived_log where first_time>sysdate-1 and dest_id=1 group by to_char(first_time,'YYYY-MM-DD HH24')) having max(c)>12;
select 'CHECK|INFO|control_management_pack_access='||value||' - AWR/ASH not used' from v\$parameter where name='control_management_pack_access' and upper(value) not like '%DIAGNOSTIC%';"
}

db_hist() { # dba_hist: needs the Diagnostics Pack
  local sid="$1"
  h3 "AWR window"
  local snaps; snaps="$(sql_lines "$sid" "select min(snap_id)||' '||max(snap_id)||' '||dbid||' '||instance_number from dba_hist_snapshot where end_interval_time>=$WFROM and begin_interval_time<=$WTO and dbid=(select dbid from v\$database) and instance_number=(select instance_number from v\$instance) group by dbid, instance_number;" 2>"$RAW/db_${sid}_hist.err" | head -1)"
  # the snapshot read's status: a dba_hist_snapshot that could not be read was 'no AWR snapshots at all' and a quiet return
  [ -s "$RAW/db_${sid}_hist.err" ] && { finding WARN db "$sid: dba_hist_snapshot could not be read ($(grep -m1 -oE '(ORA|SP2)-[0-9]+[^|]*' "$RAW/db_${sid}_hist.err" | cut -c1-80)) - AWR window NOT collected"; para "_dba_hist_snapshot could not be read_"; return; }
  local bsnap esnap dbid inst; read -r bsnap esnap dbid inst <<<"$snaps"
  if [ -z "$bsnap" ] || [ "$bsnap" = "$esnap" ]; then para "_no two AWR snapshots cover $FROM .. $TO (interval too long or snapshots stopped); dba_hist queries below use the nearest snapshots_"; finding INFO db "$sid: window has fewer than two AWR snapshots"; snaps="$(sql_lines "$sid" "select min(snap_id)||' '||max(snap_id)||' '||dbid||' '||instance_number from (select * from dba_hist_snapshot where dbid=(select dbid from v\$database) and instance_number=(select instance_number from v\$instance) and end_interval_time>=$WFROM-1/12 order by snap_id) group by dbid, instance_number;" 2>/dev/null | head -1)"; read -r bsnap esnap dbid inst <<<"$snaps"; fi
  [ -z "$bsnap" ] && { para "_no AWR snapshots at all_"; return; }
  kv "snapshots" "$bsnap .. $esnap (dbid $dbid, instance $inst)"; kv_end
  sqlsec "$sid" hist_topsql "$sid: top SQL in the window (dba_hist_sqlstat deltas)" "col sql_text for a50
select * from (select s.sql_id, s.plan_hash_value, sum(s.executions_delta) execs, round(sum(s.elapsed_time_delta)/1e6) elapsed_s, round(sum(s.cpu_time_delta)/1e6) cpu_s, round(sum(s.iowait_delta)/1e6) io_s, round(sum(s.elapsed_time_delta)/greatest(sum(s.executions_delta),1)/1000) avg_ms, sum(s.buffer_gets_delta) gets, sum(s.disk_reads_delta) reads, sum(s.rows_processed_delta) rows_, substr(regexp_replace(dbms_lob.substr(t.sql_text,200,1),'\s+',' '),1,50) sql_text from dba_hist_sqlstat s left join dba_hist_sqltext t on t.sql_id=s.sql_id and t.dbid=s.dbid where s.snap_id>$bsnap and s.snap_id<=$esnap and s.dbid=$dbid and s.instance_number=$inst group by s.sql_id, s.plan_hash_value, dbms_lob.substr(t.sql_text,200,1) order by elapsed_s desc) where rownum<=$PERF_TOP;
select 'DB time in window (s): '||round(sum(case when stat_name='DB time' then delta end)/1e6)||', DB CPU (s): '||round(sum(case when stat_name='DB CPU' then delta end)/1e6) from (select stat_name, value - lag(value) over (partition by stat_name order by snap_id) delta from dba_hist_sys_time_model where snap_id between $bsnap and $esnap and dbid=$dbid and instance_number=$inst and stat_name in ('DB time','DB CPU'));
select sql_id, count(distinct plan_hash_value) plans, listagg(plan_hash_value||':'||execs,' ') within group (order by plan_hash_value) plan_execs from (select sql_id, plan_hash_value, sum(executions_delta) execs from dba_hist_sqlstat where snap_id>$bsnap and snap_id<=$esnap and dbid=$dbid and instance_number=$inst and plan_hash_value>0 group by sql_id, plan_hash_value) group by sql_id having count(distinct plan_hash_value)>1 order by 2 desc fetch first 15 rows only;"
  sqlsec "$sid" hist_waits "$sid: wait classes and top events in the window (dba_hist deltas)" "select wait_class, round(sum(time_waited_micro_delta)/1e6) secs, sum(total_waits_delta) waits from (select e.wait_class, e.time_waited_micro - lag(e.time_waited_micro) over (partition by e.event_id order by e.snap_id) time_waited_micro_delta, e.total_waits - lag(e.total_waits) over (partition by e.event_id order by e.snap_id) total_waits_delta from dba_hist_system_event e where e.snap_id between $bsnap and $esnap and e.dbid=$dbid and e.instance_number=$inst) where wait_class<>'Idle' group by wait_class order by 2 desc;
select * from (select event_name, wait_class, round(sum(d)/1e6) secs, sum(w) waits, round(sum(d)/greatest(sum(w),1)/1000,2) avg_ms from (select e.event_name, e.wait_class, e.time_waited_micro - lag(e.time_waited_micro) over (partition by e.event_id order by e.snap_id) d, e.total_waits - lag(e.total_waits) over (partition by e.event_id order by e.snap_id) w from dba_hist_system_event e where e.snap_id between $bsnap and $esnap and e.dbid=$dbid and e.instance_number=$inst) where wait_class<>'Idle' group by event_name, wait_class order by 3 desc) where rownum<=15;
select to_char(end_interval_time,'HH24:MI') snap_end, round(value,2) from (select s.end_interval_time, o.value from dba_hist_osstat o join dba_hist_snapshot s on s.snap_id=o.snap_id and s.dbid=o.dbid and s.instance_number=o.instance_number where o.stat_name='LOAD' and o.snap_id between $bsnap and $esnap and o.dbid=$dbid and o.instance_number=$inst) order by 1;"
  sqlsec "$sid" hist_ash "$sid: ASH in the window (dba_hist_active_sess_history)" "select 'avg active sessions: '||round(count(*)*10/greatest(($WTO-$WFROM)*86400,1),2)||'  (samples '||count(*)||')' from dba_hist_active_sess_history where sample_time between $WFROM and $WTO and dbid=$dbid and instance_number=$inst;
select * from (select nvl(event,'ON CPU') event, wait_class, count(*)*10 secs from dba_hist_active_sess_history where sample_time between $WFROM and $WTO and dbid=$dbid and instance_number=$inst group by nvl(event,'ON CPU'), wait_class order by 3 desc) where rownum<=15;
select * from (select sql_id, sql_plan_hash_value, count(*)*10 secs, round(count(*)*100/sum(count(*)) over (),1) pct from dba_hist_active_sess_history where sample_time between $WFROM and $WTO and dbid=$dbid and instance_number=$inst and sql_id is not null group by sql_id, sql_plan_hash_value order by 3 desc) where rownum<=15;
select * from (select nvl(user_id,-1) user_id, (select username from dba_users u where u.user_id=a.user_id) username, substr(module,1,30) module, count(*)*10 secs from dba_hist_active_sess_history a where sample_time between $WFROM and $WTO and dbid=$dbid and instance_number=$inst group by user_id, substr(module,1,30) order by 4 desc) where rownum<=10;
select * from (select blocking_session, count(*)*10 blocked_secs, count(distinct session_id) victims from dba_hist_active_sess_history where sample_time between $WFROM and $WTO and dbid=$dbid and instance_number=$inst and blocking_session is not null group by blocking_session order by 2 desc) where rownum<=10;
select to_char(sample_time,'HH24:MI') minute, count(*)/6 aas from dba_hist_active_sess_history where sample_time between $WFROM and $WTO and dbid=$dbid and instance_number=$inst group by to_char(sample_time,'HH24:MI') order by 1;"
  sql_checks "$sid" "$sid (window)" "select 'CHECK|WARN|'||sql_id||' ran with '||count(distinct plan_hash_value)||' different plans in the window (plan flip)' from dba_hist_sqlstat where snap_id>$bsnap and snap_id<=$esnap and dbid=$dbid and instance_number=$inst and plan_hash_value>0 group by sql_id having count(distinct plan_hash_value)>1 and sum(executions_delta)>10 fetch first 5 rows only;
select 'CHECK|WARN|'||sql_id||' took '||pct||'% of DB time in the window' from (select sql_id, round(sum(elapsed_time_delta)*100/(select sum(delta) from (select value - lag(value) over (order by snap_id) delta from dba_hist_sys_time_model where snap_id between $bsnap and $esnap and dbid=$dbid and instance_number=$inst and stat_name='DB time'))) pct from dba_hist_sqlstat where snap_id>$bsnap and snap_id<=$esnap and dbid=$dbid and instance_number=$inst group by sql_id) where pct>=25;
select 'CHECK|WARN|wait class '||wait_class||' is '||pct||'% of non-idle wait time in the window' from (select wait_class, round(sum(d)*100/sum(sum(d)) over ()) pct from (select e.wait_class, e.time_waited_micro - lag(e.time_waited_micro) over (partition by e.event_id order by e.snap_id) d from dba_hist_system_event e where e.snap_id between $bsnap and $esnap and e.dbid=$dbid and e.instance_number=$inst) where wait_class<>'Idle' group by wait_class) where pct>=60 and wait_class<>'User I/O';
select 'CHECK|CRIT|session '||blocking_session||' blocked others for '||count(*)*10||' s in the window' from dba_hist_active_sess_history where sample_time between $WFROM and $WTO and dbid=$dbid and instance_number=$inst and blocking_session is not null group by blocking_session having count(*)*10>300;"
  if [ "$WANT_AWR" = 1 ]; then
    h3 "AWR / ASH / ADDM text reports (raw/)"
    sql_run "$sid" "set heading off pagesize 0 linesize 1500 trimspool on\nselect output from table(dbms_workload_repository.awr_report_text($dbid,$inst,$bsnap,$esnap));" >"$RAW/awr_${sid}_${bsnap}_${esnap}.txt" 2>&1
    sql_run "$sid" "set heading off pagesize 0 linesize 1500 trimspool on\nselect output from table(dbms_workload_repository.ash_report_text($dbid,$inst,$WFROM,$WTO));" >"$RAW/ash_${sid}.txt" 2>&1
    sql_run "$sid" "set heading off pagesize 0 linesize 1500 trimspool on serveroutput on\nvariable t varchar2(60)\nbegin :t:='perf-snapshot_'||to_char(sysdate,'YYYYMMDDHH24MISS'); dbms_addm.analyze_inst(:t, $bsnap, $esnap); end;\n/\nselect dbms_addm.get_report(:t) from dual;\nexec dbms_addm.delete(:t)" >"$RAW/addm_${sid}.txt" 2>&1
    kv "AWR" "raw/awr_${sid}_${bsnap}_${esnap}.txt ($(wc -l <"$RAW/awr_${sid}_${bsnap}_${esnap}.txt") lines)"; kv "ASH" "raw/ash_${sid}.txt"; kv "ADDM" "raw/addm_${sid}.txt"; kv_end
    fence_start; grep -A12 'Top 10 Foreground Events' "$RAW/awr_${sid}_${bsnap}_${esnap}.txt" | head -16 >>"$REPORT"; echo >>"$REPORT"; grep -B2 -A6 'Load Profile' "$RAW/awr_${sid}_${bsnap}_${esnap}.txt" | head -14 >>"$REPORT"; fence_end
    grep -qE 'FINDING 1' "$RAW/addm_${sid}.txt" && { fence_start; grep -A6 -E '^ *FINDING [0-9]+' "$RAW/addm_${sid}.txt" | head -60 >>"$REPORT"; fence_end; }
  fi
}

sql_deep_dive() { # --sql-id
  local sid="$1" id="$2"
  h2 "SQL $id in $sid"
  sqlsec "$sid" "sql_${id}" "$id: text, children, plans over time, binds, tables" "set long 4000 longchunksize 4000
select sql_fulltext from v\$sqlarea where sql_id='$id';
select child_number, plan_hash_value, executions, round(elapsed_time/greatest(executions,1)/1000) avg_ms, buffer_gets, disk_reads, optimizer_env_hash_value, is_bind_sensitive, is_bind_aware, is_shareable, to_char(last_active_time,'YYYY-MM-DD HH24:MI') last_active from v\$sql where sql_id='$id';
select plan_table_output from table(dbms_xplan.display_cursor('$id', null, 'ALLSTATS LAST +PEEKED_BINDS +OUTLINE'));
select to_char(s.end_interval_time,'YYYY-MM-DD HH24:MI') snap, st.plan_hash_value, st.executions_delta execs, round(st.elapsed_time_delta/greatest(st.executions_delta,1)/1000) avg_ms, st.buffer_gets_delta gets, st.rows_processed_delta rows_ from dba_hist_sqlstat st join dba_hist_snapshot s on s.snap_id=st.snap_id and s.dbid=st.dbid and s.instance_number=st.instance_number where st.sql_id='$id' and s.end_interval_time>sysdate-7 order by 1 desc fetch first 60 rows only;
select plan_hash_value, min(timestamp) first_seen, max(timestamp) last_seen from dba_hist_sql_plan where sql_id='$id' group by plan_hash_value order by 2;
select name, position, datatype_string, value_string, to_char(last_captured,'YYYY-MM-DD HH24:MI') captured from v\$sql_bind_capture where sql_id='$id' and child_number=(select min(child_number) from v\$sql where sql_id='$id');
select 'profile/baseline/patch: '||nvl(sql_profile,'-')||' / '||nvl(sql_plan_baseline,'-')||' / '||nvl(sql_patch,'-') from v\$sql where sql_id='$id' and rownum=1;
select owner, object_name, object_type from dba_hist_sql_plan where sql_id='$id' and object_owner is not null and object_owner not in ('SYS') group by owner, object_name, object_type union select object_owner, object_name, object_type from v\$sql_plan where sql_id='$id' and object_owner is not null and object_owner<>'SYS' group by object_owner, object_name, object_type;
select t.owner, t.table_name, t.num_rows, t.blocks, to_char(t.last_analyzed,'YYYY-MM-DD HH24:MI') analyzed, t.stale_stats, (select count(*) from dba_indexes i where i.table_owner=t.owner and i.table_name=t.table_name) indexes from dba_tab_statistics t where (t.owner, t.table_name) in (select object_owner, object_name from v\$sql_plan where sql_id='$id' and object_type like 'TABLE%' union select object_owner, object_name from dba_hist_sql_plan where sql_id='$id' and object_type like 'TABLE%') and t.partition_name is null;
select plan_table_output from table(dbms_xplan.display_awr('$id', null, null, 'ALL'));"
  sql_checks "$sid" "$id" "select 'CHECK|WARN|'||count(distinct plan_hash_value)||' plans for $id in the last 7 days' from dba_hist_sql_plan where sql_id='$id' and timestamp>sysdate-7 having count(distinct plan_hash_value)>1;
select 'CHECK|WARN|table '||owner||'.'||table_name||' used by $id has stale statistics' from dba_tab_statistics where stale_stats='YES' and partition_name is null and (owner, table_name) in (select object_owner, object_name from v\$sql_plan where sql_id='$id' and object_type like 'TABLE%');
select 'CHECK|INFO|$id is bind sensitive/aware ('||is_bind_sensitive||'/'||is_bind_aware||') - adaptive cursor sharing in play' from v\$sql where sql_id='$id' and is_bind_sensitive='Y' and rownum=1;"
}

middleware_threads() {
  [ "$THREADS" = 1 ] || return 0
  h1 "JVM thread dumps (3 x 10 s)"
  # wls_running and ords_detect both read the process list and lose its status in the pipe: an unreadable list was an empty
  # section with no word (the main loop's CRIT says the databases were not found, not that these dumps were skipped)
  ps_pid_args >/dev/null 2>&1 || { para "_process list unreadable: no JVM found_"; finding WARN mw "cannot read the process list (ps failed, $PROC_DIR unreadable) - no WebLogic/ORDS JVM found; thread dumps NOT collected"; return; }
  local pids; pids="$( { wls_running | awk '{print $2}'; ords_detect >/dev/null && echo "$ORDS_PID"; } | grep -E '^[0-9]+$' | sort -u)"
  [ -n "$pids" ] || para "_no WebLogic server or ORDS JVM running on this host_"
  local p i; for p in $pids; do
    local jbin; jbin="$(dirname "$(readlink -f "/proc/$p/exe" 2>/dev/null)")"; local jcmd="$jbin/jcmd"; [ -x "$jcmd" ] || jcmd="$(command -v jcmd 2>/dev/null)"; [ -x "$jcmd" ] || continue
    local name; name="$(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | grep -oE 'weblogic.Name=[^ ]+' | cut -d= -f2)"; name="${name:-ords}"
    for i in 1 2 3; do to 60 "$jcmd" "$p" Thread.print >"$RAW/threads_${name}_${p}_$i.txt" 2>&1; [ "$i" -lt 3 ] && sleep 10; done
    to 60 "$jcmd" "$p" GC.heap_info >"$RAW/heap_${name}_$p.txt" 2>&1
    h3 "$name (pid $p)"; fence_start
    { echo "threads: $(grep -c '^"' "$RAW/threads_${name}_${p}_3.txt")"; grep -oE 'java.lang.Thread.State: [A-Z_]+' "$RAW/threads_${name}_${p}_3.txt" | sort | uniq -c
      echo; echo "top stack frames across the 3 dumps (what threads are doing):"; cat "$RAW/threads_${name}_${p}_"*.txt | grep -E '^\s+at ' | sed 's/^\s*at //; s/(.*//' | sort | uniq -c | sort -rn | head -15
      echo; echo "STUCK / blocked:"; grep -cE 'STUCK|BLOCKED' "$RAW/threads_${name}_${p}_3.txt"; echo; cat "$RAW/heap_${name}_$p.txt"; } >>"$REPORT"; fence_end
    if grep -q '^"' "$RAW/threads_${name}_${p}_3.txt"; then
      local blocked; blocked="$(grep -c 'java.lang.Thread.State: BLOCKED' "$RAW/threads_${name}_${p}_3.txt")"; [ "${blocked:-0}" -gt 20 ] && finding WARN wls "$name: $blocked threads BLOCKED in the last dump (lock contention)"
      grep -q 'STUCK' "$RAW/threads_${name}_${p}_3.txt" && finding WARN wls "$name: STUCK threads in the dump"
    else finding WARN wls "$name (pid $p): jcmd Thread.print returned no threads - $(head -1 "$RAW/threads_${name}_${p}_3.txt" | cut -c1-120); STUCK/BLOCKED unknown, not 0 (same user as the JVM? jcmd from the same JDK?)"; fi
  done
}

main() {
  load_config; parse_args "$@"; set_window
  report_init "$PERF_OUT/${HOST}_$(date '+%Y%m%d_%H%M%S')"
  say "perf-snapshot $VERSION window $FROM .. $TO -> $OUT"
  h1 "Window"; kv "from" "$FROM"; kv "to" "$TO"; kv "live samples" "$SAMPLES x 2 s"; kv_end
  host_stats
  # the loop head tests db_instances' status (lib b728ff6): a process list that cannot be read is a CRIT, not an empty loop
  local sids=""; if sids="$(db_instances)"; then sids="$(printf '%s\n' "$sids" | grep -vE '^\+ASM|^-MGMTDB|^\+APX')" || true
  else finding CRIT db "cannot read the process list (ps failed, $PROC_DIR unreadable) - no database was found or checked; pass --sid to check one"; fi
  [ -n "$ONLY_SID" ] && sids="$ONLY_SID"
  [ -z "$sids" ] && { h1 "Databases"; para "_no running database instance on this host_"; }
  local s; for s in $sids; do
    h1 "Database $s"
    if ! sql_ok "$s"; then finding CRIT db "$s: cannot connect as sysdba"; continue; fi
    pack_check "$s"; kv "Diagnostics Pack views used" "$([ "$PACK_OK" = 1 ] && echo yes || echo 'no (v$ and live sampling only)')"; kv_end
    say "database $s (pack=$PACK_OK)"
    db_live "$s"; live_samples "$s"
    [ "$PACK_OK" = 1 ] && db_hist "$s"
    [ -n "$SQL_ID" ] && sql_deep_dive "$s" "$SQL_ID"
    if db_is_cdb "$s"; then local p pdbs; pdbs="$(db_pdbs "$s")" || finding WARN db "$s: v\$pdbs could not be read - the per-PDB sections were NOT collected"; for p in $(printf '%s\n' "$pdbs" | head -8); do
      with_pdb "$p" sqlsec "$s" "pdb_${p}_top" "$s/$p: top SQL and sessions in this PDB now" "select * from (select sql_id, plan_hash_value, executions, round(elapsed_time/1e6) elapsed_s, round(elapsed_time/greatest(executions,1)/1000) avg_ms, buffer_gets, substr(regexp_replace(sql_text,'\s+',' '),1,60) sql_text from v\$sqlstats where con_id=sys_context('userenv','con_id') order by elapsed_time desc) where rownum<=10;
select nvl(username,'bg') username, count(*) sessions, sum(decode(status,'ACTIVE',1,0)) active from v\$session where type='USER' and con_id=sys_context('userenv','con_id') group by nvl(username,'bg') order by 2 desc fetch first 10 rows only;"
    done; fi
    sql_section_audit "$s"
  done
  middleware_threads
  findings_sync
  report_finish "perf-snapshot: $HOST $FROM .. $TO" "$MAKE_TAR" >/dev/null
  [ "$QUIET" = 1 ] || { echo; print_findings; }
  printf '\n%s\n' "$OUT/REPORT.md"
  findings_rc   # until now main returned the printf's 0 whatever the findings said
}
main "$@"
