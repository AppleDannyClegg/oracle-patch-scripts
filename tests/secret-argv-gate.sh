#!/usr/bin/env bash
# shellcheck disable=SC2034  # SQL_CMD, SQL_CONNECT, CONNECT, SQLCL, SQLPLUS, TOOL_MODE, DB_HOME, EXP_CONNECT are read by the harnessed functions
# Behavioural gate for secrets: no connect string, password or SQL ever appears on a child process's command line
# (ps, /proc/<pid>/cmdline) or in its environment. Every function in the repo that hands a credential to sqlplus,
# SQLcl, expdp/impdp or ggsci is run against a stub of that tool, with canary values in the credential and the SQL.
# The stub records its argv, its environment and everything it read on stdin (or, for Data Pump, the parfile).
# Pass: the canary is ABSENT from argv and environ, PRESENT on the route the function claims (stdin / 600-mode
# parfile outside the run dir) - a call site that silently drops the secret must not pass either. Needs no
# database. Usage: tests/secret-argv-gate.sh
cd "$(dirname "$0")/.." || exit 1
exec </dev/null   # a tool that is not fed stdin (expdp, impdp) must see EOF, not an inherited terminal or pipe
ROOT="$PWD"; T="$(mktemp -d)"; CAP="$T/cap"; STUB="$T/stub"; mkdir -p "$CAP" "$STUB/bin"
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
# every stub: argv, environment and stdin to $CAP/<tool>.<pid>; Data Pump stubs add the parfile's content and mode
for tool in sqlplus sql expdp impdp ggsci; do
  cat >"$STUB/bin/$tool" <<'STUB'
#!/bin/sh
me="$(basename "$0")"; f="${CAP}/$me.$$"
{ echo "ARGV: $*"; echo "ENV-BEGIN"; env; echo "ENV-END"; echo "STDIN-BEGIN"; cat; echo "STDIN-END"; } >"$f"
for a in "$@"; do case "$a" in parfile=*) p="${a#parfile=}"; { echo "PARFILE: $p"; echo "PARFILE-MODE: $(stat -c %a "$p" 2>/dev/null || stat -f %Lp "$p")"; echo "PARFILE-BEGIN"; cat "$p"; echo "PARFILE-END"; } >>"$f";; esac; done
STUB
  chmod +x "$STUB/bin/$tool"
done
cp "$STUB/bin/ggsci" "$STUB/ggsci"   # lib ggsci() runs ./ggsci inside OGG_HOME
export CAP
# fn <name> <file>: the body of one top-level function, so a script that ends in main "$@" can be harnessed
fn() { awk -v f="$1" '$0 ~ "^"f"\\(\\) *\\{" {p=1; if ($0 ~ /\} *$/ && $0 !~ /\{ *$/) {print; exit}} p{print} p && /^}/ {exit}' "$2"; }
# check <case> <tool> <expect-on-route: stdin|parfile> : assert on the newest capture of <tool>
check() {
  local name="$1" tool="$2" route="$3" f
  f="$(ls -t "$CAP/$tool".* 2>/dev/null | head -1)"
  [ -n "$f" ] || { echo "FAIL $name: $tool was never called"; fail=$((fail+1)); return; }
  local argv envv r
  argv="$(sed -n '1p' "$f")"; envv="$(sed -n '/^ENV-BEGIN/,/^ENV-END/p' "$f")"
  if [ "$route" = parfile ]; then r="$(sed -n '/^PARFILE-BEGIN/,/^PARFILE-END/p' "$f")"; else r="$(sed -n '/^STDIN-BEGIN/,/^STDIN-END/p' "$f")"; fi
  local bad=""
  printf '%s' "$argv" | grep -q CANARY && bad="$bad argv[$argv]"
  printf '%s' "$envv" | grep -q CANARY && bad="$bad environ[$(printf '%s' "$envv" | grep CANARY | head -2 | tr '\n' ' ')]"
  printf '%s' "$r" | grep -q CANARYpw || bad="$bad no-canary-on-$route"
  if [ "$route" = parfile ]; then
    local pf mode; pf="$(sed -n 's/^PARFILE: //p' "$f")"; mode="$(sed -n 's/^PARFILE-MODE: //p' "$f")"
    [ "$mode" = 600 ] || bad="$bad parfile-mode[$mode]"
    case "$pf" in "$RUN_DIR"/*) bad="$bad parfile-in-run-dir";; esac
    [ -e "$pf" ] && bad="$bad parfile-left-behind"
  fi
  if [ -z "$bad" ]; then pass=$((pass+1)); else echo "FAIL $name:$bad"; fail=$((fail+1)); fi
  rm -f "$CAP/$tool".*
}
# ---- lib -----------------------------------------------------------------------------------------------------
RUN_DIR="$T/run"; LOG_FILE="$RUN_DIR/log"; mkdir -p "$RUN_DIR"; export RUN_DIR LOG_FILE
# shellcheck source=../lib/oracle-lib.sh
. "$ROOT/lib/oracle-lib.sh"
SQL_CMD="$STUB/bin/sqlplus -S"; SQL_CONNECT="u/CANARYpw@t"
sql_run X "alter user a identified by CANARYpw;" >/dev/null 2>&1; check "lib sql_run" sqlplus stdin
touch "$T/x.sql"; sql_script X "$T" x.sql a b >/dev/null 2>&1;             check "lib sql_script" sqlplus stdin
OGG_HOME="$STUB" ORACLE_HOME="$STUB" ggsci "alter credentialstore replace user ggadmin password CANARYpw alias ogg" >/dev/null 2>&1; check "lib ggsci" ggsci stdin
# the run dir and the log must not hold the canary either (incident packs collect what operators point them at)
VERBOSE=1 dbg "create database link L connect to U identified by \"CANARYpw\" using 'x'" 2>"$T/dbg.out"
if grep -q CANARYpw "$T/dbg.out"; then echo "FAIL lib dbg: plaintext in --verbose output"; fail=$((fail+1)); else pass=$((pass+1)); fi
if grep -rq CANARYpw "$RUN_DIR" 2>/dev/null; then echo "FAIL lib: canary under RUN_DIR ($(grep -rl CANARYpw "$RUN_DIR" | tr '\n' ' '))"; fail=$((fail+1)); else pass=$((pass+1)); fi
# ---- apex-patch -------------------------------------------------------------------------------------------------
eval "$(fn run_sql patching/apex-patch/apex-patch.sh)"; eval "$(fn run_sql_script patching/apex-patch/apex-patch.sh)"
PDB=P run_sql "alter user a identified by CANARYpw;" >/dev/null 2>&1; check "apex-patch run_sql" sqlplus stdin
PDB=P run_sql_script "$T" apexins.sql a b c >/dev/null 2>&1;         check "apex-patch run_sql_script" sqlplus stdin
# ---- ords-patch -------------------------------------------------------------------------------------------------
eval "$(fn sql_available patching/ords-patch/ords-patch.sh)"; eval "$(fn run_sql patching/ords-patch/ords-patch.sh)"
PDB=P run_sql "select 1 from dual;" >/dev/null 2>&1; check "ords-patch run_sql" sqlplus stdin
# ---- apex-export ------------------------------------------------------------------------------------------------
for f in conn_user conn_pass conn_db ax_sql ax_export; do eval "$(fn $f operations/apex-export/apex-export.sh)"; done
CONNECT="apx/CANARYpw@//h:1521/s"; SQLCL="$STUB/bin/sql"; SQLPLUS="$STUB/bin/sqlplus"; TOOL_MODE=sqlcl
ax_sql "select 1 from dual;" >/dev/null 2>&1;      check "apex-export ax_sql (sqlcl)" sql stdin
SQLCL="" ax_sql "select 1 from dual;" >/dev/null 2>&1; check "apex-export ax_sql (sqlplus)" sqlplus stdin
ax_export "$T/exp" -applicationid 100 >/dev/null 2>&1; check "apex-export ax_export (sqlcl)" sql stdin
# java mode: APEXExport only takes -password on argv, so the export must refuse unless the operator opted in
mkdir -p "$STUB/jbin"; printf '#!/bin/sh\necho "JAVA ARGV: $*" >"$CAP/java.$$"\n' >"$STUB/jbin/java"; chmod +x "$STUB/jbin/java"
out="$(TOOL_MODE=java JAVA="$STUB/jbin/java" APEX_HOME="$T" OJDBC_JAR="$T/o.jar" ax_export "$T/exp" 2>&1)"; rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'SQLcl' && ! ls "$CAP"/java.* >/dev/null 2>&1; then pass=$((pass+1)); else echo "FAIL apex-export java mode: not refused (rc=$rc: ${out:0:120})"; fail=$((fail+1)); fi
if ! grep -q CANARYpw "$LOG_FILE" 2>/dev/null; then pass=$((pass+1)); else echo "FAIL apex-export: canary in the log"; fail=$((fail+1)); fi
# ---- db-refresh Data Pump ---------------------------------------------------------------------------------------
eval "$(fn dp_run operations/db-refresh/db-refresh.sh)"
DB_HOME="$STUB"; EXP_CONNECT="dp/CANARYpw@tpdb"
dp_run expdp schemas=A directory=D dumpfile=x.dmp >/dev/null 2>&1; check "db-refresh dp_run expdp" expdp parfile
dp_run impdp schemas=A directory=D dumpfile=x.dmp >/dev/null 2>&1; check "db-refresh dp_run impdp" impdp parfile
# ---- static: no sqlplus/sql invocation in the tree takes a connect variable as an argument --------------------------
hits="$(grep -nE '(sqlplus|\$cmd|\$SQL_CMD|\$SQLCL|\$SQLPLUS)([^|#]*) +"?\$\{?[A-Z_]*CONNECT' --include='*.sh' -r "$ROOT/lib" "$ROOT/operations" "$ROOT/patching" "$ROOT/reports" | grep -v 'printf .connect ' || true)"
if [ -z "$hits" ]; then pass=$((pass+1)); else echo "FAIL static: connect string on a sqlplus command line:"; echo "$hits"; fail=$((fail+1)); fi
# ---- static: no keytool/orapki/openssl command line carries a password word (only :file / file: forms). A line that must
# (one documented, gated exception) carries the marker '# secret-on-argv: accepted' and is listed, not failed ---------------
# any value at all ('changeit', "MyPass1", "$VAR", env:, pass:) minus the file forms (-storepass:file F, -passin file:F) - Pi's cases
pwopt='-(storepass|keypass|srcstorepass|deststorepass|passin|passout|pwd|pkcs12pwd|password)'
hits="$(grep -rnE --include='*.sh' -e "${pwopt}[[:space:]=]+[^[:space:]]" "$ROOT/lib" "$ROOT/operations" "$ROOT/patching" "$ROOT/reports" | grep -vE -e "${pwopt}[[:space:]=]+\"?(file:|:file)" | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true)"
accepted="$(printf '%s\n' "$hits" | grep 'secret-on-argv: accepted' || true)"; hits="$(printf '%s\n' "$hits" | grep -v 'secret-on-argv: accepted' || true)"
[ -n "$accepted" ] && echo "accepted (documented, gated): $(printf '%s\n' "$accepted" | cut -d: -f1,2 | sed "s#$ROOT/##" | tr '\n' ' ')"
if [ -z "$hits" ]; then pass=$((pass+1)); else echo "FAIL static: a password word on a keytool/orapki/openssl command line:"; printf '%s\n' "$hits" | sed "s#$ROOT/##" | cut -c1-160; fail=$((fail+1)); fi
# ---- conf loaders: a secret in a conf file must not be exported into the environment of the script's children -----------
# every loader in the tree (the lib and the four self-contained copies), fed one conf holding five secret-shaped names and
# one plain one: after load_config a child's environ must hold the plain one and none of the secrets
H="$T/home"; mkdir -p "$H"; conf='WALLET_PWD=CANARY1
KEY_PASS=CANARY2
CACERTS_PASSWD=CANARY3
ADMIN_PASSWORD=CANARY4
SQL_CONNECT=u/CANARY5@t
MY_TOKEN=CANARY6
PLAIN_VAR=plainvalue'
for f in .oracle.conf .apex-patch.conf .ords-patch.conf .wls-patch.conf .oracle-diag.conf; do printf '%s\n' "$conf" >"$H/$f"; done
loader_case() { # <name> <bash snippet that defines and runs load_config>
  local name="$1" out; out="$(cd "$T" && HOME="$H" bash -c "$2; load_config >/dev/null 2>&1; env" 2>&1)"
  if printf '%s' "$out" | grep -q CANARY; then echo "FAIL loader $name: secrets exported [$(printf '%s' "$out" | grep -o '^[A-Z_]*=[^ ]*CANARY[0-9]*' | tr '\n' ' ')]"; fail=$((fail+1))
  elif ! printf '%s' "$out" | grep -q '^PLAIN_VAR=plainvalue'; then echo "FAIL loader $name: PLAIN_VAR not exported (the loader must still export ordinary keys)"; fail=$((fail+1))
  else pass=$((pass+1)); fi
}
loader_case "lib" "TOOL=x; . '$ROOT/lib/oracle-lib.sh'"
for sc in patching/apex-patch/apex-patch.sh patching/ords-patch/ords-patch.sh patching/wls-patch/wls-patch.sh reports/oracle-diag/oracle-diag.sh; do
  fn load_config "$sc" >"$T/loader.sh"; loader_case "$(basename "$sc" .sh)" "SCRIPT_DIR=$T/nowhere; . '$T/loader.sh'"
done
echo "secret-argv gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
