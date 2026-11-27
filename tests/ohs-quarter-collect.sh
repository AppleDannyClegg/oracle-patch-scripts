#!/usr/bin/env bash
# ohs-quarter-collect gate. The fixture is laid out the way dbclient-upgrade, ohs-patch and java-patch
# actually leave a run folder, and every section is checked for CONTENT: a grep for the word 'listen'
# would match the always-printed header and pass with an empty section.
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
insection()     { awk -v h="== $1" 'index($0,h)==1{f=1;next} /^== /{f=0} f' "$2" | grep -qE "$3"; }
sec_nonempty()  { [ -n "$(awk -v h="== $1" 'index($0,h)==1{f=1;next} /^== /{f=0} f' "$2" | grep -vE '^\s*$|^\(.*\)$')" ]; }

R="$T/runs/20261127-1129-ohs-quarter"
OH="$T/u01/app/oracle/product/12.2.1.4"
INST="$T/u01/app/oracle/user_projects/domains/base_domain/config/fmwconfig/components/OHS/instances/ohs1"
mkdir -p "$R/backup" "$R/dbclient" "$R/java" "$R/opatch" "$R/wallet" "$OH/network/admin" "$INST" "$T/jdk19"

printf 'outcome=rollback-failed\noracle_home=%s\n' "$OH" >"$R/state"
printf 'outcome=refused-backup\noracle_home=%s\n' "$OH" >"$R/opatch/state"
printf 'outcome=refused-backup\noracle_home=%s\n' "$OH" >"$R/dbclient/state"
printf 'JAVA_VERSION="19.0.9"\n'                             >"$T/jdk19/release"
printf 'new_jh=%s\nold_jh=%s\n' "$T/jdk19" "$T/jdk17"        >"$R/java/state"
# the installer's own log lives in the SHARED dir the client apply runs against
printf 'Check:Packages failed\nPrereq failed. Aborting Install\nredhat-lsb redhat-lsb-core libXtst-devel\n' >"$R/backup/run.log"
mkdir -p "${OH}.failed-20261127-112913"      # the set-aside keeps the stamp (dbclient-upgrade.sh:397)
printf 'Listen 7777\n' >"$INST/httpd.conf"
printf 'Listen 7778\n' >"$INST/ssl.conf"
printf 'inventory_loc=%s/oraInventory\n' "$T" >"$OH/oraInst.loc"
printf 'WALLET-CANARY-4f2a\n' >"$R/wallet/cwallet.sso"
ln -s "$T/jdk19" "$OH/jdk" 2>/dev/null || true
printf '=== 7/7 phase: verify\n[ERROR] ohs-patch verify failed on base_domain\n' >"$T/console.log"
before="$(cd "$R" && find . -type f | sort | xargs shasum 2>/dev/null | shasum | cut -d' ' -f1)"

"$Q" collect "$R" "$T/console.log" >"$T/stdout" 2>"$T/stderr"; rc=$?
[ "$rc" = 0 ] || bad "collect exited $rc; stderr: $(head -2 "$T/stderr" | tr '\n' ' ')"
f="$(grep -oE '/[^ ]*\.txt' "$T/stdout" | head -1)"
[ -n "$f" ] && [ -f "$f" ] || bad "no single .txt path printed on stdout"
[ -f "$f" ] || { echo "gate: $pass ok, $fail FAIL (no file)"; exit 1; }

# the usage region: usage() is sed -n '2,/^$/p', so a blank line above an option hides it
h="$("$Q" --help 2>&1)"
printf '%s\n' "$h" | grep -qF 'collect <run-dir>' && ok || bad "--help does not mention collect <run-dir>"
printf '%s\n' "$h" | grep -qF 'Env:' && ok || bad "--help lost the Env: paragraph (usage() stops at the first blank line)"
printf '%s\n' "$h" | grep -qF -- '-h|--help' && ok || bad "--help lost -h|--help"
head -6 "$f" | grep -qiE 'could not|cannot|unreadable' && ok || bad "top of file does not say which sections failed"
insection 'installer prerequisites' "$f" 'Prereq failed'      && ok || bad "P1: the installer's Prereq line is missing (it is in backup/run.log)"
insection 'home and its set-aside'  "$f" '\.failed-20261127-112913' && ok || bad "P1: the .failed-<stamp> set-aside copy is missing"
insection 'listeners'               "$f" '7777'               && ok || bad "P2: the OHS instance Listen 7777 is missing"
insection 'jdk'                     "$f" 'jdk19'              && ok || bad "P2: the JDK from the java run's state (new_jh) is missing"
insection 'quarter log tail'        "$f" 'verify failed'      && ok || bad "the tee'd console log (second argument) is not in the log section"
insection 'os line'                 "$f" "$(uname -s)"        && ok || bad "the OS line is missing"
insection 'run state files'         "$f" 'outcome='           && ok || bad "the run's state files are missing"
for s in 'run state files' 'quarter log tail' 'installer prerequisites' 'os line' 'home and its set-aside' 'inventory pointer' 'jdk' 'process count' 'listeners' 'df'; do
  sec_nonempty "$s" "$f" && ok || bad "section '$s' is empty"
done
grep -q 'WALLET-CANARY-4f2a' "$f" && bad "wallet contents leaked" || ok
after="$(cd "$R" && find . -type f | sort | xargs shasum 2>/dev/null | shasum | cut -d' ' -f1)"
[ "$before" = "$after" ] && ok || bad "the run folder changed"
case "$f" in "$R"/*) bad "the collector wrote INSIDE the run folder";; *) ok;; esac
echo "gate: $pass ok, $fail FAIL"
[ "$fail" = 0 ]
