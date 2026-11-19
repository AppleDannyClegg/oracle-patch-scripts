#!/usr/bin/env bash
# get-push gate: get.ps1 -Server copies the tree to a server and makes every script executable there, because
# a copy from Windows (git pull + scp) delivers scripts without the exec bit. Run end to end with pwsh and a
# fake ssh that runs the remote command in a scratch "server home":
#   - the scripts arrive, and every *.sh is executable on the server;
#   - .git, *.conf and downloaded patches (patches-*) are left out, and the server's own oracle.conf is kept;
#   - a failed tar, scp or ssh (even an ssh that exits non-zero after printing its counts), or a server where
#     the chmod did not take, is an error, never "done"; a local path holding $ or a space is copied as it is;
#     an option-like value (-oProxyCommand=...) is refused.
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
REALTAR="$(command -v tar)"
cat >"$T/bin/scp" <<EOF
#!/bin/bash
# fake scp: copy the archive into the server home under the name given after the colon
[ "\${FAKE_MODE:-}" = scpdown ] && { echo "ssh: connect to host db1 port 22: Connection refused" >&2; exit 255; }
src="\${@: -2:1}"; dst="\${@: -1}"; cp "\$src" "$H/\${dst#*:}"
EOF
cat >"$T/bin/ssh" <<EOF
#!/bin/bash
# fake ssh: drop the host, run the command in the server home; FAKE_MODE breaks it on purpose
shift; cmd="\$1"
case "\${FAKE_MODE:-}" in
  down) echo "ssh: connect to host db1 port 22: Connection refused" >&2; exit 255;;
  nochmod) cmd="\${cmd//-exec chmod +x \{\} +/-exec true \{\} +}";;
  rc7) cd "$H" && bash -c "\$cmd"; exit 7;;
esac
cd "$H" && exec bash -c "\$cmd"
EOF
cat >"$T/bin/tar" <<EOF
#!/bin/bash
# real tar, except FAKE_MODE=tarfail makes the packing call write its archive and then exit 9
"$REALTAR" "\$@"; rc=\$?
[ "\${FAKE_MODE:-}" = tarfail ] && [ "\$1" = -cf ] && exit 9
exit \$rc
EOF
chmod +x "$T/bin/scp" "$T/bin/ssh" "$T/bin/tar"
push() { PATH="$T/bin:$PATH" "$pwsh" -NoProfile -File "$S" -PushOnly -Server oracle@db1 "${1:-$L}" >"$T/out" 2>&1; }

push; rc=$?
[ $rc = 0 ] && grep -q 'done on oracle@db1: 3 scripts at ./scripts, all executable' "$T/out" && ok || bad "push failed or did not report 3 executable scripts (rc=$rc): $(cat "$T/out")"
n="$(find "$H/scripts" -name '*.sh' | wc -l | tr -d ' ')"; nx="$(find "$H/scripts" -name '*.sh' ! -perm -u+x | wc -l | tr -d ' ')"
[ "$n" = 3 ] && [ "$nx" = 0 ] && ok || bad "server has $n scripts, $nx not executable (want 3, 0)"
[ -f "$H/scripts/README.md" ] && ok || bad "a non-script file did not arrive"
[ ! -e "$H/scripts/.git" ] && [ ! -e "$H/scripts/patches-db1" ] && ok || bad ".git or the downloaded patches were copied to the server"
left=("$H"/.oracle-push-*); [ ! -e "${left[0]}" ] && ok || bad "a successful push left its archive in the server home: ${left[*]}"
[ "$(cat "$H/scripts/oracle.conf")" = "OFFLINE=1" ] && ok || bad "the server's own oracle.conf was overwritten: $(cat "$H/scripts/oracle.conf")"

chmod 644 "$H"/scripts/lib/*.sh   # as if the chmod never ran
FAKE_MODE=nochmod push; rc=$?
[ $rc != 0 ] && grep -q 'are not executable after the copy' "$T/out" && ! grep -q '^done on' "$T/out" && ok || bad "a server where chmod did not take was reported done (rc=$rc): $(cat "$T/out")"
FAKE_MODE=down push; rc=$?
[ $rc != 0 ] && grep -q 'ssh exit 255' "$T/out" && ! grep -q '^done on' "$T/out" && ok || bad "a failed ssh was not an error (rc=$rc): $(cat "$T/out")"
FAKE_MODE=scpdown push; rc=$?
[ $rc != 0 ] && grep -q 'scp to oracle@db1 failed' "$T/out" && ! grep -q '^done on' "$T/out" && ok || bad "a failed scp was not an error (rc=$rc): $(cat "$T/out")"
# Vesper #29425: ssh exiting non-zero AFTER a valid trailer, and tar failing after writing its archive
FAKE_MODE=rc7 push; rc=$?
[ $rc != 0 ] && grep -q 'ssh exit 7' "$T/out" && ! grep -q '^done on' "$T/out" && ok || bad "ssh rc 7 after a valid trailer was reported done (rc=$rc): $(cat "$T/out")"
FAKE_MODE=tarfail push; rc=$?
[ $rc != 0 ] && grep -q 'tar could not pack' "$T/out" && ! grep -q '^done on' "$T/out" && ok || bad "a failed tar was reported done (rc=$rc): $(cat "$T/out")"
# a local parent holding a literal $ (legal on Windows and Unix): copied as it is, not expanded by a shell
D="$T/l\$HOME x"; mkdir -p "$D"; cp -R "$L" "$D/scripts2"; chmod 644 "$D"/scripts2/lib/*.sh
push "$D/scripts2"; rc=$?
[ $rc = 0 ] && [ -z "$(find "$H/scripts2" -name '*.sh' ! -perm -u+x)" ] && [ -f "$H/scripts2/lib/oracle-lib.sh" ] && ok || bad "a parent folder with \$ and a space did not push as it is (rc=$rc): $(cat "$T/out")"
# option-like values are refused before anything runs
PATH="$T/bin:$PATH" "$pwsh" -NoProfile -File "$S" -PushOnly -Server -oBatchMode "$L" >"$T/out" 2>&1; rc=$?
[ $rc != 0 ] && grep -q "may not start with '-'" "$T/out" && ok || bad "an option-like -Server value was not refused (rc=$rc): $(cat "$T/out")"

# -PushOnly on a folder that is not the tree is refused before any ssh
PATH="$T/bin:$PATH" "$pwsh" -NoProfile -File "$S" -PushOnly -Server oracle@db1 "$T" >"$T/out" 2>&1; rc=$?
[ $rc != 0 ] && grep -q 'not an oracle-patch-scripts tree' "$T/out" && ok || bad "a non-tree folder was not refused (rc=$rc): $(cat "$T/out")"

echo "get-push: $pass passed, $fail failed"
[ "$fail" = 0 ]
