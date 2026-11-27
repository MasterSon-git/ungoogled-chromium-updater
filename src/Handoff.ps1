#Requires -Version 7.5
param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][int]$ParentId,
    [Parameter(Mandatory)][long]$ParentTicks,
    [Parameter(Mandatory)][string]$ResumePayload
)

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Browser.ps1')
. (Join-Path $PSScriptRoot 'SelfUpdate.ps1')

Assert-PrivateRoot $Root
$parent = Get-UpdaterProcess $ParentId $ParentTicks
if ($parent) {
    try {
        if (!$parent.WaitForExit(20000)) { throw 'Updater activation timed out waiting for the original worker.' }
    } finally { $parent.Dispose() }
}

$app = Join-Path $Root 'app'
$work = Join-Path $Root 'updater-work'
$previous = Join-Path $Root 'updater-previous-app'
$payload = Join-Path $work 'payload'
$nextApp = Join-Path $work 'next-app'
$planPath = Join-Path $work 'handoff.json'
if ($PSScriptRoot -ine $payload) { throw 'Unexpected updater handoff location.' }
$resume = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ResumePayload)) | ConvertFrom-Json -AsHashtable

$guard = Enter-UpdateLock $Root 420
if (!$guard) { throw 'Updater activation timed out. Retry the launcher after the other check completes.' }
$outcome = 'Failed'
try {
    Assert-LocalPath $planPath
    $plan = Read-Json $planPath
    if ($plan.ProcessId -ne $PID) { throw 'Unexpected updater handoff owner.' }
    try {
        $active = Get-UpdaterSlot $Root
        $current = Get-UpdaterVersion (Join-Path $active.Directory 'Updater.version')
        $target = Get-UpdaterVersion (Join-Path $payload 'Updater.version')
        $slot = if ($active.Slot -ceq 'updater-a') { 'updater-b' } else { 'updater-a' }
        if ($active.Slot -cne $plan.FromSlot -or $current.Text -cne $plan.From -or
            $target.Text -cne $plan.To -or $slot -cne $plan.ToSlot -or
            (Compare-UpdaterVersion $target $current) -le 0) {
            throw 'Updater handoff identity changed.'
        }
        Assert-OrdinaryTree $payload
        Assert-OrdinaryTree $nextApp
        Assert-LocalPath $previous
        $launcher = Join-Path $app 'ChromiumUpdater.exe'
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        foreach ($process in (Get-Process -Name ChromiumUpdater -ErrorAction SilentlyContinue)) {
            try {
                if ($process.Path -ieq $launcher -and
                    !$process.WaitForExit([Math]::Max(0, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds))) {
                    throw 'The previous updater launcher is still running.'
                }
            } finally { $process.Dispose() }
        }
        Remove-UpdaterDirectory $Root $slot
        [IO.Directory]::Move($payload, (Join-Path $Root $slot))
        Remove-UpdaterDirectory $Root 'updater-previous-app'
        [IO.Directory]::Move($app, $previous)
        try { [IO.Directory]::Move($nextApp, $app) }
        catch {
            [IO.Directory]::Move($previous, $app)
            throw
        }
        $outcome = 'Applied'
    } catch {
        if (![IO.Directory]::Exists($app)) {
            throw 'Updater activation was interrupted. Reinstall the verified updater with Setup.ps1 -Install.'
        }
    } finally {
        try { Remove-UpdaterDirectory $Root 'updater-work' }
        catch { Write-Host '[WARN] Updater staging cleanup needs manual attention.' }
    }
} finally { $guard.Dispose() }

[Environment]::CurrentDirectory = $resume.Directory
Set-Location -LiteralPath $resume.Directory
$options = $resume.Options
& (Join-Path $app 'Update.ps1') -SelfUpdateOutcome $outcome @options
exit $LASTEXITCODE
