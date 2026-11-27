#Requires -Version 7.5
param([switch]$ReleaseCli)

$ErrorActionPreference = 'Stop'
$repo = Join-Path $PSScriptRoot '..'
foreach ($file in Get-ChildItem -Path "$repo/src","$repo/tests","$repo/tools" -Filter '*.ps1' -File) {
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
}
Get-Content -LiteralPath (Join-Path $repo 'config.example.json') -Raw | ConvertFrom-Json | Out-Null
git -C $repo diff --check HEAD^ HEAD
if ($LASTEXITCODE) { throw 'The checked-out change has whitespace errors.' }
$tests = @('Test-Updater.ps1','Test-SelfUpdate.ps1')
if ($ReleaseCli) { $tests += 'Test-ReleasePublish.ps1' }
foreach ($test in $tests) {
    & ([Environment]::ProcessPath) -NoLogo -NoProfile -NonInteractive -File (Join-Path $repo "tests/$test")
    if ($LASTEXITCODE) { throw "$test failed." }
}
