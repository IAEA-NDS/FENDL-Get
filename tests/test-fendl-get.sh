#!/usr/bin/env bash
#
# End-to-end test of fendl-get.sh: clones the repository into a temporary
# directory, downloads a few small files of the processed library and of the
# ENDF submodule, and checks their contents against the git-annex keys.
#
# Environment variables:
#   TEST_BASH   bash binary used to run fendl-get.sh (default: bash), e.g.
#               /bin/bash on macOS to test with bash 3.2
#   TEST_ARGS   extra options for fendl-get.sh, e.g. --system-annex
#   KEEP_WORK   if set to 1, the temporary directory is kept
#
# Needs network access. Uses the default venv inside the clone unless
# --system-annex is given.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
SCRIPT="$here/../fendl-get.sh"
BASH_BIN="${TEST_BASH:-bash}"
# shellcheck disable=SC2206  # intentional word splitting of option list
EXTRA=(${TEST_ARGS:-})

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t fendl-get-test)
cleanup() {
    if [ "${KEEP_WORK:-0}" = 1 ]; then
        echo "work dir kept: $WORK"
    else
        chmod -R u+w "$WORK" 2>/dev/null || true   # annex objects are read-only
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT
CLONE="$WORK/clone"
OUT="$WORK/out"
LOG="$WORK/log"

n_pass=0
pass() { n_pass=$((n_pass + 1)); echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; echo "--- last output:" >&2; cat "$LOG" >&2; exit 1; }

# Run fendl-get.sh, logging its output to $LOG (and to the console).
run() {
    "$BASH_BIN" "$SCRIPT" --dir "$CLONE" \
        ${EXTRA[@]+"${EXTRA[@]}"} "$@" > "$LOG" 2>&1 || { cat "$LOG"; return 1; }
    cat "$LOG"
}

# Run fendl-get.sh expecting it to fail with a message matching a pattern.
run_fails() {  # run_fails PATTERN ARGS...
    local pattern="$1"; shift
    if "$BASH_BIN" "$SCRIPT" "$@" > "$LOG" 2>&1; then fail "accepted: $*"; fi
    grep -q -- "$pattern" "$LOG" || fail "unexpected error message for: $*"
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f 1
    else shasum -a 256 "$1" | cut -d ' ' -f 1; fi
}

# Check that a downloaded file matches the SHA256 recorded in its annex key.
check_content() {  # check_content PATH_IN_CLONE [COPY]
    local f="$CLONE/$1" copy="${2:-}" target key want got
    [ -L "$f" ] || fail "$1 is not an annex symlink"
    [ -f "$f" ] || fail "$1 has no content (broken symlink)"
    target=$(readlink "$f")
    key=$(basename "$target")
    case "$key" in SHA256E-*) ;; *) fail "unexpected key $key for $1" ;; esac
    want=$(printf '%s\n' "$key" | sed 's/.*--//; s/\..*//')
    got=$(sha256_of "$f")
    [ "$got" = "$want" ] || fail "checksum mismatch for $1"
    if [ -n "$copy" ]; then
        [ -f "$copy" ] && [ ! -L "$copy" ] || fail "$copy is not a regular file"
        [ -w "$copy" ] || fail "$copy is not writable"
        [ "$(sha256_of "$copy")" = "$want" ] || fail "checksum mismatch for $copy"
    fi
}

# shellcheck disable=SC2016  # expanded by the inner bash
echo "=== bash used for fendl-get.sh: $("$BASH_BIN" -c 'echo $BASH_VERSION')"

# shellcheck disable=SC2054  # the commas belong to the --type value
SEL=(-t ace,endf -p n -m '01H*' -m '*H-1.endf')
EXPECTED="
general-purpose/neutron/ace/01H_001
general-purpose/neutron/ace/01H_001.xsd
general-purpose/neutron/ace/01H_002
general-purpose/neutron/ace/01H_002.xsd
general-purpose/neutron/ace/01H_003
general-purpose/neutron/ace/01H_003.xsd
fendl-endf/general-purpose/neutron/n_0125_1-H-1.endf
"

# Side effects outside the clone: entries in the home directory (3 levels,
# e.g. ~/.cache/pip, ~/Library/Caches/...) and the global git config.
snapshot() {
    find "$HOME" -mindepth 1 -maxdepth 3 2>/dev/null | LC_ALL=C sort
    echo "--- global git config:"
    git config --global --list 2>/dev/null || true
}
snapshot > "$WORK/home-before"

echo "=== 1. argument errors"
if "$BASH_BIN" "$SCRIPT" -t bogus > "$LOG" 2>&1; then fail "invalid type accepted"; fi
grep -q "unknown type 'bogus'" "$LOG" || fail "no error message for invalid type"
"$BASH_BIN" "$SCRIPT" --help > "$LOG" 2>&1 || fail "--help failed"
run_fails 'integer from 1 to 64' -t ace -j 0
run_fails 'integer from 1 to 64' -t ace -j 65
pass "argument handling"

echo "=== 2. dry run (sets up git-annex, clones, enables remotes)"
run "${SEL[@]}" --dry-run || fail "dry run failed"
for f in $EXPECTED; do
    grep -q "^  $f\$" "$LOG" || fail "dry run does not list $f"
done
grep -q 'to download: 7 files' "$LOG" || fail "dry run: unexpected file count"
[ ! -f "$CLONE/general-purpose/neutron/ace/01H_001" ] || fail "dry run downloaded files"
pass "dry run"

echo "=== 3. download with --copy-to"
run "${SEL[@]}" --copy-to "$OUT" || fail "download failed"
for f in $EXPECTED; do check_content "$f" "$OUT/$f"; done
if [ ${#EXTRA[@]} -eq 0 ]; then
    [ -f "$CLONE/.git/fendl-get-venv/.fendl-get-venv" ] || fail "venv not inside the clone"
    # the pinned versions were installed (not silently skipped)
    pipv=$("$CLONE/.git/fendl-get-venv/bin/python" -m pip --version | cut -d ' ' -f 2)
    case "$pipv" in 26.3|26.0.1) ;; *) fail "unexpected pip version $pipv in the venv" ;; esac
    [ -n "${FENDL_GET_PIP_SPEC:-}" ] || "$CLONE/.git/fendl-get-venv/bin/git-annex" version --raw |
        grep -q '^10\.20261026' || fail "git-annex in the venv is not the pinned version"
fi
pass "download from S3 and --copy-to (contents verified)"

echo "=== 4. rerun is a no-op"
run "${SEL[@]}" || fail "rerun failed"
grep -q 'to download: 0 files' "$LOG" || fail "rerun wanted to download files again"
pass "rerun"

echo "=== 5. paths, hdf5 and photon alias"
run general-purpose/neutron/njoy/01H_001.nji || fail "download by path failed"
check_content general-purpose/neutron/njoy/01H_001.nji
run -t hdf5 -p photon -m 'H.h5' || fail "hdf5 download failed"
check_content general-purpose/atom/hdf5/H.h5
# --release with a commit id and a relative revision, then back
c=$(git -C "$CLONE" rev-parse --short=9 'FENDL-3.2c^{commit}')
run -r "$c" -t ace -p p -m 01H_001 -n || fail "--release with a commit id failed"
grep -q "Checking out $c" "$LOG" || fail "commit $c not checked out"
run -r 'FENDL-3.2c~1' -t ace -p p -m 01H_001 -n || fail "--release FENDL-3.2c~1 failed"
run -t ace -p n -m 01H_001 -n || fail "switching back to the default release failed"
grep -q "Checking out fendl32d_prep" "$LOG" || fail "default release not checked out again"
pass "paths, hdf5, photon alias, revisions as --release"

echo "=== 6. drop"
run -t ace -p n -m '01H_001' --drop || fail "drop failed"
[ ! -f "$CLONE/general-purpose/neutron/ace/01H_001" ] || fail "file still present after drop"
pass "drop"

echo "=== 7. protection against wrong arguments"
# --venv: a non-empty directory not created by the script is refused and
# left alone, also as a relative path.
mkdir -p "$WORK/data" && echo keep > "$WORK/data/thesis.tex"
run_fails 'refusing to use it' --dir "$CLONE" --venv "$WORK/data" -t ace -p n -n
(cd "$WORK" && run_fails '/data is not empty' --dir "$CLONE" --venv data -t ace -p n -n)
[ "$(ls -A "$WORK/data")" = thesis.tex ] || fail "--venv directory was modified"
# --venv: if creating the venv fails, only a directory created by the
# script is removed, and an existing empty directory is kept. (PYTHON=false
# makes venv creation fail; the script may then fall back to a system
# git-annex, so only the state of the directories is checked.)
PYTHON=false "$BASH_BIN" "$SCRIPT" --dir "$CLONE" --venv "$WORK/newvenv" -t ace -p n -n > "$LOG" 2>&1 || true
grep -q 'could not create a venv' "$LOG" || fail "venv creation did not fail as intended"
[ ! -e "$WORK/newvenv" ] || fail "venv directory created by the script not cleaned up"
mkdir "$WORK/emptyvenv"
PYTHON=false "$BASH_BIN" "$SCRIPT" --dir "$CLONE" --venv "$WORK/emptyvenv" -t ace -p n -n > "$LOG" 2>&1 || true
[ -d "$WORK/emptyvenv" ] || fail "existing (empty) --venv directory was removed"
# --dir: another git repository is refused and left unchanged.
git init -q "$WORK/project"
git -C "$WORK/project" -c user.name=t -c user.email=t@t commit -q --allow-empty -m mine
cfg_before=$(git -C "$WORK/project" config --local -l)
run_fails 'not a clone of fendl-processed' --dir "$WORK/project" -t ace -p n -n
[ ! -e "$WORK/project/.git/annex" ] || fail "git-annex was initialised in another repository"
[ "$(git -C "$WORK/project" config --local -l)" = "$cfg_before" ] || fail "config of another repository changed"
# --dir: a non-empty directory that is no repository is refused.
run_fails 'exists and is not a git repository' --dir "$WORK/data" -t ace -p n -n
# --copy-to: directories inside the clone are refused.
run_fails 'outside the clone' --dir "$CLONE" -t ace -p n -m 01H_001 --copy-to "$CLONE"
run_fails 'outside the clone' --dir "$CLONE" -t ace -p n -m 01H_001 --copy-to "$CLONE/general-purpose"
pass "protection against wrong arguments"

echo "=== 8. AWS credentials, interrupted venv creation, disk space"
# AWS credentials in the environment are not used (nor stored in the clone).
AWS_ACCESS_KEY_ID=AKIAFAKEFAKEFAKEFAKE AWS_SECRET_ACCESS_KEY=fakesecret \
    run -t ace -p n -m 01H_001 || fail "download with AWS credentials in the environment failed"
check_content general-purpose/neutron/ace/01H_001
[ -z "$(ls -A "$CLONE/.git/annex/creds" 2>/dev/null)" ] || fail "AWS credentials were stored in the clone"
# An incomplete venv (e.g. from an interrupted first run) is repaired.
if [ ${#EXTRA[@]} -eq 0 ]; then
    rm -rf "$CLONE/.git/fendl-get-venv/lib"
    run -t ace -p n -m 01H_001 -n || fail "incomplete venv was not repaired"
    grep -q 'Creating Python venv' "$LOG" || fail "incomplete venv was not recreated"
fi
# Downloads that would leave less than the reserve free are refused.
FENDL_GET_MIN_FREE=999000000000000 run -t njoy-input -p n -m '01H_002*' -n || fail "dry run failed"
grep -q 'not enough disk space' "$LOG" || fail "dry run did not warn about disk space"
if FENDL_GET_MIN_FREE=999000000000000 run -t njoy-input -p n -m '01H_002*'; then
    fail "download not refused despite lack of disk space"
fi
grep -q 'not enough disk space' "$LOG" || fail "unexpected error message for lack of disk space"
[ ! -f "$CLONE/general-purpose/neutron/njoy/01H_002.nji" ] || fail "file downloaded despite lack of disk space"
[ "$(git -C "$CLONE" config --get annex.diskreserve)" = "2 gigabytes" ] || fail "annex.diskreserve not set"
pass "AWS credentials ignored, venv repaired, disk space checked"

echo "=== 9. removal as documented"
chmod -R u+w "$CLONE" && rm -rf "$CLONE"
[ ! -e "$CLONE" ] || fail "clone could not be removed with the documented command"
pass "removal of the clone (including the venv)"

echo "=== 10. nothing changed outside the clone"
snapshot > "$WORK/home-after"
if ! cmp -s "$WORK/home-before" "$WORK/home-after"; then
    diff "$WORK/home-before" "$WORK/home-after" | sed 's/^/  /' > "$LOG" || true
    fail "the home directory or the global git config changed"
fi
pass "no changes in the home directory and the global git config"

echo "=== all $n_pass checks passed"
