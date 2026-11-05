# shellcheck shell=bash disable=SC2034,SC2016   # sourced by tests/dry-run-gate.sh and tests/false-success-gate.sh: ARGS*, FAIL_*, OK* are read there
# rman-ops: one database FREE running (its pmon in the gate's ps), RMAN through a fake under $T/env/bin that hands every script to
# the gate's rman stub and models what RMAN prints around it - 'Recovery Manager complete.' when the stub accepted the script
# (rman_completed needs that line, the stub prints nothing), 'show all' and 'report obsolete' answered here (reads), and a
# 'delete noprompt obsolete' the stub accepted makes the next 'report obsolete' say 'no obsolete backups found'
mkdir -p "$T/env/bin" "$T/env/scratch"; echo ora_pmon_FREE >"$T/ps.txt"
cat >"$T/env/bin/rman" <<R
#!/bin/sh
q="\$(cat)"
case "\$q" in
  *"show all"*) echo "CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF 7 DAYS;"; echo "CONFIGURE CONTROLFILE AUTOBACKUP ON;"; echo "Recovery Manager complete."; exit 0;;
  *"report obsolete"*) if [ -e "$T/env/obsolete_deleted" ]; then echo "no obsolete backups found"
    else printf 'Report of obsolete backups and copies\nType                 Key    Completion Time    Filename/Handle\nBackup Set           12     01-OCT-26\n  Backup Piece       12     01-OCT-26          /u01/fra/FREE/backupset/x.bkp\nArchive Log          44     01-OCT-26          /u01/fra/FREE/archivelog/arch_44.arc\n'; fi
    echo "Recovery Manager complete."; exit 0;;
esac
printf '%s' "\$q" | "$STUB/rman" "\$@"; rc=\$?
# crosscheck is not a verb CHANGE_RE knows, so the stub accepts it: the expired summary it would print (one backup set, status X) lets
# the script reach its 'delete noprompt expired' - the change the gate fails
[ \$rc = 0 ] && case "\$q" in *"list expired backup summary"*) printf 'List of Backups\n===============\nKey     TY LV S Device Type Completion Time #Pieces #Copies Compressed Tag\n------- -- -- - ----------- --------------- ------- ------- ---------- ---\n12      B  F  X DISK        01-OCT-26       1       1       NO         TAG20261001T010000\n';; esac
[ \$rc = 0 ] && { echo "Recovery Manager complete."; case "\$q" in *"delete noprompt obsolete"*) touch "$T/env/obsolete_deleted";; esac; }
exit \$rc
R
chmod +x "$T/env/bin/rman"
cat >"$ANSWERS" <<'A'
db_unique_name.*log_mode.*database_role|FREE|ARCHIVELOG|PRIMARY
v\$datafile d where ts# not in|5|/u01/oradata/FREE/users01.dbf|100|8192
v\$datafile where file#=5 and name|0
A
export RMAN_CMD="$T/env/bin/rman" RESTORE_SCRATCH_DIR="$T/env/scratch" RMAN_TIMEOUT=30 RMAN_OUT="$T/env/out"
ARGS="--sid FREE"
