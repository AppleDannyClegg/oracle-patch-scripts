# shellcheck shell=bash disable=SC2034,SC2016   # sourced by tests/dry-run-gate.sh and tests/false-success-gate.sh: ARGS*, FAIL_*, OK* are read there
# exascale-space: escli is not one of the gates' stub tools, so the env supplies one at $T/env/bin/escli (ESCLI= points at it): it
# answers the reads itself - lscluster, lsstoragepool (pool1, HC, 20T provisionable), lsvault (vault v1, 9.5T used of the provisioned
# value kept in $T/env/exa/provHC, 95%: a CRIT heal acts on), lsfile (a 2G datafile no database claims) - and hands chvault and
# rmfile to a copy of the gate's own stub (same logging, same FAIL_RE), moving provHC when a chvault was accepted. FAIL_<cmd> names
# those verbs because CHANGE_RE does not know escli. One database FREE in ps for the RMAN side (purge, heal, run), RMAN through a
# fake that adds 'Recovery Manager complete.' around the gate's rman stub.
P="$T/env/exa"; mkdir -p "$T/env/bin" "$T/env/stubs" "$P"; cp "$STUB/sqlplus" "$T/env/stubs/escli"; chmod +x "$T/env/stubs/escli"
echo 10.0000T >"$P/provHC"
cat >"$T/env/bin/escli" <<E
#!/bin/sh
case "\$1" in
  lscluster) printf 'name                 excl1\nversion              25.1.0.0.0\n'; exit 0;;
  lsstoragepool) [ "\$2" = --detail ] || exit 0; printf 'name                 pool1\nmediaType            HC\nspaceRaw             100.0000T\nspaceUsed            60.0000T\nspaceProvisionable   20.0000T\nspaceProvisioned     70.0000T\nhighDataStatus       normal\nhighRecoStatus       normal\n'; exit 0;;
  lsvault) case "\$*" in
      *--attributes*) echo "name                 v1"; exit 0;;
      *--provision*) exit 0;;
      *--detail*) printf 'name                 v1\nspaceUsedHC          9.5000T\nspaceProvHC          %s\nspaceUsedEF          0\nspaceProvEF          0\nspaceUsedXT          0\nspaceProvXT          0\nflags                \n' "\$(cat "$P/provHC")"; exit 0;;
      *) printf 'name   spaceUsedHC   spaceProvHC\nv1     9.5000T       %s\n' "\$(cat "$P/provHC")"; exit 0;; esac;;
  lsfile) case "\$*" in *--detail*) printf 'name                 %s\nspaceUsed            2.0000G\nfileType             datafile\nusedBy               \n' "\$2"; exit 0;; *) exit 0;; esac;;
  chvault|rmfile) "$T/env/stubs/escli" "\$@"; rc=\$?; [ \$rc = 0 ] && case "\$*" in *spaceProvHC=*) printf '%s\n' "\$*" | sed 's/.*spaceProvHC=//; s/ .*//' >"$P/provHC";; esac; exit \$rc;;
esac
exit 0
E
chmod +x "$T/env/bin/escli"
cat >"$T/env/bin/rman" <<R
#!/bin/sh
q="\$(cat)"; printf '%s' "\$q" | "$STUB/rman" "\$@"; rc=\$?; [ \$rc = 0 ] && echo "Recovery Manager complete."; exit \$rc
R
chmod +x "$T/env/bin/rman"
echo ora_pmon_FREE >"$T/ps.txt"
cat >"$ANSWERS" <<'A'
backup_count>=|12 files 3.5 GB
backup_count=0|0
v\$parameter where name in|1
v\$datafile where name like|4
A
export ESCLI="$T/env/bin/escli" RMAN_CMD="$T/env/bin/rman" EXA_OUT="$T/env/out" EXA_HISTORY="$T/env/hist" RMAN_TIMEOUT=30
# the grow that happened, for rollback and verify: provHC is already the new value
R="$T/home/exascale-space/runs/20260101-000000-grow-v1"; mkdir -p "$R"
printf 'vault=v1\nold_spaceProvHC=10995116277760\nnew_spaceProvHC=13194139533312\npool_HC=pool1\nmode_HC=attributes\napplied_spaceProvHC=1\n' >"$R/state"
case "$CMD" in rollback|verify) echo 13194139533312 >"$P/provHC";; esac
ARGS=""; ARGS_grow="v1 --hc +2T"; ARGS_release="@v1/old/file.dbf --force"; ARGS_purge_archivelogs="--sid FREE"
# the changing escli verbs (CHANGE_RE knows none): grow and rollback change with chvault, release with rmfile; purge, heal and run
# change through RMAN's delete, which CHANGE_RE has. --force on release stands in for the typed confirmation (confirm_typed is
# 'type the word' on a terminal, --force off one)
FAIL_grow='^escli .*chvault'; FAIL_rollback='^escli .*chvault'; FAIL_release='^escli .*rmfile'
