# Ungoogled Chromium Updater

This Windows launcher checks the official ungoogled-chromium Windows release, compares its version with broadly served Google Chrome stable, and audits installed extension update channels. It can run the official per-user browser installer after release approval and a closed-browser backup. Extension installation uses Chromium's prompts.

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

Add a verified Chrome Web Store extension's exact ID to `extensions` with the value `"ChromeWebStore"` after checking its official listing and developer identity. See [extension maintenance](docs/extensions.md) for official GitHub channels and migration. The first run reports unapproved sources for review.

## Launch and check

Start Chromium from an integrated Desktop or Start Menu shortcut. The first applicable launch on each Windows local day shows a color-coded console. The launcher starts Chromium after the check. A complete check is reused for the rest of the local day. Deferred work retries after 15 minutes, failures after 30 minutes, and items requiring review after two hours. A new day or a forced check bypasses those intervals. A warning or error stays visible until acknowledged.

```powershell
$update = Join-Path $env:LOCALAPPDATA 'UngoogledChromiumUpdater\app\Update.ps1'
& $update -Force
& $update -CheckOnly -VerifyCurrent
& $update -Stage
& $update -Apply -NoLaunch
& $update -Force -BrowserArguments @('--profile-directory=Default','https://example.com/')
```

`-CheckOnly` checks release metadata and, where needed, verifies extension packages in memory. `-VerifyCurrent` also checks signed packages for the same installed version. `-Stage` additionally downloads and verifies the current Windows installer when an update is available. These two modes keep the daily state and browser untouched. The script returns 0 for a completed check, 1 for failure, and 2 for pending action or deferral.

Pass browser arguments directly to `app\ChromiumUpdater.exe` for a quiet shortcut invocation with normal daily behavior. It forwards URLs and arguments as individual strings. The launcher only coordinates launches that go through it.

## Coverage and uninstall

Setup backs up the original Desktop and Start Menu shortcuts before changing their targets. Existing arguments, icons, and working directories are preserved. Pinned Chromium, direct `chrome.exe` launches, default HTTP/HTTPS handlers and file associations can bypass the updater. The taskbar can use a separately pinned launcher where Windows offers that action. The native Chromium taskbar pin continues to identify Chromium itself.

Run `.\src\Setup.ps1 -Uninstall` from the checkout, or run the installed `app\Setup.ps1 -Uninstall`. Setup restores the backed-up shortcuts and removes the launcher files. If a shortcut was edited after integration, use the corresponding copy in `shortcut-backups` to restore it manually. Remove any separate updater pin in Windows. The private runtime directory retains configuration, logs and recovery data.

See [browser maintenance and recovery](docs/maintenance.md), [extension maintenance](docs/extensions.md), [security](SECURITY.md), and [development](CONTRIBUTING.md).
