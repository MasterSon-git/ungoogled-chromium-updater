function Expand-RuntimeZip([IO.Stream]$Stream, [string]$Destination, [long]$Limit) {
    $archive = [IO.Compression.ZipArchive]::new($Stream, 'Read', $true)
    try {
        $total = 0L
        if ($archive.Entries.Count -gt 5000) { throw 'Runtime ZIP has too many entries.' }
        foreach ($entry in $archive.Entries) {
            $total += $entry.Length
            if ($total -gt $Limit -or $entry.FullName -match '(^[/\\]|(^|[/\\])\.\.?([/\\]|$)|:)' -or
                (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000 -or
                ($entry.ExternalAttributes -band [int][IO.FileAttributes]::ReparsePoint)) {
                throw 'Unsafe or oversized runtime ZIP entry.'
            }
            $path = [IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName))
            if (!$path.StartsWith("$Destination\", [StringComparison]::OrdinalIgnoreCase)) { throw 'Archive path escapes test directory.' }
        }
        [IO.Compression.ZipFileExtensions]::ExtractToDirectory($archive, $Destination)
    } finally { $archive.Dispose() }
}

function Send-RuntimeCdp($Connection, [string]$Method, $Parameters = @{}, [string]$Session) {
    $id = ++$Connection.Id
    $request = @{ id = $id; method = $Method; params = $Parameters }
    if ($Session) { $request.sessionId = $Session }
    $data = [Text.Encoding]::UTF8.GetBytes(($request | ConvertTo-Json -Depth 9 -Compress))
    $socket = $Connection.Socket
    $token = $Connection.Deadline.Token
    [void]$socket.SendAsync([ArraySegment[byte]]::new($data), 'Text', $true, $token).GetAwaiter().GetResult()
    $buffer = [byte[]]::new(16384)
    do {
        $body = [IO.MemoryStream]::new()
        try {
            do {
                $part = $socket.ReceiveAsync([ArraySegment[byte]]::new($buffer), $token).GetAwaiter().GetResult()
                if ($part.MessageType -eq 'Close' -or $body.Length + $part.Count -gt 1MB) { throw 'Invalid runtime debugging response.' }
                $body.Write($buffer, 0, $part.Count)
            } until ($part.EndOfMessage)
            $reply = [Text.Encoding]::UTF8.GetString($body.ToArray()) | ConvertFrom-Json -AsHashtable
        } finally { $body.Dispose() }
    } until ($reply.Contains('id') -and $reply.id -eq $id)
    if ($reply.Contains('error')) { throw "CDP command failed: $Method." }
    $reply.result
}

function Invoke-RuntimeExpression($Connection, [string]$Session, [string]$Expression) {
    $result = Send-RuntimeCdp $Connection 'Runtime.evaluate' @{ expression = $Expression; awaitPromise = $true; returnByValue = $true } $Session
    if ($result.Contains('exceptionDetails')) {
        $error = [InvalidOperationException]::new('The runtime fixture expression failed.')
        $error.Data['RuntimeException'] = $result.exceptionDetails['exception']
        throw $error
    }
    if ($result.result.Contains('value')) { $result.result.value }
}

function Connect-RuntimeCdp($Connection, [string]$PortFile) {
    $endpoint = @(Get-Content -LiteralPath $PortFile -TotalCount 2)
    if ($endpoint.Count -ne 2 -or $endpoint[0] -cnotmatch '^[1-9]\d{0,4}$' -or [int]$endpoint[0] -gt 65535 -or
        $endpoint[1] -cnotmatch '^/devtools/browser/[a-f0-9-]{36}$') {
        throw 'Unexpected isolated debugging endpoint.'
    }
    [void]$Connection.Socket.ConnectAsync([uri]"ws://127.0.0.1:$($endpoint[0])$($endpoint[1])",
        $Connection.Deadline.Token).GetAwaiter().GetResult()
}

function Invoke-Mv2Fixture([string]$Lab, [string]$Exe, $Ubo, $Run) {
    $extension = Join-Path $Lab 'ubo'
    $profile = Join-Path $Lab 'profile'
    $manifest = $Ubo.Manifest
    $bytes = $Ubo.Bytes
    $verified = $Ubo.Proof
    $stream = [IO.MemoryStream]::new($bytes, $verified.ZipOffset, $bytes.Length - $verified.ZipOffset, $false)
    try { Expand-RuntimeZip $stream $extension 64MB } finally { $stream.Dispose() }
    # Give the disposable unpacked fixture the identity derived from the signed developer key.
    $manifest['key'] = $verified.PublicKey
    Write-Json (Join-Path $extension 'manifest.json') $manifest

    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $hits = [Collections.Concurrent.ConcurrentQueue[string]]::new()
    $connection = @{ Socket = [Net.WebSockets.ClientWebSocket]::new(); Id = 0
        Deadline = [Threading.CancellationTokenSource]::new(60000) }
    $connection.Socket.Options.Proxy = $null
    $process = $null
    $server = $null
    $portFile = Join-Path $profile 'DevToolsActivePort'
    try {
        $listener.Start()
        $httpPort = $listener.LocalEndpoint.Port
        $fixtureUrl = "http://uc-updater.test:$httpPort/"
        $server = Start-ThreadJob -ArgumentList $listener,$hits -ScriptBlock {
            param($Http, $Requests)
            while ($true) {
                try { $client = $Http.AcceptTcpClient() } catch { break }
                try {
                    $client.ReceiveTimeout = 1000
                    $client.SendTimeout = 1000
                    $stream = $client.GetStream()
                    $reader = [IO.StreamReader]::new($stream)
                    if ($reader.ReadLine() -cmatch '^GET (/(?:blocked-check|allowed-check)?) HTTP/1\.[01]$') {
                        $Requests.Enqueue($Matches[1])
                        $response = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: text/plain`r`nCache-Control: no-store`r`nContent-Length: 2`r`nConnection: close`r`n`r`nOK")
                        $stream.Write($response)
                    }
                } catch [IO.IOException] { } finally { $client.Dispose() }
            }
        }
        $start = [Diagnostics.ProcessStartInfo]::new($Exe)
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardError = $true
        $start.WorkingDirectory = [IO.Path]::GetDirectoryName($Exe)
        # Chromium defines --mute-audio for automated tests in media/base/media_switches.cc.
        foreach ($arg in '--headless=new','--mute-audio','--disable-background-networking','--disable-quic',
            '--host-resolver-rules=MAP uc-updater.test 127.0.0.1, MAP * ~NOTFOUND',
            "--proxy-server=http://127.0.0.1:$httpPort",'--proxy-bypass-list=<-loopback>;uc-updater.test',
            '--disk-cache-size=1048576','--no-first-run','--no-default-browser-check','--remote-debugging-port=0',
            "--user-data-dir=$profile","--load-extension=$extension",'about:blank') {
            [void]$start.ArgumentList.Add($arg)
        }
        if (!$start.ArgumentList.Contains('--mute-audio')) { throw 'The isolated browser launch must be muted.' }
        $Run.BrowserActive = $true
        $process = [Diagnostics.Process]::Start($start)
        [void]$process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
        for ($i = 0; $i -lt 100 -and ![IO.File]::Exists($portFile) -and !$process.HasExited; $i++) {
            Start-Sleep -Milliseconds 200
        }
        if (![IO.File]::Exists($portFile)) { throw [TimeoutException]::new('The isolated browser did not open its debugging port.') }
        Connect-RuntimeCdp $connection $portFile
        $version = (Send-RuntimeCdp $connection 'Browser.getVersion').product
        $extSession = $null
        $ready = $false
        for ($i = 0; $i -lt 80 -and !$ready; $i++) {
            if (!$extSession) {
                $background = (Send-RuntimeCdp $connection 'Target.getTargets').targetInfos |
                    Where-Object { $_.type -eq 'background_page' -and $_.url.StartsWith("chrome-extension://$script:UboId/") } |
                    Select-Object -First 1
                if ($background) {
                    $extSession = (Send-RuntimeCdp $connection 'Target.attachToTarget' @{ targetId = $background.targetId; flatten = $true }).sessionId
                }
            }
            if ($extSession -and (Invoke-RuntimeExpression $connection $extSession "document.readyState === 'complete' && Boolean(globalThis.vAPI?.defer)")) {
                $ready = Invoke-RuntimeExpression $connection $extSession "import('/js/background.js').then(({default:m}) => Boolean(m.readyToFilter && m.availableFilterLists[m.userFiltersPath] && chrome.webRequest.onBeforeRequest.hasListeners()))"
            }
            if (!$ready) { Start-Sleep -Milliseconds 250 }
        }
        if (!$ready) { return @{ Status = 'Incompatible'; Detail = 'The full uBlock Origin MV2 background page or request listener did not initialize.' } }
        $actual = Invoke-RuntimeExpression $connection $extSession 'chrome.runtime.getManifest()'
        if ($actual.manifest_version -ne 2 -or $actual.version -ne $manifest.version) {
            return @{ Status = 'Inconclusive'; Detail = 'The runtime extension manifest differed from the signed fixture.' }
        }
        $target = (Send-RuntimeCdp $connection 'Target.createTarget' @{ url = $fixtureUrl }).targetId
        $page = (Send-RuntimeCdp $connection 'Target.attachToTarget' @{ targetId = $target; flatten = $true }).sessionId
        for ($i = 0; $i -lt 50; $i++) {
            if ((Invoke-RuntimeExpression $connection $page 'document.readyState') -eq 'complete' -and '/' -in $hits.ToArray()) { break }
            Start-Sleep -Milliseconds 200
        }
        $fetch = "async path => fetch(path).then(r => r.ok, () => false)"
        if (!(Invoke-RuntimeExpression $connection $page "($fetch)('/blocked-check')") -or '/blocked-check' -notin $hits.ToArray()) {
            throw 'The baseline request did not reach the loopback fixture.'
        }
        Invoke-RuntimeExpression $connection $extSession "import('/js/background.js').then(async m => { await m.default.appendUserFilters('|$($fixtureUrl)blocked-check|'); return true; })" | Out-Null
        $before = @($hits | Where-Object { $_ -eq '/blocked-check' }).Count
        $blocked = !(Invoke-RuntimeExpression $connection $page "($fetch)('/blocked-check')")
        $control = Invoke-RuntimeExpression $connection $page "($fetch)('/allowed-check')"
        if (!$control -or '/allowed-check' -notin $hits.ToArray()) {
            return @{ Status = 'Inconclusive'; Detail = 'The allowed loopback control failed, so request blocking could not be attributed to uBlock Origin.' }
        }
        if (!$blocked -or @($hits | Where-Object { $_ -eq '/blocked-check' }).Count -ne $before) {
            return @{ Status = 'Incompatible'; Detail = 'The filtered request reached the loopback fixture or succeeded.' }
        }
        @{ Status = 'Pass'; Detail = "$version, full uBlock Origin $($actual.version) MV2. Filtering and the allowed control passed." }
    } finally {
        $connection.Socket.Dispose()
        $connection.Deadline.Dispose()
        if ($process) {
            if (!$process.HasExited -and [IO.File]::Exists($portFile)) {
                $shutdown = @{ Socket = [Net.WebSockets.ClientWebSocket]::new(); Id = 0
                    Deadline = [Threading.CancellationTokenSource]::new(5000) }
                $shutdown.Socket.Options.Proxy = $null
                try {
                    Connect-RuntimeCdp $shutdown $portFile
                    Send-RuntimeCdp $shutdown 'Browser.close' | Out-Null
                } catch { } finally { $shutdown.Socket.Dispose(); $shutdown.Deadline.Dispose() }
            }
            $Run.BrowserActive = !$process.WaitForExit(10000)
            $process.Dispose()
        } else { $Run.BrowserActive = $false }
        $listener.Stop()
        if ($server) {
            Wait-Job $server -Timeout 3 | Out-Null
            Remove-Job $server -Force
        }
    }
}

function Get-BrowserCompatibility([string]$Root, $Candidate, $Artifact, [bool]$NeedsMv2) {
    $lab = Join-Path $Root 'mv2-work'
    $cachePath = Join-Path $Root 'mv2-pass.json'
    $run = @{ BrowserActive = $false }
    $created = $false
    $result = $null
    try {
        Assert-LocalPath $lab
        Assert-LocalPath $cachePath
        if ([IO.Directory]::Exists($lab)) {
            return @{ Status = 'OperationalFailure'; Detail = 'A prior test workspace needs cleanup. See browser maintenance.' }
        }
        $uboAsset = if ($NeedsMv2) { Get-ExtensionRelease 'Ubo' }
        if ($NeedsMv2) {
            # Bump the test version for changes affecting fixture behavior or payload verification.
            $key = "1/$($Candidate.Architecture)/$($Candidate.Tag)/$($Candidate.Digest)/$($Candidate.Size)/$($Artifact.Signer)" +
                "/$script:UboId/$($uboAsset.Version)/$($uboAsset.Digest)/$($uboAsset.Size)"
            if ([IO.File]::Exists($cachePath)) {
                try { $cache = Read-Json $cachePath } catch { $cache = @{} }
                if ($cache -is [Collections.IDictionary] -and $cache['Key'] -ceq $key -and
                    $cache['Files'] -is [Collections.IDictionary] -and $cache['Files']['chrome.exe'] -and
                    $cache['Files']["$($Candidate.Version)\chrome.dll"]) {
                    if (!(Test-ArtifactFile $Artifact.Path $Candidate)) { throw 'The staged installer no longer matches the cached test.' }
                    return @{ Status = 'Pass'; Detail = 'Exact artifact identities match a prior successful MV2 test.'
                        Files = $cache.Files; UboVersion = $uboAsset.Version; UboDigest = $uboAsset.Digest; UboAsset = $uboAsset }
                }
            }
        }
        [void][IO.Directory]::CreateDirectory($lab)
        $created = $true
        $payload = Expand-BrowserPayload $lab $Candidate $Artifact
        if ($NeedsMv2) {
            $ubo = Get-VerifiedExtensionPackage $uboAsset $script:UboId $false
            if (!(Test-FullUboManifest $ubo.Manifest)) { throw 'The verified uBlock Origin manifest changed its source or Manifest version.' }
            $result = Invoke-Mv2Fixture $lab $payload.Exe $ubo $run
            $result.UboVersion = $uboAsset.Version
            $result.UboDigest = $uboAsset.Digest
            $result.UboAsset = $uboAsset
        } else { $result = @{ Status = 'Pass'; Detail = 'Verified the exact same-version installer payload.' } }
    } catch [NotSupportedException] {
        $result = @{ Status = 'Inconclusive'; Detail = $_.Exception.Message }
    } catch {
        $detail = 'Payload verification, signed fixture verification or test operation failed.'
        if ($_.Exception -is [TimeoutException] -or $_.Exception -is [OperationCanceledException] -or
            $_.Exception.InnerException -is [OperationCanceledException]) {
            $detail = 'The compatibility test or archive operation timed out.'
        } elseif ($_.Exception.Message -ceq 'The runtime fixture expression failed.') {
            $result = @{ Status = 'Inconclusive'; Detail = 'The signed uBlock Origin fixture no longer exposes the expected test interface.' }
        } elseif ($_.Exception.Message -cin @(
            'The compatibility test needs 2 GiB of free space on the updater drive.',
            'The staged installer changed before payload verification.',
            'The staged installer no longer matches the cached test.',
            'Extension package size or SHA-256 mismatch.',
            'The verified uBlock Origin manifest changed its source or Manifest version.')) {
            $detail = $_.Exception.Message
        }
        if (!$result) { $result = @{ Status = 'OperationalFailure'; Detail = $detail } }
    }
    if ($run.BrowserActive) {
        return @{ Status = 'OperationalFailure'; Detail = 'The isolated Chromium instance did not exit. Close it manually and see browser maintenance.' }
    }
    if ($created) {
        try { Remove-Mv2Lab $Root $lab }
        catch { return @{ Status = 'OperationalFailure'; Detail = 'The isolated test workspace could not be removed. See browser maintenance.' } }
    }
    if ($result.Status -eq 'Pass') {
        $result.Files = $payload.Files
        if ($NeedsMv2) {
            try { Write-Json $cachePath @{ Key = $key; Files = $payload.Files } }
            catch { Write-Status WARN 'The compatibility test passed. Its result could not be cached for later checks.' }
        }
    }
    $result
}
