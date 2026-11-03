#!/usr/bin/env bash
# okv-diag.sh - read-only Oracle Key Vault client check: every okvclient.ora on the host, the endpoint
# certificate (age and, when the wallet password is available, notAfter), server reachability, okvutil
# connectivity, the PKCS#11 library, and the database side (TDE keystore OPEN per instance). Changes nothing.
#
# Usage: okv-diag.sh [options]
#   --sid SID        one database for the TDE side (default: every running instance)
#   --okv-home DIR   one OKV client home to check (default: auto-discover every okvclient.ora)
#   --out DIR  --lines N  --quiet  --no-tar
#
# Config: okv-diag.conf or the shared oracle.conf: OKV_OUT, SQL_CONNECT, OKV_HOME,
# OKV_WALLET_PASSWORD (the endpoint wallet password; env or config only, never an argument - it reaches
# openssl through a 600-mode file in the run dir and never on a command line).
# Output: OKV_OUT/<host>_<ts>/REPORT.md (FINDINGS first) + raw/ + tar.gz.
# Exit: 2 with a CRIT finding, 1 with a WARN, 0 clean. A read that failed is said out loud (a finding
# naming the database and the failure) - never a clean verdict, never exit 0.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="okv-diag"; VERSION="1.0.0"
# shellcheck source=../../lib/oracle-lib.sh
. "$SCRIPT_DIR/../../lib/oracle-lib.sh" || { echo "lib/oracle-lib.sh not found" >&2; exit 1; }

OKV_OUT="${OKV_OUT:-$HOME/okv-diag}"; ONLY_SID=""; OKV_HOME_OPT=""; MAKE_TAR=1
# the 600-mode endpoint-wallet password file; removed on exit AND on a signal, so a kill during openssl does
# not leave it behind (Cortex 3 Nov, the /tmp leak class)
SECRET_FILE=""

usage() { usage_from_header "$0"; }
parse_args() {
  while [ $# -gt 0 ]; do case "$1" in
    --sid) optchk "$@"; ONLY_SID="$2"; shift 2;;
    --okv-home) optchk "$@"; OKV_HOME_OPT="$2"; shift 2;;
    --out) optchk "$@"; OKV_OUT="$2"; shift 2;;
    --lines) optchk "$@"; DIAG_LINES="$2"; shift 2;;
    --quiet) QUIET=1; shift;;
    --no-tar) MAKE_TAR=0; shift;;
    --verbose) VERBOSE=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown option: $1";; esac; done
}

okv_configs() {
  if [ -n "$OKV_HOME_OPT" ]; then
    [ -f "$OKV_HOME_OPT/conf/okvclient.ora" ] && printf '%s\n' "$OKV_HOME_OPT/conf/okvclient.ora"
  else
    okv_ora_discover
  fi
}

# server_reachable <okvclient.ora>: one OK / UNREACHABLE line per SERVER= host:port on a 5s probe.
server_reachable() {
  local f="$1" s p
  printf 'servers reachable (TCP 5696 unless the line names a port):\n'
  for s in $(okv_field "$f" SERVER | tr ',' '\n' | cut -d: -f1 | sed '/^[[:space:]]*$/d'); do
    # sed -nE, not 'sed -n' with BRE '\+': BSD sed has no BRE \+, the substitution never matches on macOS, and
    # the port falls through to the 5696 default below - a healthy endpoint on its named port is reported
    # unreachable CRIT (TARS/Jocasta/Vision 3 Nov). ERE works on both BSD and GNU sed.
    p="$(printf '%s\n' "$(okv_field "$f" SERVER)" | tr ',' '\n' | grep -E "^${s}(:|$)" | sed -nE 's/^[^:]*:([0-9]+).*/\1/p' | head -1)"
    p="${p:-5696}"
    if to 5 bash -c "</dev/tcp/$s/$p" 2>/dev/null; then printf '  %s:%s OK\n' "$s" "$p"; else printf '  %s:%s UNREACHABLE\n' "$s" "$p"; fi
  done
}

# endpoint_cert <okvclient.ora>: the endpoint certificate lives 1 year. A console rotation does not replace
# ssl/ewallet.p12: the client writes the new wallet into a SUBFOLDER of ssl/ and repoints SSL_WALLET_LOC at it,
# so until that line moves the endpoint still runs the old certificate. $OKV_HOME/conf/ewallet.p12 is the TDE
# secret store, not the endpoint certificate, and is not read here.
endpoint_cert() {
  local f="$1" loc d wal m age exp pf pfx
  loc="$(okv_field "$f" SSL_WALLET_LOC)"; d="$(dirname "$(dirname "$f")")"; [ -n "$loc" ] || loc="$d/ssl"
  h3 "endpoint certificate"
  kv "SSL_WALLET_LOC" "$loc$(okv_is_rotated "$loc" && echo '  (rotated: a subfolder of ssl/)' || echo '  (not rotated: still the original ssl/ wallet)')"
  kv "OKV_HOSTNAME (node last talked to)" "$(okv_field "$f" OKV_HOSTNAME)"
  kv "UPDATE_TIMESTAMP" "$(okv_field "$f" UPDATE_TIMESTAMP)"
  wal="$loc/ewallet.p12"
  if [ ! -f "$wal" ]; then finding CRIT okv "SSL_WALLET_LOC in $f points at $loc but $wal does not exist - the endpoint cannot present a certificate to Key Vault"; kv_end; return 0; fi
  m="$(stat -c %Y "$wal" 2>/dev/null || stat -f %m "$wal" 2>/dev/null)" || true
  if [ -z "$m" ]; then finding WARN okv "cannot stat $wal - endpoint certificate age and expiry unknown (not assumed fine)"; kv_end; return 0; fi
  age=$(( ( $(date +%s) - m ) / 86400 )); kv "ewallet.p12 age" "$age days"
  if [ -n "${OKV_WALLET_PASSWORD:-}" ] && command -v openssl >/dev/null 2>&1; then
    pf="$(tmp_secret_file "$OKV_WALLET_PASSWORD")"; SECRET_FILE="$pf"
    exp="$( { openssl pkcs12 -in "$wal" -nokeys -clcerts -passin "file:$pf" 2>/dev/null || openssl pkcs12 -legacy -in "$wal" -nokeys -clcerts -passin "file:$pf" 2>/dev/null; } | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 )"
    rm -f "$pf"; SECRET_FILE=""
    if [ -z "$exp" ]; then finding WARN okv "could not read $wal with OKV_WALLET_PASSWORD (wrong password, or an openssl that cannot open this p12) - endpoint certificate expiry unknown, file age $age days"; cert_age_finding "$wal" "$age" "$f"
    else
      kv "endpoint certificate notAfter" "$exp"
      local es; es="$(date -d "$exp" +%s 2>/dev/null || date -j -f '%b %d %T %Y %Z' "$exp" +%s 2>/dev/null)"
      if [ -z "$es" ]; then finding WARN okv "endpoint certificate notAfter '$exp' in $wal could not be parsed by date - check it by hand; file age $age days"; cert_age_finding "$wal" "$age" "$f"
      else local dl=$(( (es - $(date +%s)) / 86400 ))
        if [ "$dl" -lt 0 ]; then finding CRIT okv "endpoint certificate in $wal EXPIRED on $exp - TDE cannot reach Key Vault after the next keystore open"
        elif [ "$dl" -lt 30 ]; then finding CRIT okv "endpoint certificate in $wal expires in $dl days ($exp): rotate it in the Key Vault console and run 'okvutil list' until SSL_WALLET_LOC changes"
        elif [ "$dl" -lt 90 ]; then finding WARN okv "endpoint certificate in $wal expires in $dl days ($exp): plan the rotation"; fi
      fi
    fi
  else cert_age_finding "$wal" "$age" "$f"; fi
  kv_end
}
# cert_age_finding <wallet> <age> <okvclient.ora>: the age stands in when the wallet password is not available.
# An unreadable date is a WARN plus the age, never silence.
cert_age_finding() {
  local wal="$1" age="$2" f="$3"
  if [ "$age" -ge 365 ]; then finding CRIT okv "endpoint wallet $wal is $age days old and endpoint certificates live 1 year: unless it was rotated in place the certificate has EXPIRED and TDE cannot reach Key Vault at the next keystore open (set OKV_WALLET_PASSWORD to read the real date; rotate in the console, then 'okvutil list -v 4' until SSL_WALLET_LOC in $f moves to a subfolder of ssl/)"
  elif [ "$age" -ge 300 ]; then finding WARN okv "endpoint wallet $wal is $age days old: endpoint certificates live 1 year, so about $((365 - age)) days remain unless it was rotated (set OKV_WALLET_PASSWORD to read the real date)"; fi
}

diag_okv_client() {
  h1 "Oracle Key Vault client"; say "key vault client"
  local confs; confs="$(okv_configs)"
  if [ -z "$confs" ]; then
    if [ -n "$OKV_HOME_OPT" ]; then finding WARN okv "no okvclient.ora under --okv-home $OKV_HOME_OPT (looked for $OKV_HOME_OPT/conf/okvclient.ora) - check the path, or omit --okv-home to auto-discover"; else finding WARN okv "no okvclient.ora found on the host (looked in WALLET_ROOT, /u01/app/oracle/okv, OKV_HOME, ORACLE_HOME/flex_tde_wallet, ...) - pass --okv-home DIR if it lives elsewhere"; fi
    return 0
  fi
  local f; while IFS= read -r f <&3; do
    [ -f "$f" ] || { finding WARN okv "$f does not exist"; continue; }
    h2 "$f"
    section "okv_conf_$(printf '%s' "$f" | md5sum | cut -c1-8)" grep -vE '^#|^$' "$f"
    local d; d="$(dirname "$(dirname "$f")")"
    section "okv_dir_$(printf '%s' "$f" | md5sum | cut -c1-8)" ls -la "$d/bin" "$d/ssl" "$d/lib"
    local rname; rname="okv_reach_$(printf '%s' "$f" | md5sum | cut -c1-8)"
    local rfile="$RAW/$rname.txt" nok nbad
    { server_reachable "$f"; } >"$rfile" 2>&1
    fence_start; head -n "$DIAG_LINES" "$rfile" >>"$REPORT"; fence_end
    nok="$(grep -cE '^  [^ ]+:[0-9]+ OK$' "$rfile" 2>/dev/null || true)"; nbad="$(grep -cE '^  [^ ]+:[0-9]+ UNREACHABLE$' "$rfile" 2>/dev/null || true)"
    if [ $(( ${nok:-0} + ${nbad:-0} )) -eq 0 ]; then
      # no SERVER= line means nothing was probed: that is an unreadable read, not a clean one. Without this the
      # report shows an empty reachability fence, 0 findings and exit 0 while the client reaches no Key Vault
      # (Vision, 3 Nov).
      finding CRIT okv "$f has no usable SERVER= line - nothing was probed and the client does not know which Key Vault server to reach; reachability NOT checked (a missing or failed read is not a clean one)"
    elif [ "${nbad:-0}" -gt 0 ]; then
      if [ "${nok:-0}" = 0 ]; then finding CRIT okv "no Oracle Key Vault server in $f is reachable - TDE cannot open the keystore after a restart"; else finding WARN okv "$nbad of $((nok + nbad)) Key Vault servers in $f unreachable (HA degraded)"; fi
    fi
    [ -x "$d/bin/okvutil" ] && section "okvutil_$(printf '%s' "$f" | md5sum | cut -c1-8)" "$d/bin/okvutil" list || finding WARN okv "$d/bin/okvutil is missing or not executable - cannot check the client's view of Key Vault"
    grep -qiE 'okvutil.*(error|fail|unable)|Cannot connect|Unable to connect|Connection refused' "$RAW/okvutil_$(printf '%s' "$f" | md5sum | cut -c1-8).txt" 2>/dev/null && finding WARN okv "okvutil list failed against Key Vault (wallet password needed, endpoint not enrolled, or no server reachable)"
    endpoint_cert "$f"
  done 3<<<"$confs"
  # PKCS#11: report the state whether or not the library was found. A discovery that returned nothing used to
  # leave this section silent, so a host whose client cannot reach Key Vault looked clean (Vision 3 Nov).
  local dbh pk; dbh="$(oratab_home "$(db_instances 2>/dev/null | head -1)")"; pk=""
  [ -n "${dbh:-}" ] && [ -f "$dbh/lib/liborapkcs.so" ] && pk="$dbh/lib/liborapkcs.so"
  [ -f /opt/oracle/extapi/64/hsm/oracle/1.0.0/liborapkcs.so ] && pk="/opt/oracle/extapi/64/hsm/oracle/1.0.0/liborapkcs.so"
  if [ -n "$pk" ]; then kv "PKCS#11 library (liborapkcs.so)" "$pk"; kv_end
  elif [ -z "${dbh:-}" ]; then finding WARN okv "no liborapkcs.so at /opt/oracle/extapi/64/hsm/oracle/1.0.0, and ORACLE_HOME could not be resolved (db_instances/oratab returned nothing) so the ORACLE_HOME/lib check did NOT run - if this host uses OKV for TDE, the client cannot reach Key Vault"
  else finding WARN okv "no liborapkcs.so in $dbh/lib or /opt/oracle/extapi/64/hsm/oracle/1.0.0 - if this host uses OKV for TDE, the client cannot reach Key Vault (a not-found read is reported, not left silent)"; fi
  return 0
}

# tde_checks <sid>: the database side - the TDE keystore must be OPEN against every instance, or TDE cannot
# read an encrypted tablespace. sql_checks adds a WARN naming the sid when the batch does not complete, so a
# failed read is never a clean verdict.
tde_checks() {
  local sid="$1"
  h3 "database $sid: TDE keystore"
  sql_checks "$sid" "$sid" "
select 'CHECK|'||case when upper(status) like 'OPEN%' then 'INFO' else 'CRIT' end||'|TDE keystore status = '||status||' (wallet_type='||nvl(wallet_type,'?')||')' from v\$encryption_wallet;
select 'CHECK|INFO|wallet_root = '||nvl(value,'(unset)') from v\$parameter where name='wallet_root';
select 'CHECK|INFO|tde_configuration = '||nvl(value,'(unset)') from v\$parameter where name='tde_configuration';" || true
}

diag_databases() {
  local sids="" s
  if [ -n "$ONLY_SID" ]; then sids="$ONLY_SID"
  elif sids="$(db_instances)"; then sids="$(printf '%s\n' "$sids" | grep -vE '^\+ASM|^-MGMTDB|^\+APX')" || true
  else finding CRIT db "cannot read the process list (ps failed, ${PROC_DIR:-/proc} unreadable) - no database was found or checked; pass --sid to check one"; return 0; fi
  h1 "Database TDE"; say "database TDE"
  for s in $sids; do
    if sql_ok "$s"; then tde_checks "$s"
    else finding CRIT db "$s: cannot connect as sysdba - the TDE keystore state was NOT checked"; fi
  done
  return 0
}

main() {
  load_config; parse_args "$@"
  init_run_dir "okv-diag"
  # EXIT removes the 600-mode file; INT/TERM must EXIT through it, not just run the rm and carry on - a handler that
  # does not exit swallows the signal, so a timeout kill or Ctrl-C let the script finish and return findings_rc as if
  # it had succeeded (Cortex 3 Nov). 'exit' still fires the EXIT trap, so the file is removed.
  trap 'rm -f "${SECRET_FILE:-}" 2>/dev/null' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  report_init "$OKV_OUT/${HOST}_$(date '+%Y%m%d_%H%M%S')"
  say "okv-diag $VERSION -> $OUT"
  h1 "Host"; kv "host" "$HOST"; kv "user" "$(id -un)"; kv_end
  diag_okv_client
  diag_databases
  report_finish "okv-diag: $HOST $(date '+%Y-%m-%d')" "$MAKE_TAR" >/dev/null
  [ "$QUIET" = 1 ] || { echo; print_findings; }
  printf '\n%s\n' "$OUT/REPORT.md"
  findings_rc
}
main "$@"
