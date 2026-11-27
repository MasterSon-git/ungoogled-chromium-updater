# Ungoogled Chromium Updater

This Windows launcher automatically installs eligible stable builds from the official ungoogled-chromium Windows distribution when Chromium is closed. It verifies the installer, checks Manifest V2 compatibility when needed, and backs up the browser and profiles before installation. It reports the remaining Chrome stable patch gap and audits installed extension update channels. Extension installation uses Chromium's prompts.

Ungoogled Chromium Updater is an independent, unofficial project. It has no affiliation with or endorsement from Chromium, the ungoogled-chromium projects, uBlock Origin, or the other upstream publishers it references.

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

Keep a current, trusted installation of [official 7-Zip](https://www.7-zip.org/download.html) in Program Files for MV2 testing, same-version packaging updates, or initializing a legacy release record. The updater reports its version when it extracts an installer payload. In Automatic mode, launch normally after reviewing `browserTrust`. Choose Manual mode to require an exact tag and SHA-256 approval and an explicit `-Apply`. On upgrade, Setup backs up legacy settings, migrates them to Manual mode, and records the installed packaging revision if it can verify the existing evidence. Review the standing trust policy and select Automatic explicitly when ready. See [browser maintenance](docs/maintenance.md).

Add a verified Chrome Web Store extension's exact ID to `extensions` with the value `"ChromeWebStore"` after checking its official listing and developer identity. See [extension maintenance](docs/extensions.md) for official GitHub channels and migration. The first run reports unapproved sources for review.

### Updater releases

The updater checks this project's GitHub Releases on eligible launches through a shortcut or `app\ChromiumUpdater.exe`. `selfUpdateEnabled` defaults to `true`. `updaterChannel` defaults to `"Stable"`, which accepts stable updater releases. Set it to `"Staging"` to also receive updater prereleases. The updater only installs a higher version, so switching back to Stable may mean waiting for a newer stable release. Self-update replaces the launcher, bootstrap, worker and maintenance code at the existing shortcut target. Chromium and extension channels keep their stable release policies.

Automatic updater releases require a maintainer-approved public signing pin in the installed updater and a publicly accessible release feed. A failed, deferred or unavailable updater check is reported separately from the browser and extension checks. Set `"selfUpdateEnabled": false` to pause updater self-updates. See [manual installation and recovery](docs/maintenance.md#updater-maintenance-and-recovery) for upgrades from an older installation, verification, and repair.

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

`-CheckOnly` checks release metadata and, where needed, verifies extension packages in memory. `-VerifyCurrent` also checks signed packages for the same installed version. `-Stage` stages and verifies the installer for an available update or an unknown installed packaging revision. Add `-TestCompatibility` to run the isolated test with the latest verified stable full uBlock Origin and cache a pass for the exact artifacts. The result identifies the tested version and warns if an installed full uBlock Origin version differs. Other MV2 extensions are outside the test. In `-CheckOnly` and `-Stage`, the installed updater, browser, production profiles, and daily check state stay untouched. The script returns 0 for a completed check, 1 for failure, and 2 for pending action or deferral. Read the individual results for patch-gap warnings and compatibility outcomes.

Pass browser arguments directly to `app\ChromiumUpdater.exe` for a quiet shortcut invocation with normal daily behavior. It forwards URLs and arguments as individual strings. The launcher only coordinates launches that go through it.

## Coverage and uninstall

Setup backs up the original Desktop and Start Menu shortcuts before changing their targets. Existing arguments, icons, and working directories are preserved. Pinned Chromium, direct `chrome.exe` launches, default HTTP/HTTPS handlers and file associations can bypass the updater. The taskbar can use a separately pinned launcher where Windows offers that action. The native Chromium taskbar pin continues to identify Chromium itself.

Run `app\Setup.ps1 -Uninstall` to use the installed version's maintenance code. You can also use `.\src\Setup.ps1 -Uninstall` from a current trusted checkout. Setup restores the backed-up shortcuts and removes the launcher files. If a shortcut was edited after integration, use the corresponding copy in `shortcut-backups` to restore it manually. Remove any separate updater pin in Windows. The private runtime directory retains configuration, logs and recovery data.

See [browser maintenance and recovery](docs/maintenance.md), [extension maintenance](docs/extensions.md), [security](SECURITY.md), and [development](CONTRIBUTING.md).

## License

Original project code, scripts, tooling, and documentation use [Zero-Clause BSD (0BSD)](LICENSE). Original creative assets, if added, use [CC0 1.0 Universal (CC0-1.0)](https://creativecommons.org/publicdomain/zero/1.0/). See [third-party notices](THIRD_PARTY_NOTICES.md) for upstream material, tools, and downloads.
