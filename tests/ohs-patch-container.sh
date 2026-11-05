#!/usr/bin/env bash
# ohs-patch-container.sh - run the ohs-patch gate the way a server runs it: on Linux, with GNU tools.
#
# Why a container at all: tests/ohs-patch.sh is written to be host-independent - it puts its own ps and curl
# stubs first on PATH - so a green run on macOS proves the logic. What macOS does NOT prove is the environment
# a real OHS box has: GNU tar/awk/sed/find, and the script's own 'command -v curl' branch when curl is absent.
# This lane runs the same gate inside a Linux image, twice: normally, and with curl and ps removed from PATH
# (a PATH of symlinks to everything the gate needs except those two), so the tools the gate stubs are genuinely
# absent for the outer shell too.
#
# It does NOT prove the ceiling: the real OHS home layout (instances/, registry.xml), opatch's real output and
# the ~/.wlst/nm-* credentials. A container of fakes encodes our own assumptions; only a real OHS box (Gen's
# read-only preflight) settles those. This lane removes the macOS-vs-Linux blind spot, nothing more.
#
# Usage: tests/ohs-patch-container.sh [image]     default oraclelinux:8, or set OHS_IMAGE
# Exit: 0 both passes green, 1 the gate reported a failure, 2 could not run (no docker/image).
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${1:-${OHS_IMAGE:-oraclelinux:8}}"

command -v docker >/dev/null || { echo "docker not found"; exit 2; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "image $IMAGE not present locally (docker pull it first)"; exit 2; }

# <mode: normal|hidden> -> run tests/ohs-patch.sh in the container and print its output
gate() {
  docker run --rm --entrypoint bash -v "$REPO":/scripts:ro -e MODE="$1" "$IMAGE" -lc '
    set -uo pipefail
    if [ "${MODE}" = hidden ]; then
      # every binary the image has, except curl and ps: a real PATH where those two are absent, not stubbed
      d=/tmp/ohs-gate-bin; rm -rf "$d"; mkdir -p "$d"
      for f in /usr/bin/* /bin/* /usr/sbin/*; do
        b="$(basename "$f")"; case "$b" in curl|ps) continue;; esac
        [ -e "$f" ] && ln -sf "$f" "$d/$b"
      done
      export PATH="$d"
      echo "hidden PATH -> curl=$(command -v curl || echo none) ps=$(command -v ps || echo none)"
    fi
    command -v unzip >/dev/null || echo "note: no unzip in this image - the zip fixture case will not run"
    cd /scripts && bash tests/ohs-patch.sh'
}

echo "=== image: $IMAGE ==="
ok=1
for mode in normal hidden; do
  out="$(gate "$mode")"
  summary="$(printf '%s\n' "$out" | grep -E '^ohs-patch gate: ' | tail -1)"
  printf '%s\n' "$out" | sed -n '1,2p' | sed 's/^/   /'
  echo "--- $mode: ${summary:-no gate summary}"
  printf '%s' "$summary" | grep -qE '[0-9]+ passed, 0 failed' || ok=0
done

if [ "$ok" = 1 ]; then
  echo "ohs-patch container gate: OK on $IMAGE (normal + no-curl/no-ps)"
  echo "CEILING: not proven here - the real OHS layout, opatch output and NM creds; only a real OHS box settles those."
  exit 0
fi
echo "ohs-patch container gate: FAILED on $IMAGE"
exit 1
