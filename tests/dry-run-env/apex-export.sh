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
export SQLCL="$STUB/sql" APEX_EXPORT_CONNECT="ax/pw@//h:1521/s" APEX_REPO="$T/env/repo" APEX_OUT="$T/env/out"
ARGS_restore="--app 100 --to HEAD"
