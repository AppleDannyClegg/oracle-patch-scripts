#!/usr/bin/env bash
# ohs-quarter-explain gate. Every log it reads is made by the REAL ohs-quarter.sh, run against stub children that fail
# on request, so the logs cannot drift from what the script prints. It pins:
#   - each way ohs-quarter stops gives its path (A, B, C1, C3, D, E1, E2, E3) and that path's first next command
#   - a later recovery failure decides the path, not the failure that started it (apply + restore FAIL gives E2, not D)
#   - the two "the restore failed" lines print the installer's or ohs-patch's retry, by the "recovering:" line before
#   - the run dir's real paths are filled in; with no log, or no stop message in it, it exits 2 and guesses nothing
#   - every die/err/fail_after/restart_after_stop message in ohs-quarter.sh has a row, so a new one fails here
#
# Usage: tests/ohs-quarter-explain.sh [repo-root]

set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
Q="$ROOT/patching/ohs-quarter/ohs-quarter.sh"
X="$ROOT/patching/ohs-quarter/ohs-quarter-explain.sh"
[ -f "$Q" ] && [ -f "$X" ] || { echo "ohs-quarter-explain gate: $Q or $X not found"; exit 2; }

T="$(cd "$(mktemp -d /tmp/oqx.XXXXXX)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

# a stub child: a FAIL_<WHO>_<VERB> or FAIL_<VERB> names the call that fails. FAIL_STOP_2 fails only the second stop
# (recovery's), FAIL_START_ALL every start (FAIL_START only the first). A backup writes the state keys the real one does.
sed "s|__T__|$T|g" >"$T/stub" <<'STUB'
#!/bin/sh
who="$(basename "$0")"; who="${who#stub-}"; verb="$1"
rd=""; prev=""; for a in "$@"; do [ "$prev" = "--run-dir" ] && rd="$a"; prev="$a"; done
W="$(echo "$who" | tr a-z A-Z)"; V="$(echo "$verb" | tr a-z A-Z)"
eval "f1=\${FAIL_${W}_${V}:-}; f2=\${FAIL_${V}:-}"
# SIGNAL_AT='<who> <verb>' sends TERM to ohs-quarter (this stub's parent) from inside that call, as a Ctrl-C would
[ -n "${SIGNAL_AT:-}" ] && [ "$who $verb" = "$SIGNAL_AT" ] && kill -TERM "$PPID"
case "$verb" in
  stop)  n=$(cat "__T__/stops" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >"__T__/stops"
         [ -n "${FAIL_STOP_2:-}" ] && [ "$n" = 2 ] && { echo "$(date '+%F %T') [ERROR] stub: stop timed out" >&2; exit 1; };;
  start) [ -n "${FAIL_START_ALL:-}" ] && exit 1
         [ -n "${FAIL_START:-}" ] && [ ! -e "__T__/start.failed" ] && { : >"__T__/start.failed"; exit 1; };;
  backup) [ -n "$rd" ] && mkdir -p "$rd" && case "$who" in
            wls) echo "backup_dir=/backups/wls-20261112" >>"$rd/state";;
            dbclient|ohs) printf 'oracle_home=/u01/app/ohs\nbackup=ok\nbackup_dir=/backups/dbclient-20261112\n' >>"$rd/state";;
          esac;;
esac
if [ -n "$f1$f2" ]; then echo "$(date '+%F %T') [ERROR] stub $who: $verb failed (injected)" >&2; exit 1; fi
exit 0
STUB
for w in java wls dbclient ohs; do cp "$T/stub" "$T/stub-$w"; chmod +x "$T/stub-$w"; done
export OHS_QUARTER_JAVA_PATCH="$T/stub-java" OHS_QUARTER_WLS_PATCH="$T/stub-wls"
export OHS_QUARTER_DBCLIENT="$T/stub-dbclient" OHS_QUARTER_OHS_PATCH="$T/stub-ohs"

# a root with every set; NODC=1 leaves dbclient/ out (with --skip), so the shared restore is ohs-patch's
mkdir -p "$T/root/jdk"; : >"$T/root/jdk/jdk-8u511-linux-x64.tar.gz"
for s in wlspsu dbclient dbclientru webgate oss ohs fmwbp jdbc libovd fmwthirdparty perl libdms2 libiau cloningspu rda; do
  mkdir -p "$T/root/$s"; : >"$T/root/$s/p.zip"; done
cp -R "$T/root" "$T/rootnodc"; rm -rf "$T/rootnodc/dbclient"

# run <name> [env...]: the real ohs-quarter, its console log to $T/<name>.log; then explain it to $T/<name>.out
run() {
  local name="$1"; shift
  local root="$T/root" skip=()
  [ "${NODC:-}" = 1 ] && { root="$T/rootnodc"; skip=(--skip dbclient); }
  rm -rf "$T/run"; rm -f "$T/stops" "$T/start.failed"
  env "$@" bash "$Q" --patch-root "$root" --run-dir "$T/run" --yes "${skip[@]}" >"$T/$name.log" 2>&1; echo $? >"$T/$name.rc"
  local rd=(); [ -d "$T/run" ] && rd=("$T/run")   # an operator gives the run dir only when the run made one
  bash "$X" "$T/$name.log" "${rd[@]}" >"$T/$name.out" 2>&1; echo $? >"$T/$name.xrc"
  bash "$X" --terse "$T/$name.log" "${rd[@]}" >"$T/$name.terse" 2>&1; echo $? >"$T/$name.trc"
}
# want <name> <ohs-quarter rc> <path> <text the next steps must hold>
want() {
  local name="$1" qrc="$2" p="$3" text="$4"
  [ "$(cat "$T/$name.rc")" = "$qrc" ] || { bad "$name: ohs-quarter exited $(cat "$T/$name.rc"), not $qrc (the fixture is not that path): $(tail -2 "$T/$name.log")"; return; }
  [ "$(cat "$T/$name.xrc")" = 0 ] && head -1 "$T/$name.out" | grep -q "^PATH $p:" && ok || bad "$name: want PATH $p, got: $(head -1 "$T/$name.out")"
  grep -qF -- "$text" "$T/$name.out" && ok || bad "$name: no '$text' in: $(cat "$T/$name.out")"
}

run prefl   FAIL_OHS_PREFLIGHT=1;            want prefl 1 A  'rerun with --dry-run first'
run backup  FAIL_BACKUP=1;                   want backup 1 B 'are not reused'
run stopup  FAIL_STOP=1;                     want stopup 1 C1 "verify --oracle-home /u01/app/ohs"
run stopdn  FAIL_STOP=1 FAIL_START_ALL=1;    want stopdn 3 C3 "start --oracle-home /u01/app/ohs --run-dir $T/run/opatch"
run recov   FAIL_JAVA_APPLY=1;               want recov 1 D  "keep $T/run and its backups"
run e1      FAIL_OHS_APPLY=1 FAIL_STOP_2=1;  want e1 3 E1   'stop everything from the home'
# E1 after an opatch apply failed: the restore it lists is the installer's (dbclient/ is in this root), and the WLS and
# JDK restores, since both applied before it
grep -qF "dbclient-upgrade.sh rollback --oracle-home /u01/app/ohs --run-dir $T/run/backup" "$T/e1.out" && ok || bad "e1: no installer restore with the shared run dir: $(cat "$T/e1.out")"
grep -qF "wls-patch.sh restore /backups/wls-20261112" "$T/e1.out" && grep -qF 'java-patch.sh rollback' "$T/e1.out" && ok || bad "e1: the WLS or JDK restore is missing: $(cat "$T/e1.out")"
# the cause is the first ERROR (the child's), not ohs-quarter's later lines
grep -q '^CAUSE: .*stub ohs: apply failed' "$T/e1.out" && ok || bad "e1: CAUSE is not the child's apply ERROR: $(grep CAUSE "$T/e1.out")"
# apply FAIL + restore FAIL: the recovery line decides (E2), not the apply that started it (D)
run e2dc    FAIL_OHS_APPLY=1 FAIL_ROLLBACK=1; want e2dc 3 E2 'dbclient-upgrade.sh rollback'
NODC=1 run e2oh FAIL_OHS_APPLY=1 FAIL_ROLLBACK=1; want e2oh 3 E2 "ohs-patch.sh rollback --oracle-home /u01/app/ohs --run-dir $T/run/backup"
grep -q 'dbclient-upgrade' "$T/e2oh.out" && bad "e2oh: printed the installer's restore on a run with no dbclient/" || ok
run e2wls   FAIL_OHS_APPLY=1 FAIL_WLS_RESTORE=1; want e2wls 3 E2 "wls-patch.sh restore /backups/wls-20261112 --oracle-home /u01/app/ohs --run-dir $T/run/wls"
run e3      FAIL_OHS_VERIFY=1 FAIL_START_ALL=1; want e3 3 E3 'nodemanager.out'
# a JDK apply that failed first: only the JDK is restored (nothing else was attempted)
run e2java  FAIL_JAVA_APPLY=1 FAIL_ROLLBACK=1; want e2java 3 E2 'java-patch.sh rollback'
grep -qE 'wls-patch.sh restore|dbclient-upgrade.sh rollback' "$T/e2java.out" && bad "e2java: listed a restore for a set never attempted: $(cat "$T/e2java.out")" || ok

# a Ctrl-C during an opatch apply: that apply logs nothing (it logs only once it succeeds), so the set in flight is
# known only from recover's own "recovering:" lines. With a restore failing it must still print the home restore
# (it once printed only "start"); with recover's stop failing, it must say the set is not logged.
# no dbclient/ here, so the interrupted opatch apply is the FIRST shared set and no "applied" line names it
NODC=1 run inte2 SIGNAL_AT='ohs apply' FAIL_ROLLBACK=1; want inte2 3 E2 "ohs-patch.sh rollback --oracle-home /u01/app/ohs --run-dir $T/run/backup"
# inte1 interrupts the FIRST shared set (no dbclient/), so only the preflight fallback can list its restore (with a
# set applied first, that fallback was never needed). It is listed as CHECK FIRST, not as a restore
# to run blind: the JDK and WLS applied, so those two are plain restores.
NODC=1 run inte1 SIGNAL_AT='ohs apply' FAIL_STOP_2=1; want inte1 3 E1 'is not in the log'
grep -qF "CHECK FIRST, home + inventory" "$T/inte1.out" && grep -qF "ohs-patch.sh rollback --oracle-home /u01/app/ohs" "$T/inte1.out" && ok || bad "inte1: the interrupted opatch set is not listed as CHECK FIRST + its restore: $(cat "$T/inte1.out")"
grep -qE 'CHECK FIRST, (WLS|JDK)' "$T/inte1.out" && bad "inte1: an applied set was marked CHECK FIRST: $(cat "$T/inte1.out")" || ok
run intd  SIGNAL_AT='ohs apply';                  want intd 1 D 'check every component answers'
# a Ctrl-C inside the JDK apply (the first set of all), recovery's stop failing: the JDK is CHECK FIRST, and no other
# set is a plain restore, since none applied
run intj  SIGNAL_AT='java apply' FAIL_STOP_2=1;   want intj 3 E1 'is not in the log'
grep -qF "CHECK FIRST, JDK" "$T/intj.out" && grep -qF 'java-patch.sh rollback' "$T/intj.out" && ok || bad "intj: the interrupted JDK set is not CHECK FIRST + its rollback: $(cat "$T/intj.out")"
# inside the WLS apply: WLS is CHECK FIRST, and the JDK, which applied, is a plain restore
run intw  SIGNAL_AT='wls apply' FAIL_STOP_2=1;    want intw 3 E1 'is not in the log'
grep -qF "CHECK FIRST, WLS" "$T/intw.out" && ok || bad "intw: the interrupted WLS set is not CHECK FIRST: $(cat "$T/intw.out")"
grep -qF "CHECK FIRST, JDK" "$T/intw.out" && bad "intw: the applied JDK was marked CHECK FIRST: $(cat "$T/intw.out")" || ok

# the rollback distance line: restores counted from the 1s, check-firsts from the 2s. Sets apply in a fixed order, so
# only the set in flight is a check-first; the ones after it never started (intj: not WLS, not the shared home)
dist() { grep -qxF "TO GET BACK TO THE PRE-RUN HOME: $2" "$T/$1.out" && ok || bad "$1: want distance '$2', got: $(grep 'PRE-RUN' "$T/$1.out")"; }
dist intj   '0 restore(s), plus up to 1 more to check first (JDK), then start.'
dist intw   '1 restore(s) (JDK), plus up to 1 more to check first (WLS), then start.'
dist inte1  '2 restore(s) (WLS, JDK), plus up to 1 more to check first (home + inventory), then start.'
dist e2java '1 restore(s) (JDK), then start.'
# recover goes on past a failed restore, so only the ones that failed are left to do: e2wls's home and JDK restores worked
dist e2wls  '1 restore(s) (WLS), then start.'
grep -E '^  [0-9]+\. ' "$T/e2wls.out" | grep -qE 'dbclient-upgrade|ohs-patch.sh rollback|java-patch' && bad "e2wls: a restore that worked is in the steps: $(cat "$T/e2wls.out")" || ok
for n in prefl backup stopup recov intd; do grep -qxF 'TO GET BACK TO THE PRE-RUN HOME: nothing to restore.' "$T/$n.out" && ok || bad "$n: want nothing to restore, got: $(grep 'PRE-RUN' "$T/$n.out")"; done
grep -qxF 'TO GET BACK TO THE PRE-RUN HOME: nothing to restore; start what is down.' "$T/stopdn.out" && ok || bad "stopdn: $(grep 'PRE-RUN' "$T/stopdn.out")"
grep -qxF 'TO GET BACK TO THE PRE-RUN HOME: nothing to restore; start it.' "$T/e3.out" && ok || bad "e3: $(grep 'PRE-RUN' "$T/e3.out")"

# --terse is the same steps and nothing else: on every fixture its output is exactly the full output's numbered lines
nt=0
for f in "$T"/*.terse; do
  name="$(basename "$f" .terse)"; nt=$((nt + 1))
  [ "$(cat "$T/$name.trc")" = 0 ] && [ -s "$f" ] && grep -E '^  [0-9]+\. ' "$T/$name.out" | cmp -s - "$f" && ok \
    || bad "$name: --terse (rc $(cat "$T/$name.trc")) is not the full output's steps: $(cat "$f")"
done
nl="$(find "$T" -maxdepth 1 -name '*.log' -newer "$T/root" | wc -l | tr -d ' ')"
[ "$nt" -gt 0 ] && [ "$nt" = "$nl" ] && ok || bad "--terse ran on $nt fixtures, but $nl ran"

# every command a step prints names a real script, a verb that script has a case arm for, and options it parses: so a
# renamed verb or option in a child shows here, not at 02:00. Static: the child is asked for --help, never run for real.
PR="$ROOT/patching"; : >"$T/cmds"
grep -hE '^  [0-9]+\. ' "$T"/*.out | while IFS= read -r line; do
  rest="$line"
  while [[ "$rest" == *"$PR/"* ]]; do
    rest="${rest#*"$PR/"}"; script="${rest%%.sh*}.sh"; seg="${rest#*.sh}"; seg="${seg%%, *}"; seg="${seg%%. *}"; seg="${seg%% (*}"
    read -r verb _ <<<"$seg"
    printf '%s|%s|%s\n' "$script" "$verb" "$(grep -oE -- '--[a-z][a-z-]*' <<<"$seg" | tr '\n' ' ')" >>"$T/cmds"
  done
done
sort -u "$T/cmds" -o "$T/cmds"
nc="$(wc -l <"$T/cmds" | tr -d ' ')"; [ "$nc" -gt 0 ] && ok || bad "no printed commands were found to check"
while IFS='|' read -r script verb opts; do
  f="$PR/$script"
  [[ "$script" =~ ^[a-z-]+/[a-z-]+\.sh$ ]] && [ -x "$f" ] || { bad "printed command names $script, which is not an executable script"; continue; }
  bash "$f" --help >/dev/null 2>&1 && ok || bad "$script --help does not answer rc 0"
  # the verb must be an arm of the script's own command dispatch (its case "$cmd" block), not any "x)" in the file
  awk '/case "\$cmd" in/ { f = 1 } f { print } f && /^[[:space:]]*esac/ { exit }' "$f" | grep -qE "(^|[[:space:];|])$verb(\||\))" \
    && ok || bad "printed '$script $verb', but $script's command dispatch has no '$verb' arm"
  # each option must be an arm of the script's option parser: the case "$1" block that holds --help, not a usage
  # table or another case elsewhere in the file. The block ends at ITS esac: case/esac are counted, so a case nested
  # inside the parser does not cut it short
  parser="$(awk 'function flush() { if (b ~ /--help/) printf "%s", b; b = "" }
    !f && /case "\$1" in/ { f = 1; d = 0 }
    f { b = b $0 "\n"; t = $0; d += gsub(/(^|[^[:alnum:]_])case[[:space:]][^;]*[[:space:]]in([[:space:]]|$)/, "", t)
        t = $0; d -= gsub(/(^|[^[:alnum:]_])esac([^[:alnum:]_]|$)/, "", t); if (d <= 0) { f = 0; flush() } }' "$f")"
  [ -n "$parser" ] && ok || bad "$script: no option parser (a case \"\$1\" block with --help) was found"
  for o in $opts; do grep -qE -- "(^|[[:space:];|])$o(\)|\|)" <<<"$parser" && ok || bad "printed '$script $verb ... $o', but $script's option parser has no $o arm"; done
done <"$T/cmds"
# coverage from the run: every script + verb the explain source can print was printed by some fixture, so it was checked
want_s="$(grep -oE '\$P/[a-z-]+/[a-z-]+\.sh [a-z-]+' "$X" | sed 's#^\$P/##; s/ /|/' | sort -u)"
got_s="$(cut -d'|' -f1,2 "$T/cmds" | sort -u)"
[ -n "$want_s" ] && [ "$want_s" = "$got_s" ] && ok || bad "commands explain can print: $(echo $want_s); checked: $(echo $got_s)"
# --terse anywhere on the line is the flag, never the run dir; a run dir that is not a directory is refused, not used
bash "$X" --terse "$T/stopdn.log" >"$T/tfirst.out" 2>&1; bash "$X" "$T/stopdn.log" --terse >"$T/tlast.out" 2>&1; r=$?
[ "$r" = 0 ] && grep -q '^  1\. ' "$T/tlast.out" && cmp -s "$T/tlast.out" "$T/tfirst.out" && ok || bad "--terse given last (rc $r) is not the terse output: $(cat "$T/tlast.out")"
bash "$X" "$T/stopdn.log" "$T/no-such-run" >"$T/nord.out" 2>&1; r=$?
[ "$r" = 2 ] && ! grep -q '^PATH' "$T/nord.out" && grep -qF 'no-such-run' "$T/nord.out" && ok || bad "a run dir that is not a directory (rc $r) was not refused: $(cat "$T/nord.out")"

# no log, an empty one, or one with no stop message: exit 2, the tee line, no PATH
bash "$X" "$T/nothere.log" >"$T/nolog.out" 2>&1; [ $? = 2 ] && grep -q 'tee' "$T/nolog.out" && ! grep -q '^PATH' "$T/nolog.out" && ok || bad "missing log: $(cat "$T/nolog.out")"
echo "some other program's output" >"$T/other.log"
bash "$X" "$T/other.log" >"$T/other.out" 2>&1; [ $? = 2 ] && ! grep -q '^PATH' "$T/other.out" && ok || bad "a log with no stop message was explained: $(cat "$T/other.out")"
# no run dir (an A path stops before it is made): placeholders, never another run's paths
bash "$X" "$T/prefl.log" >"$T/nord.out" 2>&1; [ $? = 0 ] && grep -q '^RUN_DIR: <RUN_DIR>' "$T/nord.out" && ok || bad "no run dir: $(cat "$T/nord.out")"

# every stop message in ohs-quarter.sh has a row: one fixed run of each literal (the text between its $ expansions)
# must hold one of the keys.
# restart_after_stop's "$1 - nothing was patched; ..." pins an interpolated message (its fixed part is after the $1).
bash "$X" --keys >"$T/keys"
grep -oE '(die|err|fail_after|restart_after_stop) "[^"]*' "$Q" | sed -E 's/^[a-z_]+ "//' | while IFS= read -r lit; do
  frags="$(printf '%s\n' "$lit" | sed -E 's/\$\{[^}]*\}|\$\([^)]*\)?|\$[A-Za-z_0-9*@#?]+/\n/g' | sed -E 's/^[ :.,-]+|[ :.,-]+$//g' | grep .)"
  [ -n "$frags" ] || continue
  hit=0; while IFS= read -r k; do case "$frags" in *"$k"*) hit=1; break;; esac; done <"$T/keys"
  [ "$hit" = 1 ] && echo ok || echo "FAIL no explain row for ohs-quarter message: $lit"
done >"$T/cover"
c="$(wc -l <"$T/cover" | tr -d ' ')"; [ "$c" -ge 40 ] && ok || bad "coverage read only $c messages from $Q (expected 40+): the extraction is broken"
grep '^FAIL' "$T/cover" | while IFS= read -r l; do echo "$l"; done
cf="$(grep -c '^FAIL' "$T/cover")"; [ "$cf" = 0 ] && ok || fail=$((fail + cf))
grep -q 'nothing was patched; the components are started again' "$T/cover" && bad "the interpolated C1 message is not covered" || ok

echo "ohs-quarter-explain gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
