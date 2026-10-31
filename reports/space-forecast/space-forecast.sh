#!/usr/bin/env bash
# space-forecast.sh - growth and days-to-full for tablespaces, FRA, ASM diskgroups, filesystems,
# archivelog generation and the fastest-growing segments. Read-only.
#
# Every run appends today's sizes to its own history (SPACE_HISTORY/<host>/*.csv), so after a few
# runs it can forecast without any licensed views. When the Diagnostics Pack is on it also uses
# dba_hist_tbspc_space_usage / dba_hist_seg_stat for up to 30 days of history straight away.
# Forecast = least-squares line over the window; days-to-90% and days-to-100% from the slope.
#
# Usage: space-forecast.sh [options]
#   --window N        days of history to fit (default 30)
#   --sid SID         one database (default: every running instance)
#   --pdb NAME        also the per-container tablespaces of this PDB (open PDBs otherwise)
#   --csv             print the main table as CSV on stdout (for a spreadsheet) instead of the summary
#   --history DIR     where the history CSVs live (default ~/space-forecast/history)
#   --out DIR  --no-pack  --quiet  --no-tar
#   --install-cron HH:MM   print the crontab line (daily history makes the forecast better)
#
# Config: space-forecast.conf or the shared oracle.conf: SPACE_OUT, SPACE_HISTORY, SPACE_WINDOW,
# SPACE_WARN_DAYS=30, SPACE_CRIT_DAYS=7, SQL_CONNECT, PDB, PERF_PACK.
# Output: SPACE_OUT/<host>_<ts>/REPORT.md (FINDINGS first) + raw/*.csv + tar.gz.

# shellcheck disable=SC2034  # QUIET/VERBOSE read by the lib
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="space-forecast"; VERSION="1.0.0"
# shellcheck source=../../lib/oracle-lib.sh
. "$SCRIPT_DIR/../../lib/oracle-lib.sh" || { echo "lib/oracle-lib.sh not found" >&2; exit 1; }

SPACE_OUT="${SPACE_OUT:-$HOME/space-forecast}"; SPACE_HISTORY="${SPACE_HISTORY:-$HOME/space-forecast/history}"
SPACE_WINDOW="${SPACE_WINDOW:-30}"; SPACE_WARN_DAYS="${SPACE_WARN_DAYS:-30}"; SPACE_CRIT_DAYS="${SPACE_CRIT_DAYS:-7}"
ONLY_SID=""; CSV=0; NO_PACK=0; MAKE_TAR=1; TODAY="$(date +%Y-%m-%d)"
# forecast rows (kind|db|name|used|max|pct|per_day_mb|days_to_90|days_to_100|points|since) go to $RAW/forecast.rows:
# add_forecast runs inside "| while" subshells, so a shell variable would lose them

usage() { usage_from_header "$0"; }
parse_args() {
  while [ $# -gt 0 ]; do case "$1" in
    --window) SPACE_WINDOW="$2"; shift 2;; --sid) ONLY_SID="$2"; shift 2;; --pdb) PDB="$2"; shift 2;; --csv) CSV=1; QUIET=1; shift;;
    --history) SPACE_HISTORY="$2"; shift 2;; --out) SPACE_OUT="$2"; shift 2;; --no-pack) NO_PACK=1; shift;;
    --quiet) QUIET=1; shift;; --no-tar) MAKE_TAR=0; shift;; --verbose) VERBOSE=1; shift;;
    --install-cron) printf '%s %s * * * %s --quiet --no-tar >/dev/null 2>&1\n' "${2#*:}" "${2%%:*}" "$SCRIPT_DIR/$TOOL.sh"; exit 0;;
    -h|--help) usage; exit 0;; *) die "Unknown option: $1";; esac; done
}

# history: one CSV per kind: date,db,name,used_mb,max_mb
hist_file() { mkdir -p "$SPACE_HISTORY/$HOST"; printf '%s/%s/%s.csv' "$SPACE_HISTORY" "$HOST" "$1"; }
hist_append() { # <kind> <db> <name> <used> <max>
  local f; f="$(hist_file "$1")"; [ -f "$f" ] || echo "date,db,name,used_mb,max_mb" >"$f"
  grep -q "^$TODAY,$2,$3," "$f" 2>/dev/null && sed -i.bak "/^$TODAY,$2,$3,/d" "$f" 2>/dev/null; rm -f "$f.bak"
  printf '%s,%s,%s,%s,%s\n' "$TODAY" "$2" "$3" "$4" "$5" >>"$f"
}
# fit <kind> <db> <name>: least squares over the window from the history; prints "per_day_mb points first_date"
fit() {
  local f; f="$(hist_file "$1")"; [ -f "$f" ] || { echo "0 0 -"; return; }
  local since; since="$(days_ago "$SPACE_WINDOW")"
  awk -F, -v db="$2" -v n="$3" -v since="$since" '
    function jdn(y,m,d) { a=int((14-m)/12); y2=y+4800-a; m2=m+12*a-3; return d+int((153*m2+2)/5)+365*y2+int(y2/4)-int(y2/100)+int(y2/400)-32045 }
    $2==db && $3==n && $1>=since { split($1,d,"-"); t=jdn(d[1]+0,d[2]+0,d[3]+0); k++; sx+=t; sy+=$4; sxx+=t*t; sxy+=t*$4; if (first=="" || $1<first) first=$1 }
    END { if (k<2) { print "0", k, (first==""?"-":first); exit } den=k*sxx-sx*sx; slope=(den==0)?0:(k*sxy-sx*sy)/den; printf "%.2f %d %s\n", slope, k, first }' "$f"
}
# days_to <used> <max> <per_day> <target pct>
days_to() { awk -v u="$1" -v m="$2" -v s="$3" -v p="$4" 'BEGIN{ if (m<=0) {print "-"; exit} if (s<=0) {print "never"; exit} d=(m*p/100-u)/s; if (d<0) print 0; else printf "%d", d }'; }
add_forecast() { # <kind> <db> <name> <used_mb> <max_mb>
  local kind="$1" db="$2" name="$3" used="$4" max="$5"
  hist_append "$kind" "$db" "$name" "$used" "$max"
  local slope pts first; read -r slope pts first <<<"$(fit "$kind" "$db" "$name")"
  local pct d90 d100; pct="$(pct_of "$used" "$max")"; d90="$(days_to "$used" "$max" "$slope" 90)"; d100="$(days_to "$used" "$max" "$slope" 100)"
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$kind" "$db" "$name" "$used" "$max" "$pct" "$slope" "$d90" "$d100" "$pts" "$first" >>"$RAW/forecast.rows"
  local lbl="$kind $db $name"
  case "$d100" in never|-) ;; *) [ "$d100" -le "$SPACE_CRIT_DAYS" ] && finding CRIT space "$lbl: full in ~$d100 days at +$(human_mb "${slope%.*}")/day (${pct}% now)" ;;
    esac
  case "$d100" in never|-) ;; *) [ "$d100" -gt "$SPACE_CRIT_DAYS" ] && [ "$d100" -le "$SPACE_WARN_DAYS" ] && finding WARN space "$lbl: full in ~$d100 days at +$(human_mb "${slope%.*}")/day (${pct}% now)" ;; esac
  [ "$pct" -ge 95 ] && finding CRIT space "$lbl: ${pct}% full now"; [ "$pct" -ge 90 ] && [ "$pct" -lt 95 ] && finding WARN space "$lbl: ${pct}% full now"
  return 0
}

# ---------------------------------------------------------------------------
collect_fs() {
  say "filesystems"
  df -Pk -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR>1 {print $6, int($3/1024), int(($3+$4)/1024)}' | while read -r mnt used max; do add_forecast fs "$HOST" "$mnt" "$used" "$max"; done
}
collect_db() {
  local sid="$1"; say "database $sid"
  sql_ok "$sid" || { finding CRIT db "$sid: cannot connect as sysdba"; return; }
  local pack=0; [ "$NO_PACK" = 0 ] && [[ "$(sql_val "$sid" "(select upper(value) from v\$parameter where name='control_management_pack_access')" 2>/dev/null)" == *DIAGNOSTIC* ]] && pack=1
  # tablespaces: root (or non-CDB) and each PDB
  local containers="" p; if db_is_cdb "$sid"; then containers="CDB\$ROOT $(db_pdbs "$sid" | tr '\n' ' ')"; [ -n "${PDB:-}" ] && containers="$containers $PDB"; else containers="$sid"; fi
  for p in $containers; do
    local label="$sid"; [ "$p" != "$sid" ] && [ "$p" != 'CDB$ROOT' ] && label="$sid/$p"
    with_pdb "$p" sql_lines "$sid" "select t.tablespace_name||'|'||round(nvl(u.used_mb,0))||'|'||round(f.max_mb) from dba_tablespaces t join (select tablespace_name, sum(greatest(bytes, decode(autoextensible,'YES',maxbytes,bytes)))/1048576 max_mb from dba_data_files group by tablespace_name) f on f.tablespace_name=t.tablespace_name left join (select tablespace_name, sum(bytes)/1048576 used_mb from dba_segments group by tablespace_name) u on u.tablespace_name=t.tablespace_name where t.contents<>'TEMPORARY';" 2>/dev/null \
      | while IFS='|' read -r ts used max; do [ -n "$ts" ] && add_forecast tablespace "$label" "$ts" "$used" "$max"; done
    # seed history from dba_hist_tbspc_space_usage when licensed and our own history is short
    if [ "$pack" = 1 ]; then
      with_pdb "$p" sql_lines "$sid" "select to_char(s.end_interval_time,'YYYY-MM-DD')||'|'||t.name||'|'||round(max(u.tablespace_usedsize)*(select value from v\$parameter where name='db_block_size')/1048576)||'|'||round(max(u.tablespace_maxsize)*(select value from v\$parameter where name='db_block_size')/1048576) from dba_hist_tbspc_space_usage u join dba_hist_snapshot s on s.snap_id=u.snap_id and s.dbid=u.dbid join v\$tablespace t on t.ts#=u.tablespace_id where s.end_interval_time>sysdate-$SPACE_WINDOW and u.dbid=(select dbid from v\$database) group by to_char(s.end_interval_time,'YYYY-MM-DD'), t.name;" 2>/dev/null \
        | while IFS='|' read -r d ts used max; do [ -n "$ts" ] || continue; local f; f="$(hist_file tablespace)"; grep -q "^$d,$label,$ts," "$f" 2>/dev/null || printf '%s,%s,%s,%s,%s\n' "$d" "$label" "$ts" "$used" "$max" >>"$f"; done
    fi
  done
  # FRA, ASM
  sql_lines "$sid" "select 'FRA|'||round((space_used-space_reclaimable)/1048576)||'|'||round(space_limit/1048576) from v\$recovery_file_dest where space_limit>0;" 2>/dev/null | while IFS='|' read -r n used max; do [ -n "$n" ] && add_forecast fra "$sid" "$n" "$used" "$max"; done
  sql_lines "$sid" "select name||'|'||(total_mb-free_mb)||'|'||total_mb from v\$asm_diskgroup where total_mb>0;" 2>/dev/null | while IFS='|' read -r n used max; do [ -n "$n" ] && add_forecast asm "$HOST" "$n" "$used" "$max"; done
  # archivelog generation per day
  h2 "$sid: archivelog generation per day (last $SPACE_WINDOW days)"
  sqlsec "$sid" arch "$sid: redo/archive per day" "select to_char(first_time,'YYYY-MM-DD') day, count(*) logs, round(sum(blocks*block_size)/1048576) mb from v\$archived_log where first_time>sysdate-$SPACE_WINDOW and dest_id=1 group by to_char(first_time,'YYYY-MM-DD') order by 1;
select 'avg MB/day: '||round(d.a)||'  max: '||round(d.m)||'  last 24h: '||l.mb from (select avg(mb) a, max(mb) m from (select sum(blocks*block_size)/1048576 mb from v\$archived_log where first_time>sysdate-$SPACE_WINDOW and dest_id=1 group by to_char(first_time,'YYYY-MM-DD'))) d, (select round(nvl(sum(blocks*block_size),0)/1048576) mb from v\$archived_log where first_time>sysdate-1 and dest_id=1) l;"
  local avg last; avg="$(grep -oE 'avg MB/day: [0-9]+' "$RAW/db_${sid}_arch.txt" | grep -oE '[0-9]+$')"; last="$(grep -oE 'last 24h: [0-9]+' "$RAW/db_${sid}_arch.txt" | grep -oE '[0-9]+$')"
  [ -n "$avg" ] && [ "$avg" -gt 0 ] && [ "${last:-0}" -gt "$((avg*2))" ] && finding WARN space "$sid: archivelog generation last 24h (${last} MB) is more than twice the $SPACE_WINDOW-day average (${avg} MB)"
  # fastest growing segments
  h2 "$sid: biggest and fastest-growing segments"
  if [ "$pack" = 1 ]; then
    sqlsec "$sid" seg_growth "$sid: segment growth from dba_hist_seg_stat (last $SPACE_WINDOW days)" "select * from (select o.owner, o.object_name, o.subobject_name part, o.object_type, round(sum(s.space_allocated_delta)/1048576) grown_mb, round(max(s.space_allocated_total)/1048576) now_mb from dba_hist_seg_stat s join dba_hist_seg_stat_obj o on o.obj#=s.obj# and o.dataobj#=s.dataobj# and o.dbid=s.dbid join dba_hist_snapshot sn on sn.snap_id=s.snap_id and sn.dbid=s.dbid where sn.end_interval_time>sysdate-$SPACE_WINDOW and s.dbid=(select dbid from v\$database) group by o.owner, o.object_name, o.subobject_name, o.object_type order by grown_mb desc) where rownum<=25;"
  else
    para "_no Diagnostics Pack: segment growth comes from this script's own history (raw/segments.csv) once it has run a few times_"
  fi
  sqlsec "$sid" seg_top "$sid: largest segments now (CDB-wide)" "select * from (select con_id, owner, segment_name, segment_type, tablespace_name, round(bytes/1048576) mb from cdb_segments order by bytes desc) where rownum<=25;
select 'audit: aud\$ '||(select round(sum(bytes)/1048576) from dba_segments where segment_name in ('AUD\$','FGA_LOG\$'))||' MB, unified audit '||(select round(nvl(sum(bytes),0)/1048576) from dba_segments where owner='AUDSYS')||' MB' from dual;
select 'APEX logs: '||round(nvl(sum(bytes),0)/1048576)||' MB' from cdb_segments where owner like 'APEX_%' and (segment_name like 'WWV_FLOW_ACTIVITY_LOG%' or segment_name like 'WWV_FLOW_DEBUG_MESSAGES%' or segment_name like 'WWV_FLOW_SESSIONS%' or segment_name like 'WWV_FLOW_WORKSHEET_NOTIFY%');
select 'recyclebin: '||round(nvl(sum(space),0)*8/1024)||' MB' from dba_recyclebin;
select 'temp used now: '||u.mb||' MB; temp max: '||m.mb from (select round(nvl(sum(blocks),0)*8/1024) mb from v\$sort_usage) u, (select round(sum(decode(autoextensible,'YES',maxbytes,bytes))/1048576) mb from dba_temp_files) m;
select 'undo: '||t.mb||' MB total, '||a.mb||' MB active/unexpired, retention '||p.value||' s' from (select round(sum(bytes)/1048576) mb from dba_data_files where tablespace_name=(select value from v\$parameter where name='undo_tablespace')) t, (select round(nvl(sum(bytes),0)/1048576) mb from dba_undo_extents where status in ('ACTIVE','UNEXPIRED')) a, (select value from v\$parameter where name='undo_retention') p;"
  # top segments into history for a pack-free growth view
  sql_lines "$sid" "select owner||'.'||segment_name||'|'||round(sum(bytes)/1048576) from (select * from cdb_segments order by bytes desc) where rownum<=50 group by owner, segment_name;" 2>/dev/null | while IFS='|' read -r n mb; do [ -n "$n" ] && hist_append segment "$sid" "$n" "$mb" 0; done
  sql_checks "$sid" "$sid" "select 'CHECK|WARN|'||count(*)||' datafile(s) at their autoextend maximum (cannot grow)' from dba_data_files where autoextensible='YES' and bytes>=maxbytes*0.99 having count(*)>0;
select 'CHECK|WARN|'||count(*)||' datafile(s) with autoextend OFF in '||listagg(distinct tablespace_name, ',') within group (order by tablespace_name) from dba_data_files where autoextensible='NO' having count(*)>0;
select 'CHECK|WARN|datafiles '||c.n||' of db_files='||p.value from (select count(*) n from dba_data_files) c, (select value from v\$parameter where name='db_files') p where c.n>to_number(p.value)*0.9;
select 'CHECK|INFO|recyclebin holds '||round(sum(space)*8/1024)||' MB' from dba_recyclebin having sum(space)*8/1024>5000;
select 'CHECK|WARN|aud\$ is '||round(sum(bytes)/1048576)||' MB - purge with DBMS_AUDIT_MGMT' from dba_segments where segment_name='AUD\$' having sum(bytes)/1048576>5000;
select 'CHECK|WARN|APEX activity/debug logs are '||round(sum(bytes)/1048576)||' MB - check the APEX purge jobs' from cdb_segments where owner like 'APEX_%' and (segment_name like 'WWV_FLOW_ACTIVITY_LOG%' or segment_name like 'WWV_FLOW_DEBUG_MESSAGES%') having sum(bytes)/1048576>5000;"
}

write_tables() {
  h1 "Forecast (window $SPACE_WINDOW days, history points per object in the last column)"
  para "Sorted by days to 100 %. Growth is a least-squares slope over the history; fewer than 3 points means the slope is a guess. Run daily (\`--install-cron\`) and it gets better."
  table_head "kind" "database" "object" "used" "max" "% now" "MB/day" "days to 90%" "days to 100%" "points" "since"
  sort -t'|' -k9,9n "$RAW/forecast.rows" 2>/dev/null | while IFS='|' read -r kind db name used max pct slope d90 d100 pts first; do
    [ -n "$kind" ] && table_row "$kind" "$db" "$name" "$(human_mb "$used")" "$(human_mb "$max")" "$pct" "$slope" "$d90" "$d100" "$pts" "$first"
  done
  echo >>"$REPORT"
  { echo "kind,database,object,used_mb,max_mb,pct_now,mb_per_day,days_to_90,days_to_100,points,since"; tr '|' ',' <"$RAW/forecast.rows" 2>/dev/null; } >"$RAW/forecast.csv"
  cp "$(hist_file segment)" "$RAW/segments.csv" 2>/dev/null
  h2 "Segment growth from the script's own history"
  local f; f="$(hist_file segment)"
  if [ -f "$f" ] && [ "$(cut -d, -f1 "$f" | sort -u | wc -l)" -gt 2 ]; then
    fence_start
    awk -F, 'NR>1 { k=$2"|"$3; if (!(k in first)) { first[k]=$4; fd[k]=$1 } last[k]=$4; ld[k]=$1 } END { for (k in last) if (ld[k]!=fd[k]) printf "%8d MB  %s -> %s  %s\n", last[k]-first[k], fd[k], ld[k], k }' "$f" | sort -rn | head -25 >>"$REPORT"
    fence_end
  else para "_needs at least three days of history_"; fi
}

main() {
  load_config; parse_args "$@"
  report_init "$SPACE_OUT/${HOST}_$(date '+%Y%m%d_%H%M%S')"
  say "space-forecast $VERSION window ${SPACE_WINDOW}d history $SPACE_HISTORY/$HOST -> $OUT"
  collect_fs
  local sids s; sids="$(db_instances | grep -vE '^\+ASM|^-MGMTDB|^\+APX')"; [ -n "$ONLY_SID" ] && sids="$ONLY_SID"
  for s in $sids; do collect_db "$s"; done
  findings_sync
  write_tables
  report_finish "space-forecast: $HOST $TODAY" "$MAKE_TAR" >/dev/null
  if [ "$CSV" = 1 ]; then cat "$RAW/forecast.csv"; else print_findings; printf '\n%s\n' "$OUT/REPORT.md"; fi
}
main "$@"
