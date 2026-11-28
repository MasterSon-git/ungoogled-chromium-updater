$script:WindowsRepo = 'ungoogled-software/ungoogled-chromium-windows'

function Get-BrowserVersion([string]$Path, [string]$Architecture) {
    Assert-LocalPath $Path
    $file = Get-Item -LiteralPath $Path
    $reader = [IO.BinaryReader]::new([IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite,Delete'))
    try {
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw 'Browser executable has no PE header.' }
        $reader.BaseStream.Position = 60
        $reader.BaseStream.Position = $reader.ReadInt32()
        if ($reader.ReadUInt32() -ne 0x4550) { throw 'Browser executable has an invalid PE header.' }
        $expected = @{ x86 = 0x14c; x64 = 0x8664; arm64 = 0xaa64 }[$Architecture]
        if ($reader.ReadUInt16() -ne $expected) { throw 'Installed browser architecture differs from the configuration.' }
    } finally { $reader.Dispose() }
    Get-Version $file.VersionInfo.ProductVersion
}

function Convert-WindowsTag([string]$Tag) {
    if ($Tag -cnotmatch '^(\d+\.\d+\.\d+\.\d+)-([1-9]\d{0,5})(?:\.([1-9]\d{0,5}))?$') {
        throw 'Unexpected stable Windows release tag.'
    }
    @{ Version = Get-Version $Matches[1]; Revision = [version]::new([int]$Matches[2], [int]($Matches[3] ?? 0)) }
}

function Get-WindowsCandidate([string]$Architecture) {
    $release = Get-StableRelease $script:WindowsRepo
    $tag = Convert-WindowsTag $release.tag_name
    $asset = Get-ReleaseAsset $release $script:WindowsRepo "ungoogled-chromium_$($release.tag_name)_installer_$Architecture.exe"
    $asset.Version = $tag.Version
    $asset.Revision = $tag.Revision
    $asset.Tag = $release.tag_name
    $asset.Architecture = $Architecture
    $asset
}

function Get-UpstreamStable([string]$Architecture) {
    $platform = @{ x86 = 'win'; x64 = 'win64'; arm64 = 'win_arm64' }[$Architecture]
    $url = "https://versionhistory.googleapis.com/v1/chrome/platforms/$platform/channels/stable/versions/all/releases?filter=endtime%3Dnone%2Cfraction%3D1&order_by=version%20desc&page_size=1"
    $response = Get-RemoteJson $url 'versionhistory.googleapis.com'
    if (@($response.releases).Count -ne 1 -or $response.releases[0].fraction -ne 1) {
        throw 'Chrome Version History did not return a broadly served stable release.'
    }
    Get-Version $response.releases[0].version
}

function Test-BrowserBusy($Config) {
    $app = [IO.Path]::GetDirectoryName($Config.browserPath) + '\'
    $filter = "Name='chrome.exe' OR Name='chromium.exe' OR Name='chrome_proxy.exe' OR Name='new_chrome.exe' OR Name='setup.exe'"
    foreach ($process in (Get-CimInstance Win32_Process -Filter $filter -OperationTimeoutSec 10)) {
        if ($process.ExecutablePath -and $process.ExecutablePath.StartsWith($app,[StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
        if (!$process.ExecutablePath -and $process.Name -in 'chrome.exe','chromium.exe','chrome_proxy.exe','new_chrome.exe') {
            return $true
        }
    }
    $false
}

function Test-BrowserApproval($Approval, $Candidate) {
    $Approval -is [Collections.IDictionary] -and $Approval['tag'] -ceq $Candidate.Tag -and
        $Approval['sha256'] -ieq $Candidate.Digest
}

function Assert-BrowserTrust($Trust, $Artifact) {
    if ($Artifact.Signer) {
        if ($Trust['signerSha256'] -ine $Artifact.Signer) { throw 'The Windows installer signer does not match the configured pin.' }
    } elseif ($Trust['allowUnsigned'] -ne $true -or $Trust['signerSha256']) {
        throw 'The standing browser policy does not accept this unsigned installer.'
    }
}

function Get-InstalledBrowserIdentity($Config, [version]$Version, $ExpectedFiles) {
    $app = [IO.Path]::GetDirectoryName($Config.browserPath)
    $versionDirectory = Join-Path $app $Version.ToString()
    Assert-OrdinaryTree $versionDirectory
    [string[]]$files = @($Config.browserPath, (Join-Path $app 'chrome_proxy.exe')) +
        @(Get-ChildItem -LiteralPath $versionDirectory -File -Recurse -Force | ForEach-Object FullName)
    [Array]::Sort($files, [StringComparer]::Ordinal)
    $matched = 0
    $contents = foreach ($file in $files) {
        Assert-LocalPath $file
        $relative = [IO.Path]::GetRelativePath($app, $file)
        $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        if ($ExpectedFiles -and $ExpectedFiles.Contains($relative)) {
            if ($ExpectedFiles[$relative] -ine $hash) { return }
            $matched++
        }
        "$relative=$hash"
    }
    if ($ExpectedFiles -and $matched -ne $ExpectedFiles.Count) { return }
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($contents -join "`n")))
}

function Write-BrowserRelease([string]$Root, $Candidate, [string]$Identity, $Compatibility) {
    $record = @{
        Tag = $Candidate.Tag; Digest = $Candidate.Digest; Architecture = $Candidate.Architecture
        Identity = $Identity
    }
    if ($Compatibility) { $record.Mv2 = $Compatibility }
    Write-Json (Join-Path $Root 'browser-release.json') $record
}

function Get-InstalledMv2Evidence([string]$Root, $Config, [version]$Version) {
    try {
        $path = Join-Path $Root 'browser-release.json'
        Assert-LocalPath $path
        if (![IO.File]::Exists($path)) { return }
        $record = Read-Json $path
        if ($record['Mv2'] -and $record.Mv2.UboVersion -cmatch '^\d+\.\d+\.\d+$' -and
            $record.Mv2.UboDigest -cmatch '^[a-fA-F0-9]{64}$' -and $record.Architecture -ceq $Config.architecture -and
            (Convert-WindowsTag $record.Tag).Version -eq $Version -and
            $record.Digest -cmatch '^[a-fA-F0-9]{64}$' -and
            $record.Identity -cmatch '^[a-fA-F0-9]{64}$' -and
            $record.Identity -ceq (Get-InstalledBrowserIdentity $Config $Version)) {
            return $record.Mv2
        }
    } catch {
        Write-Status WARN 'The installed browser compatibility record is unavailable for extension reconciliation.'
    }
}

function Get-BrowserReleaseStatus([string]$Root, $Config, [version]$Installed, $Candidate) {
    if ($Candidate.Version -gt $Installed) { return 'Newer' }
    if ($Candidate.Version -lt $Installed) { return 'Older' }
    $path = Join-Path $Root 'browser-release.json'
    Assert-LocalPath $path
    if (![IO.File]::Exists($path)) { return 'UnknownRevision' }
    try {
        $record = Read-Json $path
        $tag = Convert-WindowsTag $record['Tag']
        if ($tag.Version -ne $Installed -or $record['Architecture'] -cne $Config.architecture -or
            $record['Digest'] -cnotmatch '^[a-fA-F0-9]{64}$' -or $record['Identity'] -cnotmatch '^[a-fA-F0-9]{64}$' -or
            $record['Identity'] -cne (Get-InstalledBrowserIdentity $Config $Installed)) {
            return 'UnknownRevision'
        }
    } catch { return 'UnknownRevision' }
    if ($Candidate.Revision -gt $tag.Revision) { return 'Newer' }
    if ($Candidate.Revision -lt $tag.Revision) { return 'Older' }
    if ($Candidate.Tag -cne $record.Tag -or $Candidate.Digest -ine $record.Digest) { return 'ChangedRelease' }
    'Current'
}

function Test-ArtifactFile([string]$Path, $Artifact) {
    Assert-LocalPath $Path
    (Get-Item -LiteralPath $Path).Length -eq $Artifact.Size -and
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ieq $Artifact.Digest
}

function Get-BrowserArtifact([string]$Root, $Candidate) {
    $downloads = Join-Path $Root 'downloads'
    Assert-LocalPath $downloads
    [void][IO.Directory]::CreateDirectory($downloads)
    $file = Join-Path $downloads $Candidate.Name
    Assert-LocalPath $file
    if ($Candidate.Size -gt 350MB) { throw 'The browser installer exceeds the size limit.' }
    if (!(Test-Path -LiteralPath $file) -or !(Test-ArtifactFile $file $Candidate)) {
        $temp = "$file.partial"
        Assert-LocalPath $temp
        [IO.File]::Delete($temp)
        try {
            Write-Status INFO 'Downloading the official Windows installer.'
            Invoke-TrustedGet $Candidate.Uri $script:GitHubAssetHosts $Candidate.Size 180 $temp
            if (!(Test-ArtifactFile $temp $Candidate)) { throw 'Browser installer SHA-256 or byte count mismatch.' }
            [IO.File]::Move($temp, $file, $true)
        } finally { [IO.File]::Delete($temp) }
    }
    Write-Status ' OK ' 'Windows installer matches the published SHA-256 and byte count.'
    if ((Get-BrowserVersion $file $Candidate.Architecture) -ne $Candidate.Version) {
        throw 'The Windows installer version differs from the release tag.'
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $file
    if ($signature.Status -notin 'Valid','NotSigned') { throw 'Windows installer has an invalid Authenticode status.' }
    $signer = if ($signature.Status -eq 'Valid') {
        Write-Status ' OK ' 'Authenticode is valid. Installation also requires a matching configured signer pin.'
        $signature.SignerCertificate.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256)
    } else {
        Write-Status WARN 'The installer is unsigned. GitHub SHA-256 verifies integrity of the hosted artifact.'
        $null
    }
    foreach ($item in (Get-ChildItem -LiteralPath $downloads -File -Force)) {
        if ($item.FullName -ne $file -and $item.Name -cmatch '^ungoogled-chromium_[\d.-]+_installer_(x86|x64|arm64)\.exe(?:\.partial)?$' -and
            !($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            [IO.File]::Delete($item.FullName)
        }
    }
    @{ Path = $file; Signer = $signer }
}

function Assert-OrdinaryTree([string]$Path) {
    Assert-LocalPath $Path
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Path)
    while ($pending.Count) {
        foreach ($item in (Get-ChildItem -LiteralPath $pending.Pop() -Force)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'A backup source or destination includes a link or junction.' }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
        }
    }
}

function Copy-BrowserTree([string]$Source, [string]$Destination) {
    Assert-OrdinaryTree $Source
    Assert-LocalPath $Destination
    $copy = Join-Path ([Environment]::SystemDirectory) 'robocopy.exe'
    & $copy $Source $Destination /E /COPY:DAT /DCOPY:DAT /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP *> $null
    if ($LASTEXITCODE -notin 0,1) { throw "Backup copy failed or was inconsistent (Robocopy exit $LASTEXITCODE)." }
    Assert-OrdinaryTree $Destination
    & $copy $Source $Destination /L /E /COPY:DAT /DCOPY:DAT /XJ /R:0 /W:0 /NFL /NDL /NJH /NJS /NP *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Backup verification found a missing or changed file.' }
}

function New-BrowserBackup([string]$Root, $Config, [version]$Version) {
    if (Test-BrowserBusy $Config) { throw 'The browser must be fully closed before the backup.' }
    $parent = Join-Path $Root 'backups'
    Assert-LocalPath $parent
    $name = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N')
    $backup = Join-Path $parent $name
    [void][IO.Directory]::CreateDirectory($backup)
    Write-Status INFO 'Backing up the browser and its full profile data under the private updater directory.'
    Copy-BrowserTree ([IO.Path]::GetDirectoryName($Config.browserPath)) (Join-Path $backup 'Application')
    if (Test-BrowserBusy $Config) { throw 'The browser started during backup. The backup is incomplete.' }
    Copy-BrowserTree $Config.userData (Join-Path $backup 'User Data')
    if (Test-BrowserBusy $Config) { throw 'The browser started during backup. The backup is incomplete.' }
    Write-Json (Join-Path $backup 'complete.json') @{ Version = $Version.ToString(); Created = [DateTimeOffset]::UtcNow.ToString('o') }
    $name
}

function Remove-ExpiredBackups([string]$Root, [string]$NewBackup) {
    $parent = Join-Path $Root 'backups'
    Assert-LocalPath $parent
    $previous = @(Get-ChildItem -LiteralPath $parent -Directory |
        Where-Object { $_.Name -cmatch '^\d{8}T\d{6}Z-[a-f0-9]{32}$' -and $_.Name -ne $NewBackup } |
        Sort-Object Name -Descending)
    $keptPrevious = $false
    foreach ($dir in $previous) {
        if (!$keptPrevious -and (Test-Path -LiteralPath (Join-Path $dir.FullName 'complete.json'))) {
            $keptPrevious = $true
            continue
        }
        if (![IO.Path]::GetFullPath($dir.FullName).StartsWith("$parent\",[StringComparison]::OrdinalIgnoreCase)) {
            throw 'Backup retention path escaped the backup directory.'
        }
        Assert-OrdinaryTree $dir.FullName
        Remove-Item -LiteralPath $dir.FullName -Recurse -Force
    }
}

function Assert-RegisteredInstall($Config, [version]$Version) {
    $expected = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Chromium\Application\chrome.exe'
    $expectedProfile = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Chromium\User Data'
    if ($Config.browserPath -ine $expected -or $Config.userData -ine $expectedProfile) {
        throw 'Installation is supported for the standard per-user installer layout.'
    }
    $registry = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Chromium'
    $setup = Join-Path ([IO.Path]::GetDirectoryName($Config.browserPath)) "$Version\Installer\setup.exe"
    if ($registry.DisplayVersion -ne $Version.ToString() -or !$registry.UninstallString.StartsWith('"' + $setup + '" ', [StringComparison]::OrdinalIgnoreCase) -or
        !(Test-Path -LiteralPath $setup -PathType Leaf)) { throw 'The expected per-user Chromium installation registration is missing.' }
    Assert-LocalPath $setup
}

function Install-BrowserCandidate([string]$Root, $Config, [version]$Installed, $Candidate, $Artifact, $Payload, $Compatibility) {
    Assert-BrowserTrust $Config.browserTrust $Artifact
    if (Test-BrowserBusy $Config) { return 'Deferred' }
    Assert-RegisteredInstall $Config $Installed
    $pending = Join-Path $Root 'installation.json'
    Assert-LocalPath $pending
    if (Test-Path -LiteralPath $pending) { throw 'An interrupted installation requires recovery.' }
    if ((Get-BrowserVersion $Config.browserPath $Config.architecture) -ne $Installed -or
        (Get-BrowserReleaseStatus $Root $Config $Installed $Candidate) -ne 'Newer') {
        throw 'The installed browser changed before the update.'
    }
    if ($Installed -eq $Candidate.Version -and !$Payload) { throw 'Cannot verify a same-version installer payload.' }
    $backup = New-BrowserBackup $Root $Config $Installed
    if (!(Test-ArtifactFile $Artifact.Path $Candidate)) { throw 'The staged installer changed after verification.' }
    if (Test-BrowserBusy $Config) { return 'Deferred' }
    if ((Get-BrowserVersion $Config.browserPath $Config.architecture) -ne $Installed -or
        ($Installed -eq $Candidate.Version -and (Get-BrowserReleaseStatus $Root $Config $Installed $Candidate) -ne 'Newer')) {
        throw 'The installed browser changed during backup.'
    }
    $installPreferences = Join-Path $Root 'installer-preferences.json'
    Write-Json $installPreferences @{ distribution = @{ do_not_create_any_shortcuts = $true } }
    Write-Json $pending @{ Previous = $Installed.ToString(); Candidate = $Candidate.Version.ToString()
        Tag = $Candidate.Tag; Digest = $Candidate.Digest; Backup = $backup }
    if (Test-BrowserBusy $Config) {
        [IO.File]::Delete($pending)
        [IO.File]::Delete($installPreferences)
        return 'Deferred'
    }
    Write-Status INFO 'Running the verified per-user Chromium installer.'
    $start = [Diagnostics.ProcessStartInfo]::new($Artifact.Path)
    $start.UseShellExecute = $false
    [void]$start.ArgumentList.Add('--do-not-launch-chrome')
    [void]$start.ArgumentList.Add("--installerdata=$installPreferences")
    $process = [Diagnostics.Process]::Start($start)
    try {
        if (!$process.WaitForExit(180000)) { throw 'The installer is still running. Check recovery instructions before launching.' }
        if ($process.ExitCode -ne 0) { throw "The Chromium installer exited with code $($process.ExitCode)." }
    } finally { $process.Dispose() }
    if ((Get-BrowserVersion $Config.browserPath $Config.architecture) -ne $Candidate.Version -or
        (Test-Path -LiteralPath (Join-Path ([IO.Path]::GetDirectoryName($Config.browserPath)) 'new_chrome.exe'))) {
        throw 'The installed browser version did not match the verified candidate.'
    }
    Assert-RegisteredInstall $Config $Candidate.Version
    if ($Payload -and !(Test-BrowserPayload ([IO.Path]::GetDirectoryName($Config.browserPath)) $Payload)) {
        throw 'The installed browser files do not match the verified installer payload.'
    }
    Write-BrowserRelease $Root $Candidate (Get-InstalledBrowserIdentity $Config $Candidate.Version) $Compatibility
    [IO.File]::Delete($pending)
    [IO.File]::Delete($installPreferences)
    try { Remove-ExpiredBackups $Root $backup } catch { Write-Status WARN 'Backup retention needs manual attention.' }
    'Installed'
}

function Remove-Mv2Lab([string]$Root, [string]$Lab) {
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Lab)) -ine $Root -or
        [IO.Path]::GetFileName($Lab) -cne 'mv2-work') { throw 'Unexpected compatibility workspace.' }
    Assert-OrdinaryTree $Lab
    Remove-Item -LiteralPath $Lab -Recurse -Force
}

function Start-Chromium($Config, [string[]]$BrowserArguments) {
    $start = [Diagnostics.ProcessStartInfo]::new($Config.browserPath)
    $start.WorkingDirectory = [Environment]::CurrentDirectory
    $start.UseShellExecute = $false
    foreach ($argument in @($Config.browserArgs) + $BrowserArguments) { [void]$start.ArgumentList.Add($argument) }
    [Diagnostics.Process]::Start($start).Dispose()
}

function Get-ChromiumSwitches([string[]]$Arguments) {
    $switches = @{}
    foreach ($argument in $Arguments) {
        if ($argument -ceq '--') { break }
        if ($argument -match '^(?:--?|/)([^=]+)(?:=(.*))?$') {
            $switches[$Matches[1]] = $Matches[2]
        }
    }
    $switches
}

function Test-RegularChromiumLaunch($Switches) {
    foreach ($name in 'incognito','guest','headless','app','app-id','kiosk','no-startup-window',
        'disable-extensions','disable-extensions-except','pack-extension','validate-crx') {
        if ($Switches.ContainsKey($name)) { return $false }
    }
    $true
}

function Test-ChromiumExtensionPrompt([string]$UserData, $Switches) {
    $saved = @()
    if (!$Switches.ContainsKey('no-experiments')) {
        try {
            $path = Join-Path $UserData 'Local State'
            Assert-LocalPath $path
            $data = Read-Json $path
            if ($data['browser']) {
                $saved = @(@($data['browser']['enabled_labs_experiments']) -clike 'extension-mime-request-handling@*')
            }
        } catch { return $false }
    }
    if (@($saved -cne 'extension-mime-request-handling@2').Count) { return $false }
    if ($Switches.ContainsKey('extension-mime-request-handling')) {
        return $Switches['extension-mime-request-handling'] -ceq 'always-prompt-for-install'
    }
    'extension-mime-request-handling@2' -cin $saved
}

function Find-ReadyChromium($Config, [int]$TimeoutMilliseconds = 6000) {
    if (!('ChromiumHandoffWindow' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ChromiumHandoffWindow
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string windowClass, string title);

    [DllImport("user32.dll", ExactSpelling = true)]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out int processId);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern IntPtr CommandLineToArgvW(string commandLine, out int count);

    [DllImport("kernel32.dll", ExactSpelling = true)]
    private static extern IntPtr LocalFree(IntPtr memory);

    public static int FindOwner(string userData)
    {
        IntPtr window = FindWindowExW(new IntPtr(-3), IntPtr.Zero, "Chrome_MessageWindow", userData);
        int owner = 0;
        if (window != IntPtr.Zero) GetWindowThreadProcessId(window, out owner);
        return owner;
    }

    public static string[] ReadArguments(string commandLine)
    {
        int count;
        IntPtr argv = CommandLineToArgvW(commandLine, out count);
        if (argv == IntPtr.Zero) throw new InvalidOperationException("Cannot read Chromium launch arguments.");
        try
        {
            var arguments = new string[Math.Max(0, count - 1)];
            for (int i = 1; i < count; i++)
                arguments[i - 1] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size));
            return arguments;
        }
        finally { LocalFree(argv); }
    }
}
'@
    }
    $userData = [IO.Path]::TrimEndingDirectorySeparator($Config.userData)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $owner = [ChromiumHandoffWindow]::FindOwner($userData)
        if ($owner) {
            $process = Get-Process -Id $owner -ErrorAction SilentlyContinue
            if ($process) {
                try {
                    if ($process.Path -ieq $Config.browserPath -and $process.MainWindowHandle -ne [IntPtr]::Zero -and
                        $process.Responding) { return $owner }
                } finally { $process.Dispose() }
            }
        }
        if ($timer.ElapsedMilliseconds -lt $TimeoutMilliseconds) { Start-Sleep -Milliseconds 125 }
    } while ($timer.ElapsedMilliseconds -lt $TimeoutMilliseconds)
}

function Get-RunningChromiumSwitches($Config, [int]$Owner) {
    $running = Get-CimInstance Win32_Process -Filter "ProcessId=$Owner" -OperationTimeoutSec 5
    if ($running -and $running.ExecutablePath -ieq $Config.browserPath -and $running.CommandLine) {
        Get-ChromiumSwitches ([ChromiumHandoffWindow]::ReadArguments($running.CommandLine))
    }
}
