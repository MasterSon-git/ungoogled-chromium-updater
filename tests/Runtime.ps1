param(
    [Parameter(Mandatory)][string]$BrowserZip,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$BrowserSha256,
    [Parameter(Mandatory)][string]$UboCrx,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$UboSha256
)

. (Join-Path $PSScriptRoot '../src/Common.ps1')
Add-Type -Path (Join-Path $PSScriptRoot '../src/Crx3.cs')

function Expand-TestZip([IO.Stream]$Stream, [string]$Destination) {
    $archive = [IO.Compression.ZipArchive]::new($Stream, 'Read', $true)
    try {
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName -match '(^[/\\]|(^|[/\\])\.\.([/\\]|$)|:)' -or
                (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {
                throw 'Unsafe archive entry.'
            }
            $path = [IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName))
            if (!$path.StartsWith("$Destination\", [StringComparison]::OrdinalIgnoreCase)) { throw 'Archive path escapes test directory.' }
        }
        [IO.Compression.ZipFileExtensions]::ExtractToDirectory($archive, $Destination)
    } finally { $archive.Dispose() }
}

function Send-Cdp([string]$Method, $Parameters = @{}, [string]$Session) {
    $id = ++$script:messageId
    $request = @{ id = $id; method = $Method; params = $Parameters }
    if ($Session) { $request.sessionId = $Session }
    $data = [Text.Encoding]::UTF8.GetBytes(($request | ConvertTo-Json -Depth 9 -Compress))
    $deadline = [Threading.CancellationTokenSource]::new(15000)
    try {
        [void]$socket.SendAsync([ArraySegment[byte]]::new($data), 'Text', $true, $deadline.Token).GetAwaiter().GetResult()
        $buffer = [byte[]]::new(16384)
        do {
            $body = [IO.MemoryStream]::new()
            try {
                do {
                    $part = $socket.ReceiveAsync([ArraySegment[byte]]::new($buffer), $deadline.Token).GetAwaiter().GetResult()
                    if ($part.MessageType -eq 'Close') { throw 'The test browser closed its debugging connection.' }
                    $body.Write($buffer, 0, $part.Count)
                } until ($part.EndOfMessage)
                $reply = [Text.Encoding]::UTF8.GetString($body.ToArray()) | ConvertFrom-Json -AsHashtable
            } finally { $body.Dispose() }
        } until ($reply.Contains('id') -and $reply.id -eq $id)
        if ($reply.Contains('error')) { throw "CDP command failed: $Method." }
        $reply.result
    } finally { $deadline.Dispose() }
}

function Evaluate([string]$Session, [string]$Expression) {
    $result = Send-Cdp 'Runtime.evaluate' @{ expression = $Expression; awaitPromise = $true; returnByValue = $true } $Session
    if ($result.Contains('exceptionDetails')) { throw "Runtime expression failed: $($result.exceptionDetails.exception.description)" }
    if ($result.result.Contains('value')) { $result.result.value }
}

if ((Get-FileHash -LiteralPath $BrowserZip).Hash -ine $BrowserSha256 -or
    (Get-FileHash -LiteralPath $UboCrx).Hash -ine $UboSha256) { throw 'Runtime fixture SHA-256 mismatch.' }
$runtimeRoot = New-PrivateRoot
$lab = Join-Path $runtimeRoot ('runtime-' + [guid]::NewGuid().ToString('N'))
$browser = Join-Path $lab 'browser'
$extension = Join-Path $lab 'ubo'
$profile = Join-Path $lab 'profile'
[void][IO.Directory]::CreateDirectory($lab)
$stream = [IO.File]::OpenRead($BrowserZip)
try { Expand-TestZip $stream $browser } finally { $stream.Dispose() }
$bytes = [IO.File]::ReadAllBytes($UboCrx)
$uboId = 'fkgkibajhfbepljeaefdnfnegdcjomkh'
$verified = [Crx3]::Verify($bytes, $uboId, $false)
$manifest = $verified.Manifest | ConvertFrom-Json -AsHashtable
if ($manifest.manifest_version -ne 2) { throw 'Expected a full MV2 uBlock Origin package.' }
$stream = [IO.MemoryStream]::new($bytes, $verified.ZipOffset, $bytes.Length - $verified.ZipOffset, $false)
try { Expand-TestZip $stream $extension } finally { $stream.Dispose() }
# The native CRX installer adds this verified key to the stored manifest.
# Set it in the disposable unpacked fixture so that it gets the same ID.
$manifest['key'] = $verified.PublicKey
Write-Json (Join-Path $extension 'manifest.json') $manifest
$matches = @(Get-ChildItem -LiteralPath $browser -Recurse -Filter chrome.exe)
if ($matches.Count -ne 1) { throw 'Expected exactly one browser executable.' }
$exe = $matches[0]

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start()
$httpPort = $listener.LocalEndpoint.Port
$fixtureUrl = "http://uc-updater.test:$httpPort/"
$hits = [Collections.Concurrent.ConcurrentQueue[string]]::new()
$server = Start-ThreadJob -ArgumentList $listener,$hits -ScriptBlock {
    param($Http, $Requests)
    while ($true) {
        try { $client = $Http.AcceptTcpClient() } catch { break }
        try {
            $client.ReceiveTimeout = 2000
            $stream = $client.GetStream()
            $reader = [IO.StreamReader]::new($stream)
            $line = $reader.ReadLine()
            if ($line -match '^GET (/[^ ]*) HTTP/1\.[01]$') {
                $Requests.Enqueue($Matches[1])
                while ($reader.ReadLine()) { }
                $response = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: text/plain`r`nCache-Control: no-store`r`nContent-Length: 2`r`nConnection: close`r`n`r`nOK")
                $stream.Write($response)
            }
        } catch [IO.IOException] { } finally { $client.Dispose() }
    }
}

$socket = [Net.WebSockets.ClientWebSocket]::new()
$script:messageId = 0
$process = $null
try {
    $start = [Diagnostics.ProcessStartInfo]::new($exe.FullName)
    $start.UseShellExecute = $false
    # Chromium media/base/media_switches.cc defines --mute-audio for this build.
    foreach ($arg in '--headless=new','--mute-audio','--disable-background-networking','--no-proxy-server',
        '--host-resolver-rules=MAP uc-updater.test 127.0.0.1, MAP * ~NOTFOUND',
        '--no-first-run','--no-default-browser-check','--remote-debugging-port=0',
        "--user-data-dir=$profile","--load-extension=$extension",'about:blank') {
        [void]$start.ArgumentList.Add($arg)
    }
    if (!$start.ArgumentList.Contains('--mute-audio')) { throw 'The isolated browser launch must be muted.' }
    $start.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($start)
    $portFile = Join-Path $profile 'DevToolsActivePort'
    for ($i = 0; $i -lt 100 -and !(Test-Path -LiteralPath $portFile) -and !$process.HasExited; $i++) {
        Start-Sleep -Milliseconds 200
    }
    if (!(Test-Path -LiteralPath $portFile)) { throw 'The isolated browser did not open its debugging port.' }
    $endpoint = Get-Content -LiteralPath $portFile
    [void]$socket.ConnectAsync([uri]"ws://127.0.0.1:$($endpoint[0])$($endpoint[1])", [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $version = (Send-Cdp 'Browser.getVersion').product
    $extSession = $null
    $ready = $false
    for ($i = 0; $i -lt 80 -and !$ready; $i++) {
        $background = (Send-Cdp 'Target.getTargets').targetInfos |
            Where-Object { $_.type -eq 'background_page' -and $_.url.StartsWith("chrome-extension://$uboId/") } |
            Select-Object -First 1
        if ($background) {
            try {
                $extSession = (Send-Cdp 'Target.attachToTarget' @{ targetId = $background.targetId; flatten = $true }).sessionId
                $ready = Evaluate $extSession "import('/js/background.js').then(({default:m}) => Boolean(m.readyToFilter && m.availableFilterLists[m.userFiltersPath] && chrome.webRequest.onBeforeRequest.hasListeners()))"
            } catch { $ready = $false }
        }
        if (!$ready) { Start-Sleep -Milliseconds 250 }
    }
    if (!$ready) { throw 'The MV2 background page did not finish initializing and register its request listener.' }
    $actual = Evaluate $extSession 'chrome.runtime.getManifest()'
    if ($actual.manifest_version -ne 2 -or $actual.version -ne $manifest.version) { throw 'Wrong extension manifest at runtime.' }
    $target = (Send-Cdp 'Target.createTarget' @{ url = $fixtureUrl }).targetId
    $page = (Send-Cdp 'Target.attachToTarget' @{ targetId = $target; flatten = $true }).sessionId
    for ($i = 0; $i -lt 50; $i++) {
        if ((Evaluate $page 'document.readyState') -eq 'complete' -and '/' -in $hits.ToArray()) { break }
        Start-Sleep -Milliseconds 200
    }
    $fetch = "async path => fetch(path).then(r => r.ok, () => false)"
    if (!(Evaluate $page "($fetch)('/blocked-check')") -or '/blocked-check' -notin $hits.ToArray()) {
        throw 'The request did not reach the fixture before the custom filter.'
    }
    Evaluate $extSession "import('/js/background.js').then(async m => { await m.default.appendUserFilters('|$($fixtureUrl)blocked-check|'); return true; })" | Out-Null
    $before = @($hits | Where-Object { $_ -eq '/blocked-check' }).Count
    $blockedRequest = !(Evaluate $page "($fetch)('/blocked-check')")
    $controlRequest = Evaluate $page "($fetch)('/allowed-check')"
    if (!$blockedRequest -or !$controlRequest -or
        @($hits | Where-Object { $_ -eq '/blocked-check' }).Count -ne $before -or '/allowed-check' -notin $hits.ToArray()) {
        throw "Filtering failed (selected request blocked: $blockedRequest, allowed control passed: $controlRequest)."
    }
    Write-Output "PASS: $version, full uBlock Origin $($actual.version) MV2, tested real request blocking and the allowed control."
} finally {
    if ($socket.State -eq 'Open') {
        try { Send-Cdp 'Browser.close' | Out-Null } catch { Write-Warning 'The debugging connection closed during browser shutdown.' }
    }
    $socket.Dispose()
    $listener.Stop()
    Wait-Job $server -Timeout 5 | Out-Null
    Remove-Job $server -Force
    if ($process -and !$process.WaitForExit(10000)) { Write-Warning 'The isolated test browser still needs to be closed.' }
    Write-Output "Isolated test files: $lab"
}
