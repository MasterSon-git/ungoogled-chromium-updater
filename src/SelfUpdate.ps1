. (Join-Path $PSScriptRoot 'ReleaseTrust.ps1')

$script:UpdaterRepository = 'MasterSon-git/ungoogled-chromium-updater'
$script:UpdaterPackageName = 'ungoogled-chromium-updater-v1.zip'
$script:UpdaterPackageLimit = 512KB

function Get-UpdaterCoreFiles {
    [ordered]@{
        'Browser.ps1' = 'src/Browser.ps1'
        'BrowserPayload.ps1' = 'src/BrowserPayload.ps1'
        'Common.ps1' = 'src/Common.ps1'
        'config.example.json' = 'config.example.json'
        'Crx3.cs' = 'src/Crx3.cs'
        'Extensions.ps1' = 'src/Extensions.ps1'
        'Handoff.ps1' = 'src/Handoff.ps1'
        'Launcher.cs' = 'src/Launcher.cs'
        'LICENSE' = 'LICENSE'
        'Mv2.ps1' = 'src/Mv2.ps1'
        'ReleaseTrust.ps1' = 'src/ReleaseTrust.ps1'
        'SelfUpdate.ps1' = 'src/SelfUpdate.ps1'
        'Setup.ps1' = 'src/Setup.ps1'
        'THIRD_PARTY_NOTICES.md' = 'THIRD_PARTY_NOTICES.md'
        'Update.ps1' = 'src/Update.ps1'
        'Updater.version' = 'src/Updater.version'
        'Worker.ps1' = 'src/Worker.ps1'
    }
}

function Get-UpdaterPackageFiles { Get-UpdaterCoreFiles }

function Test-UpdaterPayloadName([string]$Name) {
    $Name -cmatch '\A[A-Za-z][A-Za-z0-9._-]{0,63}\z' -and
        $Name -notmatch '\A(?:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|\z)' -and
        $Name -notin 'updater-slot.json','config.json' -and
        ($Name -cin (Get-UpdaterCoreFiles).Keys -or $Name -cmatch '\.(?:ps1|cs|json|md|txt)\z')
}

function Convert-UpdaterVersion([string]$Text) {
    if ($Text.Length -gt 128 -or $Text -cnotmatch '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?\z') {
        throw 'Invalid updater SemVer.'
    }
    $core = @($Matches[1], $Matches[2], $Matches[3])
    $build = $Matches.ContainsKey(5)
    $pre = @(if ($Matches.ContainsKey(4)) { $Matches[4].Split('.') })
    if ($pre -cmatch '\A0[0-9]+\z') { throw 'Invalid updater SemVer.' }
    @{ Text = $Text; Core = $core; Pre = $pre; HasBuild = $build }
}

function Get-UpdaterVersion([string]$Path) {
    Assert-LocalPath $Path
    if ((Get-Item -LiteralPath $Path).Length -gt 130) { throw 'Invalid updater version file.' }
    $version = Convert-UpdaterVersion ([IO.File]::ReadAllText($Path).TrimEnd("`r", "`n"))
    if ($version.HasBuild) { throw 'Build metadata is reserved in updater release tags.' }
    $version
}

function Compare-UpdaterIdentifier([string]$Left, [string]$Right) {
    $a = $Left -cmatch '\A[0-9]+\z'
    $b = $Right -cmatch '\A[0-9]+\z'
    if ($a -and !$b) { return -1 }
    if ($b -and !$a) { return 1 }
    if ($a -and $Left.Length -ne $Right.Length) { return $Left.Length.CompareTo($Right.Length) }
    [string]::CompareOrdinal($Left, $Right)
}

function Compare-UpdaterVersion($Left, $Right) {
    for ($i = 0; $i -lt 3; $i++) {
        $order = Compare-UpdaterIdentifier $Left.Core[$i] $Right.Core[$i]
        if ($order) { return $order }
    }
    if (!$Left.Pre.Count -or !$Right.Pre.Count) { return $Right.Pre.Count.CompareTo(0) - $Left.Pre.Count.CompareTo(0) }
    for ($i = 0; $i -lt [Math]::Min($Left.Pre.Count, $Right.Pre.Count); $i++) {
        $order = Compare-UpdaterIdentifier $Left.Pre[$i] $Right.Pre[$i]
        if ($order) { return $order }
    }
    $Left.Pre.Count.CompareTo($Right.Pre.Count)
}

function Select-UpdaterRelease($Releases, $Installed, [string]$Channel) {
    $best = $null
    $version = $Installed
    foreach ($release in $Releases) {
        if ($release['draft'] -ne $false -or $release['tag_name'] -isnot [string] -or
            !$release['tag_name'].StartsWith('v', [StringComparison]::Ordinal)) { continue }
        $tag = $release['tag_name']
        $candidate = try { Convert-UpdaterVersion $tag.Substring(1) } catch { continue }
        if ($candidate.HasBuild -or
            ($Channel -ceq 'Stable' -and ($candidate.Pre.Count -or $release['prerelease'] -eq $true)) -or
            (Compare-UpdaterVersion $candidate $version) -le 0) { continue }
        if ($release['draft'] -isnot [bool] -or $release['prerelease'] -isnot [bool] -or
            $release['prerelease'] -ne ($candidate.Pre.Count -gt 0) -or
            ($release['id'] -isnot [long] -and $release['id'] -isnot [int]) -or $release['id'] -le 0 -or
            $release['url'] -cne "https://api.github.com/repos/$script:UpdaterRepository/releases/$($release['id'])" -or
            $release['html_url'] -cne "https://github.com/$script:UpdaterRepository/releases/tag/$tag") {
            throw 'Unexpected updater release identity.'
        }
        $version = $candidate
        $best = $release
    }
    if (!$best) { return }
    $package = Get-ReleaseAsset $best $script:UpdaterRepository $script:UpdaterPackageName
    $signature = Get-ReleaseAsset $best $script:UpdaterRepository ($script:UpdaterPackageName + '.sig')
    if ($package.Size -gt $script:UpdaterPackageLimit -or $signature.Size -notin 384,512) {
        throw 'Unexpected updater release asset size.'
    }
    @{ Version = $version.Text; Tag = $best['tag_name']; Package = $package; Signature = $signature }
}

function Get-UpdaterSignatureInput([string]$Tag, [long]$Size, [string]$Digest) {
    $length = $Size.ToString([Globalization.CultureInfo]::InvariantCulture)
    ,([Text.Encoding]::ASCII.GetBytes("Ungoogled Chromium Updater package v1`n$script:UpdaterRepository`n$Tag`n$length`n$($Digest.ToLowerInvariant())`n"))
}

function New-UpdaterVerificationKey([string]$PublicKey = $script:UpdaterReleasePublicKey) {
    $rsa = [Security.Cryptography.RSA]::Create()
    try {
        if ($PublicKey.Trim() -cnotmatch '\A-----BEGIN PUBLIC KEY-----\r?\n[A-Za-z0-9+/=\r\n]+\n-----END PUBLIC KEY-----\z') {
            throw 'Invalid updater release public key pin.'
        }
        $rsa.ImportFromPem($PublicKey)
        if ($rsa.KeySize -notin 3072,4096) { throw 'Unsupported updater release key size.' }
        $rsa
    } catch {
        $rsa.Dispose()
        throw
    }
}

function Assert-UpdaterSignature([string]$Tag, [long]$Size, [string]$Digest, [byte[]]$Signature, [string]$PublicKey = $script:UpdaterReleasePublicKey) {
    $rsa = New-UpdaterVerificationKey $PublicKey
    try {
        if ($Signature.Length -ne $rsa.KeySize / 8 -or
            !$rsa.VerifyData((Get-UpdaterSignatureInput $Tag $Size $Digest), $Signature,
                [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)) {
            throw 'Invalid updater release signature.'
        }
    } finally { $rsa.Dispose() }
}

function Expand-UpdaterPackage([string]$Path, [string]$Destination, [string]$Version) {
    $manifestName = 'updater-files.json'
    Assert-LocalPath $Path
    Assert-LocalPath $Destination
    if ((Get-Item -LiteralPath $Path).Length -gt $script:UpdaterPackageLimit -or
        (Test-Path -LiteralPath $Destination)) {
        throw 'Unexpected updater package size or staging directory.'
    }
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    $deadline = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(10))
    try {
        if ($archive.Entries.Count -gt 48) { throw 'Unexpected updater package file count.' }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $total = 0L
        foreach ($entry in $archive.Entries) {
            $deadline.Token.ThrowIfCancellationRequested()
            $type = ($entry.ExternalAttributes -shr 16) -band 0xF000
            if (!(Test-UpdaterPayloadName $entry.FullName) -or !$seen.Add($entry.FullName) -or
                $type -notin 0,0x8000 -or ($entry.ExternalAttributes -band 0x410) -or
                $entry.Length -le 0 -or $entry.Length -gt 256KB) {
                throw 'Unsafe or unexpected updater package entry.'
            }
            [void]$names.Add($entry.FullName)
            $total += $entry.Length
            if ($total -gt 1MB) { throw 'Updater package exceeds the extraction size limit.' }
        }
        if (!$names.Contains($manifestName) -or $archive.GetEntry($manifestName).Length -gt 8KB) {
            throw 'Missing or oversized updater package manifest.'
        }
        foreach ($required in (Get-UpdaterCoreFiles).Keys) {
            if (!$names.Contains($required)) { throw 'Missing required updater package file.' }
        }
        [void][IO.Directory]::CreateDirectory($Destination)
        $buffer = [byte[]]::new(16384)
        foreach ($entry in $archive.Entries) {
            $deadline.Token.ThrowIfCancellationRequested()
            $inputStream = $entry.Open()
            try {
                $output = [IO.File]::Open((Join-Path $Destination $entry.FullName), 'CreateNew', 'Write', 'None')
                try {
                    $total = 0L
                    while (($count = $inputStream.ReadAsync($buffer, 0, $buffer.Length, $deadline.Token).GetAwaiter().GetResult()) -gt 0) {
                        $total += $count
                        if ($total -gt $entry.Length) { throw 'Updater archive entry exceeds its declared length.' }
                        $output.Write($buffer, 0, $count)
                    }
                    if ($total -ne $entry.Length) { throw 'Updater archive entry length mismatch.' }
                    $output.Flush($true)
                } finally { $output.Dispose() }
            } finally { $inputStream.Dispose() }
        }
        $deadline.Token.ThrowIfCancellationRequested()
        [void]$names.Remove($manifestName)
        $manifest = Read-Json (Join-Path $Destination $manifestName)
        if ($manifest -isnot [Collections.IDictionary] -or $manifest.Count -ne 2 -or $manifest['Schema'] -ne 1 -or
            $manifest['Files'] -isnot [array] -or $manifest['Files'].Count -ne $names.Count) {
            throw 'Invalid updater package manifest.'
        }
        foreach ($name in $manifest['Files']) {
            if ($name -isnot [string] -or !$names.Remove($name)) { throw 'Unexpected updater package manifest file.' }
        }
        if ((Get-UpdaterVersion (Join-Path $Destination 'Updater.version')).Text -cne $Version) {
            throw 'Updater package version does not match its release tag.'
        }
    } finally {
        $archive.Dispose()
        $deadline.Dispose()
    }
}

function Assert-UpdaterWorker([string]$Directory, [string]$Shell = [Environment]::ProcessPath) {
    foreach ($file in Get-ChildItem -LiteralPath $Directory -Filter '*.ps1' -File) {
        $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
        if ($errors.Count) { throw 'Updater package contains an invalid PowerShell script.' }
    }
    $start = [Diagnostics.ProcessStartInfo]::new($Shell)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = $Directory
    foreach ($argument in '-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $Directory 'Update.ps1'),'-Probe') {
        [void]$start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($start)
    try {
        if (!$process.WaitForExit(20000)) {
            $process.Kill()
            throw 'Updater worker validation timed out.'
        }
        if ($process.ExitCode -ne 42) { throw 'Updater worker validation failed.' }
    } finally { $process.Dispose() }
}

function Build-UpdaterLauncher([string]$Directory, [string]$Shell) {
    $compiler = Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (![IO.File]::Exists($compiler)) {
        $compiler = Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
    }
    $launcher = Join-Path $Directory 'ChromiumUpdater.exe'
    & $compiler '/nologo' '/target:winexe' '/reference:System.Windows.Forms.dll' '/reference:System.Web.Extensions.dll' "/out:$launcher" (Join-Path $Directory 'Launcher.cs') | Out-Null
    if ($LASTEXITCODE -ne 0 -or ![IO.File]::Exists($launcher)) { throw 'Windows launcher compilation failed.' }
    [IO.File]::WriteAllText((Join-Path $Directory 'pwsh.path'), $Shell)
}

function Remove-UpdaterDirectory([string]$Root, [ValidateSet('updater-work','updater-a','updater-b','updater-previous-app')][string]$Name) {
    $path = Join-Path $Root $Name
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($path)) -ine [IO.Path]::GetFullPath($Root)) {
        throw 'Unexpected updater directory.'
    }
    Assert-LocalPath $path
    if (!(Test-Path -LiteralPath $path)) { return }
    Assert-OrdinaryTree $path
    Remove-Item -LiteralPath $path -Recurse -Force
}

function Get-UpdaterProcess([int]$ProcessId, [long]$StartTicks) {
    $process = $null
    try {
        $process = [Diagnostics.Process]::GetProcessById($ProcessId)
        if (!$process.HasExited -and $process.StartTime.ToUniversalTime().Ticks -eq $StartTicks) { return $process }
    } catch [ArgumentException], [InvalidOperationException], [ComponentModel.Win32Exception] { }
    if ($process) { $process.Dispose() }
}

function Test-PendingUpdaterHandoff([string]$Root) {
    $path = Join-Path $Root 'updater-work/handoff.json'
    Assert-LocalPath $path
    if (![IO.File]::Exists($path) -or (Get-Item -LiteralPath $path).Length -gt 4096) { return $false }
    $helper = try {
        $pending = Read-Json $path
        Get-UpdaterProcess $pending.ProcessId $pending.StartTicks
    } catch { $null }
    if (!$helper) { return $false }
    $helper.Dispose()
    $true
}

function Install-UpdaterCandidate([string]$Root, [string]$Directory, [string]$Channel, $Resume) {
    if (!$script:UpdaterReleasePublicKey) { return 'Unavailable' }
    $active = Get-UpdaterSlot $Root
    if ($active.Directory -ine $Directory) { throw 'Updater activation changed unexpectedly.' }
    $installed = Get-UpdaterVersion (Join-Path $Directory 'Updater.version')
    $work = Join-Path $Root 'updater-work'
    $planPath = Join-Path $work 'handoff.json'
    if (Test-PendingUpdaterHandoff $Root) { return 'Deferred' }
    $releases = Get-RemoteJson "https://api.github.com/repos/$script:UpdaterRepository/releases?per_page=100" 'api.github.com'
    $candidate = Select-UpdaterRelease $releases $installed $Channel
    if (!$candidate) { return 'Current' }

    Remove-UpdaterDirectory $Root 'updater-work'
    [void][IO.Directory]::CreateDirectory($work)
    $started = $false
    try {
        $package = Join-Path $work $script:UpdaterPackageName
        $signature = "$package.sig"
        Invoke-TrustedGet $candidate.Package.Uri $script:GitHubAssetHosts $candidate.Package.Size 15 $package
        Invoke-TrustedGet $candidate.Signature.Uri $script:GitHubAssetHosts $candidate.Signature.Size 15 $signature
        if (!(Test-ArtifactFile $package $candidate.Package) -or !(Test-ArtifactFile $signature $candidate.Signature)) {
            throw 'Updater asset SHA-256 or byte count mismatch.'
        }
        Assert-UpdaterSignature $candidate.Tag $candidate.Package.Size $candidate.Package.Digest ([IO.File]::ReadAllBytes($signature))
        $staged = Join-Path $work 'payload'
        Expand-UpdaterPackage $package $staged $candidate.Version
        Assert-UpdaterWorker $staged

        $slot = if ($active.Slot -ceq 'updater-a') { 'updater-b' } else { 'updater-a' }
        $nextApp = Join-Path $work 'next-app'
        Copy-Item -LiteralPath $staged -Destination $nextApp -Recurse
        $shell = [Environment]::ProcessPath
        Build-UpdaterLauncher $nextApp $shell
        Write-Json (Join-Path $nextApp 'updater-slot.json') @{ Schema = 1; Slot = $slot; Version = $candidate.Version }

        $start = [Diagnostics.ProcessStartInfo]::new($shell)
        $start.UseShellExecute = $false
        $start.WorkingDirectory = $Root
        $continuation = ConvertTo-Json -Compress -Depth 5 @{ Options = $Resume; Directory = [Environment]::CurrentDirectory }
        $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($continuation))
        $parent = [Diagnostics.Process]::GetCurrentProcess()
        try { $parentTicks = $parent.StartTime.ToUniversalTime().Ticks }
        finally { $parent.Dispose() }
        foreach ($arg in '-NoLogo','-NoProfile','-File',(Join-Path $staged 'Handoff.ps1'),
            '-Root',$Root,'-ParentId',"$PID",'-ParentTicks',"$parentTicks",'-ResumePayload',$payload) {
            [void]$start.ArgumentList.Add($arg)
        }
        $helper = [Diagnostics.Process]::Start($start)
        try {
            Write-Json $planPath @{
                ProcessId = $helper.Id; StartTicks = $helper.StartTime.ToUniversalTime().Ticks
                From = $installed.Text; FromSlot = $active.Slot; To = $candidate.Version; ToSlot = $slot
            }
            $started = $true
        } finally { $helper.Dispose() }
        'Handoff'
    } finally {
        if (!$started) {
            try { Remove-UpdaterDirectory $Root 'updater-work' }
            catch { Write-Status WARN 'Updater staging cleanup needs manual attention.' }
        }
    }
}
