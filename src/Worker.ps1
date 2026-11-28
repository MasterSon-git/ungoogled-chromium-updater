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
        '^The installed browser files do not match the verified installer payload\.$')) {
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
    Write-Status $Level "$name $version ($mv, $enabled): $Text" "Extension $($Extension.Id) $version ($mv, ${enabled}): $Text"
}

function Invoke-ExtensionChecks($Inventory, $Config, [version]$Installed, $Previous, [bool]$DeepCheck) {
    $statuses = [Collections.Generic.List[string]]::new()
    $observed = @{}
    $storeIds = @($Inventory | Where-Object { (Get-ExtensionChannel $_ $Config.extensions) -eq 'Store' } | ForEach-Object Id)
    $storeFailure = $false
    try { $store = Get-StoreUpdates $storeIds $Installed }
    catch {
        Write-Status ERROR (Get-SafeProblem $_ 'The Chrome Web Store channel check failed.')
        $statuses.Add('Failed')
        $storeFailure = $true
    }
    $releases = @{}
    foreach ($extension in $Inventory) {
        $channel = Get-ExtensionChannel $extension $Config.extensions
        $key = $extension.Profile + '/' + $extension.Id
        $manifest = $extension.Manifest
        $record = if ($manifest) {
            @{ Version = $manifest['version']; Permissions = @(Get-ManifestPermissions $manifest) }
        }
        $old = $Previous[$key]
        try {
            $outcome = switch ($channel) {
                Component { @{ Level = 'INFO'; Text = 'built in and serviced with Chromium'; Status = 'Complete' } }
                Unknown { @{ Level = 'WARN'; Text = 'unapproved source or installation type. Review manually'; Status = 'Action' } }
                LegacyUbo {
                    Assert-ExtensionKey $extension.Id $manifest
                    if (!$releases['Ubo']) { $releases['Ubo'] = Get-ExtensionRelease 'Ubo' }
                    $asset = $releases['Ubo']
                    $signed = Get-VerifiedManifest $asset $script:UboId $false
                    if (!(Test-FullUboManifest $signed)) {
                        throw 'Unexpected Manifest version or source for full uBlock Origin.'
                    }
                    $review = if (@(Get-PermissionChanges $manifest $signed).Count) { ' Review changed permissions.' } else { '' }
                    @{ Level = 'WARN'; Text = "legacy Store ID. Signed full uBlock Origin $($asset.Version) is available via GitHub. Export and migrate in the browser.$review"; Status = 'Action' }
                }
                default {
                    if ($channel -eq 'Store') {
                        if ($storeFailure) { throw 'The Web Store data is unavailable.' }
                        $asset = $store[$extension.Id]
                    } else {
                        if (!$releases[$channel]) { $releases[$channel] = Get-ExtensionRelease $channel }
                        $asset = $releases[$channel]
                    }
                    $changed = $old -and $old['Version'] -ne $record.Version
                    Test-ExtensionCandidate $extension $channel $asset $Installed ($DeepCheck -or $changed)
                }
            }
            if ($record -and $old -and @($record.Permissions | Where-Object { $_ -cnotin $old['Permissions'] }).Count) {
                Write-ExtensionStatus $extension WARN 'new permissions observed in the installed manifest. Review in Chromium'
                $statuses.Add('Action')
                $record = $old
            }
            Write-ExtensionStatus $extension $outcome.Level $outcome.Text
            $statuses.Add($outcome.Status)
        } catch {
            Write-ExtensionStatus $extension ERROR (Get-SafeProblem $_ 'channel, manifest or package verification failed. Review the trusted source before installing')
            $statuses.Add('Failed')
            if ($old) { $record = $old }
        }
        if ($record) { $observed[$key] = $record }
    }
    @{ Status = Get-CheckStatus $statuses.ToArray(); Inventory = $observed }
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
        }
        if (!$hasMv2 -and (Test-Mv2Needed @(Get-ExtensionInventory $Config.userData))) {
            Write-Status WARN 'The profile now requires an MV2 compatibility check. Retry the browser update.'
            return @{ Status = 'Deferred'; Version = $Installed }
        }
        if ((Install-BrowserCandidate $Root $Config $Installed $Candidate $artifact $payload) -eq 'Deferred') {
            Write-Status WARN 'Browser update deferred. Close Chromium manually before the next installation attempt.'
            $status = 'Deferred'
        } else {
            $Installed = $Candidate.Version
            Write-Status ' OK ' "Installed and verified Windows distribution release $($Candidate.Tag)."
            $status = 'Complete'
        }
    }
    @{ Status = $status; Version = $Installed }
}

function Write-CompatibilityResult($Test, $Inventory) {
    if ($Test['UboVersion']) {
        $tested = Get-Version $Test.UboVersion
        Write-Status INFO "The isolated MV2 test covers full uBlock Origin $($Test.UboVersion) from GitHub. Other installed MV2 extensions were not tested."
        $different = foreach ($extension in $Inventory) {
            if ($extension.Id -notin $script:UboId,$script:OldUboId) { continue }
            $version = if ($extension.Manifest) { $extension.Manifest['version'] }
            try {
                if ((Get-Version $version) -ne $tested) { $version }
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
    } catch {
        Write-Status ERROR (Get-SafeProblem $_ 'Browser update check or installation failed. Review download verification and recovery instructions.')
        $results.Add('Failed')
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
    $extensions = if ($inventoryReady) {
        Invoke-ExtensionChecks $inventory $Config $installed $Previous.Inventory $VerifyCurrent
    } else { @{ Status = 'Failed'; Inventory = $Previous.Inventory } }
    $results.Add($extensions.Status)
    @{ Status = Get-CheckStatus $results.ToArray(); Inventory = $extensions.Inventory }
}

function Invoke-UpdateSession([string]$Root) {
    $pending = Join-Path $Root 'installation.json'
    Assert-LocalPath $pending
    $statePath = Join-Path $Root 'state.json'
    $config = Read-Config $root
    $state = Read-DailyState $statePath
    $forceCheck = $Force -or $CheckOnly -or $Apply -or $Stage -or $VerifyCurrent -or $SelfUpdateOutcome
    $due = Test-Due $state ([DateTimeOffset]::Now) $forceCheck
    $recover = Test-Path -LiteralPath $pending
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
        if (!$NoLaunch) { Start-Chromium $config $BrowserArguments }
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
    if (!$CheckOnly -and !$Stage) {
        $now = [DateTimeOffset]::Now
        Write-Json $statePath @{
            Schema = 1; Day = $now.ToString('yyyy-MM-dd'); Attempt = $now.ToString('o')
            Status = $outcome.Status; UpdaterStatus = $updaterStatus; Inventory = $outcome.Inventory
        }
    }
    switch ($outcome.Status) {
        Complete { Write-Status ' OK ' 'Update check completed.' }
        Action { Write-Status WARN 'Update check found items requiring review.' }
        Deferred { Write-Status WARN 'Update check completed with deferred work.' }
        Failed { Write-Status ERROR 'Update check did not complete successfully.' }
    }
    if (!$NoLaunch -and !$CheckOnly -and !$Stage -and !(Test-Path -LiteralPath $pending)) {
        Start-Chromium $config $BrowserArguments
    }
    if ($outcome.Status -eq 'Failed') { return 1 }
    if ($outcome.Status -eq 'Complete' -and $updaterStatus -cnotin 'Failed','Deferred','Unavailable') { return 0 }
    2
}

if ($Probe) {
    [void](Get-UpdaterVersion (Join-Path $PSScriptRoot 'Updater.version'))
    Initialize-CrxVerifier
    exit 42
}
