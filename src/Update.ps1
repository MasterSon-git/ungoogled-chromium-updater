#Requires -Version 7.5
[CmdletBinding()]
param(
    [switch]$Force, [switch]$CheckOnly, [switch]$Stage, [switch]$Apply, [switch]$NoLaunch,
    [switch]$VerifyCurrent, [switch]$Dispatch, [switch]$Interactive,
    [string]$Payload,
    [string[]]$BrowserArguments = @()
)

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Extensions.ps1')
. (Join-Path $PSScriptRoot 'Browser.ps1')

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
    if ($reason -cmatch '^The update request timed out\.$|^Update server returned HTTP \d{3}\.$|^The Chromium installer exited with code -?\d+\.$|^Backup copy failed or was inconsistent \(Robocopy exit \d+\)\.$') {
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
                    if ($signed.manifest_version -ne 2 -or $signed['update_url'] -cnotin @(
                        $script:UboUrl,'https://raw.githubusercontent.com/gorhill/uBlock/master/dist/chromium/update.xml')) {
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

function Invoke-Workflow($Root, $Config, $Previous) {
    $results = [Collections.Generic.List[string]]::new()
    $installed = Get-BrowserVersion $Config.browserPath $Config.architecture
    Write-Status CHECK "Installed Chromium $installed ($($Config.architecture))."
    $inventory = @()
    $inventoryReady = $false
    try {
        $inventory = @(Get-ExtensionInventory $Config.userData)
        $inventoryReady = $true
    } catch {
        Write-Status ERROR 'Chromium extension inventory could not be read. Browser installation is blocked until this check works.'
        $results.Add('Failed')
    }
    $hasMv2 = @($inventory | Where-Object { $_.Location -notin 5,10 -and (!$_.Manifest -or $_.Manifest['manifest_version'] -ne 3) }).Count -gt 0
    try {
        $stable = Get-UpstreamStable $Config.architecture
        Write-Status INFO "Broadly served Google Chrome stable: $stable. See Google Chrome Releases for security advisories."
        $candidate = Get-WindowsCandidate $Config.architecture
        Write-Status CHECK "Official stable ungoogled-chromium Windows build: $($candidate.Tag)."
        if ($candidate.Version -lt $stable -and $installed -lt $stable) {
            Write-Status WARN 'The Windows channel trails Google Chrome stable. Review upstream security fixes before postponing maintenance.'
            $results.Add('Action')
        }
        if ($candidate.Version -lt $installed) {
            Write-Status WARN 'The installed version is newer than the listed stable Windows release.'
            $results.Add('Action')
        } elseif ($candidate.Version -eq $installed) {
            Write-Status ' OK ' 'Chromium is current for the Windows distribution.'
        } else {
            $approved = Test-BrowserApproval $Config.browserApproval $candidate $stable $hasMv2
            if ($hasMv2 -and (!$approved -or $Config.browserApproval['mv2RuntimeVerified'] -ne $true)) {
                Write-Status WARN 'Installed MV2 add-ons require isolated runtime validation for this exact Windows release before installation.'
            } elseif ($hasMv2) {
                Write-Status INFO 'The configured exact-release approval records an isolated MV2 test. Profile-specific behavior still needs validation.'
            }
            $canInstall = !$CheckOnly -and !$Stage -and ($Apply -or $Config.installOnLaunch)
            if (($Stage -or ($canInstall -and $inventoryReady -and $approved)) -and $candidate.Version -gt $installed) {
                $artifact = Get-BrowserArtifact $Root $candidate
            }
            if (!$approved) {
                Write-Status WARN 'The available browser release needs an exact release approval. See the browser update procedure.'
                $results.Add('Action')
            } elseif (!$canInstall -or !$inventoryReady) {
                Write-Status WARN 'Browser update available. Use the verified install procedure when ready.'
                $results.Add('Action')
            } elseif (@(@($Config.browserArgs) + $BrowserArguments | Where-Object { $_ -match '^--user-data-dir(?:=|$)' }).Count) {
                Write-Status WARN 'The launch requests a different user-data directory. Update the standard profile separately.'
                $results.Add('Deferred')
            } else {
                $update = Install-BrowserCandidate $Root $Config $installed $candidate $artifact
                if ($update -eq 'Deferred') {
                    Write-Status WARN 'Browser update deferred. Close Chromium manually before the next installation attempt.'
                    $results.Add('Deferred')
                } else {
                    $installed = $candidate.Version
                    Write-Status ' OK ' "Installed and verified Chromium $installed."
                }
            }
        }
    } catch {
        Write-Status ERROR (Get-SafeProblem $_ 'Browser update check or installation failed. Review download verification and recovery instructions.')
        $results.Add('Failed')
    }
    $extensions = if ($inventoryReady) {
        Invoke-ExtensionChecks $inventory $Config $installed $Previous.Inventory $VerifyCurrent
    } else { @{ Status = 'Failed'; Inventory = $Previous.Inventory } }
    $results.Add($extensions.Status)
    @{ Status = Get-CheckStatus $results.ToArray(); Inventory = $extensions.Inventory }
}

function Invoke-Launcher {
    if ($Payload) {
        $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Payload))
        $BrowserArguments = ConvertFrom-Json -InputObject $decoded -NoEnumerate
        if ($BrowserArguments -isnot [array] -or @($BrowserArguments | Where-Object { $_ -isnot [string] }).Count) {
            throw 'Invalid launcher arguments.'
        }
    }
    if (($CheckOnly -and $Apply) -or ($Stage -and $Apply)) { throw 'Choose one of check-only, stage or apply.' }
    $root = Get-UpdaterRoot
    Assert-PrivateRoot $root
    $config = Read-Config $root
    $statePath = Join-Path $root 'state.json'
    $pending = Join-Path $root 'installation.json'
    Assert-LocalPath $pending
    $lock = Enter-UpdateLock $root
    if (!$lock) {
        if ($Dispatch) { return 10 }
        Write-Status INFO 'Another launcher is checking Chromium. Waiting for it to finish.'
        $lock = Enter-UpdateLock $root 420
        if (!$lock) {
            Write-Status WARN 'The other launcher is still active. Wait for it to finish, then retry this launch.'
            return 2
        }
    }
    try {
        $state = Read-DailyState $statePath
        $forceCheck = $Force -or $CheckOnly -or $Apply -or $Stage -or $VerifyCurrent
        $due = Test-Due $state ([DateTimeOffset]::Now) $forceCheck
        $recover = Test-Path -LiteralPath $pending
        if ($Dispatch -and ($due -or $recover)) { return 10 }
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
        $outcome = Invoke-Workflow $root $config $state
        if (!$CheckOnly -and !$Stage) {
            $now = [DateTimeOffset]::Now
            Write-Json $statePath @{
                Schema = 1; Day = $now.ToString('yyyy-MM-dd'); Attempt = $now.ToString('o')
                Status = $outcome.Status; Inventory = $outcome.Inventory
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
        if ($outcome.Status -eq 'Complete') { return 0 }
        if ($outcome.Status -eq 'Failed') { return 1 }
        2
    } finally { $lock.Dispose() }
}

try { $code = Invoke-Launcher }
catch {
    if ($Dispatch) { exit 10 }
    Write-Host '[ERROR] The updater could not read its configuration or complete the operation. Check the private runtime and recovery instructions.' -ForegroundColor Red
    $code = 1
}
if ($Interactive) {
    if ($code) { [void](Read-Host 'Press Enter to close this window') }
    else { Start-Sleep -Milliseconds 1500 }
}
exit $code
