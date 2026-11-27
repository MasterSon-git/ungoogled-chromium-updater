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

function Get-WindowsCandidate([string]$Architecture) {
    $release = Get-StableRelease $script:WindowsRepo
    if ($release.tag_name -cnotmatch '^(\d+\.\d+\.\d+\.\d+)-\d+(?:\.\d+)?$') {
        throw 'Unexpected stable Windows release tag.'
    }
    $version = Get-Version $Matches[1]
    $asset = Get-ReleaseAsset $release $script:WindowsRepo "ungoogled-chromium_$($release.tag_name)_installer_$Architecture.exe"
    $asset.Version = $version
    $asset.Tag = $release.tag_name
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

function Test-BrowserApproval($Approval, $Candidate, [version]$Stable, [bool]$HasMv2) {
    if ($Approval -isnot [Collections.IDictionary] -or $Approval['tag'] -cne $Candidate.Tag -or
        $Approval['sha256'] -ine $Candidate.Digest) { return $false }
    if ($HasMv2 -and ($Approval['mv2RuntimeVerified'] -isnot [bool] -or !$Approval['mv2RuntimeVerified'])) { return $false }
    if ($Candidate.Version -lt $Stable -and
        (!$Approval['acceptedStableVersion'] -or (Get-Version $Approval['acceptedStableVersion']) -lt $Stable)) { return $false }
    if ($Approval['allowUnsigned'] -isnot [bool]) { return $false }
    $true
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

function Install-BrowserCandidate([string]$Root, $Config, [version]$Installed, $Candidate, $Artifact) {
    $approval = $Config.browserApproval
    if ($Artifact.Signer) {
        if ($approval['signerSha256'] -ine $Artifact.Signer) { throw 'The Windows installer signer does not match the approved pin.' }
    } elseif (!$approval['allowUnsigned']) { throw 'This unsigned Windows installer lacks explicit approval.' }
    if (Test-BrowserBusy $Config) { return 'Deferred' }
    Assert-RegisteredInstall $Config $Installed
    $pending = Join-Path $Root 'installation.json'
    Assert-LocalPath $pending
    if (Test-Path -LiteralPath $pending) { throw 'An interrupted installation requires recovery.' }
    $backup = New-BrowserBackup $Root $Config $Installed
    if (!(Test-ArtifactFile $Artifact.Path $Candidate)) { throw 'The staged installer changed after verification.' }
    if (Test-BrowserBusy $Config) { return 'Deferred' }
    $installPreferences = Join-Path $Root 'installer-preferences.json'
    Write-Json $installPreferences @{ distribution = @{ do_not_create_any_shortcuts = $true } }
    Write-Json $pending @{ Previous = $Installed.ToString(); Candidate = $Candidate.Version.ToString(); Tag = $Candidate.Tag; Backup = $backup }
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
    [IO.File]::Delete($pending)
    [IO.File]::Delete($installPreferences)
    try { Remove-ExpiredBackups $Root $backup } catch { Write-Status WARN 'Backup retention needs manual attention.' }
    'Installed'
}

function Start-Chromium($Config, [string[]]$BrowserArguments) {
    $start = [Diagnostics.ProcessStartInfo]::new($Config.browserPath)
    $start.WorkingDirectory = [Environment]::CurrentDirectory
    $start.UseShellExecute = $false
    foreach ($argument in @($Config.browserArgs) + $BrowserArguments) { [void]$start.ArgumentList.Add($argument) }
    [Diagnostics.Process]::Start($start).Dispose()
}
