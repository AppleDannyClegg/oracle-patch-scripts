#!/usr/bin/env bash
# ohs-quarter-collect gate. RED FIRST: the command does not exist on the frozen ref.
#
# It pins what ONE collector file must hold after a FAILED run, that it only reads,
# and that it never prints a wallet's contents.
#
# Usage: tests/ohs-quarter-collect.sh [repo-root]
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
Q="$ROOT/patching/ohs-quarter/ohs-quarter.sh"
[ -f "$Q" ] || { echo "ohs-quarter-collect gate: $Q not found"; exit 2; }

T="$(cd "$(mktemp -d /tmp/oqc.XXXXXX)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

# --- a failed run's folder, as one is left on a host ---
R="$T/runs/20261127-1129-ohs-quarter"; mkdir -p "$R/wls" "$R/dbclient" "$R/home/OPatch" "$R/home/network/admin" "$R/wallet"
printf 'outcome=rollback-failed\n'            >"$R/state"
printf 'outcome=refused-backup\noracle_home=%s/home\n' "$R" >"$R/dbclient/state"
printf 'backup_dir=%s/bk\n' "$T"              >"$R/wls/state"
printf 'recovering: wls-patch restore (its own home+domains backup)\nRESTORED: the client home is back and running\n' >"$R/run.log"
printf 'inventory_loc=%s/oraInventory\n' "$T" >"$R/home/oraInst.loc"
printf 'Listen 7777\n'                        >"$R/home/network/admin/httpd.conf"
printf 'WALLET-CANARY-4f2a\n'                 >"$R/wallet/cwallet.sso"
mkdir -p "$T/jdk19" && printf 'JAVA_VERSION="19.0.9"\n' >"$T/jdk19/release" && ln -s "$T/jdk19" "$R/home/jdk" 2>/dev/null || true
OUTDIR="$T/out"; mkdir -p "$OUTDIR"
before="$(cd "$R" && find . -type f | sort | xargs shasum 2>/dev/null | shasum | cut -d' ' -f1)"

# --- the command under test: takes a run folder, writes ONE text file ---
"$Q" collect "$R" >"$T/stdout" 2>"$T/stderr"; rc=$?
[ "$rc" = 0 ] || bad "collect exited $rc (red until implemented); stderr: $(head -2 "$T/stderr" | tr '\n' ' ')"
f="$(grep -oE '/[^ ]*\.txt' "$T/stdout" | head -1)"
[ -n "$f" ] && [ -f "$f" ] || bad "no single .txt path printed on stdout"
[ -f "$f" ] || { echo "gate: $pass ok, $fail FAIL (no file)"; exit 1; }

# --- one file, at the top: which sections could not be read ---
head -6 "$f" | grep -qiE 'could not|cannot|unreadable' || bad "top of file does not say which sections failed"
# --- the sections the spec names ---
for s in 'state' 'log' 'listen' 'jdk' 'inventory' 'df' 'process'; do
  if grep -qi "$s" "$f"; then ok; else bad "section '$s' missing"; fi
done
# --- redaction: a wallet's CONTENTS never appear ---
grep -q 'WALLET-CANARY-4f2a' "$f" && bad "wallet contents leaked into the collector file" || ok
# --- only reads: the run folder is byte-identical, and nothing was added inside it ---
after="$(cd "$R" && find . -type f | sort | xargs shasum 2>/dev/null | shasum | cut -d' ' -f1)"
[ "$before" = "$after" ] && ok || bad "the run folder changed: $before -> $after"
case "$f" in "$R"/*) bad "the collector wrote INSIDE the run folder ($f)";; *) ok;; esac
echo "gate: $pass ok, $fail FAIL"
[ "$fail" = 0 ]
