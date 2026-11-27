$script:StoreUrl = 'https://clients2.google.com/service/update2/crx'
$script:UboId = 'fkgkibajhfbepljeaefdnfnegdcjomkh'
$script:OldUboId = 'cjpalhdlnbpafiamejdnhcphjbkeiagm'
$script:WebStoreId = 'ocaahdebbfolfmndjeplogmgcagdmblk'
$script:UboUrl = 'https://cdn.jsdelivr.net/gh/gorhill/uBlock@master/dist/chromium/update.xml'
$script:WebStoreUrl = 'https://raw.githubusercontent.com/NeverDecaf/chromium-web-store/master/updates.xml'
$script:GitHubAssetHosts = @('github.com','release-assets.githubusercontent.com','objects.githubusercontent.com')

function Initialize-CrxVerifier {
    if (!('Crx3' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'Crx3.cs') }
}

function Get-ExtensionInventory([string]$UserData) {
    if (!(Test-Path -LiteralPath $UserData -PathType Container)) { throw 'The browser user-data directory is unavailable.' }
    $profiles = @()
    foreach ($folder in (Get-ChildItem -LiteralPath $UserData -Directory -Force)) {
        $prefs = Join-Path $folder.FullName 'Preferences'
        $secure = Join-Path $folder.FullName 'Secure Preferences'
        if (!(Test-Path -LiteralPath $prefs) -and !(Test-Path -LiteralPath $secure)) { continue }
        Assert-LocalPath $folder.FullName
        $profiles += $folder.Name
        $settings = @{}
        foreach ($path in $prefs,$secure) {
            if (!(Test-Path -LiteralPath $path)) { continue }
            Assert-LocalPath $path
            $data = Read-Json $path
            if (!$data['extensions'] -or !$data['extensions']['settings']) { continue }
            foreach ($entry in $data['extensions']['settings'].GetEnumerator()) { $settings[$entry.Key] = $entry.Value }
        }
        foreach ($id in ($settings.Keys | Sort-Object)) {
            if ($id -cnotmatch '^[a-p]{32}$') { continue }
            $entry = $settings[$id]
            $manifest = $entry['manifest']
            $relative = [string]$entry['path']
            if (!$manifest -and $relative -match "^${id}[/\\][\d_.-]+$") {
                $path = Join-Path $folder.FullName "Extensions\$relative\manifest.json"
                Assert-LocalPath $path
                if (Test-Path -LiteralPath $path) { $manifest = Read-Json $path }
            }
            $disabled = $entry['state'] -eq 0 -or @($entry['disable_reasons'] | Where-Object { $null -ne $_ -and $_ -ne 0 }).Count -gt 0
            [pscustomobject]@{
                Profile = $folder.Name
                Id = $id
                Location = $entry['location']
                Enabled = !$disabled
                Manifest = $manifest
            }
        }
    }
    if (!$profiles.Count) { throw 'No readable Chromium profiles were found.' }
}

function Get-ExtensionChannel($Extension, $Approved) {
    if ($Extension.Location -in 5,10) { return 'Component' }
    if ($Extension.Location -ne 1 -or !$Extension.Manifest) { return 'Unknown' }
    $url = [string]$Extension.Manifest['update_url']
    switch -CaseSensitive ($Extension.Id) {
        $script:OldUboId { if ($url -ceq $script:StoreUrl) { return 'LegacyUbo' } }
        $script:UboId {
            if ($url -cin @($script:UboUrl,'https://raw.githubusercontent.com/gorhill/uBlock/master/dist/chromium/update.xml')) { return 'Ubo' }
        }
        $script:WebStoreId { if ($url -ceq $script:WebStoreUrl) { return 'WebStoreHelper' } }
        default {
            if ($url -ceq $script:StoreUrl -and $Approved[$Extension.Id] -ceq 'ChromeWebStore') { return 'Store' }
        }
    }
    'Unknown'
}

function Get-StoreUpdates($Ids, [version]$BrowserVersion) {
    $result = @{}
    $idsToCheck = @($Ids | Sort-Object -Unique)
    for ($offset = 0; $offset -lt $idsToCheck.Count; $offset += 20) {
        $last = [Math]::Min($offset + 19, $idsToCheck.Count - 1)
        $batch = @($idsToCheck[$offset..$last])
        if (@($batch | Where-Object { $_ -cnotmatch '^[a-p]{32}$' }).Count) { throw 'Invalid extension ID.' }
        $query = ($batch | ForEach-Object { 'x=' + [uri]::EscapeDataString("id=$_&uc") }) -join '&'
        $url = "${script:StoreUrl}?response=updatecheck&acceptformat=crx3&prodversion=$BrowserVersion&$query"
        $raw = Invoke-TrustedGet $url @('clients2.google.com')
        $settings = [Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = 'Prohibit'
        $settings.XmlResolver = $null
        $inputReader = [IO.MemoryStream]::new($raw)
        $reader = [Xml.XmlReader]::Create($inputReader, $settings)
        try {
            $xml = [Xml.XmlDocument]::new()
            $xml.XmlResolver = $null
            $xml.Load($reader)
        } finally { $reader.Dispose(); $inputReader.Dispose() }
        $ns = [Xml.XmlNamespaceManager]::new($xml.NameTable)
        $ns.AddNamespace('g', 'http://www.google.com/update2/response')
        foreach ($app in $xml.SelectNodes('/g:gupdate/g:app', $ns)) {
            $id = $app.GetAttribute('appid')
            if ($id -cnotin $batch -or $result.ContainsKey($id)) { throw 'Unexpected extension identity in the Web Store response.' }
            $entries = $app.SelectNodes('./g:updatecheck', $ns)
            if ($entries.Count -ne 1 -or $entries[0].GetAttribute('status') -ne 'ok') {
                $result[$id] = $null
                continue
            }
            $item = $entries[0]
            $location = [uri]$item.GetAttribute('codebase')
            $size = [long]$item.GetAttribute('size')
            $digest = $item.GetAttribute('hash_sha256')
            if (!$location.IsAbsoluteUri -or $location.Scheme -cne 'https' -or
                $location.Host -cne 'clients2.googleusercontent.com' -or
                $location.AbsolutePath -notmatch '^/crx/blobs/.+\.crx$' -or
                $size -le 0 -or $digest -cnotmatch '^[a-f0-9]{64}$') {
                throw 'Unexpected Web Store artifact source or integrity metadata.'
            }
            $result[$id] = @{
                Uri = $location; Version = $item.GetAttribute('version'); Digest = $digest; Size = $size
                Hosts = @('clients2.googleusercontent.com')
            }
        }
    }
    $result
}

function Get-ExtensionRelease([string]$Channel) {
    $repo = switch ($Channel) { Ubo { 'gorhill/uBlock' } WebStoreHelper { 'NeverDecaf/chromium-web-store' } }
    $release = Get-StableRelease $repo
    if ($Channel -eq 'Ubo' -and $release.tag_name -cmatch '^\d+\.\d+\.\d+$') {
        $name = "uBlock0_$($release.tag_name).chromium.crx"
        $version = $release.tag_name
    } elseif ($Channel -eq 'WebStoreHelper' -and $release.tag_name -cmatch '^v(\d+\.\d+\.\d+(?:\.\d+)?)$') {
        $name = 'Chromium.Web.Store.crx'
        $version = $Matches[1]
    } else { throw 'Unexpected stable extension release tag.' }
    $asset = Get-ReleaseAsset $release $repo $name
    $asset.Version = $version
    $asset.Hosts = $script:GitHubAssetHosts
    $asset
}

function Get-ManifestPermissions($Manifest) {
    foreach ($key in 'permissions','host_permissions','optional_permissions','optional_host_permissions') {
        foreach ($item in @($Manifest[$key])) {
            if ($null -ne $item) { "$key=" + (ConvertTo-Json -InputObject $item -Depth 12 -Compress) }
        }
    }
    foreach ($scriptEntry in @($Manifest['content_scripts'])) {
        if ($null -eq $scriptEntry) { continue }
        foreach ($field in 'matches','include_globs','exclude_matches','exclude_globs','all_frames','match_about_blank','match_origin_as_fallback','world') {
            foreach ($item in @($scriptEntry[$field])) {
                if ($null -ne $item) { "content_scripts.$field=" + (ConvertTo-Json -InputObject $item -Depth 12 -Compress) }
            }
        }
    }
    foreach ($key in 'externally_connectable','oauth2','sandbox','content_security_policy') {
        if ($Manifest[$key]) { "$key=" + (ConvertTo-Json -InputObject $Manifest[$key] -Depth 12 -Compress) }
    }
}

function Assert-ExtensionKey([string]$Id, $Manifest) {
    Initialize-CrxVerifier
    if (!$Manifest['key'] -or [Crx3]::ExtensionId([Convert]::FromBase64String($Manifest['key'])) -cne $Id) {
        throw 'The installed extension key does not match its ID.'
    }
}

function Get-VerifiedManifest($Asset, [string]$Id, [bool]$Store) {
    Initialize-CrxVerifier
    $limit = 32MB
    if ($Asset.Size -gt $limit) { throw 'The extension package exceeds the size limit.' }
    $bytes = Invoke-TrustedGet $Asset.Uri $Asset.Hosts $limit 30
    if ($bytes.Length -ne $Asset.Size -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -ine $Asset.Digest) {
        throw 'Extension package size or SHA-256 mismatch.'
    }
    $verified = [Crx3]::Verify($bytes, $Id, $Store)
    $manifest = $verified.Manifest | ConvertFrom-Json -AsHashtable
    if ((Get-Version $manifest.version) -ne (Get-Version $Asset.Version) -or
        ($manifest['key'] -and $manifest['key'] -cne $verified.PublicKey)) {
        throw 'Signed package key or version did not match its metadata.'
    }
    $manifest
}

function Get-PermissionChanges($Previous, $Candidate) {
    $old = @(Get-ManifestPermissions $Previous)
    $new = @(Get-ManifestPermissions $Candidate)
    $changes = @($new | Where-Object { $_ -cnotin $old })
    $changes += @($old | Where-Object { $_ -like 'content_scripts.exclude*' -and $_ -cnotin $new })
    $changes | Sort-Object -Unique
}

function Test-ExtensionCandidate($Extension, [string]$Channel, $Asset, [version]$BrowserVersion, [bool]$VerifyCurrent) {
    $manifest = $Extension.Manifest
    Assert-ExtensionKey $Extension.Id $manifest
    if (!$Asset) { return @{ Level = 'WARN'; Text = 'no verified package is currently offered'; Status = 'Action' } }
    $offered = Get-Version $Asset.Version
    $installed = Get-Version $manifest.version
    if ($offered -lt $installed) { return @{ Level = 'WARN'; Text = 'installed version is newer than the channel offers'; Status = 'Action' } }
    if ($offered -eq $installed -and !$VerifyCurrent) {
        return @{ Level = ' OK '; Text = 'current for verified channel'; Status = 'Complete' }
    }
    $remote = Get-VerifiedManifest $Asset $Extension.Id ($Channel -eq 'Store')
    $validChannel = switch ($Channel) {
        Store { $remote['update_url'] -ceq $script:StoreUrl }
        Ubo { $remote['manifest_version'] -eq 2 -and $remote['update_url'] -cin @($script:UboUrl,'https://raw.githubusercontent.com/gorhill/uBlock/master/dist/chromium/update.xml') }
        WebStoreHelper { $remote['update_url'] -ceq $script:WebStoreUrl }
    }
    if (!$validChannel) { throw 'Signed package changed its update source or required Manifest version.' }
    if ($remote['minimum_chrome_version'] -and (Get-Version $remote['minimum_chrome_version']) -gt $BrowserVersion) {
        return @{ Level = 'WARN'; Text = "$($Asset.Version) requires a newer browser"; Status = 'Action' }
    }
    $changes = @(Get-PermissionChanges $manifest $remote)
    if ($changes.Count -or $manifest.manifest_version -ne $remote.manifest_version) {
        return @{ Level = 'WARN'; Text = "$($Asset.Version) changes requested permissions or Manifest version. Review before installing"; Status = 'Action' }
    }
    if ($offered -gt $installed) {
        $backend = if ($Channel -eq 'Store') { 'Chromium Web Store prompt' } else { 'official GitHub CRX and Chromium prompt' }
        return @{ Level = 'WARN'; Text = "$($Asset.Version) SHA-256 and CRX3 signature verified. Review in $backend"; Status = 'Action' }
    }
    @{ Level = ' OK '; Text = 'installed version matches the signed channel package'; Status = 'Complete' }
}
