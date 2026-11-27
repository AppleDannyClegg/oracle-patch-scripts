#!/usr/bin/env bash
# quiet-grep-equivalence.sh - the gate for PR 7's grep conversions.
#
# A conversion rewrites a check from one grep form to another. The claim it has to
# earn is: the check answers the SAME question, and says the same thing, before and
# after. This compares the OLD command taken from the base text with the NEW command
# taken from the head text. Neither side is rebuilt from the other: deriving one form
# from the other by substitution is how a gate reports agreement while comparing a
# command with itself (or two commands that both fail to parse).
#
# Three things are compared per site, per input:
#   exit status  - what the check decides;
#   stdout       - where it sends its messages. A redirect on the wrong command is
#                  valid bash with the same exit status, so rc alone cannot see it;
#   stderr-class - a shell error (unparseable, unbound variable, missing command) is
#                  a GAP, never a pass: two different failures are not agreement.
#
# Four inputs, and the verdict each site must earn on them:
#   match     content the pattern matches        old rc == new rc, stdout equal
#   nomatch   the id asked about is absent, and the name it looks for is a different one
#                                                old rc == new rc, stdout equal
#   absent    the id asked about is ABSENT from a NON-EMPTY list - the input that makes a
#             wrong pattern visible             old rc == new rc, stdout equal
#   big       4000 matching lines, > pipe buffer on the EXPECTED long-stream case
#             the OLD form is allowed to differ and to fail: under pipefail a grep
#             that exits early sends SIGPIPE to the producer, so the old pipeline
#             reports 141 where the new one reports the matched status. That
#             difference IS the fix, and it is reported, not counted as a failure.
#
# It reads: git show <ref>:<file> for both refs, and git diff for the line pairing.
# It runs: the extracted commands only, in a subshell. No repo script is run and no
# host is touched.
#
# Usage: tests/quiet-grep-equivalence.sh [--base REF] [--head REF] [--verbose]
#        tests/quiet-grep-equivalence.sh --self-test
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
BASE_REF="origin/main"; HEAD_REF="HEAD"; VERBOSE=0; SELF_TEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE_REF="$2"; shift 2;;
    --head) HEAD_REF="$2"; shift 2;;
    --verbose) VERBOSE=1; shift;;
    --self-test) SELF_TEST=1; shift;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0; GAPS=0; EXPECTED=0; RAN=0
ok()  { PASS=$((PASS+1)); [ "$VERBOSE" = 1 ] && echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL  $1"; }
gap() { GAPS=$((GAPS+1)); echo "GAP   $1"; }

# ------------------------------------------------------------------ extraction
# Every sub-command on a line that contains a grep, one per line of output. The
# WHOLE sub-command, producer included: a producer carries the input (that is how
# `printf ... | grep` and `grep <<<"$var"` differ), so slicing at the pipe would
# hand one side the other side's input and manufacture a difference. A line can
# hold two of them; the unit is the command, not the line.
cmd_segments() { # stdin: one line of shell
  awk '
    BEGIN { q = "" }
    {
      s = $0; seg = ""; depth = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q != "") { seg = seg c; if (c == q) q = ""; continue }
        if (c == "\"" || c == "\047") { q = c; seg = seg c; continue }
        if (c == ";" || (c == "&" && substr(s, i+1, 1) == "&") || (c == "|" && substr(s, i+1, 1) == "|") || c == "{" || c == "}") {
          if (seg ~ /grep[ \t]/) print trim(seg)
          seg = ""
          if ((c == "&" || c == "|") && substr(s, i+1, 1) == c) i++
          continue
        }
        seg = seg c
      }
      if (seg ~ /grep[ \t]/) print trim(seg)
    }
    function trim(t) {
      sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
      sub(/^if[ \t]+/, "", t); sub(/^elif[ \t]+/, "", t); sub(/^then[ \t]+/, "", t)
      sub(/^![ \t]+/, "", t); sub(/[ \t]+then$/, "", t); sub(/[ \t]+fi$/, "", t)
      sub(/\\$/, "", t)
      return t
    }'
}

# The line pairs, from the diff: file, base line number, head line number. Within a
# hunk the '-' lines come first and the '+' lines that replace them follow, in order,
# so they are zipped positionally. The TEXT of each line then comes from its own ref,
# so neither form is ever rebuilt from the other.
pairs() {
  git -C "$REPO" diff -U0 "$BASE_REF" "$HEAD_REF" -- patching/ |
  awk '
    /^diff --git/ { f = $0; sub(/^diff --git a\//,"",f); sub(/ b\/.*/,"",f); np=0; next }
    /^@@/ {
      s = $0; sub(/^@@ -/,"",s); sub(/ \+/," ",s); sub(/ @@.*/,"",s)
      split(s, a, " "); sub(/,.*/,"",a[1]); sub(/,.*/,"",a[2])
      bn = a[1] + 0; hn = a[2] + 0; next
    }
    /^---/ || /^\+\+\+/ { next }
    /^-/ { bn_arr[np] = bn; txt_arr[np] = substr($0,2); np++; bn++; next }
    /^\+/ { if (np > 0) { gsub(/\t/," ",txt_arr[0]); print f "\t" bn_arr[0] "\t" hn; for (i=1;i<np;i++) { txt_arr[i-1]=txt_arr[i]; bn_arr[i-1]=bn_arr[i] } np--; } hn++; next }
  '
}

# -------------------------------------------------------------------- fixtures
# The same fixture values for both sides. The content the patterns look for lives
# in the stdin payload AND in the variables, so a pattern reading either is tested.
FIXTURE_MODE="match"
MAKE='
# WHAT MOVES BETWEEN MODES IS THE INPUT EACH CHECK READS. A wrong pattern and the right one
# can only disagree on an input that does not hold what the check looks for, and it must not
# be EMPTY: a match-anything pattern finds nothing in an empty list either, so an empty input
# hides the mutant. `absent` feeds a NON-EMPTY inventory holding a different patch, which is
# the input that makes a wrong pattern visible. Without it a mutant at wls-patch.sh:1165
# (`grep "^$id;"` -> `grep ".*"`) was reported "same" on all three inputs, because the input
# held the very id the check asks about; tests/quiet-grep-mutant-controls.sh is the control
# that measures this, and it reports 0 of 4 mutants caught before this fixture existed.
CHK=28575727
case "${FIXTURE_MODE:-match}" in
  nomatch) HIT=99999999; OTHER="OtherServer"; DOMAIN="/u01/domains/other"; NAMES="Apache Tomcat"; HOST="example.invalid";;
  absent)  HIT=$CHK;     OTHER="Server1";     DOMAIN="/u01/domains/base";  NAMES="Oracle HTTP Server"; HOST="example.invalid";;
  *)       HIT=$CHK;     OTHER="Server1";     DOMAIN="/u01/domains/base";  NAMES="Oracle HTTP Server"; HOST="updates.oracle.com";;
esac
IDS="11111111;22222222;"
case "${FIXTURE_MODE:-match}" in match|big) IDS="28575727;28737975;";; esac
# JUST OVER ONE PIPE BUFFER, and not one line more. The 141 race is decided by whether the
# writer needs more than one write, not by how much more: at 4000 lines this string is
# exported multi-megabyte and every FORK in this shell fails E2BIG, so the base and the
# head both returned 126 and the big comparison agreed on a failure to run - the
# expected-difference count was 0 on the honest head, which is the tell. 1200 lines of 60
# bytes is ~74 KB: over the 64 KB pipe buffer, far under any argument limit.
BIG="$(awk "BEGIN{for(i=0;i<1200;i++)printf \"28575727; row %d xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n\",i}")"
case "${FIXTURE_MODE:-match}" in
  nomatch) CONTENT="nothing that matches";;
  big)     CONTENT="$BIG";;
  *)       CONTENT="28575727;";;
esac
INPUT="$1"
# A CONTROLLED HOME. The netrc check at wls-patch.sh:1367 reads $HOME/.netrc; leaving HOME
# alone makes both sides read the same operator file file, so the comparison is between two
# reads of one input nobody set and cannot fail.
HOME="$WORK/home"; mkdir -p "$HOME"; printf "machine %s login u password p\n" "$HOST" > "$HOME/.netrc"
id=28575727 PID=28575727 short="12.2.1.4" ADMIN_SERVER_NAME="AdminServer"
out="$(printf "%s\n" "Prereq \"checkConflictAgainstOHWithDetail\" for patch $HIT passed" "Prereq \"checkApplicable\" for patch $HIT passed" "Patch $HIT supersedes subset 12345678" "ORA-01017" "ERROR: nope")"
pre="$out" app="$out" title="DB19C patch"
INSTALLED="$IDS" INSTALLED_PATCHES="$IDS" inv="$IDS"
lsp="$(printf "%s\n" "OHS (NATIVE) DB19C BUNDLE PATCH 19.0.0.0.0" "$IDS")"
now=" $HIT " PRE_IDS=" $HIT 28737975 " want=" AdminServer $OTHER "
DOMAINS="$DOMAIN" d="$DOMAIN" running="$OTHER 1234 (weblogic.Server)"
up="$OTHER 1234" procs="1234 weblogic.Server" names="$NAMES"
lst="/tmp/fmw_12.2.1.19.0_dbclient_linux64.bin /tmp/changePerm.sh"
fp="$(awk "BEGIN{for(i=0;i<64;i++)printf \"A\"}")" present="$fp"
v="file:/wallet" vr="chain: OK" xml="<html>portal</html>" mentioned="12.2.1.4"
X_CN=localhost X_ICN=localhost X_ISS=OracleOHS X_SIG=sha1WithRSA X_SAN="localhost,127.0.0.1"
NEW_CN=localhost NEW_SAN=localhost CHECK_HOST=localhost CN=localhost SAN="localhost,127.0.0.1"
LIVE_PORTS=" tcp:8080 " done=" $OTHER " s="127.0.0.1" tailtxt="password: x"
need="oracle.rdbms.rsf:19.0" rsf="19.3.0.0.0" ids=" $HIT " OPATCH_KIT_BUG=6880880
first="$HIT - DB19C bundle" LOG_FILE="$WORK/log.txt" LOG="$WORK/log.txt"
kit_zip="$WORK/kit.zip" arg="$WORK/arg" pdir="$WORK/pdir" raw="$WORK/raw.html" name="x.part"
ORACLE_HOME="$WORK/oh" OH="$WORK/oh" TARBALL="$WORK/x.tar.gz" JAVA_HOME="$WORK/jdk"
OOP="" off=0 ver="12.2.1.4" APEX_VER="22.1.0" spb_path="$WORK/spb" x="config.url=x"
stmt="select 1 from dual" rp="rp1" proc="1234" n="$OTHER" MOS_USER="" T_HOME="$WORK/oh"
export BIG INPUT id PID short ADMIN_SERVER_NAME out pre app title INSTALLED INSTALLED_PATCHES
export inv lsp now PRE_IDS want DOMAINS d running up procs names lst fp present v vr xml
export mentioned X_CN X_ICN X_ISS X_SIG X_SAN NEW_CN NEW_SAN CHECK_HOST CN SAN LIVE_PORTS
export done s tailtxt need rsf ids OPATCH_KIT_BUG first LOG_FILE LOG kit_zip arg pdir raw
export name ORACLE_HOME OH TARBALL JAVA_HOME OOP off ver APEX_VER spb_path x stmt rp proc n
export MOS_USER T_HOME
# names the sites read that the first pass left unbound: a gap is an unrun site, so
# each one added here is a site that can now be compared (or honestly fail).
c=28575727; pout="$out"; dout="$out"; l="$OTHER"; last="$OTHER 1234"; re="OracleOHS"
shaped="AdminServer"; w="AdminServer"; wls="$WORK/wls"; path="$WORK/oh"; port=7001
target="$WORK/chain.pem"; body="<html>portal</html>"; CERT="$WORK/chain.pem"; T_FILE="$WORK/t.jks"
f="$WORK/chain.pem"; CHAIN="$WORK/chain.pem"; h="$OTHER"
export c pout dout l last re shaped w wls path port target body CERT T_FILE f CHAIN h
export HOME HIT OTHER IDS HOST
# big mode: every variable a producer might write becomes larger than one stdio
# write, so an early-exiting grep can lose the race and SIGPIPE its writer (the
# class this PR exists for). Appended after the content, so the first line still
# MATCHES and the check still takes its matching branch.
# UNEXPORT EACH ONE AS IT GROWS. The append alone is not enough: a variable that is
# exported stays exported, so growing twenty of them puts ~1.7 MB into the environment of
# every child and each FORK inside a site fails E2BIG. grep is a child, so the pipeline the
# gate is testing cannot run at all: base and head both returned 126, both "same", and the
# expected-difference count on the honest head was 0 - a comparison that agreed on a
# failure to run. export -n drops the export and keeps the value in this shell, which is
# where the producer and the pattern both read it.
if [ "${FIXTURE_MODE:-match}" = big ]; then
  for v in out pre app INSTALLED INSTALLED_PATCHES inv lsp up running procs first names done \
           want now PRE_IDS ids lst CONTENT src v2 xml body; do
    export -n "$v" 2>/dev/null || true
    eval "$v=\"\${$v:-\${CONTENT:-}}
$BIG\""
  done
fi
'
STUBS='
log(){ printf "[log] %s\n" "$*"; }; warn(){ printf "[warn] %s\n" "$*"; }
err(){ printf "[err] %s\n" "$*"; }; dbg(){ printf "[dbg] %s\n" "$*"; }
has(){ printf "[has] %s\n" "$*"; }; die(){ printf "[die] %s\n" "$*"; exit 3; }
recover(){ printf "[recover] %s\n" "$*"; }; block(){ printf "[block] %s\n" "$*"; }
add_wallet(){ printf "[add_wallet] %s\n" "$*"; }; add_live(){ printf "[add_live] %s\n" "$*"; }
patch_desc(){ printf "desc\n"; }; patch_description(){ printf "desc\n"; }
prepare_patch_dir(){ printf "28575727|x|patch\n"; }; state_get(){ :; }; state_set(){ :; }
run_sh(){ printf "[run_sh] %s\n" "$*"; }; x509_facts(){ :; }; kt(){ :; }; ks_pass(){ printf x; }
sql_val(){ printf "%s" "$v"; }; chain_cas(){ printf "%s\n" "$WORK/chain.pem"; }
wls_homes(){ printf "%s\n" "$WORK/wls"; }; wls_domains(){ printf "%s" "$DOMAINS"; }
wls_java_home(){ printf "%s" "$JAVA_HOME"; }; cacerts_pw_file(){ printf "%s" "$WORK/pw"; }
systemctl(){ printf "%s\n" "ords.service loaded active running"; }
'
mkdir -p "$WORK/oh" "$WORK/jdk" "$WORK/arg/extracted" "$WORK/pdir"
printf '%s\n' 'jdk: applied ' 'wlspsu: applied ' 'dbclient-upgrade preflight OK' 'ohs-patch preflight OK' > "$WORK/log.txt"
printf 'PK\003\004not-a-real-zip' > "$WORK/kit.zip"
printf '%s\n' '-----BEGIN CERTIFICATE-----' 'MIIB' '-----END CERTIFICATE-----' > "$WORK/chain.pem"
printf '%s\n' 'not-a-real-keystore' > "$WORK/t.jks"; mkdir -p "$WORK/wls"; printf '%s\n' '</results>' > "$WORK/raw.html"
printf '%s\n' '<html>' > "$WORK/pdir/x.part"; : > "$WORK/x.tar.gz"

# A segment cut at a ; or { can be half a block (an `if ...; then` with no fi, a body
# with no closing brace). Completing it is worth doing: the site then runs and its
# verdict is real, which matters because an unbalanced fragment would otherwise be
# reported as a parse gap and the site left uncompared. The first completion that
# parses wins; if none does, the segment is compared as-is and reported as a gap.
complete() { # $1 segment -> a runnable command on stdout
  local seg="$1" pre suf
  for pre in "" "true; "; do
    for suf in "" "; :" "; then :; fi" "; do :; done" " ; }" "; fi" "; done" \
               "; then :; fi; }" " ; } ; fi" " ; } ; done" " :; fi" " :; done"; do
      if bash -n <<<"$pre$seg$suf" 2>/dev/null; then printf '%s' "$pre$seg$suf"; return 0; fi
    done
  done
  printf '%s' "$seg"; return 1
}

# -------------------------------------------------------------------- one site
# Runs one command with the input on stdin, inside the shape the script uses:
# pipefail on, helpers stubbed. Prints: "rc=<n>" then stdout. A shell error is
# reported as a GAP by the caller, not compared.
run_cmd() { # $1 command (as written in the file), $2 mode
  ( set -uo pipefail; FIXTURE_MODE="$2"; export FIXTURE_MODE WORK; eval "$MAKE"; eval "$STUBS"
    eval "$1" ) > "$WORK/o" 2> "$WORK/e"
  local rc=$?
  if grep -qE 'unbound variable|command not found:|syntax error' "$WORK/e"; then
    printf 'SHELL-ERROR %s\n' "$(grep -oE '[A-Za-z_][A-Za-z0-9_]*: unbound variable|command not found: [A-Za-z_]+|syntax error' "$WORK/e" | head -1)"
    return 0
  fi
  printf 'rc=%s\n' "$rc"
  sed 's/[[:space:]]*$//' "$WORK/o" | head -20
}

compare() { # $1 base cmd, $2 head cmd, $3 label
  local b h mode verdict_b verdict_h err=0 h_match=""
  export WORK
  for mode in match nomatch absent big; do
    b="$(run_cmd "$1" "$mode")"; h="$(run_cmd "$2" "$mode")"
    case "$b$h" in
      *SHELL-ERROR*)
        gap "$3 [$mode] shell error, not a verdict: $(printf '%s\n' "$b$h" | grep -oE '[A-Za-z_][A-Za-z0-9_]*: unbound variable|command not found: [A-Za-z_]+|syntax error' | head -1)"
        continue;;
    esac
    # A HEAD THAT STILL TAKES THE EARLY EXIT IS NOT A CONVERSION, and equal verdicts cannot
    # show it: base and head can agree on 141 because the new form kills the writer too. The
    # equality branch below would call that "same", which is how a converted-looking site
    # passes a gate that exists to prove the 141 is gone.
    if [ "$mode" = big ] && [ "$(printf '%s\n' "$h" | head -1)" = "rc=141" ]; then
      err=1
      bad "$3 [big] the head still takes the early exit (rc=141): the new form kills the writer too, so this site is not fixed"
      printf '      base: %s\n      head: %s\n' "${1:0:150}" "${2:0:150}"
      continue
    fi
    if [ "$b" = "$h" ]; then ok "$3 [$mode] same"; [ "$mode" = match ] && h_match="$(printf '%s\n' "$h" | head -1)"; continue; fi
    verdict_b="$(printf '%s\n' "$b" | head -1)"; verdict_h="$(printf '%s\n' "$h" | head -1)"
    if [ "$mode" = big ] && [ "$verdict_b" = "rc=141" ]; then
      # A 141 on the base is the difference the conversion exists to remove, so it is
      # reported, not failed - BUT ONLY IF THE HEAD DECIDED WHAT IT DECIDES ON MATCHING
      # INPUT. Excusing any head verdict accepts the case where the new form takes the
      # same early exit and 141s too, and then "the fix" is credited with
      # a failure it did not fix. The head verdict on matching input is the expected one.
      if [ -n "$h_match" ] && [ "$verdict_h" = "$h_match" ]; then
        EXPECTED=$((EXPECTED+1))
        echo "EXPECTED $3 [big] base rc=141 (the grep exited early and the producer took SIGPIPE under pipefail), head ${verdict_h#rc=} matches the head verdict on matching input (${h_match#rc=}) - this difference is the fix"
        continue
      fi
      err=1
      bad "$3 [big] base rc=141 and head $verdict_h does not match the head verdict on matching input (${h_match:-no match-mode run}) - a 141 that was not removed"
      printf '      base: %s\n      head: %s\n' "${1:0:150}" "${2:0:150}"
      continue
    fi
    err=1
    bad "$3 [$mode] base $verdict_b / head $verdict_h"
    printf '      base: %s\n      head: %s\n' "${1:0:150}" "${2:0:150}"
    printf '      base stdout: %s\n' "$(printf '%s\n' "$b" | tail -n +2 | head -3 | tr '\n' '|')"
    printf '      head stdout: %s\n' "$(printf '%s\n' "$h" | tail -n +2 | head -3 | tr '\n' '|')"
  done
  [ "$err" = 0 ] && RAN=$((RAN+1))
}

# ------------------------------------------------------------------- self-test
# The gate must be able to fail. These four cases exercise the three ways it can:
# a real regression (rc changes), a silent one (stdout changes, rc does not), and
# the one difference it is supposed to allow (the long-stream SIGPIPE fix).
self_test() {
  local fails=0
  st() { # $1 want (same|differ), $2 base, $3 head, $4 what
    local before_f=$FAIL before_p=$PASS
    compare "$2" "$3" "self-test: $4"
    local got; [ "$FAIL" -gt "$before_f" ] && got=differ || got=same
    if [ "$got" = "$1" ]; then echo "  ok   self-test: $4 -> $got (want $1)"
    else echo "  FAIL self-test: $4 -> $got (want $1)"; fails=$((fails+1)); fi
    FAIL=$before_f; PASS=$before_p
  }
  st same   'printf "%s\n" "$INSTALLED" | grep -q "^28575727;"' \
            'printf "%s\n" "$INSTALLED" | grep "^28575727;" >/dev/null' \
            "an honest conversion"
  st differ 'printf "%s\n" "$INSTALLED" | grep -q "^28575727;"' \
            'printf "%s\n" "$INSTALLED" | grep - "^28575727;" >/dev/null' \
            "a bare dash (the pattern becomes -, the real pattern becomes a filename)"
  st differ 'printf "%s\n" "$INSTALLED" | grep -q "^99999999;" || warn "not installed"' \
            'printf "%s\n" "$INSTALLED" | grep - "^99999999;" >/dev/null || warn "not installed" >/dev/null' \
            "a redirect on the wrong command (rc equal, the warning gone)"
  st same   'printf "%s\n" "$INSTALLED" | grep -q "^28575727;"' \
            'printf "%s\n" "$INSTALLED" | grep "^28575727;" >/dev/null' \
            "the long-input fix: base 141, head matches its own verdict on matching input"
  # EQUAL VERDICTS ARE NOT ENOUGH: this head takes the same early exit as the base, so both
  # sides 141 in big mode and the old equality branch said "same". It has to fail.
  st differ 'printf "%s\n" "$INSTALLED" | grep -q "^28575727;"' \
            'printf "%s\n" "$INSTALLED" | grep -m1 "^28575727;" >/dev/null' \
            "both sides take the early exit: equal verdicts, and the head still 141s"
  # The 141 excuse needs the head verdict to be the one it gives on matching input. This
  # head maps a 141 to exit 9 and reproduces the base's own 0 and 1 otherwise, so big mode
  # is the ONLY mode it can differ in - where the old rule excused it and this rule must not.
  st differ 'printf "%s\n" "$INSTALLED" | grep -q "^28575727;"' \
            'printf "%s\n" "$INSTALLED" | grep -m1 "^28575727;" >/dev/null; rc=$?; [ "$rc" = 141 ] && exit 9; [ "$rc" = 1 ] && exit 1; exit 0' \
            "a head that never reached its matching verdict: the 141 is not excused"
  [ "$fails" = 0 ] && { echo "self-test: the gate fails on a regression and passes an honest conversion"; return 0; }
  echo "self-test: the gate cannot fail - do not trust its verdicts"; return 1
}

if [ "$SELF_TEST" = 1 ]; then
  self_test
  exit $?
fi

# ------------------------------------------------------------------- the sites
pairs > "$WORK/pairs"
sites=0; cmds=0
while IFS=$'\t' read -r file bl hl; do
  [ -n "$file" ] || continue
  old_text="$(git -C "$REPO" show "$BASE_REF:$file" | sed -n "${bl}p")"
  new_text="$(git -C "$REPO" show "$HEAD_REF:$file" | sed -n "${hl}p")"
  case "$old_text$new_text" in *grep*) ;; *) continue;; esac
  sites=$((sites+1))
  o=(); while IFS= read -r p; do [ -n "$p" ] && o+=("$p"); done < <(printf '%s' "$old_text" | cmd_segments)
  n=(); while IFS= read -r p; do [ -n "$p" ] && n+=("$p"); done < <(printf '%s' "$new_text" | cmd_segments)
  if [ "${#o[@]}" -ne "${#n[@]}" ]; then
    bad "$file:$bl->$hl grep commands changed in number: base ${#o[@]}, head ${#n[@]} - a pipeline on the line was missed"
    printf '      base: %s\n      head: %s\n' "${old_text:0:150}" "${new_text:0:150}"
    continue
  fi
  i=0
  while [ "$i" -lt "${#o[@]}" ]; do
    cmds=$((cmds+1))
    compare "${o[$i]}" "${n[$i]}" "$file:$bl->$hl#$((i+1))"
    i=$((i+1))
  done
done < "$WORK/pairs"

# ------------------------------------------------- completeness (by command)
# Equivalence cannot see a site that was never converted: the command is identical
# on both sides, so it compares equal to itself. This is the other half of the
# claim, and it is counted in grep COMMANDS, not lines - a line can hold two (the
# pid_alive pair below held two, and a line-based count missed the second).
#
# The class is a grep -q that reads a PIPE: its producer can be killed by SIGPIPE
# when grep exits early, which under pipefail is a status no caller expects. A
# here-string (grep -q <<<"$x") has no such producer and is not in the class, and a
# comment is not code.
#
# THE UNIT IS THE COMMAND, AND THREE CASES CHANGED TO MAKE IT ONE. An earlier
# version exempted the whole LINE on seeing `<<<`, which is wrong twice over: a
# pipeline sharing its line with a here-string command is still in the class (a
# successor holding one was accepted - a verdict fault, not a miscount), and a
# here-string pattern that is QUOTED, as in `grep -q '<<<'`, is text and not an
# exemption at all. So the exempt unit is the command, quoting is respected when
# looking for a bar, a bar is a pipeline only when it is single (`||` is an OR, and
# the bar inside a pattern is text), and the RHS has to be the same grep shapes the
# extraction half looks for. Every count below is an OCCURRENCE count.
#
# Not handled, exactly as before: a pipeline continued onto the next line with a
# backslash, and `|&` (the bar is followed by &, not by grep).
pipeline_greps_left() { # stdin: one line of shell -> stdout: how many of the class
  awk '
    # A shell-quoting walk, because the bar is live in some quoted places and dead
    # in others: `|` inside "..." is text, but `$( )` and backticks inside "..."
    # ARE commands, and the pipeline in "$(printf ... | grep -q ...)" is real
    # (patching/db-patch/db-patch.sh:255 on the pre-conversion tree is exactly that
    # shape - it is in the class and the old line-based count caught it, so a rule
    # that skips all quoted text would lose it). Not parsed: case patterns and
    # here-documents.
    {
      s = $0; n = 0
      top = 0; ctx[0] = ""; par[0] = 0
      i = 1; L = length(s)
      while (i <= L) {
        c = substr(s, i, 1); k = ctx[top]
        if (k == "s") {                             # single quotes: all text
          if (c == "\047") top--
          i++; continue
        }
        if (k == "d") {                             # double quotes: text, with three exceptions
          if (c == "\\") { i += 2; continue }
          if (c == "\"") { top--; i++; continue }
          if (c == "$" && substr(s, i+1, 1) == "(") { top++; ctx[top] = "p"; par[top] = 1; i += 2; continue }
          if (c == "`") { top++; ctx[top] = "b"; i++; continue }
          i++; continue
        }
        if (c == "\047") { top++; ctx[top] = "s"; i++; continue }
        if (c == "\"") { top++; ctx[top] = "d"; i++; continue }
        if (c == "\\") { i += 2; continue }
        if (c == "`") { if (k == "b") { top-- } else { top++; ctx[top] = "b" }; i++; continue }
        if (c == "$" && substr(s, i+1, 1) == "(") { top++; ctx[top] = "p"; par[top] = 1; i += 2; continue }
        if (k == "p" && c == "(") { par[top]++; i++; continue }
        if (k == "p" && c == ")") { par[top]--; if (par[top] == 0) top--; i++; continue }
        if (c == "|") {
          if (substr(s, i+1, 1) == "|") { i += 2; continue }   # the OR, not a pipe
          rhs = substr(s, i+1); sub(/^[ \t]+/, "", rhs)
          if (rhs ~ /^grep[ \t]+-[A-Za-z]*q/) n++
          i++; continue
        }
        i++
      }
      print n
    }'
}
leftover_lines() { # $1 ref -> one line per LINE holding any: "<count>TAB<file>:<line>TAB<text>"
  local ref="$1" f line text c
  while IFS= read -r f; do
    while IFS= read -r line; do
      text="${line#*:}"
      case "${text#"${text%%[![:space:]]*}"}" in \#*|"") continue;; esac
      c="$(printf '%s\n' "$text" | pipeline_greps_left)"
      [ "${c:-0}" -gt 0 ] || continue
      printf '%s\t%s:%s\t%s\n' "$c" "$f" "${line%%:*}" "$(printf '%s' "$text" | cut -c1-120)"
    done < <(git -C "$REPO" show "$ref:$f" | grep -nE '\|[[:space:]]*grep[[:space:]]+-[A-Za-z]*q')
  done < <(git -C "$REPO" ls-tree -r --name-only "$ref" | grep -E '^patching/.*\.sh$')
}
unconverted() { # $1 ref - the offending lines, for a human
  local c rest
  while IFS=$'\t' read -r c rest; do
    if [ "$c" -gt 1 ]; then
      printf '      %s   (%s pipeline grep -q on this one line)\n' "$rest" "$c"
    else
      printf '      %s\n' "$rest"
    fi
  done < <(leftover_lines "$1")
}
unconverted_count() { # $1 ref - how many pipeline grep -q COMMANDS are left
  local c rest total=0
  while IFS=$'\t' read -r c rest; do
    total=$((total + c))
  done < <(leftover_lines "$1")
  printf '%s\n' "$total"
}
base_left=$(unconverted_count "$BASE_REF")
head_left=$(unconverted_count "$HEAD_REF")
echo "== unconverted pipeline grep -q commands (the converted class) =="
echo "   base $BASE_REF: $base_left"
echo "   head $HEAD_REF: $head_left"
if [ "$base_left" = 0 ]; then
  # THE BASE HOLDS NONE OF THE CONVERTED CLASS. Two states look like this, and neither is a
  # reason to fail a tree, so the deciding question is about the HEAD, which is the half this
  # gate can still assert without a differential:
  #   - the refs are the same tree: the after-merge state, which is how run-all invokes this
  #     file - with no arguments the base is the merge ref and the head is the checkout;
  #   - the refs differ by an ordinary successor commit that touches nothing of this class,
  #     which is every commit made after this branch merges.
  # In both, the invariant the conversion exists to keep is that the head has no pipeline
  # grep -q left. That can fail, so it is a check and not a formality. A wrong base shows up
  # as a missing comparison, and the mutant controls are what measure whether the comparison
  # works, so a run with nothing to compare says exactly that instead of deciding red.
  if [ "$head_left" != 0 ]; then
    bad "$head_left pipeline grep -q command(s) left in the head - not converted:"
    unconverted "$HEAD_REF"
  elif git -C "$REPO" diff --quiet "$BASE_REF" "$HEAD_REF" 2>/dev/null; then
    ok "$BASE_REF and $HEAD_REF are the same tree (the conversion is already there): nothing to compare, and $head_left pipeline grep -q left in the head"
  else
    ok "$BASE_REF holds none of the converted class and the head has none left: nothing to compare here, and the static half of this gate - 0 pipeline grep -q left in the head - is what ran"
  fi
elif [ "$head_left" = 0 ]; then
  ok "every pipeline grep -q in the base is converted in the head"
else
  bad "$head_left pipeline grep -q command(s) left in the head - not converted:"
  unconverted "$HEAD_REF"
fi
echo

echo
echo "quiet-grep-equivalence: $PASS passed, $FAIL failed, $GAPS fixture/parse gaps"
echo "  uncovered: $GAPS gate(s) not compared for a shell error, plus ${head_left:-?} pipeline grep -q left in the head - each one is printed above, and none of them is a pass"
if [ "${cmds:-0}" = 0 ]; then
  echo "  compared 0 grep commands: $BASE_REF and $HEAD_REF have no differing lines of this class"
else
  echo "  compared $cmds grep commands over $sites changed lines in $(cut -f1 "$WORK/pairs" | sort -u | wc -l | tr -d ' ') files"
fi
echo "  expected differences (the pipefail fix): $EXPECTED"
[ "$FAIL" = 0 ]