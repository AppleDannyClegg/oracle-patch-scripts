# shellcheck shell=bash disable=SC2034,SC2016   # sourced by tests/dry-run-gate.sh and tests/false-success-gate.sh: ARGS*, FAIL_*, OK* are read there
# apex-export: one connection, SQLcl present, one application in one workspace, an existing repo with that app
cat >"$ANSWERS" <<'A'
db_name|FREE|PDB1|24.2.0|AXUSER
from apex_applications a|100|WS1|1|Sales|sales|3|2026-01-01 00:00:00|bob|1.0|SCHEMA1
from apex_workspaces w|1|WS1|SCHEMA1|2|1
from apex_workspace_apex_users|bob|-|Y|Y|N|-|SCHEMA1
apex_workspace_schemas|SCHEMA1
application_id=100|100 Sales v1.0 3 pages, updated 2026-01-01 00:00:00
owner from apex_applications|SCHEMA1
A
export SQLCL="$T/env/sqlcl" APEX_EXPORT_CONNECT="ax/pw@//h:1521/s" APEX_REPO="$T/env/repo" APEX_OUT="$T/env/out"
ARGS_restore="--app 100 --to HEAD --force"   # --force: confirm_typed cannot be answered without a terminal
OK_restore="^restored="   # restore exports the current state first and records that export (true: only the import fails)
# SQLcl fake: 'apex export -applicationid N -dir D' leaves D/fN.sql behind (SQLcl writes the file, the stub only records the call); everything else is the stub
printf '#!/bin/sh\nq=""; [ -t 0 ] || q="$(cat)"\nid="$(printf %%s "$q" | sed -n "s/.*-applicationid \\([0-9]*\\).*/\\1/p")"; d="$(printf %%s "$q" | sed -n "s/.*-dir \\([^ ]*\\).*/\\1/p")"\n[ -n "$id" ] && [ -n "$d" ] && echo "-- fake export" >"$d/f$id.sql"\nprintf %%s "$q" | exec "%s/sql" "$@"\n' "$STUB" >"$T/env/sqlcl"; chmod +x "$T/env/sqlcl"
# a repo that already holds application 100, so restore has a revision to take it from
mkdir -p "$T/env/repo/FREE/PDB1/WS1"; echo "-- f100 as committed" >"$T/env/repo/FREE/PDB1/WS1/f100.sql"
git -C "$T/env/repo" init -q 2>/dev/null; git -C "$T/env/repo" -c user.name=t -c user.email=t@t add -A; git -C "$T/env/repo" -c user.name=t -c user.email=t@t commit -q -m seed
