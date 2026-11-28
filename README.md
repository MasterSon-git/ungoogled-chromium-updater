# Ungoogled Chromium Updater

This Windows launcher automatically installs eligible stable builds from the official ungoogled-chromium Windows distribution when Chromium is closed. It verifies the installer, checks Manifest V2 compatibility when needed, and backs up the browser and profiles before installation. It reports the remaining Chrome stable patch gap and hands verified extension updates to Chromium for any native confirmations.

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

Setup builds the small Windows launcher with the Windows .NET Framework C# compiler and installs it under `%LOCALAPPDATA%\UngoogledChromiumUpdater`. Configuration starts with [config.example.json](config.example.json). Select the installed browser architecture (`x64`, `arm64`, or `x86`), browser executable, and user-data directory. The installer workflow supports the registered per-user installation in `%LOCALAPPDATA%\Chromium`. Use `browserArgs` for arguments shared by all launches. Leave it empty for arguments already present on your shortcuts.

To pin the updater, search Start for **Chromium Updater** and right-click the result. Select **Pin to taskbar** (under **More** in the Windows 10 app list). This one-time action adds a separate pin alongside any existing Chromium pin. Both can display the installed Chromium icon. Use **Chromium Updater** to check for updates and open Chromium. [Windows taskbar controls](https://support.microsoft.com/en-us/windows/experience/personalization/customize-the-taskbar-in-windows)

Keep a current, trusted installation of [official 7-Zip](https://www.7-zip.org/download.html) in Program Files for MV2 testing, same-version packaging updates, or initializing a legacy release record. The updater reports its version when it extracts an installer payload. In Automatic mode, launch normally after reviewing `browserTrust`. Choose Manual mode to require an exact tag and SHA-256 approval and an explicit `-Apply`. On upgrade, Setup backs up legacy settings, migrates them to Manual mode, and records the installed packaging revision if it can verify the existing evidence. Review the standing trust policy and select Automatic explicitly when ready. See [browser maintenance](docs/maintenance.md).

Add a verified Chrome Web Store extension's exact ID to `extensions` with the value `"ChromeWebStore"` after checking its official listing and developer identity. See [extension maintenance](docs/extensions.md) for official GitHub channels and migration. The first run reports unapproved sources for review.

### Updater releases

The updater checks this project's GitHub Releases on eligible launches through a shortcut or `app\ChromiumUpdater.exe`. `selfUpdateEnabled` defaults to `true`. `updaterChannel` defaults to `"Stable"`, which accepts stable updater releases. Set it to `"Staging"` to also receive updater prereleases. The updater only installs a higher version, so switching back to Stable may mean waiting for a newer stable release. Self-update replaces the launcher, bootstrap, worker and maintenance code at the existing shortcut target. Chromium and extension channels keep their stable release policies.

Automatic updater releases require a maintainer-approved public signing pin in the installed updater and a publicly accessible release feed. Upgrading to a version with taskbar integration adds the **Chromium Updater** Start menu entry automatically. A failed, deferred or unavailable updater check is reported separately from the browser and extension checks. Set `"selfUpdateEnabled": false` to pause updater self-updates. See [manual installation and recovery](docs/maintenance.md#updater-maintenance-and-recovery) for upgrades from an older installation, verification, and repair.

## Launch and check

Start Chromium from **Chromium Updater**, its taskbar pin, or an integrated Desktop or Start menu shortcut. The first applicable launch on each Windows local day shows a color-coded console. The launcher starts Chromium after the check. A complete check is reused for the rest of the local day. An upstream patch gap is shown as an advisory and keeps that daily schedule. Deferred work retries after 15 minutes, failures after 30 minutes, and items requiring review after two hours. A new day or a forced check bypasses those intervals. Warnings that need your attention stay visible until acknowledged. [Notifications and logs](docs/maintenance.md#notifications-and-logs)

If the updater asks for **Always prompt for install**, enable it in Chromium and relaunch. The next regular updater launch resumes the pending extension handoff even before another check is due. To retry a dismissed Chromium prompt, hold **Shift** while opening **Chromium Updater**, then type **R** and press **Enter** in the console. [Extension handoff and manual fallback](docs/extensions.md#install-a-verified-update)

### Advanced maintenance commands

```powershell
$update = Join-Path $env:LOCALAPPDATA 'UngoogledChromiumUpdater\app\Update.ps1'
& $update -Force
& $update -CheckOnly -VerifyCurrent
& $update -Stage
& $update -Stage -TestCompatibility
& $update -Apply -NoLaunch
& $update -Force -BrowserArguments @('--profile-directory=Default','https://example.com/')
```

`-CheckOnly` verifies extension candidates in memory. `-VerifyCurrent` compares the installed registration and manifest with the signed package for the same version when available. A due launcher check stages exact verified CRXs and automatically opens them in their profiles when Chromium is configured to prompt for installation. Use `-RetryExtensionUpdates` to request native prompts again for pending packages. `-Stage` saves verified candidates for manual installation and verifies the Windows installer for an available update or an unknown installed packaging revision. Add `-TestCompatibility` to run the isolated test with the latest verified stable full uBlock Origin and cache a pass for the exact artifacts. The launcher reports whether each profile has the tested version or still needs an extension update. Other MV2 extensions are outside the test. In `-CheckOnly` and `-Stage`, the installed updater, browser, production profiles, and daily check state stay untouched. The script returns 0 for a completed check, 1 for failure, and 2 for pending action or deferral. [Extension handoff and manual fallback](docs/extensions.md#install-a-verified-update)

Pass browser arguments directly to `app\ChromiumUpdater.exe` for a quiet shortcut invocation with normal daily behavior. It forwards URLs and arguments as individual strings. The launcher only coordinates launches that go through it.

## Coverage and uninstall

`Setup.ps1 -Integrate` backs up the original Desktop and Start menu Chromium shortcuts before changing their targets. Existing arguments, icons, and working directories are preserved. The native Chromium pin and direct `chrome.exe` launches still open Chromium directly. Windows retains existing HTTP/HTTPS handlers and file associations.

First right-click the **Chromium Updater** pin and select **Unpin from taskbar**. Run `app\Setup.ps1 -Uninstall` or run `.\src\Setup.ps1 -Uninstall` from a current trusted checkout. Setup removes its dedicated Start menu entry and launcher files and restores the original integrated shortcuts. An edited or unrelated **Chromium Updater** entry stays in place for you to review. If an integrated Chromium shortcut was edited, use the corresponding copy in `shortcut-backups` to restore it manually. The private runtime directory retains configuration, logs and recovery data.

See [browser maintenance and recovery](docs/maintenance.md), [extension maintenance](docs/extensions.md), [security](SECURITY.md), and [development](CONTRIBUTING.md).

## License

Original project code, scripts, tooling, and documentation use [Zero-Clause BSD (0BSD)](LICENSE). Original creative assets, if added, use [CC0 1.0 Universal (CC0-1.0)](https://creativecommons.org/publicdomain/zero/1.0/). See [third-party notices](THIRD_PARTY_NOTICES.md) for upstream material, tools, and downloads.
