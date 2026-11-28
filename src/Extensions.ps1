$script:StoreUrl = 'https://clients2.google.com/service/update2/crx'
$script:UboId = 'fkgkibajhfbepljeaefdnfnegdcjomkh'
$script:OldUboId = 'cjpalhdlnbpafiamejdnhcphjbkeiagm'
$script:WebStoreId = 'ocaahdebbfolfmndjeplogmgcagdmblk'
$script:UboUrl = 'https://cdn.jsdelivr.net/gh/gorhill/uBlock@master/dist/chromium/update.xml'
$script:WebStoreUrl = 'https://raw.githubusercontent.com/NeverDecaf/chromium-web-store/master/updates.xml'

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
            $manifestPath = $null
            if ($relative -cmatch "^${id}[/\\]\d{1,6}(?:\.\d{1,6}){0,3}_\d+$") {
                $manifestPath = Join-Path $folder.FullName "Extensions\$relative\manifest.json"
                if (!$manifest) {
                    Assert-LocalPath $manifestPath
                    if ([IO.File]::Exists($manifestPath)) { $manifest = Read-Json $manifestPath }
                }
            }
            $disabled = $entry['state'] -eq 0 -or @($entry['disable_reasons'] | Where-Object { $null -ne $_ -and $_ -ne 0 }).Count -gt 0
            [pscustomobject]@{
                Profile = $folder.Name
                Id = $id
                Location = $entry['location']
                Enabled = !$disabled
                Manifest = $manifest
                ManifestPath = $manifestPath
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

function ConvertTo-CanonicalManifestValue($Value) {
    if ($Value -is [Collections.IDictionary]) {
        [string[]]$keys = @($Value.Keys)
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        $result = [ordered]@{}
        foreach ($key in $keys) { $result[$key] = ConvertTo-CanonicalManifestValue $Value[$key] }
        return $result
    }
    if ($Value -is [array]) {
        return ,@(foreach ($item in $Value) { ConvertTo-CanonicalManifestValue $item })
    }
    $Value
}

function Get-ManifestPermissions($Manifest) {
    foreach ($key in 'permissions','host_permissions','optional_permissions','optional_host_permissions') {
        foreach ($item in @($Manifest[$key])) {
            if ($null -ne $item) {
                "$key=" + (ConvertTo-Json -InputObject (ConvertTo-CanonicalManifestValue $item) -Depth 20 -Compress)
            }
        }
    }
    foreach ($scriptEntry in $Manifest['content_scripts']) {
        if ($null -eq $scriptEntry) { continue }
        $rule = [ordered]@{}
        foreach ($field in 'matches','include_globs','exclude_matches','exclude_globs') {
            [string[]]$patterns = @($scriptEntry[$field] | Where-Object { $null -ne $_ } | Sort-Object -CaseSensitive -Unique)
            [Array]::Sort($patterns, [StringComparer]::Ordinal)
            $rule[$field] = $patterns
        }
        foreach ($field in 'js','css') { $rule[$field] = @($scriptEntry[$field] | Where-Object { $null -ne $_ }) }
        foreach ($field in 'all_frames','match_about_blank','match_origin_as_fallback') {
            $rule[$field] = $scriptEntry[$field] -eq $true
        }
        $rule['world'] = $scriptEntry['world'] ?? 'ISOLATED'
        $rule['run_at'] = $scriptEntry['run_at'] ?? 'document_idle'
        'content_scripts=' + (ConvertTo-Json -InputObject $rule -Depth 12 -Compress)
    }
    foreach ($key in 'externally_connectable','oauth2','sandbox','content_security_policy','web_accessible_resources',
        'cross_origin_embedder_policy','cross_origin_opener_policy') {
        if ($Manifest.Contains($key)) {
            "$key=" + (ConvertTo-Json -InputObject (ConvertTo-CanonicalManifestValue $Manifest[$key]) -Depth 20 -Compress)
        }
    }
}

function Assert-ExtensionKey([string]$Id, $Manifest) {
    Initialize-CrxVerifier
    if (!$Manifest['key'] -or [Crx3]::ExtensionId([Convert]::FromBase64String($Manifest['key'])) -cne $Id) {
        throw 'The installed extension key does not match its ID.'
    }
}

function Get-VerifiedExtensionPackage($Asset, [string]$Id, [bool]$Store) {
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
    @{ Manifest = $manifest; Bytes = $bytes; Proof = $verified }
}

function Test-FullUboManifest($Manifest) {
    $Manifest['manifest_version'] -eq 2 -and $Manifest['update_url'] -cin @(
        $script:UboUrl,'https://raw.githubusercontent.com/gorhill/uBlock/master/dist/chromium/update.xml')
}

function Compare-PermissionSnapshots($Previous, $Candidate, [switch]$Exact) {
    $old = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $new = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in $Previous) { [void]$old.Add($item) }
    foreach ($item in $Candidate) { [void]$new.Add($item) }
    $changes = @(foreach ($item in $new) {
        if (!$old.Contains($item)) { ($item -split '=', 2)[0] }
    })
    $changes += @(foreach ($item in $old) {
        $field = ($item -split '=', 2)[0]
        if (!$new.Contains($item) -and ($Exact -or $field -cnotin @(
            'permissions','host_permissions','optional_permissions','optional_host_permissions','content_scripts'))) {
            $field
        }
    })
    $changes | Sort-Object -Unique
}

function Get-ChannelPackage($Asset, [string]$Id, [string]$Channel, $Packages) {
    $key = "$Channel/$Id/$($Asset.Version)/$($Asset.Digest)/$($Asset.Size)"
    if ($Packages.ContainsKey($key)) { return $Packages[$key] }
    $package = Get-VerifiedExtensionPackage $Asset $Id ($Channel -eq 'Store')
    $remote = $package.Manifest
    $validChannel = switch ($Channel) {
        Store { $remote['update_url'] -ceq $script:StoreUrl }
        Ubo { Test-FullUboManifest $remote }
        WebStoreHelper { $remote['update_url'] -ceq $script:WebStoreUrl }
    }
    if (!$validChannel) { throw 'Signed package changed its update source or required Manifest version.' }
    $Packages[$key] = $package
    $package
}

function Save-VerifiedExtensionPackage([string]$Root, [string]$Id, $Asset, [byte[]]$Bytes) {
    if ($Id -cnotmatch '^[a-p]{32}$' -or $Asset.Digest -cnotmatch '^[0-9a-fA-F]{64}$') {
        throw 'Invalid staged extension identity.'
    }
    $version = Get-Version $Asset.Version
    $directory = Join-Path $Root 'extension-packages'
    $path = Join-Path $directory "$Id-$version-$($Asset.Digest.ToLowerInvariant()).crx"
    Assert-LocalPath $path
    [void][IO.Directory]::CreateDirectory($directory)
    if (![IO.File]::Exists($path) -or !(Test-ArtifactFile $path $Asset)) {
        $size = 0L
        $expired = [DateTime]::UtcNow.AddDays(-7)
        foreach ($file in (Get-ChildItem -LiteralPath $directory -File -Force)) {
            if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint -or
                $file.Name -cnotmatch '^[a-p]{32}-[\d.]+-[a-f0-9]{64}\.crx(?:\.[a-f0-9]{32}\.tmp)?$') { continue }
            if ($file.LastWriteTimeUtc -lt $expired) { [IO.File]::Delete($file.FullName) }
            elseif ($file.FullName -ine $path) { $size += $file.Length }
        }
        if ($size + $Asset.Size -gt 256MB) { throw 'The private extension package cache is full.' }
        $temp = "$path.$([guid]::NewGuid().ToString('N')).tmp"
        try {
            [IO.File]::WriteAllBytes($temp, $Bytes)
            if (!(Test-ArtifactFile $temp $Asset)) { throw 'Staged extension package size or SHA-256 mismatch.' }
            [IO.File]::Move($temp, $path, $true)
        } finally { [IO.File]::Delete($temp) }
    }
    $path
}

function Test-ExtensionCandidate($Extension, [string]$Channel, $Asset, [version]$BrowserVersion, [bool]$VerifyCurrent,
    [string]$StageRoot, $Packages = @{}) {
    $manifest = $Extension.Manifest
    Assert-ExtensionKey $Extension.Id $manifest
    if (!$Asset) { return @{ Level = 'WARN'; Text = 'no package is currently offered'; Status = 'Action'; Update = 'Unavailable' } }
    $offered = Get-Version $Asset.Version
    $installed = Get-Version $manifest.version
    if ($offered -lt $installed) {
        return @{ Level = 'WARN'; Text = 'installed version is newer than the channel offers'; Status = 'Action'; Update = 'Unavailable' }
    }
    if ($offered -eq $installed -and !$VerifyCurrent) {
        return @{ Level = 'INFO'; Text = 'registered version is current in channel metadata'; Status = 'Complete'; Update = 'Current' }
    }
    $package = Get-ChannelPackage $Asset $Extension.Id $Channel $Packages
    $remote = $package.Manifest
    if ($remote['minimum_chrome_version'] -and (Get-Version $remote['minimum_chrome_version']) -gt $BrowserVersion) {
        return @{ Level = 'WARN'; Text = "$($Asset.Version) verified and requires a newer browser"; Status = 'Action'; Update = 'Verified' }
    }
    $changes = @(Compare-PermissionSnapshots (Get-ManifestPermissions $manifest) (Get-ManifestPermissions $remote) -Exact:($offered -eq $installed))
    if ($manifest.manifest_version -ne $remote.manifest_version) { $changes += 'manifest_version' }
    if ($offered -eq $installed) {
        if ($manifest['update_url'] -cne $remote['update_url'] -or $changes.Count) {
            throw 'Installed manifest source or permissions differ from the signed package.'
        }
        if ($Extension.PSObject.Properties['ManifestPath'] -and $Extension.ManifestPath) {
            Assert-LocalPath $Extension.ManifestPath
            $onDisk = Read-Json $Extension.ManifestPath
            if ($onDisk['key']) { Assert-ExtensionKey $Extension.Id $onDisk }
            if ((Get-Version $onDisk['version']) -ne $installed -or $onDisk['update_url'] -cne $remote['update_url'] -or
                $onDisk['manifest_version'] -ne $remote['manifest_version'] -or
                @(Compare-PermissionSnapshots (Get-ManifestPermissions $remote) (Get-ManifestPermissions $onDisk) -Exact).Count) {
                throw 'Installed extension files differ from the signed manifest evidence.'
            }
        }
        return @{ Level = ' OK '; Text = 'installed ID, version, source and permission fields match the signed channel package'
            Status = 'Complete'; Update = 'Installed'; Digest = $Asset.Digest }
    }
    $outcome = @{ Level = 'WARN'; Text = "$($Asset.Version) SHA-256 and CRX3 signature verified."; Status = 'Action'; Update = 'Verified' }
    if ($changes.Count) {
        $outcome.Text += " Review changed permission or scope fields before installing ($($changes -join ', '))."
    }
    if ($StageRoot) {
        $outcome.Path = Save-VerifiedExtensionPackage $StageRoot $Extension.Id $Asset $package.Bytes
        $outcome.Update = 'Pending'
        $outcome.Text += if ($Extension.Enabled) { ' Pending installation in Chromium.' }
            else { ' Pending installation in Chromium. Keep the extension disabled.' }
    } else { $outcome.Text += ' Run a normal launcher check for Chromium handoff, or Update.ps1 -Stage to save the verified CRX.' }
    $outcome
}
