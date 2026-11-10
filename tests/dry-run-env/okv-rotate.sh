# shellcheck shell=bash disable=SC2034,SC2016   # sourced by tests/dry-run-gate.sh and tests/false-success-gate.sh: ARGS*, FAIL_*, OK* are read there
# okv-rotate: a fake OKV client home. For check/report the ora is NOT switched (SSL_WALLET_LOC ends at /ssl); for
# wait it is seeded switched, so a wait that ignores okvutil's failed read and returns 0 is a false success the gate
# can see. The okvutil stub, on success, does what the real client does on the switching run: repoints
# SSL_WALLET_LOC at ssl/<timestamp>/ and creates that ewallet.p12.
O="$T/env/okv"; mkdir -p "$O/conf" "$O/ssl" "$O/bin" "$T/env/dbhome/bin"
printf 'SERVER=okv1.example:5696,okv2.example:5696\nSSL_WALLET_LOC=%s/ssl\nOKV_HOSTNAME=okv1.example\nUPDATE_TIMESTAMP=2026-10-31 12:00:00\n' "$O" >"$O/conf/okvclient.ora"
printf 'not a real p12\n' >"$O/ssl/ewallet.p12"
# wait is seeded already switched: the switch is what the console does, and the point of the false-success case is
# that a failed okvutil read must not be reported as a clean switch. check/report keep the not-rotated world.
# rollback needs a backup in the run dir; pin --run-dir so the fixture knows where the script looks
if [ "${CMD:-}" = rollback ]; then
  mkdir -p "$T/env/rollback-run"; cp -p "$O/conf/okvclient.ora" "$T/env/rollback-run/okvclient.ora.bak"
fi
if [ "${CMD:-}" = wait ] && [ -z "${CASE:-}" ]; then
  mkdir -p "$O/ssl/19700101000000000000"
  printf 'not a real p12\n' >"$O/ssl/19700101000000000000/ewallet.p12"
  printf 'SERVER=okv1.example:5696,okv2.example:5696\nSSL_WALLET_LOC=%s/ssl/19700101000000000000\nOKV_HOSTNAME=okv1.example\nUPDATE_TIMESTAMP=2026-10-31 12:00:00\n' "$O" >"$O/conf/okvclient.ora"
fi
cat >"$O/bin/okvutil" <<'STUB'
#!/bin/sh
echo "TOOL okvutil $*" >>"$DRY_LOG"
# honour the false-success gate's FAIL_RE, like the gate's own stubs: a failed read must be visible
if [ -n "${FAIL_RE:-}" ] && printf 'okvutil %s | ' "$*" | grep -qiE -- "$FAIL_RE"; then
  echo "FAILED okvutil $*" >>"$DRY_LOG"; echo "okvutil: failed (false-success gate)" >&2; exit 1
fi
# the switching run: repoint SSL_WALLET_LOC and create the new wallet (unless the case wants a repoint with no wallet)
if [ "${OKV_STUB_NO_WALLET:-0}" != 1 ]; then
  mkdir -p "$OKV_HOME/ssl/19700101000000000000"
  printf 'not a real p12\n' >"$OKV_HOME/ssl/19700101000000000000/ewallet.p12"
fi
printf 'SERVER=okv1.example:5696,okv2.example:5696\nSSL_WALLET_LOC=%s/ssl/19700101000000000000\nOKV_HOSTNAME=okv1.example\nUPDATE_TIMESTAMP=2026-10-31 12:00:00\n' "$OKV_HOME" >"$OKV_HOME/conf/okvclient.ora"
printf 'Endpoint\n  SSL_WALLET_LOC: %s/ssl/19700101000000000000\n  OKV_HOSTNAME: okv1.example\n' "$OKV_HOME"
exit 0
STUB
chmod +x "$O/bin/okvutil"
# openssl: the certificate read. A fixed notAfter in 2027 is the post-rotation date; the pre-rotation snapshot is the
# same call, so the script must compare against the snapshot, not a hardcoded year.
cat >"$STUB/openssl" <<'STUB'
#!/bin/sh
echo "TOOL openssl $*" >>"$DRY_LOG"
case "$*" in
  *"-enddate"*) echo "notAfter=Nov  9 14:23:00 2027 GMT";;
  *"-serial"*) echo "serial=01";;
esac
exit 0
STUB
chmod +x "$STUB/openssl"
# cp: the backup/rollback paths are file copies, not tool calls, so the gate sees nothing unless cp is a stub.
# It logs and honours FAIL_RE; otherwise it runs the real cp.
cat >"$STUB/cp" <<'STUB'
#!/bin/sh
echo "TOOL cp $*" >>"$DRY_LOG"
if [ -n "${FAIL_RE:-}" ] && printf 'cp %s | ' "$*" | grep -qiE -- "$FAIL_RE"; then
  echo "FAILED cp $*" >>"$DRY_LOG"; echo "cp: failed (false-success gate)" >&2; exit 1
fi
exec /bin/cp "$@"
STUB
chmod +x "$STUB/cp"
# a database instance for db_instances (ps stub reads $T/ps.txt), and sqlplus via SQL_CMD so the gate's stub answers
printf '1234 ora_pmon_FREE\n' >"$T/ps.txt"
export SQL_CMD="sqlplus -S" SQL_CONNECT="/ as sysdba"
cat >>"$ANSWERS" <<'A'
gv\$encryption_wallet|1|OPEN|OKV
gv\$managed_standby|MRP0|APPLYING_LOG
v\$dataguard_stats|apply lag|0
A
export OKV_HOME="$O" OKV_WALLET_PASSWORD="test-password" OKV_TIMEOUT=1 OKV_INTERVAL=0 OKV_MAX_RUNS=1
ARGS="--okv-home $O"
ARGS_check="--okv-home $O"
ARGS_wait="--okv-home $O --timeout 1 --interval 0 --max-runs 1"
ARGS_verify="--okv-home $O"
ARGS_report="--okv-home $O --report"
ARGS_rollback="--okv-home $O --run-dir $T/env/rollback-run"
# false-success: the okvutil read fails while the ora is already switched, so a wait that ignores the read's rc
# returns 0 and claims a clean switch. OK_wait forbids the success lines; the gate also fails an exit 0 after FAILED.
FAIL_wait='okvutil .*list'
OK_wait='^(rotated=(yes|ok|true)|switched=(yes|ok|true)|verify=ok|all_open=ok)$'
# a repoint with no wallet must be exit 1, not 0 (Ava 13:21:11 item 2). The stub succeeds but skips the wallet.
CASES_backup="backup_cp_fails"
FAIL_backup__backup_cp_fails='cp .*okvclient.ora.bak'
OK_backup__backup_cp_fails='^backup_ora='
# rollback is ADVISORY since 6b2b08f: it prints the manual steps and writes nothing. There is no failure to
# inject and no state line to forbid, so the false-success gate marks it NOT-EXERCISED by design; the
# 'prints the backed-up SSL_WALLET_LOC, exits 0, okvclient.ora byte-identical' assertion belongs in KITT's harness.
CASES_wait="not_switched_okvutil_fails repointed_no_wallet"
# not switched + a failed read: wait must return 1 (investigate, do not go to the next node), never 0 (Mother 13:29:55)
FAIL_wait__not_switched_okvutil_fails='okvutil .*list'
OK_wait__not_switched_okvutil_fails='^(rotated=(yes|ok|true)|switched=(yes|ok|true)|verify=ok|all_open=ok)$'
# a repoint with no wallet must be exit 1, not 0 (Ava 13:21:11 item 2); the stub succeeds but skips the wallet
[ "${CASE:-}" = repointed_no_wallet ] && export OKV_STUB_NO_WALLET=1
FAIL_wait__repointed_no_wallet='^$'
OK_wait__repointed_no_wallet='^(rotated=(yes|ok|true)|switched=(yes|ok|true)|verify=ok|all_open=ok)$'
# apply and run are the two verbs no other gate reaches (T245): tests/okv-rotate.sh drives check/verify/wait/
# backup/rollback, and these two sequences - wait then verify, and check+wait+verify - are only reachable here.
# The property: a failed okvutil read must end the sequence non-zero. apply has no change of its own (the console
# rotation is manual), so the failure is the only thing that can make it claim anything, and a 0 after FAILED is
# exactly the false success this gate exists for.
# apply/run: the world is ALREADY switched with the wallet present, so verify would PASS - that is what makes the
# case bite. With okvutil broken the only honest exit is non-zero; a sequence that swallows the failed read runs
# verify on a healthy world and claims a clean apply, which is the false success T245 is about.
if [ "${CASE:-}" = okvutil_fails ] && { [ "${CMD:-}" = apply ] || [ "${CMD:-}" = run ]; }; then
  mkdir -p "$O/ssl/19700101000000000000"
  printf 'not a real p12\n' >"$O/ssl/19700101000000000000/ewallet.p12"
  printf 'SERVER=okv1.example:5696,okv2.example:5696\nSSL_WALLET_LOC=%s/ssl/19700101000000000000\nOKV_HOSTNAME=okv1.example\nUPDATE_TIMESTAMP=2026-10-31 12:00:00\n' "$O" >"$O/conf/okvclient.ora"
fi
CASES_apply="okvutil_fails"
FAIL_apply__okvutil_fails='okvutil .*list'
OK_apply__okvutil_fails='^(rotated=(yes|ok|true)|switched=(yes|ok|true)|verify=ok|all_open=ok)$'
CASES_run="okvutil_fails"
FAIL_run__okvutil_fails='okvutil .*list'
OK_run__okvutil_fails='^(rotated=(yes|ok|true)|switched=(yes|ok|true)|verify=ok|all_open=ok)$'
