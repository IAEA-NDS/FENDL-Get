<#
.SYNOPSIS
    End-to-end test of fendl-get.ps1.

.DESCRIPTION
    Clones the repository into a temporary directory, downloads a few small
    files of the processed library and of the ENDF repository, checks their
    contents against the git-annex keys, and switches between releases.

    Environment variables:
      TEST_SHELL  PowerShell used to run fendl-get.ps1: pwsh (default) or
                  powershell (Windows PowerShell 5.1)
      TEST_ARGS   extra options for fendl-get.ps1, e.g. -SystemAnnex
      KEEP_WORK   if set to 1, the temporary directory is kept

    Needs network access. Uses the default venv inside the clone unless
    -SystemAnnex is given.
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Script = Join-Path (Split-Path $PSScriptRoot -Parent) 'fendl-get.ps1'
$Shell = if ($env:TEST_SHELL) { $env:TEST_SHELL } else { 'pwsh' }
$Extra = @()
if ($env:TEST_ARGS) { $Extra = @($env:TEST_ARGS -split ' ' | Where-Object { $_ }) }
$OnWindows = [System.IO.Path]::DirectorySeparatorChar -eq '\'

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ("fendl-get-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work | Out-Null
$Clone = Join-Path $Work 'clone'
$Out = Join-Path $Work 'out'
$VenvDir = Join-Path $Clone '.git/fendl-get-venv'   # default location
$VenvBin = if ($OnWindows) { Join-Path $VenvDir 'Scripts' } else { Join-Path $VenvDir 'bin' }
$script:Log = ''
$TestRelease = 'FENDL-3.2d-T4'
$script:Passed = 0

function Pass([string]$t) { $script:Passed++; Write-Host "PASS: $t" -ForegroundColor Green }
function Fail([string]$t) {
    Write-Host "FAIL: $t" -ForegroundColor Red
    Write-Host '--- last output:'
    Write-Host $script:Log
    Remove-Work
    exit 1
}
function Remove-Work {
    if ($env:KEEP_WORK -eq '1') { Write-Host "work dir kept: $Work"; return }
    # annexed objects are read-only
    Get-ChildItem -LiteralPath $Work -Recurse -Force -File -ErrorAction SilentlyContinue |
        ForEach-Object { try { $_.IsReadOnly = $false } catch { Write-Verbose "cannot make $_ writable" } }
    if (-not $OnWindows) { & chmod -R u+w $Work 2>$null }
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}

# Run fendl-get.ps1 in a separate PowerShell process (as users would).
function Invoke-FendlGet([string[]]$Arguments, [switch]$NoDefaults, [switch]$NoRelease) {
    $a = @('-NoProfile')
    if ($OnWindows) { $a += @('-ExecutionPolicy', 'Bypass') }
    $a += @('-File', $Script)
    if (-not $NoDefaults) { $a += @('-Dir', $Clone) + $Extra }
    # fendl-get.ps1 requires -Release; tests that name one use their own.
    if (-not $NoRelease -and $Arguments -notcontains '-Release') { $a += @('-Release', $TestRelease) }
    $a += $Arguments
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $script:Log = (& $Shell @a 2>&1 | ForEach-Object { "$_" }) -join "`n" }
    finally { $ErrorActionPreference = $eap }
    Write-Host $script:Log
    return ($LASTEXITCODE -eq 0)
}

function Invoke-Annex([string]$Repo, [string[]]$Arguments) {
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $r = & git -C $Repo annex @Arguments 2>$null }
    finally { $ErrorActionPreference = $eap }
    if ($null -eq $r) { return , @() }
    return , @($r)
}

# Split "fendl-endf/x" paths into (repository, relative path).
function Get-RepoAndPath([string]$f) {
    if ($f.StartsWith('fendl-endf/')) { return @((Join-Path $Clone 'fendl-endf'), $f.Substring(11)) }
    return @($Clone, $f)
}

function Test-Present([string]$f) {
    $rp = Get-RepoAndPath $f
    return ((Invoke-Annex $rp[0] @('find', '--in=here', '--', $rp[1])).Count -gt 0)
}

# Check that a downloaded file (and optionally its copy) is a regular file
# whose SHA256 matches its git-annex key.
function Test-Content([string]$f, [string]$Copy = '') {
    $rp = Get-RepoAndPath $f
    $full = Join-Path $rp[0] $rp[1]
    $item = Get-Item -LiteralPath $full -ErrorAction SilentlyContinue
    if ($null -eq $item) { Fail "$f does not exist" }
    if ($item.LinkType) { Fail "$f is a link, expected a regular (unlocked) file" }
    $key = Invoke-Annex $rp[0] @('lookupkey', '--', $rp[1])
    if ($key.Count -eq 0 -or -not ([string]$key[0]).StartsWith('SHA256E-')) { Fail "no SHA256E key for $f" }
    $want = ((([string]$key[0]) -replace '^.*--', '') -replace '\..*$', '').ToLowerInvariant()
    $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $full).Hash.ToLowerInvariant()
    if ($got -ne $want) { Fail "checksum mismatch for $f" }
    if ($Copy) {
        if (-not (Test-Path -LiteralPath $Copy -PathType Leaf)) { Fail "$Copy missing" }
        if ((Get-Item -LiteralPath $Copy).IsReadOnly) { Fail "$Copy is read-only" }
        $gotc = (Get-FileHash -Algorithm SHA256 -LiteralPath $Copy).Hash.ToLowerInvariant()
        if ($gotc -ne $want) { Fail "checksum mismatch for $Copy" }
    }
}

function Assert-Log([string]$Pattern, [string]$What) {
    if ($script:Log -notmatch $Pattern) { Fail $What }
}

# Run fendl-get.ps1 expecting it to fail with a message matching a pattern.
function Assert-Fails([string]$Pattern, [string[]]$Arguments) {
    if (Invoke-FendlGet $Arguments -NoDefaults) { Fail "accepted: $($Arguments -join ' ')" }
    Assert-Log $Pattern "unexpected error message for: $($Arguments -join ' ')"
}

# git-annex from the venv in the clone for the checks above (-SystemAnnex: from PATH).
$env:PATH = $VenvBin + [System.IO.Path]::PathSeparator + $env:PATH

Write-Host "=== PowerShell used for fendl-get.ps1: $Shell"
& $Shell -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'

$Sel = @('-Type', 'ace,endf', '-Particle', 'n', '-Match', '01H*,*H-1.endf')
$Expected = @(
    'general-purpose/neutron/ace/01H_001',
    'general-purpose/neutron/ace/01H_001.xsd',
    'general-purpose/neutron/ace/01H_002',
    'general-purpose/neutron/ace/01H_002.xsd',
    'general-purpose/neutron/ace/01H_003',
    'general-purpose/neutron/ace/01H_003.xsd',
    'fendl-endf/general-purpose/neutron/n_0125_1-H-1.endf'
)

# Side effects outside the clone: entries in the home directory (3 levels,
# e.g. AppData\Local\pip, ~/.cache/pip) and the global git config. Excluded
# are files that PowerShell and Windows themselves keep changing.
$Noise = '(?i)^/(ntuser|\.cache/powershell|\.local/share/powershell)|/PowerShell($|/)'
# On GitHub's Windows runners, Firefox's background tasks create these at
# random times (seen once in CI; nothing in the scripts uses Mozilla).
if ($env:GITHUB_ACTIONS -eq 'true') { $Noise += '|(?i)^/AppData/(Local|Roaming)/Mozilla($|/)' }
function Get-HomeSnapshot {
    $h = if ($OnWindows) { $env:USERPROFILE } else { $HOME }
    $entries = Get-ChildItem -LiteralPath $h -Force -Recurse -Depth 2 -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName.Substring($h.Length) -replace '\\', '/' } |
        Where-Object { $_ -notmatch $Noise } | Sort-Object
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $cfg = (& git config --global --list 2>$null) -join "`n" } finally { $ErrorActionPreference = $eap }
    return ((@($entries) + '--- global git config:' + $cfg) -join "`n")
}
$HomeBefore = Get-HomeSnapshot

Write-Host '=== 1. argument errors'
if (Invoke-FendlGet @('-Type', 'bogus')) { Fail 'invalid type accepted' }
Assert-Log "unknown type 'bogus'" 'no error message for invalid type'
Assert-Fails 'integer from 1 to 64' @('-Type', 'ace', '-Jobs', '0')
if (Invoke-FendlGet @('-Type', 'ace') -NoRelease) { Fail 'missing -Release accepted' }
Assert-Log '-Release is required' 'no error message for missing -Release'
Assert-Fails 'integer from 1 to 64' @('-Type', 'ace', '-Jobs', '65')
Pass 'argument handling'

Write-Host '=== 2. dry run (sets up git-annex, clones, enables remotes)'
if (-not (Invoke-FendlGet ($Sel + '-DryRun'))) { Fail 'dry run failed' }
foreach ($f in $Expected) { Assert-Log ("(?m)^  " + [regex]::Escape($f) + '\s*$') "dry run does not list $f" }
Assert-Log 'to download: 7 files' 'dry run: unexpected file count'
if (Test-Present $Expected[0]) { Fail 'dry run downloaded files' }
Pass 'dry run'

Write-Host '=== 3. download with -CopyTo'
if (-not (Invoke-FendlGet ($Sel + @('-CopyTo', $Out)))) { Fail 'download failed' }
foreach ($f in $Expected) { Test-Content $f (Join-Path $Out $f) }
if ($Extra.Count -eq 0) {
    if (-not (Test-Path (Join-Path $VenvDir '.fendl-get-venv'))) { Fail 'venv not inside the clone' }
    # the pinned versions were installed (not silently skipped)
    $py = Join-Path $VenvBin $(if ($OnWindows) { 'python.exe' } else { 'python' })
    $pipv = ((& $py -m pip --version) -split ' ')[1]
    if (@('26.3', '26.0.1') -notcontains $pipv) { Fail "unexpected pip version $pipv in the venv" }
    $annexv = ((& (Join-Path $VenvBin 'git-annex') version --raw) -join '')
    if (-not $env:FENDL_GET_PIP_SPEC -and -not $annexv.StartsWith('10.20261026')) { Fail "git-annex in the venv is not the pinned version ($annexv)" }
}
Pass 'download from S3 and -CopyTo (contents verified)'

Write-Host '=== 4. rerun is a no-op'
if (-not (Invoke-FendlGet $Sel)) { Fail 'rerun failed' }
Assert-Log 'to download: 0 files' 'rerun wanted to download files again'
Pass 'rerun'

Write-Host '=== 5. paths, hdf5 and photon alias'
if (-not (Invoke-FendlGet @('general-purpose/neutron/njoy/01H_001.nji'))) { Fail 'download by path failed' }
Test-Content 'general-purpose/neutron/njoy/01H_001.nji'
if (-not (Invoke-FendlGet @('-Type', 'hdf5', '-Particle', 'photon', '-Match', 'H.h5'))) { Fail 'hdf5 download failed' }
Test-Content 'general-purpose/atom/hdf5/H.h5'
Pass 'paths, hdf5, photon alias'

Write-Host '=== 6. drop'
if (-not (Invoke-FendlGet @('-Type', 'ace', '-Particle', 'n', '-Match', '01H_001', '-Drop'))) { Fail 'drop failed' }
if (Test-Present 'general-purpose/neutron/ace/01H_001') { Fail 'file still present after drop' }
Pass 'drop'

Write-Host '=== 7. switch to an older release and back'
$old = @('-Type', 'ace,endf', '-Particle', 'p', '-Match', '01H_001,p_0125*')
if (-not (Invoke-FendlGet (@('-Release', 'FENDL-3.2c') + $old))) { Fail 'download of FENDL-3.2c failed' }
Assert-Log 'Checking out FENDL-3.2c' 'did not switch to FENDL-3.2c'
Test-Content 'general-purpose/proton/ace/01H_001'
Test-Content 'fendl-endf/general-purpose/proton/p_0125_1-H-1.endf'
if (-not (Invoke-FendlGet $Sel)) { Fail 'switching back failed' }
# only the file dropped in step 6 has to be downloaded again
Assert-Log 'to download: 1 files' 'content of the test release lost after switching back'
foreach ($f in $Expected) { Test-Content $f }
# -Release with a commit id and a revision that is no valid branch name
$c = ((& git -C $Clone rev-parse --short=9 'FENDL-3.2c^{commit}') -join '').Trim()
if (-not (Invoke-FendlGet @('-Release', "$c~0", '-Type', 'ace', '-Particle', 'p', '-Match', '01H_001', '-DryRun'))) { Fail "-Release $c~0 failed" }
Assert-Log ([regex]::Escape("Checking out $c~0")) "revision $c~0 not checked out"
if (-not (Invoke-FendlGet (@('-Release', 'fendl32d_prep') + $Sel + '-DryRun'))) { Fail '-Release with a branch name failed' }
Assert-Log 'Checking out fendl32d_prep' 'branch fendl32d_prep not checked out'
Pass 'release switching (tag, branch, commit id)'

Write-Host '=== 8. protection against wrong arguments'
# -Venv: a non-empty directory not created by the script is refused and left alone.
$data = Join-Path $Work 'data'
New-Item -ItemType Directory -Path $data | Out-Null
Set-Content -LiteralPath (Join-Path $data 'thesis.tex') -Value 'keep'
Assert-Fails 'refusing to use it' @('-Dir', $Clone, '-Venv', $data, '-Type', 'ace', '-Particle', 'n', '-DryRun')
if (@(Get-ChildItem -LiteralPath $data -Force).Count -ne 1) { Fail '-Venv directory was modified' }
# -Dir: another git repository is refused and left unchanged.
$project = Join-Path $Work 'project'
& git init -q $project
& git -C $project -c user.name=t -c user.email=t@t commit -q --allow-empty -m mine
$cfgBefore = (& git -C $project config --local -l) -join "`n"
Assert-Fails 'not a clone of fendl-processed' @('-Dir', $project, '-Type', 'ace', '-Particle', 'n', '-DryRun')
if (Test-Path (Join-Path $project '.git/annex')) { Fail 'git-annex was initialised in another repository' }
if (((& git -C $project config --local -l) -join "`n") -ne $cfgBefore) { Fail 'config of another repository changed' }
# GIT_DIR/GIT_WORK_TREE in the environment do not redirect the script to
# another repository.
$headBefore = (& git -C $project rev-parse HEAD)
$env:GIT_DIR = Join-Path $project '.git'; $env:GIT_WORK_TREE = $project
try { $ok = Invoke-FendlGet @('-Type', 'ace', '-Particle', 'n', '-Match', '01H_001', '-DryRun') }
finally { Remove-Item Env:GIT_DIR, Env:GIT_WORK_TREE }
if (-not $ok) { Fail 'run with GIT_DIR set failed' }
if ((Test-Path (Join-Path $project '.git/annex')) -or (Test-Path (Join-Path $project '.git/fendl-get-venv'))) {
    Fail 'GIT_DIR redirected the script to another repository'
}
if (((& git -C $project config --local -l) -join "`n") -ne $cfgBefore) { Fail 'config of the GIT_DIR repository changed' }
if ((& git -C $project rev-parse HEAD) -ne $headBefore) { Fail 'HEAD of the GIT_DIR repository changed' }
# -Dir: a clone set up with git-annex by someone else (e.g. a maintainer) is
# refused and left unchanged ...
$foreign = Join-Path $Work 'foreign'
& git clone -q --no-checkout $Clone $foreign
& git -C $foreign config annex.uuid 00000000-0000-0000-0000-000000000000
$cfgBefore = (& git -C $foreign config --local -l) -join "`n"
Assert-Fails 'not set up by this script' @('-Dir', $foreign, '-Type', 'ace', '-Particle', 'n', '-Match', '01H_001', '-DryRun')
if (((& git -C $foreign config --local -l) -join "`n") -ne $cfgBefore) { Fail 'config of a foreign clone changed' }
if (Test-Path (Join-Path $foreign '.git/annex')) { Fail 'a foreign clone was modified' }
# ... while a plain git clone without git-annex state is used (and marked).
$plain = Join-Path $Work 'plain'
& git clone -q --no-checkout $Clone $plain
& git -C $plain fetch -q $Clone '+refs/remotes/origin/*:refs/remotes/origin/*'
if (-not (Invoke-FendlGet (@('-Dir', $plain, '-Venv', $VenvDir) + $Extra +
        @('-Type', 'ace', '-Particle', 'n', '-Match', '01H_001', '-DryRun')) -NoDefaults)) {
    Fail 'plain git clone not accepted'
}
if ((& git -C $plain config --get fendl-get.managed) -ne 'true') { Fail 'plain git clone not marked' }
# -Dir: a non-empty directory that is no repository is refused.
Assert-Fails 'exists and is not a git repository' @('-Dir', $data, '-Type', 'ace', '-Particle', 'n', '-DryRun')
# -CopyTo: directories inside the clone are refused.
Assert-Fails 'outside the clone' @('-Dir', $Clone, '-Type', 'ace', '-Particle', 'n', '-Match', '01H_001', '-CopyTo', $Clone)
Assert-Fails 'outside the clone' @('-Dir', $Clone, '-Type', 'ace', '-Particle', 'n', '-Match', '01H_001', '-CopyTo', (Join-Path $Clone 'general-purpose'))
Pass 'protection against wrong arguments'

Write-Host '=== 9. AWS credentials, interrupted venv creation, disk space'
# AWS credentials in the environment are not used (nor stored in the clone).
if (-not (Invoke-FendlGet @('-Type', 'ace', '-Particle', 'n', '-Match', '01H_001', '-Drop'))) { Fail 'drop failed' }
$env:AWS_ACCESS_KEY_ID = 'AKIAFAKEFAKEFAKEFAKE'; $env:AWS_SECRET_ACCESS_KEY = 'fakesecret'
try { $ok = Invoke-FendlGet @('-Type', 'ace', '-Particle', 'n', '-Match', '01H_001') }
finally { Remove-Item Env:AWS_ACCESS_KEY_ID, Env:AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue }
if (-not $ok) { Fail 'download with AWS credentials in the environment failed' }
Test-Content 'general-purpose/neutron/ace/01H_001'
$creds = Join-Path $Clone '.git/annex/creds'
if ((Test-Path $creds) -and @(Get-ChildItem -Force $creds).Count -gt 0) { Fail 'AWS credentials were stored in the clone' }
# An incomplete venv (e.g. from an interrupted first run) is repaired.
if ($Extra.Count -eq 0) {
    Remove-Item -Recurse -Force (Join-Path $VenvDir $(if ($OnWindows) { 'Lib' } else { 'lib' }))
    if (-not (Invoke-FendlGet @('-Type', 'ace', '-Particle', 'n', '-Match', '01H_001', '-DryRun'))) { Fail 'incomplete venv was not repaired' }
    Assert-Log 'Creating Python venv' 'incomplete venv was not recreated'
}
# Downloads that would leave less than the reserve free are refused.
$env:FENDL_GET_MIN_FREE = '999000000000000'
try {
    if (-not (Invoke-FendlGet @('-Type', 'njoy-input', '-Particle', 'n', '-Match', '01H_002*', '-DryRun'))) { Fail 'dry run failed' }
    Assert-Log 'not enough disk space' 'dry run did not warn about disk space'
    if (Invoke-FendlGet @('-Type', 'njoy-input', '-Particle', 'n', '-Match', '01H_002*')) { Fail 'download not refused despite lack of disk space' }
    Assert-Log 'not enough disk space' 'unexpected error message for lack of disk space'
} finally { Remove-Item Env:FENDL_GET_MIN_FREE -ErrorAction SilentlyContinue }
if (Test-Present 'general-purpose/neutron/njoy/01H_002.nji') { Fail 'file downloaded despite lack of disk space' }
if (((& git -C $Clone config --get annex.diskreserve) -join '') -ne '2 gigabytes') { Fail 'annex.diskreserve not set' }
Pass 'AWS credentials ignored, venv repaired, disk space checked'

Write-Host '=== 10. removal as documented'
if ($OnWindows) {
    # the command given in the README for Windows
    Remove-Item -Recurse -Force $Clone
} else {
    & chmod -R u+w $Clone
    Remove-Item -Recurse -Force $Clone
}
if (Test-Path $Clone) { Fail 'clone could not be removed with the documented command' }
Pass 'removal of the clone (including the venv)'

Write-Host '=== 11. nothing changed outside the clone'
$HomeAfter = Get-HomeSnapshot
if ($HomeAfter -ne $HomeBefore) {
    $b = $HomeBefore -split "`n"; $a = $HomeAfter -split "`n"
    $script:Log = (@($a | Where-Object { $b -notcontains $_ } | ForEach-Object { "  + $_" }) +
                   @($b | Where-Object { $a -notcontains $_ } | ForEach-Object { "  - $_" })) -join "`n"
    Fail 'the home directory or the global git config changed'
}
Pass 'no changes in the home directory and the global git config'

Write-Host "=== all $($script:Passed) checks passed"
Remove-Work
exit 0
