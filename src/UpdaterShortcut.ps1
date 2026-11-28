function Set-UpdaterShortcut([string]$Root, [switch]$Remove) {
    try {
        $programs = if ($Root -ieq (Get-UpdaterRoot)) { [Environment]::GetFolderPath('Programs', 'DoNotVerify') }
        else { Join-Path $Root 'test-programs' }
        if (!$programs) { throw 'The per-user Start Menu is unavailable.' }

        $path = Join-Path $programs 'Chromium Updater.lnk'
        $recordPath = Join-Path $Root 'updater-shortcut.json'
        Assert-LocalPath $path
        Assert-LocalPath $recordPath
        $record = if ([IO.File]::Exists($recordPath)) { Read-Json $recordPath }
        if ($record -and $record['Path'] -ine $path) {
            Write-Warning 'The Start Menu folder moved. Review the recorded Chromium Updater shortcut manually.'
            return
        }
        $existingHash = $null
        if (Test-Path -LiteralPath $path) {
            if ($record -and [IO.File]::Exists($path)) { $existingHash = (Get-FileHash -LiteralPath $path).Hash }
            if (!$existingHash -or $existingHash -cnotin $record['Hash'],$record['PreviousHash']) {
                Write-Warning 'The existing Chromium Updater shortcut is unowned or has changed. It was left in place.'
                return
            }
        }
        if ($Remove) {
            if ($existingHash) { [IO.File]::Delete($path) }
            [IO.File]::Delete($recordPath)
            return
        }

        $launcher = Join-Path $Root 'app\ChromiumUpdater.exe'
        Assert-LocalPath $launcher
        if (![IO.File]::Exists($launcher)) { throw 'Install the launcher first.' }
        $config = Read-Config $Root
        if ($existingHash -and $existingHash -ceq $record['Hash'] -and $config.browserPath -ieq $record['BrowserPath']) { return }
        if (!('LauncherIdentity' -as [type])) {
            Add-Type -Path (Join-Path $PSScriptRoot 'Launcher.cs') -CompilerOptions '/define:SHORTCUT_ONLY'
        }
        [void][IO.Directory]::CreateDirectory($programs)
        $temp = Join-Path $programs ('.ChromiumUpdater-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [LauncherIdentity]::CreateShortcut($temp, $launcher, $config.browserPath)
            # Keep the current hash valid until the atomic rename publishes its replacement.
            Write-Json $recordPath @{
                Path = $path; BrowserPath = $config.browserPath
                Hash = (Get-FileHash -LiteralPath $temp).Hash; PreviousHash = $existingHash
            }
            if ($existingHash -and (Get-FileHash -LiteralPath $path).Hash -cne $existingHash) {
                throw 'The shortcut changed during setup.'
            }
            [IO.File]::Move($temp, $path, [bool]$existingHash)
        } finally { [IO.File]::Delete($temp) }
        if (!$existingHash -and $Root -ieq (Get-UpdaterRoot)) {
            Write-Host '[ OK ] Created the Chromium Updater Start Menu shortcut. Right-click it in Start and select Pin to taskbar (under More on Windows 10).'
        }
    } catch {
        if ($Remove) { Write-Warning 'Could not remove the Chromium Updater shortcut. Review it in the Start Menu.' }
        else { Write-Warning 'Could not create the Chromium Updater shortcut. Check the Start Menu and rerun Setup.ps1 -Integrate.' }
    }
}
