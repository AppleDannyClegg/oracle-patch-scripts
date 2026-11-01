# ords-patch: standalone ORDS 26.2.3 under a symlinked home, one pool, a newer release already unpacked
mkdir -p "$T/env/ords/ords-26.2.3/bin" "$T/env/ords/ords-26.3.0/bin" "$T/env/ords/config/global" "$T/env/ords/config/databases/default" "$T/env/ords/downloads"
printf '#!/bin/sh\necho "TOOL ords(home) $*" >>"$DRY_LOG"; echo 26.2.3\n' >"$T/env/ords/ords-26.2.3/bin/ords"; printf '#!/bin/sh\necho "TOOL ords(new) $*" >>"$DRY_LOG"; echo 26.3.0\n' >"$T/env/ords/ords-26.3.0/bin/ords"; chmod +x "$T/env/ords/ords-26.2.3/bin/ords" "$T/env/ords/ords-26.3.0/bin/ords"
ln -sfn "$T/env/ords/ords-26.2.3" "$T/env/ords/home"; touch "$T/env/ords/config/global/settings.xml" "$T/env/ords/config/databases/default/pool.xml"
cat >"$ANSWERS" <<'A'
con_name|PDB1
select cdb from|YES
log_mode|ARCHIVELOG
db_recovery_file_dest|/fra
dba_registry|1
A
export SQL_CMD="$STUB/sqlplus -S" ORDS_HOME="$T/env/ords/home" ORDS_CONFIG="$T/env/ords/config" ORDS_BASE="$T/env/ords" ORDS_ADMIN_USER=SYS ORDS_ADMIN_PASSWORD=x ORDS_URL=http://localhost:1/ords/
# a run dir that 'latest' would have left: the new release recorded
mkdir -p "$T/home/ords-patch/runs/r1"; printf 'new_dir=%s\nnew_version=26.3.0\nprev_dir=%s\nprev_version=26.2.3\nrestore_point=ORDSPATCH_X\npool_default=ok\n' "$T/env/ords/ords-26.3.0" "$T/env/ords/ords-26.2.3" >"$T/home/ords-patch/runs/r1/state"; ln -sfn "$T/home/ords-patch/runs/r1" "$T/home/ords-patch/runs/latest"
ARGS_rollback="--allow-flashback"   # the flashback branch must be reached, and under --dry-run must send nothing
