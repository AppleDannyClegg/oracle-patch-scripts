#!/bin/bash
# install-screen.sh - gate for operations/install-screen/install-screen.sh, with a fake rpm/uname on PATH.
# Checks what it installs (and in what order), and every refusal: already installed, wrong arch, unreadable EL,
# no RPM for this EL, two candidates, libutempter missing with no RPM, a failing --test, and --dry-run.
# Own mktemp dir, offline, no root.
set -u
cd "$(dirname "$0")/.." || exit 1
S="$PWD/operations/install-screen/install-screen.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

# fake tools: behaviour from env, every rpm call logged
mkdir -p "$T/bin"
cat >"$T/bin/rpm" <<'EOF'
#!/bin/bash
echo "rpm $*" >>"$FAKE_LOG"
case "$1" in
  -E) printf '%s\n' "${FAKE_EL-9}"; exit 0 ;;
  -q) [ "${FAKE_UT:-1}" = 1 ] && { echo libutempter-1.2.1-6.el9.x86_64; exit 0; }; exit 1 ;;
  -Uvh)
    if [ "$2" = --test ]; then exit "${FAKE_TEST_RC:-0}"; fi
    [ "${FAKE_NO_SCREEN_AFTER:-0}" = 1 ] || { printf '#!/bin/sh\necho "Screen version 4.08.00"\n' >"$FAKE_BIN/screen"; chmod +x "$FAKE_BIN/screen"; }
    exit 0 ;;
esac
exit 0
EOF
printf '#!/bin/sh\nprintf "%%s\\n" "${FAKE_ARCH:-x86_64}"\n' >"$T/bin/uname"
chmod +x "$T/bin/rpm" "$T/bin/uname"
# a PATH with only the tools the script and fakes use, so a real screen/rpm on this box cannot leak in
mkdir -p "$T/sys"
for t in bash sh head cat chmod env; do ln -s "$(command -v "$t")" "$T/sys/$t"; done

# run <case> [env...] -- args ; sets rc, out, log. Fresh bin per case so 'screen' starts absent.
run() {
    local c="$1"; shift
    local envs=(); while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
    rm -rf "${T:?}/$c"; mkdir -p "$T/$c/bin"; cp "$T/bin/rpm" "$T/bin/uname" "$T/$c/bin/"
    : >"$T/$c/log"
    out="$(env -i HOME="$T" PATH="$T/$c/bin:$T/sys" FAKE_LOG="$T/$c/log" FAKE_BIN="$T/$c/bin" "${envs[@]}" bash "$S" "$@" 2>&1)"
    rc=$?; log="$(cat "$T/$c/log")"
}
rpms() { # <dir> <file...>
    local d="$1"; shift; mkdir -p "$d"; for f in "$@"; do : >"$d/$f"; done
}
R9="$T/r9"; rpms "$R9" screen-4.8.0-6.el9.x86_64.rpm libutempter-1.2.1-6.el9.x86_64.rpm

# 1. normal install, libutempter present: only screen, --test before the install
run a -- "$R9"
[ "$rc" = 0 ] && ok || bad "a: rc $rc: $out"
printf '%s\n' "$log" | grep -q "^rpm -Uvh --test --nosignature $R9/screen-4.8.0-6.el9.x86_64.rpm$" && ok || bad "a: no --test of screen alone: $log"
printf '%s\n' "$log" | grep -q "^rpm -Uvh --nosignature $R9/screen-4.8.0-6.el9.x86_64.rpm$" && ok || bad "a: no install of screen alone: $log"
[ "$(printf '%s\n' "$log" | grep -n -- '--test' | cut -d: -f1)" -lt "$(printf '%s\n' "$log" | grep -vn -- '--test' | grep -- '-Uvh' | cut -d: -f1)" ] && ok || bad "a: install ran before the test: $log"
printf '%s' "$out" | grep -q 'Screen version' && ok || bad "a: no version printed: $out"

# 2. libutempter missing: both, libutempter first
run b FAKE_UT=0 -- "$R9"
[ "$rc" = 0 ] && ok || bad "b: rc $rc: $out"
printf '%s\n' "$log" | grep -q "^rpm -Uvh --nosignature $R9/libutempter-1.2.1-6.el9.x86_64.rpm $R9/screen-4.8.0-6.el9.x86_64.rpm$" && ok || bad "b: not both, libutempter first: $log"

# 3. already installed: no rpm call at all
mkdir -p "$T/c2/bin"; cp "$T/bin/rpm" "$T/bin/uname" "$T/c2/bin/"; printf '#!/bin/sh\necho "Screen version 4.08.00"\n' >"$T/c2/bin/screen"; chmod +x "$T/c2/bin/screen"; : >"$T/c2/log"
out="$(env -i PATH="$T/c2/bin:$T/sys" FAKE_LOG="$T/c2/log" FAKE_BIN="$T/c2/bin" bash "$S" "$R9" 2>&1)"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'already installed' && ok || bad "c: rc $rc: $out"
[ ! -s "$T/c2/log" ] && ok || bad "c: rpm was called when screen was already there: $(cat "$T/c2/log")"

# an install call is an rpm -Uvh without --test
installed() { printf '%s\n' "$log" | grep -- '-Uvh' | grep -vq -- '--test'; }

# refusals: rc 1 (or 2 for usage) and no install call
refuses() { # <case> <want-rc> <grep> -- env... -- args
    local c="$1" want="$2" pat="$3"; shift 3
    run "$c" "$@"
    [ "$rc" = "$want" ] && ok || bad "$c: rc $rc, want $want: $out"
    printf '%s' "$out" | grep -q -- "$pat" && ok || bad "$c: message missing '$pat': $out"
    if installed; then bad "$c: it installed: $log"; else ok; fi
}
refuses d 1 'this server is aarch64' FAKE_ARCH=aarch64 -- "$R9"
refuses e 1 'could not read the EL version' FAKE_EL='%{rhel}' -- "$R9"
refuses f 1 'found 0' FAKE_EL=7 -- "$R9"
R2="$T/r2"; rpms "$R2" screen-4.8.0-5.el9.x86_64.rpm screen-4.8.0-6.el9.x86_64.rpm
refuses g 1 'found 2' -- "$R2"
R3="$T/r3"; rpms "$R3" screen-4.8.0-6.el9.x86_64.rpm
refuses h 1 'libutempter is not installed' FAKE_UT=0 -- "$R3"
refuses i 1 '' FAKE_TEST_RC=1 -- "$R9"
refuses j 2 'usage' --
refuses k 2 'is not a folder' -- "$T/nope"
# rpm says it installed, but no screen appeared: must not report success
run l FAKE_NO_SCREEN_AFTER=1 -- "$R9"
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'screen is not on PATH' && ok || bad "l: rc $rc: $out"

# --dry-run: tests, never installs, rc 0
run m -- --dry-run "$R9"
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'nothing installed' && ok || bad "m: rc $rc: $out"
printf '%s\n' "$log" | grep -q -- '--test' && ok || bad "m: no --test: $log"
if installed; then bad "m: dry run installed: $log"; else ok; fi

echo "install-screen gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
