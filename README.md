# Ungoogled Chromium Updater

This Windows launcher automatically installs eligible stable builds from the official ungoogled-chromium Windows distribution when Chromium is closed. It verifies the installer, checks Manifest V2 compatibility when needed, and backs up the browser and profiles before installation. It reports the remaining Chrome stable patch gap and audits installed extension update channels. Extension installation uses Chromium's prompts.

## Install

Run from PowerShell 7.5 or newer, as the same Windows user who runs Chromium.

```powershell
.\src\Setup.ps1 -Install
$updater = Join-Path $env:LOCALAPPDATA 'UngoogledChromiumUpdater'
notepad (Join-Path $updater 'config.json')
& (Join-Path $updater 'app\Update.ps1') -CheckOnly -VerifyCurrent
.\src\Setup.ps1 -Integrate
```

Setup builds the small Windows launcher with the Windows .NET Framework C# compiler. It installs everything under `%LOCALAPPDATA%\UngoogledChromiumUpdater`. Configuration starts with [config.example.json](config.example.json). Select the installed browser architecture (`x64`, `arm64`, or `x86`), browser executable, and user-data directory. The installer workflow supports the registered per-user installation in `%LOCALAPPDATA%\Chromium`. Use `browserArgs` for arguments shared by all launches. Leave it empty for arguments already present on your shortcuts.

Install current official [7-Zip](https://www.7-zip.org/download.html) in Program Files if Chromium has Manifest V2 extensions or needs a same-version packaging update. The updater uses it to extract the exact installer payload without running the installer. In Automatic mode, launch normally after reviewing `browserTrust`. Choose Manual mode to require an exact tag and SHA-256 approval and an explicit `-Apply`. On upgrade, Setup backs up legacy settings and migrates them to Manual mode. Review the standing trust policy and select Automatic explicitly when ready. See [browser maintenance](docs/maintenance.md).

Add a verified Chrome Web Store extension's exact ID to `extensions` with the value `"ChromeWebStore"` after checking its official listing and developer identity. See [extension maintenance](docs/extensions.md) for official GitHub channels and migration. The first run reports unapproved sources for review.

## Launch and check

Start Chromium from an integrated Desktop or Start Menu shortcut. The first applicable launch on each Windows local day shows a color-coded console. The launcher starts Chromium after the check. A complete check is reused for the rest of the local day. Deferred work retries after 15 minutes, failures after 30 minutes, and items requiring review after two hours. A new day or a forced check bypasses those intervals. A warning or error stays visible until acknowledged.

```powershell
$update = Join-Path $env:LOCALAPPDATA 'UngoogledChromiumUpdater\app\Update.ps1'
& $update -Force
& $update -CheckOnly -VerifyCurrent
& $update -Stage
& $update -Stage -TestCompatibility
& $update -Apply -NoLaunch
& $update -Force -BrowserArguments @('--profile-directory=Default','https://example.com/')
```

`-CheckOnly` checks release metadata and, where needed, verifies extension packages in memory. `-VerifyCurrent` also checks signed packages for the same installed version. `-Stage` stages and verifies the installer for an available update or an unknown installed packaging revision. Add `-TestCompatibility` to run the isolated full uBlock Origin test and cache a pass for the exact artifacts. These modes leave the installed browser, production profiles, and daily check state untouched. The script returns 0 for a completed check, 1 for failure, and 2 for pending action or deferral. Read the individual results for patch-gap warnings and compatibility outcomes.

Pass browser arguments directly to `app\ChromiumUpdater.exe` for a quiet shortcut invocation with normal daily behavior. It forwards URLs and arguments as individual strings. The launcher only coordinates launches that go through it.

## Coverage and uninstall

Setup backs up the original Desktop and Start Menu shortcuts before changing their targets. Existing arguments, icons, and working directories are preserved. Pinned Chromium, direct `chrome.exe` launches, default HTTP/HTTPS handlers and file associations can bypass the updater. The taskbar can use a separately pinned launcher where Windows offers that action. The native Chromium taskbar pin continues to identify Chromium itself.

Run `.\src\Setup.ps1 -Uninstall` from the checkout, or run the installed `app\Setup.ps1 -Uninstall`. Setup restores the backed-up shortcuts and removes the launcher files. If a shortcut was edited after integration, use the corresponding copy in `shortcut-backups` to restore it manually. Remove any separate updater pin in Windows. The private runtime directory retains configuration, logs and recovery data.

See [browser maintenance and recovery](docs/maintenance.md), [extension maintenance](docs/extensions.md), [security](SECURITY.md), and [development](CONTRIBUTING.md).
