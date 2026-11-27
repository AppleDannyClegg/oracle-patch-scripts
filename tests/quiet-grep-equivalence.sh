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
BIG="$(awk "BEGIN{for(i=0;i<4000;i++)printf \"28575727; row %d for the pipeline\n\",i}")"
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
if [ "${FIXTURE_MODE:-match}" = big ]; then
  for v in out pre app INSTALLED INSTALLED_PATCHES inv lsp up running procs first names done \
           want now PRE_IDS ids lst CONTENT src v2 xml body; do
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
  local b h mode verdict_b verdict_h err=0
  export WORK
  for mode in match nomatch absent big; do
    b="$(run_cmd "$1" "$mode")"; h="$(run_cmd "$2" "$mode")"
    case "$b$h" in
      *SHELL-ERROR*)
        gap "$3 [$mode] shell error, not a verdict: $(printf '%s\n' "$b$h" | grep -oE '[A-Za-z_][A-Za-z0-9_]*: unbound variable|command not found: [A-Za-z_]+|syntax error' | head -1)"
        continue;;
    esac
    if [ "$b" = "$h" ]; then ok "$3 [$mode] same"; continue; fi
    verdict_b="$(printf '%s\n' "$b" | head -1)"; verdict_h="$(printf '%s\n' "$h" | head -1)"
    if [ "$mode" = big ] && [ "$verdict_b" = "rc=141" ]; then
      EXPECTED=$((EXPECTED+1))
      echo "EXPECTED $3 [big] base rc=141 (the grep exited early and the producer took SIGPIPE under pipefail), head ${verdict_h#rc=} - this difference is the fix"
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
unconverted() { # $1 ref
  local ref="$1" f line found=0
  while IFS= read -r f; do
    while IFS= read -r line; do
      local text="${line#*:}"
      case "${text#"${text%%[![:space:]]*}"}" in \#*|"") continue;; esac
      case "$text" in *'<<<'*) continue;; esac
      printf '%s\n' "$text" | grep -qE '\|[[:space:]]*grep[[:space:]]+-[A-Za-z]*q' || continue
      printf '      %s:%s  %s\n' "$f" "${line%%:*}" "$(printf '%s' "$text" | cut -c1-120)"
      found=$((found+1))
    done < <(sed -n '1,100000{=;p}' /dev/null 2>/dev/null; git -C "$REPO" show "$ref:$f" | grep -nE '\|[[:space:]]*grep[[:space:]]+-[A-Za-z]*q')
  done < <(git -C "$REPO" ls-tree -r --name-only "$ref" | grep -E '^patching/.*\.sh$')
  return "$found"
}
base_left=$(unconverted "$BASE_REF" | wc -l | tr -d ' ')
head_left=$(unconverted "$HEAD_REF" | wc -l | tr -d ' ')
echo "== unconverted pipeline grep -q commands (the converted class) =="
echo "   base $BASE_REF: $base_left"
echo "   head $HEAD_REF: $head_left"
if [ "$base_left" = 0 ]; then
  bad "the base has none of this class, so this gate compares nothing - wrong refs?"
elif [ "$head_left" = 0 ]; then
  ok "every pipeline grep -q in the base is converted in the head"
else
  bad "$head_left pipeline grep -q command(s) left in the head - not converted:"
  unconverted "$HEAD_REF"
fi
echo

echo
echo "quiet-grep-equivalence: $PASS passed, $FAIL failed, $GAPS fixture/parse gaps"
echo "  compared $cmds grep commands over $sites changed lines in $(cut -f1 "$WORK/pairs" | sort -u | wc -l | tr -d ' ') files"
echo "  expected differences (the pipefail fix): $EXPECTED"
[ "$FAIL" = 0 ]