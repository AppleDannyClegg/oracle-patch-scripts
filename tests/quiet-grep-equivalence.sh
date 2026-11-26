#!/bin/bash
# quiet-grep-equivalence.sh - every converted "| grep -q" must give the SAME answer as
# the form it replaced, on four inputs: one matching, one not, empty, and one long
# enough that an early-exiting grep would have killed the writer.
#
# Why per-site and not by eye: a redirect that lands in the wrong place produces VALID
# bash with a WRONG pattern, so bash -n is silent. On the first attempt this happened
# twelve times in this tree, twice inside a quoted grep pattern and the rest on the
# command after the grep (has/recover/warn/local/echo) in an || chain.
#
# Only the PIPELINE is rebuilt from each site: the command from its "|" up to the next
# unquoted separator. The line's prefix is discarded, so a function body cannot eat the
# input that belongs to the grep.
set -u
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
pass=0; fail=0; sites=0; ran=0; skipped=0
check() { if [ "$1" = 1 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $2"; fi }

# print the pipeline starting at the last "|" that precedes a grep, ending at the first
# unquoted & ; ( ) | after it (a "||" after the grep belongs to the caller, not to us)
extract() {
  printf '%s' "$1" | awk '
    BEGIN { q = ""; start = 0; started = 0 }
    {
      s = $0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q != "") { if (c == q) q = ""; continue }
        if (c == "\"" || c == "\047") { q = c; continue }
        if (c == "|") {
          rest = substr(s, i + 1)
          if (rest ~ /^[ \t]*grep[ \t]/) { start = i; started = 1; continue }
          if (started) { print substr(s, start, i - start); exit }
          continue
        }
        if (started && c ~ /[&;()]/) { print substr(s, start, i - start); exit }
      }
      if (started) { print substr(s, start); exit }
    }'
}

cmp_site() {
  local file="$1" ln="$2" pipe="$3" old new
  [[ "$pipe" =~ ^\|[[:space:]]*grep ]] || return 0
  case "$pipe" in *'>/dev/null'*) : ;; *) return 0 ;; esac
  new="$pipe"
  # old: add q to the flag group (or a bare -q if there are no flags), drop the redirect
  old="$(printf '%s' "$new" | sed -E 's#^\|([[:space:]]*)grep([[:space:]]+)(-[A-Za-z]+)?#|\1grep\2\3q#; s# *> */dev/null *$##')"
  # collapse -q carried twice (grep -q-q) which can only come from our own edit
  old="$(printf '%s' "$old" | sed -E 's#-q(q+)#-q#')"
  [ "$old" = "$new" ] && { echo "SKIP  $file:$ln  could not derive: $pipe"; skipped=$((skipped+1)); return 0; }
  local inputs=( "x" "" "no match here" "$(printf 'y\n%.0s' $(seq 1 4000))" )
  local i=0
  for inp in "${inputs[@]}"; do
    i=$((i+1)); local r_old r_new
    ( set -o pipefail; printf '%s' "$inp" | eval "$old" ) >/dev/null 2>&1; r_old=$?
    ( set -o pipefail; printf '%s' "$inp" | eval "$new" ) >/dev/null 2>&1; r_new=$?
    check "$([ "$r_old" = "$r_new" ] && echo 1 || echo 0)" \
      "$file:$ln input#$i rc old=$r_old new=$r_new :: $new"
  done
  ran=$((ran+1))
}

while IFS=: read -r file ln rest; do
  case "$rest" in \#*) continue;; esac
  sites=$((sites+1))
  pipe="$(extract "$rest")"
  [ -n "$pipe" ] && cmp_site "$file" "$ln" "$pipe"
done < <(grep -rn '| grep' "$ROOT/patching" 2>/dev/null | grep '>/dev/null')

check "$([ "$ran" -gt 0 ] && echo 1 || echo 0)" "no site was actually run (ran=$ran)"
check "$([ "$skipped" -lt 10 ] && echo 1 || echo 0)" "$skipped sites skipped as un-derivable"
inside=$(grep -rnE "grep +-[A-Za-z]+ +'[^']* /> */dev/null|grep +-[A-Za-z]+ +\"[^\"]* /> */dev/null" "$ROOT/patching" 2>/dev/null | wc -l | tr -d ' ')
check "$([ "$inside" = 0 ] && echo 1 || echo 0)" "redirect inside a quoted grep pattern: $inside"
stray=$(grep -rnE '(has|recover|warn|local|echo|die|block)[^|;&]*>/dev/null' "$ROOT/patching" 2>/dev/null | grep -c 'grep')
check "$([ "$stray" = 0 ] && echo 1 || echo 0)" "redirect attached past the grep onto another command: $stray"

echo "quiet-grep-equivalence gate: $pass passed, $fail failed, $ran compared of $sites sites, $skipped skipped"
[ "$fail" = 0 ]
