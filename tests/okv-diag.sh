#!/usr/bin/env bash
# okv-diag.sh - behavioural + portability gate for reports/okv-diag/okv-diag.sh.
#
# Three ways the OKV client check can lie, none of which tests/oracle-free-container.sh can see (the image runs
# Oracle Linux / GNU sed, and a container is never signalled):
#  - a named port must be probed. BSD sed has no BRE '\+', so 'sed -n ...\([0-9]\+\).*' silently fails there,
#    the port falls through to the 5696 default and a healthy endpoint is reported unreachable (TARS/Jocasta/
#    Vision, 3 Nov). The failure is invisible on GNU sed, so it is guarded statically as well as behaviourally.
#  - a config with no SERVER= must be a CRIT (nothing was probed), never a clean exit 0 (Vision, 3 Nov).
#  - a signal must STOP the run: INT -> 130, TERM -> 143. A handler that runs the cleanup but does not exit
#    swallows the signal and the script finishes as if it had succeeded (Cortex, 3 Nov).
#
# No database, no docker: local temp OKV homes. The server probe is real (a refused/hung TCP connect), so the
# reachability line's port is the script's own, not something the gate substituted.
#
# Usage: tests/okv-diag.sh [repo-root]
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SH="$ROOT/reports/okv-diag/okv-diag.sh"
[ -f "$SH" ] || { echo "okv-diag gate: $SH not found"; exit 2; }
pass=0; fail=0
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ok() { pass=$((pass + 1)); }
no() { fail=$((fail + 1)); echo "FAIL $*"; }

# mkfixture <dir> <SERVER= line>: a minimal OKV home; the okvutil stub fails the way an unenrolled client does.
mkfixture() {
  mkdir -p "$1/conf" "$1/ssl" "$1/bin"
  { printf 'SSL_WALLET_LOC=%s/ssl\n' "$1"; [ -n "$2" ] && printf '%s\n' "$2"; } >"$1/conf/okvclient.ora"
  : >"$1/ssl/ewallet.p12"
  printf '#!/bin/sh\necho "OKV-00001: Cannot connect to the Oracle Key Vault server"\n' >"$1/bin/okvutil"
  chmod +x "$1/bin/okvutil"
}

# 1. an explicit SERVER=host:PORT is probed on PORT (5999), not the 5696 default. Accept OK or UNREACHABLE: the
#    assertion is the port, so the gate needs no listener. Port 1 would be instant-refused on any host.
mkfixture "$T/a" 'SERVER=127.0.0.1:5999'
OKV_OUT="$T/out-a" bash "$SH" --okv-home "$T/a" --no-tar --quiet >/dev/null 2>&1
reach="$(cat "$T"/out-a/*/raw/okv_reach_*.txt 2>/dev/null)"
if printf '%s\n' "$reach" | grep -qE '^  127\.0\.0\.1:5999 (OK|UNREACHABLE)$'; then ok
else no "named port: reachability did not probe 127.0.0.1:5999 (the 5696 default means the port parse failed):"; printf '%s\n' "$reach" | sed 's/^/    /'; fi

# 1b. portability guard: the failure above is invisible on GNU sed, so forbid the construct outright in CODE
#     (comment lines may name it - line 55 does, to explain this gate).
if grep -v '^[[:space:]]*#' "$SH" | grep 'sed' | grep -qF '\+'; then no "portability: a sed BRE '\+' in ${SH#"$ROOT"/} is GNU-only (BSD sed never matches; use sed -nE)"; else ok; fi

# 2. no SERVER= is a CRIT and rc=2, not the WARN-and-return-0 that let an unprobed config look clean.
mkfixture "$T/b" ''
OKV_OUT="$T/out-b" bash "$SH" --okv-home "$T/b" --no-tar --quiet >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ] && grep -q 'has no usable SERVER= line' "$T"/out-b/*/REPORT.md 2>/dev/null; then ok
else no "no-SERVER=: rc=$rc (want 2) and/or no 'has no usable SERVER= line' CRIT in REPORT.md"; fi

# 2b. if --okv-home was given, the no-okvclient.ora message names the path, not a flag already passed.
OKV_OUT="$T/out-b2" bash "$SH" --okv-home "$T/absent" --no-tar --quiet >/dev/null 2>&1
grep -q "no okvclient.ora under --okv-home $T/absent" "$T"/out-b2/*/REPORT.md 2>/dev/null && ok || no "okv-home message does not name $T/absent"

# 2c. the reachability tally is reconciled against the SERVER lines PARSED, not trusted (T384): a line the probe
#     cannot turn into an OK/UNREACHABLE result used to vanish from the count (and, with 0 counted, was reported as
#     "no usable SERVER= line" - the wrong reason for the right verdict). An EMPTY host (`SERVER=:5999`) is declared
#     and then skipped by the probe loop: a server line whose reachability was NOT established.
mkfixture "$T/b3" 'SERVER=:5999'
OKV_OUT="$T/out-b3" bash "$SH" --okv-home "$T/b3" --no-tar --quiet >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ] && grep -q 'reachability line(s) counted against 1 SERVER line(s) parsed' "$T"/out-b3/*/REPORT.md 2>/dev/null; then ok
else no "an unparseable probe line: rc=$rc (want 2), count-vs-parsed CRIT $([ -n "$(grep -o 'reachability line(s) counted[^;]*' "$T"/out-b3/*/REPORT.md 2>/dev/null)" ] && echo present || echo MISSING)"; fi

# 3. TERM stops the run (rc=143) instead of falling through. The okvutil stub sleeps, so the signal lands in a
#    deterministic window rather than racing the probe's 5s timeout.
mkfixture "$T/c" 'SERVER=127.0.0.1:1'
printf '#!/bin/sh\nsleep 10\n' >"$T/c/bin/okvutil"; chmod +x "$T/c/bin/okvutil"
OKV_OUT="$T/out-c" bash "$SH" --okv-home "$T/c" --no-tar --quiet >/dev/null 2>&1 &
pid=$!; sleep 1; kill -TERM "$pid" 2>/dev/null; wait "$pid"; rc=$?
[ "$rc" = 143 ] && ok || no "signal: TERM gave rc=$rc (want 143) - the handler swallowed the signal and the run continued"

# 4. the database side: every keystore line names its instance, and its container when v$containers can be
#    read; a non-CDB / pre-12c home that cannot read v$containers keeps its keystore check; a
#    keystore that is not OPEN is a CRIT only for a keystore type tde_configuration uses - a CLOSED FILE row under
#    KEYSTORE_CONFIGURATION=OKV is not an outage. No database: a sqlplus
#    stub answers each statement the script sends, by what the statement selects.
#    mkdb <dir> <tde_configuration|-> <containers: yes|no> <keystore rows, one per line: status|wrl_type|wallet_type|con>
mkdb() {
  mkdir -p "$1"; printf '%s\n' "$2" >"$1/cfg"; printf '%s\n' "$4" >"$1/rows"
  { echo '#!/bin/sh'; echo "D='$1'"; echo "CON='$3'"
    cat <<'STUB'
q="$(cat)"
case "$q" in
  *"'ok'"*) echo ok ;;
  *"name='tde_configuration'"*"max(value)"*|*"max(value)"*"name='tde_configuration'"*) cat "$D/cfg" ;;
  *'v$containers c, v$encryption_wallet w'*) if [ "$CON" = yes ]; then echo 3; else echo 'ORA-00942: table or view does not exist'; exit 1; fi ;;
  *"'KS|'"*) if [ -f "$D/fail" ]; then echo 'ORA-01031: insufficient privileges'; exit 1; fi
             case "$q" in *'v$containers'*) [ "$CON" = yes ] || { echo 'ORA-00942: table or view does not exist'; exit 1; }
               sed 's/^/KS|/' "$D/rows" ;;
             *) sed 's/^/KS|/; s/|[^|]*$//' "$D/rows" ;; esac ;;
  *) echo "CHECK|INFO|wallet_root = /stub" ;;
esac
STUB
  } >"$1/sqlplus"; chmod +x "$1/sqlplus"
}
# rundb <dir>: one run against the stub; the OKV half gets a fixture that refuses instantly
rundb() {
  mkfixture "$1/okv" 'SERVER=127.0.0.1:1'
  SQL_CMD="$1/sqlplus" OKV_OUT="$1/out" bash "$SH" --sid TDB1 --okv-home "$1/okv" --no-tar --quiet >/dev/null 2>&1
  cat "$1"/out/*/REPORT.md 2>/dev/null
}
# 4a. CDB, OKV-only configuration: a CLOSED FILE row is not a CRIT; every line carries instance AND container
mkdb "$T/d1" 'KEYSTORE_CONFIGURATION=OKV' yes 'OPEN|OKV|HSM|CDB$ROOT
CLOSED|FILE|UNKNOWN|CDB$ROOT
OPEN|OKV|HSM|PDB1'
r="$(rundb "$T/d1")"
n="$(printf '%s\n' "$r" | grep -c 'TDE keystore status')"
nl="$(printf '%s\n' "$r" | grep 'TDE keystore status' | grep -c 'instance TDB1, container ')"
if [ "$n" = 3 ] && [ "$nl" = 3 ] && ! printf '%s\n' "$r" | grep 'TDE keystore status' | grep -q 'CRIT' \
   && printf '%s\n' "$r" | grep -q 'container CDB\$ROOT: TDE keystore status = CLOSED (wrl_type=FILE.*not a keystore type tde_configuration uses'; then ok
else no "CDB/OKV-only: want 3 keystore lines all labelled 'instance TDB1, container ...' and the CLOSED FILE row not CRIT; got $n lines, $nl labelled:"; printf '%s\n' "$r" | grep 'TDE keystore' | sed 's/^/    /'; fi
# 4b. the same CLOSED FILE row IS a CRIT when the configuration uses FILE (OKV|FILE)
mkdb "$T/d2" 'KEYSTORE_CONFIGURATION=OKV|FILE' yes 'OPEN|OKV|HSM|CDB$ROOT
CLOSED|FILE|UNKNOWN|CDB$ROOT'
r="$(rundb "$T/d2")"
printf '%s\n' "$r" | grep -q 'CRIT.*instance TDB1, container CDB\$ROOT: TDE keystore status = CLOSED (wrl_type=FILE' && ok \
  || { no "OKV|FILE: a CLOSED FILE keystore must be a CRIT:"; printf '%s\n' "$r" | grep 'TDE keystore' | sed 's/^/    /'; }
# 4c. no tde_configuration (pre-18c, or the keystore set in sqlnet.ora): nothing says the type is unused, so CRIT stays
mkdb "$T/d3" '-' yes 'CLOSED|FILE|UNKNOWN|CDB$ROOT'
r="$(rundb "$T/d3")"
printf '%s\n' "$r" | grep -q 'CRIT.*container CDB\$ROOT: TDE keystore status = CLOSED' && ok \
  || { no "no tde_configuration: a CLOSED keystore must stay a CRIT:"; printf '%s\n' "$r" | grep 'TDE keystore' | sed 's/^/    /'; }
# 4d. v$containers unreadable (non-CDB on an old release): the keystore is STILL checked, instance-labelled, no container
#     and no 'NOT checked' / 'did not complete' WARN: a join that fails would lose the whole check
mkdb "$T/d4" '-' no 'CLOSED|HSM|HSM|x'
r="$(rundb "$T/d4")"
if printf '%s\n' "$r" | grep -q 'CRIT.*instance TDB1: TDE keystore status = CLOSED (wrl_type=HSM' \
   && ! printf '%s\n' "$r" | grep -qE 'keystore.*NOT checked|did not complete'; then ok
else no "no v\$containers: want an instance-labelled CRIT and no NOT-checked WARN:"; printf '%s\n' "$r" | grep -E 'TDE keystore|NOT checked|did not complete' | sed 's/^/    /'; fi
# 4e. the keystore read itself fails: a WARN naming the instance and saying NOT checked, never silence
mkdb "$T/d5" 'KEYSTORE_CONFIGURATION=OKV' yes 'OPEN|OKV|HSM|CDB$ROOT'; : >"$T/d5/fail"
r="$(rundb "$T/d5")"
printf '%s\n' "$r" | grep -q 'WARN.*instance TDB1: the TDE keystore state was NOT checked.*ORA-01031' && ok \
  || { no "failed keystore read: want a WARN 'instance TDB1: the TDE keystore state was NOT checked ... ORA-01031':"; printf '%s\n' "$r" | grep -E 'keystore|ORA-' | sed 's/^/    /'; }

# 4f. a non-OPEN row with no wrl_type cannot be shown to be an unused type, so it stays a CRIT
mkdb "$T/d6" 'KEYSTORE_CONFIGURATION=OKV' yes 'CLOSED||?|PDB2'
r="$(rundb "$T/d6")"
printf '%s\n' "$r" | grep -q 'CRIT.*container PDB2: TDE keystore status = CLOSED (wrl_type=?' && ok \
  || { no "empty wrl_type: a CLOSED row must stay a CRIT:"; printf '%s\n' "$r" | grep 'TDE keystore' | sed 's/^/    /'; }

# 4g. OPEN_NO_MASTER_KEY is open but has no master key set for that container: a WARN, not a healthy INFO
mkdb "$T/d7" 'KEYSTORE_CONFIGURATION=OKV' yes 'OPEN|OKV|HSM|CDB$ROOT
OPEN_NO_MASTER_KEY|OKV|HSM|PDB3'
r="$(rundb "$T/d7")"
if printf '%s\n' "$r" | grep -q 'WARN.*container PDB3: TDE keystore status = OPEN_NO_MASTER_KEY .*no master key set for this container' \
   && printf '%s\n' "$r" | grep -q 'INFO.*container CDB\$ROOT: TDE keystore status = OPEN (wrl_type=OKV'; then ok
else no "OPEN_NO_MASTER_KEY: want a WARN with the no-master-key note and plain OPEN still INFO:"; printf '%s\n' "$r" | grep 'TDE keystore' | sed 's/^/    /'; fi

echo "okv-diag gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
