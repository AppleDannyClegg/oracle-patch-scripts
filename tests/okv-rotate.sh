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
SCRIPT="operations/okv-rotate/okv-rotate.sh"
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
  mkdir -p "$OKV/ssl/19700101000000000000"; : >"$OKV/ssl/19700101000000000000/ewallet.p12"
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
if printf '%s' "$q" | grep -q 'gv\$encryption_wallet'; then
  printf '1|%s|OKV\n' "${STUB_TDE_STATUS:-OPEN}"
fi
if printf '%s' "$q" | grep -q 'gv\$managed_standby'; then printf 'MRP0|%s\n' "${STUB_MRP:-APPLYING_LOG}"; fi
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

# wait: the switch happens on the 2nd okvutil run; assert okvutil was actually called
write_ora "$OKV/ssl"; : >"$OKV/ssl/ewallet.p12"; : >"$OKVUTIL_LOG"
export OKVUTIL_SWITCH_AFTER=1
run wait --max-runs 5 --interval 0; expect_rc 0 "wait switches on run 2 (0)"
if [ -s "$OKVUTIL_LOG" ]; then ok "wait actually ran okvutil ($(wc -l <"$OKVUTIL_LOG" | tr -d ' ') calls)"; else bad "wait never ran okvutil (the run_sh/to bug)"; fi

# wait timeout
write_ora "$OKV/ssl"; : >"$OKV/ssl/ewallet.p12"; : >"$OKVUTIL_LOG"
unset OKVUTIL_SWITCH_AFTER
run wait --max-runs 2 --interval 0; expect_rc 2 "wait times out at the run cap (2)"
if [ -s "$OKVUTIL_LOG" ]; then ok "wait ran okvutil before timing out"; else bad "wait never ran okvutil on timeout"; fi

# wait: already switched but okvutil cannot run -> must not be a clean 0 (Unicron 13:27:32)
new_wallet; write_ora "$OKV/ssl/19700101000000000000"; : >"$OKVUTIL_LOG"
OKVUTIL_FAIL=1 run wait --max-runs 2 --interval 0
if [ "$RC" != 0 ]; then ok "wait does not call a failed-read switch clean (rc=$RC)"; else bad "wait returned 0 after a failed okvutil read (Unicron 13:27:32)"; fi
unset OKVUTIL_FAIL

printf '\nokv-rotate gate: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
