# shellcheck shell=bash disable=SC2034,SC2016   # sourced by tests/dry-run-gate.sh and tests/false-success-gate.sh: ARGS*, FAIL_*, OK* are read there
# ords-patch: standalone ORDS 26.2.3 under a symlinked home, one pool, a newer release already unpacked
mkdir -p "$T/env/ords/ords-26.2.3/bin" "$T/env/ords/ords-26.3.0/bin" "$T/env/ords/config/global" "$T/env/ords/config/databases/default" "$T/env/ords/downloads"
# each release's bin/ords answers --version itself and hands everything else to the gate's stub (so 'install' is recorded, and fails when the gate says so)
for v in 26.2.3 26.3.0; do printf '#!/bin/sh\n[ "$1" = --version ] && { echo %s; exit 0; }\nexec "%s/ords" "$@"\n' "$v" "$STUB" >"$T/env/ords/ords-$v/bin/ords"; chmod +x "$T/env/ords/ords-$v/bin/ords"; done
ln -sfn "$T/env/ords/ords-26.2.3" "$T/env/ords/home"; touch "$T/env/ords/config/global/settings.xml" "$T/env/ords/config/databases/default/pool.xml"
cat >"$ANSWERS" <<'A'
con_name|PDB1
select cdb from|YES
log_mode|ARCHIVELOG
db_recovery_file_dest|/fra
dba_registry|1
A
export SQL_CMD="$STUB/sqlplus -S" ORDS_HOME="$T/env/ords/home" ORDS_CONFIG="$T/env/ords/config" ORDS_BASE="$T/env/ords" ORDS_ADMIN_USER=SYS ORDS_ADMIN_PASSWORD=x ORDS_URL=http://localhost:1/ords/ START_TIMEOUT=5
# a run dir that 'latest' would have left: the new release recorded
mkdir -p "$T/home/ords-patch/runs/r1"; printf 'new_dir=%s\nnew_version=26.3.0\nprev_dir=%s\nprev_version=26.2.3\nrestore_point=ORDSPATCH_X\npool_default=ok\napplied=26.3.0\n' "$T/env/ords/ords-26.3.0" "$T/env/ords/ords-26.2.3" >"$T/home/ords-patch/runs/r1/state"; ln -sfn "$T/home/ords-patch/runs/r1" "$T/home/ords-patch/runs/latest"
# a release zip on disk (no internet in the gate): what 'latest' unpacks carries the version in a jar name, nothing else is read
mkdir -p "$T/env/zipsrc/lib" "$T/env/zipsrc/bin"; : >"$T/env/zipsrc/lib/ords-plugin-api-26.3.0.jar"; cp "$T/env/ords/ords-26.3.0/bin/ords" "$T/env/zipsrc/bin/ords"
(cd "$T/env/zipsrc" && zip -qr "$T/env/ords/downloads/ords-latest-20260101.zip" lib bin)
# a Java that preflight accepts (the gate's java stub says nothing to -version)
mkdir -p "$T/env/java/bin"; printf '#!/bin/sh\n[ "$1" = -version ] && { echo "openjdk version \\"17.0.12\\" 2024-07-16" >&2; exit 0; }\nexec "%s/java" "$@"\n' "$STUB" >"$T/env/java/bin/java"; chmod +x "$T/env/java/bin/java"; export JAVA_HOME="$T/env/java"
ARGS_rollback="--allow-flashback"   # the flashback branch must be reached, and under --dry-run must send nothing
# stop:ps_unreadable - ORDS is a process of ours (a sleep started here), pgrep finds it, kill works, and then ps cannot run: the stop
# must not end 'ORDS stopped' rc 0 (bcb193e: before it pid_alive read a ps that failed as 'gone'). No sqlplus call fails in this case
CASES_stop='ps_unreadable'; FAIL_stop__ps_unreadable='^never matches$'
case "$CMD:${CASE:-}" in stop:ps_unreadable) sleep 300 & echo $! >"$T/pgrep.txt"; : >"$T/ps.fail";; esac
