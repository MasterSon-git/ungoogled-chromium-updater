#Requires -Version 7.5
. (Join-Path $PSScriptRoot '../src/Update.ps1')

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

$script:passed = 0
function Test-Case([string]$Name, [scriptblock]$Action) {
    & $Action
    $script:passed++
    Write-Output "PASS $Name"
}

function Write-Status($Level, $Message) { }
$script:testRoot = Join-Path $env:TEMP ('uc-updater-tests-' + [guid]::NewGuid().ToString('N'))
function Get-UpdaterRoot { $script:testRoot }
$root = New-PrivateRoot

function New-BackupFixture([string]$Directory) {
    foreach ($relative in 'Application\chrome.exe','Application\158.0.8127.36\chrome.dll','User Data\Local State',
        'User Data\Default\Preferences','User Data\Default\Network\Cookies-wal','User Data\Default\Cache\cache-entry',
        'User Data\Profile 1\Secure Preferences','User Data\Profile 1\Local Extension Settings\fixture\000001.log') {
        $path = Join-Path $Directory $relative
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
        [IO.File]::WriteAllText($path, 'good')
    }
    @{ browserPath = Join-Path $Directory 'Application\chrome.exe'; userData = Join-Path $Directory 'User Data'
        architecture = 'x64'; browserTrust = @{ allowUnsigned = $true } }
}

try {
    Test-Case 'daily success, local day rollover, forced check and retry timing' {
        $now = [DateTimeOffset]::Parse('2026-11-27T18:00:00+01:00')
        $state = @{ Status = 'Complete'; Day = '2026-11-27'; Attempt = $now.ToString('o') }
        Assert-Equal (Test-Due $state $now $false) $false
        Assert-Equal (Test-Due $state $now $true) $true
        Assert-Equal (Test-Due $state $now.AddHours(7) $false) $true
        foreach ($retry in @{ Deferred = 15; Failed = 30; Action = 120 }.GetEnumerator()) {
            $state.Status = $retry.Key
            Assert-Equal (Test-Due $state $now.AddMinutes($retry.Value - 1) $false) $false
            Assert-Equal (Test-Due $state $now.AddMinutes($retry.Value) $false) $true
        }
    }

    Test-Case 'atomic state and corrupt state recovery' {
        $path = Join-Path $root 'state.json'
        Assert-Equal (Read-DailyState $path).Status 'New'
        Write-Json $path @{
            Schema = 1; Status = 'Complete'; Day = '2026-11-27'
            Attempt = [DateTimeOffset]::Now.ToString('o'); Inventory = @{}
        }
        Assert-Equal (Read-DailyState $path).Status 'Complete'
        [IO.File]::WriteAllText($path, '{invalid')
        Assert-Equal (Read-DailyState $path).Status 'Corrupt'
    }

    Test-Case 'exclusive access under concurrent launcher execution' {
        $first = Enter-UpdateLock $root
        try {
            if (!$first) { throw 'First launcher did not obtain the lock.' }
            if (Enter-UpdateLock $root) { throw 'Second launcher obtained the same lock.' }
        } finally { $first.Dispose() }
        $next = Enter-UpdateLock $root
        if (!$next) { throw 'Lock was not released.' }
        $next.Dispose()
    }

    Test-Case 'stable Windows artifact and release source validation' {
        $digest = 'a' * 64
        function Get-RemoteJson($Uri, $HostName) {
            Assert-Equal $HostName 'api.github.com'
            $tag = '158.0.8127.36-1.1'
            $source = "https://github.com/$script:WindowsRepo/releases"
            $name = "ungoogled-chromium_$($tag)_installer_x64.exe"
            @{
                draft = $false; prerelease = $false; tag_name = $tag; html_url = "$source/tag/$tag"
                assets = @(@{ name = $name; state = 'uploaded'; size = 3; digest = "sha256:$digest"
                    browser_download_url = "$source/download/$tag/$name" })
            }
        }
        $candidate = Get-WindowsCandidate x64
        Assert-Equal $candidate.Tag '158.0.8127.36-1.1'
        Assert-Equal ($candidate.Version -gt (Get-Version '150.0.7871.186')) $true
        Assert-Equal ($candidate.Version -eq (Get-Version '158.0.8127.36')) $true
        Assert-Fails { Get-WindowsCandidate arm64 } 'artifact is unavailable'
        $release = Get-RemoteJson '' 'api.github.com'
        $release.assets[0].browser_download_url = 'https://example.test/untrusted.exe'
        Assert-Fails { Get-ReleaseAsset $release $script:WindowsRepo $candidate.Name } 'Unexpected release artifact'
    }

    Test-Case 'unavailable or timed-out release check fails closed' {
        function Invoke-TrustedGet($Uri, $Hosts) { throw 'The update request timed out.' }
        Assert-Fails { Get-WindowsCandidate x64 } 'timed out'
        function Invoke-TrustedGet($Uri, $Hosts) { throw 'Update server returned HTTP 503.' }
        Assert-Fails { Get-WindowsCandidate x64 } 'HTTP 503'
    }

    Test-Case 'untrusted or plaintext transport fails before contacting the server' {
        Assert-Fails { Invoke-TrustedGet 'http://github.com/example' @('github.com') } 'source allowlist'
        Assert-Fails { Invoke-TrustedGet 'https://github.com@example.test/example' @('github.com') } 'source allowlist'
    }

    Test-Case 'migration retains exact approval and asks for new standing trust' {
        foreach ($setting in $true,$false) {
            $config = @{ installOnLaunch = $setting; browserApproval = @{ tag = '158.0.8127.36-1.1'
                sha256 = 'b' * 64; allowUnsigned = $true; mv2RuntimeVerified = $true; acceptedStableVersion = '160.1.1.1' } }
            Assert-Equal (Convert-LegacyBrowserConfig $config) $true
            Assert-Equal $config.browserUpdateMode 'Manual'
            Assert-Equal $config.browserTrust.allowUnsigned $false
            Assert-Equal $config.browserApproval.Count 2
            Assert-Equal $config.browserApproval.tag '158.0.8127.36-1.1'
            Assert-Equal ($config.ContainsKey('installOnLaunch')) $false
            Assert-Equal (Convert-LegacyBrowserConfig $config) $false
        }
    }

    Test-Case 'manual approval is exact and signature trust is independent' {
        $candidate = @{ Tag = '158.0.8127.36-1.1'; Digest = 'b' * 64; Version = [version]'158.0.8127.36' }
        $approval = @{ tag = $candidate.Tag; sha256 = $candidate.Digest }
        Assert-Equal (Test-BrowserApproval $approval $candidate) $true
        $approval.sha256 = 'c' * 64
        Assert-Equal (Test-BrowserApproval $approval $candidate) $false
        $trust = @{ allowUnsigned = $true; signerSha256 = $null }
        Assert-BrowserTrust $trust @{ Signer = $null }
        Assert-Fails { Assert-BrowserTrust $trust @{ Signer = 'a' * 64 } } 'configured pin'
        $trust.signerSha256 = 'a' * 64
        Assert-BrowserTrust $trust @{ Signer = 'A' * 64 }
        Assert-Fails { Assert-BrowserTrust $trust @{ Signer = 'b' * 64 } } 'configured pin'
        Assert-Fails { Assert-BrowserTrust $trust @{ Signer = $null } } 'standing browser policy'
    }

    Test-Case 'known packaging revisions compare numerically and unknown revisions never reinstall' {
        $version = [version]'158.0.8127.36'
        $config = @{ architecture = 'x64' }
        $candidate = @{ Tag = '158.0.8127.36-1.11'; Digest = 'b' * 64; Version = $version
            Revision = (Convert-WindowsTag '158.0.8127.36-1.11').Revision }
        $path = Join-Path $root 'browser-release.json'
        function Get-InstalledBrowserIdentity($Config, $Version) { 'a' * 64 }
        Assert-Equal (Get-BrowserReleaseStatus $root $config $version $candidate) 'UnknownRevision'
        $record = @{ Tag = '158.0.8127.36-1.2'; Digest = 'a' * 64; Architecture = 'x64'; Identity = 'a' * 64 }
        Write-Json $path $record
        Assert-Equal (Get-BrowserReleaseStatus $root $config $version $candidate) 'Newer'
        $record.Tag = '158.0.8127.36-2'
        Write-Json $path $record
        Assert-Equal (Get-BrowserReleaseStatus $root $config $version $candidate) 'Older'
        $record.Tag = $candidate.Tag
        Write-Json $path $record
        Assert-Equal (Get-BrowserReleaseStatus $root $config $version $candidate) 'ChangedRelease'
        $record.Digest = $candidate.Digest
        Write-Json $path $record
        Assert-Equal (Get-BrowserReleaseStatus $root $config $version $candidate) 'Current'
        $record.Identity = 'f' * 64
        Write-Json $path $record
        Assert-Equal (Get-BrowserReleaseStatus $root $config $version $candidate) 'UnknownRevision'
        Assert-Equal (Get-BrowserReleaseStatus $root $config ([version]'159.0.0.0') $candidate) 'Older'
        [IO.File]::Delete($path)
    }

    Test-Case 'migration records a release only with matching legacy install evidence and installed hashes' {
        $version = [version]'158.0.8127.36'
        $fixtureCandidate = @{ Tag = "$version-1.1"; Digest = 'b' * 64; Version = $version; Architecture = 'x64' }
        $approval = @{ tag = $fixtureCandidate.Tag; sha256 = $fixtureCandidate.Digest; allowUnsigned = $true }
        $app = Join-Path $root 'migration-app'
        $setup = Join-Path $app "$version\Installer\setup.exe"
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($setup))
        $config = @{ browserPath = (Join-Path $app 'chrome.exe'); architecture = 'x64' }
        $expected = @{}
        foreach ($full in $config.browserPath,(Join-Path $app 'chrome_proxy.exe'),(Join-Path $app "$version\chrome.dll"),$setup) {
            [IO.File]::WriteAllText($full, [IO.Path]::GetFileName($full))
            $expected[[IO.Path]::GetRelativePath($app, $full)] = (Get-FileHash -LiteralPath $full).Hash
        }
        $logs = Join-Path $root 'logs'
        [void][IO.Directory]::CreateDirectory($logs)
        $log = Join-Path $logs '2026-11-27.log'
        $lines = @(
            "[CHECK] Official stable ungoogled-chromium Windows build: $($fixtureCandidate.Tag)."
            '[ OK ] Windows installer matches the published SHA-256 and byte count.'
            '[INFO] Running the verified per-user Chromium installer.'
            "[ OK ] Installed and verified Chromium $version."
        ) | ForEach-Object { "2026-11-27T10:00:00.0000000+01:00 $_" }
        function Get-BrowserVersion { $version }
        function Get-WindowsCandidate { $fixtureCandidate }
        function Get-BrowserArtifact { @{ Signer = $null } }
        function Assert-RegisteredInstall { }
        function Expand-BrowserPayload($Lab, $Candidate, $Artifact, [switch]$IncludeSetup) {
            Assert-Equal $IncludeSetup.IsPresent $true
            @{ Files = $expected }
        }
        $record = Join-Path $root 'browser-release.json'
        [IO.File]::WriteAllLines($log, [string[]]$lines[0..2])
        Assert-Equal (Initialize-BrowserRelease $root $config $approval) $null
        Assert-Equal ([IO.File]::Exists($record)) $false
        [IO.File]::WriteAllLines($log, [string[]]($lines + $lines[0..2]))
        Assert-Equal (Initialize-BrowserRelease $root $config $approval) $null
        [IO.File]::WriteAllLines($log, [string[]]$lines)
        $approval.sha256 = 'c' * 64
        Assert-Equal (Initialize-BrowserRelease $root $config $approval) $null
        $approval.sha256 = $fixtureCandidate.Digest
        [IO.File]::WriteAllText($setup, 'different setup')
        Assert-Equal (Initialize-BrowserRelease $root $config $approval) $null
        Assert-Equal ([IO.File]::Exists($record)) $false
        [IO.File]::WriteAllText($setup, 'setup.exe')
        $marker = Join-Path $root 'installation.json'
        Write-Json $marker @{}
        Assert-Equal (Initialize-BrowserRelease $root $config $approval) $null
        [IO.File]::Delete($marker)
        Assert-Equal (Initialize-BrowserRelease $root $config $approval) $fixtureCandidate.Tag
        Assert-Equal (Read-Json $record).Digest $fixtureCandidate.Digest
        Assert-Equal (Read-Json $record).Identity (Get-InstalledBrowserIdentity $config $version)
        Assert-Equal ([IO.Directory]::Exists((Join-Path $root 'mv2-work'))) $false
        [IO.File]::Delete($record)
        [IO.File]::Delete($log)
    }

    Test-Case 'compatibility reporting distinguishes the verified fixture from installed extensions' {
        $messages = [Collections.Generic.List[string]]::new()
        function Write-Status($Level, $Message) { $messages.Add("$Level $Message") }
        $inventory = @(
            @{ Id = $script:UboId; Manifest = @{ version = '1.77.2.0' } }
            @{ Id = $script:OldUboId; Manifest = @{ version = '1.77.1' } }
            @{ Id = 'a' * 32; Manifest = @{ version = '3.0'; manifest_version = 2 } }
        )
        Assert-Equal (Write-CompatibilityResult @{ Status = 'Pass'; Detail = 'fixture'; UboVersion = '1.77.2' } $inventory) 'Complete'
        Assert-Equal (@($messages -like '*Other installed MV2 extensions were not tested.*').Count) 1
        Assert-Equal (@($messages -like 'WARN *1.77.1*test of 1.77.2*unverified*').Count) 1
        Assert-Equal (@($messages -like 'WARN *1.77.2.0*').Count) 0
        Assert-Equal (@($messages -like '*3.0*').Count) 0
    }

    Test-Case 'workflow installs with a patch gap or unavailable Chrome history, and requires MV2 pass' {
        $config = @{ browserPath = 'fixture'; userData = 'fixture'; architecture = 'x64'; browserArgs = @()
            browserUpdateMode = 'Automatic'; browserTrust = @{ allowUnsigned = $true; signerSha256 = $null } }
        $candidate = @{ Tag = '158.0.8127.36-1.1'; Digest = 'b' * 64; Version = [version]'158.0.8127.36' }
        $record = @{ Installs = 0; GateStatus = 'Pass'; Messages = [Collections.Generic.List[string]]::new() }
        $fixtureInventory = @(@{ Id = 'a' * 32; Location = 1; Enabled = $false; Manifest = @{ manifest_version = 2 } })
        function Write-Status($Level, $Message) { $record.Messages.Add($Message) }
        function Get-BrowserVersion { [version]'157.0.8000.1' }
        function Get-WindowsCandidate { $candidate }
        function Get-ExtensionInventory { $fixtureInventory }
        function Invoke-ExtensionChecks { @{ Status = 'Complete'; Inventory = @{} } }
        function Get-UpstreamStable { [version]'158.0.8127.89' }
        function Test-BrowserBusy { $false }
        function Assert-RegisteredInstall { }
        function Get-BrowserArtifact { @{ Signer = $null } }
        function Install-BrowserCandidate { $record.Installs++; 'Installed' }
        function Get-BrowserCompatibility($Root, $Candidate, $Artifact, $NeedsMv2) {
            Assert-Equal $NeedsMv2 $true
            @{ Status = $record.GateStatus; Detail = 'fixture'; Files = @{ 'chrome.exe' = 'hash' } }
        }
        $previous = @{ Inventory = @{} }
        $outcome = Invoke-Workflow $root $config $previous
        Assert-Equal $outcome.Status 'Complete'
        Assert-Equal $outcome.Upstream.Status 'Gap'
        Assert-Equal $record.Installs 1
        Assert-Equal (@($record.Messages -like '*158.0.8127.36 trails Chrome stable 158.0.8127.89*').Count) 1
        function Get-UpstreamStable { throw 'service unavailable' }
        $outcome = Invoke-Workflow $root $config $previous
        Assert-Equal $outcome.Status 'Complete'
        Assert-Equal $outcome.Upstream.Status 'Unavailable'
        Assert-Equal $record.Installs 2
        Assert-Equal (@($record.Messages -like '*comparison is unavailable*').Count) 1
        foreach ($gateStatus in 'Incompatible','Inconclusive','OperationalFailure') {
            $record.GateStatus = $gateStatus
            $outcome = Invoke-Workflow $root $config $previous
            Assert-Equal $outcome.Status $(if ($gateStatus -eq 'OperationalFailure') { 'Failed' } else { 'Action' })
            Assert-Equal $record.Installs 2
        }
        $record.GateStatus = 'Pass'
        $config.browserUpdateMode = 'Manual'
        $config.browserApproval = @{ tag = $candidate.Tag; sha256 = $candidate.Digest }
        [void](Invoke-Workflow $root $config $previous)
        Assert-Equal $record.Installs 2
        $Apply = $true
        $config.browserApproval.sha256 = 'c' * 64
        [void](Invoke-Workflow $root $config $previous)
        Assert-Equal $record.Installs 2
        $config.browserApproval.sha256 = $candidate.Digest
        [void](Invoke-Workflow $root $config $previous)
        Assert-Equal $record.Installs 3
        function Test-BrowserBusy { $true }
        Assert-Equal (Invoke-Workflow $root $config $previous).Status 'Deferred'
        Assert-Equal $record.Installs 3
        function Test-BrowserBusy { $false }
        function Get-BrowserArtifact { throw 'Browser installer SHA-256 or byte count mismatch.' }
        Assert-Equal (Invoke-Workflow $root $config $previous).Status 'Failed'
        Assert-Equal $record.Installs 3
    }

    Test-Case 'patch gap is visible on daily checks and does not reopen the console by itself' {
        $isolated = Join-Path $root 'daily-advisory'
        [void](New-PrivateRoot $isolated)
        $configFixture = @{ browserPath = 'fixture'; userData = 'fixture'; architecture = 'x64'; browserArgs = @()
            selfUpdateEnabled = $false; extensions = @{} }
        $installedFixture = [version]'158.0.8127.36'
        $record = @{ Stable = [version]'158.0.8127.89'; Checks = 0; Launches = 0; Messages = [Collections.Generic.List[string]]::new() }
        function Read-Config { $configFixture }
        function Get-BrowserVersion { $installedFixture }
        function Get-ExtensionInventory { }
        function Get-WindowsCandidate { $record.Checks++; @{ Tag = "$installedFixture-1"; Version = $installedFixture } }
        function Invoke-BrowserUpdate { @{ Status = 'Complete'; Version = $installedFixture } }
        function Get-UpstreamStable { $record.Stable }
        function Set-UpdaterShortcut { }
        function Write-Status($Level, $Message) { $record.Messages.Add("$Level $Message") }
        function Start-Chromium { $record.Launches++ }
        $Dispatch = $true
        Assert-Equal (Invoke-UpdateSession $isolated) 10
        Assert-Equal $record.Checks 0
        $Dispatch = $false
        $Interactive = $true
        Assert-Equal (Invoke-UpdateSession $isolated) 0
        $stateFile = Join-Path $isolated 'state.json'
        $saved = Read-DailyState $stateFile
        Assert-Equal $saved.Status 'Complete'
        Assert-Equal $saved.Upstream.Status 'Gap'
        Assert-Equal @($record.Messages -like 'WARN *trails Chrome stable*').Count 1
        $saved.Attempt = [DateTimeOffset]::Now.AddHours(-3).ToString('o')
        Write-Json $stateFile $saved
        $Dispatch = $true
        Assert-Equal (Invoke-UpdateSession $isolated) 0
        Assert-Equal $record.Checks 1
        $saved.Day = [DateTimeOffset]::Now.AddDays(-1).ToString('yyyy-MM-dd')
        Write-Json $stateFile $saved
        $record.Stable = [version]'158.0.8127.90'
        Assert-Equal (Invoke-UpdateSession $isolated) 10
        $Dispatch = $false
        $SelfUpdateOutcome = 'Failed'
        Assert-Equal (Invoke-UpdateSession $isolated) 2
        $saved = Read-DailyState $stateFile
        Assert-Equal $saved.UpdaterStatus 'Failed'
        Assert-Equal $saved.Status 'Complete'
        Assert-Equal $saved.Upstream.Version '158.0.8127.90'
        Assert-Equal @($record.Messages -like 'WARN *trails Chrome stable 158.0.8127.90*').Count 1
        Assert-Equal $record.Launches 3
    }

    Test-Case 'MV2 cache only accepts exact verified identities and successful runs' {
        $candidate = @{ Tag = '158.0.8127.36-1.1'; Digest = 'b' * 64; Version = [version]'158.0.8127.36'
            Architecture = 'x64'; Size = 10 }
        $asset = @{ Version = '1.77.2'; Digest = 'c' * 64; Size = 5 }
        $artifact = @{ Signer = $null; Path = 'staged' }
        $fixture = @{ Attempts = 0; Status = 'Incompatible'; ArtifactMatches = $true }
        function Test-ArtifactFile { $fixture.ArtifactMatches }
        function Get-ExtensionRelease { $asset }
        function Get-VerifiedExtensionPackage { @{ Manifest = @{ manifest_version = 2; update_url = $script:UboUrl } } }
        function Expand-BrowserPayload {
            if (!$fixture.ArtifactMatches) { throw [NotSupportedException]::new('Payload mismatch.') }
            @{ Exe = 'fixture.exe'; Files = @{ 'chrome.exe' = 'hash'; '158.0.8127.36\chrome.dll' = 'hash' } }
        }
        function Invoke-Mv2Fixture {
            $fixture.Attempts++
            if ($fixture.Status -eq 'Timeout') { throw [TimeoutException]::new() }
            @{ Status = $fixture.Status; Detail = 'fixture' }
        }
        $cache = Join-Path $root 'mv2-pass.json'
        Assert-Equal (Get-BrowserCompatibility $root $candidate $artifact $true).Status 'Incompatible'
        Assert-Equal (Test-Path -LiteralPath $cache) $false
        $fixture.Status = 'Timeout'
        $result = Get-BrowserCompatibility $root $candidate $artifact $true
        Assert-Equal $result.Status 'OperationalFailure'
        Assert-Equal ($result.Detail -like '*timed out*') $true
        Assert-Equal (Test-Path -LiteralPath $cache) $false
        $fixture.ArtifactMatches = $false
        Assert-Equal (Get-BrowserCompatibility $root $candidate $artifact $true).Status 'Inconclusive'
        Assert-Equal $fixture.Attempts 2
        $fixture.ArtifactMatches = $true
        $fixture.Status = 'Pass'
        foreach ($attempt in 1..2) {
            $result = Get-BrowserCompatibility $root $candidate $artifact $true
            Assert-Equal $result.Status 'Pass'
            Assert-Equal $result.UboVersion $asset.Version
        }
        Assert-Equal $fixture.Attempts 3
        $fixture.ArtifactMatches = $false
        Assert-Equal (Get-BrowserCompatibility $root $candidate $artifact $true).Status 'OperationalFailure'
        $fixture.ArtifactMatches = $true
        $asset.Digest = 'd' * 64
        Assert-Equal (Get-BrowserCompatibility $root $candidate $artifact $true).Status 'Pass'
        $candidate.Digest = 'e' * 64
        Assert-Equal (Get-BrowserCompatibility $root $candidate $artifact $true).Status 'Pass'
        $oldCache = Read-Json $cache
        $oldCache.Key = $oldCache.Key -replace '^1/', '0/'
        Write-Json $cache $oldCache
        Assert-Equal (Get-BrowserCompatibility $root $candidate $artifact $true).Status 'Pass'
        Assert-Equal $fixture.Attempts 6
        Assert-Equal (Test-Path -LiteralPath (Join-Path $root 'mv2-work')) $false
    }

    Test-Case 'artifact checksum failure' {
        $file = Join-Path $root 'fixture.bin'
        [IO.File]::WriteAllBytes($file, [byte[]]@(0,1,2))
        $asset = @{ Size = 3; Digest = (Get-FileHash -LiteralPath $file).Hash }
        Assert-Equal (Test-ArtifactFile $file $asset) $true
        [IO.File]::WriteAllBytes($file, [byte[]]@(3,4,5))
        Assert-Equal (Test-ArtifactFile $file $asset) $false
    }

    Test-Case 'profile discovery, disabled state and unknown extension source' {
        $profiles = Join-Path $root 'profiles'
        $default = Join-Path $profiles 'Default'
        [void][IO.Directory]::CreateDirectory($default)
        $first = 'a' * 32
        $second = 'b' * 32
        $records = @{
            $first = @{ location = 1; disable_reasons = @(2); manifest = @{ version = '1.2'; update_url = $script:StoreUrl } }
            $second = @{ location = 1; manifest = @{ version = '2.0'; update_url = 'https://example.test/update' } }
        }
        Write-Json (Join-Path $default 'Secure Preferences') @{ extensions = @{ settings = $records } }
        $inventory = @(Get-ExtensionInventory $profiles)
        Assert-Equal $inventory.Count 2
        Assert-Equal $inventory[0].Enabled $false
        Assert-Equal $inventory[1].Enabled $true
        Assert-Equal (Get-ExtensionChannel $inventory[0] @{}) 'Unknown'
        Assert-Equal (Get-ExtensionChannel $inventory[0] @{ $first = 'ChromeWebStore' }) 'Store'
        Assert-Equal (Get-ExtensionChannel $inventory[1] @{ $second = 'ChromeWebStore' }) 'Unknown'
    }

    Test-Case 'Web Store XML accepts an update and rejects mismatched app ID or host' {
        $id = 'a' * 32
        $replyId = $id
        $hostName = 'clients2.googleusercontent.com'
        function Invoke-TrustedGet($Uri, $Hosts) {
            Assert-Equal $Hosts[0] 'clients2.google.com'
            $digest = 'd' * 64
            $xml = "<gupdate xmlns='http://www.google.com/update2/response'><app appid='$replyId'><updatecheck status='ok' version='2.1' size='12' hash_sha256='$digest' codebase='https://$hostName/crx/blobs/asset.crx'/></app></gupdate>"
            return ,[Text.Encoding]::UTF8.GetBytes($xml)
        }
        $packages = Get-StoreUpdates @($id) ([version]'158.0.8127.36')
        Assert-Equal $packages[$id].Version '2.1'
        $replyId = 'b' * 32
        Assert-Fails { Get-StoreUpdates @($id) ([version]'158.0.8127.36') } 'Unexpected extension identity'
        $replyId = $id
        $hostName = 'example.test'
        Assert-Fails { Get-StoreUpdates @($id) ([version]'158.0.8127.36') } 'Unexpected Web Store artifact'
    }

    Test-Case 'approved channels stage only exact verified bytes and verify actual installed identity' {
        function Assert-ExtensionKey($Id, $Manifest) { }
        $installed = @{ version = '1.0'; manifest_version = 3; permissions = @('storage'); update_url = $script:StoreUrl }
        $remote = @{ version = '1.1'; manifest_version = 3; permissions = @('storage'); update_url = $script:StoreUrl }
        [byte[]]$bytes = @(0,1,2,3)
        $asset = @{ Version = '1.1'; Size = $bytes.Length; Digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) }
        $fixture = @{ Store = $true; ExpectedId = 'a' * 32 }
        function Get-VerifiedExtensionPackage($Asset, $Id, $Store) {
            Assert-Equal $Id $fixture.ExpectedId
            Assert-Equal $Store $fixture.Store
            @{ Manifest = $remote; Bytes = $bytes }
        }
        $extension = @{ Id = $fixture.ExpectedId; Manifest = $installed; Enabled = $false }
        $version = [version]'158.0.8127.36'
        $update = Test-ExtensionCandidate $extension 'Store' $asset $version $false
        Assert-Equal $update.Update 'Verified'
        Assert-Equal (Test-Path -LiteralPath (Join-Path $root 'extension-packages')) $false
        $remote.permissions += 'tabs'
        $update = Test-ExtensionCandidate $extension 'Store' $asset $version $false $root
        Assert-Equal $update.Update 'Pending'
        Assert-Equal (Test-ArtifactFile $update.Path $asset) $true
        if ($update.Text -notlike '*changed permission*disabled*') { throw 'Expected permission and disabled-state notices.' }
        [IO.File]::WriteAllBytes($update.Path, [byte[]]@(4,3,2,1))
        $update = Test-ExtensionCandidate $extension 'Store' $asset $version $false $root
        Assert-Equal (Test-ArtifactFile $update.Path $asset) $true
        $installed.version = '1.1'
        Assert-Fails { Test-ExtensionCandidate $extension 'Store' $asset $version $true } 'differ from the signed package'
        $installed.permissions = $remote.permissions
        Assert-Equal (Test-ExtensionCandidate $extension 'Store' $asset $version $true).Update 'Installed'
        Assert-Equal $extension.Enabled $false
        $diskManifest = Join-Path $root 'extension-manifest.json'
        $registered = [pscustomobject]@{ Id = $extension.Id; Enabled = $false; Manifest = $installed; ManifestPath = $diskManifest }
        Write-Json $diskManifest $installed
        Assert-Equal (Test-ExtensionCandidate $registered 'Store' $asset $version $true).Update 'Installed'
        Write-Json $diskManifest ($installed + @{ externally_connectable = @{ ids = @('*') } })
        Assert-Fails { Test-ExtensionCandidate $registered 'Store' $asset $version $true } 'differ from the signed manifest evidence'
        $installed.version = '1.0'
        $remote.update_url = 'https://example.test/update'
        Assert-Fails { Test-ExtensionCandidate $extension 'Store' $asset $version $false } 'changed its update source'
        $fixture.Store = $false
        foreach ($channel in 'WebStoreHelper','Ubo') {
            $fixture.ExpectedId = if ($channel -ceq 'Ubo') { $script:UboId } else { $script:WebStoreId }
            $remote.update_url = if ($channel -ceq 'Ubo') { $script:UboUrl } else { $script:WebStoreUrl }
            if ($channel -ceq 'Ubo') { $remote.manifest_version = 2 }
            $extension.Id = $fixture.ExpectedId
            $update = Test-ExtensionCandidate $extension $channel $asset $version $false $root
            Assert-Equal $update.Update 'Pending'
            Assert-Equal (Test-ArtifactFile $update.Path $asset) $true
        }
    }

    Test-Case 'permission snapshots preserve associations and detect removed restrictions' {
        $first = @{ matches = @('https://one.test/*','https://other.test/*'); js = @('first.js')
            include_globs = @('*limited*'); exclude_matches = @('https://one.test/no/*'); exclude_globs = @('*private*') }
        $second = @{ matches = @('https://two.test/*'); js = @('second.js') }
        $baseline = @{ content_scripts = @($first,$second); optional_permissions = @('tabs')
            externally_connectable = @{ ids = @('a' * 32) }; content_security_policy = @{ extension_pages = "script-src 'self'" } }
        $old = @(Get-ManifestPermissions $baseline)
        $candidate = $baseline.Clone()
        $firstNew = $first.Clone()
        $secondNew = $second.Clone()
        $candidate.content_scripts = @($secondNew,$firstNew)
        $firstNew.matches = @('https://other.test/*','https://one.test/*')
        $firstNew.all_frames = $false
        Assert-Equal @(Compare-PermissionSnapshots $old (Get-ManifestPermissions $candidate)).Count 0
        $firstNew.js = $second.js
        $secondNew.js = $first.js
        Assert-Equal (Compare-PermissionSnapshots $old (Get-ManifestPermissions $candidate)) 'content_scripts'
        $firstNew.js = $first.js
        $secondNew.js = $second.js
        foreach ($field in 'include_globs','exclude_matches','exclude_globs') {
            $firstNew.Remove($field)
            Assert-Equal (Compare-PermissionSnapshots $old (Get-ManifestPermissions $candidate)) 'content_scripts'
            $firstNew[$field] = $first[$field]
        }
        $firstNew.match_origin_as_fallback = $true
        Assert-Equal (Compare-PermissionSnapshots $old (Get-ManifestPermissions $candidate)) 'content_scripts'
        $firstNew.Remove('match_origin_as_fallback')
        foreach ($field in 'externally_connectable','content_security_policy') {
            $candidate.Remove($field)
            Assert-Equal (Compare-PermissionSnapshots $old (Get-ManifestPermissions $candidate)) $field
            $candidate[$field] = $baseline[$field]
        }
        $candidate.Remove('optional_permissions')
        $candidate.permissions = @('tabs')
        Assert-Equal (Compare-PermissionSnapshots $old (Get-ManifestPermissions $candidate)) 'permissions'
    }

    Test-Case 'uBlock compatibility follows actual version, identity, package and profile outcome' {
        $tested = @{ UboVersion = '1.2.0'; UboDigest = 'a' * 64 }
        $bytes = [byte[]]@(1)
        $asset = @{ Version = $tested.UboVersion; Digest = $tested.UboDigest; Size = $bytes.Length }
        $manifest = @{ version = $asset.Version; manifest_version = 2; update_url = $script:UboUrl }
        $pending = $manifest.Clone()
        $pending.version = '1.1.0'
        $failed = $manifest.Clone()
        $failed.permissions = @('tabs')
        $legacy = $manifest.Clone()
        $legacy.update_url = $script:StoreUrl
        function Assert-ExtensionKey { }
        function Get-StoreUpdates { @{} }
        function Get-ExtensionRelease { $asset }
        function Get-VerifiedExtensionPackage { @{ Manifest = $manifest; Bytes = $bytes } }
        function Save-VerifiedExtensionPackage { 'fixture.crx' }
        $messages = [Collections.Generic.List[string]]::new()
        function Write-Status($Level, $Message) { $messages.Add($Message) }
        $inventory = @(
            @{ Profile = 'Match'; Id = $script:UboId; Enabled = $false; Location = 1; Manifest = $manifest }
            @{ Profile = 'Pending'; Id = $script:UboId; Enabled = $true; Location = 1; Manifest = $pending }
            @{ Profile = 'Failed'; Id = $script:UboId; Enabled = $true; Location = 1; Manifest = $failed }
            @{ Profile = 'Legacy'; Id = $script:OldUboId; Enabled = $true; Location = 1; Manifest = $legacy }
        )
        $outcome = Invoke-ExtensionChecks $inventory @{ extensions = @{} } ([version]'158.0.8127.36') @{} $false $root $tested
        Assert-Equal $outcome.Inventory["Match/$script:UboId"].Update 'Installed'
        Assert-Equal $outcome.Inventory["Match/$script:UboId"].Enabled $false
        Assert-Equal $outcome.Inventory["Pending/$script:UboId"].Version '1.1.0'
        Assert-Equal $outcome.Inventory["Pending/$script:UboId"].Update 'Pending'
        Assert-Equal $outcome.Inventory["Failed/$script:UboId"].Update 'Failed'
        Assert-Equal @($messages -like '*match the tested Chromium*').Count 1
        Assert-Equal @($messages -like '*installed combination is unverified*').Count 3
        $messages.Clear()
        $tested.UboDigest = 'b' * 64
        [void](Invoke-ExtensionChecks @($inventory[0]) @{ extensions = @{} } ([version]'158.0.8127.36') $outcome.Inventory $false $root $tested)
        Assert-Equal @($messages -like '*match the tested Chromium*').Count 0
        Assert-Equal @($messages -like '*is no longer registered*').Count 3
    }

    Test-Case 'CRX prompt configuration detects saved and active switches without editing Chromium' {
        $data = Join-Path $root 'prompt-config'
        [void][IO.Directory]::CreateDirectory($data)
        $path = Join-Path $data 'Local State'
        $prompt = '--extension-mime-request-handling=always-prompt-for-install'
        Write-Json $path @{ browser = @{ enabled_labs_experiments = @('unrelated@1','extension-mime-request-handling@2') } }
        $original = Get-FileHash -LiteralPath $path
        Assert-Equal (Test-ChromiumExtensionPrompt $data @{}) $true
        Assert-Equal (Test-ChromiumExtensionPrompt $data (Get-ChromiumSwitches @('--no-experiments'))) $false
        Assert-Equal (Test-ChromiumExtensionPrompt $data (Get-ChromiumSwitches @('--no-experiments',$prompt))) $true
        Assert-Equal (Test-ChromiumExtensionPrompt $data (Get-ChromiumSwitches @('--extension-mime-request-handling=download-as-regular-file'))) $false
        Assert-Equal (Get-FileHash -LiteralPath $path).Hash $original.Hash
        Write-Json $path @{ browser = @{ enabled_labs_experiments = @('extension-mime-request-handling@1') } }
        Assert-Equal (Test-ChromiumExtensionPrompt $data (Get-ChromiumSwitches @($prompt))) $false
        Write-Json $path @{ browser = @{} }
        Assert-Equal (Test-ChromiumExtensionPrompt $data @{}) $false
        Assert-Equal (Test-ChromiumExtensionPrompt $data (Get-ChromiumSwitches @($prompt))) $true
        Assert-Equal (Test-RegularChromiumLaunch (Get-ChromiumSwitches @('/INCOGNITO'))) $false
        Assert-Equal (Test-RegularChromiumLaunch (Get-ChromiumSwitches @('--','--guest'))) $true
    }

    Test-Case 'native CRX requests batch per profile and suppress identical pending requests' {
        $data = Join-Path $root 'handoff-data'
        [void][IO.Directory]::CreateDirectory($data)
        $statePath = Join-Path $root 'handoff-state.json'
        $exe = Join-Path $root 'chrome.exe'
        $fixture = @{ Prompt = $true; Owner = 42; FailLaunch = $false; Calls = [Collections.Generic.List[object]]::new() }
        $fixtureConfig = @{ userData = $data; browserPath = $exe; browserArgs = @("--user-data-dir=$data"); extensions = @{} }
        $versions = @{ version = '1.1'; manifest_version = 2; update_url = $script:UboUrl }
        $helperManifest = @{ version = '1.1'; manifest_version = 3; update_url = $script:WebStoreUrl }
        $inventory = @(
            @{ Profile = 'Default'; Id = $script:UboId; Location = 1; Enabled = $false; Manifest = $versions }
            @{ Profile = 'Default'; Id = $script:WebStoreId; Location = 1; Enabled = $true; Manifest = $helperManifest }
            @{ Profile = 'Profile 1'; Id = $script:UboId; Location = 1; Enabled = $true; Manifest = $versions.Clone() }
        )
        $state = @{ Inventory = @{} }
        $i = 0
        $candidates = @(foreach ($entry in $inventory) {
            $key = "$($entry.Profile)/$($entry.Id)"
            $state.Inventory[$key] = @{ Version = '1.1'; Enabled = $entry.Enabled; Update = 'Pending' }
            $package = Join-Path $root "package-$i.crx"
            [IO.File]::WriteAllBytes($package, [byte[]]@($i++))
            @{ Key = $key; Profile = $entry.Profile; Channel = Get-ExtensionChannel $entry @{}; Version = '1.1'
                Path = $package; Asset = @{ Version = '1.2'; Size = 1; Digest = (Get-FileHash -LiteralPath $package).Hash } }
        })
        function Find-ReadyChromium { $fixture.Owner }
        function Get-RunningChromiumSwitches { @{} }
        function Test-ChromiumExtensionPrompt { $fixture.Prompt }
        function Get-ExtensionInventory { $inventory }
        function Assert-ExtensionKey { }
        function Start-Chromium($Config, $Arguments) {
            Assert-Equal $Config.browserPath $exe
            Assert-Equal $Config.browserArgs.Count 0
            $saved = Read-Json $statePath
            foreach ($c in ($candidates | Where-Object Path -cin $Arguments)) {
                Assert-Equal $saved.Inventory[$c.Key].HandoffDigest $c.Asset.Digest
            }
            if ($fixture.FailLaunch) { throw 'Fixture process creation failed.' }
            $fixture.Calls.Add($Arguments)
        }
        $fixture.Prompt = $false
        Assert-Equal (Invoke-ExtensionHandoffs $fixtureConfig @() $candidates $state $statePath $false) $false
        Assert-Equal $fixture.Calls.Count 0
        $queued = Read-Json $statePath
        Assert-Equal $queued.Inventory[$candidates[0].Key].AwaitingPromptDigest $candidates[0].Asset.Digest
        Assert-Equal (Test-RequestedExtensionUpdates $queued.Inventory) $false
        Assert-Equal (Invoke-ExtensionHandoffs $fixtureConfig @() $candidates $state $statePath $false) $true
        $fixture.Prompt = $true
        Assert-Equal (Invoke-ExtensionHandoffs $fixtureConfig @('--user-data-dir=C:\other') $candidates $state $statePath $false) $false
        Assert-Equal (Invoke-ExtensionHandoffs $fixtureConfig @('--incognito') $candidates $state $statePath $false) $false
        $fixture.Owner = 0
        Assert-Equal (Invoke-ExtensionHandoffs $fixtureConfig @() $candidates $state $statePath $false) $false
        $fixture.Owner = 42
        Assert-Equal (Invoke-ExtensionHandoffs $fixtureConfig @() $candidates $state $statePath $false) $true
        Assert-Equal $fixture.Calls.Count 2
        Assert-Equal $fixture.Calls[0].Count 4
        Assert-Equal $fixture.Calls[0][1] '--profile-directory=Default'
        Assert-Equal $fixture.Calls[1][1] '--profile-directory=Profile 1'
        Assert-Equal $fixture.Calls[1][2] $candidates[2].Path
        Assert-Equal $state.Inventory[$candidates[0].Key].Enabled $false
        Assert-Equal $state.Inventory[$candidates[0].Key].Update 'Pending'
        Assert-Equal (Invoke-ExtensionHandoffs $fixtureConfig @() $candidates $state $statePath $false) $true
        Assert-Equal $fixture.Calls.Count 2
        $first = $candidates[0]
        $fixture.Prompt = $false
        Assert-Equal (Invoke-ExtensionHandoffs $fixtureConfig @() @($first) $state $statePath $true) $false
        Assert-Equal $state.Inventory[$first.Key].AwaitingPromptDigest $first.Asset.Digest
        Assert-Equal $state.Inventory[$first.Key].HandoffDigest $first.Asset.Digest
        $fixture.Prompt = $true
        Assert-Equal (Invoke-ExtensionHandoffs $fixtureConfig @() @($first) $state $statePath $false) $true
        Assert-Equal $fixture.Calls.Count 3
        # A registered version change and a corrupt CRX both block a handoff.
        [IO.File]::WriteAllBytes($candidates[1].Path, [byte[]]@(10))
        $inventory[2].Manifest.version = '1.2'
        Assert-Equal (Invoke-ExtensionHandoffs $fixtureConfig @() $candidates $state $statePath $true) $false
        Assert-Equal $fixture.Calls.Count 4
        Assert-Equal $fixture.Calls[3].Count 3
        Assert-Equal $fixture.Calls[3][2] $first.Path
        $fixture.FailLaunch = $true
        $state.Inventory[$first.Key].Remove('HandoffDigest')
        Assert-Equal (Invoke-ExtensionHandoffs $fixtureConfig @() @($first) $state $statePath $false) $false
        $saved = Read-Json $statePath
        Assert-Equal $saved.Inventory[$first.Key]['HandoffDigest'] $null
        Assert-Equal $saved.Inventory[$first.Key]['AwaitingPromptDigest'] $null
        Assert-Equal (Test-RequestedExtensionUpdates @{ First = $saved.Inventory[$first.Key] }) $false
    }

    Test-Case 'missing prompt setting resumes verified handoff before the daily check is due' {
        $isolated = Join-Path $root 'prompt-resume'
        [void][IO.Directory]::CreateDirectory($isolated)
        $localState = Join-Path $isolated 'Local State'
        Write-Json $localState @{ browser = @{ enabled_labs_experiments = @() } }
        $fixture = @{ Checks = 0; BrowserStarts = 0; Handoffs = 0; Messages = [Collections.Generic.List[string]]::new() }
        $fixtureConfig = @{ userData = $isolated; architecture = 'x64'; browserPath = 'fixture'; selfUpdateEnabled = $false
            browserArgs = @("--user-data-dir=$isolated"); extensions = @{} }
        $version = [version]'158.0.8127.88'
        $bytes = [byte[]]@(0, 1, 2)
        $asset = @{ Version = '1.77.4'; Size = $bytes.Length
            Digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) }
        $manifest = @{ version = '1.77.2'; manifest_version = 2; update_url = $script:UboUrl }
        $remote = $manifest.Clone()
        $remote.version = $asset.Version
        $key = "Default/$script:UboId"
        function Read-Config { $fixtureConfig }
        function Get-BrowserVersion { $version }
        function Get-WindowsCandidate { $fixture.Checks++; @{ Tag = "$version-1"; Version = $version } }
        function Invoke-BrowserUpdate { @{ Status = 'Complete'; Version = $version } }
        function Get-UpstreamStable { $version }
        function Get-StoreUpdates { @{} }
        function Get-ExtensionRelease { $asset }
        function Get-VerifiedExtensionPackage { @{ Manifest = $remote; Bytes = $bytes } }
        function Assert-ExtensionKey { }
        function Get-ExtensionInventory {
            [pscustomobject]@{ Id = $script:UboId; Profile = 'Default'; Manifest = $manifest; Enabled = $true; Location = 1 }
        }
        function Find-ReadyChromium { 42 }
        function Get-RunningChromiumSwitches { @{} }
        function Set-UpdaterShortcut { }
        function Write-Status($Level, $Message) { $fixture.Messages.Add($Message) }
        function Start-Chromium($Config, $Arguments) {
            if (@($Arguments).Count -eq 3) { $fixture.Handoffs++ } else { $fixture.BrowserStarts++ }
        }
        $statePath = Join-Path $isolated 'state.json'
        Assert-Equal (Invoke-UpdateSession $isolated) 2
        $waiting = Read-DailyState $statePath
        Assert-Equal $waiting.Inventory[$key].AwaitingPromptDigest $asset.Digest
        Assert-Equal (Test-Due $waiting ([DateTimeOffset]::Now) $false) $false
        Assert-Equal $fixture.Handoffs 0
        Assert-Equal @($fixture.Messages -like '*Always prompt for install*relaunch Chromium*').Count 1
        Assert-Equal @($fixture.Messages -like '*-Force*').Count 0
        $Dispatch = $true
        Assert-Equal (Invoke-UpdateSession $isolated) 0
        Assert-Equal $fixture.Checks 1
        Assert-Equal $fixture.BrowserStarts 2
        Write-Json $localState @{ browser = @{ enabled_labs_experiments = @('extension-mime-request-handling@2') } }
        $BrowserArguments = @('--incognito')
        Assert-Equal (Invoke-UpdateSession $isolated) 0
        $BrowserArguments = @()
        Assert-Equal (Invoke-UpdateSession $isolated) 10
        Assert-Equal $fixture.Checks 1
        $Dispatch = $false
        $Interactive = $true
        Assert-Equal (Invoke-UpdateSession $isolated) 21
        Assert-Equal $fixture.Checks 2
        Assert-Equal $fixture.Handoffs 1
        $submitted = Read-DailyState $statePath
        Assert-Equal $submitted.Inventory[$key]['AwaitingPromptDigest'] $null
        Assert-Equal $submitted.Inventory[$key].HandoffDigest $asset.Digest
        Assert-Equal (Test-RequestedExtensionUpdates $submitted.Inventory) $true
        Assert-Equal (Invoke-UpdateSession $isolated) 0
        Assert-Equal $fixture.Handoffs 1
    }

    Test-Case 'extension actions offer an opt-in retry for previously submitted updates' {
        $fixture = @{ Answer = 'R'; Reads = 0 }
        function Read-Host([string]$Prompt) {
            Assert-Equal ($Prompt -like '*press Enter to continue*') $true
            $fixture.Reads++
            $fixture.Answer
        }
        $digest = 'a' * 64
        $record = @{ Update = 'Pending'; OfferedDigest = $digest; AwaitingPromptDigest = $digest }
        $state = @{ Inventory = @{ 'Default/fixture' = $record } }
        Assert-Equal (Read-ExtensionRetryChoice $state) $false
        Assert-Equal $fixture.Reads 0
        $record.Remove('AwaitingPromptDigest')
        $record.HandoffDigest = $digest
        Assert-Equal (Read-ExtensionRetryChoice $state) $true
        $fixture.Answer = ''
        Assert-Equal (Read-ExtensionRetryChoice $state) $false
        Assert-Equal $fixture.Reads 2
        $record.OfferedDigest = 'b' * 64
        Assert-Equal (Test-RequestedExtensionUpdates $state.Inventory) $false
    }

    Test-Case 'the console choice reaches the normal launcher once and only when requested' {
        $isolated = Join-Path $root 'retry-console'
        [void](New-PrivateRoot $isolated)
        $now = [DateTimeOffset]::Now
        Write-Json (Join-Path $isolated 'state.json') @{
            Schema = 1; Status = 'Action'; Day = $now.ToString('yyyy-MM-dd'); Attempt = $now.ToString('o')
            Inventory = @{ 'Default/fixture' = @{ Update = 'Pending'; HandoffDigest = 'a' * 64 } }
        }
        [IO.File]::WriteAllText((Join-Path $isolated 'Worker.ps1'), @'
function Invoke-UpdateSession([string]$Root) {
    $fixture.Retries.Add([bool]$RetryExtensionUpdates)
    0
}
'@)
        $fixture = @{ Reads = 0; Answer = ''; Retries = [Collections.Generic.List[bool]]::new() }
        function Get-UpdaterRoot { $isolated }
        function Get-UpdaterSlot { @{ Directory = $isolated } }
        function Read-Host {
            $lock = Enter-UpdateLock $isolated
            if (!$lock) { throw 'The retry choice should run outside the updater lock.' }
            $lock.Dispose()
            $fixture.Reads++
            $fixture.Answer
        }
        $Interactive = $true
        Assert-Equal (Invoke-Launcher) 0
        Assert-Equal $fixture.Reads 0
        $ExtensionActions = $true
        Assert-Equal (Invoke-Launcher) 0
        $fixture.Answer = 'R'
        Assert-Equal (Invoke-Launcher) 0
        Assert-Equal $fixture.Reads 2
        Assert-Equal ($fixture.Retries -join ',') 'False,False,True'
        $RetryExtensionUpdates = $true
        Assert-Equal (Invoke-Launcher) 0
        Assert-Equal $fixture.Reads 2
        Assert-Equal $fixture.Retries[3] $true
    }

    Test-Case 'normal browser invocation keeps its arguments and precedes extension handoff' {
        $isolated = Join-Path $root 'launch-handoff'
        [void][IO.Directory]::CreateDirectory($isolated)
        $fixtureConfig = @{ browserArgs = @('--new-window'); selfUpdateEnabled = $false }
        $events = [Collections.Generic.List[string]]::new()
        function Read-Config { $fixtureConfig }
        function Set-UpdaterShortcut { }
        function Invoke-Workflow {
            @{ Status = 'Action'; Inventory = @{}; Candidates = @(@{ Path = 'verified.crx' }); NativeActionOnly = $true }
        }
        function Start-Chromium($Config, $Arguments) {
            Assert-Equal $Config.browserArgs[0] '--new-window'
            Assert-Equal $Arguments.Count 2
            Assert-Equal $Arguments[0] 'relative path.html'
            Assert-Equal $Arguments[1] 'https://example.test/?a=1&b=2'
            $events.Add('browser')
        }
        function Invoke-ExtensionHandoffs { $events.Add('extensions'); $true }
        $Force = $true
        $Interactive = $true
        $BrowserArguments = @('relative path.html','https://example.test/?a=1&b=2')
        Assert-Equal (Invoke-UpdateSession $isolated) 21
        Assert-Equal ($events -join ',') 'browser,extensions'
        $events.Clear()
        $NoLaunch = $true
        Assert-Equal (Invoke-UpdateSession $isolated) 2
        $NoLaunch = $false
        $CheckOnly = $true
        Assert-Equal (Invoke-UpdateSession $isolated) 2
        $CheckOnly = $false
        $Stage = $true
        Assert-Equal (Invoke-UpdateSession $isolated) 2
        Assert-Equal $events.Count 0
    }

    Test-Case 'browser installation refreshes inventory and next standard handoff reconciles startup changes' {
        $isolated = Join-Path $root 'reconcile'
        [void](New-PrivateRoot $isolated)
        $profileRoot = Join-Path $isolated 'profiles'
        $firstProfile = Join-Path $profileRoot 'Default'
        $startupProfile = Join-Path $profileRoot 'Profile 1'
        [void][IO.Directory]::CreateDirectory($firstProfile)
        $initial = 'a' * 32
        $afterInstall = 'b' * 32
        $afterLaunch = 'c' * 32
        function Write-ComponentRegistration([string]$ProfilePath, [string]$Id) {
            Write-Json (Join-Path $ProfilePath 'Preferences') @{ extensions = @{ settings = @{
                $Id = @{ location = 5; manifest = @{ version = '1.0'; manifest_version = 3 } }
            } } }
        }
        Write-ComponentRegistration $firstProfile $initial
        $fixture = @{ Checks = 0; Launches = 0; StoreIds = 0; Messages = [Collections.Generic.List[string]]::new()
            Logs = [Collections.Generic.List[string]]::new() }
        $fixtureConfig = @{ browserPath = 'fixture'; userData = $profileRoot; architecture = 'x64'; browserArgs = @(); extensions = @{} }
        $version = [version]'158.0.8127.36'
        function Read-Config { $fixtureConfig }
        function Get-BrowserVersion { $version }
        function Get-WindowsCandidate { @{ Tag = "$version-1"; Version = $version } }
        function Get-UpstreamStable { $version }
        function Get-StoreUpdates($Ids) { $fixture.StoreIds += @($Ids).Count; @{} }
        function Write-Status($Level, $Message, $LogMessage = $Message) {
            $fixture.Messages.Add("$Level $Message")
            $fixture.Logs.Add($LogMessage)
        }
        function Invoke-BrowserUpdate {
            $fixture.Checks++
            if ($fixture.Checks -eq 1) {
                Write-ComponentRegistration $firstProfile $afterInstall
                return @{ Status = 'Complete'; Version = $version; Applied = $true }
            }
            @{ Status = 'Complete'; Version = $version }
        }
        function Start-Chromium {
            $fixture.Launches++
            if ($fixture.Launches -eq 1) {
                [void][IO.Directory]::CreateDirectory($startupProfile)
                Write-ComponentRegistration $startupProfile $afterLaunch
            }
        }
        $stateFile = Join-Path $isolated 'state.json'
        $NoLaunch = $true
        Assert-Equal (Invoke-UpdateSession $isolated) 0
        $state = Read-DailyState $stateFile
        Assert-Equal $state.InventoryRefresh 'AwaitingLaunch'
        Assert-Equal $state.Inventory.Contains("Default/$initial") $false
        Assert-Equal $state.Inventory.Contains("Default/$afterInstall") $true
        $NoLaunch = $false
        Assert-Equal (Invoke-UpdateSession $isolated) 0
        Assert-Equal (Read-DailyState $stateFile).InventoryRefresh 'Pending'
        Assert-Equal $fixture.Checks 1
        Assert-Equal (Invoke-UpdateSession $isolated) 0
        $state = Read-DailyState $stateFile
        Assert-Equal $state.InventoryRefresh $null
        Assert-Equal $state.Inventory.Contains("Profile 1/$afterLaunch") $true
        Assert-Equal $fixture.Checks 2
        Assert-Equal $state.Status 'Complete'
        Assert-Equal $state.Inventory["Profile 1/$afterLaunch"].Update 'Component'
        Assert-Equal @($fixture.Messages -like 'INFO *browser-managed component added to inventory').Count 2
        Assert-Equal @($fixture.Logs -like "Component $afterLaunch *added to inventory").Count 1
        Assert-Equal @($fixture.Logs -like '*Profile 1*').Count 0
        Assert-Equal $fixture.StoreIds 0
        $fixture.Messages.Clear()
        [IO.File]::Delete((Join-Path $startupProfile 'Preferences'))
        $Force = $true
        Assert-Equal (Invoke-UpdateSession $isolated) 0
        Assert-Equal @($fixture.Messages -like "INFO *browser-managed component $afterLaunch is no longer registered*").Count 1
        Assert-Equal @($fixture.Messages -like "INFO *$afterInstall*added to inventory").Count 0
    }

    Test-Case 'CRX3 cryptography rejects a modified package, unpinned ID and absent Store proof' {
        Initialize-CrxVerifier
        $rsa = [Security.Cryptography.RSA]::Create(2048)
        function Add-ProtobufField([IO.MemoryStream]$Stream, [int]$Field, [byte[]]$Data) {
            foreach ($value in @(($Field * 8 + 2),$Data.Length)) {
                $remaining = $value
                while ($remaining -ge 128) { $Stream.WriteByte(($remaining -band 127) -bor 128); $remaining = $remaining -shr 7 }
                $Stream.WriteByte($remaining)
            }
            $Stream.Write($Data)
        }
        try {
            $key = $rsa.ExportSubjectPublicKeyInfo()
            $id = [Crx3]::ExtensionId($key)
            $signed = [IO.MemoryStream]::new()
            Add-ProtobufField $signed 1 ([Security.Cryptography.SHA256]::HashData($key)[0..15])
            $archive = [IO.MemoryStream]::new()
            $zip = [IO.Compression.ZipArchive]::new($archive, 'Create', $true)
            $manifest = $zip.CreateEntry('manifest.json').Open()
            $manifest.Write([Text.Encoding]::UTF8.GetBytes('{"version":"1.1","manifest_version":3}'))
            $manifest.Dispose()
            $zip.Dispose()
            [byte[]]$data = [Text.Encoding]::ASCII.GetBytes("CRX3 SignedData$([char]0)") +
                [BitConverter]::GetBytes([int]$signed.Length) + $signed.ToArray() + $archive.ToArray()
            $proof = [IO.MemoryStream]::new()
            Add-ProtobufField $proof 1 $key
            Add-ProtobufField $proof 2 ($rsa.SignData($data, [Security.Cryptography.HashAlgorithmName]::SHA256,
                    [Security.Cryptography.RSASignaturePadding]::Pkcs1))
            $header = [IO.MemoryStream]::new()
            Add-ProtobufField $header 2 $proof.ToArray()
            Add-ProtobufField $header 10000 $signed.ToArray()
            [byte[]]$crx = [Text.Encoding]::ASCII.GetBytes('Cr24') + [BitConverter]::GetBytes(3) +
                [BitConverter]::GetBytes([int]$header.Length) + $header.ToArray() + $archive.ToArray()
            Assert-Equal (([Crx3]::Verify($crx,$id,$false).Manifest | ConvertFrom-Json).version) '1.1'
            Assert-Fails { [Crx3]::Verify($crx,('a' * 32),$false) } 'Unexpected signed extension ID'
            Assert-Fails { [Crx3]::Verify($crx,$id,$true) } 'publisher proof is missing'
            $crx[-1] = $crx[-1] -bxor 1
            Assert-Fails { [Crx3]::Verify($crx,$id,$false) } 'Invalid CRX3 signature'
        } finally { $rsa.Dispose() }
    }

    Test-Case 'closed snapshot copies both trees and SHA-256 verifies the documented recovery scope' {
        $isolated = Join-Path $root 'backup-scope'
        $config = New-BackupFixture $isolated
        $version = [version]'158.0.8127.36'
        function Test-BrowserBusy { $false }
        $parent = Join-Path $isolated 'backups'
        $legacy = '20261127T110000Z-' + ('a' * 32)
        $abandoned = '20261127T120000Z-' + ('b' * 32)
        foreach ($dir in $legacy,$abandoned,'incomplete','operator-copy') {
            [void][IO.Directory]::CreateDirectory((Join-Path $parent $dir))
        }
        Write-Json (Join-Path $parent "$legacy\complete.json") @{ Version = $version.ToString(); Created = '2026-11-27T11:00:00Z' }
        $name = New-BrowserBackup $isolated $config $version
        Assert-Equal ([IO.Directory]::Exists((Join-Path $parent 'incomplete'))) $false
        Assert-Equal ([IO.Directory]::Exists((Join-Path $parent $abandoned))) $false
        Assert-Equal ([IO.Directory]::Exists((Join-Path $parent 'operator-copy'))) $true
        Assert-Equal (Confirm-BrowserBackup $isolated $legacy) 'Legacy'
        Assert-Equal (Confirm-BrowserBackup $isolated $name) 'Verified'
        $backup = Join-Path $parent $name
        $record = Read-Json (Join-Path $backup 'complete.json')
        Assert-Equal $record.HashScope 'sha256-v1'
        Assert-Equal $record.Hashes.Count 7
        $cache = Join-Path $backup 'User Data\Default\Cache\cache-entry'
        Assert-Equal ([IO.File]::ReadAllText($cache)) 'good'
        [IO.File]::WriteAllText($cache, 'evil')
        Assert-Equal (Confirm-BrowserBackup $isolated $name) 'Verified'
        foreach ($relative in 'Application\158.0.8127.36\chrome.dll','User Data\Profile 1\Secure Preferences',
            'User Data\Default\Network\Cookies-wal','User Data\Profile 1\Local Extension Settings\fixture\000001.log') {
            $file = Join-Path $backup $relative
            $time = [IO.File]::GetLastWriteTimeUtc($file)
            [IO.File]::WriteAllText($file, 'evil')
            [IO.File]::SetLastWriteTimeUtc($file, $time)
            Assert-Fails { Confirm-BrowserBackup $isolated $name } 'SHA-256 verification found missing or changed files'
            [IO.File]::WriteAllText($file, 'good')
            [IO.File]::SetLastWriteTimeUtc($file, $time)
        }
        [IO.File]::Delete((Join-Path $backup 'User Data\Local State'))
        Assert-Fails { Confirm-BrowserBackup $isolated $name } 'SHA-256 verification found missing or changed files'
        Assert-Fails { Confirm-BrowserBackup $isolated '..\operator-copy' } 'completed backup by its folder name'
    }

    Test-Case 'backup verification errors block installation and preserve both completed snapshots' {
        $isolated = Join-Path $root 'failed-backup'
        $config = New-BackupFixture $isolated
        $version = [version]'158.0.8127.36'
        $candidate = @{ Version = [version]'158.0.8127.88'; Tag = '158.0.8127.88-1.1'; Digest = 'a' * 64 }
        $artifact = @{ Path = (Join-Path $isolated 'unused-installer.exe'); Signer = $null }
        $fixture = @{ Corrupt = 'Copy'; AfterBackup = 0 }
        function Test-BrowserBusy { $false }
        function Assert-RegisteredInstall { }
        function Get-BrowserVersion { $version }
        function Test-ArtifactFile { $fixture.AfterBackup++; $true }
        $known = @(New-BrowserBackup $isolated $config $version; New-BrowserBackup $isolated $config $version)
        $parent = Join-Path $isolated 'backups'
        $verifiedCopy = (Get-Command Copy-BrowserTree).ScriptBlock
        function Copy-BrowserTree($Source, $Destination) {
            & $verifiedCopy $Source $Destination
            if ([IO.Path]::GetFileName($Destination) -ceq 'User Data') {
                $tree = if ($fixture.Corrupt -ceq 'Copy') { $Destination } else { $Source }
                $prefs = Join-Path $tree 'Default\Preferences'
                $modified = [IO.File]::GetLastWriteTimeUtc($prefs)
                [IO.File]::WriteAllText($prefs, 'evil')
                [IO.File]::SetLastWriteTimeUtc($prefs, $modified)
                & (Join-Path ([Environment]::SystemDirectory) 'robocopy.exe') $Source $Destination /L /E /COPY:DAT /DCOPY:DAT /XJ /R:0 /W:0 /NFL /NDL /NJH /NJS /NP *> $null
                Assert-Equal $LASTEXITCODE 0
            }
        }
        foreach ($corrupt in 'Copy','Source') {
            $fixture.Corrupt = $corrupt
            Assert-Fails { Install-BrowserCandidate $isolated $config $version $candidate $artifact } 'SHA-256 verification found missing or changed files'
            Assert-Equal @(Get-ChildItem -LiteralPath $parent -Directory | Where-Object { $_.Name -cnotin $known }).Count 0
            Assert-Equal @(Get-ChildItem -LiteralPath $parent -Directory).Count 2
        }
        $file = Join-Path $config.userData 'Local State'
        $lock = [IO.File]::Open($file, 'Open', 'ReadWrite', 'None')
        try {
            Assert-Fails { Install-BrowserCandidate $isolated $config $version $candidate $artifact } 'could not be read for SHA-256'
        } finally { $lock.Dispose() }
        Assert-Equal $fixture.AfterBackup 0
        Assert-Equal ([IO.File]::Exists((Join-Path $isolated 'installation.json'))) $false
        Assert-Equal ([IO.File]::Exists((Join-Path $isolated 'installer-preferences.json'))) $false
        foreach ($name in $known) { Assert-Equal (Confirm-BrowserBackup $isolated $name) 'Verified' }
        Assert-Equal ([IO.Directory]::Exists((Join-Path $parent 'incomplete'))) $false
    }

    Test-Case 'backup retention rotates completed copies and refuses unsafe incomplete cleanup' {
        $isolated = Join-Path $root 'backup-retention'
        $config = New-BackupFixture $isolated
        $version = [version]'158.0.8127.36'
        function Test-BrowserBusy { $false }
        $parent = Join-Path $isolated 'backups'
        $older = '20261127T110000Z-' + ('a' * 32)
        $previous = '20261127T120000Z-' + ('b' * 32)
        foreach ($old in $older,$previous) {
            $path = Join-Path $parent $old
            [void][IO.Directory]::CreateDirectory($path)
            Write-Json (Join-Path $path 'complete.json') @{ Version = $version.ToString(); Created = '2026-11-27T12:00:00Z' }
        }
        $name = New-BrowserBackup $isolated $config $version
        Assert-Equal ([IO.Directory]::Exists((Join-Path $parent $older))) $false
        Assert-Equal ([IO.Directory]::Exists((Join-Path $parent $previous))) $true
        Assert-Equal (Confirm-BrowserBackup $isolated $name) 'Verified'
        $outside = Join-Path $isolated 'unmanaged'
        [void][IO.Directory]::CreateDirectory($outside)
        $witness = Join-Path $outside 'keep.txt'
        [IO.File]::WriteAllText($witness, 'keep')
        $link = Join-Path $parent 'incomplete'
        New-Item -ItemType Junction -Path $link -Target $outside | Out-Null
        try {
            Assert-Fails { New-BrowserBackup $isolated $config $version } 'Backup cleanup failed'
            Assert-Equal ([IO.File]::ReadAllText($witness)) 'keep'
            Assert-Equal (Confirm-BrowserBackup $isolated $name) 'Verified'
            Assert-Equal ([IO.Directory]::Exists((Join-Path $parent $previous))) $true
        } finally { [IO.Directory]::Delete($link) }
    }

    Test-Case 'running browser defers installation and pending marker blocks retry' {
        $candidate = @{ Version = [version]'158.0.8127.36' }
        $config = @{ browserTrust = @{ allowUnsigned = $true } }
        $artifact = @{ Signer = $null }
        function Test-BrowserBusy($Config) { $true }
        $installed = [version]'150.0.7871.186'
        Assert-Equal (Install-BrowserCandidate $root $config $installed $candidate $artifact) 'Deferred'
        function Test-BrowserBusy($Config) { $false }
        function Assert-RegisteredInstall($Config, $Version) { }
        $pending = Join-Path $root 'installation.json'
        Write-Json $pending @{ Previous = '150.0.7871.186'; Candidate = '158.0.8127.36'; Backup = 'fixture' }
        Assert-Fails { Install-BrowserCandidate $root $config $installed $candidate $artifact } 'interrupted installation'
        [IO.File]::Delete($pending)
    }

    Test-Case 'interrupted installer leaves a recovery marker and never launches a browser' {
        $isolated = Join-Path $root 'backup-recovery'
        [void](New-PrivateRoot $isolated)
        $candidate = @{ Version = [version]'158.0.8127.36'; Tag = '158.0.8127.36-1.1'; Digest = 'a' * 64 }
        $config = New-BackupFixture $isolated
        $artifact = @{ Signer = $null; Path = (Join-Path $root 'absent-installer.exe') }
        function Test-BrowserBusy($Config) { $false }
        function Assert-RegisteredInstall($Config, $Version) { }
        function Get-BrowserVersion { [version]'150.0.7871.186' }
        function Test-ArtifactFile($Path, $Artifact) { $true }
        try { Install-BrowserCandidate $isolated $config ([version]'150.0.7871.186') $candidate $artifact | Out-Null }
        catch [Management.Automation.MethodInvocationException] { }
        $marker = Join-Path $isolated 'installation.json'
        $recovery = Read-Json $marker
        Assert-Equal (Confirm-BrowserBackup $isolated $recovery.Backup) 'Verified'
        Assert-Fails { Remove-ExpiredBackups $isolated } 'interrupted installation requires recovery'
        $VerifyBackup = $recovery.Backup
        $workerFixture = Join-Path $PSScriptRoot '../src'
        function Get-UpdaterRoot { $isolated }
        function Get-UpdaterSlot { @{ Directory = $workerFixture } }
        Assert-Equal (Invoke-Launcher) 0
        [IO.File]::WriteAllText((Join-Path $isolated "backups\$VerifyBackup\User Data\Local State"), 'evil')
        Assert-Equal (Invoke-Launcher) 1
        Assert-Equal (Read-Json $marker).Backup $VerifyBackup
    }

    Test-Case 'same-version install records a verified revision or blocks launch after a payload mismatch' {
        $version = [version]'158.0.8127.36'
        $candidate = @{ Version = $version; Tag = "$version-1.2"; Architecture = 'x64'; Revision = [version]'1.2'; Digest = 'b' * 64 }
        $app = Join-Path $root 'fixture-app'
        [void][IO.Directory]::CreateDirectory((Join-Path $app $version.ToString()))
        $exe = Join-Path $app 'chrome.exe'
        $dll = Join-Path $app "$version\chrome.dll"
        [IO.File]::WriteAllText($exe, 'browser')
        [IO.File]::WriteAllText((Join-Path $app 'chrome_proxy.exe'), 'proxy')
        [IO.File]::WriteAllText($dll, 'before')
        $config = @{ browserTrust = @{ allowUnsigned = $true }; browserPath = $exe; architecture = 'x64' }
        $stateFile = Join-Path $root 'browser-release.json'
        $previousRelease = @{ Tag = "$version-1.1"; Digest = 'a' * 64; Architecture = 'x64'
            Identity = Get-InstalledBrowserIdentity $config $version }
        Write-Json $stateFile $previousRelease
        $compiled = Join-Path $root 'fixture-installer.exe'
        $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
        $source = Join-Path $root 'InstallerFixture.cs'
        [IO.File]::WriteAllText($source, @'
using System.IO;
public static class InstallerFixture {
    public static void Main(string[] args) {
        string root = Path.GetDirectoryName(args[1].Substring("--installerdata=".Length));
        if (!File.Exists(Path.Combine(root, "installation.json"))) throw new IOException("Missing marker");
        File.WriteAllText(Path.Combine(root, "fixture-app", "158.0.8127.36", "chrome.dll"), "after");
    }
}
'@)
        & $compiler /nologo /target:winexe "/out:$compiled" $source
        if ($LASTEXITCODE -ne 0) { throw 'Cannot compile installer fixture.' }
        $artifact = @{ Signer = $null; Path = $compiled }
        function Get-BrowserVersion { [version]'158.0.8127.36' }
        $busy = @{ Checks = 0; At = 3 }
        function Test-BrowserBusy { $busy.Checks++; $busy.Checks -eq $busy.At }
        function Assert-RegisteredInstall { }
        function New-BrowserBackup { 'fixture-backup' }
        function Test-ArtifactFile { $true }
        $files = @{ "$version\chrome.dll" = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('after'))) }
        $pending = Join-Path $root 'installation.json'
        Assert-Equal (Install-BrowserCandidate $root $config $version $candidate $artifact $files) 'Deferred'
        Assert-Equal ([IO.File]::ReadAllText($dll)) 'before'
        Assert-Equal ([IO.File]::Exists($pending)) $false
        $busy.At = 0
        $compatibility = @{ UboVersion = '1.77.4'; UboDigest = 'a' * 64 }
        Assert-Equal (Install-BrowserCandidate $root $config $version $candidate $artifact $files $compatibility) 'Installed'
        Assert-Equal ([IO.File]::Exists($pending)) $false
        Assert-Equal (Read-Json $stateFile).Tag $candidate.Tag
        Assert-Equal (Get-BrowserReleaseStatus $root $config $version $candidate) 'Current'
        Assert-Equal (Get-InstalledMv2Evidence $root $config $version).UboDigest $compatibility.UboDigest

        [IO.File]::WriteAllText($dll, 'before')
        Assert-Equal (Get-InstalledMv2Evidence $root $config $version) $null
        Write-Json $stateFile $previousRelease
        $config.userData = $root
        $config.browserArgs = @()
        $config.browserUpdateMode = 'Automatic'
        $fixtureConfig = $config
        $fixtureCandidate = $candidate
        $fixtureArtifact = $artifact
        $fixtureFiles = @{ "$version\chrome.dll" = '0' * 64 }
        $calls = @{ Launch = 0; PayloadMismatch = $false }
        $Force = $true
        function Read-Config { $fixtureConfig }
        function Get-WindowsCandidate { $fixtureCandidate }
        function Get-UpstreamStable { $fixtureCandidate.Version }
        function Get-ExtensionInventory { }
        function Get-StoreUpdates { @{} }
        function Get-BrowserArtifact { $fixtureArtifact }
        function Get-BrowserCompatibility { @{ Status = 'Pass'; Detail = 'fixture'; Files = $fixtureFiles } }
        function Write-Status($Level, $Message) {
            if ($Message -like '*installed browser files do not match the verified installer payload*') { $calls.PayloadMismatch = $true }
        }
        function Start-Chromium { $calls.Launch++ }
        Assert-Equal (Invoke-UpdateSession $root) 1
        Assert-Equal ([IO.File]::ReadAllText($dll)) 'after'
        Assert-Equal $calls.PayloadMismatch $true
        Assert-Equal (Read-Json $pending).Tag $candidate.Tag
        Assert-Equal (Read-Json $stateFile).Tag $previousRelease.Tag
        Assert-Equal (Read-Json $stateFile).Digest $previousRelease.Digest
        Assert-Equal (Read-Json $stateFile).Identity $previousRelease.Identity
        Assert-Equal (Invoke-UpdateSession $root) 1
        Assert-Equal $calls.Launch 0
        [IO.File]::Delete($pending)
        [IO.File]::Delete($stateFile)
    }

    Test-Case 'launch preserves the working directory, URLs, quotes, empty arguments and Unicode' {
        $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        if (!(Test-Path -LiteralPath $compiler)) {
            $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
        }
        $source = Join-Path $root 'Recorder.cs'
        [IO.File]::WriteAllText($source, @'
using System;
using System.IO;
using System.Text;
internal static class Recorder {
    private static void Main(string[] args) {
        using (var writer = new StreamWriter(args[0], false, new UTF8Encoding(false))) {
            for (int i = 1; i < args.Length; ++i) writer.WriteLine(Convert.ToBase64String(Encoding.UTF8.GetBytes(args[i])));
        }
        File.WriteAllText(args[0] + ".done", Directory.GetCurrentDirectory());
    }
}
'@)
        $recorder = Join-Path $root 'Recorder.exe'
        & $compiler /nologo /target:winexe "/out:$recorder" $source
        if ($LASTEXITCODE -ne 0) { throw 'Cannot compile argv fixture.' }
        $output = Join-Path $root 'args.txt'
        $argsToCheck = @('--single-argument','https://example.test/?a=1&b=2','quote"inside','dir with space\','', "utf-$([char]0x00e9)")
        $originalDirectory = [Environment]::CurrentDirectory
        try {
            [Environment]::CurrentDirectory = $root
            Start-Chromium @{ browserPath = $recorder; browserArgs = @($output) } $argsToCheck
        } finally { [Environment]::CurrentDirectory = $originalDirectory }
        for ($i = 0; $i -lt 30 -and !(Test-Path -LiteralPath "$output.done"); $i++) { Start-Sleep -Milliseconds 100 }
        Assert-Equal ([IO.File]::ReadAllText("$output.done")) $root
        $recorded = [IO.File]::ReadAllLines($output)
        Assert-Equal $recorded.Count $argsToCheck.Count
        for ($i = 0; $i -lt $recorded.Count; $i++) {
            Assert-Equal ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($recorded[$i]))) $argsToCheck[$i]
        }

        $launcher = Join-Path $root 'ChromiumUpdater.exe'
        & $compiler /nologo /target:winexe /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll "/out:$launcher" (Join-Path $PSScriptRoot '../src/Launcher.cs')
        if ($LASTEXITCODE -ne 0) { throw 'Cannot compile launcher fixture.' }
        [IO.File]::WriteAllText((Join-Path $root 'pwsh.path'), [Environment]::ProcessPath)
        [IO.File]::WriteAllText((Join-Path $root 'Update.ps1'), @'
param([switch]$Dispatch, [string]$Payload)
if (!$Dispatch) { exit 1 }
[IO.File]::WriteAllBytes((Join-Path $PSScriptRoot 'dispatch.json'), [Convert]::FromBase64String($Payload))
exit 0
'@)
        $builder = [Diagnostics.ProcessStartInfo]::new($launcher)
        $builder.UseShellExecute = $false
        foreach ($argument in $argsToCheck) { [void]$builder.ArgumentList.Add($argument) }
        $frontend = [Diagnostics.Process]::Start($builder)
        try {
            if (!$frontend.WaitForExit(10000) -or $frontend.ExitCode -ne 0) { throw 'Quiet launcher dispatch did not finish.' }
        } finally { $frontend.Dispose() }
        $dispatched = Read-Json (Join-Path $root 'dispatch.json')
        Assert-Equal $dispatched.Count $argsToCheck.Count
        for ($i = 0; $i -lt $dispatched.Count; $i++) { Assert-Equal $dispatched[$i] $argsToCheck[$i] }
    }

    Write-Output "$script:passed automated cases passed."
} finally {
    Assert-OrdinaryTree $root
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($root)) -ine [IO.Path]::GetFullPath($env:TEMP) -or
        [IO.Path]::GetFileName($root) -cnotmatch '^uc-updater-tests-[a-f0-9]{32}$') { throw 'Unexpected test directory.' }
    Remove-Item -LiteralPath $root -Recurse -Force
}
