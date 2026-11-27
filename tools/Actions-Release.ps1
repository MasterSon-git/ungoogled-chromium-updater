#Requires -Version 7.5
param([Parameter(Mandatory)][ValidateSet('Build','Sign','Publish')][string]$Phase)

$signingSecret = $env:UPDATER_SIGNING_KEY
$env:UPDATER_SIGNING_KEY = $null
. (Join-Path $PSScriptRoot 'Release.ps1')

function Get-TaggedRelease([string]$Repository, [string]$Tag, [string]$EventRevision) {
    if (!$Tag.StartsWith('v', [StringComparison]::Ordinal)) { throw 'Invalid updater release tag.' }
    $version = Convert-UpdaterVersion $Tag.Substring(1)
    if ($version.HasBuild) { throw 'Build metadata is reserved in updater release tags.' }
    $commit = git -C $Repository rev-parse --verify "refs/tags/${Tag}^{commit}"
    if ($LASTEXITCODE) { throw 'The selected release tag is missing.' }
    $eventCommit = git -C $Repository rev-parse --verify "${EventRevision}^{commit}"
    if ($LASTEXITCODE) { throw 'The triggering revision is missing.' }
    $head = git -C $Repository rev-parse HEAD
    if ($LASTEXITCODE -or $commit -cne $eventCommit -or $commit -cne $head) {
        throw 'The tag, triggering revision and checkout must resolve to the same commit.'
    }
    git -C $Repository merge-base --is-ancestor $commit refs/remotes/origin/main
    if ($LASTEXITCODE) { throw 'Select a release commit from reviewed main.' }
    if ((Get-UpdaterVersion (Join-Path $Repository 'src/Updater.version')).Text -cne $version.Text) {
        throw 'The release tag does not match the updater version file.'
    }
    @{ Tag = $Tag; Commit = $commit; Version = $version.Text; Prerelease = ($version.Pre.Count -gt 0) }
}

if ($MyInvocation.InvocationName -eq '.') { return }

if ($env:GITHUB_EVENT_NAME -cne 'push' -or $env:GITHUB_REF_TYPE -cne 'tag' -or
    $env:GITHUB_REPOSITORY -cne $script:UpdaterRepository -or $env:GITHUB_SHA -cnotmatch '\A[0-9a-f]{40}\z') {
    throw 'Releases require a tag push in the canonical repository.'
}
$event = Read-Json $env:GITHUB_EVENT_PATH
if ($event['created'] -ne $true -or $event['deleted'] -ne $false -or $event['forced'] -ne $false) {
    throw 'Releases require a newly created tag.'
}
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$release = Get-TaggedRelease $repo $env:GITHUB_REF_NAME $env:GITHUB_SHA

$output = Join-Path $repo 'release-out'
$unsigned = Join-Path $output 'unsigned'
$package = Join-Path $unsigned $script:UpdaterPackageName
if ($Phase -eq 'Build') {
    & (Join-Path $PSScriptRoot 'Test-Project.ps1')
    $repeat = Join-Path $output 'repeat'
    & (Join-Path $PSScriptRoot 'Release.ps1') -Commit $release.Commit -OutputDirectory $unsigned
    & (Join-Path $PSScriptRoot 'Release.ps1') -Commit $release.Commit -OutputDirectory $repeat
    $hash = (Get-FileHash -LiteralPath $package).Hash
    if ((Get-FileHash -LiteralPath (Join-Path $repeat $script:UpdaterPackageName)).Hash -cne $hash) {
        throw 'The selected release build was not reproducible.'
    }
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "hash=$hash"
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value "Verified reproducible updater $($release.Tag) at $($release.Commit). ZIP SHA-256 ``$hash``."
    return
}

Assert-LocalPath $package
$length = (Get-Item -LiteralPath $package).Length
if ($env:EXPECTED_PACKAGE_HASH -cnotmatch '\A[A-F0-9]{64}\z' -or
    $length -le 0 -or $length -gt $script:UpdaterPackageLimit -or
    (Get-FileHash -LiteralPath $package).Hash -cne $env:EXPECTED_PACKAGE_HASH) {
    throw 'The downloaded release package does not match the tested build.'
}
$publicKey = if ($script:UpdaterBridgeSigningPublicKey) { $script:UpdaterBridgeSigningPublicKey } else { $script:UpdaterReleasePublicKey }
$verified = Join-Path $output 'verified'
$signature = Join-Path (Join-Path $output 'signed') ($script:UpdaterPackageName + '.sig')
if ($Phase -eq 'Sign') {
    Expand-UpdaterPackage $package $verified $release.Version
    (New-UpdaterVerificationKey $publicKey).Dispose()
    $env:UPDATER_SIGNING_KEY = $signingSecret
    $signingSecret = $null
    Write-EnvironmentUpdaterSignature $package $release.Version $publicKey
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($signature))
    [IO.File]::Move("$package.sig", $signature)
    return
}

Assert-LocalPath $signature
[IO.File]::Copy($signature, "$package.sig")
Test-UpdaterReleasePackage $package $release.Version $verified $publicKey
$immutable = gh api -H 'X-GitHub-Api-Version: 2026-03-10' "repos/$script:UpdaterRepository/immutable-releases" --jq '.enabled'
if ($LASTEXITCODE -or $immutable -cne 'true') { throw 'Enable immutable releases before publishing.' }
$options = @('--verify-tag','--notes-from-tag','--repo',$script:UpdaterRepository)
if ($release.Prerelease) { $options += '--prerelease' }
gh release create $release.Tag $package "$package.sig" @options
if ($LASTEXITCODE) { throw 'GitHub release publication failed. Inspect the release before retrying.' }
