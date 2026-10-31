#!/usr/bin/env bash
# db-health-daily.sh - the 60-second daily check, built for cron. Read-only.
# Looks at every running database on the host (plus listener, ORDS, WebLogic, Grid if present),
# writes a one-screen SUMMARY.md and a DELTA.md against the previous run (new / cleared findings,
# new alert-log errors since last time), and exits 2 on CRIT, 1 on WARN, 0 when clean.
#
# Usage: db-health-daily.sh [options]
#   --out DIR            where runs go (default ~/db-health-daily); each run is DIR/<YYYYMMDD_HHMMSS>/
#   --sid SID            only this database (default: every running instance)
#   --pdb NAME           also run the per-container checks in this PDB (open PDBs are found anyway)
#   --mail ADDR          send SUMMARY.md with mail/mailx when there is anything CRIT/WARN
#   --always-mail        ...even when clean
#   --cron               quiet; only the exit code and the files
#   --install-cron HH:MM print the crontab line for a daily run (does not install it)
#   --quiet  --no-tar
#
# Config: db-health-daily.conf next to the script or ~/.db-health-daily.conf (and the shared
# oracle.conf / ~/.oracle.conf). Keys: HEALTH_OUT, SQL_CONNECT, PDB, ORDS_URL, ADMIN_URL,
# FS_WARN=85 FS_CRIT=95 TS_WARN=85 TS_CRIT=95 FRA_WARN=85 FRA_CRIT=95 BACKUP_WARN_DAYS=2 (Exascale vaults use FS_*; ESCLI, EXA_WALLET, EXA_POOL_FREE_PCT=12)
# BACKUP_CRIT_DAYS=7 DG_LAG_WARN_MIN=30 PROC_WARN=80 MAIL_TO.
# Feed DELTA.md (or SUMMARY.md) to Claude: "here is today's db-health-daily delta, what needs doing?"

# shellcheck disable=SC2034  # QUIET/VERBOSE/FORCE are read by the lib
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="db-health-daily"; VERSION="1.0.0"
# shellcheck source=../../lib/oracle-lib.sh
. "$SCRIPT_DIR/../../lib/oracle-lib.sh" || { echo "lib/oracle-lib.sh not found next to $SCRIPT_DIR" >&2; exit 1; }

HEALTH_OUT="${HEALTH_OUT:-$HOME/db-health-daily}"
FS_WARN="${FS_WARN:-85}"; FS_CRIT="${FS_CRIT:-95}"; TS_WARN="${TS_WARN:-85}"; TS_CRIT="${TS_CRIT:-95}"
FRA_WARN="${FRA_WARN:-85}"; FRA_CRIT="${FRA_CRIT:-95}"; BACKUP_WARN_DAYS="${BACKUP_WARN_DAYS:-2}"; BACKUP_CRIT_DAYS="${BACKUP_CRIT_DAYS:-7}"
DG_LAG_WARN_MIN="${DG_LAG_WARN_MIN:-30}"; PROC_WARN="${PROC_WARN:-80}"
ONLY_SID=""; MAIL_TO="${MAIL_TO:-}"; ALWAYS_MAIL=0; CRON=0; MAKE_TAR=1
STATUS_LINES=""   # one line per database for the summary

usage() { usage_from_header "$0"; }
parse_args() {
  while [ $# -gt 0 ]; do case "$1" in
    --out) HEALTH_OUT="$2"; shift 2;; --sid) ONLY_SID="$2"; shift 2;; --pdb) PDB="$2"; shift 2;;
    --mail) MAIL_TO="$2"; shift 2;; --always-mail) ALWAYS_MAIL=1; shift;; --cron) CRON=1; QUIET=1; shift;;
    --install-cron) printf '%s %s * * * %s --cron --mail %s >/dev/null 2>&1\n' "${2#*:}" "${2%%:*}" "$SCRIPT_DIR/$TOOL.sh" "${MAIL_TO:-dba@example.com}"; exit 0;;
    --quiet) QUIET=1; shift;; --no-tar) MAKE_TAR=0; shift;; --verbose) VERBOSE=1; shift;;
    -h|--help) usage; exit 0;; *) die "Unknown option: $1";; esac; done
}

status_line() { STATUS_LINES="${STATUS_LINES}| $1 | $2 | $3 |"$'\n'; }

# ---------------------------------------------------------------------------
check_host() {
  h2 "Host"
  local mem_total mem_avail swap_total swap_used
  mem_total="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null)"; mem_avail="$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null)"
  swap_total="$(awk '/SwapTotal/{print $2}' /proc/meminfo 2>/dev/null)"; swap_used="$(awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{print t-f}' /proc/meminfo 2>/dev/null)"
  kv "load" "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || uptime)"; kv "cpus" "$(nproc 2>/dev/null)"
  [ -n "$mem_total" ] && kv "memory available" "$((mem_avail/1024)) MB of $((mem_total/1024)) MB"
  [ -n "$swap_total" ] && [ "$swap_total" -gt 0 ] && kv "swap used" "$((swap_used/1024)) MB of $((swap_total/1024)) MB"
  kv_end
  [ -n "$mem_total" ] && [ "$(pct_of "$mem_avail" "$mem_total")" -lt 10 ] && finding CRIT host "less than 10% RAM available"
  [ -n "$swap_total" ] && [ "$swap_total" -gt 0 ] && [ "$(pct_of "$swap_used" "$swap_total")" -gt 50 ] && finding WARN host "swap more than half used"
  local load1 cpus; load1="$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)"; cpus="$(nproc 2>/dev/null || echo 1)"
  [ -n "$load1" ] && awk -v l="$load1" -v c="$cpus" 'BEGIN{exit !(l > c*2)}' && finding WARN host "load $load1 is over twice the CPU count ($cpus)"
  section_sh fs "df -hP -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null || df -hP"
  df -P -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR>1 {gsub("%","",$5); print $5, $6}' | while read -r pct mnt; do
    if [ "$pct" -ge "$FS_CRIT" ]; then finding CRIT host "filesystem $mnt ${pct}% full"; elif [ "$pct" -ge "$FS_WARN" ]; then finding WARN host "filesystem $mnt ${pct}% full"; fi
  done
  df -iP -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR>1 {gsub("%","",$5); if ($5+0 >= 90) print $5, $6}' | while read -r pct mnt; do finding CRIT host "filesystem $mnt ${pct}% inodes used"; done
  local failed; failed="$(systemctl --failed --no-legend 2>/dev/null | wc -l | tr -d ' ')"; [ "${failed:-0}" -gt 0 ] && finding WARN host "$failed failed systemd unit(s): $(systemctl --failed --no-legend 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
  if [ -n "$SUDO" ] || [ "$(id -u)" = 0 ]; then
    $SUDO journalctl -k --since '-1d' --no-pager -q 2>/dev/null | grep -iE 'out of memory|killed process|I/O error|hung task' >"$RAW/kernel.txt"
    [ -s "$RAW/kernel.txt" ] && finding CRIT host "kernel log last 24h: $(head -1 "$RAW/kernel.txt" | cut -c1-100)"
  fi
  # process inventory delta: what was running last time and is not now
  ps -eo args 2>/dev/null | grep -oE '^ora_pmon_[A-Za-z0-9_$]+|^asm_pmon_[^ ]+|^[^ ]*/bin/tnslsn[r] [^ ]+|-Dweblogic\.Name=[^ ]+|ords\.wa[r]|weblogic\.NodeManage[r]|/bin/(ocss[d]|crs[d]|ohas[d])|[^ ]*/mg[r] PARAMFILE|emagen[t]|/tf[a]' | sort -u >"$OUT/processes.txt"
  if [ -n "$PREV" ] && [ -f "$PREV/processes.txt" ]; then
    comm -23 "$PREV/processes.txt" "$OUT/processes.txt" | while read -r p; do finding CRIT host "process present last run, gone now: $p"; done
  fi
}

# Exascale: vault used vs provisioned and pool free space, through escli with the oracle wallet (full picture: operations/exascale-space)
check_exascale() {
  local esc="${ESCLI:-}"; [ -n "$esc" ] || for c in escli /opt/oracle/dbserver/dbms/bin/escli /opt/oracle/cell/cellsrv/bin/escli /usr/sbin/escli; do command -v "$c" >/dev/null 2>&1 && { esc="$c"; break; }; done
  [ -n "$esc" ] || return 0
  local w=(); [ -n "${EXA_WALLET:-}" ] && w=(--wallet "$EXA_WALLET")
  h2 "Exascale"
  to 60 "$esc" "${w[@]}" lsvault --detail </dev/null >"$RAW/exa_vaults.txt" 2>&1 || { kv "escli" "lsvault failed: $(head -1 "$RAW/exa_vaults.txt" | cut -c1-120)"; kv_end; return 0; }
  to 60 "$esc" "${w[@]}" lsstoragepool --detail </dev/null >"$RAW/exa_pools.txt" 2>&1
  # attr value lines -> "vault|media|used|prov|pct"
  awk 'function b(v,  u,n,m){ if (v=="unlimited") return "unlimited"; n=v; u=""; if (v ~ /[A-Za-z]+$/) { match(v,/[A-Za-z]+$/); u=toupper(substr(v,RSTART)); n=substr(v,1,RSTART-1) } m=1; if (u ~ /^K/) m=1024; else if (u ~ /^M/) m=1048576; else if (u ~ /^G/) m=1073741824; else if (u ~ /^T/) m=1099511627776; else if (u ~ /^P/) m=1125899906842624; return n*m }
    function out(  i){ if (name=="") return; split("HC EF XT",t," "); for (i in t) { u=b(used[t[i]]); p=b(prov[t[i]]); if (u==0 && (p==0 || p=="unlimited")) continue; printf "%s|%s|%.0f|%s|%s\n", name, t[i], u, p, (p=="unlimited"||p==0)?"-":int(u*100/p) } name=""; delete used; delete prov }
    /^[[:space:]]*$/ { out(); next } $1=="name" { out(); name=$2 } $1 ~ /^spaceUsed(HC|EF|XT)$/ { used[substr($1,10)]=$2 } $1 ~ /^spaceProv(HC|EF|XT)$/ { prov[substr($1,10)]=$2 } END { out() }' "$RAW/exa_vaults.txt" >"$RAW/exa_vaults.csv"
  awk 'function b(v,  u,n,m){ n=v; u=""; if (v ~ /[A-Za-z]+$/) { match(v,/[A-Za-z]+$/); u=toupper(substr(v,RSTART)); n=substr(v,1,RSTART-1) } m=1; if (u ~ /^K/) m=1024; else if (u ~ /^M/) m=1048576; else if (u ~ /^G/) m=1073741824; else if (u ~ /^T/) m=1099511627776; else if (u ~ /^P/) m=1125899906842624; return n*m }
    function out(){ if (name=="" || raw==0) return; printf "%s|%s|%d\n", name, media, (raw-used)*100/raw; name="" }
    /^[[:space:]]*$/ { out(); next } $1=="name" { out(); name=$2; raw=0; used=0 } $1=="mediaType" { media=$2 } $1=="spaceRaw" { raw=b($2) } $1=="spaceUsed" { used=b($2) } END { out() }' "$RAW/exa_pools.txt" >"$RAW/exa_pools.csv"
  local v m u p pct; while IFS='|' read -r v m u p pct; do
    [ -n "$v" ] || continue; kv "vault @$v $m" "$(awk -v u="$u" -v p="$p" 'BEGIN{printf "%.1f TB used of %s", u/1099511627776, (p=="unlimited"?p:sprintf("%.1f TB", p/1099511627776))}') (${pct}%)"
    [ "$pct" = "-" ] && continue
    if [ "$pct" -ge "$FS_CRIT" ]; then finding CRIT exascale "vault @$v $m ${pct}% of provisioned space used - operations/exascale-space/exascale-space.sh plan"
    elif [ "$pct" -ge "$FS_WARN" ]; then finding WARN exascale "vault @$v $m ${pct}% of provisioned space used"; fi
  done <"$RAW/exa_vaults.csv"
  local n f; while IFS='|' read -r n m f; do
    [ -n "$n" ] || continue; kv "pool $n $m" "${f}% free"
    if [ "$f" -lt 5 ]; then finding CRIT exascale "storage pool $n ($m) only ${f}% free"; elif [ "$f" -lt "${EXA_POOL_FREE_PCT:-12}" ]; then finding WARN exascale "storage pool $n ($m) ${f}% free, below the ${EXA_POOL_FREE_PCT:-12}% rebalance reserve"; fi
  done <"$RAW/exa_pools.csv"
  kv_end
}

check_listener() {
  local n; n="$(listener_homes | wc -l | tr -d ' ')"
  if [ "$n" = 0 ]; then [ -n "$(db_instances)" ] && finding CRIT db "no tnslsnr process"; return; fi
  listener_homes | while read -r h lsn; do
    ORACLE_HOME="$h" to 30 "$h/bin/lsnrctl" status "$lsn" >"$RAW/lsnr_$lsn.txt" 2>&1
    grep -qE 'TNS-12541|TNS-12560|TNS-00511' "$RAW/lsnr_$lsn.txt" && finding CRIT db "listener $lsn not responding"
    grep -qE 'The listener supports no services' "$RAW/lsnr_$lsn.txt" && finding CRIT db "listener $lsn has no services registered"
  done
}

# alert log cursor: report only lines added since the previous run
check_alert_log() {
  local sid="$1" alert off=0 newlines
  alert="$(sql_lines "$sid" "select value||'/alert_${sid}.log' from v\$diag_info where name='Diag Trace';" 2>/dev/null | head -1)"
  [ -f "$alert" ] || alert="$(find /u01/app/oracle/diag/rdbms /opt/oracle/diag/rdbms -name "alert_${sid}.log" 2>/dev/null | head -1)"
  [ -f "$alert" ] || { kv "alert log" "not found"; return; }
  local size; size="$(file_size "$alert")"
  [ -n "$PREV" ] && [ -f "$PREV/alert_${sid}.offset" ] && off="$(cat "$PREV/alert_${sid}.offset")"
  [ "$off" -gt "$size" ] && off=0   # rotated
  printf '%s' "$size" >"$OUT/alert_${sid}.offset"
  tail -c +"$((off+1))" "$alert" 2>/dev/null >"$RAW/alert_${sid}.new"
  newlines="$(wc -l <"$RAW/alert_${sid}.new" | tr -d ' ')"
  grep -aE 'ORA-[0-9]+|TNS-[0-9]+|Errors in file|Checkpoint not complete|deadlock|Instance terminated|archiver (stuck|error)|unable to extend|ORA-00020' "$RAW/alert_${sid}.new" >"$RAW/alert_${sid}.errors"
  local n; n="$(wc -l <"$RAW/alert_${sid}.errors" | tr -d ' ')"
  kv "alert log" "$alert"; kv "new lines since last run" "$newlines"; kv "of which error lines" "$n"; kv_end
  if [ "$n" -gt 0 ]; then
    h3 "New alert-log errors ($sid)"; fence_start
    sed -E 's/^[0-9T:. -]+//; s/[0-9]{4,}/N/g' "$RAW/alert_${sid}.errors" | cut -c1-140 | sort | uniq -c | sort -rn | head -15 >>"$REPORT"; fence_end
    local f="$RAW/alert_${sid}.errors"
    grep -qE 'ORA-00257|archiver (stuck|error)' "$f" && finding CRIT db "$sid: archiver stuck (ORA-00257)"
    grep -qE 'ORA-04031|ORA-04030' "$f" && finding CRIT db "$sid: ORA-04031/4030 memory errors"
    grep -qE 'ORA-00020' "$f" && finding CRIT db "$sid: ORA-00020 max processes"
    grep -qE 'ORA-0165[234]|unable to extend' "$f" && finding CRIT db "$sid: unable to extend (tablespace full)"
    grep -qE 'ORA-00600|ORA-07445' "$f" && finding CRIT db "$sid: ORA-600/7445 internal errors ($(grep -cE 'ORA-00600|ORA-07445' "$f"))"
    grep -qE 'ORA-01555' "$f" && finding WARN db "$sid: ORA-01555 snapshot too old"
    grep -qE 'ORA-00060|deadlock' "$f" && finding WARN db "$sid: deadlocks"
    grep -qE 'Instance terminated|Shutting down instance' "$f" && finding WARN db "$sid: instance shutdown/termination in the new alert lines"
    grep -qE 'ORA-28365|ORA-28374|wallet is not open' "$f" && finding CRIT db "$sid: TDE wallet errors"
    grep -qE 'Checkpoint not complete' "$f" && finding WARN db "$sid: checkpoint not complete ($(grep -c 'Checkpoint not complete' "$f")x)"
    [ "$n" -gt 200 ] && finding WARN db "$sid: $n new error lines in the alert log since last run"
  fi
}

check_db() {
  local sid="$1"
  h2 "Database $sid"
  if ! sql_ok "$sid"; then finding CRIT db "$sid: cannot connect as sysdba"; status_line "$sid" "DOWN/UNREACHABLE" "sqlplus / as sysdba failed"; check_alert_log "$sid"; return; fi
  local ov; ov="$(sql_lines "$sid" "select status||'|'||database_status||'|'||to_char(startup_time,'YYYY-MM-DD HH24:MI')||'|'||(select open_mode||'|'||database_role||'|'||log_mode from v\$database) from v\$instance;" 2>/dev/null | head -1)"
  kv "instance" "$ov"
  sqlsec "$sid" core "$sid: the numbers" "select 'sessions' k, current_utilization||' / '||limit_value v from v\$resource_limit where resource_name='sessions'
union all select 'processes', current_utilization||' / '||limit_value from v\$resource_limit where resource_name='processes'
union all select 'FRA % used (net)', to_char(round((space_used-space_reclaimable)*100/space_limit)) from v\$recovery_file_dest where space_limit>0
union all select 'last DB backup', nvl(to_char(max(start_time),'YYYY-MM-DD HH24:MI'),'never') from v\$rman_backup_job_details where status like 'COMPLETED%' and input_type like 'DB%'
union all select 'last ARCH backup', nvl(to_char(max(start_time),'YYYY-MM-DD HH24:MI'),'never') from v\$rman_backup_job_details where status like 'COMPLETED%' and input_type in ('ARCHIVELOG','DB INCR','DB FULL')
union all select 'failed RMAN jobs 24h', to_char(count(*)) from v\$rman_backup_job_details where start_time>sysdate-1 and status not like 'COMPLETED%' and status<>'RUNNING'
union all select 'blocked sessions', to_char(count(*)) from v\$session where blocking_session is not null
union all select 'active user sessions', to_char(count(*)) from v\$session where status='ACTIVE' and type='USER'
union all select 'invalid objects', to_char(count(*)) from dba_objects where status<>'VALID'
union all select 'failed scheduler runs 24h', to_char(count(*)) from dba_scheduler_job_run_details where status<>'SUCCEEDED' and log_date>sysdate-1
union all select 'outstanding alerts', to_char(count(*)) from dba_outstanding_alerts
union all select 'DG apply lag', nvl((select value from v\$dataguard_stats where name='apply lag'),'n/a') from dual
union all select 'DG transport lag', nvl((select value from v\$dataguard_stats where name='transport lag'),'n/a') from dual
union all select 'archive dest errors', to_char(count(*)) from v\$archive_dest_status where status='ERROR'
union all select 'guaranteed restore points', to_char(count(*)) from v\$restore_point where guarantee_flashback_database='YES'
union all select 'PDBs not READ WRITE', to_char(count(*)) from v\$pdbs where open_mode<>'READ WRITE' and name<>'PDB\$SEED';
select tablespace_name, pct_max from (select t.tablespace_name, round(u.used_mb*100/f.max_mb) pct_max from dba_tablespaces t join (select tablespace_name, sum(greatest(bytes, decode(autoextensible,'YES',maxbytes,bytes)))/1048576 max_mb from dba_data_files group by tablespace_name) f on f.tablespace_name=t.tablespace_name left join (select tablespace_name, sum(bytes)/1048576 used_mb from dba_segments group by tablespace_name) u on u.tablespace_name=t.tablespace_name where t.contents<>'TEMPORARY') where pct_max>=$TS_WARN order by 2 desc;
select name, state, round((total_mb-free_mb)*100/total_mb) pct_used, offline_disks from v\$asm_diskgroup where total_mb>0;"
  sql_checks "$sid" "$sid" "select 'CHECK|'||case when pct>=$TS_CRIT then 'CRIT' else 'WARN' end||'|tablespace '||tablespace_name||' '||pct||'% of max' from (select t.tablespace_name, round(u.used_mb*100/f.max_mb) pct from dba_tablespaces t join (select tablespace_name, sum(greatest(bytes, decode(autoextensible,'YES',maxbytes,bytes)))/1048576 max_mb from dba_data_files group by tablespace_name) f on f.tablespace_name=t.tablespace_name join (select tablespace_name, sum(bytes)/1048576 used_mb from dba_segments group by tablespace_name) u on u.tablespace_name=t.tablespace_name where t.contents<>'TEMPORARY') where pct>=$TS_WARN;
select 'CHECK|'||case when p>=$FRA_CRIT then 'CRIT' else 'WARN' end||'|FRA '||p||'% full' from (select round((space_used-space_reclaimable)*100/space_limit) p from v\$recovery_file_dest where space_limit>0) where p>=$FRA_WARN;
select 'CHECK|WARN|ASM '||name||' '||round((total_mb-free_mb)*100/total_mb)||'% used' from v\$asm_diskgroup where total_mb>0 and (total_mb-free_mb)*100/total_mb>=$FS_WARN;
select 'CHECK|CRIT|ASM '||name||' has '||offline_disks||' offline disk(s)' from v\$asm_diskgroup where offline_disks>0;
select 'CHECK|'||case when p>=$FS_CRIT then 'CRIT' else 'WARN' end||'|Exascale vault '||vault_name||' HC '||p||'% of provisioned (V\$EXA_VAULT)' from (select vault_name, round(hc_space_used*100/hc_space_prov) p from v\$exa_vault where hc_space_prov>0) where p>=$FS_WARN;
select 'CHECK|'||case when current_utilization*100/to_number(limit_value)>=95 then 'CRIT' else 'WARN' end||'|'||resource_name||' '||current_utilization||' of '||limit_value from v\$resource_limit where resource_name in ('processes','sessions') and limit_value not like '%UNLIMITED%' and current_utilization*100/to_number(limit_value)>=$PROC_WARN;
select 'CHECK|CRIT|'||count(*)||' session(s) blocked >60s by sid '||blocking_session from v\$session where blocking_session is not null and seconds_in_wait>60 group by blocking_session;
select 'CHECK|'||case when nvl(max(start_time),sysdate-99)<sysdate-$BACKUP_CRIT_DAYS then 'CRIT' else 'WARN' end||'|last DB backup '||nvl(to_char(max(start_time),'YYYY-MM-DD'),'never') from v\$rman_backup_job_details where status like 'COMPLETED%' and input_type like 'DB%' having nvl(max(start_time),sysdate-99)<sysdate-$BACKUP_WARN_DAYS;
select 'CHECK|CRIT|RMAN '||input_type||' job at '||to_char(start_time,'YYYY-MM-DD HH24:MI')||' '||status from v\$rman_backup_job_details where start_time>sysdate-1 and status not like 'COMPLETED%' and status<>'RUNNING';
select 'CHECK|CRIT|archive dest '||dest_id||' '||error from v\$archive_dest_status where status='ERROR';
select 'CHECK|CRIT|Data Guard '||name||' '||value from v\$dataguard_stats where name in ('apply lag','transport lag') and value is not null and (substr(value,2,2)<>'00' or to_number(substr(value,5,2))>=$DG_LAG_WARN_MIN);
select 'CHECK|CRIT|standby without MRP' from v\$database where database_role='PHYSICAL STANDBY' and not exists (select 1 from v\$managed_standby where process like 'MRP%');
select 'CHECK|CRIT|TDE keystore '||status||' (con '||con_id||')' from v\$encryption_wallet where wallet_type<>'UNKNOWN' and status not in ('OPEN','OPEN_NO_MASTER_KEY','NOT_AVAILABLE') and con_id<>2;
select 'CHECK|CRIT|'||username||' is '||account_status from dba_users where username in ('APEX_PUBLIC_USER','ORDS_PUBLIC_USER','APEX_LISTENER','APEX_REST_PUBLIC_USER','ORDS_METADATA') and account_status<>'OPEN';
select 'CHECK|WARN|'||username||' expires '||to_char(expiry_date,'YYYY-MM-DD') from dba_users where expiry_date between sysdate and sysdate+7 and (oracle_maintained='N' or username like 'APEX%' or username like 'ORDS%' or username='DBSNMP');
select 'CHECK|WARN|'||count(*)||' failed scheduler run(s) last 24h' from dba_scheduler_job_run_details where status<>'SUCCEEDED' and log_date>sysdate-1 having count(*)>0;
select 'CHECK|WARN|'||count(*)||' PDB(s) not READ WRITE' from v\$pdbs where open_mode<>'READ WRITE' and name<>'PDB\$SEED' having count(*)>0;
select 'CHECK|CRIT|alert: '||substr(reason,1,100) from dba_outstanding_alerts where creation_time>sysdate-1 and rownum<=5;
select 'CHECK|WARN|'||count(*)||' datafile(s) in hot backup mode' from v\$backup where status='ACTIVE' having count(*)>0;
select 'CHECK|WARN|guaranteed restore point '||name||' is '||round(sysdate-time)||' days old' from v\$restore_point where guarantee_flashback_database='YES' and time<sysdate-7;"
  # invalid-object delta
  local inv; inv="$(sql_val "$sid" "(select count(*) from dba_objects where status<>'VALID')" 2>/dev/null)"; printf '%s' "$inv" >"$OUT/invalid_${sid}.txt"
  if [ -n "$PREV" ] && [ -f "$PREV/invalid_${sid}.txt" ]; then local pinv; pinv="$(cat "$PREV/invalid_${sid}.txt")"; [ "${inv:-0}" -gt "$((${pinv:-0}+10))" ] && finding WARN db "$sid: invalid objects went from $pinv to $inv"; fi
  check_alert_log "$sid"
  # per PDB: accounts + tablespaces
  if db_is_cdb "$sid"; then
    local p pdbs; pdbs="$(db_pdbs "$sid")"; [ -n "${PDB:-}" ] && pdbs="$(printf '%s\n%s\n' "$PDB" "$pdbs" | awk '!s[$0]++')"
    for p in $pdbs; do
      with_pdb "$p" sql_checks "$sid" "$sid/$p" "select 'CHECK|'||case when pct>=$TS_CRIT then 'CRIT' else 'WARN' end||'|tablespace '||tablespace_name||' '||pct||'% of max' from (select t.tablespace_name, round(u.used_mb*100/f.max_mb) pct from dba_tablespaces t join (select tablespace_name, sum(greatest(bytes, decode(autoextensible,'YES',maxbytes,bytes)))/1048576 max_mb from dba_data_files group by tablespace_name) f on f.tablespace_name=t.tablespace_name join (select tablespace_name, sum(bytes)/1048576 used_mb from dba_segments group by tablespace_name) u on u.tablespace_name=t.tablespace_name where t.contents<>'TEMPORARY') where pct>=$TS_WARN;
select 'CHECK|CRIT|'||username||' is '||account_status from dba_users where username in ('APEX_PUBLIC_USER','ORDS_PUBLIC_USER','APEX_LISTENER','APEX_REST_PUBLIC_USER','ORDS_METADATA') and account_status<>'OPEN';
select 'CHECK|WARN|APEX job '||job_name||' '||state||' failures '||failure_count from dba_scheduler_jobs where owner like 'APEX%' and (state in ('BROKEN','FAILED') or failure_count>0);"
    done
  fi
  local role mode; role="$(printf '%s' "$ov" | cut -d'|' -f5)"; mode="$(printf '%s' "$ov" | cut -d'|' -f4)"
  status_line "$sid" "$mode / $role" "$(grep -c "^CRIT|db|$sid" "$FINDINGS_FILE") crit, $(grep -c "^WARN|db|$sid" "$FINDINGS_FILE") warn"
}

check_middleware() {
  h2 "Middleware"
  if ords_detect; then
    local code; code="$(url_code "$ORDS_URL")"; kv "ORDS" "pid ${ORDS_PID:-NOT RUNNING}, $ORDS_URL -> HTTP ${code:-none}"
    [ -z "$ORDS_PID" ] && finding CRIT ords "ORDS not running"
    case "$code" in 200|30[0-9]) ;; 503) finding CRIT ords "ORDS 503 at $ORDS_URL (pool down: locked user / DB / listener)";; *) [ -n "$ORDS_PID" ] && finding CRIT ords "ORDS answers HTTP ${code:-none} at $ORDS_URL";; esac
  fi
  local h d; for h in $(wls_homes); do for d in $(wls_domains "$h"); do
    local cfg="$d/config/config.xml" running; running="$(wls_running "$d")"
    kv "WebLogic $(basename "$d")" "running: $(printf '%s\n' "$running" | awk '{print $1}' | tr '\n' ' ')"
    [ -z "$running" ] && finding CRIT wls "$(basename "$d"): no server JVM running"
    [ -z "$(nodemanager_pid)" ] && finding WARN wls "Node Manager not running"
    local admin port url; admin="$(wls_admin_name "$d")"; port="$(wls_servers "$d" | awk -v a="$admin" '$1==a{print $2}')"; url="${ADMIN_URL:-http://localhost:${port:-7001}}"
    [ -n "$running" ] && [ "$(url_code "$url/weblogic/ready")" != 200 ] && finding WARN wls "$(basename "$d"): $url/weblogic/ready not 200"
    local s; for s in "$d"/servers/*/logs/*.log; do [ -f "$s" ] || continue; local sn; sn="$(basename "$(dirname "$(dirname "$s")")")"
      local size off=0; size="$(file_size "$s")"; [ -n "$PREV" ] && [ -f "$PREV/wls_${sn}.offset" ] && off="$(cat "$PREV/wls_${sn}.offset")"; [ "$off" -gt "$size" ] && off=0; printf '%s' "$size" >"$OUT/wls_${sn}.offset"
      tail -c +"$((off+1))" "$s" 2>/dev/null | grep -aE '<Error>|<Critical>|OutOfMemoryError|STUCK|Too many open files' >"$RAW/wls_${sn}.errors"
      local n; n="$(wc -l <"$RAW/wls_${sn}.errors" | tr -d ' ')"
      grep -qE 'OutOfMemoryError' "$RAW/wls_${sn}.errors" && finding CRIT wls "$sn: OutOfMemoryError since last run"
      grep -qE 'STUCK' "$RAW/wls_${sn}.errors" && finding WARN wls "$sn: stuck threads since last run"
      [ "$n" -gt 50 ] && finding WARN wls "$sn: $n new error lines since last run"
    done
    [ -z "$cfg" ] && true
  done; done
  local g; g="$(grid_home)"
  if [ -n "$g" ]; then
    to 60 "$g/bin/crsctl" stat res -w '(TARGET = ONLINE) and (STATE != ONLINE)' -t >"$RAW/crs_offline.txt" 2>&1
    grep -qE '^[a-z]' "$RAW/crs_offline.txt" && finding CRIT grid "cluster resources not ONLINE: $(grep -oE '^ora\.[^ ]+' "$RAW/crs_offline.txt" | tr '\n' ' ' | cut -c1-150)"
    kv "Grid" "$(to 30 "$g/bin/crsctl" check crs 2>&1 | grep -c 'is online') of 3 CRS components online"
  fi
  if ogg_detect && [ -x "${OGG_HOME:-/nonexistent}/ggsci" ]; then
    ggsci "info all" >"$RAW/ogg.txt" 2>&1
    grep -E '^(EXTRACT|REPLICAT)' "$RAW/ogg.txt" | grep -qE 'ABENDED|STOPPED' && finding CRIT ogg "GoldenGate not running: $(grep -E '^(EXTRACT|REPLICAT)' "$RAW/ogg.txt" | grep -E 'ABENDED|STOPPED' | awk '{print $2}' | tr '\n' ' ')"
    grep -q 'MANAGER.*RUNNING' "$RAW/ogg.txt" || finding CRIT ogg "GoldenGate manager not running"
    kv "GoldenGate" "$(grep -cE 'RUNNING' "$RAW/ogg.txt") running, $(grep -cE 'ABENDED|STOPPED' "$RAW/ogg.txt") down"
  fi
  kv_end
}

write_delta() {
  local delta="$OUT/DELTA.md"
  { printf '# db-health-daily delta: %s  %s\n\n' "$HOST" "$(ts)"
    if [ -z "$PREV" ]; then echo "_first run: no previous run to compare with_"
    else
      printf 'previous run: `%s`\n\n## New findings\n\n' "$PREV"
      comm -13 <(cut -d'|' -f1-3 "$PREV/findings.txt" | sort -u) <(cut -d'|' -f1-3 "$FINDINGS_FILE" | sort -u) | sed 's/^\([A-Z]*\)|\([a-z]*\)|/- **\1** [\2] /' | grep . || echo "- none"
      printf '\n## Cleared since last run\n\n'
      comm -23 <(cut -d'|' -f1-3 "$PREV/findings.txt" | sort -u) <(cut -d'|' -f1-3 "$FINDINGS_FILE" | sort -u) | sed 's/^\([A-Z]*\)|\([a-z]*\)|/- ~~\1 [\2]~~ /' | grep . || echo "- none"
      printf '\n## Still open\n\n'
      comm -12 <(cut -d'|' -f1-3 "$PREV/findings.txt" | sort -u) <(cut -d'|' -f1-3 "$FINDINGS_FILE" | sort -u) | sed 's/^\([A-Z]*\)|\([a-z]*\)|/- \1 [\2] /' | grep . || echo "- none"
    fi
    printf '\n## New alert-log error lines since last run\n\n'
    local f; for f in "$RAW"/alert_*.errors; do [ -s "$f" ] || continue; printf '**%s**\n\n```\n' "$(basename "$f" .errors)"; tail -40 "$f" | cut -c1-160; printf '```\n\n'; done
  } >"$delta"
}

main() {
  load_config; parse_args "$@"
  OUTDIR="$HEALTH_OUT/$(date '+%Y%m%d_%H%M%S')"
  PREV=""; local d; for d in "$HEALTH_OUT"/20*/; do d="${d%/}"; [ -d "$d" ] && [ "$d" != "$OUTDIR" ] && [ -f "$d/findings.txt" ] && PREV="$d"; done
  report_init "$OUTDIR"
  say "db-health-daily $VERSION -> $OUTDIR (previous: ${PREV:-none})"
  check_host; check_exascale; check_listener
  h1 "Databases"
  local sids; sids="$(db_instances | grep -vE '^\+ASM|^-MGMTDB|^\+APX')"; [ -n "$ONLY_SID" ] && sids="$ONLY_SID"
  for s in $(oratab_sids); do printf '%s\n' "$sids" | grep -qx "$s" || { grep -qE "^$s:.*:Y" /etc/oratab 2>/dev/null && finding CRIT db "$s is :Y in oratab but not running"; }; done
  local s; for s in $sids; do check_db "$s"; done
  check_middleware
  findings_sync
  local final; final="$(report_finish "db-health-daily: $HOST $(date '+%Y-%m-%d %H:%M')" "$MAKE_TAR")"
  # SUMMARY.md: one screen
  { printf '# %s  %s  -  %s critical, %s warnings\n\n| database | state | findings |\n|---|---|---|\n%s\n' "$HOST" "$(date '+%Y-%m-%d %H:%M')" "$NCRIT" "$NWARN" "$STATUS_LINES"
    print_findings 'CRIT|WARN'; printf '\nfull report: %s\n' "$final"; } >"$OUTDIR/SUMMARY.md"
  write_delta
  if [ -n "$MAIL_TO" ] && { [ "$ALWAYS_MAIL" = 1 ] || [ "$NCRIT" -gt 0 ] || [ "$NWARN" -gt 0 ]; }; then
    local m; m="$(command -v mailx || command -v mail)"; [ -n "$m" ] && "$m" -s "[db-health] $HOST: $NCRIT crit, $NWARN warn" "$MAIL_TO" <"$OUTDIR/SUMMARY.md"
  fi
  [ "$CRON" = 1 ] || cat "$OUTDIR/SUMMARY.md"
  findings_rc
}
main "$@"
