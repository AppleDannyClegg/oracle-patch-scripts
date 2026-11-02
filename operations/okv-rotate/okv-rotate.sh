#!/usr/bin/env bash
# okv-rotate.sh - walk the per-node Oracle Key Vault endpoint-certificate rotation and prove it happened.
#
# The rotation itself is done in the Key Vault console and cannot be scripted. What this script owns is the
# part around it, from Gen's runbook (OKV endpoint certificate rotation, 1 Nov 2026):
#   check   where the endpoint is now: SSL_WALLET_LOC still ends at .../ssl (not rotated) or points into a
#           subfolder (rotated), OKV_HOSTNAME, UPDATE_TIMESTAMP, the endpoint certificate's serial and
#           notAfter, and whether TDE is OPEN on every instance (and standby apply, on a standby).
#   wait    run 'okvutil list -v 4' and re-read okvclient.ora until SSL_WALLET_LOC moves under ssl/ - the
#           console rotation is not finished until that line moves. Prints OKV_HOSTNAME each run: the switch
#           is expected on the run whose OKV_HOSTNAME is the node the console rotation was started from.
#   verify  the runbook's step 4/5 as assertions: switched, certificate notAfter in the future, every TDE
#           wallet OPEN, standby MRP0 APPLYING_LOG/WAIT_FOR_LOG and a non-growing apply lag.
#   report  check as REPORT.md, for the change record.
#
# Read-only. It never rotates anything and never writes into $OKV_HOME: it reads okvclient.ora, reads the
# endpoint wallet with the wallet password, runs okvutil list and sqlplus selects. It never touches
# $OKV_HOME/conf/ewallet.p12 (the TDE secret store), never edits SERVER=, and never closes/reopens the
# keystore, restarts an instance or re-enrols an endpoint. Runs as the Oracle software owner, on each node.
#
# Usage: okv-rotate.sh <command> [options]
#
# Commands
#   inspect               Read-only report of this node's endpoint state (alias: check). Exit 2 CRIT / 1 WARN / 0.
#   check                 Alias for inspect.
#   plan                  Print the ordered rotation steps for this node, with the live state and exact commands.
#                         Read-only; the console step stays manual.
#   preflight             Tools, okvclient.ora (readable/writable), okvutil, openssl, password, instances - ready?
#   wait                  Wait for the console rotation to switch. Runs okvutil once, then polls okvclient.ora
#                         (the client refreshes ~hourly) keyed on UPDATE_TIMESTAMP. Exit 0 switched, new wallet
#                         present and okvutil ok; 1 do NOT go to the next node (repointed but ewallet.p12 missing /
#                         switched but okvutil failed / okvutil failed on every run); 2 clean reads, still on the
#                         old wallet - re-rotate and re-run wait.
#   verify                inspect as pass/fail assertions, with 'not rotated' escalated to CRIT. Exit 2 CRIT / 1 WARN / 0.
#   apply                 The script's half: wait, then verify (the console click is manual).
#   backup                Copy okvclient.ora (the SSL_WALLET_LOC line) into the run dir, for rollback.
#   rollback              Restore okvclient.ora from the run-dir backup. Never touches $OKV_HOME/conf/ewallet.p12.
#   run                   inspect, then wait, then verify (the whole local sequence).
#   report                inspect with --report: writes REPORT.md and raw/.
#
# Options
#   --okv-home DIR        $OKV_HOME (default: discovered; OKV_HOME from the config/env is preferred)
#   --ora FILE            okvclient.ora (default: <okv-home>/conf/okvclient.ora)
#   --node NAME           node label in the report (default: hostname -s)
#   --rotated-from NAME   the OKV node the console rotation was started from; wait flags the switch match
#   --timeout SECS        wait: give up after this long (default 3600; the client refreshes ~hourly)
#   --interval SECS       wait: seconds between okvclient.ora polls (default 60)
#   --max-runs N          wait: optional cap on polls (default 0 = no cap; rely on --timeout)
#   --out DIR             report output dir (default $CERT_OUT or ~/okv-rotate)
#   --dry-run --yes --force --json --verbose --run-dir DIR   (shared library behaviour; --dry-run only prints)
#
# Config: okv-rotate.conf (600), ~/.okv-rotate.conf or the shared oracle.conf -
#   OKV_HOME, OKV_NODE, OKV_ROTATED_FROM, OKV_TIMEOUT, OKV_INTERVAL, OKV_MAX_RUNS,
#   OKV_CERT_WARN_DAYS (90), OKV_CERT_CRIT_DAYS (30), OKV_AGE_WARN_DAYS (300), OKV_AGE_CRIT_DAYS (365),
#   OKV_WALLET_PASSWORD (or set it in the environment; it is read through a 600-mode file, never on argv).

# shellcheck disable=SC2034
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="okv-rotate"; VERSION="1.0.0"
# shellcheck source=../../lib/oracle-lib.sh
. "$SCRIPT_DIR/../../lib/oracle-lib.sh" || { echo "lib/oracle-lib.sh not found" >&2; exit 1; }

OKV_HOME="${OKV_HOME:-}"; OKV_ORA="${OKV_ORA:-}"; OKV_NODE="${OKV_NODE:-}"
ROTATED_FROM="${OKV_ROTATED_FROM:-}"; WAIT_TIMEOUT="${OKV_TIMEOUT:-3600}"; WAIT_INTERVAL="${OKV_INTERVAL:-60}"
MAX_RUNS="${OKV_MAX_RUNS:-0}"
CERT_WARN_DAYS="${OKV_CERT_WARN_DAYS:-90}"; CERT_CRIT_DAYS="${OKV_CERT_CRIT_DAYS:-30}"
AGE_WARN_DAYS="${OKV_AGE_WARN_DAYS:-300}"; AGE_CRIT_DAYS="${OKV_AGE_CRIT_DAYS:-365}"
DO_REPORT=0; OKV_PW=""; VERIFY_STRICT=0

usage() { usage_from_header "$0"; }
parse_opts() {
  while [ $# -gt 0 ]; do case "$1" in
    --okv-home) optchk "$@"; OKV_HOME="$2"; shift 2;;
    --ora) optchk "$@"; OKV_ORA="$2"; shift 2;;
    --node) optchk "$@"; OKV_NODE="$2"; shift 2;;
    --rotated-from) optchk "$@"; ROTATED_FROM="$2"; shift 2;;
    --timeout) optchk "$@"; WAIT_TIMEOUT="$2"; shift 2;;
    --interval) optchk "$@"; WAIT_INTERVAL="$2"; shift 2;;
    --max-runs) optchk "$@"; MAX_RUNS="$2"; shift 2;;
    --out) optchk "$@"; CERT_OUT="$2"; shift 2;;
    --force) FORCE=1; shift;;
    --run-dir) optchk "$@"; RUN_DIR="$2"; shift 2;;
    --report) DO_REPORT=1; shift;;
    --dry-run) DRY_RUN=1; shift;; --yes) ASSUME_YES=1; shift;; --json) JSON_OUT=1; shift;; --verbose) VERBOSE=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown option: $1 (see --help)";;
  esac; done
}

# okv_ora_file: the okvclient.ora to read - --ora, then $OKV_HOME/conf, then the lib's discovery list
okv_ora_file() {
  if [ -n "$OKV_ORA" ]; then [ -f "$OKV_ORA" ] && { printf '%s' "$OKV_ORA"; return 0; }; die "--ora $OKV_ORA is not a file"; fi
  if [ -n "$OKV_HOME" ] && [ -f "$OKV_HOME/conf/okvclient.ora" ]; then printf '%s' "$OKV_HOME/conf/okvclient.ora"; return 0; fi
  okv_ora_discover | head -1
}
okv_client_dir() { dirname "$(dirname "$1")"; }

# okv_pwfile/okv_pwfile_rm: the wallet password reaches openssl through a 600-mode file, never argv/environ
okv_pwfile() {
  [ -n "${OKV_WALLET_PASSWORD:-}" ] || return 1
  OKV_PW="$(mktemp "${TMPDIR:-/tmp}/okv.XXXXXX" 2>/dev/null)" || return 1
  chmod 600 "$OKV_PW"; printf '%s' "$OKV_WALLET_PASSWORD" >"$OKV_PW"
}
okv_pwfile_rm() { [ -n "$OKV_PW" ] && rm -f "$OKV_PW"; OKV_PW=""; }

# okv_cert <p12>: "serial|notAfter" when the wallet can be read (needs OKV_WALLET_PASSWORD), else nothing
okv_cert() {
  local wal="$1" out
  command -v openssl >/dev/null 2>&1 || return 0
  okv_pwfile || return 0
  out="$( { openssl pkcs12 -in "$wal" -nokeys -clcerts -passin "file:$OKV_PW" 2>/dev/null \
         || openssl pkcs12 -legacy -in "$wal" -nokeys -clcerts -passin "file:$OKV_PW" 2>/dev/null; } )"  # -legacy on RC2 errors
  okv_pwfile_rm
  [ -n "$out" ] || return 0
  printf '%s|%s' "$(printf '%s' "$out" | openssl x509 -noout -serial 2>/dev/null | cut -d= -f2)" \
                 "$(printf '%s' "$out" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
}

# okv_db_role: PRIMARY / PHYSICAL_STANDBY / ... (empty when it cannot be read)
okv_db_role() {
  local s; s="$(db_instances | head -1)"; [ -n "$s" ] || return 1
  sql_lines "$s" "set heading off feedback off\nselect database_role from v\$database;" 2>/dev/null | head -1 | tr -d '[:space:]'
}
# okv_tde: "inst_id|status|wallet_type" for every instance (gv$ works on a mounted standby).
# Its status is the sqlplus status: a failed read is NOT an empty result - the caller must say so, not assume fine.
okv_tde() {
  local s; s="$(db_instances | head -1)"; [ -n "$s" ] || return 1
  sql_lines "$s" "set heading off feedback off\nselect inst_id||'|'||status||'|'||wallet_type from gv\$encryption_wallet order by inst_id;" | grep -E '^[0-9]+\|'
}
# okv_standby: MRP process rows and the apply/transport lag, when this is a standby
okv_standby() {
  local s; s="$(db_instances | head -1)"; [ -n "$s" ] || return 1
  sql_lines "$s" "set heading off feedback off\nselect process||'|'||status from gv\$managed_standby where process like 'MRP%';\nselect name||'|'||value from v\$dataguard_stats where name in ('apply lag','transport lag');" | grep -E '^(MRP|[Aa]pply lag|[Tt]ransport lag)\|'
}

# okv_age_days <file>: whole days since the file's mtime (empty when it cannot be read - never assumed 0)
okv_age_days() {
  local m; m="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null)" || true
  [ -n "$m" ] || return 0
  echo $(( ( $(date +%s) - m ) / 86400 ))
}

# okv_check_node: the runbook's step 1/4/5 as findings. Prints the key values; the caller prints findings.
okv_check_node() {
  local f loc host upd cdir wal age; f="$(okv_ora_file)" || { finding WARN okv "no okvclient.ora found (set --ora or OKV_HOME) - endpoint state unknown, nothing assumed fine"; return 0; }
  loc="$(okv_field "$f" SSL_WALLET_LOC)"; host="$(okv_field "$f" OKV_HOSTNAME)"; upd="$(okv_field "$f" UPDATE_TIMESTAMP)"
  cdir="$(okv_client_dir "$f")"; [ -n "$loc" ] || loc="$cdir/ssl"; wal="$loc/ewallet.p12"

  kv "okvclient.ora" "$f"; kv "client dir" "$cdir"
  if okv_is_rotated "$loc"; then kv "SSL_WALLET_LOC" "$loc  (rotated: a subfolder of ssl/)"
  else kv "SSL_WALLET_LOC" "$loc  (not rotated: still the original ssl/ wallet)"
    if [ "$VERIFY_STRICT" = 1 ]; then finding CRIT okv "verify FAILED: endpoint is NOT rotated - SSL_WALLET_LOC in $f is $loc (ends at /ssl); the console rotation has not switched this node"
    else finding WARN okv "endpoint is NOT rotated: SSL_WALLET_LOC in $f is $loc (ends at /ssl). Rotate it in the Key Vault console, then run 'okv-rotate.sh wait'"; fi
  fi
  kv "OKV_HOSTNAME (node last talked to)" "${host:-?}"; kv "UPDATE_TIMESTAMP" "${upd:-?}"
  if [ -n "$ROTATED_FROM" ] && [ -n "$host" ] && [ "$host" = "$ROTATED_FROM" ]; then kv "rotation started from" "$ROTATED_FROM  (matches OKV_HOSTNAME - this is the run expected to switch)"; fi

  # a new subfolder under ssl/ and the wallet it holds
  local nsub; nsub="$(find "$cdir/ssl" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"; kv "subfolders under ssl/" "$nsub"
  [ -f "$wal" ] || { finding CRIT okv "SSL_WALLET_LOC in $f points at $loc but $wal does not exist - the endpoint cannot present a certificate to Key Vault"; kv_end; }
  [ -f "$wal" ] || { okv_tde_check; okv_standby_check; return 0; }
  age="$(okv_age_days "$wal")"
  if [ -z "$age" ]; then finding WARN okv "cannot stat $wal - endpoint certificate age and expiry unknown (not assumed fine)"; kv_end
  else
    kv "ewallet.p12 age" "$age days"
    local ci serial exp
    ci="$(okv_cert "$wal")"; serial="${ci%%|*}"; exp="${ci#*|}"
    if [ -z "${OKV_WALLET_PASSWORD:-}" ]; then
      finding INFO okv "certificate notAfter not read (set OKV_WALLET_PASSWORD to read it; file age $age days used instead)"
      okv_age_finding_local "$wal" "$age"
    elif [ -z "$ci" ] || [ "$exp" = "$ci" ]; then
      finding WARN okv "could not read $wal with OKV_WALLET_PASSWORD (wrong password, or an openssl that cannot open this p12) - expiry unknown, file age $age days"; okv_age_finding_local "$wal" "$age"
    else
      kv "endpoint certificate serial" "$serial"; kv "endpoint certificate notAfter" "$exp"
      local es dl
      es="$(date -d "$exp" +%s 2>/dev/null || date -j -f '%b %d %T %Y %Z' "$exp" +%s 2>/dev/null)"
      if [ -z "$es" ]; then finding WARN okv "notAfter '$exp' could not be parsed by date - check it by hand; file age $age days"; okv_age_finding_local "$wal" "$age"
      else dl=$(( (es - $(date +%s)) / 86400 ))
        if [ "$dl" -lt 0 ]; then finding CRIT okv "endpoint certificate in $wal EXPIRED on $exp - TDE cannot reach Key Vault after the next keystore open"
        elif [ "$dl" -lt "$CERT_CRIT_DAYS" ]; then finding CRIT okv "endpoint certificate expires in $dl days ($exp): rotate it now"
        elif [ "$dl" -lt "$CERT_WARN_DAYS" ]; then finding WARN okv "endpoint certificate expires in $dl days ($exp): plan the rotation"; fi
      fi
    fi
  fi
  kv_end
  okv_tde_check
  okv_standby_check
}

# the age heuristic, same thresholds as oracle-diag: WARN 300, CRIT 365
okv_age_finding_local() {
  local wal="$1" age="$2"
  if [ "$age" -ge "$AGE_CRIT_DAYS" ]; then finding CRIT okv "endpoint wallet $wal is $age days old and endpoint certificates live 1 year: unless it was rotated the certificate has EXPIRED (set OKV_WALLET_PASSWORD to read the real date)"
  elif [ "$age" -ge "$AGE_WARN_DAYS" ]; then finding WARN okv "endpoint wallet $wal is $age days old: about $((365 - age)) days remain unless it was rotated (set OKV_WALLET_PASSWORD to read the real date)"; fi
}

# TDE must stay OPEN through the rotation; a CLOSED/CLOSING wallet is the failure the rotation risks
okv_tde_check() {
  local rows="" rc=0 bad
  rows="$(okv_tde)" || rc=$?
  if [ "$rc" != 0 ]; then finding WARN okv "gv\$encryption_wallet could not be read (sqlplus status $rc, see the ORA- above) - the 'OPEN on every inst_id' assertion was NOT evaluated"; return 0; fi
  [ -n "$rows" ] || { finding INFO okv "no open database instance on this host - TDE wallets not checked"; return 0; }
  h2 "TDE wallets"; table_head "inst_id" "status" "wallet_type"
  while IFS='|' read -r i st wt; do [ -n "$i" ] || continue; table_row "$i" "$st" "$wt"; done <<<"$rows"
  bad="$(printf '%s\n' "$rows" | awk -F'|' '$2 !~ /^OPEN/')"
  [ -n "$bad" ] && finding CRIT okv "TDE wallet is not OPEN on: $(printf '%s' "$bad" | tr '\n' ' ') - Key Vault access is failing after the rotation (note: OPEN_UNKNOWN_MASTER_KEY_STATUS on the PDB rows of a mounted standby is normal)"
}

# standby apply needs the TDE keys, so a stopped/behind apply is the real functional test
okv_standby_check() {
  local rows="" mrp role rc=0
  rows="$(okv_standby)" || rc=$?
  role="$(okv_db_role)" || role=""
  if [ "$rc" != 0 ]; then finding WARN okv "gv\$managed_standby/v\$dataguard_stats could not be read (sqlplus status $rc) - redo apply was NOT checked"; return 0; fi
  [ -n "$role" ] || return 0                 # cannot tell the role -> make no claim about apply
  if [ "$role" != "PHYSICAL_STANDBY" ]; then
    [ -n "$rows" ] && { h2 "Standby apply"; fence_start; printf '%s\n' "$rows" >>"$REPORT"; fence_end; }
    return 0
  fi
  h2 "Standby apply"
  [ -n "$rows" ] && { fence_start; printf '%s\n' "$rows" >>"$REPORT"; fence_end; }
  mrp="$(printf '%s\n' "$rows" | awk -F'|' '$1 ~ /^MRP/ {print $2}' | head -1)"
  if [ -z "$mrp" ]; then finding CRIT okv "database_role is PHYSICAL_STANDBY but gv\$managed_standby has no MRP row - redo apply is not running; apply needs the TDE keys, so this is the rotation failure the runbook checks for"; return 0; fi
  case "$mrp" in APPLYING_LOG|WAIT_FOR_LOG) ;; *) finding CRIT okv "MRP is $mrp, not APPLYING_LOG/WAIT_FOR_LOG - redo apply is not running after the rotation";; esac
}

# cmd_plan: the ordered steps for this node, read-only. The console step is manual, so plan is the runbook
# printed for the node in front of you, with the live state filled in and the 22:32 timing caveat.
cmd_plan() {
  local node="${OKV_NODE:-$(hostname -s)}" f loc host ts
  printf 'OKV endpoint certificate rotation - plan for %s\n\n' "$node"
  f="$(okv_ora_file)" || { printf 'no okvclient.ora found: set OKV_HOME or --ora before planning\n'; return 1; }
  loc="$(okv_field "$f" SSL_WALLET_LOC)"; host="$(okv_field "$f" OKV_HOSTNAME)"; ts="$(okv_field "$f" UPDATE_TIMESTAMP)"
  printf 'okvclient.ora : %s\n' "$f"
  printf 'SSL_WALLET_LOC: %s %s\n' "${loc:-?}" "$(okv_is_rotated "$loc" && echo '(rotated)' || echo '(NOT rotated)')"
  printf 'OKV_HOSTNAME  : %s\nUPDATE_TIMESTAMP: %s\n\n' "${host:-?}" "${ts:-?}"
  if okv_is_rotated "$loc"; then printf 'This node is ALREADY rotated. Do not rotate it again; run:  okv-rotate.sh verify\n'; return 0; fi
  cat <<EOF
Steps (one node at a time; finish and verify this node before the next):
  1. (manual, Key Vault console) log in on the node shown as OKV_HOSTNAME (${host:-unknown}) and rotate THIS
     endpoint from there. Note which node you used.
  2. Run okvutil once and wait for the switch:
       okv-rotate.sh wait --rotated-from <the node you rotated from>
     The client refreshes its config about ONCE AN HOUR, so this can take up to ~1h; running okvutil
     repeatedly does not help. Switched = SSL_WALLET_LOC points into a subfolder of ssl/ and its ewallet.p12 exists.
  3. If wait says the config refreshed but SSL_WALLET_LOC is still .../ssl: re-rotate from the node now shown
     as OKV_HOSTNAME. 2-3 re-rotations with no switch -> raise a Sev 2 SR.
  4. Verify (runbook steps 4-5):  okv-rotate.sh verify
     asserts: switched; cert notAfter in the future; gv\$encryption_wallet OPEN on every inst_id
     (OPEN_UNKNOWN_MASTER_KEY_STATUS on a mounted standby's PDB rows is normal); on a standby, MRP0
     APPLYING_LOG/WAIT_FOR_LOG and apply lag not growing.
  5. Record:  okv-rotate.sh report

Do NOT: touch \$OKV_HOME/conf/ewallet.p12 (the TDE secret store); delete the old \$OKV_HOME/ssl/ewallet.p12
(keep it for rollback); hand-edit SERVER=; close/reopen the keystore, restart instances or re-enrol.
EOF
}

# cmd_preflight: are the tools, the file and the password here to do (and to verify) this on this node?
cmd_preflight() {
  local f="" cdir; report_init "$RUN_DIR/report"; VERIFY_STRICT=1
  if f="$(okv_ora_file)"; then kv okvclient.ora "$f"; [ -r "$f" ] || finding CRIT okv "cannot read $f"; [ -w "$f" ] || finding WARN okv "$f is not writable - rollback (restore the file) needs the oracle owner"
  else finding CRIT okv "no okvclient.ora found (set OKV_HOME or --ora)"; fi
  if [ -n "$f" ]; then cdir="$(okv_client_dir "$f")"; [ -x "$cdir/bin/okvutil" ] && kv okvutil "$cdir/bin/okvutil" || finding WARN okv "no executable $cdir/bin/okvutil - wait cannot refresh the config"; fi
  have openssl && kv openssl "$(command -v openssl)" || finding WARN okv "openssl missing - the certificate notAfter cannot be read"
  [ -n "${OKV_WALLET_PASSWORD:-}" ] && kv "wallet password" "set (read through a 600-mode file)" || finding WARN okv "OKV_WALLET_PASSWORD not set - notAfter falls back to the wallet age (300/365 days)"
  [ -n "$(db_instances | head -1)" ] && kv "database instances" "$(db_instances | tr '\n' ' ')" || finding WARN okv "no database instance found - the TDE gv\$encryption_wallet assertion cannot be checked here"
  kv_end; print_findings; findings_rc
}

# cmd_backup: snapshot okvclient.ora (the switch line) for rollback. Writes only into the run dir.
cmd_backup() {
  local f b; f="$(okv_ora_file)" || die "no okvclient.ora found (set OKV_HOME or --ora)"
  b="$RUN_DIR/okvclient.ora.bak"
  if [ "$DRY_RUN" = 1 ]; then log "dry-run: would copy $f -> $b"; return 0; fi
  cp -p "$f" "$b" || die "backup of $f failed"
  state_set backup_ora "$b"; state_set backup_ssl_wallet_loc "$(okv_field "$f" SSL_WALLET_LOC)"
  log "backed up $f -> $b (SSL_WALLET_LOC=$(okv_field "$f" SSL_WALLET_LOC))"
}

# cmd_apply: the script's half of the rotation - wait for the switch, then verify. The console click is manual.
cmd_apply() {
  log "apply: the console rotation is manual; running wait then verify"
  cmd_wait || return $?
  cmd_verify
}

# cmd_rollback: restore the previous okvclient.ora (the old SSL_WALLET_LOC). Never touches conf/ewallet.p12.
cmd_rollback() {
  local b f cdir; b="$(state_get backup_ora || true)"; [ -n "$b" ] || b="$RUN_DIR/okvclient.ora.bak"
  [ -f "$b" ] || die "no okvclient.ora backup here ($RUN_DIR): run 'backup' first, or give --run-dir of the run that holds one"
  f="$(okv_ora_file)" || die "no okvclient.ora found (set OKV_HOME or --ora)"
  warn "rollback restores $f from $b (the previous SSL_WALLET_LOC). It does NOT touch \$OKV_HOME/conf/ewallet.p12; keep the old ssl/ewallet.p12 until well after the deadline"
  if [ "$DRY_RUN" = 1 ]; then log "dry-run: would restore $f from $b"; return 0; fi
  cp -p "$b" "$f" || { state_set rollback failed; die "restore of $f failed"; }
  cdir="$(okv_client_dir "$f")"
  if [ -x "$cdir/bin/okvutil" ]; then local orc=0; to 60 "$cdir/bin/okvutil" list -v 4 </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 || orc=$?; fi
  state_set rollback ok; log "rolled back: SSL_WALLET_LOC is now $(okv_field "$f" SSL_WALLET_LOC)"
}

# cmd_run: inspect, then wait for the switch, then verify (the whole local sequence).
cmd_run() { cmd_check || true; cmd_wait || return $?; cmd_verify; }

cmd_check() {
  local node="${OKV_NODE:-$(hostname -s)}" od
  od="${CERT_OUT:-$HOME/okv-rotate}/$(date '+%Y%m%d-%H%M%S')-${node}"
  report_init "$od"
  [ "$DO_REPORT" = 1 ] && { h1 "OKV endpoint certificate rotation - $node"; para "Read-only. Console rotation is step 2 of the runbook and is not done here."; }
  say "OKV endpoint state on $node"
  okv_check_node
  if [ "$DO_REPORT" = 1 ]; then local r; r="$(report_finish "OKV endpoint certificate rotation - $node" 0)"; say "report: $r"
  else rm -rf "$od"; print_findings; fi
  findings_rc
}

# cmd_wait: the runbook step 3 - run okvutil list -v 4 and re-read okvclient.ora until SSL_WALLET_LOC moves
# cmd_wait: Gen's 22:32 correction - the client refreshes its config about ONCE AN HOUR, not per run, and
# only switches on a refresh that (a) happens after the console rotation and (b) lands on the node that
# generated the certificate. So run okvutil ONCE (hammering it is pointless), then poll okvclient.ora and
# key on UPDATE_TIMESTAMP.
cmd_wait() {
  local f loc host ts i=0 start base_ts base_host okvfail=0
  f="$(okv_ora_file)" || die "no okvclient.ora found (set --ora or OKV_HOME)"
  local cdir; cdir="$(okv_client_dir "$f")"
  if [ -x "$cdir/bin/okvutil" ] && [ "$DRY_RUN" != 1 ]; then
    local orc=0; to 60 "$cdir/bin/okvutil" list -v 4 </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 || orc=$?
    [ "$orc" != 0 ] && { okvfail=1; warn "okvutil list failed (status $orc, see ${LOG_FILE:-the log}) - the switch cannot be verified on this run"; }
  fi
  loc="$(okv_field "$f" SSL_WALLET_LOC)"; host="$(okv_field "$f" OKV_HOSTNAME)"; ts="$(okv_field "$f" UPDATE_TIMESTAMP)"
  base_ts="$ts"; base_host="$host"
  if [ "$okvfail" != 0 ] && ! okv_is_rotated "$loc"; then
    err "okvutil list failed and SSL_WALLET_LOC is still .../ssl - the client cannot refresh its config (wallet password, endpoint enrolment, or TCP 5696), so no switch can happen until that works; fix it, then run wait again"
    return 1
  fi
  say "start: UPDATE_TIMESTAMP=${ts:-?} OKV_HOSTNAME=${host:-?} SSL_WALLET_LOC=${loc:-?}$([ -n "$ROTATED_FROM" ] && [ "$host" = "$ROTATED_FROM" ] && echo '  <- expected switching node')"
  log "polling ${f} every ${WAIT_INTERVAL}s for up to ${WAIT_TIMEOUT}s (the client refreshes roughly hourly)"
  start="$(date +%s)"
  while :; do
    if okv_is_rotated "$loc"; then
      if [ ! -f "$loc/ewallet.p12" ]; then err "SSL_WALLET_LOC is $loc but $loc/ewallet.p12 is missing - the endpoint cannot present a certificate; do not proceed to the next node"; return 1; fi
      if [ "$okvfail" != 0 ]; then err "SSL_WALLET_LOC is already under ssl/, but 'okvutil list' failed on this run - the switch is NOT verified; fix the okvutil failure (wallet password/enrolment/5696) and re-run wait"; return 1; fi
      log "switched: SSL_WALLET_LOC is now $loc (ewallet.p12 present)"; return 0
    fi
    if [ "$ts" != "$base_ts" ]; then
      if [ -n "$host" ] && [ "$host" != "$base_host" ]; then
        err "the config refreshed (UPDATE_TIMESTAMP ${base_ts:-?} -> ${ts:-?}) and now points at OKV_HOSTNAME=${host}, but SSL_WALLET_LOC is still .../ssl - re-rotate this endpoint from ${host}, then run wait again"
      else
        err "the config refreshed (UPDATE_TIMESTAMP ${base_ts:-?} -> ${ts:-?}) but SSL_WALLET_LOC is still .../ssl - re-rotate from the node shown as OKV_HOSTNAME=${host:-?}, or wait for the next hourly refresh"
      fi
      return 2
    fi
    if [ $(( $(date +%s) - start )) -ge "$WAIT_TIMEOUT" ] || { [ "$MAX_RUNS" -gt 0 ] && [ "$i" -ge "$MAX_RUNS" ]; }; then
      if [ "$okvfail" != 0 ]; then err "no switch after $(( $(date +%s) - start ))s and 'okvutil list' failed at the start - check the endpoint wallet password, the endpoint enrolment and TCP 5696"; return 1; fi
      err "no refresh yet after $(( $(date +%s) - start ))s: UPDATE_TIMESTAMP is unchanged (${ts:-?}). The client refreshes about hourly - re-rotate from OKV_HOSTNAME=${host:-?}, or wait; do not re-run okvutil repeatedly"
      return 2
    fi
    sleep "$WAIT_INTERVAL"; i=$((i + 1))
    loc="$(okv_field "$f" SSL_WALLET_LOC)"; host="$(okv_field "$f" OKV_HOSTNAME)"; ts="$(okv_field "$f" UPDATE_TIMESTAMP)"
    say "poll $i: UPDATE_TIMESTAMP=${ts:-?} OKV_HOSTNAME=${host:-?} SSL_WALLET_LOC=${loc:-?}$([ -n "$ROTATED_FROM" ] && [ "$host" = "$ROTATED_FROM" ] && echo '  <- expected switching node')"
  done
}

# verify = check plus the explicit step-4/5 assertions, as an exit code for the change window
cmd_verify() {
  local node="${OKV_NODE:-$(hostname -s)}" od; log "verifying $node"; VERIFY_STRICT=1
  od="$RUN_DIR/report"; report_init "$od"
  okv_check_node
  rm -rf "$od"
  print_findings
  findings_rc
}

main() {
  load_config; refuse_root
  local cmd="${1:-}"; shift || true; parse_opts "$@"
  case "$cmd" in
    report) init_run_dir "$cmd"; DO_REPORT=1;;
    inspect|check|verify|wait|plan|preflight|backup|apply|rollback|run) init_run_dir "$cmd";;
    ""|-h|--help|help) usage; exit 0;;
    *) die "Unknown command: $cmd";;
  esac
  case "$cmd" in
    inspect|check|report) cmd_check;;
    plan) cmd_plan;;
    preflight) cmd_preflight;;
    backup) cmd_backup;;
    apply) cmd_apply;;
    rollback) cmd_rollback;;
    run) cmd_run;;
    wait) cmd_wait;;
    verify) cmd_verify;;
  esac
}
main "$@"
