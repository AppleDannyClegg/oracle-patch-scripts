#!/usr/bin/env bash
# apex-export.sh - APEX applications as code: export every application (split into one file per component,
# export dates stripped), workspace definitions, workspace users (web password hashes replaced by a placeholder), instance parameters (no secrets)
# into a git repository laid out <repo>/<db>/<pdb>/<WORKSPACE>/f<ID>/, commit only when something changed, push if
# asked, report what changed and who changed it, and restore an application from any commit or date (after
# exporting the current state first) - optionally under a new application id. SQLcl "apex export" with the password
# on stdin; the APEXExport java class as a fallback. Meant for a nightly cron and for the "who broke page 12 at 16:40"
# question.
#
# Usage: apex-export.sh <command> [options]
#
# Commands
#   inspect              Connections, APEX version, workspaces, applications (id, name, pages, last change, by whom),
#                        what the repo holds and what is newer in the database; --report writes REPORT.md
#   export               Export into the repo: --app ID (repeatable), --workspace NAME, --since DAYS (changed apps only;
#                        apps missing from the repo always), default everything; --pdb NAME or --all for several databases
#   commit               git add/commit the repo when there is a diff (message lists the changed apps); --push pushes
#   diff [--rev REV]     What changed since the last commit (or since REV / --since DAYS): files, apps, pages
#   restore --app ID --to <commit|YYYY-MM-DD[ HH:MM]> [--as-new-id N] [--workspace NAME]
#                        Export the current state and commit it, take f<ID> from that revision, import it (same id, or N)
#   verify               Repo clean, every application exported, nothing newer in the database, cron installed, last run
#   install-cron         Add the nightly "run --all" line to the crontab (APEX_CRON, default 02:30)
#   run                  export --since 1 (all connections), commit (--push when APEX_PUSH=1), diff --report
#
# Options
#   --app ID  --workspace NAME  --since DAYS  --pdb NAME  --all  --push  --rev REV  --to REV|DATE  --as-new-id N
#   --repo DIR  --out DIR  --report  --dry-run  --yes  --force  --verbose
#
# Config (apex-export.conf, mode 600 - it holds the connect string): APEX_EXPORT_CONNECT="user/pass@//host:1521/pdb"
# (a user with APEX_ADMINISTRATOR_ROLE, or the workspace schema for one workspace), APEX_EXPORT_CONNECT_<NAME> for more
# databases (--pdb NAME / --all), APEX_REPO (~/apex-export/repo), APEX_REMOTE (git remote url for the first push),
# SQLCL (path to sql), APEX_HOME + JAVA_HOME + OJDBC_JAR for the java fallback, APEX_EXPORT_OPTS, APEX_CRON, APEX_PUSH,
# APEX_OUT (reports), APEX_STALE_DAYS (7).

# shellcheck disable=SC2034
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="apex-export"; VERSION="1.0.0"
# shellcheck source=../../lib/oracle-lib.sh
. "$SCRIPT_DIR/../../lib/oracle-lib.sh" || { echo "lib/oracle-lib.sh not found" >&2; exit 1; }

APPS=(); WS=""; SINCE=""; PDB_NAME=""; ALL=0; PUSH=0; REV=""; TO=""; NEW_ID=""; REPORT_OUT=0
APEX_REPO="${APEX_REPO:-$(output_path apex-export)/repo}"; APEX_OUT="${APEX_OUT:-$(output_path apex-export)}"; APEX_STALE_DAYS="${APEX_STALE_DAYS:-7}"; APEX_CRON="${APEX_CRON:-30 2 * * *}"; APEX_PUSH="${APEX_PUSH:-0}"
APEX_EXPORT_OPTS="${APEX_EXPORT_OPTS:--split -skipExportDate -expOriginalIds -expPubReports -expACLAssignments}"
CONNECT=""; CONN_NAME=""; DBN=""; PDBN=""; TARGET=""   # per connection: TARGET=<repo>/<db>/<pdb>
TOOL_MODE=""   # sqlcl | java

usage() { usage_from_header "$0"; }
parse_opts() {
  ARGS=()
  while [ $# -gt 0 ]; do case "$1" in
    --app) optchk "$@"; APPS+=("$2"); shift 2;; --workspace) optchk "$@"; WS="$2"; shift 2;; --since) optchk "$@"; SINCE="$2"; shift 2;; --pdb) optchk "$@"; PDB_NAME="$2"; shift 2;; --all) ALL=1; shift;; --push) PUSH=1; shift;; --rev) optchk "$@"; REV="$2"; shift 2;; --to) optchk "$@"; TO="$2"; shift 2;; --as-new-id) optchk "$@"; NEW_ID="$2"; shift 2;;
    --repo) optchk "$@"; APEX_REPO="$2"; shift 2;; --out) optchk "$@"; APEX_OUT="$2"; shift 2;; --report) REPORT_OUT=1; shift;; --dry-run) DRY_RUN=1; shift;; --yes) ASSUME_YES=1; shift;; --force) FORCE=1; shift;; --verbose) VERBOSE=1; shift;; --run-dir) optchk "$@"; RUN_DIR="$2"; shift 2;;
    -h|--help) usage; exit 0;; --*) die "Unknown option: $1";; *) ARGS+=("$1"); shift;; esac; done
}

# ---------------------------------------------------------------------------
# connections and SQL
# ---------------------------------------------------------------------------
conn_names() { compgen -A variable | grep -E '^APEX_EXPORT_CONNECT_' | sed 's/^APEX_EXPORT_CONNECT_//'; [ -n "${APEX_EXPORT_CONNECT:-}" ] && echo default; return 0; }
select_conn() { # <name>
  CONN_NAME="$1"; if [ "$1" = default ]; then CONNECT="${APEX_EXPORT_CONNECT:-}"; else local v="APEX_EXPORT_CONNECT_$1"; CONNECT="${!v:-}"; fi
  [ -n "$CONNECT" ] || die "no connect string for '$1' (APEX_EXPORT_CONNECT or APEX_EXPORT_CONNECT_$1 in apex-export.conf)"
  [[ "$CONNECT" == *@* ]] || die "APEX_EXPORT_CONNECT must look like user/password@//host:port/service"
}
conn_user() { printf '%s' "${CONNECT%%/*}"; }
conn_pass() { local r="${CONNECT#*/}"; printf '%s' "${r%@*}"; }
conn_db() { printf '%s' "${CONNECT##*@}"; }   # after the LAST @ (conn_pass keeps everything before it: a password may contain @)
find_tools() {
  SQLCL="${SQLCL:-$(command -v sql 2>/dev/null || ls /opt/oracle/sqlcl/bin/sql "$HOME"/sqlcl/bin/sql /u01/app/oracle/product/sqlcl/bin/sql 2>/dev/null | head -1)}"
  SQLPLUS="${SQLPLUS:-$(command -v sqlplus 2>/dev/null || ls /u01/app/oracle/product/*/dbhome*/bin/sqlplus "${ORACLE_HOME:-/nonexistent}/bin/sqlplus" 2>/dev/null | head -1)}"
  if [ -x "${SQLCL:-}" ]; then TOOL_MODE=sqlcl
  elif [ -n "${APEX_HOME:-}" ] && [ -f "$APEX_HOME/utilities/oracle/apex/APEXExport.class" ]; then TOOL_MODE=java; [ -x "${SQLPLUS:-}" ] || die "java mode still needs sqlplus for the catalogue queries"
    JAVA="${JAVA_HOME:+$JAVA_HOME/bin/java}"; JAVA="${JAVA:-$(command -v java)}"; [ -x "${JAVA:-}" ] || die "java not found (JAVA_HOME)"
    OJDBC_JAR="${OJDBC_JAR:-$(ls "${ORACLE_HOME:-/nonexistent}"/jdbc/lib/ojdbc8.jar /u01/app/oracle/product/*/dbhome*/jdbc/lib/ojdbc8.jar 2>/dev/null | head -1)}"; [ -f "${OJDBC_JAR:-}" ] || die "ojdbc8.jar not found (OJDBC_JAR)"
  else die "neither SQLcl (SQLCL=/path/to/sql) nor APEXExport (APEX_HOME=/path/to/apex) found"; fi
  dbg "tool: $TOOL_MODE sqlcl=$SQLCL sqlplus=$SQLPLUS"
}
# ax_sql <sql>: run SQL on the current connection, password on stdin, rows only (heading off). Errors -> return 1
ax_sql() {
  local cmd; if [ -x "${SQLCL:-}" ]; then cmd="$SQLCL -S /nolog"; else cmd="$SQLPLUS -S /nolog"; fi
  local out; out="$(printf 'connect %s\nset heading off feedback off pagesize 0 linesize 4000 trimspool on tab off verify off echo off\nalter session set nls_date_format='"'"'YYYY-MM-DD HH24:MI:SS'"'"';\n%s\nexit\n' "$CONNECT" "$1" | to "$SQL_TIMEOUT" $cmd 2>&1)"; local rc=$?
  [ "$rc" = 0 ] || { err "sql exited with status $rc$([ "$rc" = 124 ] && echo " (timeout after ${SQL_TIMEOUT}s)"): $(printf '%s\n' "$out" | redact | tail -2 | tr '\n' ' ')"; return 1; }   # a killed query returned its partial rows as the answer
  if printf '%s\n' "$out" | grep -qE '^(ORA-[0-9]+|SP2-[0-9]+|PLS-[0-9]+|ERROR|Error starting)'; then printf '%s\n' "$out" | redact | grep -E '^(ORA-|SP2-|PLS-|ERROR|Error)' | head -3 >&2; return 1; fi
  printf '%s\n' "$out" | sed '/^[[:space:]]*$/d; s/^ *//; s/ *$//'
}
# ax_export <dir> <options...>: one export call into <dir>; logs the command (never the password)
ax_export() {
  local dir="$1"; shift; mkdir -p "$dir"
  if [ "$TOOL_MODE" = sqlcl ]; then
    log "apex export $* -dir $dir"; [ "$DRY_RUN" = 1 ] && return 0
    local out rc=1; out="$(cd "$dir" && printf 'connect %s\napex export %s -dir %s\nexit\n' "$CONNECT" "$*" "$dir" | to "${EXPORT_TIMEOUT:-1800}" "$SQLCL" -S /nolog 2>&1)"; rc=$?; printf '%s\n' "$out" | redact >>"$LOG_FILE"
    [ "$rc" = 0 ] || { printf '%s\n' "$out" | redact | grep -E 'ORA-[0-9]+|SP2-[0-9]+|PLS-[0-9]+|Exception' | head -3 >&2; err "sqlcl export exited with status $rc"; return 1; }
    printf '%s' "$out" | grep -qE 'ORA-[0-9]+|SP2-[0-9]+|PLS-[0-9]+|Exception' && { printf '%s\n' "$out" | redact | grep -E 'ORA-[0-9]+|SP2-[0-9]+|PLS-[0-9]+|Exception' | head -3 >&2; return 1; }
  else
    # APEXExport takes the password only as -password on its command line: every user on the host can read it from
    # ps / /proc while the export runs. Refused unless the operator accepts that explicitly in apex-export.conf.
    [ "${APEX_JAVA_PASSWORD_ON_ARGV:-no}" = yes ] || die "java APEXExport puts the export password on the java command line (visible in ps to every user for the whole export). Install SQLcl (SQLCL=/path/to/sql; 'apex export' takes the password on stdin), or set APEX_JAVA_PASSWORD_ON_ARGV=yes in apex-export.conf to accept the exposure"
    warn "java APEXExport: APEX_JAVA_PASSWORD_ON_ARGV=yes - the password is visible in the process list while the export runs"
    log "java oracle.apex.APEXExport -db $(conn_db) -user $(conn_user) $* -dir $dir"; [ "$DRY_RUN" = 1 ] && return 0
    (cd "$dir" && to "${EXPORT_TIMEOUT:-1800}" "$JAVA" -cp "$APEX_HOME/utilities:$OJDBC_JAR" oracle.apex.APEXExport -db "$(conn_db | sed 's#^//##')" -user "$(conn_user)" -password "$(conn_pass)" "$@" -dir "$dir") 2>&1 | redact >>"$LOG_FILE"   # secret-on-argv: accepted (APEX_JAVA_PASSWORD_ON_ARGV=yes only)
    local -a ps=("${PIPESTATUS[@]}"); [ "${ps[0]:-1}" = 0 ] && [ "${ps[1]:-1}" = 0 ] || { err "java APEXExport failed (status ${ps[0]:-unknown})"; return 1; }
  fi
  return 0
}
db_identity() { # sets DBN PDBN TARGET and checks APEX
  local r; r="$(ax_sql "select sys_context('userenv','db_name')||'|'||sys_context('userenv','con_name')||'|'||nvl((select version_no from apex_release),'none')||'|'||user from dual;")" || { err "cannot connect as $(conn_user)@$(conn_db) (see $LOG_FILE)"; return 1; }
  IFS='|' read -r DBN PDBN APEXV AXUSER <<<"$r"; [ "$APEXV" != none ] || { err "no APEX in $DBN/$PDBN (apex_release not visible to $(conn_user))"; return 1; }
  PDBN="${PDBN//\$/}"; TARGET="$APEX_REPO/$DBN/$PDBN"; log "$CONN_NAME: $DBN/$PDBN APEX $APEXV as $AXUSER"
}
# catalogue: application rows id|workspace|workspace_id|name|alias|pages|last_updated_on|last_updated_by|version|owner
app_rows() {
  ax_sql "select a.application_id||'|'||a.workspace||'|'||a.workspace_id||'|'||replace(a.application_name,'|','/')||'|'||nvl(a.alias,'-')||'|'||a.pages||'|'||greatest(nvl(a.last_updated_on,a.created_on),nvl((select max(p.last_updated_on) from apex_application_pages p where p.application_id=a.application_id),a.created_on))||'|'||nvl(a.last_updated_by,'-')||'|'||nvl(a.version,'-')||'|'||a.owner from apex_applications a $([ -n "$WS" ] && echo "where upper(a.workspace)=upper('$WS')") order by a.workspace, a.application_id;"
}
ws_rows() { ax_sql "select workspace_id||'|'||workspace||'|'||nvl(primary_schema,'-')||'|'||nvl((select count(*) from apex_workspace_apex_users u where u.workspace_id=w.workspace_id),0)||'|'||nvl((select count(*) from apex_applications a where a.workspace_id=w.workspace_id),0) from apex_workspaces w $([ -n "$WS" ] && echo "where upper(workspace)=upper('$WS')") order by workspace;"; }

# ---------------------------------------------------------------------------
# repo
# ---------------------------------------------------------------------------
repo_init() {
  mkdir -p "$APEX_REPO"; [ -d "$APEX_REPO/.git" ] || { log "git init $APEX_REPO"; [ "$DRY_RUN" = 1 ] && return 0; git -C "$APEX_REPO" init -q; printf '*.log\n*.tmp\n.DS_Store\n' >"$APEX_REPO/.gitignore"; git -C "$APEX_REPO" add .gitignore; git -C "$APEX_REPO" -c user.name=apex-export -c user.email=apex-export@localhost commit -q -m "apex-export: repository created on $HOST"; [ -n "${APEX_REMOTE:-}" ] && git -C "$APEX_REPO" remote add origin "$APEX_REMOTE"; }
  return 0
}
g() { git -C "$APEX_REPO" -c user.name="${GIT_AUTHOR_NAME:-apex-export}" -c user.email="${GIT_AUTHOR_EMAIL:-apex-export@$HOST}" "$@"; }
normalise() { # <dir>: strip export dates/authors so unchanged apps give no diff
  [ -d "$1" ] || return 0
  find "$1" -type f -name '*.sql' -print0 | xargs -0 sed -i.axtmp -E -e '/^--   (Date and time|Exported By|Export Date|Generated by|Date and Time)[[:space:]]*:/d; /^prompt +--  +Date and time:/d' \
    -e "s/(p_web_password[[:space:]]*=>[[:space:]]*)'[^']*'/\1'***REMOVED-BY-APEX-EXPORT***'/" 2>/dev/null; find "$1" -name '*.axtmp' -delete   # workspace user password hashes never reach the repo
}
meta_write() { # <file> <row>
  IFS='|' read -r id ws wsid name alias pages upd by ver owner <<<"$2"
  printf 'application_id=%s\nworkspace=%s\nworkspace_id=%s\nname=%s\nalias=%s\npages=%s\nlast_updated_on=%s\nlast_updated_by=%s\nversion=%s\nowner=%s\n' "$id" "$ws" "$wsid" "$name" "$alias" "$pages" "$upd" "$by" "$ver" "$owner" >"$1"
}
meta_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }
export_app() { # <row>
  local row="$1" id ws wsid name alias pages upd by ver owner; IFS='|' read -r id ws wsid name alias pages upd by ver owner <<<"$row"
  local wsdir="$TARGET/$ws" dir="$TARGET/$ws/f$id"
  say "  f$id $name ($ws, $pages pages, changed $upd by $by)"
  [ "$DRY_RUN" = 1 ] && { log "export application $id -> $dir"; return 0; }
  local tmp="$RUN_DIR/exp_$id"; rm -rf "$tmp"; mkdir -p "$tmp"
  # shellcheck disable=SC2086
  ax_export "$tmp" -applicationid "$id" $APEX_EXPORT_OPTS || { err "export of application $id failed"; return 1; }
  local got; got="$(find "$tmp" -maxdepth 1 -name "f$id*" | head -1)"; [ -n "$got" ] || { err "application $id: export produced nothing in $tmp"; return 1; }
  mkdir -p "$wsdir"; rm -rf "$dir" "$dir.sql"
  if [ -d "$got" ]; then mv "$got" "$dir"; else mv "$got" "$dir.sql"; fi || { err "application $id: cannot move the export into $dir"; rm -rf "$tmp"; return 1; }   # -split gives a directory; a plain export gives f<ID>.sql
  normalise "$dir"; [ -f "$dir.sql" ] && normalise "$wsdir"
  meta_write "$wsdir/f$id.meta" "$row" || { err "application $id: cannot write $wsdir/f$id.meta (disk full?) - the export is on disk but unrecorded"; rm -rf "$tmp"; return 1; }; rm -rf "$tmp"
}
export_workspace() { # <ws row>
  local wsid ws schema users apps; IFS='|' read -r wsid ws schema users apps <<<"$1"
  local wsdir="$TARGET/$ws/workspace"; say "  workspace $ws (id $wsid, schema $schema, $users users, $apps apps)"
  [ "$DRY_RUN" = 1 ] && return 0; mkdir -p "$wsdir"
  local tmp="$RUN_DIR/ws_$wsid"; rm -rf "$tmp"; mkdir -p "$tmp"
  ax_export "$tmp" -workspaceid "$wsid" -expWorkspace -expFiles -expACLAssignments -skipExportDate && { find "$tmp" -maxdepth 1 -type f -name 'w*.sql' -exec mv {} "$wsdir/" \; ; normalise "$wsdir"; } || warn "workspace export of $ws failed (needs APEX_ADMINISTRATOR_ROLE); continuing with the catalogue"
  ax_sql "select user_name||'|'||nvl(email,'-')||'|'||is_admin||'|'||is_app_developer||'|'||nvl(account_locked,'N')||'|'||nvl(to_char(account_expiry),'-')||'|'||nvl(default_schema,'-') from apex_workspace_apex_users where workspace_id=$wsid order by user_name;" | sed '1i\
user|email|admin|developer|locked|expires|default_schema' >"$wsdir/users.txt" 2>/dev/null
  ax_sql "select schema from apex_workspace_schemas where workspace_id=$wsid order by 1;" >"$wsdir/schemas.txt" 2>/dev/null
  rm -rf "$tmp"
}
export_instance() {
  local idir="$TARGET/instance"; [ "$DRY_RUN" = 1 ] && return 0; mkdir -p "$idir"
  { echo "application_id|workspace|workspace_id|name|alias|pages|last_updated_on|last_updated_by|version|owner"; app_rows; } >"$idir/applications.txt"
  { echo "workspace_id|workspace|primary_schema|users|applications"; ws_rows; } >"$idir/workspaces.txt"
  ax_sql "select name||'|'||case when regexp_like(name,'PASSWORD|SECRET|KEY|WALLET|TOKEN','i') then '***' else nvl(value,'') end from apex_instance_parameters order by name;" >"$idir/parameters.txt" 2>/dev/null || echo "(apex_instance_parameters needs APEX_ADMINISTRATOR_ROLE)" >"$idir/parameters.txt"
  printf 'apex_version=%s\ndb=%s\npdb=%s\nexport_user=%s\ntool=%s\nopts=%s\n' "$APEXV" "$DBN" "$PDBN" "$AXUSER" "$TOOL_MODE" "$APEX_EXPORT_OPTS" >"$idir/export.meta"
}
apps_to_export() { # rows to export under --app/--workspace/--since
  local rows; rows="$(app_rows)" || { err "cannot list the applications of $DBN/$PDBN"; return 1; }
  if [ ${#APPS[@]} -gt 0 ]; then local a; for a in "${APPS[@]}"; do printf '%s\n' "$rows" | grep -q "^$a|" || { err "application $a does not exist in $DBN/$PDBN"; return 1; }; done
    local re; re="$(printf '%s|' "${APPS[@]}")"; printf '%s\n' "$rows" | grep -E "^(${re%|})\|"; return 0; fi
  if [ -n "$SINCE" ]; then
    local cutoff; cutoff="$(if [ "$GNU_DATE" = 1 ]; then date -d "-$SINCE days" '+%Y-%m-%d %H:%M:%S'; else date -v-"$SINCE"d '+%Y-%m-%d %H:%M:%S'; fi)"
    printf '%s\n' "$rows" | while IFS='|' read -r id ws rest; do local upd; upd="$(printf '%s' "$rest" | cut -d'|' -f5)"
      if [ ! -d "$TARGET/$ws/f$id" ] && [ ! -f "$TARGET/$ws/f$id.sql" ]; then echo "$id|$ws|$rest"; elif [ "$upd" \> "$cutoff" ] || [ "$upd" != "$(meta_get "$TARGET/$ws/f$id.meta" last_updated_on)" ]; then echo "$id|$ws|$rest"; fi; done; return 0
  fi
  printf '%s\n' "$rows"
}
for_each_conn() { # <function>: run over --pdb / --all / default
  local names; if [ "$ALL" = 1 ]; then names="$(conn_names)"; elif [ -n "$PDB_NAME" ]; then names="$PDB_NAME"; else names="$(conn_names | grep -x default || conn_names | head -1)"; fi
  [ -n "$names" ] || die "no APEX_EXPORT_CONNECT* in the config"
  local n rc=0; for n in $names; do select_conn "$n"; db_identity || { rc=1; continue; }; "$@" || rc=1; done; return $rc
}
do_export() {
  say "== $DBN/$PDBN ($CONN_NAME): export to $TARGET"; mkdir -p "$TARGET"
  local rows; rows="$(apps_to_export)" || { state_set "exported_${CONN_NAME}" "failed: cannot list applications"; return 1; }; local n=0 fail=0 row
  if [ -z "$rows" ]; then say "  nothing changed$([ -n "$SINCE" ] && echo " in the last $SINCE day(s)")"; else
    while IFS= read -r row; do [ -n "$row" ] || continue; export_app "$row" && n=$((n+1)) || fail=$((fail+1)); done <<<"$rows"; fi
  # workspaces: only when exporting everything or a named workspace (cheap enough nightly as well: definitions only)
  local wr; while IFS= read -r wr; do [ -n "$wr" ] || continue; [ -n "$SINCE" ] && [ ${#APPS[@]} -gt 0 ] && continue; export_workspace "$wr"; done < <(ws_rows)
  export_instance
  # applications deleted in the database: keep the files, mark them so verify/report see it
  if [ ${#APPS[@]} = 0 ] && [ -z "$WS" ]; then
    local all; if all="$(app_rows)"; then
      local d; for d in "$TARGET"/*/f[0-9]*.meta; do [ -f "$d" ] || continue; local id; id="$(basename "$d" .meta | tr -d f)"
        if printf '%s\n' "$all" | grep -q "^$id|"; then sed -i.axtmp '/^deleted_in_db=/d' "$d" 2>/dev/null; rm -f "$d.axtmp"   # back again (restored): the mark goes
        else grep -q '^deleted_in_db=' "$d" || { warn "application $id ($(meta_get "$d" name)) no longer exists in $DBN/$PDBN; the last export stays in the repo"; echo "deleted_in_db=$(date '+%Y-%m-%d')" >>"$d"; }; fi
      done
    else warn "cannot list the applications: deleted-in-db check skipped"; fi
  fi
  state_set "exported_${CONN_NAME}" "$n ok, $fail failed"; [ "$fail" = 0 ] || return 1
  say "  $n application(s) exported"
}
cmd_export() { init_run_dir export; find_tools; repo_init; for_each_conn do_export; }

cmd_commit() {
  init_run_dir commit; [ -d "$APEX_REPO/.git" ] || die "$APEX_REPO is not a git repository (export first)"
  g add -A . >/dev/null; local st; st="$(g status --porcelain)"; [ -n "$st" ] || { say "nothing to commit in $APEX_REPO"; return 0; }
  local apps; apps="$(printf '%s\n' "$st" | awk '{print $2}' | grep -oE '[^/]+/[^/]+/[^/]+/f[0-9]+' | sort -u)"; local nf; nf="$(printf '%s\n' "$st" | wc -l | tr -d ' ')"
  local msg; msg="apex-export $HOST: $(printf '%s\n' "$apps" | grep -c . ) application(s), $nf file(s) changed"$'\n\n'"$(printf '%s\n' "$apps" | while IFS= read -r a; do [ -n "$a" ] || continue; local m; m="$APEX_REPO/${a%/f*}/$(basename "$a").meta"; printf '%s  %s  (changed %s by %s)\n' "$a" "$(meta_get "$m" name)" "$(meta_get "$m" last_updated_on)" "$(meta_get "$m" last_updated_by)"; done)"
  printf '%s\n' "$msg" | tee "$RUN_DIR/commit_msg.txt"; [ "$DRY_RUN" = 1 ] && { g reset -q; return 0; }
  g commit -q -F "$RUN_DIR/commit_msg.txt" || die "git commit failed in $APEX_REPO (index.lock? hook?) - nothing committed"; say "committed $(g rev-parse --short HEAD)"
  if [ "$PUSH" = 1 ] || [ "$APEX_PUSH" = 1 ]; then g remote get-url origin >/dev/null 2>&1 || die "no 'origin' remote (APEX_REMOTE= in the config before the first export, or git remote add origin ...)"; if g push -q -u origin HEAD >"$RUN_DIR/push.log" 2>&1; then say "pushed"; else tail -3 "$RUN_DIR/push.log" >&2; die "git push failed (see $RUN_DIR/push.log) - the commit is local only"; fi; fi   # the status used to be tail's, so a failed push said 'pushed'
}

cmd_diff() {
  init_run_dir diff; [ -d "$APEX_REPO/.git" ] || die "$APEX_REPO is not a git repository"
  local base="${REV:-}"; [ -z "$base" ] && [ -n "$SINCE" ] && { base="$(g rev-list -1 --before="$SINCE days ago" HEAD 2>/dev/null)"; [ -z "$base" ] && base="$(g rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)"; }; [ -z "$base" ] && base="HEAD"
  report_init "$([ "$REPORT_OUT" = 1 ] && echo "$APEX_OUT/${HOST}_apex_$(date '+%Y%m%d_%H%M%S')" || echo "$RUN_DIR/report")"
  h1 "APEX export repo $APEX_REPO on $HOST"; kv "head" "$(g log -1 --format='%h %ci %s' | head -1)"; kv "compared with" "$base"; kv "commits" "$(g rev-list --count HEAD)"; kv_end
  h2 "Commits since $base"; fence_start; g log --format='%h %ci %s' "$base"..HEAD 2>/dev/null | head -50 >>"$REPORT"; [ "$base" = HEAD ] && echo "(working tree vs HEAD)" >>"$REPORT"; fence_end
  h2 "Changed applications"; local chg; chg="$( { g diff --name-only "$base" 2>/dev/null; g status --porcelain | awk '{print $2}'; } | sort -u | grep -oE '^[^/]+/[^/]+/[^/]+/f[0-9]+/' | sort | uniq -c | sort -rn | sed 's#/$##')"
  if [ -n "$chg" ]; then table_head files app name changed by pages
    printf '%s\n' "$chg" | while read -r n a; do local m; m="$APEX_REPO/${a%/f*}/$(basename "$a").meta"; table_row "$n" "$a" "$(meta_get "$m" name)" "$(meta_get "$m" last_updated_on)" "$(meta_get "$m" last_updated_by)" "$(g diff --name-only "$base" -- "$a" 2>/dev/null | grep -c 'pages/page_')"; done; printf '\n' >>"$REPORT"
    printf '%s\n' "$chg" | while read -r n a; do finding INFO apex "$a $(meta_get "$APEX_REPO/${a%/f*}/$(basename "$a").meta" name): $n file(s) changed, last by $(meta_get "$APEX_REPO/${a%/f*}/$(basename "$a").meta" last_updated_by)"; done
  else para "_no application changed_"; fi
  h2 "Changed pages"; fence_start; { g diff --name-only "$base" 2>/dev/null; g status --porcelain | awk '{print $2}'; } | grep -E 'pages/page_[0-9]+\.sql' | sed -E 's#^([^/]+/[^/]+/[^/]+/f[0-9]+)/.*/page_0*([0-9]+)\.sql#\1 page \2#' | sort -u | head -100 >>"$REPORT"; fence_end
  h2 "Deleted / new applications"; grep -l '^deleted_in_db=' "$APEX_REPO"/*/*/*/f*.meta 2>/dev/null | while IFS= read -r m; do finding WARN apex "$(printf '%s' "${m#"$APEX_REPO"/}" | sed 's/\.meta$//') $(meta_get "$m" name) was deleted in the database on $(meta_get "$m" deleted_in_db); last export kept in the repo"; para "deleted: ${m#"$APEX_REPO"/}"; done
  g diff --name-only --diff-filter=A "$base" 2>/dev/null | grep -E '/f[0-9]+\.meta$' | while IFS= read -r m; do finding INFO apex "new application $(printf '%s' "$m" | sed 's/\.meta$//') $(meta_get "$APEX_REPO/$m" name)"; done
  h2 "git diff --stat"; fence_start; g diff --stat "$base" 2>/dev/null | tail -40 >>"$REPORT"; fence_end
  findings_sync; print_findings 'CRIT|WARN|INFO'
  if [ "$REPORT_OUT" = 1 ]; then report_finish "apex-export: $APEX_REPO" 0 >/dev/null; fi; return 0
}

cmd_restore() {
  [ ${#APPS[@]} = 1 ] && [ -n "$TO" ] || die "restore --app ID --to <commit|date> [--as-new-id N] [--workspace NAME] [--pdb NAME]"
  init_run_dir restore; find_tools; [ -d "$APEX_REPO/.git" ] || die "$APEX_REPO is not a git repository"
  for_each_conn : || die "cannot reach the database"; local id="${APPS[0]}"
  local rev; rev="$(g rev-parse --verify -q "$TO^{commit}" 2>/dev/null)"; [ -z "$rev" ] && rev="$(g rev-list -1 --before="$TO" HEAD 2>/dev/null)"; [ -n "$rev" ] || die "no commit for '$TO' (a hash, tag, or a date like 2026-10-30 16:00)"
  local path; path="$(g ls-tree -r --name-only "$rev" | grep -E "^$DBN/$PDBN/[^/]+/f$id(/install\.sql|\.sql)$" | head -1)"; [ -n "$path" ] || die "application $id of $DBN/$PDBN is not in commit $rev"
  local ws; ws="$(printf '%s' "$path" | cut -d/ -f3)"; [ -n "$WS" ] && ws="$WS"
  local tgt="${NEW_ID:-$id}" schema; schema="$(ax_sql "select nvl((select owner from apex_applications where application_id=$id),(select primary_schema from apex_workspaces where upper(workspace)=upper('$ws'))) from dual;")" || die "cannot read the parsing schema"; [ -n "$schema" ] || die "no parsing schema for application $id / workspace $ws"
  local live=0; [ "$tgt" != "$id" ] && [ "$(ax_sql "select count(*) from apex_applications where application_id=$tgt;")" = 1 ] && live=1
  say "restore application $id of $DBN/$PDBN from $(g log -1 --format='%h %ci' "$rev") ($path) into workspace $ws, schema $schema, as application $tgt"
  [ "$tgt" = "$id" ] && warn "application $id is REPLACED in $DBN/$PDBN: sessions end, every change since that commit is lost (it is exported and committed first)"
  [ "$live" = 1 ] && { [ "$FORCE" = 1 ] || die "--as-new-id $tgt: application $tgt already exists in $DBN/$PDBN and would be replaced; --force to do that (its current state is exported and committed first)"; warn "application $tgt is REPLACED (--force)"; }
  confirm_typed "Import application $tgt into $DBN/$PDBN from $rev" "$tgt" || die "aborted"
  # 1. current state into the repo
  APPS=("$id"); [ "$live" = 1 ] && APPS+=("$tgt"); do_export || die "export of the current state of f$id failed; refusing the restore (nothing committed or imported)"
  [ "$DRY_RUN" = 1 ] || { g add -A . >/dev/null; if [ -n "$(g status --porcelain)" ]; then g commit -q -m "apex-export: state of f$id before restore from $rev" || die "git commit of the current state failed: refusing the restore (the only copy of the current state is the working tree)"; say "current state committed $(g rev-parse --short HEAD)"; fi; }
  # 2. the files from the revision
  local src="$RUN_DIR/restore_f$id"; mkdir -p "$src"; g archive "$rev" "$(dirname "$path")" | tar -x -C "$src" || die "git archive failed"
  local app_dir; app_dir="$(find "$src" -type d -name "f$id" | head -1)"; local install; if [ -n "$app_dir" ]; then install="$app_dir/install.sql"; else install="$(find "$src" -name "f$id.sql" | head -1)"; app_dir="$(dirname "$install")"; fi
  [ -f "$install" ] || die "no install.sql / f$id.sql in the archive"
  cat >"$RUN_DIR/import.sql" <<SQL
set define off verify off feedback off
whenever sqlerror exit failure rollback
whenever oserror exit failure rollback
begin
  apex_application_install.set_workspace('$ws');
  apex_application_install.set_application_id($tgt);
  apex_application_install.set_schema('$schema');
  $([ -n "$NEW_ID" ] && echo "apex_application_install.generate_offset; apex_application_install.set_application_alias('f$tgt');")
  apex_application_install.set_keep_sessions(false);
end;
/
@$install
SQL
  log "import: $install -> $DBN/$PDBN app $tgt (script $RUN_DIR/import.sql)"; [ "$DRY_RUN" = 1 ] && { say "dry-run: would run $RUN_DIR/import.sql"; return 0; }
  local cmd; if [ -x "${SQLCL:-}" ]; then cmd="$SQLCL -S /nolog"; else cmd="$SQLPLUS -S /nolog"; fi
  (cd "$app_dir" && printf 'connect %s\n@%s\nexit\n' "$CONNECT" "$RUN_DIR/import.sql" | to "${EXPORT_TIMEOUT:-1800}" $cmd 2>&1) | redact >"$RUN_DIR/import.out"; local rc=${PIPESTATUS[0]}
  grep -E 'ORA-|PLS-|SP2-|Error' "$RUN_DIR/import.out" | head -5 >&2; [ "$rc" = 0 ] && ! grep -qE 'ORA-[0-9]+' "$RUN_DIR/import.out" || die "import failed (see $RUN_DIR/import.out)"
  grep -qE 'SP2-0310' "$RUN_DIR/import.out" && die "import failed: a file of the export is missing (SP2-0310, see $RUN_DIR/import.out)"
  local now; now="$(ax_sql "select application_id||' '||application_name||' v'||nvl(version,'-')||' '||pages||' pages, updated '||last_updated_on from apex_applications where application_id=$tgt;")"; [ -n "$now" ] || die "import ended without errors but application $tgt is not in $DBN/$PDBN (see $RUN_DIR/import.out)"
  say "imported: $now"
  state_set restored "$id -> $tgt from $rev"
}

cmd_verify() {
  init_run_dir verify; find_tools; local rc=0
  [ -d "$APEX_REPO/.git" ] || die "$APEX_REPO is not a git repository (run export first)"
  local st; st="$(g status --porcelain | wc -l | tr -d ' ')"; [ "$st" = 0 ] && say "repo: clean, HEAD $(g log -1 --format='%h %ci')" || { warn "repo: $st uncommitted change(s) (apex-export.sh commit)"; rc=1; }
  g remote get-url origin >/dev/null 2>&1 && { local ahead; ahead="$(g rev-list --count '@{u}..HEAD' 2>/dev/null || echo '?')"; [ "$ahead" = 0 ] && say "remote: in sync with $(g remote get-url origin)" || { warn "remote: $ahead commit(s) not pushed"; rc=1; }; } || say "remote: none configured"
  check_conn() {
    local rows missing=0 newer=0 total=0 row; rows="$(app_rows)" || { err "$CONN_NAME: cannot list applications"; rc=1; return 0; }
    while IFS='|' read -r id ws wsid name alias pages upd by ver owner; do [ -n "$id" ] || continue; total=$((total+1))
      local m="$TARGET/$ws/f$id.meta"; if [ ! -f "$m" ]; then missing=$((missing+1)); warn "$DBN/$PDBN: f$id $name ($ws) is not in the repo"; elif [ "$upd" != "$(meta_get "$m" last_updated_on)" ]; then newer=$((newer+1)); warn "$DBN/$PDBN: f$id $name changed $upd by $by, repo has $(meta_get "$m" last_updated_on)"; fi; done <<<"$rows"
    [ "$missing" = 0 ] && [ "$newer" = 0 ] && say "$DBN/$PDBN: $total application(s), all exported and current" || rc=1
    [ -f "$TARGET/instance/applications.txt" ] && { local d; d=$(( ( $(date +%s) - $(stat -c %Y "$TARGET/instance/applications.txt" 2>/dev/null || stat -f %m "$TARGET/instance/applications.txt") ) / 86400 )); [ "$d" -gt "$APEX_STALE_DAYS" ] && { warn "$DBN/$PDBN: last export $d days ago"; rc=1; }; }
  }
  for_each_conn check_conn
  crontab -l 2>/dev/null | grep -q "apex-export.sh run" && say "cron: $(crontab -l | grep 'apex-export.sh run' | head -1)" || { warn "cron: no nightly run (apex-export.sh install-cron)"; rc=1; }
  local last; last="$(ls -dt "$RUN_BASE"/*-export 2>/dev/null | head -1)"; [ -n "$last" ] && say "last run: $last ($(grep -c 'ERROR' "$last/$TOOL.log" 2>/dev/null) errors)"
  return $rc
}
cmd_install_cron() {
  init_run_dir install-cron; local line="$APEX_CRON $SCRIPT_DIR/apex-export.sh run --all >> $APEX_OUT/cron.log 2>&1"
  crontab -l 2>/dev/null | grep -q 'apex-export.sh run' && { say "already installed: $(crontab -l | grep 'apex-export.sh run')"; return 0; }
  say "crontab += $line"; confirm "install?" || die "aborted"; [ "$DRY_RUN" = 1 ] && return 0; mkdir -p "$APEX_OUT"
  { crontab -l 2>/dev/null; echo "$line"; } | crontab - && say "installed"
}
cmd_run() { local rc=0; SINCE="${SINCE:-1}"; ALL=1; cmd_export || { warn "export had failures"; rc=1; }; RUN_DIR=""; cmd_commit || rc=1; RUN_DIR=""; REPORT_OUT=1; cmd_diff || rc=1; return $rc; }   # the nightly must not exit 0 with nothing committed

main() {
  load_config; refuse_root
  local f; for f in "$SCRIPT_DIR/$TOOL.conf" "$HOME/.$TOOL.conf" "$SCRIPT_DIR/../../oracle.conf" "$SCRIPT_DIR/../oracle.conf"; do [ -f "$f" ] && grep -q '^APEX_EXPORT_CONNECT' "$f" && [ "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" != 600 ] && warn "$f holds the connect string and is not mode 600"; done
  local cmd="${1:-}"; shift || true; parse_opts "$@"
  case "$cmd" in
    inspect) cmd_inspect;; export) cmd_export;; commit) cmd_commit;; diff) cmd_diff;; restore) cmd_restore;; verify) cmd_verify;; install-cron) cmd_install_cron;; run) cmd_run;;
    ""|-h|--help|help) usage;; *) die "Unknown command: $cmd";;
  esac
}
cmd_inspect() {
  init_run_dir inspect; find_tools
  report_init "$([ "$REPORT_OUT" = 1 ] && echo "$APEX_OUT/${HOST}_apex_$(date '+%Y%m%d_%H%M%S')" || echo "$RUN_DIR/report")"
  h1 "APEX applications and the export repo ($HOST)"; kv "repo" "$APEX_REPO $([ -d "$APEX_REPO/.git" ] && echo "(HEAD $(g log -1 --format='%h %ci' 2>/dev/null))" || echo '(not created yet)')"; kv "tool" "$TOOL_MODE"; kv_end
  one() {
    h2 "$DBN/$PDBN ($CONN_NAME) APEX $APEXV"
    echo "== $DBN/$PDBN APEX $APEXV ($CONN_NAME, as $AXUSER)"
    h3 "Workspaces"; table_head id workspace schema users apps; printf '%-12s %-24s %-20s %5s %5s\n' ID WORKSPACE SCHEMA USERS APPS
    while IFS='|' read -r wsid ws schema users apps; do [ -n "$wsid" ] || continue; table_row "$wsid" "$ws" "$schema" "$users" "$apps"; printf '%-12s %-24s %-20s %5s %5s\n' "$wsid" "$ws" "$schema" "$users" "$apps"; done < <(ws_rows); printf '\n' >>"$REPORT"
    h3 "Applications"; table_head app workspace name pages "last change" by version repo; printf '\n%-6s %-16s %-32s %5s %-19s %-14s %s\n' APP WORKSPACE NAME PAGES CHANGED BY REPO
    while IFS='|' read -r id ws wsid name alias pages upd by ver owner; do [ -n "$id" ] || continue
      local m="$TARGET/$ws/f$id.meta" state; if [ ! -f "$m" ]; then state="not exported"; finding WARN apex "$DBN/$PDBN f$id $name is not in the repo"; elif [ "$upd" != "$(meta_get "$m" last_updated_on)" ]; then state="newer in db"; finding WARN apex "$DBN/$PDBN f$id $name changed $upd by $by since the last export ($(meta_get "$m" last_updated_on))"; else state="current"; fi
      table_row "$id" "$ws" "$name" "$pages" "$upd" "$by" "$ver" "$state"; printf '%-6s %-16s %-32s %5s %-19s %-14s %s\n' "$id" "$ws" "${name:0:32}" "$pages" "$upd" "${by:0:14}" "$state"
      [ "$upd" \> "$(if [ "$GNU_DATE" = 1 ]; then date -d '-1 day' '+%Y-%m-%d %H:%M:%S'; else date -v-1d '+%Y-%m-%d %H:%M:%S'; fi)" ] && finding INFO apex "$DBN/$PDBN f$id $name changed in the last 24 h ($upd by $by)"
    done < <(app_rows); printf '\n' >>"$REPORT"
    local m; for m in "$TARGET"/*/f[0-9]*.meta; do [ -f "$m" ] || continue; grep -q '^deleted_in_db=' "$m" && finding WARN apex "$DBN/$PDBN $(basename "$m" .meta) $(meta_get "$m" name) no longer exists in the database (deleted $(meta_get "$m" deleted_in_db))"; done
  }
  for_each_conn one
  findings_sync; echo; print_findings 'CRIT|WARN|INFO'
  [ "$REPORT_OUT" = 1 ] && report_finish "apex-export inspect: $HOST" 0 >/dev/null; return 0
}
main "$@"
