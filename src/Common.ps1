Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:GitHubAssetHosts = @('github.com','release-assets.githubusercontent.com','objects.githubusercontent.com')

function Get-UpdaterRoot {
    Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'UngoogledChromiumUpdater'
}

function New-PrivateRoot([string]$Root = (Get-UpdaterRoot)) {
    Assert-LocalPath $root
    $root = [IO.Path]::GetFullPath($root)
    if (!(Test-Path -LiteralPath $root)) {
        [void][IO.Directory]::CreateDirectory($root)
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        $acl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
        foreach ($sid in @(Get-AllowedSid)) {
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
        }
        Set-Acl -LiteralPath $root -AclObject $acl
    }
    Assert-PrivateRoot $root
    $root
}

function Get-AllowedSid {
    [Security.Principal.WindowsIdentity]::GetCurrent().User
    [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
}

function Assert-PrivateRoot([string]$Root) {
    Assert-LocalPath $Root
    $acl = Get-Acl -LiteralPath $Root
    $allowed = @(Get-AllowedSid)
    $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    $unsafe = @($rules | Where-Object { $_.IdentityReference -notin $allowed })
    if (!$acl.AreAccessRulesProtected -or $unsafe.Count -or
        $acl.GetOwner([Security.Principal.SecurityIdentifier]) -notin $allowed) {
        throw 'The updater directory is not private to this user and SYSTEM.'
    }
}

function Assert-LocalPath([string]$Path) {
    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path.Substring(2).Contains(':')) {
        throw 'A local drive path is required.'
    }
    for ($current = [IO.Path]::GetFullPath($Path); $current; $current = [IO.Path]::GetDirectoryName($current)) {
        if ((Test-Path -LiteralPath $current) -and
            ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'A path contains a link or junction.'
        }
    }
}

function Read-Json([string]$Path) {
    [IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable -DateKind String
}

function Write-Json([string]$Path, $Value) {
    Assert-LocalPath $Path
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $stream = [IO.FileStream]::new($temp, 'CreateNew', 'Write', 'None')
        try {
            $data = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Value -Depth 14))
            $stream.Write($data)
            $stream.Flush($true)
        } finally { $stream.Dispose() }
        [IO.File]::Move($temp, $Path, $true)
    } finally {
        [IO.File]::Delete($temp)
    }
}

function Enter-UpdateLock([string]$Root, [int]$WaitSeconds = 0) {
    $path = Join-Path $Root 'update.lock'
    Assert-LocalPath $path
    $deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
    do {
        try { return [IO.File]::Open($path, 'OpenOrCreate', 'ReadWrite', 'None') }
        catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { return }
            Start-Sleep -Milliseconds 250
        }
    } while ($true)
}

function Get-UpdaterSlot([string]$Root) {
    $app = Join-Path $Root 'app'
    $path = Join-Path $app 'updater-slot.json'
    Assert-LocalPath $path
    if (![IO.File]::Exists($path)) {
        return @{ Slot = 'app'; Directory = $app }
    }
    if ((Get-Item -LiteralPath $path).Length -gt 512) { throw 'Invalid updater activation record.' }
    $active = Read-Json $path
    if ($active.Schema -ne 1 -or $active.Slot -cnotin 'updater-a','updater-b') {
        throw 'Invalid updater activation record.'
    }
    $directory = Join-Path $Root $active.Slot
    $version = Join-Path $directory 'Updater.version'
    Assert-LocalPath $version
    $bootstrapVersion = Join-Path $app 'Updater.version'
    Assert-LocalPath $bootstrapVersion
    if ($active.Version -isnot [string] -or $active.Version.Length -gt 128 -or
        (Get-Item -LiteralPath $version).Length -gt 130 -or [IO.File]::ReadAllText($version).Trim() -cne $active.Version -or
        (Get-Item -LiteralPath $bootstrapVersion).Length -gt 130 -or
        [IO.File]::ReadAllText($bootstrapVersion).Trim() -cne $active.Version) {
        throw 'The active updater version does not match its activation record.'
    }
    @{ Slot = $active.Slot; Directory = $directory }
}

function Convert-LegacyBrowserConfig($Config) {
    if ($Config.Contains('browserUpdateMode')) { return $false }
    if ($Config['installOnLaunch'] -isnot [bool]) { throw 'Invalid legacy browser configuration.' }
    $approval = $Config['browserApproval']
    $Config['browserApproval'] = if ($approval -is [Collections.IDictionary]) {
        @{ tag = $approval['tag']; sha256 = $approval['sha256'] }
    } else { $null }
    $Config['browserUpdateMode'] = 'Manual'
    $Config['browserTrust'] = @{ allowUnsigned = $false; signerSha256 = $null }
    $Config.Remove('installOnLaunch')
    $true
}

function Read-Config([string]$Root) {
    $path = Join-Path $Root 'config.json'
    Assert-LocalPath $path
    $config = Read-Json $path
    $legacy = Convert-LegacyBrowserConfig $config
    $config['legacyBrowserConfig'] = $legacy
    if (!$config.Contains('selfUpdateEnabled')) { $config['selfUpdateEnabled'] = $true }
    if (!$config.Contains('updaterChannel')) { $config['updaterChannel'] = 'Stable' }
    if ($config['selfUpdateEnabled'] -isnot [bool] -or $config['updaterChannel'] -cnotin 'Stable','Staging') {
        throw 'Invalid updater self-update configuration.'
    }
    $trust = $config['browserTrust']
    if ($config.architecture -cnotin 'x86','x64','arm64' -or
        $config.browserUpdateMode -cnotin 'Automatic','Manual' -or
        $trust -isnot [Collections.IDictionary] -or $trust['allowUnsigned'] -isnot [bool] -or
        ($null -ne $trust['signerSha256'] -and $trust['signerSha256'] -cnotmatch '^[a-fA-F0-9]{64}$') -or
        $config.extensions -isnot [Collections.IDictionary] -or
        $config.browserArgs -isnot [array] -or @($config.browserArgs | Where-Object { $_ -isnot [string] }).Count) {
        throw 'Invalid browser configuration.'
    }
    foreach ($key in 'browserPath','userData') {
        $expanded = [Environment]::ExpandEnvironmentVariables($config[$key])
        Assert-LocalPath $expanded
        $config[$key] = [IO.Path]::GetFullPath($expanded)
    }
    if ([IO.Path]::GetFileName($config.browserPath) -ine 'chrome.exe') {
        throw 'The browser path must identify chrome.exe.'
    }
    $config
}

function Read-DailyState([string]$Path) {
    Assert-LocalPath $Path
    if (![IO.File]::Exists($Path)) { return @{ Status = 'New'; Inventory = @{} } }
    try {
        $state = Read-Json $Path
        if ($state.Schema -ne 1 -or $state.Status -cnotin 'Complete','Action','Deferred','Failed' -or
            $state.Day -cnotmatch '^\d{4}-\d{2}-\d{2}$' -or $state.Inventory -isnot [Collections.IDictionary]) {
            throw 'Malformed state.'
        }
        [void][DateTimeOffset]::ParseExact($state.Attempt, 'o', [Globalization.CultureInfo]::InvariantCulture)
        $state
    } catch { @{ Status = 'Corrupt'; Inventory = @{} } }
}

function Test-Due($State, [DateTimeOffset]$Now, [bool]$Force) {
    if ($Force -or $State.Status -in 'New','Corrupt' -or $State.Day -ne $Now.ToString('yyyy-MM-dd')) { return $true }
    if ($State.Status -eq 'Complete') { return $false }
    $attempt = [DateTimeOffset]::ParseExact($State.Attempt, 'o', [Globalization.CultureInfo]::InvariantCulture)
    $minutes = switch ($State.Status) { Action { 120 } Deferred { 15 } Failed { 30 } }
    $Now -lt $attempt -or $Now -ge $attempt.AddMinutes($minutes)
}

function Get-Version([string]$Value) {
    if ($Value -cnotmatch '^\d{1,6}(\.\d{1,6}){0,3}$') { throw 'Invalid version syntax.' }
    $parts = @($Value.Split('.') | ForEach-Object { [int]$_ })
    while ($parts.Count -lt 4) { $parts += 0 }
    [version]::new($parts[0], $parts[1], $parts[2], $parts[3])
}

function Invoke-TrustedGet {
    param([uri]$Uri, [string[]]$Hosts, [long]$MaxBytes = 2097152,
          [int]$Seconds = 15, [string]$Destination)
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('UngoogledChromiumUpdater/1.0')
    $deadline = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($Seconds))
    try {
        for ($redirects = 0; $redirects -le 4; $redirects++) {
            if (!$Uri.IsAbsoluteUri -or $Uri.Scheme -cne 'https' -or $Uri.Port -ne 443 -or
                $Uri.UserInfo -or $Uri.Fragment -or $Uri.IdnHost -notin $Hosts) {
                throw 'The download endpoint is outside the source allowlist.'
            }
            $response = $client.GetAsync($Uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $deadline.Token).GetAwaiter().GetResult()
            try {
                if ([int]$response.StatusCode -in 301,302,303,307,308) {
                    if (!$response.Headers.Location) { throw 'A redirect lacks a destination.' }
                    $Uri = [uri]::new($Uri, $response.Headers.Location)
                    continue
                }
                if (!$response.IsSuccessStatusCode) { throw "Update server returned HTTP $([int]$response.StatusCode)." }
                if ($response.Content.Headers.ContentLength -gt $MaxBytes) { throw 'Download exceeds the size limit.' }
                $inputStream = $response.Content.ReadAsStreamAsync($deadline.Token).GetAwaiter().GetResult()
                $output = if ($Destination) { [IO.File]::Open($Destination, 'CreateNew', 'Write', 'None') } else { [IO.MemoryStream]::new() }
                try {
                    $buffer = [byte[]]::new(65536)
                    $total = 0L
                    while (($count = $inputStream.ReadAsync($buffer, 0, $buffer.Length, $deadline.Token).GetAwaiter().GetResult()) -gt 0) {
                        $total += $count
                        if ($total -gt $MaxBytes) { throw 'Download exceeds the size limit.' }
                        $output.Write($buffer, 0, $count)
                    }
                    if ($null -ne $response.Content.Headers.ContentLength -and $total -ne $response.Content.Headers.ContentLength) {
                        throw 'Download length does not match the response.'
                    }
                    if (!$Destination) { return ,$output.ToArray() }
                    $output.Flush($true)
                    return
                } finally {
                    $output.Dispose()
                    $inputStream.Dispose()
                }
            } finally { $response.Dispose() }
        }
        throw 'Too many redirects.'
    } catch [OperationCanceledException] {
        throw 'The update request timed out.'
    } finally {
        $deadline.Dispose()
        $client.Dispose()
    }
}

function Get-RemoteJson([uri]$Uri, [string]$HostName) {
    [Text.Encoding]::UTF8.GetString((Invoke-TrustedGet $Uri @($HostName))) | ConvertFrom-Json -AsHashtable
}

function Get-StableRelease([ValidateSet('ungoogled-software/ungoogled-chromium-windows','gorhill/uBlock',
                                        'NeverDecaf/chromium-web-store')][string]$Repository) {
    $release = Get-RemoteJson "https://api.github.com/repos/$Repository/releases/latest" 'api.github.com'
    if ($release.draft -isnot [bool] -or $release.prerelease -isnot [bool] -or $release.draft -or $release.prerelease -or
        $release.html_url -cne "https://github.com/$Repository/releases/tag/$($release.tag_name)") {
        throw 'Unexpected GitHub stable release metadata.'
    }
    $release
}

function Get-ReleaseAsset($Release, [string]$Repository, [string]$Name) {
    $assets = @($Release.assets | Where-Object { $_.name -ceq $Name })
    if ($assets.Count -ne 1) { throw 'The expected release artifact is unavailable.' }
    $asset = $assets[0]
    $expected = "https://github.com/$Repository/releases/download/$($Release.tag_name)/$Name"
    if ($asset.browser_download_url -cne $expected -or $asset.state -cne 'uploaded' -or
        $asset.digest -cnotmatch '^sha256:[a-f0-9]{64}$' -or
        ($asset.size -isnot [int] -and $asset.size -isnot [long]) -or $asset.size -le 0) {
        throw 'Unexpected release artifact URL, size or SHA-256 metadata.'
    }
    @{ Uri = $expected; Name = $Name; Digest = $asset.digest.Substring(7); Size = [long]$asset.size }
}
