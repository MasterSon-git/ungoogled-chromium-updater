#Requires -Version 7.5
[CmdletBinding()]
param(
    [switch]$Force, [switch]$CheckOnly, [switch]$Stage, [switch]$Apply, [switch]$NoLaunch,
    [switch]$RetryExtensionUpdates, [switch]$ExtensionActions,
    [switch]$VerifyCurrent, [switch]$TestCompatibility, [switch]$Dispatch, [switch]$Interactive, [switch]$Probe,
    [string]$VerifyBackup,
    [ValidateSet('Applied','Failed')][string]$SelfUpdateOutcome,
    [string]$Payload,
    [string[]]$BrowserArguments = @()
)

. (Join-Path $PSScriptRoot 'Common.ps1')

function Read-ExtensionRetryChoice($State) {
    if (!(Test-RequestedExtensionUpdates $State.Inventory)) {
        Write-Host '[INFO] There are no previously requested extension installs to retry.'
        return $false
    }
    ([string](Read-Host 'Type R and press Enter to retry previous extension prompts, or press Enter to continue')).Trim() -ieq 'r'
}

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
    if ($RetryExtensionUpdates -and ($CheckOnly -or $Stage -or $NoLaunch)) {
        Write-Host '[ERROR] Retrying extension prompts requires a normal browser launch.'
        return 1
    }
    $root = if ([IO.Path]::GetFileName($PSScriptRoot) -ieq 'app') {
        [IO.Path]::GetDirectoryName($PSScriptRoot)
    } else { Get-UpdaterRoot }
    Assert-PrivateRoot $root
    if ($ExtensionActions -and $Interactive -and !$Dispatch -and !$RetryExtensionUpdates -and !$VerifyBackup -and
        !$CheckOnly -and !$Stage -and !$NoLaunch -and ![IO.File]::Exists((Join-Path $root 'installation.json'))) {
        $RetryExtensionUpdates = Read-ExtensionRetryChoice (Read-DailyState (Join-Path $root 'state.json'))
    }
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
            if ($VerifyBackup) {
                try {
                    if ((Confirm-BrowserBackup $root $VerifyBackup) -ceq 'Legacy') {
                        Write-Status WARN 'This backup predates SHA-256 verification. See the legacy backup recovery instructions.'
                        return 2
                    }
                    Write-Status ' OK ' 'Backup SHA-256 checks passed for the documented recovery scope.'
                    return 0
                } catch {
                    Write-Status ERROR (Get-SafeProblem $_ 'The backup could not be verified.')
                    return 1
                }
            }
            Invoke-UpdateSession $root
        }
    } finally { $lock.Dispose() }
}

if ($MyInvocation.InvocationName -eq '.') {
    . (Join-Path $PSScriptRoot 'Worker.ps1')
    return
}
if ($Probe) {
    & (Join-Path $PSScriptRoot 'Worker.ps1') -Probe
    exit $LASTEXITCODE
}
try { $code = Invoke-Launcher }
catch {
    if ($Dispatch) { exit 10 }
    Write-Host '[ERROR] The updater could not read its configuration or complete the operation. Check the private runtime and recovery instructions.' -ForegroundColor Red
    $code = 1
}
if ($Interactive) {
    if ($code -eq 20) { exit $code }
    if ($code -eq 21) { exit 2 }
    if ($code) { [void](Read-Host 'Press Enter to close this window') }
    else { Start-Sleep -Milliseconds 1500 }
}
exit $code
