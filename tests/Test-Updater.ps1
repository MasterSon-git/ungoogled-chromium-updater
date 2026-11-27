#Requires -Version 7.5
. (Join-Path $PSScriptRoot '../src/Common.ps1')
. (Join-Path $PSScriptRoot '../src/Extensions.ps1')
. (Join-Path $PSScriptRoot '../src/Browser.ps1')

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
$root = Join-Path (New-PrivateRoot) ('tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)

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

    Test-Case 'MV2 compatibility, artifact hash and stable gap gate' {
        $candidate = @{ Tag = '158.0.8127.36-1.1'; Digest = 'b' * 64; Version = [version]'158.0.8127.36' }
        $stable = [version]'158.0.8127.89'
        $approval = @{ tag = $candidate.Tag; sha256 = $candidate.Digest; allowUnsigned = $true }
        Assert-Equal (Test-BrowserApproval $approval $candidate $stable $true) $false
        $approval.mv2RuntimeVerified = $true
        Assert-Equal (Test-BrowserApproval $approval $candidate $stable $true) $false
        $approval.acceptedStableVersion = $stable.ToString()
        Assert-Equal (Test-BrowserApproval $approval $candidate $stable $true) $true
        Assert-Equal (Test-BrowserApproval $approval $candidate ([version]'159.0.8154.33') $true) $false
        $approval.sha256 = 'c' * 64
        Assert-Equal (Test-BrowserApproval $approval $candidate $stable $true) $false
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
        $config = @{ browserApproval = @{ allowUnsigned = $true } }
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
        $candidate = @{ Version = [version]'158.0.8127.36'; Tag = '158.0.8127.36-1.1' }
        $config = @{ browserApproval = @{ allowUnsigned = $true } }
        $artifact = @{ Signer = $null; Path = (Join-Path $root 'absent-installer.exe') }
        function Test-BrowserBusy($Config) { $false }
        function Assert-RegisteredInstall($Config, $Version) { }
        function New-BrowserBackup($Root, $Config, $Version) { 'fixture-backup' }
        function Test-ArtifactFile($Path, $Artifact) { $true }
        try { Install-BrowserCandidate $root $config ([version]'150.0.7871.186') $candidate $artifact | Out-Null }
        catch [Management.Automation.MethodInvocationException] { }
        $marker = Join-Path $root 'installation.json'
        Assert-Equal (Read-Json $marker).Backup 'fixture-backup'
        [IO.File]::Delete($marker)
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
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($root)) -ne (Get-UpdaterRoot)) { throw 'Unexpected test directory.' }
    Remove-Item -LiteralPath $root -Recurse -Force
}
