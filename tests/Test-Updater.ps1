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

    Test-Case 'workflow installs with a patch gap or unavailable Chrome history, and requires MV2 pass' {
        $config = @{ browserPath = 'fixture'; userData = 'fixture'; architecture = 'x64'; browserArgs = @()
            browserUpdateMode = 'Automatic'; browserTrust = @{ allowUnsigned = $true; signerSha256 = $null } }
        $candidate = @{ Tag = '158.0.8127.36-1.1'; Digest = 'b' * 64; Version = [version]'158.0.8127.36' }
        $record = @{ Installs = 0; GateStatus = 'Pass'; Messages = [Collections.Generic.List[string]]::new() }
        $fixtureInventory = @(@{ Location = 1; Enabled = $false; Manifest = @{ manifest_version = 2 } })
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
        Assert-Equal (Invoke-Workflow $root $config $previous).Status 'Action'
        Assert-Equal $record.Installs 1
        Assert-Equal (@($record.Messages -like '*158.0.8127.36 trails Chrome stable 158.0.8127.89*').Count) 1
        function Get-UpstreamStable { throw 'service unavailable' }
        Assert-Equal (Invoke-Workflow $root $config $previous).Status 'Action'
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
        Assert-Equal (Get-BrowserCompatibility $root $candidate $artifact $true).Status 'Pass'
        Assert-Equal (Get-BrowserCompatibility $root $candidate $artifact $true).Status 'Pass'
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

    Test-Case 'extension update prompts and reports an unexpected permission increase' {
        function Assert-ExtensionKey($Id, $Manifest) { }
        $installed = @{ version = '1.0'; manifest_version = 3; permissions = @('storage'); update_url = $script:StoreUrl }
        $remote = @{ version = '1.1'; manifest_version = 3; permissions = @('storage'); update_url = $script:StoreUrl }
        function Get-VerifiedManifest($Asset, $Id, $Store) { $remote }
        $extension = @{ Id = 'a' * 32; Manifest = $installed }
        $asset = @{ Version = '1.1' }
        $version = [version]'158.0.8127.36'
        $update = Test-ExtensionCandidate $extension 'Store' $asset $version $false
        Assert-Equal $update.Status 'Action'
        if ($update.Text -notlike '*signature verified*') { throw 'Expected a verified update prompt.' }
        $remote.permissions += 'tabs'
        $update = Test-ExtensionCandidate $extension 'Store' $asset $version $false
        if ($update.Text -notlike '*changes requested permissions*') { throw 'Expected a permission warning.' }
        $remote.update_url = 'https://example.test/update'
        Assert-Fails { Test-ExtensionCandidate $extension 'Store' $asset $version $false } 'changed its update source'
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

    Test-Case 'consistent backup copies files and verifies contents' {
        $inputDir = Join-Path $root 'input'
        $outputDir = Join-Path $root 'output'
        [void][IO.Directory]::CreateDirectory($inputDir)
        [IO.File]::WriteAllText((Join-Path $inputDir 'profile-fixture.txt'),'fixture')
        Copy-BrowserTree $inputDir $outputDir
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $outputDir 'profile-fixture.txt'))) 'fixture'
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
        $candidate = @{ Version = [version]'158.0.8127.36'; Tag = '158.0.8127.36-1.1'; Digest = 'a' * 64 }
        $config = @{ browserTrust = @{ allowUnsigned = $true }; browserPath = 'fixture'; architecture = 'x64' }
        $artifact = @{ Signer = $null; Path = (Join-Path $root 'absent-installer.exe') }
        function Test-BrowserBusy($Config) { $false }
        function Assert-RegisteredInstall($Config, $Version) { }
        function Get-BrowserVersion { [version]'150.0.7871.186' }
        function New-BrowserBackup($Root, $Config, $Version) { 'fixture-backup' }
        function Test-ArtifactFile($Path, $Artifact) { $true }
        try { Install-BrowserCandidate $root $config ([version]'150.0.7871.186') $candidate $artifact | Out-Null }
        catch [Management.Automation.MethodInvocationException] { }
        $marker = Join-Path $root 'installation.json'
        Assert-Equal (Read-Json $marker).Backup 'fixture-backup'
        [IO.File]::Delete($marker)
    }

    Test-Case 'same-version installation verifies files and records its revision before clearing recovery' {
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
        Write-Json $stateFile @{ Tag = "$version-1.1"; Digest = 'a' * 64; Architecture = 'x64'
            Identity = Get-InstalledBrowserIdentity $config $version }
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
        function Remove-ExpiredBackups { }
        function Test-ArtifactFile { $true }
        $files = @{ "$version\chrome.dll" = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('after'))) }
        $pending = Join-Path $root 'installation.json'
        Assert-Equal (Install-BrowserCandidate $root $config $version $candidate $artifact $files) 'Deferred'
        Assert-Equal ([IO.File]::ReadAllText($dll)) 'before'
        Assert-Equal ([IO.File]::Exists($pending)) $false
        $busy.At = 0
        Assert-Equal (Install-BrowserCandidate $root $config $version $candidate $artifact $files) 'Installed'
        Assert-Equal ([IO.File]::Exists($pending)) $false
        Assert-Equal (Read-Json $stateFile).Tag $candidate.Tag
        Assert-Equal (Get-BrowserReleaseStatus $root $config $version $candidate) 'Current'
        [IO.File]::Delete($stateFile)
    }

    Test-Case 'launch arguments preserve URL, quotes, empty strings and Unicode' {
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
        File.WriteAllText(args[0] + ".done", "");
    }
}
'@)
        $recorder = Join-Path $root 'Recorder.exe'
        & $compiler /nologo /target:winexe "/out:$recorder" $source
        if ($LASTEXITCODE -ne 0) { throw 'Cannot compile argv fixture.' }
        $output = Join-Path $root 'args.txt'
        $argsToCheck = @('--single-argument','https://example.test/?a=1&b=2','quote"inside','dir with space\','', "utf-$([char]0x00e9)")
        Start-Chromium @{ browserPath = $recorder; browserArgs = @($output) } $argsToCheck
        for ($i = 0; $i -lt 30 -and !(Test-Path -LiteralPath "$output.done"); $i++) { Start-Sleep -Milliseconds 100 }
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
