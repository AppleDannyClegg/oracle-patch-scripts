#!/usr/bin/env bash
# get-download-guard.sh - behavioural gate for get.sh's "never delete downloaded patches" guard.
#
# get-patches.ps1 defaults its output to ./patches-<host>, i.e. INSIDE the scripts tree. get.sh replaces
# that tree on every run: it moves the old copy to <dest>.old and, on the next run, deletes it. Before the
# guard that was an unconditional 'rm -rf', so a per-run loop quietly deleted multi-GB MOS downloads.
#
# Runs the real get.sh three times against a local archive (a curl shim; no network) with a patch zip
# seeded inside the tree, and checks that the old copy is kept aside, not removed. A control without a
# seeded file must still delete <dest>.old, so the guard cannot quietly stop replacing the tree.
#
# Usage: tests/get-download-guard.sh [repo-root]
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="$ROOT/get.sh"
[ -f "$SCRIPT" ] || { echo "get-download guard: $SCRIPT not found"; exit 2; }

T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

# a payload shaped like GitHub's archive: one top dir holding lib/oracle-lib.sh and the file patterns
mkdir -p "$T/payload/oracle-patch-scripts-deadbeef/lib"
printf '#!/bin/sh\nexit 0\n' >"$T/payload/oracle-patch-scripts-deadbeef/lib/oracle-lib.sh"
cp "$ROOT/lib/file-patterns" "$T/payload/oracle-patch-scripts-deadbeef/lib/file-patterns"
tar -czf "$T/payload.tar.gz" -C "$T/payload" .

# curl shim: the commits API answers with one sha; every other URL is the archive
mkdir -p "$T/bin"
cat >"$T/bin/curl" <<EOF
#!/bin/sh
case "\$*" in
  *api.github.com*) echo '{"sha":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}'; exit 0 ;;
  *) cat "$T/payload.tar.gz"; exit 0 ;;
esac
EOF
chmod +x "$T/bin/curl"

run_get() { ( cd "$T" && PATH="$T/bin:$PATH" bash "$SCRIPT" "$1" ) >"$T/run-$2.log" 2>&1; echo $?; }

# ---- seeded: a patch zip inside the tree must survive the second update --------------------------------
run_get dest1 1 >/dev/null
mkdir -p "$T/dest1/patching/get-patches/patches-host1/wls"
printf 'zip' >"$T/dest1/patching/get-patches/patches-host1/wls/p39000002.zip"
run_get dest1 2 >/dev/null
run_get dest1 3 >/dev/null
grep -q 'kept the previous copy as' "$T/run-3.log" && ok || bad "run 3 did not keep the old copy aside: $(tail -2 "$T/run-3.log")"
survivors="$(find "$T"/dest1.old-* -name 'p39000002.zip' 2>/dev/null | wc -l | tr -d ' ')"
[ "$survivors" = 1 ] && ok || bad "the downloaded zip did not survive (found $survivors)"
[ -d "$T/dest1/lib" ] && ok || bad "the new tree was not installed"

# ---- control: with nothing to lose, <dest>.old is still removed ---------------------------------------
run_get dest2 4 >/dev/null
run_get dest2 5 >/dev/null
run_get dest2 6 >/dev/null
grep -q 'kept the previous copy as' "$T/run-6.log" && bad "kept an old copy that held no downloads" || ok
asides="$(find "$T" -maxdepth 1 -name 'dest2.old-*' | wc -l | tr -d ' ')"
[ "$asides" = 0 ] && ok || bad "a clean old copy was set aside $asides time(s) - the guard fires without downloads"

# ---- get.ps1's keep scan: a lint, not an integration (it needs a cmdlet mock or a network to run for real) --
if command -v pwsh >/dev/null 2>&1; then
  mkdir -p "$T/psold/patching/patches-host1/wls"
  printf 'zip' >"$T/psold/patching/patches-host1/wls/p1.zip"
  cat >"$T/keep-lint.ps1" <<'PS'
$src = Get-Content -Raw -LiteralPath $env:GETPS
if ($src -notmatch 'Get-ChildItem -LiteralPath "\$Dest\.old" -Recurse') { 'NO-RECURSE'; exit }
$keep = @(Get-ChildItem -LiteralPath $env:PSOLD -Recurse -Force | Where-Object { $_.Name -like 'patches-*' -or $_.Name -like '*.zip' -or $_.Name -like '*.tar.gz' -or $_.Name -like '*.tgz' })
if ($keep.Count -ge 1) { 'OK' } else { 'NO-MATCH' }
PS
  ps_out="$(GETPS="$ROOT/get.ps1" PSOLD="$T/psold" pwsh -NoProfile -File "$T/keep-lint.ps1" 2>/dev/null)"
  [ "$ps_out" = OK ] && ok || bad "get.ps1 keep scan: expected -Recurse and a nested match, got [$ps_out]"
else
  echo "skip: pwsh not installed - get.ps1 keep-scan lint not run (the bash guard above is still gated)"
fi

echo "get-download guard: $pass passed, $fail failed"
[ "$fail" = 0 ]
