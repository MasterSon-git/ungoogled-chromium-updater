#Requires -Version 7.5
. (Join-Path $PSScriptRoot '../tools/Release.ps1')

function Assert-Equal($Actual, $Expected) {
    if ($Actual -cne $Expected) { throw "Expected [$Expected], got [$Actual]." }
}

function Assert-Fails([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        return
    }
    throw "Expected a failure matching $Pattern."
}

function New-FixtureRelease([string]$Version, [string]$Package) {
    $tag = "v$Version"
    @{
        id = 123; tag_name = $tag; draft = $false; prerelease = $Version.Contains('-'); immutable = $true
        url = "https://api.github.com/repos/$script:UpdaterRepository/releases/123"
        html_url = "https://github.com/$script:UpdaterRepository/releases/tag/$tag"
        assets = @(foreach ($file in $Package,"$Package.sig") {
            $name = [IO.Path]::GetFileName($file)
            @{
                name = $name; state = 'uploaded'; size = (Get-Item -LiteralPath $file).Length
                digest = 'sha256:' + (Get-FileHash -LiteralPath $file).Hash.ToLowerInvariant()
                browser_download_url = "https://github.com/$script:UpdaterRepository/releases/download/$tag/$name"
            }
        })
    }
}

function Publish-FixtureFeed([string]$Package, $Release) {
    foreach ($file in $Package,"$Package.sig") { Copy-Item -LiteralPath $file -Destination $feed -Force }
    Write-Json (Join-Path $feed 'releases.json') @($Release)
}

function Start-FixtureLauncher([string]$ExpectedUpdaterStatus = 'Current') {
    $workerPidFile = Join-Path $feed 'worker.pid'
    [IO.File]::Delete($state)
    [IO.File]::Delete($argumentsFile)
    [IO.File]::Delete($requestLog)
    [IO.File]::Delete($workerPidFile)
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $root 'app/ChromiumUpdater.exe'))
    $start.UseShellExecute = $false
    $start.WorkingDirectory = $feed
    foreach ($arg in $arguments) { [void]$start.ArgumentList.Add($arg) }
    $front = [Diagnostics.Process]::Start($start)
    try {
        if (!$front.WaitForExit(10000) -or $front.ExitCode -ne 0) { throw 'Fixture launcher dispatch failed.' }
        $deadline = [DateTime]::UtcNow.AddSeconds(40)
        while (![IO.File]::Exists($argumentsFile) -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 100
        }
        if (![IO.File]::Exists($argumentsFile)) {
            Get-Content (Join-Path $root 'logs/*.log') -ErrorAction SilentlyContinue | Write-Host
            throw 'Fixture browser was not launched.'
        }
        $received = Read-Json $argumentsFile
        Assert-Equal $received.directory $feed
        Assert-Equal $received.arguments.Count $arguments.Count
        for ($i = 0; $i -lt $arguments.Count; $i++) { Assert-Equal $received.arguments[$i] $arguments[$i] }
        Assert-Equal (Read-DailyState $state).Status 'Complete'
        Assert-Equal (Read-DailyState $state).UpdaterStatus $ExpectedUpdaterStatus
        $workerProcess = try { [Diagnostics.Process]::GetProcessById([int][IO.File]::ReadAllText($workerPidFile)) }
        catch [ArgumentException] { $null }
        if ($workerProcess) {
            try {
                if (!$workerProcess.WaitForExit(10000)) { throw 'Fixture worker did not exit.' }
            } finally { $workerProcess.Dispose() }
        }
    } finally { $front.Dispose() }
}

function Remove-TestDirectory([string]$Path, [string]$Expected) {
    if ($Path -ine [IO.Path]::GetFullPath($Expected)) { throw 'Unexpected self-update test directory.' }
    if (![IO.Directory]::Exists($Path)) { return }
    Assert-OrdinaryTree $Path
    Remove-Item -LiteralPath $Path -Recurse -Force
}

$id = [guid]::NewGuid()
$work = New-PrivateRoot (Join-Path $env:TEMP ('uc-self-update-tests-' + $id.ToString('N')))
$root = "$(Get-UpdaterRoot)-Test-$($id.ToString('N'))"
$signer = [Security.Cryptography.RSA]::Create(3072)
try {
    $script:UpdaterReleasePublicKey = $signer.ExportSubjectPublicKeyInfoPem()
    $order = '1.0.0-alpha','1.0.0-alpha.1','1.0.0-alpha.beta','1.0.0-beta','1.0.0-beta.2','1.0.0-beta.11','1.0.0-rc.1','1.0.0'
    for ($i = 1; $i -lt $order.Count; $i++) {
        if ((Compare-UpdaterVersion (Convert-UpdaterVersion $order[$i - 1]) (Convert-UpdaterVersion $order[$i])) -ge 0) {
            throw 'Unexpected SemVer precedence.'
        }
    }
    Assert-Equal (Compare-UpdaterVersion (Convert-UpdaterVersion '1.0.0+one') (Convert-UpdaterVersion '1.0.0+two')) 0
    Assert-Fails { Convert-UpdaterVersion '1.0.0-rc.01' } 'Invalid'
    Assert-Fails { Convert-UpdaterVersion '01.0.0' } 'Invalid'

    $source = Join-Path $work 'source'
    [void][IO.Directory]::CreateDirectory((Join-Path $source 'src'))
    $repo = Join-Path $PSScriptRoot '..'
    foreach ($relative in (Get-UpdaterPackageFiles).Values) {
        Copy-Item -LiteralPath (Join-Path $repo $relative) -Destination (Join-Path $source $relative)
    }
    $src = Join-Path $source 'src'
    $versionFile = Join-Path $src 'Updater.version'
    $pin = @('$script:UpdaterReleasePublicKey = @''', $script:UpdaterReleasePublicKey, "'@") -join "`n"
    [IO.File]::WriteAllText((Join-Path $src 'ReleaseTrust.ps1'), $pin)

    # Keep the real installer, launcher, worker, and verification code. Serve fixed replies at the transport boundary.
    $commonFile = Join-Path $src 'Common.ps1'
    Add-Content -LiteralPath $commonFile -Value @'

function Invoke-TrustedGet {
    param([uri]$Uri, [string[]]$Hosts, [long]$MaxBytes = 2097152, [int]$Seconds = 15, [string]$Destination)
    $fixture = Join-Path ([IO.Path]::GetDirectoryName($PSScriptRoot)) 'fixture-feed'
    $repo = 'MasterSon-git/ungoogled-chromium-updater'
    if ($Uri.Host -notin $Hosts -or $Seconds -le 0) { throw 'Unexpected fixture transport policy.' }
    $name = switch -Regex ($Uri.AbsoluteUri) {
        "^https://api.github.com/repos/$repo/releases\?per_page=100$" {
            [IO.File]::AppendAllText((Join-Path $fixture 'requests.txt'), "release`n")
            'releases.json'
        }
        "^https://github.com/$repo/releases/download/v[0-9a-z.-]+/(ungoogled-chromium-updater-v1\.zip(?:\.sig)?)$" { $Matches[1] }
        '^https://api.github.com/repos/ungoogled-software/ungoogled-chromium-windows/releases/latest$' { 'browser.json' }
        '^https://versionhistory.googleapis.com/' { 'chrome.json' }
        default { throw 'Unexpected fixture request.' }
    }
    $file = Join-Path $fixture $name
    if (![IO.File]::Exists($file)) { throw 'The update request timed out.' }
    if ((Get-Item -LiteralPath $file).Length -gt $MaxBytes) { throw 'Fixture asset exceeds the size limit.' }
    if ($Destination) { [IO.File]::Copy($file, $Destination) }
    else { ,([IO.File]::ReadAllBytes($file)) }
}
'@
    $handoffFile = Join-Path $src 'Handoff.ps1'
    $handoff = [IO.File]::ReadAllText($handoffFile)
    $interruptedHandoff = $handoff.Replace('        Remove-UpdaterDirectory $Root ''updater-previous-app''', @'
        if ([IO.File]::Exists((Join-Path $Root 'fixture-feed/interrupt'))) {
            [IO.File]::WriteAllText((Join-Path $Root 'fixture-feed/interrupted'), "$PID")
            [Environment]::Exit(88)
        }
        Remove-UpdaterDirectory $Root 'updater-previous-app'
'@)
    $bootstrapFile = Join-Path $src 'Update.ps1'
    $bootstrap = [IO.File]::ReadAllText($bootstrapFile).Replace("[void](Read-Host 'Press Enter to close this window')", 'Start-Sleep -Milliseconds 1500')
    [IO.File]::WriteAllText($bootstrapFile, $bootstrap)
    $launcherFile = Join-Path $src 'Launcher.cs'
    $launcher = [IO.File]::ReadAllText($launcherFile)
    $setupFile = Join-Path $src 'Setup.ps1'
    $setup = [IO.File]::ReadAllText($setupFile)
    $selfUpdateFile = Join-Path $src 'SelfUpdate.ps1'
    $selfUpdate = [IO.File]::ReadAllText($selfUpdateFile)
    $workerFile = Join-Path $src 'Worker.ps1'
    $worker = [IO.File]::ReadAllText($workerFile).Replace(
        '    $installed = Get-BrowserVersion', @'
    $fixtureRoot = [IO.Path]::GetDirectoryName($PSScriptRoot)
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'fixture-feed/worker.pid'), "$PID")
    Write-Status INFO "Fixture worker $((Get-UpdaterVersion (Join-Path $PSScriptRoot 'Updater.version')).Text) began browser checks."
    $installed = Get-BrowserVersion
'@)
    [IO.File]::WriteAllText($workerFile, $worker)

    $packages = @{}
    $releases = @{}
    $files = Get-UpdaterPackageFiles
    foreach ($version in '0.2.0-rc.2','0.2.0','0.2.1','0.3.0') {
        [IO.File]::WriteAllText($versionFile, $version)
        if ($version -eq '0.2.0') {
            [IO.File]::WriteAllText($launcherFile, $launcher.Replace(
                '            string command =', @'
            File.WriteAllText(Path.Combine(Environment.CurrentDirectory, "new-launcher.txt"), "new launcher");
            string command =
'@))
            [IO.File]::WriteAllText($bootstrapFile, $bootstrap.Replace('try { $code = Invoke-Launcher }', @'
if ($SelfUpdateOutcome -ceq 'Applied') {
    [IO.File]::WriteAllText((Join-Path ([Environment]::CurrentDirectory) 'new-bootstrap.txt'), 'new bootstrap')
}
try { $code = Invoke-Launcher }
'@))
            [IO.File]::WriteAllText((Join-Path $src 'Maintenance.txt'), 'upgraded maintenance')
            $files['Maintenance.txt'] = 'src/Maintenance.txt'
            [IO.File]::WriteAllText($selfUpdateFile, $selfUpdate.Replace(
                'function Get-UpdaterPackageFiles { Get-UpdaterCoreFiles }', @'
function Get-UpdaterPackageFiles {
    $files = Get-UpdaterCoreFiles
    $files['Maintenance.txt'] = 'src/Maintenance.txt'
    $files
}
'@))
            [IO.File]::WriteAllText($setupFile, $setup.Replace('        if ($TestInstall -eq [guid]::Empty) { Set-LauncherShortcuts $root $true }', @'
        [IO.File]::Copy((Join-Path $PSScriptRoot 'Maintenance.txt'), (Join-Path $root 'maintenance-result.txt'))
        if ($TestInstall -eq [guid]::Empty) { Set-LauncherShortcuts $root $true }
'@))
        }
        if ($version -eq '0.2.1') { [IO.File]::WriteAllText($handoffFile, $interruptedHandoff) }
        if ($version -eq '0.3.0') {
            [IO.File]::WriteAllText($workerFile, $worker.Replace('exit 42', 'exit 1'))
        }
        $dir = Join-Path $work $version
        [void][IO.Directory]::CreateDirectory($dir)
        $zip = Join-Path $dir $script:UpdaterPackageName
        New-UpdaterPackage $source $zip $files
        if ($version -eq '0.2.0') {
            $second = Join-Path $work 'reproducible.zip'
            New-UpdaterPackage $source $second $files
            Assert-Equal (Get-FileHash -LiteralPath $zip).Hash (Get-FileHash -LiteralPath $second).Hash
        }
        $env:UPDATER_SIGNING_KEY = [Convert]::ToBase64String($signer.ExportPkcs8PrivateKey())
        Write-EnvironmentUpdaterSignature $zip $version $script:UpdaterReleasePublicKey
        Assert-Equal $env:UPDATER_SIGNING_KEY $null
        $packages[$version] = $zip
        $releases[$version] = New-FixtureRelease $version $zip
    }
    $base = Convert-UpdaterVersion '0.1.0'
    $preview = $releases['0.2.0-rc.2']
    $stable = $releases['0.2.0']
    Assert-Equal (Select-UpdaterRelease @($preview) $base Stable) $null
    Assert-Equal (Select-UpdaterRelease @($preview) $base Staging).Version '0.2.0-rc.2'
    Assert-Equal (Select-UpdaterRelease @($preview,$stable) $base Staging).Version '0.2.0'
    Assert-Equal (Select-UpdaterRelease @($stable) (Convert-UpdaterVersion '0.3.0-rc.1') Stable) $null
    $wrong = $stable.Clone()
    $wrong.url = 'https://api.github.com/repos/other/repo/releases/123'
    Assert-Fails { Select-UpdaterRelease @($wrong) $base Stable } 'release identity'
    $wrong = $preview.Clone()
    $wrong.prerelease = $false
    Assert-Fails { Select-UpdaterRelease @($wrong) $base Staging } 'release identity'
    Assert-Equal (Select-UpdaterRelease @($wrong) $base Stable) $null
    $wrong = $stable.Clone()
    $wrong.immutable = $false
    Assert-Fails { Select-UpdaterRelease @($wrong) $base Stable } 'immutability'
    $wrong = $stable.Clone()
    $wrong.prerelease = $true
    Assert-Equal (Select-UpdaterRelease @($wrong) $base Stable) $null
    Assert-Fails { Select-UpdaterRelease @($wrong) $base Staging } 'release identity'

    $zip = $packages['0.2.0']
    $sig = [IO.File]::ReadAllBytes("$zip.sig")
    $size = (Get-Item -LiteralPath $zip).Length
    $hash = (Get-FileHash -LiteralPath $zip).Hash
    Assert-UpdaterSignature 'v0.2.0' $size $hash $sig
    Assert-Fails { Assert-UpdaterSignature 'v0.2.1' $size $hash $sig } 'Invalid updater release signature'
    $sig[0] = $sig[0] -bxor 1
    Assert-Fails { Assert-UpdaterSignature 'v0.2.0' $size $hash $sig } 'Invalid updater release signature'
    $sig[0] = $sig[0] -bxor 1
    Assert-Fails { Assert-UpdaterSignature 'v0.2.0' $size ('0' * 64) $sig } 'Invalid updater release signature'

    $malformed = Join-Path $work 'malformed.zip'
    Copy-Item -LiteralPath $zip -Destination $malformed
    $archive = [IO.Compression.ZipFile]::Open($malformed, 'Update')
    try {
        $archive.GetEntry('Update.ps1').Delete()
        [void]$archive.CreateEntry('../Update.ps1')
    } finally { $archive.Dispose() }
    Assert-Fails { Expand-UpdaterPackage $malformed (Join-Path $work 'escape') '0.2.0' } 'Unsafe'
    $unlisted = Join-Path $work 'unlisted.zip'
    Copy-Item -LiteralPath $zip -Destination $unlisted
    $archive = [IO.Compression.ZipFile]::Open($unlisted, 'Update')
    try {
        $entryStream = $archive.CreateEntry('Unlisted.ps1').Open()
        try { $entryStream.WriteByte(35) } finally { $entryStream.Dispose() }
    } finally { $archive.Dispose() }
    Assert-Fails { Expand-UpdaterPackage $unlisted (Join-Path $work 'unlisted') '0.2.0' } 'Invalid updater package manifest'
    Assert-Fails { Expand-UpdaterPackage $zip (Join-Path $work 'wrong-version') '0.2.1' } 'version does not match'
    Write-Output 'PASS SemVer, release identity, reproducible ZIP, signature, tampering and unsafe contents'

    [IO.File]::WriteAllText($versionFile, $base.Text)
    [IO.File]::WriteAllText($workerFile, $worker)
    [IO.File]::WriteAllText($handoffFile, $handoff)
    [IO.File]::WriteAllText($launcherFile, $launcher)
    [IO.File]::WriteAllText($bootstrapFile, $bootstrap)
    [IO.File]::WriteAllText($setupFile, $setup)
    [IO.File]::WriteAllText($selfUpdateFile, $selfUpdate)
    & (Join-Path $src 'Setup.ps1') -Install -TestInstall $id
    Assert-PrivateRoot $root
    $feed = Join-Path $root 'fixture-feed'
    $state = Join-Path $root 'state.json'
    $configPath = Join-Path $root 'config.json'
    $activePath = Join-Path $root 'app/updater-slot.json'
    $argumentsFile = Join-Path $feed 'arguments.json'
    $requestLog = Join-Path $feed 'requests.txt'
    $arguments = @('https://example.test/?a=1&b=2','quote"inside','dir with space\','', "utf-$([char]0x00e9)")
    [void][IO.Directory]::CreateDirectory($feed)
    $config = Read-Json $configPath
    $config.browserArgs = @($argumentsFile)
    $config.browserTrust.signerSha256 = '1' * 64
    $config.Remove('selfUpdateEnabled')
    $config.Remove('updaterChannel')
    Write-Json $configPath $config
    $configBefore = (Get-FileHash -LiteralPath $configPath).Hash
    $defaults = Read-Config $root
    Assert-Equal $defaults.selfUpdateEnabled $true
    Assert-Equal $defaults.updaterChannel 'Stable'
    Assert-Equal $defaults.browserUpdateMode 'Manual'
    Assert-Equal $defaults.browserTrust.signerSha256 ('1' * 64)

    $recorderSource = Join-Path $work 'Recorder.cs'
    [IO.File]::WriteAllText($recorderSource, @'
using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Web.Script.Serialization;
[assembly: AssemblyInformationalVersion("100.0.0.0")]
internal static class Recorder {
    private static void Main(string[] args) {
        var json = new JavaScriptSerializer();
        File.WriteAllText(args[0] + ".tmp", json.Serialize(new {
            directory = Environment.CurrentDirectory, arguments = args.Skip(1).ToArray()
        }));
        File.Move(args[0] + ".tmp", args[0]);
    }
}
'@)
    $browser = [IO.Path]::GetDirectoryName($config.browserPath)
    $browserVersion = '100.0.0.0'
    $tag = "$browserVersion-1"
    [void][IO.Directory]::CreateDirectory((Join-Path $browser $browserVersion))
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework/v4.0.30319/csc.exe'
    & $compiler /nologo /target:winexe /platform:x64 /reference:System.Web.Extensions.dll "/out:$($config.browserPath)" $recorderSource
    if ($LASTEXITCODE) { throw 'Could not compile the isolated argument recorder.' }
    [IO.File]::WriteAllText((Join-Path $browser 'chrome_proxy.exe'), 'fixture')
    $profile = Join-Path $config.userData 'Default'
    [void][IO.Directory]::CreateDirectory($profile)
    Write-Json (Join-Path $profile 'Preferences') @{}
    $repoUrl = 'https://github.com/ungoogled-software/ungoogled-chromium-windows'
    $asset = "ungoogled-chromium_${tag}_installer_x64.exe"
    $digest = '2' * 64
    Write-Json (Join-Path $feed 'browser.json') @{
        draft = $false; prerelease = $false; tag_name = $tag; html_url = "$repoUrl/releases/tag/$tag"
        assets = @(@{ name = $asset; state = 'uploaded'; size = 1; digest = "sha256:$digest"; browser_download_url = "$repoUrl/releases/download/$tag/$asset" })
    }
    Write-Json (Join-Path $feed 'chrome.json') @{ releases = @(@{ version = $browserVersion; fraction = 1 }) }
    Write-BrowserRelease $root @{ Tag = $tag; Digest = $digest; Architecture = 'x64' } (
        Get-InstalledBrowserIdentity $config ([version]$browserVersion))
    Publish-FixtureFeed $packages['0.2.0-rc.2'] $preview

    Start-FixtureLauncher
    Assert-Equal (Get-UpdaterSlot $root).Slot 'app'
    Assert-Equal (Get-FileHash -LiteralPath $configPath).Hash $configBefore
    $config.updaterChannel = 'Staging'
    Write-Json $configPath $config
    $configBefore = (Get-FileHash -LiteralPath $configPath).Hash
    Start-FixtureLauncher 'Applied'
    Assert-Equal (Read-Json $activePath).Version '0.2.0-rc.2'
    Assert-Equal (Get-FileHash -LiteralPath $configPath).Hash $configBefore
    Assert-Equal ([IO.File]::ReadAllLines($requestLog).Count) 1
    $logs = Get-Content (Join-Path $root 'logs/*.log') -Raw
    if ($logs -notmatch '(?s)Activated updater 0\.2\.0-rc\.2.*Fixture worker 0\.2\.0-rc\.2 began browser checks') {
        throw 'The new worker did not run the browser workflow after activation.'
    }

    Publish-FixtureFeed $zip $stable
    $config.selfUpdateEnabled = $false
    Write-Json $configPath $config
    Start-FixtureLauncher 'Skipped'
    Assert-Equal ([IO.File]::Exists($requestLog)) $false
    Assert-Equal (Read-Json $activePath).Version '0.2.0-rc.2'
    $config.selfUpdateEnabled = $true
    $config.updaterChannel = 'Stable'
    Write-Json $configPath $config
    $configBefore = (Get-FileHash -LiteralPath $configPath).Hash
    $launcherTarget = Join-Path $root 'app/ChromiumUpdater.exe'
    $launcherHash = (Get-FileHash -LiteralPath $launcherTarget).Hash
    Start-FixtureLauncher 'Applied'
    Assert-Equal (Read-Json $activePath).Version '0.2.0'
    Assert-Equal (Get-Content -LiteralPath (Join-Path $feed 'new-bootstrap.txt') -Raw) 'new bootstrap'
    Assert-Equal (Get-Content -LiteralPath (Join-Path $root 'app/Maintenance.txt') -Raw) 'upgraded maintenance'
    Assert-Equal (Get-FileHash -LiteralPath (Join-Path $root 'updater-previous-app/ChromiumUpdater.exe')).Hash $launcherHash
    Assert-Equal (Get-UpdaterVersion (Join-Path $root 'updater-a/Updater.version')).Text '0.2.0-rc.2'
    Assert-Equal (Get-FileHash -LiteralPath $configPath).Hash $configBefore
    Write-Output 'PASS Windows EXE launcher across Stable, Staging, disabled and subsequent stable releases with exact launch arguments'

    # Exit the isolated worker after the new slot is in place and before it commits the activation record.
    $update = Join-Path $root 'app/Update.ps1'
    $interrupt = Join-Path $feed 'interrupt'
    Publish-FixtureFeed $packages['0.2.1'] $releases['0.2.1']
    [IO.File]::WriteAllText($interrupt, 'interrupt')
    [IO.File]::Delete($argumentsFile)
    & ([Environment]::ProcessPath) -NoProfile -File $update -Force -Interactive
    Assert-Equal $LASTEXITCODE 20
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    $interrupted = Join-Path $feed 'interrupted'
    while (![IO.File]::Exists($interrupted) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if (![IO.File]::Exists($interrupted)) { throw 'The interrupted handoff did not reach the expected fault.' }
    Assert-Equal ([IO.File]::Exists($argumentsFile)) $false
    Assert-Equal (Read-Json $activePath).Version '0.2.0'
    Assert-Equal (Get-UpdaterVersion (Join-Path $root 'updater-a/Updater.version')).Text '0.2.1'
    Assert-Equal ([IO.Directory]::Exists((Join-Path $root 'updater-work'))) $true
    [IO.File]::Delete($interrupt)
    [IO.File]::Delete((Join-Path $feed 'releases.json'))
    Start-FixtureLauncher 'Failed'
    Assert-Equal (Get-Content -LiteralPath (Join-Path $feed 'new-launcher.txt') -Raw) 'new launcher'
    Assert-Equal (Read-Json $activePath).Version '0.2.0'
    Publish-FixtureFeed $packages['0.3.0'] $releases['0.3.0']
    Start-FixtureLauncher 'Failed'
    Assert-Equal (Read-Json $activePath).Version '0.2.0'
    Assert-Equal ([IO.Directory]::Exists((Join-Path $root 'updater-work'))) $false
    Assert-Equal (Get-UpdaterVersion (Join-Path $root 'updater-a/Updater.version')).Text '0.2.1'

    $lock = Enter-UpdateLock $root
    try {
        & ([Environment]::ProcessPath) -NoProfile -NonInteractive -File $update -Dispatch
        Assert-Equal $LASTEXITCODE 10
    } finally { $lock.Dispose() }
    $marker = Join-Path $root 'installation.json'
    Write-Json $marker @{ Interrupted = $true }
    [IO.File]::Delete($argumentsFile)
    [IO.File]::Delete($requestLog)
    & ([Environment]::ProcessPath) -NoProfile -NonInteractive -File $update -Force
    Assert-Equal $LASTEXITCODE 1
    Assert-Equal ([IO.File]::Exists($argumentsFile)) $false
    Assert-Equal ([IO.File]::Exists($requestLog)) $false

    $recovery = Join-Path $work 'recovery'
    Test-UpdaterReleasePackage $zip '0.2.0' $recovery
    [IO.File]::WriteAllText($activePath, 'interrupted')
    & (Join-Path $recovery 'Setup.ps1') -Install -TestInstall $id
    Assert-Equal (Get-UpdaterSlot $root).Slot 'app'
    Assert-Equal (Get-UpdaterVersion (Join-Path $root 'app/Updater.version')).Text '0.2.0'
    Assert-Equal (Get-FileHash -LiteralPath $configPath).Hash $configBefore
    Assert-Equal (Read-Json $marker).Interrupted $true
    [IO.File]::Delete($marker)
    Publish-FixtureFeed $zip $stable
    Start-FixtureLauncher
    Assert-Equal (Get-UpdaterSlot $root).Slot 'app'
    [IO.File]::WriteAllText((Join-Path $root 'app/ReleaseTrust.ps1'), '$script:UpdaterReleasePublicKey = ""')
    Start-FixtureLauncher 'Unavailable'
    Assert-Equal ([IO.File]::Exists($requestLog)) $false
    & (Join-Path $root 'app/Setup.ps1') -Uninstall -TestInstall $id
    Assert-Equal (Get-Content -LiteralPath (Join-Path $root 'maintenance-result.txt') -Raw) 'upgraded maintenance'
    Assert-Equal ([IO.Directory]::Exists((Join-Path $root 'app'))) $false
    Write-Output 'PASS failed network, interrupted staging, failed worker probe, concurrent dispatch, browser recovery and verified manual reinstall'
} finally {
    $signer.Dispose()
    Remove-TestDirectory $root ("$(Get-UpdaterRoot)-Test-$($id.ToString('N'))")
    Remove-TestDirectory $work (Join-Path $env:TEMP ('uc-self-update-tests-' + $id.ToString('N')))
}
