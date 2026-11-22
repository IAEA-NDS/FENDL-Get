<#
.SYNOPSIS
    Download files of the Fusion Evaluated Nuclear Data Library (FENDL)
    from https://github.com/iaea-nds/fendl-processed with git-annex.

.DESCRIPTION
    PowerShell counterpart of fendl-get.sh, primarily for Windows users
    (works with Windows PowerShell 5.1 and PowerShell 7 on any OS).

    The script
      1. installs git-annex into an isolated Python venv (via pip),
      2. clones the repository (and the fendl-endf repository with the ENDF
         files if needed),
      3. checks out the requested FENDL release, and
      4. downloads the requested file types with `git annex get`.

    Unlike fendl-get.sh, the files appear as regular files in the clone
    (git-annex "unlocked" mode), because symbolic links are usually not
    available on Windows. Downloaded content is therefore stored twice on
    disk (in .git\annex and in the working tree).

    Requirements: Git for Windows (https://git-scm.com) and Python 3
    (https://www.python.org).

.PARAMETER Type
    File types to download (comma-separated or array):
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

.PARAMETER Particle
    Sublibraries: neutron, proton, deuteron, atom (or n, p, d, a; photon is
    an alias for atom). Default: all that apply to the selected types.

.PARAMETER Match
    Only files whose name matches one of these wildcard patterns, e.g.
    '26Fe*' for processed files or '*Fe-56*' for ENDF files.

.PARAMETER Path
    Additional paths inside the repository to download, e.g.
    general-purpose/neutron/ace/26Fe056 (can be given positionally).

.PARAMETER Release
    FENDL release (git branch or tag) to check out, e.g. FENDL-3.2c, or
    'latest' for the newest FENDL-* tag. Default: fendl32d_prep.

.PARAMETER Dir
    Where to clone the repository (default: .\fendl-processed). An existing
    clone created by this script is reused.

.PARAMETER Update
    Fetch the newest commits/tags of an existing clone.

.PARAMETER ListReleases
    Show available releases and exit.

.PARAMETER DryRun
    Only show what would be downloaded and how big it is.

.PARAMETER Drop
    Remove the local content of the selected files again (they can be
    downloaded again at any time).

.PARAMETER CopyTo
    After downloading, also copy the selected files into this directory,
    keeping the directory structure.

.PARAMETER Jobs
    Number of parallel downloads (default: 4).

.PARAMETER Venv
    Location of the Python venv with git-annex
    (default: %LOCALAPPDATA%\fendl-get\venv on Windows,
    ~/.local/share/fendl-get/venv elsewhere).

.PARAMETER SystemAnnex
    Use the git-annex found on PATH instead of a venv.

.EXAMPLE
    .\fendl-get.ps1 -Type ace -Particle neutron
    ACE files of the neutron sublibrary.

.EXAMPLE
    .\fendl-get.ps1 -Type endf,njoy-input -Particle n -Match '*Fe-*','26Fe*'
    ENDF and NJOY input files for the iron isotopes (ENDF and processed files
    use different naming schemes, hence two patterns).

.EXAMPLE
    .\fendl-get.ps1 -Type ace -Particle p,d -DryRun
    Show how much data the proton and deuteron ACE files comprise.

.EXAMPLE
    .\fendl-get.ps1 -Release FENDL-3.2b -Type ace
    ACE files of the FENDL-3.2b release.

.NOTES
    If script execution is disabled on your system, run the script with
      powershell -ExecutionPolicy Bypass -File .\fendl-get.ps1 ...
    Files are downloaded anonymously from public Amazon S3 buckets (and, for
    older releases, from the IAEA-NDS web server). Please note the terms of
    use in TERMS_OF_USE.md of the repository.

.LINK
    https://github.com/iaea-nds/fendl-get
#>
[CmdletBinding()]
param(
    [string[]]$Type = @(),
    [string[]]$Particle = @(),
    [string[]]$Match = @(),
    [string]$Release = 'fendl32d_prep',
    [string]$Dir = 'fendl-processed',
    [int]$Jobs = 4,
    [string]$CopyTo = '',
    [string]$Venv = '',
    [switch]$SystemAnnex,
    [switch]$DryRun,
    [switch]$Drop,
    [switch]$Update,
    [switch]$ListReleases,
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Path = @()
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- settings
$RepoUrl = 'https://github.com/iaea-nds/fendl-processed'
$EndfSubdir = 'fendl-endf'
$DefaultRelease = 'fendl32d_prep'
$LocalBranchPrefix = 'fendl-get/'
$PipSpec = if ($env:FENDL_GET_PIP_SPEC) { $env:FENDL_GET_PIP_SPEC } else { 'git-annex' }

# Public S3 special remotes, addressed by UUID because the name
# fendl-proc-aws-s3 is registered twice in fendl-processed.
$S3Main = @{ Uuid = '4737e67e-3733-4035-8715-a2747c323879'; Name = 'fendl-proc-aws-s3'
             Bucket = 'fendl-processing-storage'; Region = 'eu-north-1' }
$S3Endf = @{ Uuid = '2cf4d611-eca6-4062-9bb9-ac099534b9e3'; Name = 'fendl-endf-aws-s3'
             Bucket = 'fendl-endf-storage'; Region = 'eu-north-1' }

$AllTypes = @('ace', 'njoy', 'njoy-input', 'njoy-output', 'matxs', 'gendf',
              'hdf5', 'plots', 'plots-ps', 'endf')
$AllParticles = @('neutron', 'proton', 'deuteron', 'atom')

$OnWindows = [System.IO.Path]::DirectorySeparatorChar -eq '\'

# ---------------------------------------------------------------- helpers
function Write-Msg([string]$Text) { Write-Host "==> $Text" }
function Write-Warn([string]$Text) { Write-Host "WARNING: $Text" -ForegroundColor Yellow }
function Fail([string]$Text) {
    Write-Host "ERROR: $Text" -ForegroundColor Red
    exit 1
}

# Run a native command, letting its output go to the console. Returns $true
# on exit code 0. (Windows PowerShell 5.1 turns stderr output of native
# commands into errors when $ErrorActionPreference is 'Stop'; avoid that.)
function Invoke-Native([string]$Exe, [string[]]$Arguments, [switch]$Quiet) {
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Quiet) { & $Exe @Arguments 2>&1 | Out-Null }
        else { & $Exe @Arguments | Out-Host }
        return ($LASTEXITCODE -eq 0)
    } finally { $ErrorActionPreference = $eap }
}

# Run a native command and return its stdout lines (stderr is merged when
# -Merge is given). Sets $script:NativeOk to whether it succeeded.
function Get-NativeOutput([string]$Exe, [string[]]$Arguments, [switch]$Merge) {
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Merge) { $out = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" } }
        else { $out = & $Exe @Arguments 2>$null }
        $script:NativeOk = ($LASTEXITCODE -eq 0)
        # The comma keeps an empty/one-element result an array for the caller.
        if ($null -eq $out) { return , @() }
        return , @($out)
    } finally { $ErrorActionPreference = $eap }
}

function Invoke-Git([string[]]$Arguments) { Invoke-Native 'git' $Arguments }
function Invoke-GitQuiet([string[]]$Arguments) { Invoke-Native 'git' $Arguments -Quiet }
function Get-GitOutput([string[]]$Arguments) { Get-NativeOutput 'git' $Arguments }
function Get-GitConfig([string]$Repo, [string]$Key) {
    $v = Get-GitOutput @('-C', $Repo, 'config', '--get', $Key)
    if ($v.Count -gt 0) { return [string]$v[0] } else { return '' }
}

function Format-Size([double]$Bytes) {
    $units = @('bytes', 'kB', 'MB', 'GB', 'TB')
    $i = 0
    while ($Bytes -ge 1000 -and $i -lt 4) { $Bytes /= 1000; $i++ }
    if ($i -eq 0) { return ('{0} {1}' -f [int64]$Bytes, $units[$i]) }
    return ('{0:N2} {1}' -f $Bytes, $units[$i])
}

# Split comma-separated values. (With `powershell -File`, `-Type ace,endf`
# arrives as the single string 'ace,endf'.)
# Absolute path relative to the PowerShell location (which, unlike the .NET
# current directory, follows Set-Location). Rooted paths are kept as they are.
function Resolve-FullPath([string]$p) {
    return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine((Get-Location).ProviderPath, $p))
}

function Split-List([string[]]$Items, [switch]$KeepCase) {
    $r = @()
    foreach ($it in $Items) {
        foreach ($x in ($it -split ',')) {
            $x = $x.Trim()
            if (-not $KeepCase) { $x = $x.ToLowerInvariant() }
            if ($x) { $r += $x }
        }
    }
    return , $r
}

# ---------------------------------------------------------------- arguments
if ($Jobs -lt 1) { Fail '-Jobs expects a positive integer' }
if ($Drop -and $CopyTo) { Fail '-Drop and -CopyTo cannot be combined' }
if ($CopyTo) { $CopyTo = Resolve-FullPath $CopyTo }
if ($Release -eq '') { $Release = $DefaultRelease }
$Match = Split-List $Match -KeepCase
$Path = Split-List $Path -KeepCase

$selTypes = @()
foreach ($t in (Split-List $Type)) {
    if ($t -eq 'all') { $selTypes = @('ace', 'njoy', 'matxs', 'gendf', 'hdf5', 'plots', 'plots-ps', 'endf'); break }
    if ($AllTypes -notcontains $t) { Fail "unknown type '$t' (valid: $($AllTypes -join ' ') all)" }
    if ($selTypes -notcontains $t) { $selTypes += $t }
}

$selParticles = @()
$explicitParticles = $false
foreach ($p in (Split-List $Particle)) {
    $explicitParticles = $true
    switch -Regex ($p) {
        '^(n|neutrons?)$'       { $p = 'neutron'; break }
        '^(p|protons?)$'        { $p = 'proton'; break }
        '^(d|deuterons?)$'      { $p = 'deuteron'; break }
        '^(a|atom|photo|photons?)$' { $p = 'atom'; break }
        '^all$'                 { $p = ''; $selParticles = $AllParticles; break }
        default                 { Fail "unknown particle '$p' (valid: $($AllParticles -join ' '))" }
    }
    if ($p -and ($selParticles -notcontains $p)) { $selParticles += $p }
}
if ($selParticles.Count -eq 0) { $selParticles = $AllParticles }

if (-not $ListReleases -and $selTypes.Count -eq 0 -and $Path.Count -eq 0) {
    Write-Host "Usage: .\fendl-get.ps1 -Type <types> [-Particle <particles>] [options] [paths]"
    Write-Host "       Get-Help .\fendl-get.ps1 -Detailed   for all options"
    Fail 'nothing selected: use -Type and/or give paths'
}
if ($selTypes.Count -eq 0 -and ($Particle.Count -gt 0 -or $Match.Count -gt 0)) {
    Fail '-Particle/-Match need -Type'
}

# Selection table: repo ('main' or 'endf'), directory, glob.
function Get-Spec([string]$t, [string]$p) {
    $gp = "general-purpose/$p"
    $npd = @('neutron', 'proton', 'deuteron') -contains $p
    switch ($t) {
        'ace'         { if ($npd) { return @('main', "$gp/ace", '*') } }
        'njoy'        { if ($npd) { return @('main', "$gp/njoy", '*') } }
        'njoy-input'  { if ($npd) { return @('main', "$gp/njoy", '*.nji') } }
        'njoy-output' { if ($npd) { return @('main', "$gp/njoy", '*.out') } }
        'matxs'       { if ($p -eq 'neutron') { return @('main', "$gp/group", '*.m') } }
        'gendf'       { if ($p -eq 'neutron') { return @('main', "$gp/group", '*.g') }
                        if ($p -eq 'atom') { return @('main', "$gp/group", '*.gam') } }
        'hdf5'        { if ($p -eq 'neutron' -or $p -eq 'atom') { return @('main', "$gp/hdf5", '*.h5') } }
        'plots'       { if ($npd) { return @('main', "$gp/plot", '*.pdf') } }
        'plots-ps'    { if ($npd) { return @('main', "$gp/plot", '*.ps') } }
        'endf'        { return @('endf', $gp, '*.endf') }
    }
    return $null
}

$specs = New-Object System.Collections.ArrayList
$needEndf = $false
foreach ($t in $selTypes) {
    $found = $false
    foreach ($p in $selParticles) {
        $s = Get-Spec $t $p
        if ($null -ne $s) {
            [void]$specs.Add($s); $found = $true
            if ($s[0] -eq 'endf') { $needEndf = $true }
        } elseif ($explicitParticles) {
            Write-Warn "type '$t' is not available for '$p' -- skipped"
        }
    }
    if (-not $found) { Fail "type '$t' is not available for the selected particle(s)" }
}
$extraPaths = @()
foreach ($x in $Path) {
    $x = ($x -replace '\\', '/') -replace '^\./', ''
    $x = $x.TrimEnd('/')
    if ($x -eq $EndfSubdir -or $x.StartsWith("$EndfSubdir/")) { $needEndf = $true }
    $extraPaths += $x
}

# ---------------------------------------------------------------- git-annex
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Fail 'git is not installed (Windows: https://git-scm.com/download/win)'
}

function Show-AnnexHint {
    Write-Host @'
Could not install git-annex with pip. The PyPI package provides binaries for
Windows (x86_64), Linux with glibc >= 2.34 and macOS >= 15. Otherwise install
git-annex yourself and rerun with -SystemAnnex, e.g.:
  Windows:  installer from https://git-annex.branchable.com/install/Windows/
  conda:    conda install -c conda-forge git-annex
  macOS:    brew install git-annex
See https://git-annex.branchable.com/install/
'@
}

function Find-Python {
    $candidates = @()
    if ($env:PYTHON) { $candidates += , @($env:PYTHON) }
    if ($OnWindows) { $candidates += , @('py', '-3') }
    $candidates += , @('python3')
    $candidates += , @('python')
    foreach ($c in $candidates) {
        if (-not (Get-Command $c[0] -ErrorAction SilentlyContinue)) { continue }
        $rest = @()
        if ($c.Count -gt 1) { $rest = $c[1..($c.Count - 1)] }
        # The Microsoft Store "python" alias exists but fails; test it.
        $v = Get-NativeOutput $c[0] ($rest + @('-c', 'import sys; print(sys.version_info[0])'))
        if ($script:NativeOk -and $v.Count -gt 0 -and "$($v[0])".Trim() -eq '3') { return , $c }
    }
    return $null
}

if (-not $Venv) {
    if ($OnWindows) { $Venv = Join-Path $env:LOCALAPPDATA 'fendl-get\venv' }
    else {
        $dataHome = if ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } else { Join-Path $HOME '.local/share' }
        $Venv = Join-Path $dataHome 'fendl-get/venv'
    }
}
$VenvBin = if ($OnWindows) { Join-Path $Venv 'Scripts' } else { Join-Path $Venv 'bin' }
$VenvPython = if ($OnWindows) { Join-Path $VenvBin 'python.exe' } else { Join-Path $VenvBin 'python' }
$VenvAnnex = if ($OnWindows) { Join-Path $VenvBin 'git-annex.exe' } else { Join-Path $VenvBin 'git-annex' }

function Install-VenvAnnex {
    if ((Test-Path $VenvAnnex) -and (Invoke-Native $VenvAnnex @('version') -Quiet)) { return $true }
    if (-not (Test-Path $VenvPython)) {
        $py = Find-Python
        if ($null -eq $py) { Write-Warn 'Python 3 not found (https://www.python.org/downloads/)'; return $false }
        Write-Msg "Creating Python venv in $Venv"
        New-Item -ItemType Directory -Force -Path (Split-Path $Venv -Parent) | Out-Null
        $rest = @()
        if ($py.Count -gt 1) { $rest = $py[1..($py.Count - 1)] }
        if (-not (Invoke-Native $py[0] ($rest + @('-m', 'venv', $Venv)))) {
            Remove-Item -Recurse -Force $Venv -ErrorAction SilentlyContinue
            Write-Warn 'could not create a Python venv'
            return $false
        }
    }
    # Old bundled pip versions may not know the platform tags of the wheels.
    Write-Msg 'Upgrading pip in the venv'
    if (-not (Invoke-Native $VenvPython @('-m', 'pip', 'install', '--quiet', '--disable-pip-version-check', '--upgrade', 'pip'))) {
        Write-Warn 'could not upgrade pip; trying with the existing version'
    }
    Write-Msg "Installing git-annex into the venv (pip install $PipSpec)"
    if (-not (Invoke-Native $VenvPython @('-m', 'pip', 'install', '--quiet', '--disable-pip-version-check', $PipSpec))) {
        return $false
    }
    return (Invoke-Native $VenvAnnex @('version') -Quiet)
}

$origPath = $env:PATH
if ($SystemAnnex) {
    if (-not (Get-Command git-annex -ErrorAction SilentlyContinue)) { Show-AnnexHint; Fail 'git-annex not found on PATH' }
} elseif (Install-VenvAnnex) {
    $env:PATH = $VenvBin + [System.IO.Path]::PathSeparator + $env:PATH   # lets `git annex` find it
} elseif (Get-Command git-annex -ErrorAction SilentlyContinue) {
    Write-Warn "pip install of git-annex failed; falling back to $((Get-Command git-annex).Source)"
} else {
    Show-AnnexHint
    Fail 'git-annex is not available'
}
$annexVersion = (Get-GitOutput @('annex', 'version', '--raw'))
if ($annexVersion.Count -eq 0) { $annexVersion = @('?') }
Write-Msg "Using git-annex $($annexVersion[0]) ($((Get-Command git-annex).Source))"

# ---------------------------------------------------------------- repository
$Root = Resolve-FullPath $Dir
$EndfRoot = Join-Path $Root $EndfSubdir

function Test-GitRepo([string]$d) { return (Test-Path (Join-Path $d '.git')) }

if (Test-GitRepo $Root) {
    Write-Msg "Using existing clone in $Root"
    if ($Update) {
        Write-Msg 'Fetching updates'
        if (-not (Invoke-Git @('-C', $Root, 'fetch', '--quiet', '--tags', 'origin'))) { Fail 'git fetch failed' }
    }
} elseif ((Test-Path $Root) -and @(Get-ChildItem -Force $Root).Count -gt 0) {
    Fail "$Root exists and is not a git repository"
} else {
    Write-Msg "Cloning $RepoUrl into $Root"
    if (-not (Invoke-Git @('-c', 'core.longpaths=true', 'clone', '--quiet', '--no-checkout', $RepoUrl, $Root))) {
        Fail 'git clone failed'
    }
}
# Annexed object paths are long; avoid the 260 character limit on Windows.
Invoke-GitQuiet @('-C', $Root, 'config', 'core.longpaths', 'true') | Out-Null
# On Windows, let git write symbolic links as plain files from the first
# checkout on. git-annex replaces them by regular files in unlocked mode
# anyway, and when symlinks are enabled (e.g. Developer Mode), Git for
# Windows may resolve the relative targets of annexed files to a wrong
# directory, after which the checkout fails with "unable to stat
# just-written file ...: Result too large".
if ($OnWindows) { Invoke-GitQuiet @('-C', $Root, 'config', 'core.symlinks', 'false') | Out-Null }

if ($ListReleases) {
    Write-Host "Default: $DefaultRelease"
    Write-Host 'Branches:'
    (Get-GitOutput @('-C', $Root, 'for-each-ref', '--format=%(refname:lstrip=3)', 'refs/remotes/origin/')) |
        Where-Object { $_ -ne 'HEAD' -and $_ -notmatch 'git-annex$' } | ForEach-Object { Write-Host "  $_" }
    Write-Host 'Release tags (newest first):'
    (Get-GitOutput @('-C', $Root, 'tag', '-l', 'FENDL-*', '--sort=-creatordate')) | ForEach-Object { Write-Host "  $_" }
    exit 0
}

if ($Release -eq 'latest') {
    $tags = Get-GitOutput @('-C', $Root, 'tag', '-l', 'FENDL-*', '--sort=-creatordate')
    if ($tags.Count -eq 0) { Fail 'no FENDL release tags found' }
    $Release = [string]$tags[0]
}

function Resolve-Ref([string]$Repo, [string]$Ref) {
    foreach ($r in @("refs/tags/$Ref^{commit}", "refs/remotes/origin/$Ref^{commit}", "$Ref^{commit}")) {
        $c = Get-GitOutput @('-C', $Repo, 'rev-parse', '-q', '--verify', $r)
        if ($script:NativeOk -and $c.Count -gt 0) { return [string]$c[0] }
    }
    return ''
}

$commit = Resolve-Ref $Root $Release
if (-not $commit) {
    Write-Msg "Release $Release not found locally, fetching"
    Invoke-Git @('-C', $Root, 'fetch', '--quiet', '--tags', 'origin') | Out-Null
    $commit = Resolve-Ref $Root $Release
    if (-not $commit) { Fail "unknown release '$Release' (see -ListReleases)" }
}

function Initialize-Annex([string]$Repo) {
    # git-annex records its state in commits, which fail without a git
    # identity. Many users of this script never commit anything, so set a
    # placeholder in this clone only (an identity configured by the user,
    # globally or via environment variables, takes precedence).
    if (-not (Invoke-GitQuiet @('-C', $Repo, 'var', 'GIT_COMMITTER_IDENT')) -or
        -not (Invoke-GitQuiet @('-C', $Repo, 'var', 'GIT_AUTHOR_IDENT'))) {
        Invoke-GitQuiet @('-C', $Repo, 'config', 'user.name', 'fendl-get') | Out-Null
        Invoke-GitQuiet @('-C', $Repo, 'config', 'user.email', 'fendl-get@localhost') | Out-Null
    }
    if (-not (Get-GitConfig $Repo 'annex.uuid')) {
        # GitHub cannot serve annexed content; skip probing origin for it.
        Invoke-GitQuiet @('-C', $Repo, 'config', 'remote.origin.annex-ignore', 'true') | Out-Null
        $hostName = [System.Environment]::MachineName
        if (-not (Invoke-GitQuiet @('-C', $Repo, 'annex', 'init', '--quiet', "fendl-get@$hostName"))) {
            Fail "git annex init failed in $Repo"
        }
    }
    if (-not (Get-GitConfig $Repo 'annex.retry')) {
        Invoke-GitQuiet @('-C', $Repo, 'config', 'annex.retry', '3') | Out-Null
    }
}

# Check out $Commit on the local branch fendl-get/<release> and switch to the
# git-annex adjusted (unlocked) branch, so that files are regular files.
function Switch-Release([string]$Repo, [string]$Commit, [string]$Label) {
    $branch = "$LocalBranchPrefix$Release"
    $adjusted = "adjusted/$branch(unlocked)"
    $current = Get-GitOutput @('-C', $Repo, 'symbolic-ref', '--short', '-q', 'HEAD')
    $current = if ($current.Count -gt 0) { [string]$current[0] } else { '' }
    $basis = Get-GitOutput @('-C', $Repo, 'rev-parse', '-q', '--verify', "refs/heads/$branch")
    $basis = if ($basis.Count -gt 0) { [string]$basis[0] } else { '' }
    if ($current -eq $adjusted -and $basis -eq $Commit) { return $false }

    # (Skipped right after `clone --no-checkout`, when there is no index yet.)
    if (Test-Path (Join-Path $Repo '.git/index')) {
        if (-not (Invoke-GitQuiet @('-C', $Repo, 'diff', '--quiet', '--ignore-submodules=all', 'HEAD', '--'))) {
            Fail "$Repo has local modifications; cannot switch to $Release"
        }
    }
    Write-Msg "Checking out $Release$Label"
    if (-not (Invoke-Git @('-C', $Repo, '-c', 'advice.detachedHead=false', 'checkout', '--quiet', '-B', $branch, $Commit))) {
        Fail "git checkout of $Release failed in $Repo"
    }
    Initialize-Annex $Repo
    $current = Get-GitOutput @('-C', $Repo, 'symbolic-ref', '--short', '-q', 'HEAD')
    if ($current.Count -eq 0 -or [string]$current[0] -ne $adjusted) {
        # (git-annex enters an adjusted branch on its own on Windows.)
        # An adjusted branch left from an earlier checkout of this release is
        # stale; we never commit on it, so it can simply be recreated.
        if ((Get-GitOutput @('-C', $Repo, 'rev-parse', '-q', '--verify', "refs/heads/$adjusted")).Count -gt 0) {
            Invoke-GitQuiet @('-C', $Repo, 'branch', '-D', $adjusted) | Out-Null
        }
        if (-not (Invoke-GitQuiet @('-C', $Repo, 'annex', 'adjust', '--unlock'))) {
            Fail "git annex adjust --unlock failed in $Repo"
        }
    }
    return $true
}

function Enable-S3Remote([string]$Repo, [hashtable]$R) {
    $name = $R.Name
    if ((Get-GitConfig $Repo "remote.$name.annex-uuid") -ne $R.Uuid -or
        (Get-GitConfig $Repo "remote.$name.fendl-get-public") -ne 'true') {
        Write-Msg "Enabling special remote $name (S3 bucket $($R.Bucket))"
        $url = "https://$($R.Bucket).s3.$($R.Region).amazonaws.com/"
        if (-not (Invoke-GitQuiet @('-C', $Repo, 'annex', 'enableremote', $R.Uuid, 'public=yes', "publicurl=$url"))) {
            Fail "could not enable special remote $name ($($R.Uuid))"
        }
        Invoke-GitQuiet @('-C', $Repo, 'config', "remote.$name.fendl-get-public", 'true') | Out-Null
    }
    # git-annex >= 10.2026 requires special remotes configured in the
    # repository to be verified. Confirm only for the expected bucket.
    $out = (Get-NativeOutput 'git' @('-C', $Repo, 'annex', 'verifyremote', $name) -Merge) -join "`n"
    if (-not $script:NativeOk) { return }            # older git-annex
    $m = [regex]::Match($out, 'verifyremote \S+ --safe (\S+)')
    if (-not $m.Success) { return }                   # already verified
    if ($out -notmatch [regex]::Escape("bucket=$($R.Bucket) ")) {
        Write-Host $out
        Fail "special remote $name does not point to bucket $($R.Bucket); refusing to verify it"
    }
    if (-not (Invoke-GitQuiet @('-C', $Repo, 'annex', 'verifyremote', $name, '--safe', $m.Groups[1].Value))) {
        Fail "could not verify special remote $name"
    }
}

if (-not (Switch-Release $Root $commit '')) { Write-Msg "Release $Release is checked out" }
Enable-S3Remote $Root $S3Main

# The ENDF files live in the fendl-endf repository, registered as a git
# submodule. It is cloned as a standalone repository at the commit recorded
# for the release, because git-annex needs symlinks to work in submodules.
if ($needEndf -or (Test-GitRepo $EndfRoot)) {
    $endfCommit = Get-GitOutput @('-C', $Root, 'rev-parse', "HEAD:$EndfSubdir")
    if ($endfCommit.Count -eq 0) { Fail "$EndfSubdir is not part of release $Release" }
    $endfCommit = [string]$endfCommit[0]
    if (-not (Test-GitRepo $EndfRoot)) {
        $endfUrl = Get-GitOutput @('-C', $Root, 'config', '-f', '.gitmodules', "submodule.$EndfSubdir.url")
        if ($endfUrl.Count -eq 0) { Fail "no URL for $EndfSubdir in .gitmodules" }
        Write-Msg "Cloning $($endfUrl[0]) (ENDF files)"
        if ((Test-Path $EndfRoot) -and @(Get-ChildItem -Force $EndfRoot).Count -gt 0) {
            Fail "$EndfRoot exists and is not a git repository"
        }
        if (-not (Invoke-Git @('-c', 'core.longpaths=true', 'clone', '--quiet', '--no-checkout', [string]$endfUrl[0], $EndfRoot))) {
            Fail "git clone of $EndfSubdir failed"
        }
        Invoke-GitQuiet @('-C', $EndfRoot, 'config', 'core.longpaths', 'true') | Out-Null
        if ($OnWindows) { Invoke-GitQuiet @('-C', $EndfRoot, 'config', 'core.symlinks', 'false') | Out-Null }
    }
    if (-not (Invoke-GitQuiet @('-C', $EndfRoot, 'cat-file', '-e', "$endfCommit^{commit}"))) {
        if (-not (Invoke-Git @('-C', $EndfRoot, 'fetch', '--quiet', '--tags', 'origin'))) { Fail "git fetch failed in $EndfSubdir" }
    }
    Switch-Release $EndfRoot $endfCommit " ($EndfSubdir)" | Out-Null
    Enable-S3Remote $EndfRoot $S3Endf
}

# ---------------------------------------------------------------- selection
$jobList = New-Object System.Collections.ArrayList
foreach ($s in $specs) {
    $base = if ($s[0] -eq 'endf') { $EndfRoot } else { $Root }
    if (-not (Test-Path (Join-Path $base $s[1]))) {
        Write-Warn "$($s[1]) does not exist in $Release ($($s[0])) -- skipped"
        continue
    }
    [void]$jobList.Add($s)
}
foreach ($x in $extraPaths) {
    if (-not (Test-Path (Join-Path $Root $x))) { Fail "path not found in repository: $x" }
    if ($x -eq $EndfSubdir) { [void]$jobList.Add(@('endf', '.', '*')) }
    elseif ($x.StartsWith("$EndfSubdir/")) { [void]$jobList.Add(@('endf', $x.Substring($EndfSubdir.Length + 1), '*')) }
    else { [void]$jobList.Add(@('main', $x, '*')) }
}
if ($jobList.Count -eq 0) { Fail 'nothing to do' }

function Get-MatchOptions([string]$Glob) {
    # Globs are matched against the path relative to the repository and '*'
    # also matches '/', hence '*/' to anchor -Match patterns at the file name.
    $o = @("--include=$Glob")
    if ($Match.Count -gt 0) {
        $o += @('--and', '-(')
        $first = $true
        foreach ($m in $Match) {
            if (-not $first) { $o += '--or' }
            $o += "--include=*/$m"
            $first = $false
        }
        $o += '-)'
    }
    return $o
}

function Invoke-AnnexJob($Job, [string[]]$Command, [switch]$Capture) {
    $repo = if ($Job[0] -eq 'endf') { $EndfRoot } else { $Root }
    $a = @('-C', $repo, 'annex') + $Command + (Get-MatchOptions $Job[2]) + @('--', $Job[1])
    if ($Capture) {
        $out = Get-GitOutput $a
        if (-not $script:NativeOk) { Fail "git annex $($Command[0]) failed" }
        return $out
    }
    return (Invoke-Git $a)
}

function Get-FileList($Job, [string[]]$Filter) {
    $prefix = if ($Job[0] -eq 'endf') { "$EndfSubdir/" } else { '' }
    $fmt = '--format=${bytesize}\t${file}\n'
    $lines = Invoke-AnnexJob $Job (@('find') + $Filter + @($fmt)) -Capture
    foreach ($l in $lines) {
        $parts = ([string]$l) -split "`t", 2
        if ($parts.Count -eq 2) {
            [pscustomobject]@{ Size = [double]$parts[0]; File = ($prefix + $parts[1]) -replace '/\./', '/' }
        }
    }
}

$all = @(); $todo = @()
foreach ($j in $jobList) {
    $all += @(Get-FileList $j @())
    if ($Drop) { $todo += @(Get-FileList $j @('--in=here')) }
    else { $todo += @(Get-FileList $j @('--not', '--in=here')) }
}
if ($all.Count -eq 0) { Fail 'no files match the selection' }
$bytesAll = ($all | Measure-Object -Property Size -Sum).Sum
$bytesTodo = if ($todo.Count -gt 0) { ($todo | Measure-Object -Property Size -Sum).Sum } else { 0 }

if ($Drop) {
    Write-Msg "Selected $($all.Count) files ($(Format-Size $bytesAll)); $($todo.Count) present locally ($(Format-Size $bytesTodo)) will be dropped"
} else {
    Write-Msg "Selected $($all.Count) files ($(Format-Size $bytesAll)); to download: $($todo.Count) files ($(Format-Size $bytesTodo))"
}

if ($DryRun) {
    if ($todo.Count -gt 0) {
        if ($Drop) { Write-Host 'Files that would be dropped:' } else { Write-Host 'Files that would be downloaded:' }
        foreach ($f in $todo) { Write-Host "  $($f.File)" }
    }
    exit 0
}

# ---------------------------------------------------------------- transfer
$ok = $true
if ($todo.Count -gt 0) {
    foreach ($j in $jobList) {
        if ($Drop) { if (-not (Invoke-AnnexJob $j @('drop'))) { $ok = $false } }
        else { if (-not (Invoke-AnnexJob $j @('get', "--jobs=$Jobs"))) { $ok = $false } }
    }
}
if (-not $ok) { Fail 'some files could not be transferred (rerun the same command to retry)' }

if ($Drop) {
    Write-Msg 'Done. Dropped files remain as small placeholder files and can be downloaded again.'
    exit 0
}

if ($CopyTo) {
    Write-Msg "Copying $($all.Count) files to $CopyTo"
    foreach ($f in $all) {
        $src = Join-Path $Root $f.File
        $dst = Join-Path $CopyTo $f.File
        New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst -Force
        (Get-Item -LiteralPath $dst).IsReadOnly = $false
    }
}

Write-Msg "Done. FENDL $Release files are in $Root"
$annexDir = Split-Path (Get-Command git-annex).Source -Parent
if (-not (($origPath -split [regex]::Escape([string][System.IO.Path]::PathSeparator)) -contains $annexDir)) {
    Write-Msg 'To run git/git-annex commands in the clone yourself, first run:'
    Write-Msg "  `$env:PATH = `"$annexDir$([System.IO.Path]::PathSeparator)`$env:PATH`""
}
