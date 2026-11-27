function Get-BrowserArchiveTool {
    $tool = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) '7-Zip\7z.exe'
    Assert-LocalPath $tool
    if (![IO.File]::Exists($tool)) {
        throw [NotSupportedException]::new('Install current official 7-Zip in Program Files to inspect the browser payload.')
    }
    $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($tool).ProductVersion
    if ($version -cnotmatch '^\d+(?:\.\d+){1,3}$') { $version = 'version unavailable' }
    Write-Status INFO "Using 7-Zip ($version) for browser payload extraction."
    $tool
}

function Invoke-BrowserArchive([string]$Tool, [string[]]$Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new($Tool)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    [void]$start.ArgumentList.Add($Arguments[0])
    foreach ($arg in @('-sccUTF-8','-bse0','-bsp0') + $Arguments[1..($Arguments.Count - 1)]) {
        [void]$start.ArgumentList.Add($arg)
    }
    $deadline = [Threading.CancellationTokenSource]::new(90000)
    $output = [IO.MemoryStream]::new()
    $process = $null
    try {
        $process = [Diagnostics.Process]::Start($start)
        $buffer = [byte[]]::new(8192)
        $stream = $process.StandardOutput.BaseStream
        while (($read = $stream.ReadAsync($buffer, 0, $buffer.Length).WaitAsync($deadline.Token).GetAwaiter().GetResult()) -gt 0) {
            if ($output.Length + $read -gt 1MB) { throw 'Browser archive listing exceeds its output limit.' }
            $output.Write($buffer, 0, $read)
        }
        [void]$process.WaitForExitAsync($deadline.Token).GetAwaiter().GetResult()
        if ($process.ExitCode) { throw [NotSupportedException]::new('7-Zip could not read the expected browser archive format.') }
        [Text.Encoding]::UTF8.GetString($output.ToArray())
    } finally {
        $deadline.Dispose()
        $output.Dispose()
        if ($process) {
            try {
                if (!$process.HasExited) { $process.Kill(); [void]$process.WaitForExit(5000) }
            } finally { $process.Dispose() }
        }
    }
}

function Get-BrowserArchiveEntries([string]$Tool, [string]$Archive, [string]$Type) {
    $listing = Invoke-BrowserArchive $Tool @('l', "-t$Type", '-slt', '-ba', '--', $Archive)
    foreach ($block in $listing.Trim("`r`n") -split '\r?\n(?:\r?\n)+') {
        $item = @{}
        foreach ($line in $block -split '\r?\n') {
            if ($line -cnotmatch '^([A-Za-z ]+) = (.*)$' -or $item.ContainsKey($Matches[1])) {
                throw [NotSupportedException]::new('Unexpected browser archive listing.')
            }
            $item[$Matches[1]] = $Matches[2]
        }
        if (!$item['Path'] -or $item['Size'] -cnotmatch '^\d{1,10}$') {
            throw [NotSupportedException]::new('Browser archive paths or sizes are unavailable.')
        }
        $item
    }
}

function Expand-BrowserPayload([string]$Lab, $Candidate, $Artifact, [switch]$IncludeSetup) {
    if (!(Test-ArtifactFile $Artifact.Path $Candidate)) { throw 'The staged installer changed before payload verification.' }
    if ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($Lab)).AvailableFreeSpace -lt 2GB) {
        throw 'The compatibility test needs 2 GiB of free space on the updater drive.'
    }
    $tool = Get-BrowserArchiveTool
    $packedName = 'CHROME.PACKED.7Z'
    $resource = ".rsrc\B7\$packedName"
    $setupResource = '.rsrc\BL\SETUP.EX_'
    $embedded = @(Get-BrowserArchiveEntries $tool $Artifact.Path PE | Where-Object { $_.Path -match '^\.rsrc\\(?:B7|BN|BL)\\' })
    $entry = @($embedded | Where-Object { $_.Path -ceq $resource })
    $setupEntry = @($embedded | Where-Object { $_.Path -ceq $setupResource })
    if ($embedded.Count -ne 2 -or $setupEntry.Count -ne 1 -or
        $entry.Count -ne 1 -or [long]$entry[0].Size -le 0 -or [long]$entry[0].Size -gt $Candidate.Size) {
        throw [NotSupportedException]::new('The verified installer lacks a supported full Chromium payload.')
    }
    [void](Invoke-BrowserArchive $tool @('e','-tPE','-bso0','-y','-spd',"-o$Lab",'--',$Artifact.Path,$resource))
    $packed = Join-Path $Lab $packedName
    Assert-LocalPath $packed
    if ((Get-Item -LiteralPath $packed).Length -ne [long]$entry[0].Size) { throw 'Unexpected embedded archive size.' }
    $inner = @(Get-BrowserArchiveEntries $tool $packed 7z)
    if ($inner.Count -ne 1 -or $inner[0].Path -cne 'chrome.7z' -or $inner[0]['Attributes'] -cne 'A' -or
        $inner[0]['Encrypted'] -cne '-' -or [long]$inner[0].Size -le 0 -or [long]$inner[0].Size -gt 700MB) {
        throw [NotSupportedException]::new('The embedded browser archive uses an unsupported layout.')
    }
    [void](Invoke-BrowserArchive $tool @('e','-t7z','-bso0','-y','-spd',"-o$Lab",'--',$packed,'chrome.7z'))
    $archive = Join-Path $Lab 'chrome.7z'
    Assert-LocalPath $archive
    if ((Get-Item -LiteralPath $archive).Length -ne [long]$inner[0].Size) { throw 'Unexpected browser archive size.' }
    [IO.File]::Delete($packed)

    $entries = @(Get-BrowserArchiveEntries $tool $archive 7z)
    $expected = @{}
    $total = 0L
    $prefix = 'Chrome-bin\'
    $versionDirectory = [regex]::Escape($Candidate.Version.ToString())
    foreach ($item in $entries) {
        $path = $item.Path
        $size = [long]$item.Size
        $total += $size
        if ($entries.Count -gt 1500 -or $total -gt 800MB -or $item['Encrypted'] -cne '-' -or
            $item['Attributes'] -cnotin 'A','D' -or $path.Length -gt 160 -or $expected.ContainsKey($path) -or
            $path -cnotmatch "^Chrome-bin(?:\\(?:chrome(?:_proxy)?\.exe|$versionDirectory(?:\\[A-Za-z0-9_.-]+)*))?$" -or
            $path -match '(?:^|\\)(?:\.|\.\.|CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:[.\\]|$)|\.(?:\\|$)') {
            throw [NotSupportedException]::new('The browser payload contains unsupported paths, attributes or sizes.')
        }
        $expected[$path] = $item
    }
    $app = Join-Path $Lab 'Chrome-bin'
    $exe = Join-Path $app 'chrome.exe'
    if (!$expected.ContainsKey('Chrome-bin\chrome.exe') -or
        !$expected.ContainsKey("Chrome-bin\$($Candidate.Version)\chrome.dll")) {
        throw [NotSupportedException]::new('The embedded payload does not contain the expected browser binaries.')
    }
    [void](Invoke-BrowserArchive $tool @('x','-t7z','-bso0','-y',"-o$Lab",'--',$archive))
    [IO.File]::Delete($archive)
    Assert-OrdinaryTree $app
    if ((Get-BrowserVersion $exe $Candidate.Architecture) -ne $Candidate.Version) {
        throw [NotSupportedException]::new('The embedded browser architecture or version differs from the release.')
    }
    $files = @{}
    foreach ($file in (Get-ChildItem -LiteralPath $app -File -Recurse -Force)) {
        $relative = [IO.Path]::GetRelativePath($app, $file.FullName)
        $item = $expected[$prefix + $relative]
        if (!$item -or $item['Attributes'] -cne 'A' -or [long]$item.Size -ne $file.Length) {
            throw 'The extracted browser payload did not match its bounded archive listing.'
        }
        $files[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    if ($files.Count -ne @($entries | Where-Object { $_['Attributes'] -ceq 'A' }).Count) {
        throw 'The extracted browser payload is incomplete.'
    }
    if ($IncludeSetup) {
        if ([long]$setupEntry[0].Size -le 0 -or [long]$setupEntry[0].Size -gt 32MB) {
            throw 'The embedded setup resource exceeds its size limit.'
        }
        [void](Invoke-BrowserArchive $tool @('e','-tPE','-bso0','-y','-spd',"-o$Lab",'--',$Artifact.Path,$setupResource))
        $cab = Join-Path $Lab 'SETUP.EX_'
        Assert-LocalPath $cab
        if ((Get-Item -LiteralPath $cab).Length -ne [long]$setupEntry[0].Size) { throw 'Unexpected setup resource size.' }
        $setup = @(Get-BrowserArchiveEntries $tool $cab Cab)
        if ($setup.Count -ne 1 -or $setup[0].Path -cne 'setup.exe' -or [long]$setup[0].Size -le 0 -or [long]$setup[0].Size -gt 32MB) {
            throw 'The embedded setup archive uses an unsupported layout.'
        }
        [void](Invoke-BrowserArchive $tool @('e','-tCab','-bso0','-y','-spd',"-o$Lab",'--',$cab,'setup.exe'))
        $setupExe = Join-Path $Lab 'setup.exe'
        Assert-LocalPath $setupExe
        if ((Get-Item -LiteralPath $setupExe).Length -ne [long]$setup[0].Size) { throw 'Unexpected extracted setup size.' }
        $files["$($Candidate.Version)\Installer\setup.exe"] = (Get-FileHash -LiteralPath $setupExe -Algorithm SHA256).Hash
    }
    @{ Exe = $exe; Files = $files }
}

function Test-LegacyBrowserInstall([string]$Root, $Candidate) {
    $logs = Join-Path $Root 'logs'
    Assert-LocalPath $logs
    if (![IO.Directory]::Exists($logs)) { return $false }
    $confirmed = $false
    $files = Get-ChildItem -LiteralPath $logs -File -Force |
        Where-Object { $_.Name -cmatch '^\d{4}-\d{2}-\d{2}(?:\.1)?\.log$' } |
        Sort-Object Name | Select-Object -Last 62
    foreach ($file in $files) {
        Assert-LocalPath $file.FullName
        if ($file.Length -gt 1MB) { return $false }
        $candidateLogged = $verified = $started = $false
        foreach ($line in [IO.File]::ReadLines($file.FullName)) {
            switch -CaseSensitive -Regex ($line -creplace '^\S+ ', '') {
                '^\[CHECK\] Official stable ungoogled-chromium Windows build: ' {
                    $candidateLogged = $_ -ceq "[CHECK] Official stable ungoogled-chromium Windows build: $($Candidate.Tag)."
                    $verified = $started = $false
                }
                '^\[ OK \] Windows installer matches the published SHA-256 and byte count\.$' { $verified = $candidateLogged }
                '^\[INFO\] Running the verified per-user Chromium installer\.$' {
                    $started = $verified
                    $verified = $confirmed = $false
                }
                '^\[ OK \] Installed and verified Chromium ' {
                    $confirmed = $started -and $_ -ceq "[ OK ] Installed and verified Chromium $($Candidate.Version)."
                    $started = $false
                }
            }
        }
    }
    $confirmed
}

function Initialize-BrowserRelease([string]$Root, $Config, $LegacyApproval) {
    $record = Join-Path $Root 'browser-release.json'
    $pending = Join-Path $Root 'installation.json'
    $lab = Join-Path $Root 'mv2-work'
    foreach ($path in $record,$pending,$lab) { Assert-LocalPath $path }
    if ($LegacyApproval -isnot [Collections.IDictionary] -or
        (Test-Path -LiteralPath $record) -or (Test-Path -LiteralPath $pending) -or (Test-Path -LiteralPath $lab)) { return }
    $installed = Get-BrowserVersion $Config.browserPath $Config.architecture
    $candidate = Get-WindowsCandidate $Config.architecture
    if ($installed -ne $candidate.Version -or !(Test-BrowserApproval $LegacyApproval $candidate) -or
        !(Test-LegacyBrowserInstall $Root $candidate)) { return }
    Assert-RegisteredInstall $Config $installed
    $app = [IO.Path]::GetDirectoryName($Config.browserPath)
    $deferredExe = Join-Path $app 'new_chrome.exe'
    if (Test-Path -LiteralPath $deferredExe) { return }
    $artifact = Get-BrowserArtifact $Root $candidate
    Assert-BrowserTrust @{
        allowUnsigned = $LegacyApproval['allowUnsigned'] -is [bool] -and $LegacyApproval['allowUnsigned']
        signerSha256 = $LegacyApproval['signerSha256']
    } $artifact
    [void][IO.Directory]::CreateDirectory($lab)
    try {
        $payload = Expand-BrowserPayload $lab $candidate $artifact -IncludeSetup
        if (!$payload.Files["$installed\Installer\setup.exe"]) { return }
        $identity = Get-InstalledBrowserIdentity $Config $installed $payload.Files
    } finally { Remove-Mv2Lab $Root $lab }
    if (!$identity -or (Test-Path -LiteralPath $deferredExe) -or
        (Get-BrowserVersion $Config.browserPath $Config.architecture) -ne $installed) { return }
    Assert-RegisteredInstall $Config $installed
    Write-BrowserRelease $Root $candidate $identity
    $candidate.Tag
}

function Test-BrowserPayload([string]$Directory, $Files) {
    foreach ($file in $Files.GetEnumerator()) {
        $full = [IO.Path]::GetFullPath((Join-Path $Directory $file.Key))
        if (!$full.StartsWith("$Directory\",[StringComparison]::OrdinalIgnoreCase)) { return $false }
        Assert-LocalPath $full
        if (![IO.File]::Exists($full) -or (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash -ine $file.Value) {
            return $false
        }
    }
    $true
}
