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
# Needs network access. Uses a fresh venv unless --system-annex is given.

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
    "$BASH_BIN" "$SCRIPT" --dir "$CLONE" --venv "$WORK/venv" \
        ${EXTRA[@]+"${EXTRA[@]}"} "$@" > "$LOG" 2>&1 || { cat "$LOG"; return 1; }
    cat "$LOG"
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

echo "=== 1. argument errors"
if "$BASH_BIN" "$SCRIPT" -t bogus > "$LOG" 2>&1; then fail "invalid type accepted"; fi
grep -q "unknown type 'bogus'" "$LOG" || fail "no error message for invalid type"
"$BASH_BIN" "$SCRIPT" --help > "$LOG" 2>&1 || fail "--help failed"
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
pass "paths, hdf5, photon alias"

echo "=== 6. drop"
run -t ace -p n -m '01H_001' --drop || fail "drop failed"
[ ! -f "$CLONE/general-purpose/neutron/ace/01H_001" ] || fail "file still present after drop"
pass "drop"

echo "=== all $n_pass checks passed"
