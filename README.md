# FENDL-Get

FENDL-Get provides scripts to download files of the Fusion Evaluated Nuclear Data Library
(FENDL) from the [fendl-processed] repository with a single command:
ACE files, NJOY input and output files, MATXS and GENDF files,
HDF5 files for OpenMC, verification plots and the ENDF source files.

The files in [fendl-processed] are stored with [git-annex]. These
scripts take care of everything needed to get them:

1. they clone [fendl-processed] (by default into `./fendl-processed`)
   and, if ENDF files are requested, the [fendl-endf] repository,
2. create a Python virtual environment inside the clone and install
   `git-annex` into it with `pip`, so nothing is installed system-wide,
3. check out the requested FENDL version (always to be given
   explicitly, see below), and
4. download the selected files from public storage
   (no account or credentials are needed).

Everything the scripts create is inside the clone folder (plus the
folder given with `--copy-to`, if any), so it can be removed completely
by deleting that folder, see [Removing everything](#removing-everything).

There are two equivalent scripts:

- `fendl-get.sh` for Linux and macOS (requires `bash`, `git` and `python3`),
- `fendl-get.ps1` for Windows (requires [Git for Windows] and [Python] 3,
  works with Windows PowerShell 5.1 and PowerShell 7).

Please take note of the [terms of use] of FENDL.

[fendl-processed]: https://github.com/iaea-nds/fendl-processed
[fendl-endf]: https://github.com/iaea-nds/fendl-endf
[git-annex]: https://git-annex.branchable.com/
[terms of use]: https://github.com/iaea-nds/fendl-processed/blob/main/TERMS_OF_USE.md
[Git for Windows]: https://git-scm.com/download/win
[Python]: https://www.python.org/downloads/


## Linux and macOS

Download the script and make it executable:
```
curl -LO https://raw.githubusercontent.com/iaea-nds/fendl-get/main/fendl-get.sh
chmod +x fendl-get.sh
```
Then choose the FENDL version with `--release` (`-r`), which is
required, select the files with `--type` (`-t`) and, optionally,
the sublibraries with `--particle` (`-p`). Both `--type` and
`--particle` accept comma-separated lists.

**The current development version to be tested by collaborators is
`FENDL-3.2d-T4`**, so the examples below use `-r FENDL-3.2d-T4`.

| Type          | Files                                  | Sublibraries          |
|---------------|----------------------------------------|-----------------------|
| `ace`         | ACE files (including `.xsd` snippets)  | neutron, proton, deuteron |
| `njoy`        | NJOY input and output files            | neutron, proton, deuteron |
| `njoy-input`  | NJOY input files (`.nji`) only         | neutron, proton, deuteron |
| `njoy-output` | NJOY output files (`.out`) only        | neutron, proton, deuteron |
| `matxs`       | MATXS files (`.m`)                     | neutron               |
| `gendf`       | GENDF files (`.g`, `.gam`)             | neutron, atom         |
| `hdf5`        | HDF5 files for OpenMC (`.h5`)          | neutron, atom         |
| `plots`       | verification plots (PDF)               | neutron, proton, deuteron |
| `plots-ps`    | verification plots (PostScript)        | neutron, proton, deuteron |
| `endf`        | ENDF source files                      | neutron, proton, deuteron, atom |
| `all`         | all of the above                       |                       |

Sublibraries can be abbreviated as `n`, `p`, `d` and `a`
(`photon` is accepted as an alias for `atom`, the photo-atomic
sublibrary). Without `--particle`, all sublibraries for which a
type is available are downloaded. The activation sublibraries are
not covered.

Some examples:
```
# ACE files of the neutron sublibrary
./fendl-get.sh -r FENDL-3.2d-T4 -t ace -p neutron

# Check first how much data a selection comprises (nothing is downloaded)
./fendl-get.sh -r FENDL-3.2d-T4 -t ace,hdf5 --dry-run

# ENDF files and NJOY input files for the iron isotopes. ENDF files
# (n_2631_26-Fe-56.endf) and processed files (26Fe056) follow different
# naming schemes, hence the two --match patterns.
./fendl-get.sh -r FENDL-3.2d-T4 -t endf,njoy-input -p n -m '*Fe-*' -m '26Fe*'

# Single files, given as paths inside the repository
./fendl-get.sh -r FENDL-3.2d-T4 general-purpose/neutron/ace/26Fe056 \
    fendl-endf/general-purpose/neutron/n_2631_26-Fe-56.endf

# Neutron ACE files as regular files in the directory ./ace-lib
./fendl-get.sh -r FENDL-3.2d-T4 -t ace -p n --copy-to ./ace-lib

# ACE files of another release
./fendl-get.sh --list-releases
./fendl-get.sh -r FENDL-3.2c -t ace
```

`-r` (`--release`) accepts a git tag such as `FENDL-3.2d-T4` or
`FENDL-3.2c`, a branch such as `main`, `latest` for the newest
`FENDL-*` tag, or any other git revision of [fendl-processed], e.g. a
full or abbreviated commit id. The ENDF files are always taken from the
[fendl-endf] commit that the selected fendl-processed commit refers to.

Running the script again with the same or a different selection reuses
the existing clone and venv and only downloads files that are not yet
present. Other useful options are `--jobs N` (number of parallel
downloads, default 4), `--update` (fetch the latest state of the
repository), `--drop` (remove the downloaded content of the selected
files again to free disk space) and `--dir DIR` (location of the clone).
See `./fendl-get.sh --help` for all options.

A few things to keep in mind:

- Downloaded files appear in the clone as read-only symbolic links
  into `.git/annex`. If you need regular files, e.g. to move them
  elsewhere, use `--copy-to`.
- The venv with git-annex (about 110 MB) is created inside the clone,
  in `fendl-processed/.git/fendl-get-venv`. If you want to run `git` or
  `git annex` commands in the clone yourself, put its `git-annex` on
  your `PATH` first, as indicated at the end of the script output, e.g.
  `export PATH="$PWD/fendl-processed/.git/fendl-get-venv/bin:$PATH"`.
- `--copy-to` overwrites files with the same names in the target folder,
  which must be outside the clone.
- Before downloading, the script checks that the files fit on the disk
  and refuses if fewer than 2 GB would remain free (git-annex is set up
  to keep the same reserve). `--dry-run` shows the size of a selection.
- AWS credentials in your environment (`AWS_ACCESS_KEY_ID` etc.) are
  ignored: the files are public, and git-annex would otherwise use the
  credentials and store them in the clone.
- An existing folder given as `--dir` is only used if it is a clone made
  by the script, or a plain `git clone` of fendl-processed. Clones that
  someone set up with git-annex themselves (e.g. a maintainer's clone
  with S3 credentials) are left alone; use `git annex get` in them
  directly. Git environment variables such as `GIT_DIR` are ignored, so
  that the script cannot act on another repository by mistake.
- If a run is interrupted (e.g. with Ctrl-C), simply run the same
  command again; it continues where it stopped.
- The `git-annex` package on PyPI provides binaries for Linux with
  glibc 2.34 or newer (e.g. Ubuntu 22.04+, Debian 12+, RHEL 9+) and
  for macOS 15 or newer. On other systems, [install git-annex] yourself,
  e.g. with `brew install git-annex`, `apt install git-annex` or
  `conda install -c conda-forge git-annex`. The script then falls back
  to the system installation automatically (or use `--system-annex`).

[install git-annex]: https://git-annex.branchable.com/install/


## Windows

Download the PowerShell script and run it:
```
curl.exe -LO https://raw.githubusercontent.com/iaea-nds/fendl-get/main/fendl-get.ps1
powershell -ExecutionPolicy Bypass -File .\fendl-get.ps1 -Release FENDL-3.2d-T4 -Type ace -Particle neutron
```
(`-ExecutionPolicy Bypass` is only needed if running scripts is
disabled on your system.) The options correspond to those of
`fendl-get.sh` described above, e.g. `-Release` (required), `-Type`,
`-Particle`, `-Match`, `-DryRun`, `-Drop`, `-CopyTo` and `-Jobs`, and lists are
separated by commas:
```
.\fendl-get.ps1 -Release FENDL-3.2d-T4 -Type endf,njoy-input -Particle n -Match '*Fe-*,26Fe*'
.\fendl-get.ps1 -Release FENDL-3.2d-T4 -Type ace,hdf5 -DryRun
```
Run `Get-Help .\fendl-get.ps1 -Detailed` for all options.

Differences from `fendl-get.sh`:

- The script does not use symbolic links on Windows, so the files
  appear as regular files in the clone (git-annex "unlocked" mode).
  Files that have not been downloaded yet are small placeholder files.
  Downloaded content is stored twice (in `.git\annex` and in the
  working tree), so plan for twice the disk space of the files you
  download (the disk-space check accounts for this).
- The ENDF files are cloned as a separate repository into the
  `fendl-endf` folder (instead of as a git submodule), because
  git-annex replaces the `.git` file of a submodule by a symbolic
  link, which is usually not possible on Windows.
- The venv with git-annex is created in `fendl-processed\.git\fendl-get-venv`.

If you use the [Windows Subsystem for Linux][WSL], you can also run
`fendl-get.sh` inside WSL.

[WSL]: https://learn.microsoft.com/windows/wsl/


## Removing everything

The scripts do not change any settings or files outside the clone
folder (and the `--copy-to` folder). To remove everything, including
the venv with git-annex and all downloaded files, delete the clone
folder. git-annex write-protects downloaded files, so a plain `rm -rf`
fails; use instead

- on Linux and macOS:
  ```
  chmod -R u+w fendl-processed && rm -rf fendl-processed
  ```
- on Windows (PowerShell):
  ```
  Remove-Item -Recurse -Force .\fendl-processed
  ```

To free disk space but keep the clone, use `--drop` (`-Drop`) instead.


## Development

The scripts hard-code the layout of [fendl-processed] (directories
and file extensions per file type) and the git-annex special remotes
holding the files. If a FENDL release changes the layout or the
storage, both scripts need to be updated.

The versions of `git-annex` and `pip` installed into the venv are
pinned in both scripts to the versions tested in CI. To try a newer
git-annex release, set the environment variable
`FENDL_GET_PIP_SPEC=git-annex` (or e.g. `git-annex==<version>`); the
weekly CI run does this in a separate job. If it passes, update the
pins in both scripts.

End-to-end tests clone the repository into a temporary directory,
download a few small files and verify them against their git-annex
checksums:
```
./tests/test-fendl-get.sh                      # bash script
TEST_BASH=/bin/bash ./tests/test-fendl-get.sh  # e.g. bash 3.2 on macOS
TEST_ARGS=--system-annex ./tests/test-fendl-get.sh

pwsh ./tests/test-fendl-get.ps1                # PowerShell script
$env:TEST_SHELL = 'powershell'; ./tests/test-fendl-get.ps1   # Windows PowerShell 5.1
```
The tests need network access. They also check that wrong arguments
(e.g. an unrelated repository or a git-annex clone set up by someone else
as `--dir`, a non-empty folder as `--venv`) are refused without changing
anything, that `GIT_DIR` in the environment does not redirect the script, that AWS credentials in the
environment are ignored, that an interrupted venv installation is
repaired, that downloads which do not fit on the disk are refused, that
the clone can be removed with the commands given above, and that
nothing changed in the home directory and the global git config. They run in GitHub Actions on
Linux, macOS and Windows for every push and weekly, to notice breakage
caused by external changes (new git-annex releases, storage, GitHub).


## License

The scripts and tests in this repository are distributed under the MIT
license augmented by an IAEA clause, see the accompanying
[license file](LICENSE) for more information. This license does not
apply to the nuclear data that the scripts download: for these, see
`TERMS_OF_USE.md` in [fendl-processed].

Copyright (c) 2026 International Atomic Energy Agency (IAEA)

## Use of AI assistance

The scripts, the tests, the GitHub Actions workflow and this README were
written with substantial AI coding assistance (Claude Opus 5.5 by
Anthropic, used through Claude Code). The maintainer specified the
requirements, made the design decisions, directed the safety reviews
and checked the results. The scripts are tested automatically on Linux,
macOS and Windows (see [Development](#development)). Please report any
problem as an issue in this repository.
