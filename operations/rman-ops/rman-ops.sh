#!/usr/bin/env bash
# rman-ops.sh - is the backup any good? RMAN configuration, history, recovery window, ZDLRA link,
# restore validation and a real small restore to scratch space, in one report. Everything is
# read-only except the three commands that say so. Runs on the database server as oracle.
#
# Usage: rman-ops.sh <command> [options]
#
# Commands (read-only, each writes REPORT.md with FINDINGS first)
#   inspect           show all, catalog, retention, device, last backups per type, job history, list backup summary,
#                     block change tracking, report obsolete / need backup, list failure, autobackup, corruption, FRA
#   validate          restore database / controlfile / archivelog ... validate (reads the backup pieces, writes nothing),
#                     restore preview (and 'until time' preview with --until); --full adds backup validate check logical database
#   recovery-window   earliest and latest restorable point in time from what exists, archivelog coverage per day, gaps,
#                     datafiles without a usable level 0, days since each datafile's last backup
#   zdlra             SBT library, RA wallet and alias, port to the Recovery Appliance, and - with RA_CATALOG_CONNECT -
#                     ra_database (policy, recovery window goal, unprotected window), restore ranges, incidents, tasks
#   evidence | run    all of the above (validate without --full) in one report, for the auditor or for Claude
#
# Commands that change something (ask first; --yes to skip the question)
#   restore-test      restore the smallest non-system datafile (or --datafile N / --tablespace X) and the controlfile to
#                     --scratch DIR under new names, NEVER switch, dbverify the file, delete it again (--keep to keep)
#   crosscheck        crosscheck backup + archivelog all, list expired, then offer delete expired
#   delete-obsolete   report obsolete, then delete noprompt obsolete (what the retention policy says can go)
#
# Options
#   --sid SID         one database (default: every running instance)      --days N      history window (default 30)
#   --until "YYYY-MM-DD HH:MI"   point in time for the restore preview    --full        backup validate check logical database
#   --datafile N | --tablespace NAME   what restore-test restores          --scratch DIR  where (default RESTORE_SCRATCH_DIR or /tmp)
#   --keep            keep the restored files                              --window N    recovery window you promise, in days (default 7)
#   --out DIR  --lines N  --no-tar  --quiet  --dry-run  --yes  --verbose
#
# Config: rman-ops.conf, ~/.rman-ops.conf or the shared oracle.conf (mode 600 when it holds passwords): SQL_CONNECT,
# RMAN_CATALOG_CONNECT (user/pw@alias or /@alias, added as 'connect catalog' on stdin), RA_CATALOG_CONNECT (VPC user on
# the Recovery Appliance for the ra_* views), RESTORE_SCRATCH_DIR, RMAN_OUT, RECOVERY_WINDOW_DAYS, RMAN_MAX_FULL_DAYS (8),
# RMAN_MAX_ARCH_HOURS (24), RMAN_TIMEOUT (3600 for validate/restore commands).

# shellcheck disable=SC2034  # QUIET/VERBOSE/FORCE are read by the lib
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="rman-ops"; VERSION="1.0.0"
# shellcheck source=../../lib/oracle-lib.sh
. "$SCRIPT_DIR/../../lib/oracle-lib.sh" || { echo "lib/oracle-lib.sh not found" >&2; exit 1; }

RMAN_OUT="${RMAN_OUT:-$HOME/rman-ops}"; RESTORE_SCRATCH_DIR="${RESTORE_SCRATCH_DIR:-/tmp}"; RECOVERY_WINDOW_DAYS="${RECOVERY_WINDOW_DAYS:-7}"
RMAN_MAX_FULL_DAYS="${RMAN_MAX_FULL_DAYS:-8}"; RMAN_MAX_ARCH_HOURS="${RMAN_MAX_ARCH_HOURS:-24}"; RMAN_TIMEOUT="${RMAN_TIMEOUT:-3600}"
RMAN_CATALOG_CONNECT="${RMAN_CATALOG_CONNECT:-}"; RA_CATALOG_CONNECT="${RA_CATALOG_CONNECT:-}"
ONLY_SID=""; DAYS=30; UNTIL=""; FULL=0; DATAFILE=""; TABLESPACE=""; KEEP=0; MAKE_TAR=1
# per database
DBUN=""; SHOWALL=""; LOG_MODE=""; ROLE=""

usage() { usage_from_header "$0"; }
parse_opts() {
  while [ $# -gt 0 ]; do case "$1" in
    --sid) optchk "$@"; ONLY_SID="$2"; shift 2;; --days) optchk "$@"; DAYS="$2"; shift 2;; --until) optchk "$@"; UNTIL="$2"; shift 2;; --full) FULL=1; shift;;
    --datafile) optchk "$@"; DATAFILE="$2"; shift 2;; --tablespace) optchk "$@"; TABLESPACE="$2"; shift 2;; --scratch) optchk "$@"; RESTORE_SCRATCH_DIR="$2"; shift 2;; --keep) KEEP=1; shift;;
    --window) optchk "$@"; RECOVERY_WINDOW_DAYS="$2"; shift 2;; --out) optchk "$@"; RMAN_OUT="$2"; shift 2;; --lines) optchk "$@"; DIAG_LINES="$2"; shift 2;; --no-tar) MAKE_TAR=0; shift;;
    --quiet) QUIET=1; shift;; --dry-run) DRY_RUN=1; shift;; --yes) ASSUME_YES=1; shift;; --force) FORCE=1; shift;; --verbose) VERBOSE=1; shift;;
    -h|--help) usage; exit 0;; *) die "Unknown option: $1";; esac; done
  [ -n "$UNTIL" ] && { [[ "$UNTIL" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]] || die "--until must be 'YYYY-MM-DD HH:MI'"; }
}

# ---------------------------------------------------------------------------
# RMAN: commands on stdin, catalog connect on stdin too (never on a command line); full output to a file
# ---------------------------------------------------------------------------
# rman_bin / rman_run come from lib/oracle-lib.sh (RMAN_CMD, RMAN_TARGET_CONNECT, RMAN_CATALOG_CONNECT honoured)
# rmansec <sid> <name> <title> <secs> <commands>: titled fenced block in the report, full output in raw/
rmansec() {
  local sid="$1" name="$2" title="$3" secs="$4" q="$5" f; f="$RAW/rman_${sid}_${name}.txt"
  { printf -- '-- %s\nRMAN> %s\n\n' "$title" "$q"; rman_run "$sid" "$secs" "$q"; } >"$f" 2>&1
  h3 "$title"; local n; n="$(wc -l <"$f" | tr -d ' ')"
  fence_start
  if [ "$n" -gt "$DIAG_LINES" ]; then head -n "$DIAG_LINES" "$f" >>"$REPORT"; printf '... (%s lines, full in raw/rman_%s_%s.txt)\n' "$n" "$sid" "$name" >>"$REPORT"; else cat "$f" >>"$REPORT"; fi
  fence_end
  # RMAN-00571/00569 are only the frame of any error stack: look for the real connection errors
  grep -qE 'ORA-01017|ORA-01031|ORA-12[0-9]{3}|RMAN-0400[4-6]|RMAN-06429|RMAN-06171' "$f" && finding CRIT rman "$sid: RMAN could not connect for '$title' (see raw/rman_${sid}_${name}.txt)"
  grep -qE 'RMAN-01009|RMAN-00558' "$f" && finding WARN rman "$sid: this RMAN does not accept '$q' (RMAN-01009: removed or renamed in this release?) - see raw/rman_${sid}_${name}.txt"
  return 0
}
rman_errors() { grep -E 'RMAN-[0-9]+|ORA-[0-9]+' "$1" 2>/dev/null | grep -vE 'RMAN-08[0-9]+' | sort -u | head -5 | tr -s ' ' | tr '\n' ';'; }
# rman_completed <rc> <file>: true only when RMAN exited 0 AND printed its closing line - a connect failure, a missing rman or a
# timeout leaves an output file with none of the lines the callers count, and a count of 0 must not read as 'nothing found'
rman_completed() { [ "$1" = 0 ] && grep -q 'Recovery Manager complete' "$2" 2>/dev/null; }
db_basics() { # <sid>: DBUN LOG_MODE ROLE SHOWALL
  local sid="$1"
  IFS='|' read -r DBUN LOG_MODE ROLE <<<"$(sql_lines "$sid" "select db_unique_name||'|'||log_mode||'|'||database_role from v\$database;" | head -1)"
  SHOWALL="$(rman_run "$sid" 120 "show all;")"
}
cfg_val() { printf '%s\n' "$SHOWALL" | grep -E "^CONFIGURE $1 " | head -1 | sed -E "s/^CONFIGURE $1 (TO )?//; s/;.*//; s/ *# default//"; }

# ---------------------------------------------------------------------------
# inspect
# ---------------------------------------------------------------------------
sec_inspect() {
  local sid="$1"
  h2 "Configuration"
  local ret auto dev del opt cat_cfg; ret="$(cfg_val 'RETENTION POLICY')"; auto="$(cfg_val 'CONTROLFILE AUTOBACKUP')"; dev="$(cfg_val 'DEFAULT DEVICE TYPE')"; del="$(cfg_val 'ARCHIVELOG DELETION POLICY')"; opt="$(cfg_val 'BACKUP OPTIMIZATION')"
  kv "db_unique_name" "$DBUN"; kv "role / log mode" "$ROLE / $LOG_MODE"; kv "retention policy" "${ret:-?}"; kv "controlfile autobackup" "${auto:-?}"; kv "default device" "${dev:-?}"; kv "archivelog deletion policy" "${del:-?}"; kv "backup optimization" "${opt:-?}"
  kv "catalog" "$([ -n "$RMAN_CATALOG_CONNECT" ] && echo "${RMAN_CATALOG_CONNECT##*@} (as ${RMAN_CATALOG_CONNECT%%/*})" || echo 'none (controlfile only)')"
  kv "block change tracking" "$(sql_lines "$sid" "select status||' '||nvl(filename,'-')||' '||nvl(round(bytes/1048576),0)||' MB' from v\$block_change_tracking;" | head -1)"
  kv "FRA" "$(sql_lines "$sid" "select nvl(name,'not set')||' '||round(space_used/1048576/1024,1)||' of '||round(space_limit/1048576/1024,1)||' GB used ('||round((space_used-space_reclaimable)*100/nullif(space_limit,0))||'% net)' from v\$recovery_file_dest;" | head -1)"
  kv_end
  [ "$LOG_MODE" != ARCHIVELOG ] && [ "$ROLE" = PRIMARY ] && finding CRIT backup "$sid: NOARCHIVELOG - only consistent cold backups are possible, no point-in-time recovery"
  case "$ret" in NONE) finding WARN backup "$sid: retention policy NONE - nothing is ever obsolete, nothing guarantees a window either";; "REDUNDANCY 1") finding WARN backup "$sid: retention REDUNDANCY 1 - one failed backup and the previous good one is already deletable";; esac
  [ "$auto" = OFF ] && finding WARN backup "$sid: controlfile autobackup OFF - losing all controlfiles means no easy restore of the controlfile/spfile"
  [ "$(sql_val "$sid" "(select status from v\$block_change_tracking)")" != ENABLED ] && [ "$(sql_val "$sid" "(select count(*) from v\$backup_datafile where incremental_level>0 and completion_time>sysdate-$DAYS)")" != 0 ] && finding WARN backup "$sid: incremental backups are taken but block change tracking is disabled (every incremental reads every block): alter database enable block change tracking"
  local fra; fra="$(sql_val "$sid" "(select round((space_used-space_reclaimable)*100/space_limit) from v\$recovery_file_dest where space_limit>0)" 2>/dev/null)"; [ -n "$fra" ] && [ "$fra" -gt 85 ] && finding WARN backup "$sid: FRA ${fra}% net used"
  sqlsec "$sid" rman_config "show all (from v\$rman_configuration)" "select name, value from v\$rman_configuration order by conf#;"
  fence_start; printf '%s\n' "$SHOWALL" | grep -E '^CONFIGURE' >>"$REPORT"; fence_end

  h2 "Last successful backup per type"
  sqlsec "$sid" last_by_type "last COMPLETED job per input type (v\$rman_backup_job_details)" "select input_type, max(end_time) last_end, round((sysdate-max(end_time))*24,1) hours_ago, count(*) runs_in_${DAYS}d from v\$rman_backup_job_details where status like 'COMPLETED%' and start_time>sysdate-$DAYS group by input_type order by 2 desc;"
  local lastfull lastarch
  lastfull="$(sql_val "$sid" "(select round(sysdate-max(end_time),1) from v\$rman_backup_job_details where status like 'COMPLETED%' and input_type like 'DB%')")"
  lastarch="$(sql_val "$sid" "(select round((sysdate-max(completion_time))*24,1) from v\$backup_set where backup_type='L')")"  # 'backup database plus archivelog' is one job of input_type DB FULL: the archivelog sets are the truth
  if [ -z "$lastfull" ]; then finding CRIT backup "$sid: no completed database backup in the last $DAYS days (job history)"; else awk -v d="$lastfull" -v m="$RMAN_MAX_FULL_DAYS" 'BEGIN{exit !(d>m)}' && finding CRIT backup "$sid: last completed database backup was $lastfull days ago (limit $RMAN_MAX_FULL_DAYS)"; fi
  if [ "$LOG_MODE" = ARCHIVELOG ]; then if [ -z "$lastarch" ]; then finding CRIT backup "$sid: no completed archivelog backup in $DAYS days"; else awk -v h="$lastarch" -v m="$RMAN_MAX_ARCH_HOURS" 'BEGIN{exit !(h>m)}' && finding CRIT backup "$sid: last archivelog backup $lastarch hours ago (limit $RMAN_MAX_ARCH_HOURS)"; fi; fi
  local notbacked; notbacked="$(sql_val "$sid" "(select count(*) from v\$archived_log where backup_count=0 and deleted='NO' and standby_dest='NO' and archived='YES')")"; [ "${notbacked:-0}" -gt 24 ] && finding WARN backup "$sid: $notbacked archived logs on disk have never been backed up"
  local cfauto; cfauto="$(sql_val "$sid" "(select round((sysdate-max(completion_time))*24,1) from v\$backup_set where controlfile_included<>'NO')")"; [ -n "$cfauto" ] && awk -v h="$cfauto" 'BEGIN{exit !(h>48)}' && finding WARN backup "$sid: last controlfile backup $cfauto hours ago"

  h2 "Job history ($DAYS days)"
  sqlsec "$sid" jobs "backup jobs (v\$rman_backup_job_details)" "select to_char(start_time,'YYYY-MM-DD HH24:MI') start_time, input_type, status, round(elapsed_seconds/60) mins, input_bytes_display input, output_bytes_display output, output_device_type dev, round(compression_ratio,1) ratio from (select * from v\$rman_backup_job_details where start_time>sysdate-$DAYS order by start_time desc) where rownum<=60;"
  local failed; failed="$(sql_val "$sid" "(select count(*) from v\$rman_backup_job_details where status not like 'COMPLETED%' and status<>'RUNNING' and start_time>sysdate-7)")"; [ "${failed:-0}" != 0 ] && finding WARN backup "$sid: $failed backup job(s) not COMPLETED in the last 7 days"
  local running; running="$(sql_val "$sid" "(select count(*) from v\$rman_backup_job_details where status='RUNNING')")"; [ "${running:-0}" != 0 ] && finding INFO backup "$sid: a backup is running now"
  sqlsec "$sid" rman_status_errors "failed RMAN operations, 7 days (v\$rman_status)" "select to_char(start_time,'YYYY-MM-DD HH24:MI') start_time, operation, object_type, status, round(mbytes_processed) mb from v\$rman_status where status like 'FAILED%' and start_time>sysdate-7 order by start_time desc fetch first 20 rows only;"
  sqlsec "$sid" rman_output_errors "RMAN error lines in memory (v\$rman_output)" "select substr(output,1,160) from v\$rman_output where output like '%RMAN-%' or output like '%ORA-%' order by recid desc fetch first 30 rows only;"

  h2 "What exists"
  rmansec "$sid" summary "list backup summary" 300 "list backup summary;"
  rmansec "$sid" cf "list backup of controlfile / spfile (latest)" 120 "list backup of controlfile summary;\nlist backup of spfile summary;"
  sqlsec "$sid" sets_by_day "backup sets per day and type (v\$backup_set_details)" "select to_char(completion_time,'YYYY-MM-DD') day, backup_type, incremental_level lvl, device_type, count(*) sets, round(sum(output_bytes)/1073741824,1) gb, sum(decode(status,'A',0,1)) not_available from v\$backup_set_details where completion_time>sysdate-$DAYS group by to_char(completion_time,'YYYY-MM-DD'), backup_type, incremental_level, device_type order by 1 desc, 2, 3;"
  sqlsec "$sid" incr_reads "incremental efficiency: blocks read vs blocks in file (BCT effect)" "select incremental_level lvl, count(*) files, round(avg(blocks_read*100/greatest(datafile_blocks,1)),1) pct_read, round(avg(blocks*100/greatest(datafile_blocks,1)),1) pct_backed from v\$backup_datafile where completion_time>sysdate-$DAYS and incremental_level is not null group by incremental_level order by 1;"
  rmansec "$sid" obsolete "report obsolete" 300 "report obsolete;"
  rmansec "$sid" needbackup "report need backup" 300 "report need backup;"
  local need; need="$(grep -cE '^[0-9]+ +[0-9]+ ' "$RAW/rman_${sid}_needbackup.txt")"; [ "${need:-0}" != 0 ] && finding WARN backup "$sid: report need backup lists $need file(s) outside the retention policy"
  # Data Recovery Advisor (list failure) was desupported in 23ai: skip it there
  local dbver; dbver="$(sql_val "$sid" "(select version_full from v\$instance)" 2>/dev/null)"
  if version_ge "${dbver:-0}" 23; then log "$sid: Data Recovery Advisor desupported in ${dbver} - 'list failure' skipped"; : >"$RAW/rman_${sid}_failure.txt"; else
  rmansec "$sid" failure "list failure (Data Recovery Advisor)" 300 "list failure;"; fi
  [ -s "$RAW/rman_${sid}_failure.txt" ] && { grep -qiE 'no failures found' "$RAW/rman_${sid}_failure.txt" || { grep -qE '^[0-9]+ +(CRITICAL|HIGH)' "$RAW/rman_${sid}_failure.txt" && finding CRIT backup "$sid: Data Recovery Advisor lists CRITICAL/HIGH failures: $(grep -E '^[0-9]+ +(CRITICAL|HIGH)' "$RAW/rman_${sid}_failure.txt" | head -2 | tr -s ' ' | tr '\n' ';')"; } }
  sqlsec "$sid" corruption "block corruption known to the database" "select 'v\$database_block_corruption' src, count(*) blocks from v\$database_block_corruption union all select 'v\$backup_corruption', count(*) from v\$backup_corruption union all select 'v\$copy_corruption', count(*) from v\$copy_corruption;"
  local corr; corr="$(sql_val "$sid" "(select count(*) from v\$database_block_corruption)")"; [ "${corr:-0}" != 0 ] && finding CRIT backup "$sid: $corr corrupt block(s) in v\$database_block_corruption - 'recover corruption list' / 'list failure'"
  sqlsec "$sid" datafiles_last "days since each datafile was last backed up (worst 15)" "select d.file_id, d.tablespace_name, round(d.bytes/1048576) mb, nvl(to_char(b.last,'YYYY-MM-DD HH24:MI'),'NEVER') last_backup, round(sysdate-b.last,1) days_ago from dba_data_files d left join (select file#, max(completion_time) last from v\$backup_datafile group by file#) b on b.file#=d.file_id order by b.last nulls first fetch first 15 rows only;"
  local never; never="$(sql_val "$sid" "(select count(*) from v\$datafile d where not exists (select 1 from v\$backup_datafile b where b.file#=d.file#))")"; [ "${never:-0}" != 0 ] && finding CRIT backup "$sid: $never datafile(s) have never been backed up (new tablespace since the last full?)"
}

# ---------------------------------------------------------------------------
# recovery window
# ---------------------------------------------------------------------------
sec_recovery_window() {
  local sid="$1"
  h2 "Recovery window"
  local earliest latest gapend
  earliest="$(sql_val "$sid" "(select to_char(max(oldest),'YYYY-MM-DD HH24:MI') from (select d.file#, min(b.completion_time) oldest from v\$datafile d join v\$backup_datafile b on b.file#=d.file# and nvl(b.incremental_level,0)=0 group by d.file#))")"
  gapend="$(sql_val "$sid" "(select to_char(max(next_time),'YYYY-MM-DD HH24:MI') from v\$archived_log where backup_count=0 and deleted='YES' and standby_dest='NO' and resetlogs_change#=(select resetlogs_change# from v\$database)${earliest:+ and first_time>=to_date('$earliest','YYYY-MM-DD HH24:MI')})")"
  latest="$(sql_val "$sid" "(select to_char(max(next_time),'YYYY-MM-DD HH24:MI') from v\$archived_log where (backup_count>0 or deleted='NO') and standby_dest='NO' and resetlogs_change#=(select resetlogs_change# from v\$database))")"
  local start="$earliest"; [ -n "$gapend" ] && start="$gapend (after an archivelog gap; level 0 goes back to $earliest)"
  kv "earliest restorable point in time" "${start:-none: no level 0 / full backup covering every datafile}"
  kv "latest point with redo available (archived)" "${latest:-?} (plus the current online redo while the database is alive)"
  kv "window you promise" "$RECOVERY_WINDOW_DAYS days (RECOVERY_WINDOW_DAYS)"
  kv "note" "from the controlfile; backups older than control_file_record_keep_time ($(sql_val "$sid" "(select value from v\$parameter where name='control_file_record_keep_time')") days) only show in a catalog"
  kv_end
  if [ -z "$earliest" ]; then finding CRIT backup "$sid: no level 0 or full backup covers every datafile - the database cannot be restored from RMAN backups"
  else
    local ed; ed="$(epoch_of "$earliest:00")"; local have_days=$(( ( $(date +%s) - ${ed:-0} ) / 86400 ))
    [ -n "$gapend" ] && { local gd; gd="$(epoch_of "$gapend:00")"; have_days=$(( ( $(date +%s) - ${gd:-0} ) / 86400 )); finding CRIT backup "$sid: archivelog gap - logs up to $gapend were deleted without a backup; point-in-time recovery before that is impossible"; }
    [ "$have_days" -lt "$RECOVERY_WINDOW_DAYS" ] && finding WARN backup "$sid: restorable window is $have_days days, promised $RECOVERY_WINDOW_DAYS"
  fi
  sqlsec "$sid" arch_cover "archivelog coverage per day (controlfile view): logs, backed up, on disk only, LOST" "select to_char(first_time,'YYYY-MM-DD') day, count(*) logs, sum(case when backup_count>0 then 1 else 0 end) backed_up, sum(case when backup_count=0 and deleted='NO' then 1 else 0 end) disk_only, sum(case when backup_count=0 and deleted='YES' then 1 else 0 end) lost, round(sum(blocks*block_size)/1073741824,1) gb from v\$archived_log where standby_dest='NO' and archived='YES' and resetlogs_change#=(select resetlogs_change# from v\$database) and first_time>sysdate-$DAYS group by to_char(first_time,'YYYY-MM-DD') order by 1 desc;"
  sqlsec "$sid" level0_per_file "oldest and newest level 0 per datafile (worst 15)" "select d.file#, d.name, to_char(min(b.completion_time),'YYYY-MM-DD') oldest_l0, to_char(max(b.completion_time),'YYYY-MM-DD') newest_l0, count(*) l0s from v\$datafile d left join v\$backup_datafile b on b.file#=d.file# and nvl(b.incremental_level,0)=0 group by d.file#, d.name order by max(b.completion_time) nulls first fetch first 15 rows only;"
  sqlsec "$sid" incarnations "incarnations (a resetlogs breaks the chain)" "select incarnation#, resetlogs_change#, to_char(resetlogs_time,'YYYY-MM-DD HH24:MI') resetlogs_time, status from v\$database_incarnation order by 1;"
  sqlsec "$sid" restore_points "restore points (guaranteed ones hold the FRA)" "select name, guarantee_flashback_database grp, to_char(time,'YYYY-MM-DD HH24:MI') time, round(storage_size/1073741824,1) gb from v\$restore_point order by time;"
}

# ---------------------------------------------------------------------------
# validate
# ---------------------------------------------------------------------------
sec_validate() {
  local sid="$1"
  h2 "Restore validation (reads backup pieces, writes nothing)"
  para "_restore ... validate_ opens every backup piece a restore would need and checks it for corruption; it does not write a file. Long on big databases: $((RMAN_TIMEOUT/60)) min limit per command."
  rmansec "$sid" preview "restore database preview summary (which backups a restore would use)" 600 "restore database preview summary;"
  grep -qE 'RMAN-06026|RMAN-06023|RMAN-06024|RMAN-06025|RMAN-20' "$RAW/rman_${sid}_preview.txt" && finding CRIT backup "$sid: restore preview cannot find a backup for something: $(rman_errors "$RAW/rman_${sid}_preview.txt")"
  grep -qE 'no backup or copy of' "$RAW/rman_${sid}_preview.txt" && finding CRIT backup "$sid: preview: 'no backup or copy of ...' - a file is not restorable"
  if [ -n "$UNTIL" ]; then
    rmansec "$sid" preview_until "restore database until time '$UNTIL' preview summary" 600 "run { set until time \"to_date('$UNTIL','YYYY-MM-DD HH24:MI')\"; restore database preview summary; }"
    grep -qE 'RMAN-06026|RMAN-06023|RMAN-06024|RMAN-06025|RMAN-20|no backup or copy' "$RAW/rman_${sid}_preview_until.txt" && finding CRIT backup "$sid: point-in-time $UNTIL is NOT restorable: $(rman_errors "$RAW/rman_${sid}_preview_until.txt")"
  fi
  rmansec "$sid" val_cf "restore controlfile validate" 600 "restore controlfile validate;"
  rmansec "$sid" val_sp "restore spfile validate" 300 "restore spfile validate;"
  rmansec "$sid" val_db "restore database validate" "$RMAN_TIMEOUT" "restore database validate;"
  [ "$LOG_MODE" = ARCHIVELOG ] && rmansec "$sid" val_arch "restore archivelog from time 'sysdate-1' validate" "$RMAN_TIMEOUT" "restore archivelog from time 'sysdate-1' validate;"
  local f; for f in val_cf val_sp val_db val_arch; do [ -f "$RAW/rman_${sid}_$f.txt" ] || continue
    if grep -qE 'RMAN-0[0-9]{4}|ORA-[0-9]+' "$RAW/rman_${sid}_$f.txt" && ! grep -qE 'Finished restore' "$RAW/rman_${sid}_$f.txt"; then finding CRIT backup "$sid: $f failed: $(rman_errors "$RAW/rman_${sid}_$f.txt")"; fi
    grep -qiE 'corrupt' "$RAW/rman_${sid}_$f.txt" && finding CRIT backup "$sid: $f reports corruption in a backup piece"
  done
  if [ "$FULL" = 1 ]; then
    rmansec "$sid" bv_db "backup validate check logical database (reads every datafile block)" "$((RMAN_TIMEOUT*3))" "backup validate check logical database;"
    local corr; corr="$(sql_val "$sid" "(select count(*) from v\$database_block_corruption)")"; [ "${corr:-0}" != 0 ] && finding CRIT backup "$sid: backup validate found $corr corrupt block(s) (v\$database_block_corruption)" || finding INFO backup "$sid: backup validate check logical: no corruption"
  fi
}

# ---------------------------------------------------------------------------
# ZDLRA
# ---------------------------------------------------------------------------
sec_zdlra() {
  local sid="$1"
  h2 "Recovery Appliance (ZDLRA)"
  local sbt; sbt="$(printf '%s\n' "$SHOWALL" | grep -iE "SBT_TAPE.*(libra|RA_WALLET)" | head -1)"
  if [ -z "$sbt" ] && [ -z "$RA_CATALOG_CONNECT" ]; then para "_no SBT channel with libra.so / RA_WALLET configured and no RA_CATALOG_CONNECT: not a Recovery Appliance client (or the channel is set per script)_"; return 0; fi
  local lib wal alias host port svc
  lib="$(printf '%s' "$sbt" | grep -oiE 'SBT_LIBRARY=[^, )]+' | cut -d= -f2)"; wal="$(printf '%s' "$sbt" | grep -oiE 'RA_WALLET=location=file:[^ ,)]+' | sed 's/.*file://')"; alias="$(printf '%s' "$sbt" | grep -oiE 'credential_alias=[^ ,)]+' | cut -d= -f2)"
  host="${alias%%:*}"; port="$(printf '%s' "$alias" | sed -n 's#^[^:]*:\([0-9]*\)/.*#\1#p')"; svc="${alias##*/}"
  kv "SBT channel" "${sbt:-none in show all}"; kv "libra.so" "${lib:-?} $([ -n "$lib" ] && { [ -f "$lib" ] && echo present || echo MISSING; })"
  kv "RA wallet" "${wal:-?} $([ -n "$wal" ] && { [ -f "$wal/cwallet.sso" ] && echo "cwallet.sso present (mode $(file_mode "$wal/cwallet.sso"))" || echo 'cwallet.sso MISSING'; })"
  kv "credential alias" "${alias:-?}"; [ -n "$host" ] && [ -n "$port" ] && kv "port $host:$port" "$(port_open "$port" "$host" && echo open || echo CLOSED)"
  kv_end
  [ -n "$lib" ] && [ ! -f "$lib" ] && finding CRIT zdlra "$sid: SBT library $lib does not exist - every SBT backup fails (ORA-27211/27206)"
  [ -n "$wal" ] && [ ! -f "$wal/cwallet.sso" ] && finding CRIT zdlra "$sid: RA wallet $wal has no cwallet.sso - backups cannot authenticate to the appliance"
  [ -n "$host" ] && [ -n "$port" ] && ! port_open "$port" "$host" && finding CRIT zdlra "$sid: cannot reach the appliance at $host:$port from this host"
  [ -n "$wal" ] && [ -d "$wal" ] && { local mk; mk="$(db_home_of "$sid")/bin/mkstore"; [ -x "$mk" ] && section_sh "zdlra_wallet_$sid" "$mk -wrl '$wal' -listCredential </dev/null 2>&1 | head -20"; }
  [ -n "$host" ] && section_sh "zdlra_tnsping_$sid" "ORACLE_HOME='$(db_home_of "$sid")' '$(db_home_of "$sid")/bin/tnsping' '$alias' 2>&1 | tail -4"
  sqlsec "$sid" sbt_jobs "SBT backups in the last 7 days" "select to_char(start_time,'YYYY-MM-DD HH24:MI') start_time, input_type, status, round(elapsed_seconds/60) mins, output_bytes_display output from v\$rman_backup_job_details where output_device_type like '%SBT%' and start_time>sysdate-7 order by start_time desc fetch first 20 rows only;"
  if [ -n "$RA_CATALOG_CONNECT" ]; then
    h3 "Appliance catalog views (as ${RA_CATALOG_CONNECT%%/*}@${RA_CATALOG_CONNECT##*@})"
    local raq; raq() { SQL_CONNECT="$RA_CATALOG_CONNECT" PDB_SET="" sqlsec "$sid" "$1" "$2" "$3"; }
    raq ra_database "ra_database: policy, recovery window goal, unprotected window, space" "select db_unique_name, policy_name, recovery_window_goal, unprotected_window, disk_reserved_space, size_estimate, nzdl_active from ra_database where upper(db_unique_name)=upper('$DBUN');"
    raq ra_restore_range "ra_disk_restore_range: what the appliance can restore for this database" "select db_unique_name, to_char(low_time,'YYYY-MM-DD HH24:MI') low_time, to_char(high_time,'YYYY-MM-DD HH24:MI') high_time, low_dbinc_key, high_dbinc_key from ra_disk_restore_range where upper(db_unique_name)=upper('$DBUN') order by low_time;"
    raq ra_incidents "ra_incident_log: open incidents for this database" "select incident_id, severity, component, to_char(first_seen,'YYYY-MM-DD HH24:MI') first_seen, to_char(last_seen,'YYYY-MM-DD HH24:MI') last_seen, status, substr(error_text,1,120) error_text from ra_incident_log where (upper(db_unique_name)=upper('$DBUN') or db_unique_name is null) and status='ACTIVE' order by last_seen desc fetch first 20 rows only;"
    raq ra_tasks "ra_task: running / waiting tasks for this database" "select task_type, state, to_char(creation_time,'YYYY-MM-DD HH24:MI') created, waiting_on, error_count from ra_task where upper(db_unique_name)=upper('$DBUN') and state not in ('COMPLETED') order by creation_time desc fetch first 20 rows only;"
    raq ra_server "ra_server: appliance version and state" "select * from ra_server;"
    local unprot; unprot="$(SQL_CONNECT="$RA_CATALOG_CONNECT" PDB_SET="" sql_lines "$sid" "select nvl(extract(day from unprotected_window)*24+extract(hour from unprotected_window),0) from ra_database where upper(db_unique_name)=upper('$DBUN');" 2>/dev/null | head -1)"
    [ -n "$unprot" ] && [ "${unprot%%.*}" -gt "$RMAN_MAX_ARCH_HOURS" ] 2>/dev/null && finding CRIT zdlra "$sid: appliance says the unprotected window is ${unprot} hours (redo not shipped/backed up)"
    local inc; inc="$(SQL_CONNECT="$RA_CATALOG_CONNECT" PDB_SET="" sql_val "$sid" "(select count(*) from ra_incident_log where (upper(db_unique_name)=upper('$DBUN') or db_unique_name is null) and status='ACTIVE')" 2>/dev/null)"; [ "${inc:-0}" != 0 ] && finding WARN zdlra "$sid: $inc ACTIVE incident(s) on the appliance for this database (or appliance-wide)"
    grep -qE 'ORA-|no rows' "$RAW/db_${sid}_ra_database.txt" && finding WARN zdlra "$sid: ra_database returned nothing for $DBUN - not enrolled under that name, or the VPC user cannot see it"
  else para "_RA_CATALOG_CONNECT not set: appliance-side views (ra_database, ra_incident_log, restore ranges) skipped_"; fi
}

# ---------------------------------------------------------------------------
# change-making: restore-test, crosscheck, delete-obsolete
# ---------------------------------------------------------------------------
cmd_restore_test() {
  local sid="$1"; init_run_dir "restore-test-$sid"; db_basics "$sid"
  local pick; if [ -n "$DATAFILE" ]; then pick="$(sql_lines "$sid" "select file#||'|'||name||'|'||round(bytes/1048576)||'|'||block_size from v\$datafile where file#=$DATAFILE;" | head -1)"
  elif [ -n "$TABLESPACE" ]; then pick="$(sql_lines "$sid" "select file#||'|'||name||'|'||round(bytes/1048576)||'|'||block_size from v\$datafile d where ts#=(select ts# from v\$tablespace where upper(name)=upper('$TABLESPACE')) order by bytes fetch first 1 row only;" | head -1)"
  else pick="$(sql_lines "$sid" "select file#||'|'||name||'|'||round(bytes/1048576)||'|'||block_size from v\$datafile d where ts# not in (select ts# from v\$tablespace where name in ('SYSTEM','SYSAUX') or name like 'UNDO%') order by bytes fetch first 1 row only;" | head -1)"; fi
  [ -n "$pick" ] || die "no datafile matches (--datafile N / --tablespace X)"
  local fno name mb bs; IFS='|' read -r fno name mb bs <<<"$pick"
  mkdir -p "$RESTORE_SCRATCH_DIR" || die "cannot create $RESTORE_SCRATCH_DIR"
  local free; free="$(df -Pm "$RESTORE_SCRATCH_DIR" | awk 'NR==2{print $4}')"; [ "$free" -lt $((mb+512)) ] && die "$RESTORE_SCRATCH_DIR has ${free} MB free, the file is ${mb} MB (pick a smaller one with --datafile, or --scratch)"
  local out; out="$RESTORE_SCRATCH_DIR/rt_${sid}_$(date +%Y%m%d%H%M%S)"; local df="${out}_df${fno}.dbf" cf="${out}_control.ctl"
  log "restore test on $sid: datafile $fno ($name, ${mb} MB) and the controlfile -> $out* ; NO switch, the database keeps using its own files"
  confirm "Restore datafile $fno and a controlfile copy to $RESTORE_SCRATCH_DIR (${mb} MB)?" || die "aborted"
  [ "$DRY_RUN" = 1 ] && { log "DRY-RUN: run { set newname for datafile $fno to '$df'; restore datafile $fno; }  restore controlfile to '$cf';"; return 0; }
  local t0; t0="$(date +%s)"
  rman_run "$sid" "$RMAN_TIMEOUT" "run { set newname for datafile $fno to '$df'; restore datafile $fno; }\nrestore controlfile to '$cf';" >"$RUN_DIR/rman_restore_test.txt" 2>&1
  local secs=$(( $(date +%s) - t0 )) rc=0
  grep -q 'Finished restore' "$RUN_DIR/rman_restore_test.txt" || { err "RMAN did not finish the restore: $(rman_errors "$RUN_DIR/rman_restore_test.txt")  (full: $RUN_DIR/rman_restore_test.txt)"; rc=1; }
  if [ -f "$df" ]; then
    local got; got="$(file_size "$df")"; log "restored $df: $((got/1048576)) MB in ${secs}s ($(( got/1048576 / (secs>0?secs:1) )) MB/s)"
    local dbv; dbv="$(db_home_of "$sid")/bin/dbv"; if [ -x "$dbv" ]; then { ORACLE_HOME="$(db_home_of "$sid")" to 1800 "$dbv" file="$df" blocksize="$bs" >"$RUN_DIR/dbv.txt" 2>&1; local fails; fails="$(sed -n 's/^Total Pages Failing *(Data) *: *//p' "$RUN_DIR/dbv.txt" | head -1)"; local idx; idx="$(sed -n 's/^Total Pages Failing *(Index) *: *//p' "$RUN_DIR/dbv.txt" | head -1)"; if [ "${fails:-0}" = 0 ] && [ "${idx:-0}" = 0 ]; then log "dbverify: no failing pages"; else err "dbverify: $fails data / $idx index pages failing (see $RUN_DIR/dbv.txt)"; rc=1; fi; }; else warn "no dbv under $(db_home_of "$sid")/bin: the restored file was NOT block-verified, only restored"; fi
    sql_val "$sid" "(select count(*) from v\$datafile where file#=$fno and name='$df')" | grep -q '^0$' || { err "the controlfile now points at $df - a SWITCH happened; this should not be possible from this script. Do NOT delete the file; investigate"; KEEP=1; rc=1; }
  else err "no file at $df after the restore"; rc=1; fi
  if [ -f "$cf" ]; then log "controlfile copy $cf: $(( $(file_size "$cf") / 1048576 )) MB"; else err "no controlfile copy at $cf - 'restore controlfile to' failed: $(rman_errors "$RUN_DIR/rman_restore_test.txt")"; rc=1; fi
  if [ "$KEEP" = 1 ]; then log "keeping $df and $cf (--keep)"; else rm -f "$df" "$cf"; log "deleted the restored files"; fi
  [ "$rc" = 0 ] && echo "SUCCESS: restore test of datafile $fno on $sid passed in ${secs}s. Log: $RUN_DIR" || die "FAILED: restore test on $sid. Log: $RUN_DIR"
}

cmd_crosscheck() {
  local sid="$1"; init_run_dir "crosscheck-$sid"; db_basics "$sid"
  confirm "crosscheck backup and archivelog all on $sid (marks pieces that are gone as EXPIRED; deletes nothing)?" || die "aborted"
  [ "$DRY_RUN" = 1 ] && { log "DRY-RUN: crosscheck backup; crosscheck archivelog all; list expired backup; list expired archivelog all;"; return 0; }
  rman_run "$sid" "$RMAN_TIMEOUT" "crosscheck backup;\ncrosscheck archivelog all;\nlist expired backup summary;\nlist expired archivelog all;" >"$RUN_DIR/rman_crosscheck.txt" 2>&1; local rrc=$?
  rman_completed "$rrc" "$RUN_DIR/rman_crosscheck.txt" || die "crosscheck did not complete on $sid (rman rc $rrc): $(rman_errors "$RUN_DIR/rman_crosscheck.txt")  (full: $RUN_DIR/rman_crosscheck.txt) - nothing is known about expired entries"
  local exp_b exp_a; exp_b="$(grep -cE "^[0-9]+ +B +.* X " "$RUN_DIR/rman_crosscheck.txt")"; exp_a="$(grep -cE "crosschecked archived log: found to be 'EXPIRED'" "$RUN_DIR/rman_crosscheck.txt")"
  log "expired: $exp_b backup set(s) in the summary, $exp_a archived log(s). Output: $RUN_DIR/rman_crosscheck.txt"
  grep -E 'RMAN-0[0-9]{4}|ORA-' "$RUN_DIR/rman_crosscheck.txt" | grep -vE 'RMAN-08' | head -3 | sed 's/^/  /' >&2
  if [ "$exp_b" != 0 ] || [ "$exp_a" != 0 ]; then
    warn "expired entries mean files the backup software thinks it has are gone - find out WHY before deleting the records (NFS unmounted? wrong host? tape recalled?)"
    if confirm "delete noprompt expired backup; delete noprompt expired archivelog all;  (records only; the files are already gone)"; then
      rman_run "$sid" "$RMAN_TIMEOUT" "delete noprompt expired backup;\ndelete noprompt expired archivelog all;" >"$RUN_DIR/rman_delete_expired.txt" 2>&1; rrc=$?
      if rman_completed "$rrc" "$RUN_DIR/rman_delete_expired.txt" && [ -z "$(rman_errors "$RUN_DIR/rman_delete_expired.txt")" ]; then log "expired records deleted ($RUN_DIR/rman_delete_expired.txt)"
      else err "delete expired did not complete on $sid (rman rc $rrc): $(rman_errors "$RUN_DIR/rman_delete_expired.txt")  (full: $RUN_DIR/rman_delete_expired.txt)"; return 1; fi
    fi
  fi
}

obsolete_count() { grep -cE '^(Backup Set|Backup Piece|Archive Log|Datafile Copy|Control File Copy) ' "$1"; }
cmd_delete_obsolete() {
  local sid="$1"; init_run_dir "delete-obsolete-$sid"; db_basics "$sid"
  local ret; ret="$(cfg_val 'RETENTION POLICY')"; [ "$ret" = NONE ] && die "retention policy is NONE: 'delete obsolete' would be meaningless (nothing is obsolete). Set a policy first."
  rman_run "$sid" 600 "report obsolete;" >"$RUN_DIR/rman_report_obsolete.txt" 2>&1; local rrc=$?
  rman_completed "$rrc" "$RUN_DIR/rman_report_obsolete.txt" || die "report obsolete did not complete on $sid (rman rc $rrc): $(rman_errors "$RUN_DIR/rman_report_obsolete.txt")  (full: $RUN_DIR/rman_report_obsolete.txt) - that is not 'nothing obsolete'"
  local n; n="$(obsolete_count "$RUN_DIR/rman_report_obsolete.txt")"
  log "retention: $ret; report obsolete lists $n item(s) ($RUN_DIR/rman_report_obsolete.txt)"; grep -E '^(Backup Set|Archive Log|Datafile Copy)' "$RUN_DIR/rman_report_obsolete.txt" | head -10 | sed 's/^/  /' >&2
  # zero items is only 'nothing obsolete' when RMAN said so; anything else (RMAN-01009 on this release, an unexpected layout) is read, not assumed
  [ "$n" = 0 ] && { grep -q 'no obsolete backups found' "$RUN_DIR/rman_report_obsolete.txt" || die "report obsolete on $sid listed no items and did not say 'no obsolete backups found' - read $RUN_DIR/rman_report_obsolete.txt before deleting anything"; log "nothing obsolete"; return 0; }
  confirm "delete noprompt obsolete on $sid ($n items, per '$ret')?" || die "aborted"
  [ "$DRY_RUN" = 1 ] && { log "DRY-RUN: delete noprompt obsolete;"; return 0; }
  rman_run "$sid" "$RMAN_TIMEOUT" "delete noprompt obsolete;" >"$RUN_DIR/rman_delete_obsolete.txt" 2>&1; rrc=$?
  rman_completed "$rrc" "$RUN_DIR/rman_delete_obsolete.txt" || { err "delete obsolete did not complete on $sid (rman rc $rrc): $(rman_errors "$RUN_DIR/rman_delete_obsolete.txt")  (full: $RUN_DIR/rman_delete_obsolete.txt)"; return 1; }
  grep -qE 'RMAN-0[0-9]{4}|ORA-' "$RUN_DIR/rman_delete_obsolete.txt" && { warn "errors during delete: $(rman_errors "$RUN_DIR/rman_delete_obsolete.txt")"; return 1; }
  # the outcome, not the command: report obsolete again and say what is left
  local left="?"; rman_run "$sid" 600 "report obsolete;" >"$RUN_DIR/rman_report_obsolete_after.txt" 2>&1 && left="$(obsolete_count "$RUN_DIR/rman_report_obsolete_after.txt")"
  [ "$left" = 0 ] || warn "$left item(s) still obsolete after the delete (was $n): see $RUN_DIR/rman_report_obsolete_after.txt"
  log "deleted: $n obsolete item(s) listed, ${left} left. FRA now: $(sql_lines "$sid" "select round((space_used-space_reclaimable)*100/nullif(space_limit,0))||'% net' from v\$recovery_file_dest;" | head -1)"
}

# ---------------------------------------------------------------------------
report_cmd() { # <command> : one report over every database
  local cmd="$1" sids s
  sids="$(db_instances | grep -vE '^\+ASM|^-MGMTDB|^\+APX')"; [ -n "$ONLY_SID" ] && sids="$ONLY_SID"
  [ -n "$sids" ] || die "no running database instance (or --sid SID)"
  report_init "$RMAN_OUT/${HOST}_${cmd}_$(date '+%Y%m%d_%H%M%S')"
  say "rman-ops $cmd on: $(printf '%s' "$sids" | tr '\n' ' ') -> $OUT"
  for s in $sids; do
    h1 "Database $s"
    if ! sql_ok "$s"; then finding CRIT db "$s: cannot connect as sysdba"; continue; fi
    db_basics "$s"; say "database $s ($DBUN, $ROLE, $LOG_MODE)"
    [ -n "$(rman_bin "$s")" ] || finding CRIT backup "$s: no rman binary in $(db_home_of "$s")/bin (RMAN_CMD unset) - every RMAN command below is skipped; the SQL views still answer"
    printf '%s\n' "$SHOWALL" >"$RAW/rman_${s}_showall.txt"
    [ "$ROLE" != PRIMARY ] && para "_${ROLE}: backups may be taken here or on the primary; job history below is this database's own controlfile_"
    case "$cmd" in
      inspect) sec_inspect "$s";;
      validate) sec_validate "$s";;
      recovery-window) sec_recovery_window "$s";;
      zdlra) sec_zdlra "$s";;
      evidence|run) sec_inspect "$s"; sec_recovery_window "$s"; sec_zdlra "$s"; sec_validate "$s";;
    esac
  done
  findings_sync
  report_finish "rman-ops $cmd: $HOST" "$MAKE_TAR" >/dev/null
  [ "$QUIET" = 1 ] || { echo; print_findings; }
  printf '\n%s\n' "$OUT/REPORT.md"
  findings_rc
}

main() {
  load_config; refuse_root
  local cmd="${1:-}"; shift || true; parse_opts "$@"
  case "$cmd" in
    inspect|validate|recovery-window|zdlra|evidence|run) report_cmd "$cmd";;
    restore-test|crosscheck|delete-obsolete)
      local sid="$ONLY_SID"; [ -z "$sid" ] && [ "$(db_instances | grep -vE '^\+ASM|^-MGMTDB' | grep -c .)" = 1 ] && sid="$(db_instances | grep -vE '^\+ASM|^-MGMTDB')"
      [ -n "$sid" ] || die "$cmd needs --sid SID (running: $(db_instances | tr '\n' ' '))"
      sql_ok "$sid" || die "cannot connect to $sid as sysdba"
      case "$cmd" in restore-test) cmd_restore_test "$sid";; crosscheck) cmd_crosscheck "$sid";; delete-obsolete) cmd_delete_obsolete "$sid";; esac;;
    ""|-h|--help|help) usage;; *) die "Unknown command: $cmd";;
  esac
}
main "$@"
