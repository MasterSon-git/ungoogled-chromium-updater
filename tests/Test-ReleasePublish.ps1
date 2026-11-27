#Requires -Version 7.5
. (Join-Path $PSScriptRoot '../tools/Release.ps1')

$gh = Get-Command gh -CommandType Application | Select-Object -First 1
$name = 'uc-release-cli-tests-' + [guid]::NewGuid().ToString('N')
$work = New-PrivateRoot (Join-Path $env:TEMP $name)
try {
    git -C $work init --quiet --initial-branch main
    if ($LASTEXITCODE) { throw 'Could not initialize the release CLI fixture.' }
    git -C $work -c user.name='Release Fixture' -c user.email='release@example.test' -c commit.gpgSign=false commit --quiet --allow-empty -m 'Release fixture'
    if ($LASTEXITCODE) { throw 'Could not create the release CLI fixture commit.' }

    $notesPath = Join-Path $work 'annotated notes.md'
    $notes = "Staging fixture`n`nCheck the exact note text.`nKeep line breaks.`n"
    [IO.File]::WriteAllText($notesPath, $notes)
    $tag = 'v9.9.9-rc.1'
    git -C $work -c user.name='Release Fixture' -c user.email='release@example.test' -c tag.gpgSign=false tag --annotate --file $notesPath $tag
    if ($LASTEXITCODE) { throw 'Could not create the isolated annotated tag.' }
    if ((Get-UpdaterTagNotes $work $tag) -cne $notes) { throw 'Annotated release notes changed.' }

    # A missing notes file stops the real CLI after flag validation and before HTTP.
    $package = Join-Path $work 'fixture package.zip'
    [IO.File]::WriteAllText($package, 'fixture data')
    [IO.File]::WriteAllText("$package.sig", 'fixture signature')
    $missingNotes = 'missing release notes.md'
    $arguments = Get-UpdaterReleaseCreateArguments $tag $package (Join-Path $work $missingNotes) $true
    $start = [Diagnostics.ProcessStartInfo]::new($gh.Source)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = $work
    $start.Environment.Clear()
    $start.Environment['SystemRoot'] = $env:SystemRoot
    $start.Environment['GH_CONFIG_DIR'] = Join-Path $work 'gh-config'
    $start.Environment['GH_PROMPT_DISABLED'] = '1'
    $start.Environment['GH_TOKEN'] = 'fixture-token'
    $start.Environment['HTTPS_PROXY'] = 'http://127.0.0.1:1'
    $start.Environment['HTTP_PROXY'] = 'http://127.0.0.1:1'
    foreach ($argument in $arguments) { [void]$start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(15000)) {
            $process.Kill()
            throw 'GitHub CLI fixture timed out.'
        }
        $diagnostic = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        if (!$process.ExitCode -or !$diagnostic.Contains($missingNotes, [StringComparison]::Ordinal)) {
            throw "GitHub CLI did not accept the release flags before the expected notes-file error.`n$diagnostic"
        }
    } finally { $process.Dispose() }
    Write-Output 'PASS annotated notes and actual GitHub CLI release argument compatibility'
} finally {
    Assert-OrdinaryTree $work
    if ($work -ine [IO.Path]::GetFullPath((Join-Path $env:TEMP $name))) { throw 'Unexpected release CLI test workspace.' }
    Remove-Item -LiteralPath $work -Recurse -Force
}
