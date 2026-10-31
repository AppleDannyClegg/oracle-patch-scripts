#!/usr/bin/env bash
# oracle-lib.sh - shared functions for the scripts in this repository.
#
# Source it from a script that has already set TOOL (its name, e.g. db-health-daily) and VERSION:
#     SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#     TOOL="db-health-daily"; VERSION="1.0.0"
#     . "$SCRIPT_DIR/../../lib/oracle-lib.sh" || exit 1
# Layout: <type>/<script>/<script>.sh with lib/ at the top of the tree (patching/, operations/, reports/). Deploy a script
# folder together with lib/ two levels up, or copy the whole tree - see README.md.
#
# Run `lib/oracle-lib.sh selftest` to check the library on a host.
#
# Sections: logging, execution (timeouts, dry-run, confirmation), run directory and state,
# config files, SQL*Plus access, report writing (REPORT.md + raw/ + FINDINGS), redaction,
# discovery (databases, Grid, WebLogic, ORDS, GoldenGate, Java), HTTP checks, My Oracle Support
# search/download, Oracle CPU quarter maths, secrets.

[ -n "${ORACLE_LIB_LOADED:-}" ] && return 0
ORACLE_LIB_LOADED=1
ORACLE_LIB_VERSION="1.0.0"

set -o pipefail
TOOL="${TOOL:-$(basename "${BASH_SOURCE[1]:-$0}" .sh)}"
VERSION="${VERSION:-0.0.0}"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[1]:-$0}")" && pwd)}"
# shellcheck disable=SC2034
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN="${DRY_RUN:-0}"; ASSUME_YES="${ASSUME_YES:-0}"; FORCE="${FORCE:-0}"; JSON_OUT="${JSON_OUT:-0}"; VERBOSE="${VERBOSE:-0}"; QUIET="${QUIET:-0}"
RUN_BASE="${RUN_BASE:-$HOME/$TOOL/runs}"
RUN_DIR="${RUN_DIR:-}"; LOG_FILE="${LOG_FILE:-}"; STATE_FILE="${STATE_FILE:-}"
CMD_TIMEOUT="${CMD_TIMEOUT:-60}"; SQL_TIMEOUT="${SQL_TIMEOUT:-90}"
HOST="$(hostname -s 2>/dev/null || hostname)"
HAVE_TIMEOUT=0; command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1
SUDO=""; command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null && SUDO="sudo -n"
GNU_DATE=0; date -d yesterday >/dev/null 2>&1 && GNU_DATE=1

# ---------------------------------------------------------------------------
# logging
# ---------------------------------------------------------------------------
ts()   { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '%s [INFO ] %s\n' "$(ts)" "$*" | tee -a "${LOG_FILE:-/dev/null}" >&2; }
warn() { printf '%s [WARN ] %s\n' "$(ts)" "$*" | tee -a "${LOG_FILE:-/dev/null}" >&2; }
err()  { printf '%s [ERROR] %s\n' "$(ts)" "$*" | tee -a "${LOG_FILE:-/dev/null}" >&2; }
dbg()  { [ "$VERBOSE" = 1 ] && printf '%s [DEBUG] %s\n' "$(ts)" "$*" >&2; return 0; }
say()  { [ "$QUIET" = 1 ] || printf '%s  %s\n' "$(ts)" "$*" >&2; [ -n "$LOG_FILE" ] && printf '%s  %s\n' "$(ts)" "$*" >>"$LOG_FILE"; return 0; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# execution
# ---------------------------------------------------------------------------
# to <secs> <cmd...>: run under a timeout when 'timeout' exists, so a hung tool cannot hang the script
to() { local s="$1"; shift; if [ "$HAVE_TIMEOUT" = 1 ]; then timeout -k 5 "$s" "$@"; else "$@"; fi; }
# run_cmd: execute (or print under --dry-run), tee output to the log, return its exit code
run_cmd() {
  log "CMD: $*"; [ "$DRY_RUN" = 1 ] && return 0
  "$@" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; return "${PIPESTATUS[0]}"
}
# run_sh: a shell snippet detached from our stdin/stdout (start/stop scripts that background things)
run_sh() { log "CMD: $*"; [ "$DRY_RUN" = 1 ] && return 0; bash -c "$*" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1; }
confirm() {
  local prompt="$1"
  if [ "$ASSUME_YES" = 1 ] || [ "$DRY_RUN" = 1 ]; then return 0; fi
  [ -t 0 ] || { warn "Non-interactive and --yes not given: refusing '$prompt'"; return 1; }
  local ans; read -r -p "$prompt [y/N] " ans; [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}
# confirm_typed <what> <word>: for destructive steps - the operator must type <word> even with --yes
confirm_typed() {
  [ "$DRY_RUN" = 1 ] && return 0
  [ -t 0 ] || { [ "$FORCE" = 1 ] && return 0; warn "Non-interactive: '$1' needs a typed confirmation (or --force)"; return 1; }
  local ans; read -r -p "$1 - type '$2' to continue: " ans; [ "$ans" = "$2" ]
}
refuse_root() { [ "$(id -u)" = 0 ] && die "Do not run $TOOL as root. Run it as the Oracle software owner."; return 0; }
require_cmd() { local c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "'$c' is required and not on PATH"; done; }
have() { command -v "$1" >/dev/null 2>&1; }

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '; }
# version_ge <a> <b>: 0 if dotted-numeric a >= b
version_ge() {
  local a b i; IFS='.' read -r -a a <<<"$1"; IFS='.' read -r -a b <<<"$2"
  for ((i = 0; i < ${#b[@]}; i++)); do
    local x="${a[i]:-0}" y="${b[i]:-0}"; x="${x//[^0-9]/}"; y="${y//[^0-9]/}"; x="${x:-0}"; y="${y:-0}"
    ((10#$x > 10#$y)) && return 0; ((10#$x < 10#$y)) && return 1
  done; return 0
}
pct_of() { awk -v a="$1" -v b="$2" 'BEGIN{ if (b+0==0) print 0; else printf "%d", a*100/b }'; }
human_mb() { awk -v m="$1" 'BEGIN{ if (m>=1048576) printf "%.1f TB", m/1048576; else if (m>=1024) printf "%.1f GB", m/1024; else printf "%d MB", m }'; }
# epoch_of <date string>: seconds since epoch, GNU or BSD date
epoch_of() {
  if [ "$GNU_DATE" = 1 ]; then date -d "$1" +%s 2>/dev/null
  else date -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s 2>/dev/null || date -j -f '%Y-%m-%d' "$1" +%s 2>/dev/null; fi
}
days_ago() { if [ "$GNU_DATE" = 1 ]; then date -d "-$1 days" '+%Y-%m-%d'; else date -v-"$1"d '+%Y-%m-%d'; fi; }
file_owner() { stat -c %U "$1" 2>/dev/null || stat -f %Su "$1" 2>/dev/null; }
file_mode()  { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }
file_size()  { stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null; }
file_mtime() { if [ "$GNU_DATE" = 1 ]; then date -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null; else stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$1" 2>/dev/null; fi; }

# ---------------------------------------------------------------------------
# run directory + state (so rollback / resume know what happened)
# ---------------------------------------------------------------------------
state_set() {
  [ -z "$STATE_FILE" ] && return 0
  touch "$STATE_FILE"; grep -v "^$1=" "$STATE_FILE" >"$STATE_FILE.tmp" 2>/dev/null || true
  printf '%s=%s\n' "$1" "$2" >>"$STATE_FILE.tmp"; mv "$STATE_FILE.tmp" "$STATE_FILE"
}
state_get() { [ -f "$STATE_FILE" ] || return 1; sed -n "s/^$1=//p" "$STATE_FILE" | tail -1 | grep .; }
state_append() { local cur; cur="$(state_get "$1" || true)"; state_set "$1" "${cur:+$cur }$2"; }
init_run_dir() {
  local name="${1:-run}"
  [ -z "$RUN_DIR" ] && RUN_DIR="$RUN_BASE/$(date '+%Y%m%d-%H%M%S')-$name"
  mkdir -p "$RUN_DIR" || die "Cannot create run dir $RUN_DIR"
  LOG_FILE="$RUN_DIR/$TOOL.log"; STATE_FILE="$RUN_DIR/state"
  ln -sfn "$RUN_DIR" "$RUN_BASE/latest"
  log "$TOOL $VERSION (lib $ORACLE_LIB_VERSION)  run dir: $RUN_DIR  dry-run=$DRY_RUN"
}
latest_run_dir() { [ -L "$RUN_BASE/latest" ] && readlink "$RUN_BASE/latest"; }
# reuse_or_init <name>: continue in the latest run dir (rollback/verify after run) or start one
reuse_or_init() { [ -n "$RUN_DIR" ] && { init_run_dir "$1"; return 0; }; RUN_DIR="$(latest_run_dir)"; [ -n "$RUN_DIR" ] && [ -d "$RUN_DIR" ] && init_run_dir || { RUN_DIR=""; init_run_dir "$1"; }; }

# ---------------------------------------------------------------------------
# config: KEY=VALUE files. Order (later wins): ../../oracle.conf (top of the tree), ../oracle.conf, ~/.oracle.conf, <tool>.conf next to the
# script, ./<tool>.conf, ~/.<tool>.conf, then any extra files given. Command-line options are parsed
# after this in every script, so they win over the files.
# ---------------------------------------------------------------------------
load_config() {
  local f
  for f in "$SCRIPT_DIR/../../oracle.conf" "$SCRIPT_DIR/../oracle.conf" "$HOME/.oracle.conf" "$SCRIPT_DIR/$TOOL.conf" "./$TOOL.conf" "$HOME/.$TOOL.conf" "$@"; do
    [ -f "$f" ] || continue
    dbg "loading config $f"
    if [ "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f" 2>/dev/null)" != "600" ] && grep -qiE '^[A-Z_]*(PASSWORD|SECRET|PASS)[A-Z_]*=' "$f"; then warn "$f holds a password and is not mode 600"; fi
    set -a
    # shellcheck disable=SC1090
    . "$f"
    set +a
  done
}

# ---------------------------------------------------------------------------
# SQL*Plus. Every function takes the SID first; ORACLE_HOME comes from /etc/oratab for that SID,
# connection from SQL_CONNECT (default "/ as sysdba"). PDB_SET="alter session set container=X;"
# when exported makes every statement run in that PDB.
# ---------------------------------------------------------------------------
oratab_home() { grep -E "^$1:" /etc/oratab /var/opt/oracle/oratab 2>/dev/null | head -1 | cut -d: -f2; }
oratab_sids() { grep -hvE '^\s*#|^\s*$' /etc/oratab /var/opt/oracle/oratab 2>/dev/null | cut -d: -f1 | grep -vE '^\+ASM|^-MGMTDB'; }
db_instances() { ps -eo args 2>/dev/null | sed -n 's/^ora_pmon_\([A-Za-z0-9_$]*\).*/\1/p; s/^db_pmon_\([A-Za-z0-9_$]*\).*/\1/p' | sort -u; }
db_home_of() { local h; h="$(oratab_home "$1")"; [ -z "$h" ] && h="${ORACLE_HOME:-}"; [ -z "$h" ] && h="$(ps -eo args 2>/dev/null | grep -oE "^[^ ]*/bin/tnslsnr" | head -1 | sed 's#/bin/tnslsnr##')"; printf '%s' "$h"; }
grid_home() {
  local g; g="$(sed -n 's/^crs_home=//p' /etc/oracle/olr.loc 2>/dev/null)"
  [ -z "$g" ] && g="$(ps -eo args 2>/dev/null | grep -oE '^[^ ]*/bin/(ocssd|crsd|ohasd)' | head -1 | sed 's#/bin/.*##')"
  [ -z "$g" ] && g="$(grep -E '^\+ASM' /etc/oratab 2>/dev/null | head -1 | cut -d: -f2)"
  [ -d "$g" ] && printf '%s' "$g"
}
is_rac() { [ -f /etc/oracle/ocr.loc ]; }
sqlplus_for() { local h; h="$(db_home_of "$1")"; if [ -n "${SQL_CMD:-}" ]; then printf '%s' "$SQL_CMD"; elif [ -x "$h/bin/sqlplus" ]; then printf '%s/bin/sqlplus -S' "$h"; elif have sqlplus; then printf 'sqlplus -S'; elif have sql; then printf 'sql -S'; fi; }
# sql_run <sid> <sql...>: formatted output (headings on). "\n" in the text becomes a newline.
sql_run() {
  local sid="$1"; shift
  local nl q; nl=$'\n'; q="${*//\\n/$nl}"
  local home cmd; home="$(db_home_of "$sid")"; cmd="$(sqlplus_for "$sid")"
  [ -n "$cmd" ] || { echo "no sqlplus for $sid"; return 1; }
  ORACLE_SID="$sid" ORACLE_HOME="$home" LD_LIBRARY_PATH="$home/lib:${LD_LIBRARY_PATH:-}" PATH="$home/bin:$PATH" NLS_LANG="${NLS_LANG:-AMERICAN_AMERICA.AL32UTF8}" \
    to "$SQL_TIMEOUT" bash -c "printf 'set pagesize 500 linesize 250 trimspool on tab off feedback off verify off echo off colsep \"  \"\nset numwidth 14\nalter session set nls_date_format=\"YYYY-MM-DD HH24:MI:SS\";\n%s\n%s\nexit\n' \"\${PDB_SET:-}\" \"\$1\" | $cmd \"\${SQL_CONNECT:-/ as sysdba}\" 2>&1" _ "$q"
}
# sql_lines <sid> <sql>: rows only, no heading, trimmed, blank lines removed; fails on ORA-/SP2- errors
sql_lines() {
  local out; out="$(sql_run "$1" "set heading off\nwhenever sqlerror exit 1\n$2")" || { dbg "SQL failed: $out"; return 1; }
  printf '%s\n' "$out" | grep -vE '^[[:space:]]*$' | grep -qE 'ORA-[0-9]+|SP2-[0-9]+' && { dbg "SQL error: $out"; printf '%s\n' "$out" | grep -E 'ORA-|SP2-' | head -3 >&2; return 1; }
  printf '%s\n' "$out" | sed '/^[[:space:]]*$/d; s/^ *//; s/ *$//'
}
sql_val() { sql_lines "$1" "select $2 from dual;" 2>/dev/null | head -1; }
sql_ok() { [ "$(sql_val "$1" "'ok'" 2>/dev/null)" = ok ]; }
# sql_script <sid> <dir> <script> [args]: @script with output to the log (upgrades, apex, datapatch helpers)
sql_script() {
  local sid="$1" dir="$2" script="$3"; shift 3
  local home cmd; home="$(db_home_of "$sid")"; cmd="$(sqlplus_for "$sid")"
  log "SQL: cd $dir && @$script $*  (output: $LOG_FILE)"; [ "$DRY_RUN" = 1 ] && return 0
  (cd "$dir" && ORACLE_SID="$sid" ORACLE_HOME="$home" PATH="$home/bin:$PATH" printf '%s\nset echo off\n@%s %s\nexit\n' "${PDB_SET:-}" "$script" "$*" | $cmd "${SQL_CONNECT:-/ as sysdba}") >>"$LOG_FILE" 2>&1
}
db_is_cdb() { [ "$(sql_val "$1" "cdb" 2>/dev/null)" = YES ]; }
db_pdbs() { sql_lines "$1" "select name from v\$pdbs where open_mode like 'READ%' and name<>'PDB\$SEED' order by con_id;" 2>/dev/null; }
# with_pdb <pdb> <function> [args]: run a function with PDB_SET exported (empty pdb = root)
with_pdb() { local p="$1"; shift; if [ -n "$p" ] && [ "$p" != CDB\$ROOT ]; then PDB_SET="alter session set container=$p;" "$@"; else PDB_SET="" "$@"; fi; }
# sql_checks <sid> <label> <sql>: rows shaped CHECK|SEV|text become findings
sql_checks() { sql_run "$1" "set heading off\n$3" 2>/dev/null | grep -a '^CHECK|' | while IFS='|' read -r _ sev txt; do finding "$sev" db "$2: $txt"; done; }

# ---------------------------------------------------------------------------
# report: REPORT.md with FINDINGS first, raw/ for full output, optional tar.gz
# ---------------------------------------------------------------------------
REPORT=""; RAW=""; OUT=""; FINDINGS=""; NCRIT=0; NWARN=0; NINFO=0
DIAG_LINES="${DIAG_LINES:-200}"; DIAG_DAYS="${DIAG_DAYS:-3}"
report_init() { # <outdir>
  OUT="$1"; RAW="$OUT/raw"; REPORT="$OUT/body.md"; FINDINGS_FILE="$OUT/findings.txt"
  mkdir -p "$RAW" || die "cannot create $RAW"; : >"$REPORT"; : >"$FINDINGS_FILE"
}
finding() { # <CRIT|WARN|INFO> <area> <text>
  case "$1" in CRIT) NCRIT=$((NCRIT+1));; WARN) NWARN=$((NWARN+1));; *) NINFO=$((NINFO+1));; esac
  FINDINGS="${FINDINGS}- **$1** [$2] $3"$'\n'
  [ -n "${FINDINGS_FILE:-}" ] && printf '%s|%s|%s\n' "$1" "$2" "$3" >>"$FINDINGS_FILE"; return 0
}
# findings written from subshells (while-read loops, $(...)) land in FINDINGS_FILE; sync them back
findings_sync() {
  [ -f "${FINDINGS_FILE:-}" ] || return 0
  FINDINGS=""; NCRIT=0; NWARN=0; NINFO=0
  while IFS='|' read -r sev area txt; do
    case "$sev" in CRIT) NCRIT=$((NCRIT+1));; WARN) NWARN=$((NWARN+1));; *) NINFO=$((NINFO+1));; esac
    FINDINGS="${FINDINGS}- **$sev** [$area] $txt"$'\n'
  done < <(awk '!seen[$0]++' "$FINDINGS_FILE")
}
h1() { printf '\n# %s\n\n' "$*" >>"$REPORT"; }
h2() { printf '\n## %s\n\n' "$*" >>"$REPORT"; }
h3() { printf '\n### %s\n\n' "$*" >>"$REPORT"; }
para() { printf '%s\n\n' "$*" >>"$REPORT"; }
kv() { printf -- '- %s: `%s`\n' "$1" "${2:-n/a}" >>"$REPORT"; }
kv_end() { printf '\n' >>"$REPORT"; }
fence_start() { printf '```%s\n' "${1:-text}" >>"$REPORT"; }
fence_end() { printf '```\n\n' >>"$REPORT"; }
table_row() { local s="|"; local c; for c in "$@"; do s="$s $c |"; done; printf '%s\n' "$s" >>"$REPORT"; }
table_head() { table_row "$@"; local s="|"; local c; for c in "$@"; do s="$s---|"; done; printf '%s\n' "$s" >>"$REPORT"; }
# section <name> <cmd...>: full output to raw/<name>.txt, first DIAG_LINES lines into the report
section() {
  local name="$1"; shift; local f="$RAW/$name.txt" rc n
  { printf '$ %s\n' "$*"; to "$CMD_TIMEOUT" "$@" 2>&1; rc=$?; printf '\n[exit %s]\n' "$rc"; } | redact >"$f"
  n="$(wc -l <"$f" | tr -d ' ')"
  fence_start
  if [ "$n" -gt "$DIAG_LINES" ]; then head -n "$DIAG_LINES" "$f" >>"$REPORT"; printf '... (%s lines total, full output in raw/%s.txt)\n' "$n" "$name" >>"$REPORT"
  else cat "$f" >>"$REPORT"; fi
  fence_end
}
section_sh() { local name="$1"; shift; section "$name" bash -c "$*"; }
# sqlsec <sid> <name> <title> <sql>: titled fenced block from SQL; full output in raw/
sqlsec() {
  local sid="$1" name="$2" title="$3" q="$4" f; f="$RAW/db_${sid}_${name}.txt"
  { printf -- '-- %s\n%s\n\n' "$title" "$q"; sql_run "$sid" "$q"; } >"$f" 2>&1
  h3 "$title"; local n; n="$(wc -l <"$f" | tr -d ' ')"
  fence_start
  if [ "$n" -gt "$DIAG_LINES" ]; then head -n "$DIAG_LINES" "$f" >>"$REPORT"; printf '... (%s lines, full in raw/db_%s_%s.txt)\n' "$n" "$sid" "$name" >>"$REPORT"; else cat "$f" >>"$REPORT"; fi
  fence_end
}
tail_file() { # <name> <file>
  local name="$1" f="$2"; [ -r "$f" ] || { para "_$f: not readable_"; return 0; }
  tail -n 5000 "$f" 2>/dev/null | redact >"$RAW/$name.log"
  printf '%s (%s, %s lines, modified %s)\n\n' "$f" "$(du -h "$f" 2>/dev/null | cut -f1)" "$(wc -l <"$f" | tr -d ' ')" "$(file_mtime "$f")" >>"$REPORT"
  fence_start; tail -n "$DIAG_LINES" "$RAW/$name.log" >>"$REPORT"; fence_end
}
# recent_errors <name> <file> <regex>: matching lines from the last 200k lines, counted by message; prints the count
recent_errors() {
  local name="$1" f="$2" re="$3"; [ -r "$f" ] || { echo 0; return 0; }
  tail -n 200000 "$f" 2>/dev/null | grep -aE "$re" | redact >"$RAW/$name.errors"
  local n; n="$(wc -l <"$RAW/$name.errors" | tr -d ' ')"
  printf 'Error lines in the last 200000 lines of %s: **%s**\n\n' "$f" "$n" >>"$REPORT"
  if [ "$n" != 0 ]; then
    para "Most frequent messages (count, message):"; fence_start
    sed -E 's/^[0-9T:. -]+//; s/[0-9]{4,}/N/g' "$RAW/$name.errors" | cut -c1-160 | sort | uniq -c | sort -rn | head -25 >>"$REPORT"; fence_end
    para "Last ${DIAG_LINES} error lines:"; fence_start; tail -n "$DIAG_LINES" "$RAW/$name.errors" >>"$REPORT"; fence_end
  fi
  echo "$n"
}
errors_match() { grep -qE "$2" "$RAW/$1.errors" 2>/dev/null; }
# report_finish <title> [tar]: REPORT.md = header + FINDINGS + body; prints its path
report_finish() {
  local title="$1" dotar="${2:-1}" final="$OUT/REPORT.md"
  findings_sync
  {
    printf '# %s\n\n' "$title"
    printf -- '- generated: `%s` by %s %s (lib %s) as `%s` on `%s`\n' "$(ts)" "$TOOL" "$VERSION" "$ORACLE_LIB_VERSION" "$(id -un)" "$HOST"
    printf -- '- log excerpts capped at %s lines; untruncated output in raw/\n\n' "$DIAG_LINES"
    printf '> **For the analyst (human or Claude):** read-only snapshot. Start with FINDINGS (the script'"'"'s own rules, not exhaustive), then the evidence. For each real problem give: what is wrong, the evidence (section / raw file), likely cause, the fix as exact commands, what to check afterwards. Say which findings are noise, and what the rules missed.\n\n'
    printf '# FINDINGS  (%s critical, %s warnings, %s info)\n\n' "$NCRIT" "$NWARN" "$NINFO"
    if [ -n "$FINDINGS" ]; then printf '%s' "$FINDINGS" | grep '^- \*\*CRIT'; printf '%s' "$FINDINGS" | grep '^- \*\*WARN'; printf '%s' "$FINDINGS" | grep '^- \*\*INFO'; else echo "- nothing tripped the built-in rules"; fi
    printf '\n---\n'; cat "$REPORT"
  } >"$final"
  rm -f "$REPORT"
  if [ "$dotar" = 1 ]; then (cd "$(dirname "$OUT")" && tar -czf "$(basename "$OUT").tar.gz" "$(basename "$OUT")") && say "tarball: $OUT.tar.gz ($(du -h "$OUT.tar.gz" | cut -f1))"; fi
  say "report: $final  ($NCRIT critical, $NWARN warnings, $NINFO info)"
  printf '%s\n' "$final"
}
print_findings() { printf '%s' "$FINDINGS" | grep -E "^- \*\*(${1:-CRIT|WARN})" | sed 's/\*\*//g'; return 0; }
# exit code for cron: 2 if CRIT, 1 if WARN, 0 clean
findings_rc() { [ "$NCRIT" -gt 0 ] && return 2; [ "$NWARN" -gt 0 ] && return 1; return 0; }

# redact passwords in xml / properties / shell / ini / jdbc-url text
REDACT="${REDACT:-1}"
redact() {
  if [ "$REDACT" = 1 ]; then
    sed -E \
      -e 's/(<entry key="[^"]*(password|passwd|secret|credential)[^"]*">)[^<]*(<\/entry>)/\1***REDACTED***\3/Ig' \
      -e 's/(<(password|passwd|secret|credential-store-password|db\.password|node-manager-password|password-encrypted)[^>]*>)[^<]*(<\/)/\1***REDACTED***\3/Ig' \
      -e 's/((password|passwd|secret|pwd)[A-Za-z0-9_.-]*[[:space:]]*[=:][[:space:]]*)[^[:space:]"]+/\1***REDACTED***/Ig' \
      -e 's/(password=")[^"]*(")/\1***REDACTED***\2/Ig' \
      -e 's#(//[^/:@[:space:]]+:)[^@[:space:]]+(@)#\1***REDACTED***\2#g' \
      -e 's#(^|[[:space:]:="(\x27])([A-Za-z0-9_$#.-]+)/[^@/[:space:]"]+@#\1\2/***REDACTED***@#g'
  else cat; fi
}

# ---------------------------------------------------------------------------
# discovery: WebLogic, ORDS, GoldenGate, Java, listener
# ---------------------------------------------------------------------------
# wls_homes: every FMW home found (inventory + common paths + running JVMs), one per line
wls_homes() {
  { local inv d
    for inv in /etc/oraInst.loc /var/opt/oracle/oraInst.loc; do
      [ -f "$inv" ] || continue; d="$(sed -n 's/^inventory_loc=//p' "$inv")"
      sed -n 's/.*<HOME NAME="[^"]*" LOC="\([^"]*\)".*/\1/p' "$d/ContentsXML/inventory.xml" 2>/dev/null
    done
    ls -d /u01/app/oracle/product/*/fmw* /u01/app/oracle/middleware* /u01/oracle/* /opt/oracle/* /opt/oracle/product/* "$HOME"/Oracle/Middleware* 2>/dev/null
    [ -n "${ORACLE_HOME:-}" ] && echo "$ORACLE_HOME"; [ -n "${MW_HOME:-}" ] && echo "$MW_HOME"
    ps -eo args 2>/dev/null | grep -oE '[^ ]*/wlserve[r]/' | sed 's#/wlserver/##'
  } 2>/dev/null | while read -r h; do [ -d "$h/wlserver" ] && echo "$h"; done | sort -u
}
wls_version() { local v; v="$(sed -n 's/.*name="WebLogic Server"[^>]*version="\([0-9.]*\)".*/\1/p' "$1/inventory/registry.xml" 2>/dev/null | head -1)"; [ -z "$v" ] && v="$(sed -n 's/^WLS_PRODUCT_VERSION=//p' "$1/wlserver/.product.properties" 2>/dev/null)"; printf '%s' "$v"; }
wls_java_home() { local j; j="$(sed -n 's/^JAVA_HOME=//p' "$1/oui/.globalEnv.properties" 2>/dev/null | head -1)"; [ -x "$j/bin/java" ] || j="$(grep -E '^\s*JAVA_HOME=' "$1/oracle_common/common/bin/commEnv.sh" 2>/dev/null | head -1 | sed 's/.*JAVA_HOME=//; s/"//g')"; [ -x "$j/bin/java" ] && printf '%s' "$j"; }
# wls_domains <home>: domain dirs with a config.xml
wls_domains() {
  { sed -n 's/.*<domain location="\([^"]*\)".*/\1/p' "$1/domain-registry.xml" 2>/dev/null; ls -d "$1"/user_projects/domains/* 2>/dev/null; [ -n "${DOMAIN_HOME:-}" ] && echo "$DOMAIN_HOME"
    ps -eo args 2>/dev/null | grep -oE -- '-Ddomain.hom[e]=[^ ]+' | cut -d= -f2; } | while read -r d; do [ -f "$d/config/config.xml" ] && echo "$d"; done | sort -u
}
# wls_servers <domain>: "name port machine cluster" per configured server
wls_servers() {
  awk '/<server>/{inblk=1;inssl=0;name="";port="";machine="";cluster=""} inblk&&/<ssl>/{inssl=1} inblk&&/<\/ssl>/{inssl=0}
       inblk&&name==""&&match($0,/<name>[^<]*<\/name>/){name=substr($0,RSTART+6,RLENGTH-13)}
       inblk&&!inssl&&port==""&&match($0,/<listen-port>[^<]*<\/listen-port>/){port=substr($0,RSTART+13,RLENGTH-27)}
       inblk&&match($0,/<machine>[^<]*<\/machine>/){machine=substr($0,RSTART+9,RLENGTH-19)}
       inblk&&match($0,/<cluster>[^<]*<\/cluster>/){cluster=substr($0,RSTART+9,RLENGTH-19)}
       inblk&&/<\/server>/{inblk=0; print name, (port==""?"7001":port), (machine==""?"-":machine), (cluster==""?"-":cluster)}' "$1/config/config.xml" 2>/dev/null
}
wls_admin_name() { sed -n 's/.*<admin-server-name>\([^<]*\)<.*/\1/p' "$1/config/config.xml" 2>/dev/null | head -1 | grep . || echo AdminServer; }
# wls_running [domain]: "name pid" for running server JVMs (only real JVMs, not shells mentioning the words)
wls_running() { ps -eo pid,args 2>/dev/null | awk -v d="${1:-}" '$2 ~ /java$/ && /weblogic\.Server/ && (d=="" || index($0,d)) { n=""; for(i=3;i<=NF;i++) if ($i ~ /^-Dweblogic\.Name=/) n=substr($i,17); if (n!="") print n, $1 }'; }
nodemanager_pid() { ps -eo pid,args 2>/dev/null | awk '$2 ~ /java$/ && /weblogic\.NodeManager/ {print $1; exit}'; }
# wls_datasources <domain>: "file jndi user url" per JDBC module (url with password redacted)
wls_datasources() { local f; for f in "$1"/config/jdbc/*.xml; do [ -f "$f" ] || continue; printf '%s %s %s %s\n' "$(basename "$f")" "$(grep -oE '<jndi-name>[^<]*' "$f" | head -1 | sed 's/<[^>]*>//')" "$(grep -oE '<name>user</name>[[:space:]]*<value>[^<]*' "$f" | sed 's/.*<value>//' | head -1)" "$(grep -oE '<url>[^<]*' "$f" | sed 's/<[^>]*>//' | redact)"; done; }

# ords_detect: sets ORDS_HOME ORDS_CONFIG ORDS_PID ORDS_VER ORDS_URL ORDS_POOLS (0 = found something)
# shellcheck disable=SC2034
ords_detect() {
  ORDS_PID="$(pgrep -f 'ords.war|ords serve|ords --config|ords\.standalone|oracle.dbtools' 2>/dev/null | head -1)"
  if [ -z "${ORDS_HOME:-}" ]; then local c; c="$(command -v ords 2>/dev/null)"; [ -n "$c" ] && ORDS_HOME="$(cd "$(dirname "$c")/.." && pwd)"; fi
  [ -z "${ORDS_HOME:-}" ] && for d in /opt/oracle/ords /opt/ords /u01/ords /u01/app/oracle/ords "$HOME/ords"; do [ -x "$d/bin/ords" ] && { ORDS_HOME="$d"; break; }; done
  [ -z "${ORDS_CONFIG:-}" ] && [ -n "$ORDS_PID" ] && ORDS_CONFIG="$(tr '\0' ' ' <"/proc/$ORDS_PID/cmdline" 2>/dev/null | sed -n 's/.*--config \([^ ]*\).*/\1/p; s/.*-Dconfig.url=\([^ ]*\).*/\1/p' | head -1)"
  [ -z "${ORDS_CONFIG:-}" ] && for d in /etc/ords/config /opt/oracle/ords/config "${ORDS_HOME:-/nonexistent}/config" "$(dirname "$(readlink -f "${ORDS_HOME:-/nonexistent}" 2>/dev/null || echo /nonexistent)")/config"; do [ -f "$d/global/settings.xml" ] && { ORDS_CONFIG="$d"; break; }; done
  ORDS_VER=""; [ -x "${ORDS_HOME:-}/bin/ords" ] && ORDS_VER="$(to 60 "$ORDS_HOME/bin/ords" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [ -z "${ORDS_URL:-}" ]; then local port; port="$(sed -n 's/^standalone.http.port=//p' "${ORDS_CONFIG:-/nonexistent}/global/standalone/standalone.properties" 2>/dev/null | head -1)"; local sport; sport="$(sed -n 's/^standalone.https.port=//p' "${ORDS_CONFIG:-/nonexistent}/global/standalone/standalone.properties" 2>/dev/null | head -1)"; if [ -n "$sport" ]; then ORDS_URL="https://localhost:$sport/ords/"; else ORDS_URL="http://localhost:${port:-8080}/ords/"; fi; fi
  ORDS_POOLS="$(ls "${ORDS_CONFIG:-/nonexistent}/databases" 2>/dev/null | tr '\n' ' ')"
  [ -n "${ORDS_HOME:-}" ] || [ -n "$ORDS_PID" ]
}
ords_pool_user() { sed -n 's/.*<entry key="db.username">\([^<]*\)<.*/\1/p' "$ORDS_CONFIG/databases/$1/pool.xml" 2>/dev/null | head -1; }
ords_images_dir() { local i; i="$(sed -n 's/^standalone.static.path=//p' "${ORDS_CONFIG:-/nonexistent}/global/standalone/standalone.properties" 2>/dev/null | head -1)"; [ -z "$i" ] && i="${APEX_IMAGES_DIR:-}"; printf '%s' "$i"; }
ords_service() { systemctl list-units --type=service --all --no-legend 2>/dev/null | awk '{print $1}' | grep -i ords | head -1; }

# ogg_detect: sets OGG_HOME (classic) and OGG_MA=1 when Microservices processes exist
ogg_detect() {
  OGG_HOME="${OGG_HOME:-}"; OGG_MA=0
  [ -z "$OGG_HOME" ] && OGG_HOME="$(ps -eo args 2>/dev/null | grep -oE '^[^ ]*/(mgr|ggsci|extract|replicat)( |$)' | sed -E 's#/(mgr|ggsci|extract|replicat) *$##' | head -1)"
  [ -z "$OGG_HOME" ] && for d in /u01/app/oracle/product/*/ogg* /u01/app/ogg* /u01/ogg* /opt/oracle/ogg* /u01/app/oracle/goldengate*; do [ -x "$d/ggsci" ] && { OGG_HOME="$d"; break; }; done
  ps -eo args 2>/dev/null | grep -qE '[S]erviceManager|/bin/(adminsrv[r]|distsrv[r]|recvsrv[r]|pmsrv[r])' && OGG_MA=1
  [ -x "${OGG_HOME:-/nonexistent}/ggsci" ] || [ "$OGG_MA" = 1 ]
}
# ggsci <commands...>: run in OGG_HOME with the DB home's libs; "\n"-separated commands
ggsci() {
  local nl q h; nl=$'\n'; q="${*//\\n/$nl}"; h="${ORACLE_HOME:-$(db_home_of "$(db_instances | head -1)")}"
  (cd "$OGG_HOME" && export ORACLE_HOME="$h" LD_LIBRARY_PATH="$OGG_HOME:$h/lib:${LD_LIBRARY_PATH:-}" && printf '%s\n' "$q" | to "${CMD_TIMEOUT}" ./ggsci 2>&1 | grep -vE '^GGSCI|^$')
}

java_version_of() { "$1/bin/java" -version 2>&1 | head -1 | sed -n 's/.*version "\([^"]*\)".*/\1/p'; }
java_major_of() { local v; v="$(java_version_of "$1")"; local j="${v%%.*}"; [ "$j" = 1 ] && { j="${v#1.}"; j="${j%%.*}"; }; printf '%s' "$j"; }
java_homes() { # every JDK referenced by something on the host, one per line
  { local h; for h in $(wls_homes); do wls_java_home "$h"; echo; done
    ps -eo pid,args 2>/dev/null | awk '$2 ~ /\/bin\/java$/ {print $2}' | sed 's#/bin/java$##' | while read -r j; do readlink -f "$j" 2>/dev/null || echo "$j"; done
    [ -n "${JAVA_HOME:-}" ] && echo "$JAVA_HOME"
    ls -d /usr/java/jdk* /usr/java/latest /usr/lib/jvm/* /opt/java/* /u01/app/oracle/jdk* /u01/jdk* 2>/dev/null
    local c; c="$(command -v java 2>/dev/null)"; [ -n "$c" ] && dirname "$(dirname "$(readlink -f "$c")")"
  } 2>/dev/null | while read -r j; do [ -x "$j/bin/java" ] && (readlink -f "$j" 2>/dev/null || echo "$j"); done | sort -u
}

listener_homes() { ps -eo args 2>/dev/null | grep -E '^[^ ]*/bin/tnslsn[r] ' | awk '{print $1, $2}' | sed 's#/bin/tnslsnr##' | sort -u; } # "home name"

# ---------------------------------------------------------------------------
# HTTP / ports
# ---------------------------------------------------------------------------
url_code() { curl -sk -o /dev/null -m "${2:-15}" -w '%{http_code}' "$1" 2>/dev/null; }
port_open() { (exec 3<>"/dev/tcp/${2:-127.0.0.1}/$1") 2>/dev/null; }
wait_for_url() { # <url> <timeout secs> [expected code regex]
  local url="$1" t="${2:-300}" want="${3:-200|30[0-9]}" start now; start="$(date +%s)"
  while :; do [[ "$(url_code "$url" 5)" =~ ^($want)$ ]] && return 0; now="$(date +%s)"; [ $((now-start)) -ge "$t" ] && return 1; sleep 5; done
}
tls_enddate() { echo | to 10 openssl s_client -connect "$1" -servername "${1%%:*}" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//'; }
days_until() { local es; es="$(epoch_of "$1")"; [ -z "$es" ] && es="$( [ "$GNU_DATE" = 1 ] && date -d "$1" +%s 2>/dev/null || date -j -f '%b %d %T %Y %Z' "$1" +%s 2>/dev/null)"; [ -z "$es" ] && return 1; echo $(( (es - $(date +%s)) / 86400 )); }

# ---------------------------------------------------------------------------
# My Oracle Support: login (~/.netrc or MOS_USER/MOS_PASSWORD), name search, file pick, download
# ---------------------------------------------------------------------------
MOS_BASE="${MOS_BASE:-https://updates.oracle.com}"; MOS_NETRC=""; MOS_COOKIES=""; MOS_CURL=()
mos_cleanup() { [ -n "$MOS_NETRC" ] && rm -f "$MOS_NETRC"; [ -n "$MOS_COOKIES" ] && rm -f "$MOS_COOKIES"; return 0; }
mos_login() {
  require_cmd curl
  [ -n "$RUN_DIR" ] || init_run_dir mos
  MOS_COOKIES="$RUN_DIR/.mos-cookies"; trap mos_cleanup EXIT
  local host netrc_opt=(); host="$(printf '%s' "$MOS_BASE" | sed -E 's#^[a-z]+://##; s#[:/].*##')"
  if [ -f "$HOME/.netrc" ] && grep -q "$host" "$HOME/.netrc"; then netrc_opt=(--netrc); log "MOS login: using ~/.netrc"
  else
    local user="${MOS_USER:-}" pass="${MOS_PASSWORD:-}"
    [ -z "$user" ] && { [ -t 0 ] || die "No MOS credentials: set MOS_USER/MOS_PASSWORD in the conf or add $host to ~/.netrc"; read -r -p "My Oracle Support email: " user; }
    [ -z "$pass" ] && { [ -t 0 ] || die "No MOS_PASSWORD and not interactive"; read -r -s -p "My Oracle Support password: " pass; echo; }
    MOS_NETRC="$RUN_DIR/.mos-netrc"; ( umask 077; printf 'machine %s login %s password %s\n' "$host" "$user" "$pass" >"$MOS_NETRC" )
    netrc_opt=(--netrc-file "$MOS_NETRC"); log "MOS login: as $user"
  fi
  MOS_CURL=(curl -sS -L --fail-with-body --retry 3 --retry-delay 5 "${netrc_opt[@]}" -b "$MOS_COOKIES" -c "$MOS_COOKIES")
  local code; code="$("${MOS_CURL[@]}" -o /dev/null -w '%{http_code}' "$MOS_BASE/Orion/Services/download" || true)"
  case "$code" in 200|302) log "MOS login OK";; 401|403) die "MOS login rejected (HTTP $code)";; *) die "Cannot reach $MOS_BASE (HTTP ${code:-none}). Set HTTPS_PROXY if needed.";; esac
}
# mos_name_search <text>: "number|description" rows from the legacy simple search
mos_name_search() {
  local q html; q="$(printf '%s' "$1" | sed 's/ /%20/g')"
  html="$("${MOS_CURL[@]}" "$MOS_BASE/Orion/SimpleSearch/process_form?search_type=patch&patch_number=$q&plat_lang=2000P" | tr -d '\n\r')" || return 1
  printf '%s' "$html" | sed 's/<tr/\n<tr/g' | sed 's/<[^>]*>/ /g; s/&nbsp;/ /g; s/  */ /g' \
    | grep -oE '\b[0-9]{8}\b.*' | awk '{n=$1; $1=""; sub(/^ /,""); print n "|" $0}' \
    | sed -E 's/ (Generic Platform|Linux x86|Linux x86-64|Microsoft Windows|Oracle Solaris|IBM AIX|Download)( .*)?$//'
}
# mos_pick_file <bug> [release]: "filename|url|sha256|release|platform" for this platform/release
mos_pick_file() {
  local bug="$1" want="${2:-}" xml cands="" p f
  xml="$("${MOS_CURL[@]}" "$MOS_BASE/Orion/Services/search?bug=$bug" | tr -d '\n\r')" || return 1
  printf '%s' "$xml" | grep -qi '<html' && { err "MOS returned a web page for $bug - login did not stick"; return 1; }
  while read -r p; do
    [ -z "$p" ] && continue
    local rel plat; rel="$(printf '%s' "$p" | sed -n 's/.*<release[^>]*name="\([^"]*\)".*/\1/p')"; plat="$(printf '%s' "$p" | sed -n 's/.*<platform[^>]*>\([^<]*\)<\/platform>.*/\1/p')"
    while read -r f; do
      [ -z "$f" ] && continue
      local name url sha; name="$(printf '%s' "$f" | sed -n 's/.*<name>\([^<]*\)<\/name>.*/\1/p')"
      url="$(printf '%s' "$f" | sed -n 's/.*<download_url[^>]*host="\([^"]*\)"[^>]*>\([^<]*\)<\/download_url>.*/\1\2/p' | sed 's/&amp;/\&/g')"
      sha="$(printf '%s' "$f" | sed -n 's/.*<digest type="SHA-256">\([^<]*\)<\/digest>.*/\1/p')"
      [ -n "$name" ] && [ -n "$url" ] && cands="${cands:+$cands$'\n'}$name|$url|$sha|$rel|$plat"
    done < <(printf '%s' "$p" | sed 's/<file>/\n<file>/g' | grep '<file>')
  done < <(printf '%s' "$xml" | sed 's/<patch>/\n<patch>/g' | grep '<patch>')
  [ -n "$cands" ] || { err "Patch $bug: no downloadable files (not entitled, or wrong number)"; return 1; }
  local os="Linux x86-64"; case "$(uname -s)" in SunOS) os="Solaris";; AIX) os="IBM AIX";; esac
  local byplat; byplat="$(printf '%s\n' "$cands" | grep -iE '\|(Generic Platform|'"$os"')$' || printf '%s\n' "$cands")"
  local pick=""; [ -n "$want" ] && pick="$(printf '%s\n' "$byplat" | awk -F'|' -v r="$want" -v t="_$(printf '%s' "$want" | tr -d .)" 'index($4,r)==1 || index($1,t) {print; exit}')"
  [ -z "$pick" ] && [ "$(printf '%s\n' "$byplat" | wc -l)" -eq 1 ] && pick="$byplat"
  [ -z "$pick" ] && { err "Patch $bug has several files; pass --release <one of>:"; printf '%s\n' "$byplat" | awk -F'|' '{printf "    %-45s release %-14s %s\n", $1, $4, $5}' >&2; return 1; }
  printf '%s\n' "$pick"
}
# mos_download <bug> <dir> [release]: fetch + verify SHA-256; prints the zip path
mos_download() {
  local bug="$1" dir="$2" rel="${3:-}" pick name url sha
  pick="$(mos_pick_file "$bug" "$rel")" || return 1
  IFS='|' read -r name url sha _ <<<"$pick"
  mkdir -p "$dir"
  if [ -f "$dir/$name" ] && [ -n "$sha" ] && [ "$(sha256sum "$dir/$name" 2>/dev/null | cut -d' ' -f1)" = "${sha,,}" ]; then log "$name already present and verified"; printf '%s\n' "$dir/$name"; return 0; fi
  log "downloading $name"; [ "$DRY_RUN" = 1 ] && return 0
  "${MOS_CURL[@]}" -o "$dir/$name.part" "$url" || { err "download of $name failed"; return 1; }
  if [ -n "$sha" ] && [ "$(sha256sum "$dir/$name.part" | cut -d' ' -f1)" != "${sha,,}" ]; then err "SHA-256 mismatch for $name"; rm -f "$dir/$name.part"; return 1; fi
  mv "$dir/$name.part" "$dir/$name"; printf '%s\n' "$dir/$name"
}

# ---------------------------------------------------------------------------
# Oracle Critical Patch Update calendar: third Tuesday of Jan/Apr/Jul/Oct
# ---------------------------------------------------------------------------
# cpu_date <year> <month 1|4|7|10>: YYYY-MM-DD of that quarter's CPU
cpu_date() {
  local y="$1" m="$2" d dow; m="$(printf '%02d' "$m")"
  for d in 15 16 17 18 19 20 21; do
    if [ "$GNU_DATE" = 1 ]; then dow="$(date -d "$y-$m-$d" +%u)"; else dow="$(date -j -f '%Y-%m-%d' "$y-$m-$d" +%u)"; fi
    [ "$dow" = 2 ] && { echo "$y-$m-$d"; return; }
  done
}
# latest_cpu_date: the most recent CPU date on or before today
latest_cpu_date() {
  local today y m; today="$(date +%Y-%m-%d)"; y="$(date +%Y)"
  for m in 10 7 4 1; do local c; c="$(cpu_date "$y" "$m")"; [[ "$c" < "$today" || "$c" == "$today" ]] && { echo "$c"; return; }; done
  cpu_date "$((y-1))" 10
}
# quarters_behind <YYYY-MM-DD of installed patch>: how many CPU releases newer than it exist
quarters_behind() {
  local at="$1" n=0 y m c; [ -z "$at" ] && { echo "?"; return; }
  y="$(date +%Y)"
  for ((yy=y; yy>=y-6; yy--)); do for m in 10 7 4 1; do c="$(cpu_date "$yy" "$m")"; [[ "$c" > "$(date +%Y-%m-%d)" ]] && continue; [[ "$c" > "$at" ]] && n=$((n+1)) || { echo "$n"; return; }; done; done
  echo "$n"
}
# yymmdd_to_date 240716 -> 2024-07-16
yymmdd_to_date() { [ -n "$1" ] && printf '20%s-%s-%s' "${1:0:2}" "${1:2:2}" "${1:4:2}"; }

# ---------------------------------------------------------------------------
# secrets: never on a command line. read_secret VAR "prompt" fills VAR from env/config or a prompt.
# ---------------------------------------------------------------------------
read_secret() {
  local var="$1" prompt="$2"
  [ -n "${!var:-}" ] && return 0
  [ -t 0 ] || die "$var is not set and the session is not interactive"
  local v; read -r -s -p "$prompt: " v; echo; printf -v "$var" '%s' "$v"; export "${var?}"
}
# tmp_secret_file: a 600-mode file in the run dir whose path can be given to tools that read a file
tmp_secret_file() { local f="$RUN_DIR/.secret.$RANDOM"; ( umask 077; printf '%s' "$1" >"$f" ); printf '%s' "$f"; }

# ---------------------------------------------------------------------------
# usage from the script's comment header, and self test
# ---------------------------------------------------------------------------
usage_from_header() { sed -n '2,/^$/p' "${1:-$0}" | sed 's/^# \{0,1\}//'; }

lib_selftest() {
  local ok=0 fail=0
  t() { if eval "$2"; then ok=$((ok+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
  t "version_ge 12.2.1.4 >= 12.2.1.3" 'version_ge 12.2.1.4 12.2.1.3'
  t "version_ge 19.3 < 19.24" '! version_ge 19.3 19.24'
  t "pct_of 50 200 = 25" '[ "$(pct_of 50 200)" = 25 ]'
  t "cpu_date 2026 1 = 2026-01-20" '[ "$(cpu_date 2026 1)" = 2026-01-20 ]'
  t "cpu_date 2025 10 = 2025-10-21" '[ "$(cpu_date 2025 10)" = 2025-10-21 ]'
  t "yymmdd_to_date" '[ "$(yymmdd_to_date 240716)" = 2024-07-16 ]'
  t "redact xml password" '[ "$(echo "<entry key=\"db.password\">secret</entry>" | redact)" = "<entry key=\"db.password\">***REDACTED***</entry>" ]'
  t "redact jdbc url" '[ "$(echo "jdbc:oracle:thin:apex/Welcome1@//db:1521/svc" | redact)" = "jdbc:oracle:thin:apex/***REDACTED***@//db:1521/svc" ]'
  t "json_escape" '[ "$(json_escape "a\"b")" = "a\\\"b" ]'
  t "report roundtrip" 'd=$(mktemp -d); report_init "$d/r"; h1 T; finding WARN x "hello"; (finding CRIT y "from subshell"); f=$(report_finish "t" 0); grep -q "from subshell" "$f" && grep -q "1 critical, 1 warnings" "$f"; rc=$?; rm -rf "$d"; [ $rc = 0 ]'
  t "quarters_behind recent = 0" '[ "$(quarters_behind "$(latest_cpu_date)")" = 0 ]'
  echo "oracle-lib $ORACLE_LIB_VERSION selftest: $ok passed, $fail failed (timeout=$HAVE_TIMEOUT gnu-date=$GNU_DATE sudo=${SUDO:-no})"
  [ "$fail" = 0 ]
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then case "${1:-}" in selftest) lib_selftest;; *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//';; esac; fi
