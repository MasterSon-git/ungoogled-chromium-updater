function Invoke-BrowserArchive([string[]]$Arguments) {
    $tool = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) '7-Zip\7z.exe'
    Assert-LocalPath $tool
    if (![IO.File]::Exists($tool)) {
        throw [NotSupportedException]::new('Install current official 7-Zip in Program Files to inspect the browser payload.')
    }
    $start = [Diagnostics.ProcessStartInfo]::new($tool)
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

function Get-BrowserArchiveEntries([string]$Archive, [string]$Type) {
    $listing = Invoke-BrowserArchive @('l', "-t$Type", '-slt', '-ba', '--', $Archive)
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

function Expand-BrowserPayload([string]$Lab, $Candidate, $Artifact) {
    if (!(Test-ArtifactFile $Artifact.Path $Candidate)) { throw 'The staged installer changed before payload verification.' }
    if ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($Lab)).AvailableFreeSpace -lt 2GB) {
        throw 'The compatibility test needs 2 GiB of free space on the updater drive.'
    }
    $packedName = 'CHROME.PACKED.7Z'
    $resource = ".rsrc\B7\$packedName"
    $embedded = @(Get-BrowserArchiveEntries $Artifact.Path PE | Where-Object { $_.Path -match '^\.rsrc\\(?:B7|BN|BL)\\' })
    $entry = @($embedded | Where-Object { $_.Path -ceq $resource })
    if ($embedded.Count -ne 2 -or @($embedded | Where-Object { $_.Path -ceq '.rsrc\BL\SETUP.EX_' }).Count -ne 1 -or
        $entry.Count -ne 1 -or [long]$entry[0].Size -le 0 -or [long]$entry[0].Size -gt $Candidate.Size) {
        throw [NotSupportedException]::new('The verified installer lacks a supported full Chromium payload.')
    }
    [void](Invoke-BrowserArchive @('e','-tPE','-bso0','-y','-spd',"-o$Lab",'--',$Artifact.Path,$resource))
    $packed = Join-Path $Lab $packedName
    Assert-LocalPath $packed
    if ((Get-Item -LiteralPath $packed).Length -ne [long]$entry[0].Size) { throw 'Unexpected embedded archive size.' }
    $inner = @(Get-BrowserArchiveEntries $packed 7z)
    if ($inner.Count -ne 1 -or $inner[0].Path -cne 'chrome.7z' -or $inner[0]['Attributes'] -cne 'A' -or
        $inner[0]['Encrypted'] -cne '-' -or [long]$inner[0].Size -le 0 -or [long]$inner[0].Size -gt 700MB) {
        throw [NotSupportedException]::new('The embedded browser archive uses an unsupported layout.')
    }
    [void](Invoke-BrowserArchive @('e','-t7z','-bso0','-y','-spd',"-o$Lab",'--',$packed,'chrome.7z'))
    $archive = Join-Path $Lab 'chrome.7z'
    Assert-LocalPath $archive
    if ((Get-Item -LiteralPath $archive).Length -ne [long]$inner[0].Size) { throw 'Unexpected browser archive size.' }
    [IO.File]::Delete($packed)

    $entries = @(Get-BrowserArchiveEntries $archive 7z)
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
    [void](Invoke-BrowserArchive @('x','-t7z','-bso0','-y',"-o$Lab",'--',$archive))
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
    @{ Exe = $exe; Files = $files }
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
