#!/usr/bin/env bash
# get-push gate: get.ps1 -Server copies the tree to a server and makes every script executable there, because
# a copy from Windows (git pull + scp) delivers scripts without the exec bit. Run end to end with pwsh and a
# fake ssh that runs the remote command in a scratch "server home":
#   - the scripts arrive, and every *.sh is executable on the server;
#   - .git, *.conf and downloaded patches (patches-*) are left out, and the server's own oracle.conf is kept;
#   - a failed ssh, or a server where the chmod did not take, is an error, never "done".
# Skipped with a notice when pwsh is absent (not counted as a pass).
#
# Usage: tests/get-push.sh [repo-root]

set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
S="$ROOT/get.ps1"
[ -f "$S" ] || { echo "get-push gate: $S not found"; exit 2; }
pwsh="$(command -v pwsh || true)"
[ -n "$pwsh" ] || { echo "get-push gate: skip - pwsh not installed, not run (not a pass)"; exit 0; }

T="$(cd "$(mktemp -d /tmp/gpush.XXXXXX)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

# a laptop tree as a Windows checkout leaves it: scripts 644, a .git, a laptop conf, a downloaded patch folder
L="$T/laptop/scripts"; mkdir -p "$L/lib" "$L/patching/java-patch/blocklist" "$L/.git" "$L/patches-db1"
printf '#!/bin/bash\n' >"$L/lib/oracle-lib.sh"; printf '#!/bin/bash\n' >"$L/patching/java-patch/java-patch.sh"
printf '#!/bin/bash\n' >"$L/patching/java-patch/blocklist/java-blocklist.sh"; printf 'x\n' >"$L/README.md"
printf 'OFFLINE=0\n' >"$L/oracle.conf"; printf 'g\n' >"$L/.git/HEAD"; printf 'z\n' >"$L/patches-db1/p.zip"
chmod 644 "$L"/lib/*.sh "$L"/patching/java-patch/*.sh "$L"/patching/java-patch/blocklist/*.sh

# the "server": an existing tree with its own oracle.conf that must survive the push
H="$T/server-home"; mkdir -p "$H/scripts"; printf 'OFFLINE=1\n' >"$H/scripts/oracle.conf"
mkdir -p "$T/bin"
cat >"$T/bin/ssh" <<EOF
#!/bin/bash
# fake ssh: drop the host, run the command in the server home; FAKE_SSH_MODE breaks it on purpose
shift
case "\${FAKE_SSH_MODE:-}" in
  down) cat >/dev/null; echo "ssh: connect to host db1 port 22: Connection refused" >&2; exit 255;;
  nochmod) cmd="\${1//-exec chmod +x \{\} +/-exec true \{\} +}";;
  *) cmd="\$1";;
esac
cd "$H" && exec bash -c "\$cmd"
EOF
chmod +x "$T/bin/ssh"
push() { PATH="$T/bin:$PATH" "$pwsh" -NoProfile -File "$S" -PushOnly -Server oracle@db1 "$L" >"$T/out" 2>&1; }

push; rc=$?
[ $rc = 0 ] && grep -q 'done on oracle@db1: 3 scripts copied to ./scripts, all executable' "$T/out" && ok || bad "push failed or did not report 3 executable scripts (rc=$rc): $(cat "$T/out")"
n="$(find "$H/scripts" -name '*.sh' | wc -l | tr -d ' ')"; nx="$(find "$H/scripts" -name '*.sh' ! -perm -u+x | wc -l | tr -d ' ')"
[ "$n" = 3 ] && [ "$nx" = 0 ] && ok || bad "server has $n scripts, $nx not executable (want 3, 0)"
[ -f "$H/scripts/README.md" ] && ok || bad "a non-script file did not arrive"
[ ! -e "$H/scripts/.git" ] && [ ! -e "$H/scripts/patches-db1" ] && ok || bad ".git or the downloaded patches were copied to the server"
[ "$(cat "$H/scripts/oracle.conf")" = "OFFLINE=1" ] && ok || bad "the server's own oracle.conf was overwritten: $(cat "$H/scripts/oracle.conf")"

FAKE_SSH_MODE=nochmod push; rc=$?
chmod 644 "$H"/scripts/lib/*.sh   # as if the chmod never ran
FAKE_SSH_MODE=nochmod push; rc=$?
[ $rc != 0 ] && grep -q 'are not executable after the copy' "$T/out" && ok || bad "a server where chmod did not take was reported done (rc=$rc): $(cat "$T/out")"
FAKE_SSH_MODE=down push; rc=$?
[ $rc != 0 ] && grep -q 'did not finish' "$T/out" && ! grep -q '^done on' "$T/out" && ok || bad "a failed ssh was not an error (rc=$rc): $(cat "$T/out")"

# -PushOnly on a folder that is not the tree is refused before any ssh
PATH="$T/bin:$PATH" "$pwsh" -NoProfile -File "$S" -PushOnly -Server oracle@db1 "$T" >"$T/out" 2>&1; rc=$?
[ $rc != 0 ] && grep -q 'not an oracle-patch-scripts tree' "$T/out" && ok || bad "a non-tree folder was not refused (rc=$rc): $(cat "$T/out")"

echo "get-push: $pass passed, $fail failed"
[ "$fail" = 0 ]
