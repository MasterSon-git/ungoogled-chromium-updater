#Requires -Version 7.5
[CmdletBinding(DefaultParameterSetName = 'Build')]
param(
    [Parameter(ParameterSetName = 'Build')][ValidatePattern('\A[0-9a-f]{40}\z')][string]$Commit,
    [Parameter(ParameterSetName = 'Build')][string]$OutputDirectory,
    [Parameter(ParameterSetName = 'Build')][ValidatePattern('\A[0-9a-fA-F]{40}\z')][string]$CertificateThumbprint,
    [Parameter(Mandatory, ParameterSetName = 'Verify')][string]$VerifyPackage,
    [Parameter(Mandatory, ParameterSetName = 'Verify')][string]$Version
)

. (Join-Path $PSScriptRoot '../src/Common.ps1')
. (Join-Path $PSScriptRoot '../src/Browser.ps1')
. (Join-Path $PSScriptRoot '../src/SelfUpdate.ps1')

function New-UpdaterPackage([string]$Source, [string]$Path) {
    Assert-LocalPath $Path
    $stream = [IO.File]::Open($Path, 'CreateNew', 'ReadWrite', 'None')
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, 'Create', $true)
        try {
            $files = Get-UpdaterPackageFiles
            foreach ($name in $files.Keys) {
                $entry = $archive.CreateEntry($name, 'NoCompression')
                $entry.LastWriteTime = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
                $entry.ExternalAttributes = 0
                $inputStream = [IO.File]::OpenRead((Join-Path $Source $files[$name]))
                try {
                    $output = $entry.Open()
                    try { $inputStream.CopyTo($output) }
                    finally { $output.Dispose() }
                } finally { $inputStream.Dispose() }
            }
        } finally { $archive.Dispose() }
        $stream.Flush($true)
    } finally { $stream.Dispose() }
}

function Write-UpdaterSignature([string]$Path, [string]$Version, [Security.Cryptography.RSA]$Signer) {
    $size = (Get-Item -LiteralPath $Path).Length
    $digest = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    $signature = $Signer.SignData((Get-UpdaterSignatureInput "v$Version" $size $digest),
        [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    Assert-UpdaterSignature "v$Version" $size $digest $signature
    Assert-LocalPath "$Path.sig"
    $file = [IO.File]::Open("$Path.sig", 'CreateNew', 'Write', 'None')
    try {
        $file.Write($signature)
        $file.Flush($true)
    } finally { $file.Dispose() }
}

function Test-UpdaterReleasePackage([string]$Path, [string]$Version, [string]$Destination) {
    Assert-LocalPath $Path
    Assert-LocalPath "$Path.sig"
    $size = (Get-Item -LiteralPath $Path).Length
    if ($size -le 0 -or $size -gt $script:UpdaterPackageLimit -or
        (Get-Item -LiteralPath "$Path.sig").Length -notin 384,512) {
        throw 'Unexpected release package or signature size.'
    }
    $digest = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    Assert-UpdaterSignature "v$Version" $size $digest ([IO.File]::ReadAllBytes("$Path.sig"))
    Expand-UpdaterPackage $Path $Destination $Version
}

if ($MyInvocation.InvocationName -eq '.') { return }
if ($PSCmdlet.ParameterSetName -eq 'Build' -and (!$Commit -or !$OutputDirectory)) {
    throw 'Provide the reviewed commit SHA and an output directory.'
}

# Work from Git objects so generated files and working-tree changes cannot enter the ZIP.
$work = New-PrivateRoot (Join-Path $env:TEMP ('uc-updater-release-' + [guid]::NewGuid().ToString('N')))
try {
    $expanded = Join-Path $work 'verified'
    if ($PSCmdlet.ParameterSetName -eq 'Verify') {
        $expected = Convert-UpdaterVersion $Version
        if ($expected.HasBuild) { throw 'Build metadata is reserved in updater release tags.' }
        $package = [IO.Path]::GetFullPath($VerifyPackage, (Get-Location).ProviderPath)
        Test-UpdaterReleasePackage $package $Version $expanded
        Assert-UpdaterWorker $expanded
        Write-Output "Verified updater v$Version."
        return
    }

    $repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    git -C $repo merge-base --is-ancestor $Commit refs/remotes/origin/main
    if ($LASTEXITCODE) { throw 'Select a reviewed commit reachable from the fetched origin/main.' }
    $sourceZip = Join-Path $work 'source.zip'
    git -C $repo archive --format=zip "--output=$sourceZip" $Commit -- @((Get-UpdaterPackageFiles).Values)
    if ($LASTEXITCODE) { throw 'Could not archive the release inputs from Git.' }
    $source = Join-Path $work 'source'
    [IO.Compression.ZipFile]::ExtractToDirectory($sourceZip, $source)
    $release = Get-UpdaterVersion (Join-Path $source 'src/Updater.version')
    $output = [IO.Path]::GetFullPath($OutputDirectory, (Get-Location).ProviderPath)
    Assert-LocalPath $output
    [void][IO.Directory]::CreateDirectory($output)
    $package = Join-Path $output $script:UpdaterPackageName
    New-UpdaterPackage $source $package
    Expand-UpdaterPackage $package $expanded $release.Text
    Assert-UpdaterWorker $expanded
    if ($CertificateThumbprint) {
        $certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$CertificateThumbprint"
        $signer = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificate)
        if (!$signer) { throw 'The release-signing certificate must have an accessible RSA private key.' }
        try { Write-UpdaterSignature $package $release.Text $signer }
        finally { $signer.Dispose() }
    }
    Write-Output "Updater v$($release.Text) from commit $Commit"
    Get-FileHash -LiteralPath $package -Algorithm SHA256 | Select-Object Algorithm, Hash
} finally {
    Assert-OrdinaryTree $work
    if ([IO.Path]::GetDirectoryName($work) -ine [IO.Path]::GetFullPath($env:TEMP) -or
        [IO.Path]::GetFileName($work) -cnotmatch '^uc-updater-release-[a-f0-9]{32}$') {
        throw 'Unexpected release workspace.'
    }
    Remove-Item -LiteralPath $work -Recurse -Force
}
