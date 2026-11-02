#!/usr/bin/env bash
# Behavioural gate for operations/okv-rotate/okv-rotate.sh (KITT, Ava 13:19:47 split).
#
# Runs the real script against a fake OKV_HOME and a PATH of stubs (okvutil, openssl, ps) plus a
# SQL_CMD sqlplus stub, so the switch test, the wait loop, the verify exit codes and the wallet
# presence/expiry checks are exercised without a database or Key Vault.
#
# The cases that matter (and the bug each would catch):
#   not-rotated       SSL_WALLET_LOC ends at /ssl                 -> check exit 1 (WARN)
#   missing-wallet    SSL_WALLET_LOC repointed, no ewallet.p12    -> check exit 2 (CRIT)
#   rotated-valid     subfolder wallet, cert far in the future    -> check/verify exit 0
#   rotated-expiring  subfolder wallet, cert 10/60 days out       -> CRIT 2 / WARN 1
#   tde-closed        gv$encryption_wallet row not OPEN           -> verify exit 2
#   wait-switch       okvutil moves SSL_WALLET_LOC on run 2       -> wait exit 0, okvutil CALLED
#   wait-timeout      it never moves                              -> wait exit 2, okvutil CALLED
# The wait cases assert the stub ran: the 13:22 P1 was that wait's run_sh 'bash -c' could not see
# the lib's `to`, so okvutil never executed and the timeout blamed the wrong node.
#
# Usage: tests/okv-rotate.sh
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
SCRIPT="${OKV_SCRIPT:-operations/okv-rotate/okv-rotate.sh}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
STUB="$T/stub"; OKV="$T/okv"; mkdir -p "$STUB" "$OKV/conf" "$OKV/bin" "$OKV/ssl" "$T/home"
export PATH="$STUB:$PATH" HOME="$T/home" CERT_OUT="$T/reports" RUN_BASE="$T/runs"
export OKV_HOME="$OKV" OKV_WALLET_PASSWORD="stubpass" SQL_CMD="$STUB/sqlplus"
export OKV OKVUTIL_LOG="$T/okvutil.log" OKV_WAIT_SLEEP=0

pass=0; fail=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# --- stubs ---------------------------------------------------------------------------------------
cat >"$OKV/bin/okvutil" <<'STUB'
#!/bin/sh
{ printf 'okvutil %s\n' "$*"; } >>"$OKVUTIL_LOG"
[ "${OKVUTIL_FAIL:-0}" = 1 ] && { echo "okvutil: stub failure" >&2; exit 1; }
# after OKVUTIL_SWITCH_AFTER successful runs, move SSL_WALLET_LOC under ssl/
n=$(wc -l <"$OKVUTIL_LOG" | tr -d ' ')
if [ -n "${OKVUTIL_SWITCH_AFTER:-}" ] && [ "$n" -ge "$OKVUTIL_SWITCH_AFTER" ]; then
  sed -i.bak "s#^SSL_WALLET_LOC=.*#SSL_WALLET_LOC=$OKV/ssl/19700101000000000000#" "$OKV_ORA"
  [ "${OKVUTIL_NO_WALLET:-0}" = 1 ] || { mkdir -p "$OKV/ssl/19700101000000000000"; : >"$OKV/ssl/19700101000000000000/ewallet.p12"; }
fi
echo "okvutil: stub list"
STUB
chmod +x "$OKV/bin/okvutil"
cat >"$STUB/openssl" <<'STUB'
#!/bin/sh
case "$1" in
  pkcs12) printf '%s\n' '-----BEGIN CERTIFICATE-----' 'stub' '-----END CERTIFICATE-----';;
  x509)
    if printf '%s' "$*" | grep -q -- '-serial'; then echo "serial=ABCDEF01"
    elif printf '%s' "$*" | grep -q -- '-enddate'; then echo "notAfter=${STUB_NOTAFTER:-Dec  1 12:00:00 2027 GMT}"; fi;;
esac
STUB
cat >"$STUB/ps" <<'STUB'
#!/bin/sh
case "$*" in *args*) echo "ora_pmon_FREE";; *) exec /bin/ps "$@";; esac
STUB
cat >"$STUB/sqlplus" <<'STUB'
#!/bin/sh
q="$(cat)"
if [ "${STUB_SQL_FAIL:-0}" = 1 ]; then echo "ORA-01017: invalid username/password; logon denied" >&2; exit 1; fi
if printf '%s' "$q" | grep -q 'v\$database'; then [ -n "${STUB_DB_ROLE:-}" ] && echo "$STUB_DB_ROLE"; fi
if printf '%s' "$q" | grep -q 'gv\$encryption_wallet'; then
  if [ "${STUB_TDE_FAIL:-0}" = 1 ]; then echo "ORA-00942: table or view does not exist" >&2; exit 1; fi
  printf '1|%s|OKV\n' "${STUB_TDE_STATUS:-OPEN}"
fi
if printf '%s' "$q" | grep -q 'gv\$managed_standby'; then [ "${STUB_NO_MRP:-0}" = 1 ] || printf 'MRP0|%s\n' "${STUB_MRP:-APPLYING_LOG}"; fi
if printf '%s' "$q" | grep -q 'v\$dataguard_stats'; then printf 'apply lag|+00 00:00:05\n'; fi
STUB
chmod +x "$STUB"/*

# --- fixtures ------------------------------------------------------------------------------------
write_ora() { # <loc>
  printf 'SSL_WALLET_LOC=%s\nOKV_HOSTNAME=okvnode1\nUPDATE_TIMESTAMP=2026-11-02 13:00:00\nSERVER=okv1:5696\n' "$1" >"$OKV/conf/okvclient.ora"
  export OKV_ORA="$OKV/conf/okvclient.ora"
}
new_wallet() { mkdir -p "$OKV/ssl/19700101000000000000"; : >"$OKV/ssl/19700101000000000000/ewallet.p12"; }

run() { # <args...>; prints stdout+stderr, sets RC
  out="$("$SCRIPT" "$@" 2>&1)"; RC=$?
}

expect_rc() { # <rc> <label>
  if [ "$RC" = "$1" ]; then ok "$2 (rc=$RC)"; else bad "$2 (rc=$RC want $1): $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"; fi
}
expect_out() { # <substr> <label>
  if printf '%s' "$out" | grep -qi -- "$1"; then ok "$2"; else bad "$2 (no '$1'): $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"; fi
}

# --- cases ---------------------------------------------------------------------------------------
write_ora "$OKV/ssl"; : >"$OKV/ssl/ewallet.p12"
run check; expect_rc 1 "check not-rotated is WARN"; expect_out "not rotated" "check names the un-rotated state"

write_ora "$OKV/ssl/19700101000000000000"   # pointed-to wallet deliberately absent
run check; expect_rc 2 "check missing pointed-to wallet is CRIT"; expect_out "does not exist" "check names the missing wallet"

new_wallet; write_ora "$OKV/ssl/19700101000000000000"
run check; expect_rc 0 "check rotated+valid is clean"

STUB_NOTAFTER="Dec  1 12:00:00 2026 GMT" run check; expect_rc 2 "check cert 10 days out is CRIT"
STUB_NOTAFTER="Dec 20 12:00:00 2026 GMT" run check; expect_rc 1 "check cert ~48 days out is WARN"

write_ora "$OKV/ssl"
run verify; expect_rc 2 "verify not-rotated is CRIT (2)"
new_wallet; write_ora "$OKV/ssl/19700101000000000000"
run verify; expect_rc 0 "verify rotated+valid is clean (0)"
STUB_TDE_STATUS=CLOSED run verify; expect_rc 2 "verify a wallet not OPEN is CRIT (2)"

# wait: okvutil runs once and repoints the ora during that call -> switched (Ava 13:31:48 design)
write_ora "$OKV/ssl"; : >"$OKV/ssl/ewallet.p12"; : >"$OKVUTIL_LOG"
export OKVUTIL_SWITCH_AFTER=0
run wait --timeout 5 --interval 0; expect_rc 0 "wait switches after the okvutil refresh (0)"
if [ -s "$OKVUTIL_LOG" ]; then ok "wait actually ran okvutil ($(wc -l <"$OKVUTIL_LOG" | tr -d ' ') calls)"; else bad "wait never ran okvutil (the run_sh/to bug)"; fi

# wait: repointed but the new wallet is missing -> 1, do not proceed
write_ora "$OKV/ssl"; : >"$OKV/ssl/ewallet.p12"; : >"$OKVUTIL_LOG"
rm -f "$OKV/ssl/19700101000000000000/ewallet.p12"
OKVUTIL_NO_WALLET=1 run wait --timeout 5 --interval 0; expect_rc 1 "wait repointed-but-no-wallet is 1 (do not proceed)"
unset OKVUTIL_NO_WALLET

# wait timeout: clean read, no refresh, still on the old wallet -> 2, re-run
write_ora "$OKV/ssl"; : >"$OKV/ssl/ewallet.p12"; : >"$OKVUTIL_LOG"
unset OKVUTIL_SWITCH_AFTER
run wait --timeout 1 --interval 0; expect_rc 2 "wait times out with a clean read (2)"
if [ -s "$OKVUTIL_LOG" ]; then ok "wait ran okvutil before timing out"; else bad "wait never ran okvutil on timeout"; fi

# wait: already switched but okvutil cannot run -> must not be a clean 0 (Unicron 13:27:32)
new_wallet; write_ora "$OKV/ssl/19700101000000000000"; : >"$OKVUTIL_LOG"
OKVUTIL_FAIL=1 run wait --timeout 1 --interval 0
if [ "$RC" != 0 ]; then ok "wait does not call a failed-read switch clean (rc=$RC)"; else bad "wait returned 0 after a failed okvutil read (Unicron 13:27:32)"; fi
unset OKVUTIL_FAIL

# standby with no MRP row -> CRIT (Landru 13:22:29 P2)
new_wallet; write_ora "$OKV/ssl/19700101000000000000"
STUB_DB_ROLE=PHYSICAL_STANDBY STUB_NO_MRP=1 run verify; expect_rc 2 "verify PHYSICAL_STANDBY with no MRP row is CRIT (2)"

# only the TDE read fails -> verify must WARN (1) and say the assertion was not evaluated
# (Mother 13:34:12: a blanket sqlplus failure also trips the standby WARN, so it cannot pin the TDE fix)
STUB_TDE_FAIL=1 run verify
if [ "$RC" = 1 ] && printf '%s' "$out" | grep -q "NOT evaluated"; then ok "verify WARNs when only the TDE read fails (rc=1)"; else bad "TDE-only failure not pinned (rc=$RC): $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; fi
unset STUB_TDE_FAIL

# wait: okvutil fails and the ora is still on the old wallet -> 1 (do not proceed)
write_ora "$OKV/ssl"; : >"$OKV/ssl/ewallet.p12"; : >"$OKVUTIL_LOG"
OKVUTIL_FAIL=1 run wait --timeout 1 --interval 0; expect_rc 1 "wait okvutil-failed and unswitched is 1"
unset OKVUTIL_FAIL

# backup positive path: the snapshot exists and backup_ora is recorded (Unicron 13:35:26)
write_ora "$OKV/ssl"; : >"$OKV/ssl/ewallet.p12"
RUN_BASE="$T/run-bak" run backup
bakdir="$(ls -d "$T"/run-bak/*-backup 2>/dev/null | tail -1)"
if [ -n "$bakdir" ] && [ -f "$bakdir/okvclient.ora.bak" ] && grep -q '^backup_ora=' "$bakdir/state"; then ok "backup snapshots the ora and records backup_ora"; else bad "backup did not snapshot/record (bakdir=$bakdir)"; fi

# rollback is advisory: with a backup present and the live ora moved on to the switched state,
# it must name the backed-up SSL_WALLET_LOC and NOT restore the file (Mother 13:38:01 - a cp mutant must fail this)
write_ora "$OKV/ssl/19700101000000000000"; : >"$OKV/ssl/19700101000000000000/ewallet.p12"
run rollback --run-dir "$bakdir"
if [ "$RC" = 0 ] && printf '%s' "$out" | grep -q "backed-up SSL_WALLET_LOC" && grep -q '^SSL_WALLET_LOC=.*/19700101000000000000' "$OKV/conf/okvclient.ora"; then
  ok "rollback is advisory: prints the backup and leaves the live ora alone"
else
  bad "rollback advisory assertion failed (rc=$RC): $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
fi

printf '\nokv-rotate gate: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
