#Requires -Version 7.5
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install')][switch]$Install,
    [Parameter(ParameterSetName = 'Install')][guid]$TestInstall,
    [Parameter(Mandatory, ParameterSetName = 'Integrate')][switch]$Integrate,
    [Parameter(Mandatory, ParameterSetName = 'Uninstall')][switch]$Uninstall
)

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Browser.ps1')
. (Join-Path $PSScriptRoot 'BrowserPayload.ps1')
. (Join-Path $PSScriptRoot 'SelfUpdate.ps1')

function Write-Status([string]$Level, [string]$Message) {
    Write-Host "[$Level] $Message"
}

function Install-LauncherFiles([string]$Root) {
    $shell = @(
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
        (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Microsoft\WindowsApps\Microsoft.PowerShell_8wekyb3d8bbwe\pwsh.exe'),
        [Environment]::ProcessPath
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
    if (!$shell) { throw 'PowerShell 7 could not be located.' }
    $probe = & $shell -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()'
    if ($LASTEXITCODE -or [version]$probe -lt [version]'7.5') { throw 'A usable PowerShell 7.5 or newer is required.' }
    $compiler = Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (!(Test-Path -LiteralPath $compiler)) {
        $compiler = Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
    }
    $app = Join-Path $Root 'app'
    $active = Join-Path $Root 'updater-active.json'
    $staged = Join-Path $Root ('app-staged-' + [guid]::NewGuid().ToString('N'))
    $previous = Join-Path $Root ('app-previous-' + [guid]::NewGuid().ToString('N'))
    Assert-LocalPath $app
    Assert-LocalPath $active
    $config = Join-Path $Root 'config.json'
    Assert-LocalPath $config
    try {
        [void][IO.Directory]::CreateDirectory($staged)
        foreach ($name in (Get-UpdaterPackageFiles).Keys) {
            $source = Join-Path $PSScriptRoot $name
            if ($name -in 'config.example.json','LICENSE','THIRD_PARTY_NOTICES.md' -and ![IO.File]::Exists($source)) {
                $source = Join-Path $PSScriptRoot "../$name"
            }
            Copy-Item -LiteralPath $source -Destination (Join-Path $staged $name)
        }
        $launcher = Join-Path $staged 'ChromiumUpdater.exe'
        & $compiler '/nologo' '/target:winexe' '/reference:System.Windows.Forms.dll' '/reference:System.Web.Extensions.dll' "/out:$launcher" (Join-Path $staged 'Launcher.cs')
        if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $launcher)) { throw 'Windows launcher compilation failed.' }
        [IO.File]::WriteAllText((Join-Path $staged 'pwsh.path'), $shell)
        Assert-UpdaterWorker $staged $shell
        if (!(Test-Path -LiteralPath $config)) {
            $example = Join-Path $staged 'config.example.json'
            if ($TestInstall -eq [guid]::Empty) {
                Copy-Item -LiteralPath $example -Destination $config
            } else {
                $isolated = Read-Json $example
                $isolated.browserPath = Join-Path $Root 'fixture\chrome.exe'
                $isolated.userData = Join-Path $Root 'fixture-profile'
                $isolated.browserUpdateMode = 'Manual'
                $isolated.browserTrust.allowUnsigned = $false
                $isolated.selfUpdateEnabled = $false
                Write-Json $config $isolated
            }
        }
        $hadApp = Test-Path -LiteralPath $app
        if ($hadApp) { [IO.Directory]::Move($app, $previous) }
        try { [IO.Directory]::Move($staged, $app) }
        catch {
            if ($hadApp) { [IO.Directory]::Move($previous, $app) }
            throw
        }
        [IO.File]::Delete($active)
    } finally {
        if (Test-Path -LiteralPath $staged) { Remove-LauncherDirectory $Root $staged }
    }
    if ($hadApp) { Remove-LauncherDirectory $Root $previous }
    $settings = Read-Json $config
    $legacyApproval = $settings['browserApproval']
    if (Convert-LegacyBrowserConfig $settings) {
        $legacyPath = Join-Path $Root 'config.legacy.json'
        Assert-LocalPath $legacyPath
        if (!(Test-Path -LiteralPath $legacyPath)) { [IO.File]::Copy($config, $legacyPath) }
        Write-Json $config $settings
        Write-Host '[WARN] Legacy browser settings migrated to Manual mode. Review browserTrust in config.json before applying an update.'
        $tag = try { Initialize-BrowserRelease $Root (Read-Config $Root) $legacyApproval }
        catch { Write-Status WARN 'Could not verify the legacy installation evidence. See browser maintenance.' }
        if ($tag) { Write-Status ' OK ' "Recorded installed Windows distribution release $tag." }
        elseif (![IO.File]::Exists((Join-Path $Root 'browser-release.json'))) {
            Write-Status WARN 'The installed Windows packaging revision remains unknown.'
        }
    }
    Write-Host '[ OK ] Launcher installed under Local AppData.'
}

function Remove-LauncherDirectory([string]$Root, [string]$Path) {
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path)) -ine $Root) { throw 'Unexpected launcher directory.' }
    Assert-LocalPath $Path
    foreach ($file in (Get-ChildItem -LiteralPath $Path -Force)) {
        if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Remove unexpected launcher files manually.'
        }
    }
    Remove-Item -LiteralPath $Path -Recurse -Force
}

function Set-LauncherShortcuts([string]$Root, [bool]$Restore) {
    $links = @{
        Desktop = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Chromium.lnk'
        StartMenu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Chromium.lnk'
    }
    $launcher = Join-Path $Root 'app\ChromiumUpdater.exe'
    Assert-LocalPath $launcher
    if (!$Restore -and !(Test-Path -LiteralPath $launcher -PathType Leaf)) { throw 'Install the launcher first.' }
    $infoPath = Join-Path $Root 'shortcuts.json'
    Assert-LocalPath $infoPath
    $records = if (Test-Path -LiteralPath $infoPath) { Read-Json $infoPath } else { @{} }
    $folder = Join-Path $Root 'shortcut-backups'
    Assert-LocalPath $folder
    [void][IO.Directory]::CreateDirectory($folder)
    $shell = New-Object -ComObject WScript.Shell
    $config = if (!$Restore) { Read-Config $Root }
    foreach ($kind in 'Desktop','StartMenu') {
        $path = $links[$kind]
        Assert-LocalPath $path
        $backup = Join-Path $folder "$kind.lnk"
        Assert-LocalPath $backup
        $record = $records[$kind]
        if ($record -and $record.Path -ine $path) { throw "The $kind folder moved. Restore its backed-up shortcut manually." }
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) {
            if ($record) { throw "The original $kind shortcut moved or was removed. Review the shortcut backup." }
            Write-Host "[INFO] No Chromium shortcut found for $kind."
            continue
        }
        $hash = (Get-FileHash -LiteralPath $path).Hash
        if ($Restore -and !$record) { continue }
        if ($record -and (!(Test-Path -LiteralPath $backup) -or (Get-FileHash -LiteralPath $backup).Hash -ne $record.Original)) {
            throw "The $kind shortcut backup could not be verified."
        }
        if ($Restore -and $hash -eq $record.Original) { continue }
        $link = $shell.CreateShortcut($path)
        if ($Restore) {
            if ($hash -ne $record['Managed'] -and
                ($record['Managed'] -or $link.TargetPath -ine $launcher -or $link.Arguments -cne $record.Arguments)) {
                throw "The $kind shortcut was changed after installation. Restore its backup manually."
            }
            [IO.File]::Copy($backup, $path, $true)
            Write-Host "[ OK ] Restored the original $kind Chromium shortcut."
            continue
        }
        if ($link.TargetPath -ieq $launcher -and $record) {
            if ($record['Managed'] -and $hash -ne $record.Managed) { throw "The managed $kind shortcut was edited." }
            $original = $shell.CreateShortcut($backup)
            if ($link.WorkingDirectory -ceq $original.WorkingDirectory -and $record['Managed']) { continue }
            $workingDirectory = $original.WorkingDirectory
        } elseif ($link.TargetPath -ine $config.browserPath) {
            throw "The $kind shortcut does not target the configured Chromium."
        } else {
            $workingDirectory = $link.WorkingDirectory
        }
        if ($record -and $link.TargetPath -ine $launcher) {
            if ($hash -ne $record.Original) { throw "The $kind shortcut was edited. Review its backup before reintegrating." }
        } elseif (!$record) {
            [IO.File]::Copy($path, $backup, $false)
            $record = @{ Path = $path; Arguments = $link.Arguments; Original = $hash; Managed = $null }
            $records[$kind] = $record
            Write-Json $infoPath $records
        }
        $icon = $link.IconLocation
        if (!$icon -or $icon -eq ',0') { $icon = $config.browserPath + ',0' }
        $arguments = $link.Arguments
        $link.TargetPath = $launcher
        $link.IconLocation = $icon
        $link.Arguments = $arguments
        $link.WorkingDirectory = $workingDirectory
        $link.Save()
        $record['Managed'] = (Get-FileHash -LiteralPath $path).Hash
        Write-Json $infoPath $records
        Write-Host "[ OK ] Integrated the $kind Chromium shortcut."
    }
}

if ($PSBoundParameters.ContainsKey('TestInstall') -and $TestInstall -eq [guid]::Empty) {
    throw 'Provide a non-empty test installation ID.'
}
$root = if ($Uninstall) { Get-UpdaterRoot }
elseif ($TestInstall -ne [guid]::Empty) { New-PrivateRoot ("$(Get-UpdaterRoot)-Test-$($TestInstall.ToString('N'))") }
else { New-PrivateRoot }
Assert-PrivateRoot $root
$guard = Enter-UpdateLock $root 20
if (!$guard) { throw 'A launcher operation is in progress. Retry after it finishes.' }
try {
    if ($Integrate) { Set-LauncherShortcuts $root $false }
    elseif ($Uninstall) {
        Set-LauncherShortcuts $root $true
        $app = Join-Path $root 'app'
        if (Test-Path -LiteralPath $app) { Remove-LauncherDirectory $root $app }
        $active = Join-Path $root 'updater-active.json'
        Assert-LocalPath $active
        [IO.File]::Delete($active)
        foreach ($name in 'updater-work','updater-a','updater-b') { Remove-UpdaterDirectory $root $name }
        Write-Host '[ OK ] Launcher removed. Private configuration, logs and backups remain available for recovery.'
    } else { Install-LauncherFiles $root }
} finally { $guard.Dispose() }
