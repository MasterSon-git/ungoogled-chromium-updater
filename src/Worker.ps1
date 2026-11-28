#Requires -Version 7.5
param([switch]$Probe)
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Extensions.ps1')
. (Join-Path $PSScriptRoot 'Browser.ps1')
. (Join-Path $PSScriptRoot 'BrowserPayload.ps1')
. (Join-Path $PSScriptRoot 'Mv2.ps1')
. (Join-Path $PSScriptRoot 'SelfUpdate.ps1')
. (Join-Path $PSScriptRoot 'UpdaterShortcut.ps1')

$script:log = $null
function Write-Status([string]$Level, [string]$Message, [string]$LogMessage = $Message) {
    $colors = @{ INFO = 'Gray'; CHECK = 'Cyan'; ' OK ' = 'Green'; WARN = 'Yellow'; ERROR = 'Red' }
    Write-Host "[$Level] $Message" -ForegroundColor $colors[$Level]
    if ($script:log) {
        $line = [DateTimeOffset]::Now.ToString('o') + " [$Level] $LogMessage" + [Environment]::NewLine
        [IO.File]::AppendAllText($script:log, $line, [Text.Encoding]::ASCII)
    }
}

function Enable-Log([string]$Root) {
    $path = Join-Path $Root 'logs'
    Assert-LocalPath $path
    [void][IO.Directory]::CreateDirectory($path)
    $name = [DateTime]::Today.ToString('yyyy-MM-dd')
    $file = Join-Path $path "$name.log"
    $rotated = Join-Path $path "$name.1.log"
    Assert-LocalPath $file
    Assert-LocalPath $rotated
    if ((Test-Path -LiteralPath $file) -and (Get-Item -LiteralPath $file).Length -ge 512KB) {
        [IO.File]::Move($file, $rotated, $true)
    }
    foreach ($old in (Get-ChildItem -LiteralPath $path -File)) {
        if ($old.Name -cmatch '^\d{4}-\d{2}-\d{2}(?:\.1)?\.log$' -and
            $old.LastWriteTime -lt [DateTime]::Today.AddDays(-30) -and
            !($old.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            [IO.File]::Delete($old.FullName)
        }
    }
    $script:log = $file
}

function Get-SafeProblem($ErrorRecord, [string]$Fallback) {
    $reason = $ErrorRecord.Exception.Message
    if ($reason -cmatch ('^The update request timed out\.$|^Update server returned HTTP \d{3}\.$|' +
        '^The Chromium installer exited with code -?\d+\.$|^Backup copy failed or was inconsistent \(Robocopy exit \d+\)\.$|' +
        '^Windows installer has an invalid Authenticode status\.$|^The Windows installer signer does not match the configured pin\.$|' +
        '^The standing browser policy does not accept this unsigned installer\.$|^Browser installer SHA-256 or byte count mismatch\.$|' +
        '^The installed browser files do not match the verified installer payload\.$|' +
        '^The private extension package cache is full\.$|^Installed manifest source or permissions differ from the signed package\.$|' +
        '^Installed extension files differ from the signed manifest evidence\.$')) {
        return "$Fallback $reason"
    }
    $Fallback
}

function Get-CheckStatus([string[]]$Results) {
    foreach ($status in 'Failed','Deferred','Action') {
        if ($Results -contains $status) { return $status }
    }
    'Complete'
}

function Write-ExtensionStatus($Extension, [string]$Level, [string]$Text) {
    $name = if ($Extension.Manifest) { [string]$Extension.Manifest['name'] } else { $Extension.Id }
    if (!$name -or $name.StartsWith('__MSG_') -or $name -notmatch '^[ -~]{1,90}$') { $name = $Extension.Id }
    $version = if ($Extension.Manifest -and $Extension.Manifest['version'] -match '^\d+(\.\d+){0,3}$') { $Extension.Manifest['version'] } else { 'unknown' }
    $enabled = if ($Extension.Enabled) { 'enabled' } else { 'disabled' }
    $mv = if ($Extension.Manifest -and $Extension.Manifest['manifest_version'] -in 2,3) { "MV$($Extension.Manifest['manifest_version'])" } else { 'MV unknown' }
    $profile = ConvertTo-Json -InputObject ([string]$Extension.Profile) -Compress -EscapeHandling EscapeNonAscii
    Write-Status $Level "$profile / $name $version ($mv, $enabled): $Text" "Extension $($Extension.Id) $version ($mv, ${enabled}): $Text"
}

function Invoke-ExtensionChecks($Inventory, $Config, [version]$Installed, $Previous, [bool]$DeepCheck,
    [string]$StageRoot, $Compatibility, [bool]$Refresh, $TestedUboAsset) {
    $statuses = [Collections.Generic.List[string]]::new()
    $candidates = [Collections.Generic.List[object]]::new()
    $needsReview = $false
    $observed = @{}
    $storeIds = @($Inventory | Where-Object { (Get-ExtensionChannel $_ $Config.extensions) -eq 'Store' } | ForEach-Object Id)
    $storeFailure = $false
    try { $store = Get-StoreUpdates $storeIds $Installed }
    catch {
        Write-Status ERROR (Get-SafeProblem $_ 'The Chrome Web Store channel check failed.')
        $statuses.Add('Failed')
        $storeFailure = $true
    }
    $releases = @{ Ubo = $TestedUboAsset }
    $packages = @{}
    $lastId = $null
    foreach ($extension in ($Inventory | Sort-Object Id)) {
        if ($extension.Id -cne $lastId) { $packages.Clear(); $lastId = $extension.Id }
        $channel = Get-ExtensionChannel $extension $Config.extensions
        $key = $extension.Profile + '/' + $extension.Id
        $manifest = $extension.Manifest
        $old = $Previous[$key]
        $record = @{ Version = $(if ($manifest) { $manifest['version'] }); Enabled = $extension.Enabled; Location = $extension.Location }
        if ($old -and $old['HandoffDigest']) { $record.HandoffDigest = $old['HandoffDigest'] }
        if ($old -and $old['PermissionSchema'] -eq 2) {
            $record.PermissionSchema = 2
            $record.Permissions = $old['Permissions']
        }
        try {
            $outcome = switch ($channel) {
                Component { @{ Level = 'INFO'; Text = 'built in and serviced with Chromium'; Status = 'Complete'; Update = 'Component' } }
                Unknown { @{ Level = 'WARN'; Text = 'unapproved source or installation type. Review manually'; Status = 'Action'; Update = 'Discovered' } }
                LegacyUbo {
                    Assert-ExtensionKey $extension.Id $manifest
                    if (!$releases['Ubo']) { $releases['Ubo'] = Get-ExtensionRelease 'Ubo' }
                    $asset = $releases['Ubo']
                    $record.Offered = $asset.Version
                    $package = Get-ChannelPackage $asset $script:UboId 'Ubo' $packages
                    $migration = @{ Level = 'WARN'; Status = 'Action'; Update = 'Verified'
                        Text = "Legacy Store ID. Signed full uBlock Origin $($asset.Version) uses a new ID. See the backup and migration procedure." }
                    if ($StageRoot -and (!$package.Manifest['minimum_chrome_version'] -or
                        (Get-Version $package.Manifest['minimum_chrome_version']) -le $Installed)) {
                        $migration.Path = Save-VerifiedExtensionPackage $StageRoot $script:UboId $asset $package.Bytes
                        $migration.Update = 'Pending'
                    }
                    $migration
                }
                default {
                    if ($channel -eq 'Store') {
                        if ($storeFailure) { throw 'The Web Store data is unavailable.' }
                        $asset = $store[$extension.Id]
                    } else {
                        if (!$releases[$channel]) { $releases[$channel] = Get-ExtensionRelease $channel }
                        $asset = $releases[$channel]
                    }
                    if ($asset) { $record.Offered = $asset.Version }
                    $verify = $DeepCheck -or !$old -or $old['Version'] -cne $record.Version -or
                        $old['Update'] -in 'Pending','Verified','Failed' -or
                        ($channel -eq 'Ubo' -and $Compatibility -and $Compatibility.UboVersion -ceq $record.Version)
                    Test-ExtensionCandidate $extension $channel $asset $Installed $verify $StageRoot $packages
                }
            }
            if (!$old -and ($Previous.Count -or $Refresh)) {
                Write-ExtensionStatus $extension INFO 'discovered in this profile'
            } elseif ($old -and $old.Contains('Enabled') -and $old['Enabled'] -ne $record.Enabled) {
                Write-ExtensionStatus $extension INFO 'enabled state changed in Chromium'
            }
            if ($manifest -and $channel -ne 'Component') {
                $permissions = @(Get-ManifestPermissions $manifest)
                $oldPermissions = $record['Permissions']
                $changes = if ($record['PermissionSchema'] -eq 2) {
                    @(Compare-PermissionSnapshots $oldPermissions $permissions)
                } elseif ($old -and $old.Contains('Permissions')) {
                    # Legacy snapshots can still detect added API and host permissions.
                    $prefix = '^(permissions|host_permissions|optional_permissions|optional_host_permissions)='
                    @(Compare-PermissionSnapshots ($old['Permissions'] -cmatch $prefix) ($permissions -cmatch $prefix))
                }
                if ($changes) {
                    Write-ExtensionStatus $extension WARN "changed permission or scope fields observed in Chromium ($($changes -join ', ')). Review in Chromium."
                    $statuses.Add('Action')
                    $needsReview = $true
                    if ($record['PermissionSchema'] -ne 2) { $record.Permissions = $old['Permissions'] }
                } else {
                    $record.PermissionSchema = 2
                    $record.Permissions = $permissions
                }
            }
            Write-ExtensionStatus $extension $outcome.Level $outcome.Text
            if ($outcome['Path']) {
                $instruction = if ($channel -eq 'LegacyUbo') { 'Follow the documented ID migration procedure with this verified CRX' }
                    else { 'Verified CRX for this profile. Open it manually if automatic handoff is unavailable' }
                Write-Status INFO "$instruction`n$($outcome.Path)" 'The exact verified extension package is available in private storage.'
            }
        } catch {
            Write-ExtensionStatus $extension ERROR (Get-SafeProblem $_ 'channel, manifest or package verification failed. Review the trusted source before installing')
            $outcome = @{ Status = 'Failed'; Update = 'Failed' }
            if ($old -and $old.Contains('Permissions')) { $record.Permissions = $old['Permissions'] }
        }
        $record.Update = $outcome.Update
        $statuses.Add($outcome.Status)
        $observed[$key] = $record
        $canHandOff = $outcome.Update -ceq 'Pending' -and $channel -cin 'Store','Ubo','WebStoreHelper'
        if ($canHandOff) {
            $record.OfferedDigest = $asset.Digest
            if ($old -and $old['AwaitingPromptDigest'] -ieq $asset.Digest) {
                $record.AwaitingPromptDigest = $asset.Digest
            }
            $candidates.Add(@{ Key = $key; Profile = $extension.Profile; Version = $record.Version
                Channel = $channel; Path = $outcome.Path; Asset = $asset })
        } elseif ($outcome.Status -ne 'Complete') {
            $needsReview = $true
        }
        if ($Compatibility -and $extension.Id -cin $script:UboId,$script:OldUboId) {
            $tested = $Compatibility.UboVersion
            if ($channel -eq 'Ubo' -and $outcome.Update -ceq 'Installed' -and
                $record.Version -ceq $tested -and $outcome.Digest -ieq $Compatibility.UboDigest) {
                Write-ExtensionStatus $extension ' OK ' "installed ID and version match the tested Chromium and full uBlock Origin $tested combination. The gate tested unpacked filtering."
            } else {
                Write-ExtensionStatus $extension WARN "tested full uBlock Origin $tested differs from the installed or verified extension evidence ($($outcome.Update)). The installed combination is unverified."
                $statuses.Add('Action')
                if (!$canHandOff) { $needsReview = $true }
            }
        }
    }
    foreach ($key in ($Previous.Keys | Sort-Object)) {
        if (!$observed.ContainsKey($key) -and $key -cmatch '/([a-p]{32})$') {
            $id = $Matches[1]
            $profile = ConvertTo-Json -InputObject $key.Substring(0, $key.Length - 33) -Compress -EscapeHandling EscapeNonAscii
            Write-Status INFO "$profile / $id is no longer registered in the inventory." "Extension $id is no longer registered in its previous profile."
        }
    }
    @{ Status = Get-CheckStatus $statuses.ToArray(); Inventory = $observed; Candidates = $candidates.ToArray(); NeedsReview = $needsReview }
}

function Test-AwaitingExtensionHandoff($Config, [string[]]$Arguments, $Inventory) {
    if (!@($Inventory.Values | Where-Object { $_ -is [Collections.IDictionary] -and $_['AwaitingPromptDigest'] }).Count) {
        return $false
    }
    try {
        $scope = Get-ChromiumHandoffScope $Config $Arguments
        if (!$scope) { return $false }
        $owner = Find-ReadyChromium $Config 0
        $switches = if ($owner) { Get-RunningChromiumSwitches $Config $owner } else { $scope.Switches }
        $null -ne $switches -and (Test-RegularChromiumLaunch $switches) -and (Test-ChromiumExtensionPrompt $scope.Data $switches)
    } catch { $false }
}

function Invoke-ExtensionHandoffs($Config, [string[]]$Arguments, $Candidates, $State, [string]$StatePath, [bool]$Retry) {
    $pending = @(foreach ($candidate in $Candidates) {
        $record = $State.Inventory[$candidate.Key]
        if ($Retry -or $record['HandoffDigest'] -ine $candidate.Asset.Digest -or
            $record['AwaitingPromptDigest'] -ieq $candidate.Asset.Digest) { $candidate }
    })
    if ($pending.Count -lt $Candidates.Count) {
        Write-Status INFO 'Previously requested extensions are still pending. To retry a dismissed prompt, hold Shift while opening Chromium Updater.'
    }
    if (!$pending.Count) { return $true }
    $scope = Get-ChromiumHandoffScope $Config $Arguments
    if (!$scope) {
        Write-Status WARN 'Automatic CRX handoff requires a regular Chromium launch for the configured user-data directory. Use the staged CRX in the listed profile.'
        return $false
    }
    $data = $scope.Data
    $owner = Find-ReadyChromium $Config
    if (!$owner) {
        Write-Status WARN 'The configured Chromium instance was not ready for CRX handoff. Use the staged CRX in the listed profile.'
        return $false
    }
    $activeSwitches = Get-RunningChromiumSwitches $Config $owner
    if ($null -eq $activeSwitches) {
        Write-Status WARN 'Chromium launch settings could not be confirmed. Use the staged CRX in the listed profile.'
        return $false
    }
    if (!(Test-RegularChromiumLaunch $activeSwitches)) {
        Write-Status WARN 'The running Chromium instance is using a launch mode that prevents automatic CRX handoff. Use the staged CRX in the listed profile.'
        return $false
    }
    if (!(Test-ChromiumExtensionPrompt $data $activeSwitches)) {
        $changed = $false
        foreach ($candidate in $pending) {
            $record = $State.Inventory[$candidate.Key]
            if ($record['AwaitingPromptDigest'] -ine $candidate.Asset.Digest) {
                $record.AwaitingPromptDigest = $candidate.Asset.Digest
                $changed = $true
            }
        }
        if ($changed) { Write-Json $StatePath $State }
        Write-Status WARN 'In Chromium, open chrome://flags/#extension-mime-request-handling, choose Always prompt for install, and relaunch Chromium. The updater will retry on your next regular launch.'
        return !$changed
    }
    $wasWaiting = $false
    foreach ($candidate in $pending) {
        $record = $State.Inventory[$candidate.Key]
        if ($record.Contains('AwaitingPromptDigest')) {
            [void]$record.Remove('AwaitingPromptDigest')
            $wasWaiting = $true
        }
    }
    if ($wasWaiting) { Write-Json $StatePath $State }
    $current = @{}
    foreach ($extension in (Get-ExtensionInventory $data)) { $current["$($extension.Profile)/$($extension.Id)"] = $extension }
    $handled = 0
    $handoffConfig = @{ browserPath = $Config.browserPath; browserArgs = @() }
    foreach ($group in ($pending | Group-Object Profile)) {
        $profile = $group.Name
        if ($profile -in 'Guest Profile','System Profile' -or $profile -match '[\\/:*?"<>|\x00-\x1f]') { continue }
        $target = @("--user-data-dir=$data", "--profile-directory=$profile")
        $batch = [Collections.Generic.List[object]]::new()
        $length = $Config.browserPath.Length + $target[0].Length + $target[1].Length + 15
        foreach ($candidate in $group.Group) {
            $extension = $current[$candidate.Key]
            if (!$extension -or (Get-ExtensionChannel $extension $Config.extensions) -cne $candidate.Channel -or
                $extension.Manifest['version'] -cne $candidate.Version) { continue }
            try {
                Assert-ExtensionKey $extension.Id $extension.Manifest
                if (!(Test-ArtifactFile $candidate.Path $candidate.Asset)) { throw 'Staged CRX integrity check failed.' }
            } catch { continue }
            $length += $candidate.Path.Length + 3
            if ($length -gt 30000) { break }
            $batch.Add($candidate)
        }
        if (!$batch.Count) { continue }
        if ((Find-ReadyChromium $Config 0) -ne $owner) { break }
        # Persist the exact requests before opening dialogs so an interrupted launcher does not repeat them.
        $previousDigests = @{}
        foreach ($candidate in $batch) {
            $record = $State.Inventory[$candidate.Key]
            $previousDigests[$candidate.Key] = $record['HandoffDigest']
            $record.HandoffDigest = $candidate.Asset.Digest
        }
        Write-Json $StatePath $State
        try {
            Start-Chromium $handoffConfig ($target + @($batch | ForEach-Object { $_.Path }))
        } catch {
            foreach ($candidate in $batch) {
                $record = $State.Inventory[$candidate.Key]
                if ($previousDigests[$candidate.Key]) { $record.HandoffDigest = $previousDigests[$candidate.Key] }
                else { [void]$record.Remove('HandoffDigest') }
            }
            Write-Json $StatePath $State
            Write-Status WARN 'Chromium could not be started for a CRX handoff. Use the staged CRX in the listed profile.'
            continue
        }
        $handled += $batch.Count
        Write-Status INFO "Requested Chromium installation for $($batch.Count) verified CRX package(s). Review Chromium's prompts. Installation is still pending."
    }
    if ($handled -lt $pending.Count) {
        Write-Status WARN 'Some CRXs could not be handed off. Rerun staging to check the current registration and package, then use the listed manual path if needed.'
        return $false
    }
    $true
}

function Test-Mv2Needed($Inventory) {
    @($Inventory | Where-Object { $_.Location -notin 5,10 -and (!$_.Manifest -or $_.Manifest['manifest_version'] -ne 3) }).Count -gt 0
}

function Invoke-BrowserUpdate($Root, $Config, [version]$Installed, $Candidate, [bool]$InventoryReady, $Inventory) {
    $release = Get-BrowserReleaseStatus $Root $Config $Installed $Candidate
    switch ($release) {
        Older { Write-Status WARN 'The installed Chromium version or packaging revision is newer than the official stable candidate.' }
        UnknownRevision { Write-Status WARN 'The installed Windows packaging revision is unknown. Same-version installation is blocked until a newer Chromium version is available.' }
        ChangedRelease { Write-Status ERROR 'Official release metadata changed for the recorded packaging revision. Review the source before updating.' }
        Current { Write-Status ' OK ' "Installed Windows distribution release $($Candidate.Tag) is current." }
    }
    if ($release -eq 'ChangedRelease') { return @{ Status = 'Failed'; Version = $Installed } }
    if ($Stage -and ($release -in 'Newer','UnknownRevision' -or ($TestCompatibility -and $release -eq 'Current'))) {
        $artifact = Get-BrowserArtifact $Root $Candidate
        Write-Status INFO "Staged $($Candidate.Tag) installer SHA-256 $($Candidate.Digest)."
        if ($TestCompatibility) {
            Assert-BrowserTrust $Config.browserTrust $artifact
            $test = Get-BrowserCompatibility $Root $Candidate $artifact $true
            $status = Write-CompatibilityResult $test $Inventory
            if ($status -ne 'Complete') { return @{ Status = $status; Version = $Installed } }
        }
    }
    if ($release -ne 'Newer') {
        $status = if ($release -eq 'Current') { 'Complete' } else { 'Action' }
        return @{ Status = $status; Version = $Installed }
    }
    $status = 'Action'
    $compatibility = $null
    $applied = $false
    $testedUboAsset = $null
    if ($CheckOnly -or $Stage -or !$InventoryReady) {
        Write-Status WARN 'A newer official Windows release is available.'
    } elseif ($Config.browserUpdateMode -eq 'Manual' -and
        (!$Apply -or !(Test-BrowserApproval $Config['browserApproval'] $Candidate))) {
        Write-Status WARN 'Manual mode requires the matching tag and SHA-256 in browserApproval and an explicit -Apply.'
    } elseif (@(@($Config.browserArgs) + $BrowserArguments | Where-Object { $_ -match '^--user-data-dir(?:=|$)' }).Count) {
        Write-Status WARN 'The launch requests a different user-data directory. Update the standard profile separately.'
        $status = 'Deferred'
    } elseif (Test-BrowserBusy $Config) {
        Write-Status WARN 'Browser update deferred. Close Chromium manually before the next installation attempt.'
        $status = 'Deferred'
    } else {
        Assert-RegisteredInstall $Config $Installed
        $artifact = Get-BrowserArtifact $Root $Candidate
        Assert-BrowserTrust $Config.browserTrust $artifact
        $installInventory = @(Get-ExtensionInventory $Config.userData)
        $hasMv2 = (Test-Mv2Needed $Inventory) -or (Test-Mv2Needed $installInventory)
        $payload = $null
        if ($hasMv2 -or $Candidate.Version -eq $Installed) {
            $test = Get-BrowserCompatibility $Root $Candidate $artifact $hasMv2
            $status = Write-CompatibilityResult $test $installInventory
            if ($status -ne 'Complete') { return @{ Status = $status; Version = $Installed } }
            $payload = $test.Files
            if ($test['UboVersion'] -and $test['UboDigest']) {
                $compatibility = @{ UboVersion = $test.UboVersion; UboDigest = $test.UboDigest }
                $testedUboAsset = $test['UboAsset']
            }
        }
        if (!$hasMv2 -and (Test-Mv2Needed @(Get-ExtensionInventory $Config.userData))) {
            Write-Status WARN 'The profile now requires an MV2 compatibility check. Retry the browser update.'
            return @{ Status = 'Deferred'; Version = $Installed }
        }
        if ((Install-BrowserCandidate $Root $Config $Installed $Candidate $artifact $payload $compatibility) -eq 'Deferred') {
            Write-Status WARN 'Browser update deferred. Close Chromium manually before the next installation attempt.'
            $status = 'Deferred'
            $compatibility = $null
            $testedUboAsset = $null
        } else {
            $Installed = $Candidate.Version
            $applied = $true
            Write-Status ' OK ' "Installed and verified Windows distribution release $($Candidate.Tag)."
            $status = 'Complete'
        }
    }
    @{ Status = $status; Version = $Installed; Applied = $applied; Compatibility = $compatibility; TestedUboAsset = $testedUboAsset }
}

function Write-CompatibilityResult($Test, $Inventory) {
    if ($Test['UboVersion']) {
        $tested = Get-Version $Test.UboVersion
        Write-Status INFO "The isolated MV2 test covers full uBlock Origin $($Test.UboVersion) from GitHub. Other installed MV2 extensions were not tested."
        $different = foreach ($extension in $Inventory) {
            if ($extension.Id -notin $script:UboId,$script:OldUboId) { continue }
            $version = if ($extension.Manifest) { $extension.Manifest['version'] }
            try {
                $observedVersion = Get-Version $version
                if ($extension.Id -cne $script:UboId -or $observedVersion -ne $tested) { $version }
            } catch { 'unknown' }
        }
        if ($different) {
            $versions = ($different | Sort-Object -Unique) -join ', '
            Write-Status WARN "Installed full uBlock Origin version(s) $versions were not matched by the test of $($Test.UboVersion). Compatibility for those installations is unverified."
        }
    }
    if ($Test.Status -eq 'Pass') {
        Write-Status ' OK ' "Browser compatibility pass. $($Test.Detail)"
        return 'Complete'
    }
    $level = if ($Test.Status -eq 'OperationalFailure') { 'ERROR' } else { 'WARN' }
    $label = switch ($Test.Status) { OperationalFailure { 'operational failure' } default { $Test.Status.ToLowerInvariant() } }
    Write-Status $level "Browser compatibility $label. $($Test.Detail) See browser maintenance before applying this release."
    if ($level -eq 'ERROR') { return 'Failed' }
    'Action'
}

function Invoke-Workflow($Root, $Config, $Previous) {
    $results = [Collections.Generic.List[string]]::new()
    $installed = Get-BrowserVersion $Config.browserPath $Config.architecture
    Write-Status CHECK "Installed Chromium $installed ($($Config.architecture))."
    if ($Config['legacyBrowserConfig']) {
        Write-Status WARN 'Legacy settings are in safe Manual mode. Run Setup.ps1 -Install and review browserTrust to migrate.'
        $results.Add('Action')
    }
    $inventory = @()
    $inventoryReady = $false
    $refresh = $Previous['InventoryRefresh']
    $update = @{}
    try {
        $inventory = @(Get-ExtensionInventory $Config.userData)
        $inventoryReady = $true
    } catch {
        Write-Status ERROR 'Chromium extension inventory could not be read. Browser installation is blocked until this check works.'
        $results.Add('Failed')
    }
    try {
        $candidate = Get-WindowsCandidate $Config.architecture
        Write-Status CHECK "Official stable ungoogled-chromium Windows build: $($candidate.Tag)."
        $update = Invoke-BrowserUpdate $Root $Config $installed $candidate $inventoryReady $inventory
        $installed = $update.Version
        $results.Add($update.Status)
        if ($update['Applied']) {
            $refresh = 'AwaitingLaunch'
            Write-Status INFO 'Refreshing the extension inventory after browser installation. Startup changes will be checked after the next launcher handoff.'
            $inventoryReady = $false
            try {
                $inventory = @(Get-ExtensionInventory $Config.userData)
                $inventoryReady = $true
            } catch {
                Write-Status ERROR 'Post-install extension inventory could not be read. The prior inventory is retained for the next check.'
                $results.Add('Failed')
            }
        }
    } catch {
        Write-Status ERROR (Get-SafeProblem $_ 'Browser update check or installation failed. Review download verification and recovery instructions.')
        $results.Add('Failed')
    }
    if ($refresh -ceq 'Pending') {
        if ($inventoryReady) { Write-Status INFO 'Reconciling extension registrations after the browser handoff.' }
        $refresh = $null
    }
    try {
        $stable = Get-UpstreamStable $Config.architecture
        Write-Status INFO "Broadly served Google Chrome stable is $stable."
        if ($installed -lt $stable) {
            Write-Status WARN "Installed Chromium $installed trails Chrome stable $stable. Review upstream security advisories for the remaining patch gap."
            $results.Add('Action')
        }
    } catch {
        Write-Status WARN (Get-SafeProblem $_ 'Chrome stable comparison is unavailable. The official Windows release is verified independently.')
        $results.Add('Action')
    }
    $browserStatus = Get-CheckStatus $results.ToArray()
    $extensions = if ($inventoryReady) {
        $stageRoot = if (!$CheckOnly) { $Root }
        $compatibility = $update['Compatibility']
        if (!$compatibility -and @($inventory | Where-Object { $_.Id -cin $script:UboId,$script:OldUboId }).Count) {
            $compatibility = Get-InstalledMv2Evidence $Root $Config $installed
        }
        Invoke-ExtensionChecks $inventory $Config $installed $Previous.Inventory $VerifyCurrent $stageRoot $compatibility (
            $update['Applied'] -or $Previous['InventoryRefresh'] -ceq 'Pending') $update['TestedUboAsset']
    } else { @{ Status = 'Failed'; Inventory = $Previous.Inventory } }
    $results.Add($extensions.Status)
    @{
        Status = Get-CheckStatus $results.ToArray(); Inventory = $extensions.Inventory; InventoryRefresh = $refresh
        Candidates = $extensions['Candidates']; NativeActionOnly = $browserStatus -ceq 'Complete' -and !$extensions['NeedsReview']
    }
}

function Invoke-UpdateSession([string]$Root) {
    $pending = Join-Path $Root 'installation.json'
    Assert-LocalPath $pending
    $statePath = Join-Path $Root 'state.json'
    $config = Read-Config $root
    $state = Read-DailyState $statePath
    $forceCheck = $Force -or $CheckOnly -or $Apply -or $Stage -or $VerifyCurrent -or $RetryExtensionUpdates -or $SelfUpdateOutcome -or
        $state['InventoryRefresh'] -ceq 'Pending'
    $due = Test-Due $state ([DateTimeOffset]::Now) $forceCheck
    $recover = Test-Path -LiteralPath $pending
    if (!$due -and !$recover -and !$NoLaunch -and (Test-AwaitingExtensionHandoff $config $BrowserArguments $state.Inventory)) {
        $due = $true
    }
    if ($Dispatch -and ($due -or $recover)) { return 10 }
    if ($SelfUpdateOutcome -ceq 'Applied' -or ($Interactive -and $due -and !$CheckOnly -and !$Stage -and
        ![IO.File]::Exists((Join-Path $root 'updater-shortcut.json')))) {
        Set-UpdaterShortcut $root
    }
    if ($recover) {
        Write-Status ERROR 'A browser installation was interrupted. Follow the recovery procedure before launching Chromium.'
        return 1
    }
    if (!$due) {
        if (!$NoLaunch) {
            if ($state['InventoryRefresh'] -ceq 'AwaitingLaunch' -and
                !(@($config.browserArgs) + $BrowserArguments -match '^--user-data-dir(?:=|$)')) {
                $state.InventoryRefresh = 'Pending'
                Write-Json $statePath $state
            }
            Start-Chromium $config $BrowserArguments
        }
        return 0
    }
    if (!$CheckOnly -and !$Stage) { Enable-Log $root }
    if ($state.Status -eq 'Corrupt') { Write-Status WARN 'The previous daily check state was invalid. Running a fresh check.' }
    $updaterStatus = if ($SelfUpdateOutcome) { $SelfUpdateOutcome } else { 'Skipped' }
    if ($SelfUpdateOutcome -ceq 'Applied') {
        $version = (Get-UpdaterVersion (Join-Path $PSScriptRoot 'Updater.version')).Text
        Write-Status ' OK ' "Activated updater $version."
    } elseif ($SelfUpdateOutcome -ceq 'Failed') {
        Write-Status WARN 'Updater activation failed. Continuing with the previous updater.'
    } elseif ($Interactive -and !$CheckOnly -and !$Stage -and $config['selfUpdateEnabled']) {
        $resume = @{
            Force = [bool]$Force; Apply = [bool]$Apply; NoLaunch = [bool]$NoLaunch
            VerifyCurrent = [bool]$VerifyCurrent; Interactive = [bool]$Interactive
            BrowserArguments = $BrowserArguments
        }
        if ($RetryExtensionUpdates) { $resume.RetryExtensionUpdates = $true }
        try {
            $updaterStatus = Install-UpdaterCandidate $Root $PSScriptRoot $config.updaterChannel $resume
            if ($updaterStatus -ceq 'Handoff') { return 20 }
            if ($updaterStatus -ceq 'Unavailable') { Write-Status WARN 'Updater self-update is unavailable. This installation has no trusted release key.' }
            if ($updaterStatus -ceq 'Deferred') { Write-Status WARN 'Another updater process is preparing activation.' }
        } catch {
            $updaterStatus = 'Failed'
            Write-Status WARN (Get-SafeProblem $_ 'Updater self-update failed. Continuing with the current updater.')
        }
    }
    $outcome = Invoke-Workflow $root $config $state
    $launch = !$NoLaunch -and !$CheckOnly -and !$Stage -and !(Test-Path -LiteralPath $pending)
    $refresh = $outcome['InventoryRefresh']
    if ($launch -and $refresh -ceq 'AwaitingLaunch' -and
        !(@($config.browserArgs) + $BrowserArguments -match '^--user-data-dir(?:=|$)')) {
        $refresh = 'Pending'
    }
    if (!$CheckOnly -and !$Stage) {
        $now = [DateTimeOffset]::Now
        $nextState = @{
            Schema = 1; Day = $now.ToString('yyyy-MM-dd'); Attempt = $now.ToString('o')
            Status = $outcome.Status; UpdaterStatus = $updaterStatus; Inventory = $outcome.Inventory; InventoryRefresh = $refresh
        }
        Write-Json $statePath $nextState
    }
    switch ($outcome.Status) {
        Complete { Write-Status ' OK ' 'Update check completed.' }
        Action { Write-Status WARN 'Update check found items requiring review.' }
        Deferred { Write-Status WARN 'Update check completed with deferred work.' }
        Failed { Write-Status ERROR 'Update check did not complete successfully.' }
    }
    $canCloseConsole = $false
    if ($launch) {
        Start-Chromium $config $BrowserArguments
        if ($outcome['Candidates']) {
            try {
                $canCloseConsole = Invoke-ExtensionHandoffs $config $BrowserArguments $outcome.Candidates $nextState $statePath $RetryExtensionUpdates
            } catch {
                Write-Status WARN 'Automatic CRX handoff could not finish. Use the listed staged files in Chromium.'
            }
        }
    }
    if ($outcome.Status -eq 'Failed') { return 1 }
    if ($outcome.Status -eq 'Complete' -and $updaterStatus -cnotin 'Failed','Deferred','Unavailable') { return 0 }
    if ($Interactive -and $canCloseConsole -and $outcome['NativeActionOnly'] -and
        $updaterStatus -cnotin 'Failed','Deferred','Unavailable') { return 21 }
    2
}

if ($Probe) {
    [void](Get-UpdaterVersion (Join-Path $PSScriptRoot 'Updater.version'))
    Initialize-CrxVerifier
    exit 42
}
