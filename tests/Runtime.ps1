#Requires -Version 7.5
param(
    [Parameter(Mandatory)][string]$BrowserZip,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$BrowserSha256,
    [Parameter(Mandatory)][string]$UboCrx,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$UboSha256
)

. (Join-Path $PSScriptRoot '../src/Common.ps1')
. (Join-Path $PSScriptRoot '../src/Extensions.ps1')
. (Join-Path $PSScriptRoot '../src/Browser.ps1')
. (Join-Path $PSScriptRoot '../src/Mv2.ps1')

$browserFile = Get-Item -LiteralPath $BrowserZip
$uboFile = Get-Item -LiteralPath $UboCrx
if ($browserFile.Length -gt 350MB -or $uboFile.Length -gt 32MB -or
    (Get-FileHash -LiteralPath $BrowserZip).Hash -ine $BrowserSha256 -or
    (Get-FileHash -LiteralPath $UboCrx).Hash -ine $UboSha256) { throw 'Runtime fixture size or SHA-256 mismatch.' }
$root = New-PrivateRoot
$lock = Enter-UpdateLock $root
if (!$lock) { throw 'A launcher operation is in progress. Retry after it finishes.' }
$lab = Join-Path $root 'mv2-work'
$created = $false
$run = @{ BrowserActive = $false }
try {
    Assert-LocalPath $lab
    if (Test-Path -LiteralPath $lab) { throw 'A prior test workspace needs cleanup. See browser maintenance.' }
    [void][IO.Directory]::CreateDirectory($lab)
    $created = $true
    $browser = Join-Path $lab 'browser'
    $stream = [IO.File]::OpenRead($BrowserZip)
    try { Expand-RuntimeZip $stream $browser 800MB } finally { $stream.Dispose() }
    $matches = @(Get-ChildItem -LiteralPath $browser -Recurse -Filter chrome.exe)
    if ($matches.Count -ne 1) { throw 'Expected exactly one browser executable.' }
    Initialize-CrxVerifier
    $bytes = [IO.File]::ReadAllBytes($UboCrx)
    $proof = [Crx3]::Verify($bytes, $script:UboId, $false)
    $manifest = $proof.Manifest | ConvertFrom-Json -AsHashtable
    if (!(Test-FullUboManifest $manifest)) { throw 'Expected the full signed MV2 uBlock Origin package.' }
    $result = Invoke-Mv2Fixture $lab $matches[0].FullName @{ Manifest = $manifest; Proof = $proof; Bytes = $bytes } $run
    Write-Output "$($result.Status). $($result.Detail)"
    if ($result.Status -ne 'Pass') { throw 'The diagnostic fixture did not pass.' }
} finally {
    try {
        if ($run.BrowserActive) { throw "Close the isolated Chromium instance manually. Test workspace is $lab" }
        if ($created) { Remove-Mv2Lab $root $lab }
    } finally { $lock.Dispose() }
}
