#Requires -Version 7.5
[CmdletBinding()]
param(
    [switch]$Force, [switch]$CheckOnly, [switch]$Stage, [switch]$Apply, [switch]$NoLaunch,
    [switch]$VerifyCurrent, [switch]$TestCompatibility, [switch]$Dispatch, [switch]$Interactive,
    [string]$Payload,
    [string[]]$BrowserArguments = @()
)

. (Join-Path $PSScriptRoot 'Common.ps1')

function Invoke-Launcher {
    if ($Payload) {
        $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Payload))
        $BrowserArguments = ConvertFrom-Json -InputObject $decoded -NoEnumerate
        if ($BrowserArguments -isnot [array] -or @($BrowserArguments | Where-Object { $_ -isnot [string] }).Count) {
            throw 'Invalid launcher arguments.'
        }
    }
    if ((@($CheckOnly,$Stage,$Apply) -eq $true).Count -gt 1 -or ($TestCompatibility -and !$Stage)) {
        throw 'Choose one of check-only, stage or apply. Compatibility testing requires -Stage.'
    }
    $root = if ([IO.Path]::GetFileName($PSScriptRoot) -ieq 'app') {
        [IO.Path]::GetDirectoryName($PSScriptRoot)
    } else { Get-UpdaterRoot }
    Assert-PrivateRoot $root
    $lock = Enter-UpdateLock $root
    if (!$lock) {
        if ($Dispatch) { return 10 }
        Write-Host '[INFO] Another launcher is checking Chromium. Waiting for it to finish.'
        $lock = Enter-UpdateLock $root 420
        if (!$lock) {
            Write-Host '[WARN] The other launcher is still active. Wait for it to finish, then retry this launch.'
            return 2
        }
    }
    try {
        $active = Get-UpdaterSlot $root
        $worker = Join-Path $active.Directory 'Worker.ps1'
        Assert-LocalPath $worker
        if (!(Test-Path -LiteralPath $worker -PathType Leaf)) { throw 'The active updater is missing. Run Setup.ps1 -Install to recover.' }
        return & {
            . $worker
            Invoke-UpdateSession $root
        }
    } finally { $lock.Dispose() }
}

if ($MyInvocation.InvocationName -eq '.') {
    . (Join-Path $PSScriptRoot 'Worker.ps1')
    return
}
try { $code = Invoke-Launcher }
catch {
    if ($Dispatch) { exit 10 }
    Write-Host '[ERROR] The updater could not read its configuration or complete the operation. Check the private runtime and recovery instructions.' -ForegroundColor Red
    $code = 1
}
if ($Interactive) {
    if ($code) { [void](Read-Host 'Press Enter to close this window') }
    else { Start-Sleep -Milliseconds 1500 }
}
exit $code
