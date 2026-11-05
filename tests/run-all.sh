#!/bin/bash
# run-all.sh [gate ...] : run the offline gates in parallel and print each one's last line, its time and its exit code.
# No gates named = every gate below. The docker gates (oracle-free-container, okv-diag) are not here: run those alone.
# Every gate here works in its own mktemp dir, so they can run side by side. Exit 1 if any gate printed FAIL,
# reported "N failed" with N > 0, or exited non-zero.
cd "$(dirname "$0")/.." || exit 1
GATES=(wls-quarter java-patch-will-stop wls-patch-spb dry-run-gate false-success-gate self-contained-gate
  secret-argv-gate java-patch-cacerts java-patch-inplace java-patch db-patch-opatch-min db-patch-ru-title
  get-download-guard check-parse optchk-gate unreadable-gate patch-manifest patch-status-oracle-home
  patch-status-unknown-level ru-date oem-standby-lag okv-rotate obic-diag)
[ $# -gt 0 ] && GATES=("$@")
out="$(mktemp -d)"; trap 'rm -rf "$out"' EXIT
start=$SECONDS
for g in "${GATES[@]}"; do
  ( s=$SECONDS; bash "tests/$g.sh" </dev/null >"$out/$g.log" 2>&1; echo "$? $((SECONDS - s))" >"$out/$g.rc" ) &
done
if command -v pwsh >/dev/null; then
  ( s=$SECONDS; pwsh -NoProfile -File tests/get-patches.ps1 </dev/null >"$out/get-patches.log" 2>&1; echo "$? $((SECONDS - s))" >"$out/get-patches.rc" ) &
  GATES+=(get-patches)
fi
( s=$SECONDS; git ls-files -z '*.sh' | xargs -0 shellcheck -S warning >"$out/shellcheck.log" 2>&1 && echo "shellcheck clean (tree)" >>"$out/shellcheck.log"; echo "$? $((SECONDS - s))" >"$out/shellcheck.rc" ) &
GATES+=(shellcheck)
wait

bad=0
for g in "${GATES[@]}"; do
  read -r rc secs <"$out/$g.rc"
  last="$(tail -1 "$out/$g.log")"
  mark=ok
  if [ "$rc" != 0 ] || grep -q '^FAIL' "$out/$g.log" || printf '%s' "$last" | grep -qE '[1-9][0-9]* failed'; then mark=FAIL; bad=1; fi
  printf '%-4s %-26s %4ss rc=%s  %s\n' "$mark" "$g" "$secs" "$rc" "$(printf '%s' "$last" | cut -c1-110)"
  [ "$mark" = FAIL ] && grep -E '^FAIL' "$out/$g.log" | head -5 | sed 's/^/       /'
done
echo "all gates: $((SECONDS - start))s wall"
exit $bad
