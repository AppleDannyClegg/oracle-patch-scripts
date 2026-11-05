#!/usr/bin/env bash
# audit-container.sh - mechanical audit of every script on Linux: syntax, and the cross-cutting gates.
#
# run-all already runs the cross-cutting gates on the developer's macOS host. This runs the same set inside a
# Linux container, which is what a server is: GNU bash/tar/awk/sed/find, a real /proc, and (in the hidden-PATH
# pass) no curl or ps at all. Where a gate or a script depends on a macOS-only tool or on a tool being present,
# that shows up here and not on the host.
#
# It is mechanical: syntax + the gates that sweep the whole tree (option parsing, self-containment, secrets on
# argv, the dry-run/unreadable/false-success sweeps). It is NOT the semantic audit - "does this script do the
# right thing on a real estate" - which is a human/seat read per script.
#
# Usage: tests/audit-container.sh [image]     default oraclelinux:8, or set OHS_IMAGE
# Exit: 0 all green, 1 something failed (the output names it), 2 could not run.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${1:-${OHS_IMAGE:-oraclelinux:8}}"
command -v docker >/dev/null || { echo "docker not found"; exit 2; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "image $IMAGE not present locally (docker pull it first)"; exit 2; }

# the gates that sweep the whole tree; keep in step with tests/run-all.sh
GATES="optchk-gate.sh check-parse.sh secret-argv-gate.sh self-contained-gate.sh dry-run-gate.sh false-success-gate.sh unreadable-gate.sh"

# --user 1000: several scripts refuse to run as root (Edi found optchk 62/90 as root, 152/0 as uid 1000);
# HOME must be writable for their run dirs, and the repo stays read-only.
docker run --rm --entrypoint bash --user 1000 -e HOME=/tmp -v "$REPO":/scripts:ro -e MODE="${MODE:-normal}" -e GATES="$GATES" "$IMAGE" -lc '
  set -uo pipefail
  if [ "$MODE" = hidden ]; then
    d=/tmp/audit-bin; rm -rf "$d"; mkdir -p "$d"
    for f in /usr/bin/* /bin/* /usr/sbin/*; do b="$(basename "$f")"; case "$b" in curl|ps) continue;; esac; [ -e "$f" ] && ln -sf "$f" "$d/$b"; done
    export PATH="$d"; echo "hidden PATH -> curl=$(command -v curl || echo none) ps=$(command -v ps || echo none)"
  fi
  cd /scripts || exit 2
  fail=0

  echo "== bash -n on every tracked *.sh"
  n=0
  while IFS= read -r f; do
    n=$((n+1))
    bash -n "$f" 2>/tmp/syn.err || { fail=1; echo "  SYNTAX $f: $(head -1 /tmp/syn.err)"; }
  done < <(git ls-files "*.sh" 2>/dev/null || find . -name "*.sh")
  [ "$fail" = 0 ] && echo "  $n files: syntax ok"

  echo "== cross-cutting gates"
  for g in $GATES; do
    [ -f "tests/$g" ] || { echo "  MISSING tests/$g"; fail=1; continue; }
    out="$(bash "tests/$g" 2>&1)"; rc=$?
    line="$(printf "%s\n" "$out" | grep -viE "^$" | tail -1)"
    printf "  %-26s rc=%-3s %s\n" "$g" "$rc" "$line"
    [ "$rc" = 0 ] || fail=1
  done

  exit "$fail"'
rc=$?
[ "$rc" = 0 ] && echo "audit-container: OK on $IMAGE" && exit 0
echo "audit-container: FAILED on $IMAGE (see the lines above)"
exit 1
