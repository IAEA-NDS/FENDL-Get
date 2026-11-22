#!/usr/bin/env bash
#
# fendl-get.sh -- download files of the Fusion Evaluated Nuclear Data Library
#                 (FENDL) from https://github.com/iaea-nds/fendl-processed
#
# The repository stores large files with git-annex. This script
#   1. clones the repository (and the fendl-endf submodule if needed),
#   2. installs git-annex into a Python venv inside the clone (via pip),
#   3. checks out the requested FENDL release, and
#   4. downloads the requested file types with `git annex get`.
# Everything it creates is inside the clone (and the --copy-to directory, if
# given); see --help for how to remove it again.
#
# Requirements: bash (3.2+, so the macOS default works), git, python3.
# Run `fendl-get.sh --help` for usage.
#
# Home: https://github.com/iaea-nds/fendl-get

set -euo pipefail

REPO_URL="https://github.com/iaea-nds/fendl-processed"
ENDF_SUBMODULE="fendl-endf"
DEFAULT_RELEASE="fendl32d_prep"   # branch or tag checked out by default

# Public S3 special remotes holding the annexed content, as
# "uuid|name|bucket|region". They are addressed by UUID because the remote
# name fendl-proc-aws-s3 is registered twice in fendl-processed.
S3_REMOTE_MAIN="4737e67e-3733-4035-8715-a2747c323879|fendl-proc-aws-s3|fendl-processing-storage|eu-north-1"
S3_REMOTE_ENDF="2cf4d611-eca6-4062-9bb9-ac099534b9e3|fendl-endf-aws-s3|fendl-endf-storage|eu-north-1"

ALL_TYPES="ace njoy njoy-input njoy-output matxs gendf hdf5 plots plots-ps endf"
ALL_PARTICLES="neutron proton deuteron atom"

# ---------------------------------------------------------------- defaults
DIR="fendl-processed"
RELEASE="$DEFAULT_RELEASE"   # 'latest' = newest FENDL-* tag
TYPES=""
PARTICLES=""
JOBS=4
VENV="${FENDL_GET_VENV:-}"   # empty: <clone>/.git/fendl-get-venv
VENV_SUBDIR="fendl-get-venv"
# Pinned versions (tested in CI). FENDL_GET_PIP_SPEC overrides the git-annex
# requirement, e.g. FENDL_GET_PIP_SPEC=git-annex for the newest release.
PIP_SPEC="${FENDL_GET_PIP_SPEC:-git-annex==10.20261026}"
# pip >= 26.1 needs Python >= 3.10; the macOS Command Line Tools have 3.9.
PIP_PIN_NEW='pip==26.3; python_version >= "3.10"'
PIP_PIN_OLD='pip==26.0.1; python_version < "3.10"'
MAX_JOBS=64
# Free disk space to keep in the clone's file system (bytes); git-annex is
# configured to keep the same (annex.diskreserve).
MIN_FREE="${FENDL_GET_MIN_FREE:-2000000000}"
# Root commits of the data branches, used to recognise existing clones.
ROOT_COMMIT_MAIN="705c960547e89788261fe9bfcf0b12602f6db072"
ROOT_COMMIT_ENDF="5b1d5b8cb48bb0c3e237850dbec163333dc921a9"
PYTHON="${PYTHON:-}"
USE_SYSTEM_ANNEX=0
DRY_RUN=0
DROP=0
COPY_TO=""
LIST_RELEASES=0
UPDATE=0
MATCHES=()
EXTRA_PATHS=()

# ---------------------------------------------------------------- helpers
msg()  { printf '%s\n' "==> $*" >&2; }
warn() { printf '%s\n' "WARNING: $*" >&2; }
die()  { printf '%s\n' "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] [PATH...]

Download FENDL files (ACE, NJOY, MATXS, GENDF, plots, ENDF) via git-annex.

Selection:
  -t, --type LIST       Comma-separated file types to download:
                          ace          ACE files incl. .xsd snippets  (n, p, d)
                          njoy         NJOY input and output files    (n, p, d)
                          njoy-input   NJOY input files (.nji) only   (n, p, d)
                          njoy-output  NJOY output files (.out) only  (n, p, d)
                          matxs        MATXS files (.m)               (n)
                          gendf        GENDF files (.g / .gam)        (n, atom)
                          hdf5         OpenMC HDF5 files (.h5)        (n, atom)
                          plots        verification plots, PDF        (n, p, d)
                          plots-ps     verification plots, PostScript (n, p, d)
                          endf         ENDF source files              (n, p, d, atom)
                          all          everything above
  -p, --particle LIST   Comma-separated sublibraries: neutron, proton,
                        deuteron, atom (default: all that apply to the type).
                        Short forms n, p, d, a are accepted.
  -m, --match GLOB      Only files whose name matches GLOB, e.g. '26Fe*' for
                        processed files or '*Fe-56*' for ENDF files.
                        Can be given several times (combined with OR).
  PATH...               Additional paths inside the repository to download,
                        e.g. general-purpose/neutron/ace/26Fe056

Release and location:
  -r, --release REF     FENDL release (git branch or tag) to check out,
                        e.g. FENDL-3.2c, or 'latest' for the newest FENDL-*
                        tag. Default: $DEFAULT_RELEASE.
      --list-releases   Show available releases and exit.
  -d, --dir DIR         Where to clone the repository (default: ./fendl-processed).
                        An existing clone of fendl-processed is reused; any
                        other existing, non-empty directory is refused.
  -u, --update          Fetch the newest commits/tags of an existing clone.

Actions:
  -n, --dry-run         Only show what would be downloaded and how big it is.
      --drop            Remove the local copies of the selected files instead
                        (they can be downloaded again at any time).
  -c, --copy-to DIR     After downloading, also copy the selected files as
                        regular files (not symlinks) into DIR, keeping the
                        directory structure.
  -j, --jobs N          Number of parallel downloads, 1-$MAX_JOBS (default: $JOBS).

git-annex installation:
      --venv DIR        Location of the Python venv with git-annex (default:
                        inside the clone, in .git/$VENV_SUBDIR). DIR must not
                        exist yet, be empty, or be a venv made by this script.
      --system-annex    Use the git-annex found on PATH instead of a venv.

  -h, --help            Show this help.

Examples:
  # ACE files of the neutron sublibrary of the latest release
  $(basename "$0") -t ace -p neutron

  # ENDF and NJOY input files for iron isotopes (ENDF and processed files
  # use different naming schemes, hence two patterns)
  $(basename "$0") -t endf,njoy-input -p n -m '*Fe-*' -m '26Fe*'

  # ACE files of the FENDL-3.2b release
  $(basename "$0") -r FENDL-3.2b -t ace

  # How much would all proton and deuteron ACE files take?
  $(basename "$0") -t ace -p p,d --dry-run

  # Get neutron ACE files as plain files in ./ace-lib
  $(basename "$0") -t ace -p n --copy-to ./ace-lib

Everything this script creates (repository, venv with git-annex, downloaded
files) is inside the clone directory, plus the --copy-to directory if given.
Downloaded files are write-protected by git-annex, so remove the clone with
  chmod -R u+w fendl-processed && rm -rf fendl-processed

Files are downloaded anonymously from public Amazon S3 buckets (and, for older
releases, from the IAEA-NDS web server). Please note the terms of
use in TERMS_OF_USE.md of the repository.
EOF
}

# Membership test in a space-separated word list.
in_list() {  # in_list WORD "LIST"
    case " $2 " in *" $1 "*) return 0 ;; esac
    return 1
}

human_size() {  # human_size BYTES  (decimal units, as git-annex uses)
    awk -v b="$1" 'BEGIN { split("bytes kB MB GB TB", u, " "); i = 1;
        while (b >= 1000 && i < 5) { b /= 1000; i++ }
        if (i == 1) printf "%d %s", b, u[i]; else printf "%.2f %s", b, u[i] }'
}

# Sum the first column of "<bytes>\t<file>" lines in a file.
sum_bytes() { awk -F '\t' '$1 ~ /^[0-9]+$/ { s += $1 } END { printf "%.0f", s + 0 }' "$1"; }

# ---------------------------------------------------------------- arguments
need_arg() { [ $# -ge 2 ] && [ -n "$2" ] || die "option $1 requires an argument"; }

while [ $# -gt 0 ]; do
    case "$1" in
        -t|--type)       need_arg "$@"; TYPES="$TYPES,$2"; shift 2 ;;
        -p|--particle)   need_arg "$@"; PARTICLES="$PARTICLES,$2"; shift 2 ;;
        -m|--match)      need_arg "$@"; MATCHES+=("$2"); shift 2 ;;
        -r|--release)    need_arg "$@"; RELEASE="$2"; shift 2 ;;
        -d|--dir)        need_arg "$@"; DIR="$2"; shift 2 ;;
        -j|--jobs)       need_arg "$@"; JOBS="$2"; shift 2 ;;
        -c|--copy-to)    need_arg "$@"; COPY_TO="$2"; shift 2 ;;
        --venv)          need_arg "$@"; VENV="$2"; shift 2 ;;
        --system-annex)  USE_SYSTEM_ANNEX=1; shift ;;
        -n|--dry-run)    DRY_RUN=1; shift ;;
        --drop)          DROP=1; shift ;;
        -u|--update)     UPDATE=1; shift ;;
        --list-releases) LIST_RELEASES=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        --)              shift; while [ $# -gt 0 ]; do EXTRA_PATHS+=("$1"); shift; done ;;
        -*)              die "unknown option: $1 (see --help)" ;;
        *)               EXTRA_PATHS+=("$1"); shift ;;
    esac
done

case "$JOBS" in ''|*[!0-9]*) die "--jobs expects an integer from 1 to $MAX_JOBS" ;; esac
{ [ "$JOBS" -ge 1 ] && [ "$JOBS" -le $MAX_JOBS ]; } || die "--jobs expects an integer from 1 to $MAX_JOBS"
[ $DROP -eq 1 ] && [ -n "$COPY_TO" ] && die "--drop and --copy-to cannot be combined"
# The script changes into the clone later, so make paths absolute now.
case "$COPY_TO" in ''|/*) ;; *) COPY_TO="$(pwd -P)/$COPY_TO" ;; esac
case "$VENV" in ''|/*) ;; *) VENV="$(pwd -P)/$VENV" ;; esac
case "$MIN_FREE" in ''|*[!0-9]*) die "FENDL_GET_MIN_FREE expects a number of bytes" ;; esac

# git-annex would use AWS credentials from the environment for the S3
# remotes, fail with them on the public buckets, and store them in the
# clone. Drop them for this script (the user's environment is unchanged).
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

# Normalise type list.
sel_types=""
for t in $(printf '%s' "$TYPES" | tr ',' ' '); do
    t=$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')
    if [ "$t" = all ]; then
        # 'njoy' already covers njoy-input/njoy-output
        sel_types="ace njoy matxs gendf hdf5 plots plots-ps endf"; break
    fi
    in_list "$t" "$ALL_TYPES" || die "unknown type '$t' (valid: $ALL_TYPES all)"
    in_list "$t" "$sel_types" || sel_types="$sel_types $t"
done

# Normalise particle list.
sel_particles=""
explicit_particles=0
for p in $(printf '%s' "$PARTICLES" | tr ',' ' '); do
    p=$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')
    case "$p" in
        n|neutron|neutrons)    p=neutron ;;
        p|proton|protons)      p=proton ;;
        d|deuteron|deuterons)  p=deuteron ;;
        a|atom|photo|photon)   p=atom ;;
        all)                   p="" ; sel_particles="$ALL_PARTICLES" ;;
        *) die "unknown particle '$p' (valid: $ALL_PARTICLES)" ;;
    esac
    explicit_particles=1
    [ -n "$p" ] && ! in_list "$p" "$sel_particles" && sel_particles="$sel_particles $p"
done
[ -n "$sel_particles" ] || sel_particles="$ALL_PARTICLES"

if [ $LIST_RELEASES -eq 0 ] && [ -z "$sel_types" ] && [ ${#EXTRA_PATHS[@]} -eq 0 ]; then
    usage >&2
    die "nothing selected: use --type and/or give paths"
fi
if [ -z "$sel_types" ] && { [ -n "$PARTICLES" ] || [ ${#MATCHES[@]} -gt 0 ]; }; then
    die "--particle/--match need --type"
fi

# Selection table: "repo|directory|glob" for a (type, particle) pair.
# repo is "main" (fendl-processed) or "endf" (the fendl-endf submodule).
spec_for() {
    local t="$1" p="$2" gp="general-purpose/$2"
    case "$t:$p" in
        ace:neutron|ace:proton|ace:deuteron)                   echo "main|$gp/ace|*" ;;
        njoy:neutron|njoy:proton|njoy:deuteron)                echo "main|$gp/njoy|*" ;;
        njoy-input:neutron|njoy-input:proton|njoy-input:deuteron)    echo "main|$gp/njoy|*.nji" ;;
        njoy-output:neutron|njoy-output:proton|njoy-output:deuteron) echo "main|$gp/njoy|*.out" ;;
        matxs:neutron)                                         echo "main|$gp/group|*.m" ;;
        gendf:neutron)                                         echo "main|$gp/group|*.g" ;;
        gendf:atom)                                            echo "main|$gp/group|*.gam" ;;
        hdf5:neutron|hdf5:atom)                                echo "main|$gp/hdf5|*.h5" ;;
        plots:neutron|plots:proton|plots:deuteron)             echo "main|$gp/plot|*.pdf" ;;
        plots-ps:neutron|plots-ps:proton|plots-ps:deuteron)    echo "main|$gp/plot|*.ps" ;;
        endf:*)                                                echo "endf|$gp|*.endf" ;;
    esac
}

SPECS=()
need_endf=0
for t in $sel_types; do
    found=0
    for p in $sel_particles; do
        s=$(spec_for "$t" "$p")
        if [ -n "$s" ]; then
            SPECS+=("$s"); found=1
            case "$s" in endf\|*) need_endf=1 ;; esac
        elif [ $explicit_particles -eq 1 ]; then
            warn "type '$t' is not available for '$p' -- skipped"
        fi
    done
    [ $found -eq 1 ] || die "type '$t' is not available for the selected particle(s)"
done
for x in ${EXTRA_PATHS[@]+"${EXTRA_PATHS[@]}"}; do
    case "$x" in "$ENDF_SUBMODULE"|"$ENDF_SUBMODULE"/*) need_endf=1 ;; esac
done

# ---------------------------------------------------------------- git-annex
command -v git >/dev/null 2>&1 || die "git is not installed"
ORIG_PATH="$PATH"

annex_hint() {
    cat >&2 <<EOF
Could not install git-annex with pip. The PyPI package provides binaries for
Linux with glibc >= 2.34 (e.g. Ubuntu 22.04+, Debian 12+, RHEL/Rocky 9+) on
x86_64/aarch64 and for macOS >= 15. On other systems install git-annex
yourself and rerun with --system-annex, e.g.:
  macOS (Homebrew):   brew install git-annex
  Debian/Ubuntu:      sudo apt install git-annex
  Fedora/RHEL (EPEL): sudo dnf install git-annex
  conda:              conda install -c conda-forge git-annex
See https://git-annex.branchable.com/install/
EOF
}

find_python() {
    if [ -n "$PYTHON" ]; then command -v "$PYTHON" >/dev/null 2>&1 || die "python '$PYTHON' not found"; return; fi
    for c in python3 python; do
        if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(sys.version_info[0] < 3)' 2>/dev/null; then
            PYTHON="$c"; return
        fi
    done
    die "python3 is not installed"
}

VENV_MARKER=".fendl-get-venv"   # marks venvs created by this script

setup_venv() {
    # Only use a directory that does not exist yet, is empty, or is a venv
    # created by this script: never put files into, or delete, anything else.
    if [ -e "$VENV" ] || [ -L "$VENV" ]; then
        [ -d "$VENV" ] && [ ! -L "$VENV" ] || die "$VENV exists and is not a directory; choose another --venv"
        if [ ! -f "$VENV/$VENV_MARKER" ] && [ -n "$(ls -A "$VENV" 2>/dev/null)" ]; then
            die "$VENV is not empty and was not created by this script; refusing to use it (choose another --venv)"
        fi
    fi
    if [ -f "$VENV/$VENV_MARKER" ] && [ -x "$VENV/bin/git-annex" ] &&
       "$VENV/bin/git-annex" version >/dev/null 2>&1; then
        return 0
    fi
    find_python
    # (Re)create the venv if it is missing or incomplete, e.g. after an
    # interrupted earlier run.
    if [ ! -x "$VENV/bin/python" ] || ! "$VENV/bin/python" -m pip --version >/dev/null 2>&1; then
        local created=0
        if [ ! -e "$VENV" ]; then
            mkdir -- "$VENV" 2>/dev/null || die "cannot create $VENV (does its parent directory exist?)"
            created=1
        fi
        # Mark the directory before filling it, so that an interrupted run
        # is recognised and resumed next time.
        : > "$VENV/$VENV_MARKER"
        msg "Creating Python venv in $VENV"
        if ! "$PYTHON" -m venv "$VENV"; then
            # Clean up only what this script created itself.
            [ $created -eq 1 ] && rm -rf -- "$VENV"
            warn "could not create a venv (on Debian/Ubuntu: sudo apt install python3-venv)"
            return 1
        fi
    fi
    # The pip bundled with older Pythons (e.g. Python 3.9 of the macOS
    # Command Line Tools) may not recognise the platform tags of the
    # git-annex wheels (macosx_15_0, manylinux_2_34), so update it first.
    # --no-cache-dir: leave no pip cache behind in the user's home directory.
    msg "Updating pip in the venv"
    "$VENV/bin/python" -m pip install --quiet --no-cache-dir --disable-pip-version-check \
        "$PIP_PIN_NEW" "$PIP_PIN_OLD" ||
        warn "could not update pip; trying with the existing version"
    msg "Installing git-annex into the venv (pip install $PIP_SPEC)"
    if ! "$VENV/bin/python" -m pip install --quiet --no-cache-dir --disable-pip-version-check "$PIP_SPEC"; then
        return 1
    fi
    "$VENV/bin/git-annex" version >/dev/null 2>&1
}


# ---------------------------------------------------------------- repository
if [ -d "$DIR/.git" ] || [ -f "$DIR/.git" ]; then
    git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || die "$DIR is not a valid git repository"
    # Never modify a repository that is not a clone of fendl-processed
    # (e.g. a project of the user given by mistake as --dir).
    git -C "$DIR" cat-file -e "$ROOT_COMMIT_MAIN^{commit}" 2>/dev/null ||
        die "$DIR is a git repository, but not a clone of fendl-processed; refusing to modify it (choose another --dir)"
    msg "Using existing clone in $DIR"
    if [ $UPDATE -eq 1 ]; then
        msg "Fetching updates"
        git -C "$DIR" fetch --quiet --tags origin
    fi
elif [ -e "$DIR" ] && [ -n "$(ls -A "$DIR" 2>/dev/null)" ]; then
    die "$DIR exists and is not a git repository"
else
    msg "Cloning $REPO_URL into $DIR"
    git clone --quiet "$REPO_URL" "$DIR"
fi
cd "$DIR"
ROOT=$(pwd -P)

# Copies inside the clone would end up as stray files in the repository.
if [ -n "$COPY_TO" ]; then
    [ -d "$COPY_TO" ] && COPY_TO=$(cd "$COPY_TO" && pwd -P)
    case "$COPY_TO/" in
        "$ROOT"/*) die "--copy-to must be a directory outside the clone ($ROOT)" ;;
    esac
fi

latest_release() {
    git tag -l 'FENDL-*' --sort=-creatordate | head -n 1
}

if [ $LIST_RELEASES -eq 1 ]; then
    echo "Default: $DEFAULT_RELEASE"
    echo "Branches:"
    git for-each-ref --format='  %(refname:lstrip=3)' refs/remotes/origin/ |
        grep -v -e '^  HEAD$' -e 'git-annex$'
    echo "Release tags (newest first):"
    git tag -l 'FENDL-*' --sort=-creatordate | sed 's/^/  /'
    exit 0
fi

# ---------------------------------------------------------------- git-annex
# By default the venv lives inside the clone, so that removing the clone
# removes everything this script installed.
[ -n "$VENV" ] || VENV="$(git rev-parse --absolute-git-dir)/$VENV_SUBDIR"
if [ $USE_SYSTEM_ANNEX -eq 1 ]; then
    command -v git-annex >/dev/null 2>&1 || { annex_hint; die "git-annex not found on PATH"; }
elif setup_venv; then
    PATH="$VENV/bin:$PATH"   # makes `git annex` find the venv binary
    export PATH
elif command -v git-annex >/dev/null 2>&1; then
    warn "pip install of git-annex failed; falling back to $(command -v git-annex)"
else
    annex_hint
    die "git-annex is not available"
fi
msg "Using $(git annex version 2>/dev/null | head -n 1) ($(command -v git-annex))"

if [ "$RELEASE" = latest ]; then
    RELEASE=$(latest_release)
    [ -n "$RELEASE" ] || die "no FENDL release tags found"
fi

resolve_ref() {  # prints a commit for tag/branch name, or fails
    # Branches resolve to the remote-tracking ref so that --update moves them.
    git rev-parse -q --verify "refs/tags/$1^{commit}" 2>/dev/null ||
    git rev-parse -q --verify "refs/remotes/origin/$1^{commit}" 2>/dev/null ||
    git rev-parse -q --verify "$1^{commit}" 2>/dev/null
}
if ! commit=$(resolve_ref "$RELEASE"); then
    msg "Release $RELEASE not found locally, fetching"
    git fetch --quiet --tags origin || true
    commit=$(resolve_ref "$RELEASE") ||
        die "unknown release '$RELEASE' (see --list-releases)"
fi

if [ "$(git rev-parse HEAD)" != "$commit" ]; then
    # Refuse to switch if tracked files were modified (annexed files that were
    # downloaded are *not* modifications; they live in .git/annex).
    if ! git diff --quiet HEAD -- 2>/dev/null; then
        die "the clone in $DIR has local modifications; cannot switch to $RELEASE"
    fi
    msg "Checking out $RELEASE"
    git -c advice.detachedHead=false checkout --quiet "$commit"
else
    msg "Release $RELEASE is checked out"
fi

annex_init() {  # annex_init: initialise git-annex in the current repo once
    # git-annex records its state in commits, which fail without a git
    # identity. Many users of this script never commit anything, so set a
    # placeholder in this clone only (an identity configured by the user,
    # globally or via environment variables, takes precedence).
    if ! git var GIT_COMMITTER_IDENT >/dev/null 2>&1 ||
       ! git var GIT_AUTHOR_IDENT >/dev/null 2>&1; then
        git config user.name "fendl-get"
        git config user.email "fendl-get@localhost"
    fi
    if [ -z "$(git config --get annex.uuid 2>/dev/null || true)" ]; then
        # GitHub cannot serve annexed content; skip probing origin for it.
        git config remote.origin.annex-ignore true
        git annex init --quiet "fendl-get@$(hostname 2>/dev/null || echo host)" >/dev/null
    fi
    # Retry transfers interrupted by transient network/S3 errors.
    [ -n "$(git config --get annex.retry 2>/dev/null || true)" ] || git config annex.retry 3
    # Never fill the disk: git-annex refuses downloads that would leave
    # less than this free (its default is only 100 MB).
    [ -n "$(git config --get annex.diskreserve 2>/dev/null || true)" ] ||
        git config annex.diskreserve "2 gigabytes"
}

# Enable a (public, anonymous) S3 special remote in the current repository.
enable_s3_remote() {  # enable_s3_remote "uuid|name|bucket|region"
    local uuid name bucket region out code
    IFS='|' read -r uuid name bucket region <<EOF
$1
EOF
    # public=yes + publicurl let git-annex download anonymously over HTTPS
    # (git-annex 10 manages without, older versions such as 8.x need it).
    # These settings only end up in the local git-annex branch.
    if [ "$(git config --get "remote.$name.annex-uuid" 2>/dev/null || true)" != "$uuid" ] ||
       [ "$(git config --get "remote.$name.fendl-get-public" 2>/dev/null || true)" != true ]; then
        msg "Enabling special remote $name (S3 bucket $bucket)"
        git annex enableremote "$uuid" public=yes \
            "publicurl=https://$bucket.s3.$region.amazonaws.com/" >/dev/null 2>&1 ||
            die "could not enable special remote $name ($uuid)"
        git config "remote.$name.fendl-get-public" true
    fi
    # Remove AWS credentials that git-annex may have stored for this remote
    # in an earlier run (they are not needed and would leak if the clone is
    # shared, e.g. via a synchronised folder).
    rm -f -- "$(git rev-parse --absolute-git-dir)/annex/creds/$uuid"
    # git-annex >= 10.2026 refuses special remotes whose config came from the
    # repository until they are verified. Confirm only if the remote really
    # points to the expected bucket.
    out=$(git annex verifyremote "$name" 2>&1) || return 0   # older git-annex
    code=$(printf '%s\n' "$out" | sed -n 's/.*verifyremote .* --safe \([^ ]*\).*/\1/p' | head -n 1)
    [ -n "$code" ] || return 0                                # already verified
    case "$out" in
        *"bucket=$bucket "*) ;;
        *) printf '%s\n' "$out" >&2
           die "special remote $name does not point to bucket $bucket; refusing to verify it" ;;
    esac
    git annex verifyremote "$name" --safe "$code" >/dev/null 2>&1 ||
        die "could not verify special remote $name"
}

annex_init
enable_s3_remote "$S3_REMOTE_MAIN"

ENDF_ROOT="$ROOT/$ENDF_SUBMODULE"
if [ $need_endf -eq 1 ] || [ -e "$ENDF_ROOT/.git" ]; then
    # Keep the submodule at the commit recorded for this release.
    [ -e "$ENDF_ROOT/.git" ] || msg "Fetching the $ENDF_SUBMODULE submodule (ENDF files)"
    git -c advice.detachedHead=false submodule --quiet update --init -- "$ENDF_SUBMODULE"
    git -C "$ENDF_ROOT" cat-file -e "$ROOT_COMMIT_ENDF^{commit}" 2>/dev/null ||
        die "$ENDF_ROOT is not a clone of fendl-endf; refusing to modify it"
    (cd "$ENDF_ROOT" && annex_init && enable_s3_remote "$S3_REMOTE_ENDF")
fi

# ---------------------------------------------------------------- selection
# Build git-annex matching options for the glob of a spec plus --match globs.
# Globs are matched against the path relative to the repo, and '*' also
# matches '/', hence '*/' to anchor --match globs at the file name.
build_match_opts() {  # sets MATCH_OPTS
    local glob="$1" m first=1
    MATCH_OPTS=("--include=$glob")
    if [ ${#MATCHES[@]} -gt 0 ]; then
        MATCH_OPTS+=("--and" "-(")
        for m in "${MATCHES[@]}"; do
            [ $first -eq 1 ] || MATCH_OPTS+=("--or")
            MATCH_OPTS+=("--include=*/$m")
            first=0
        done
        MATCH_OPTS+=("-)")
    fi
}

# JOBS for git annex: one entry per line "repo|dir|glob"; extra paths are
# turned into entries with glob '*'.
JOBLIST=()
for s in ${SPECS[@]+"${SPECS[@]}"}; do
    repo=${s%%|*}; rest=${s#*|}; d=${rest%%|*}
    base="$ROOT"; [ "$repo" = endf ] && base="$ENDF_ROOT"
    if [ ! -d "$base/$d" ]; then
        warn "$d does not exist in $RELEASE ($repo) -- skipped"
        continue
    fi
    JOBLIST+=("$s")
done
for x in ${EXTRA_PATHS[@]+"${EXTRA_PATHS[@]}"}; do
    x=${x#./}; x=${x%/}
    [ -e "$ROOT/$x" ] || [ -L "$ROOT/$x" ] || die "path not found in repository: $x"
    case "$x" in
        "$ENDF_SUBMODULE")   JOBLIST+=("endf|.|*") ;;
        "$ENDF_SUBMODULE"/*) JOBLIST+=("endf|${x#"$ENDF_SUBMODULE"/}|*") ;;
        *)                   JOBLIST+=("main|$x|*") ;;
    esac
done
[ ${#JOBLIST[@]} -gt 0 ] || die "nothing to do"

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t fendl-get)
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/all"; : > "$TMP/missing"

# Run `git annex <cmd> <match opts> <dir>` for a job in the right repository.
annex_job() {  # annex_job JOB CMD [ARGS...]
    local job="$1" repo rest d glob; shift
    repo=${job%%|*}; rest=${job#*|}; d=${rest%%|*}; glob=${rest#*|}
    build_match_opts "$glob"
    if [ "$repo" = endf ]; then
        (cd "$ENDF_ROOT" && git annex "$@" "${MATCH_OPTS[@]}" -- "$d")
    else
        (cd "$ROOT" && git annex "$@" "${MATCH_OPTS[@]}" -- "$d")
    fi
}
prefix_for() { case "$1" in endf\|*) echo "$ENDF_SUBMODULE/" ;; *) echo "" ;; esac; }

# shellcheck disable=SC2016  # git-annex format variables, not shell ones
FMT='${bytesize}\t${file}\n'
for job in "${JOBLIST[@]}"; do
    pre=$(prefix_for "$job")
    annex_job "$job" find --format="$FMT" | sed "s|	|	$pre|" >> "$TMP/all"
    if [ $DROP -eq 1 ]; then
        annex_job "$job" find --in=here --format="$FMT" | sed "s|	|	$pre|" >> "$TMP/missing"
    else
        annex_job "$job" find --not --in=here --format="$FMT" | sed "s|	|	$pre|" >> "$TMP/missing"
    fi
done
sed -i.bak 's|/\./|/|' "$TMP/all" "$TMP/missing" 2>/dev/null || true

n_all=$(wc -l < "$TMP/all" | tr -d ' ')
n_todo=$(wc -l < "$TMP/missing" | tr -d ' ')
b_all=$(sum_bytes "$TMP/all")
b_todo=$(sum_bytes "$TMP/missing")
[ "$n_all" -gt 0 ] || die "no files match the selection"

if [ $DROP -eq 1 ]; then
    msg "Selected $n_all files ($(human_size "$b_all")); $n_todo present locally ($(human_size "$b_todo")) will be dropped"
else
    msg "Selected $n_all files ($(human_size "$b_all")); to download: $n_todo files ($(human_size "$b_todo"))"
fi

# Free bytes and device of the file system holding a (possibly not yet
# existing) path.
fs_free() { _d=$1; while [ ! -d "$_d" ]; do _d=$(dirname "$_d"); done
            df -Pk "$_d" 2>/dev/null | awk 'NR == 2 { printf "%.0f", $4 * 1024 }'; }
fs_dev()  { _d=$1; while [ ! -d "$_d" ]; do _d=$(dirname "$_d"); done
            df -Pk "$_d" 2>/dev/null | awk 'NR == 2 { print $1 }'; }

# Check that the downloads (and copies) fit, keeping MIN_FREE free.
space_problem=""
if [ $DROP -eq 0 ]; then
    need_clone=$b_todo; need_copy=0
    [ -n "$COPY_TO" ] && need_copy=$b_all
    free_clone=$(fs_free "$ROOT")
    if [ -n "$COPY_TO" ] && [ "$(fs_dev "$COPY_TO")" = "$(fs_dev "$ROOT")" ]; then
        need_clone=$((need_clone + need_copy)); need_copy=0
    fi
    if [ -z "$free_clone" ]; then
        warn "could not determine the free disk space; not checking it"
    elif [ $((need_clone + MIN_FREE)) -gt "$free_clone" ]; then
        space_problem="not enough disk space for $ROOT: $(human_size "$need_clone") needed, $(human_size "$free_clone") available, and $(human_size "$MIN_FREE") are kept free"
    fi
    if [ "$need_copy" -gt 0 ]; then
        free_copy=$(fs_free "$COPY_TO")
        if [ -n "$free_copy" ] && [ $((need_copy + MIN_FREE)) -gt "$free_copy" ]; then
            space_problem="not enough disk space for $COPY_TO: $(human_size "$need_copy") needed, $(human_size "$free_copy") available, and $(human_size "$MIN_FREE") are kept free"
        fi
    fi
fi

if [ $DRY_RUN -eq 1 ]; then
    [ -z "$space_problem" ] || warn "$space_problem"
    if [ "$n_todo" -gt 0 ]; then
        [ $DROP -eq 1 ] && echo "Files that would be dropped:" || echo "Files that would be downloaded:"
        awk -F '\t' '{ print "  " $2 }' "$TMP/missing"
    fi
    exit 0
fi

# ---------------------------------------------------------------- transfer
[ -z "$space_problem" ] || die "$space_problem (choose a smaller selection, see --dry-run, or another --dir)"
status=0
if [ "$n_todo" -gt 0 ]; then
    for job in "${JOBLIST[@]}"; do
        if [ $DROP -eq 1 ]; then
            annex_job "$job" drop || status=1
        else
            annex_job "$job" get --jobs="$JOBS" || status=1
        fi
    done
fi
[ $status -eq 0 ] || die "some files could not be transferred (rerun the same command to retry)"

if [ $DROP -eq 1 ]; then
    msg "Done. Dropped files remain as (broken) symlinks and can be downloaded again."
    exit 0
fi

if [ -n "$COPY_TO" ]; then
    mkdir -p "$COPY_TO" || die "cannot create $COPY_TO"
    msg "Copying $n_all files to $COPY_TO"
    while IFS="$(printf '\t')" read -r _size f; do
        mkdir -p "$COPY_TO/$(dirname "$f")"
        cp -L "$ROOT/$f" "$COPY_TO/$f"
        chmod u+w "$COPY_TO/$f"   # annexed files are read-only
    done < "$TMP/all"
fi

msg "Done. FENDL $RELEASE files are in $ROOT"
msg "(annexed files are read-only symlinks into .git/annex; use --copy-to for plain copies)"
annex_dir=$(dirname "$(command -v git-annex)")
case ":$ORIG_PATH:" in
    *":$annex_dir:"*) ;;
    *) msg "To run git/git-annex commands in the clone yourself, first run:"
       msg "  export PATH=\"$annex_dir:\$PATH\"" ;;
esac
