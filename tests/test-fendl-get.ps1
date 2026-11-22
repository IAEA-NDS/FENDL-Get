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

    Needs network access. Uses a fresh venv unless -SystemAnnex is given.
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
$VenvDir = Join-Path $Work 'venv'
$VenvBin = if ($OnWindows) { Join-Path $VenvDir 'Scripts' } else { Join-Path $VenvDir 'bin' }
$script:Log = ''
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
function Invoke-FendlGet([string[]]$Arguments) {
    $a = @('-NoProfile')
    if ($OnWindows) { $a += @('-ExecutionPolicy', 'Bypass') }
    $a += @('-File', $Script, '-Dir', $Clone, '-Venv', $VenvDir) + $Extra + $Arguments
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

# git-annex from the test venv for the checks above (-SystemAnnex: from PATH).
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

Write-Host '=== 1. argument errors'
if (Invoke-FendlGet @('-Type', 'bogus')) { Fail 'invalid type accepted' }
Assert-Log "unknown type 'bogus'" 'no error message for invalid type'
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
Assert-Log 'to download: 1 files' 'content of the default release lost after switching back'
foreach ($f in $Expected) { Test-Content $f }
Pass 'release switching'

Write-Host "=== all $($script:Passed) checks passed"
Remove-Work
exit 0
