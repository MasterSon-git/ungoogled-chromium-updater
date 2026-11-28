# Updater and browser maintenance

## Updater maintenance and recovery

An existing configuration without updater settings uses Stable and enabled self-updates. Setup and self-updates preserve existing browser and extension settings. Existing installations that predate the self-update launcher need one manual `Setup.ps1 -Install` from a reviewed checkout or a verified package.

The updater checks for a release before browser and extension checks on an eligible EXE launch. The downloaded package is verified and the replacement launcher is compiled in staging. A separate handoff waits for the initiating updater worker and the installed launcher to exit, then replaces the app directory at the same shortcut target. The new app carries the slot selector and the updated bootstrap and Setup scripts. The handoff resumes with the original browser arguments and working directory and performs a single browser check.

A download, signature, or probe failure keeps the current app and worker active and allows the browser check to continue. The console and daily state report updater failure, deferral or unavailability separately. When the browser and extension checks complete, an updater warning leaves their normal once-a-day schedule in place. The previous app and worker are kept after an update. An interrupted attempt before the directory swap leaves the current app available. The next eligible attempt can replace abandoned staging data.

If the launcher reports a damaged installation or the shortcut target is missing after an interruption, let updater operations finish and run `Setup.ps1 -Install` from a trusted checkout or verified release of the intended version. A manual install resets the selector and replaces the fixed launcher and its base worker. Review the version before deliberately reverting because an older version can restore an older signing pin. For a downloaded release, verify the ZIP and its `.sig` using the release tool with the independently trusted public pin, extract into a new local directory and invoke Setup there. [Release verification](releases.md#verify-and-reinstall)

A hard interruption between the two app directory renames can leave `app` missing, the prior installation in `updater-previous-app`, and the candidate in `updater-work\next-app`. Preserve the prior app and use the verified manual installation procedure to restore the shortcut target. The Windows test suite exercises this interruption and checks the prior app, configuration and pending browser recovery marker through recovery.

A pending `installation.json` still requires the browser recovery procedure below after an updater reinstall. Leave private configuration, backups and recovery records in place. To pause updater downloads while investigating a release, set `"selfUpdateEnabled": false` in `config.json` while the updater is idle.

## Start menu shortcut and taskbar pin

Setup and a successful self-update create **Chromium Updater** in the per-user Start menu. The shortcut targets the stable `app\ChromiumUpdater.exe` and uses the same AppUserModelID as the launcher. Its icon location refers to index 0 in the locally configured `chrome.exe`. Chromium retains its own identity when it opens, so its windows can appear under the native Chromium pin. Windows handles pinning and unpinning through the user's taskbar actions. [Windows application identity](https://learn.microsoft.com/en-us/windows/win32/shell/appids)

Rerun `app\Setup.ps1 -Integrate` to retry shortcut creation or refresh the icon reference after changing `browserPath`. A repeated setup keeps an up-to-date entry as it is. If the Start menu location moved or a same-named shortcut is unowned or edited, review the entry before retrying. Unpin **Chromium Updater** manually when uninstalling. Setup removes its unchanged dedicated entry and separately restores the backed-up Chromium shortcuts. A `-TestInstall` fixture stores its dedicated shortcut under `test-programs` in the isolated runtime instead of the Windows Start menu.

## Browser update policy

In `config.json`, `browserUpdateMode` is `Automatic` for new installations. A due launcher check can apply an eligible stable release while Chromium is closed. For Manual mode, set the value to `Manual`, run `Update.ps1 -Stage`, and review the release and Authenticode status. Put the exact `tag` and `sha256` printed by staging in `browserApproval`, then use `Update.ps1 -Apply -NoLaunch` while Chromium is closed. Both modes enforce the same artifact and compatibility checks.

`browserTrust` is the standing distribution policy in both modes. The example accepts unsigned installers from the pinned official Windows release channel with `allowUnsigned: true` and `signerSha256: null`. Review [the distribution trust and signature policy](../SECURITY.md) before accepting that setting. For signed builds, set `signerSha256` to the independently approved certificate's SHA-256. A configured pin requires a matching, valid signature.

Rerun `Setup.ps1 -Install` from the checkout to migrate a configuration with `installOnLaunch`. Setup preserves the original as `config.legacy.json`, moves both legacy launch settings to Manual mode, and carries over the exact tag and hash. Review the new standing trust policy before applying releases. To enable unattended updates on a migrated installation, validate the staged gate with `-Stage -TestCompatibility` and then choose `Automatic`. Previous per-release unsigned acceptance, signer pins, upstream gap acceptance, and manual MV2 attestations expire at migration.

The updater records the complete Windows tag and installer SHA-256 and links the record to a fingerprint of the installed application files. During legacy migration, Setup can initialize a missing record if the legacy log records a successful verified install of the currently published tag, the legacy approval matches its official installer digest and signing policy, and Windows registration and the installed files match the verified payload, including the embedded `setup.exe`. This comparison does not run the installer. Preserve the original logs and legacy configuration until migration is complete.

Chromium version and numeric packaging revision are compared in that order. If installation evidence is missing or inconclusive, or an external repair or state loss leaves the revision unknown, the updater waits for a higher Chromium version. A lower release or a changed artifact for the recorded tag requires review.

The updater holds an exclusive per-user file lock across checks, backups, installation and the handoff to Chromium. It stages the official installer, verifies a closed-browser backup, then delegates file and registration changes to the per-user installer. It passes Chromium's documented installer preferences to preserve existing shortcuts during updates. It checks the resulting executable version, architecture, registration and deferred executable. Direct browser launches remain possible during this process. Keep Chromium closed until copying, verification and installation finish.

## Backup verification

Robocopy copies the full Application and User Data trees and checks them in list mode for differences it can observe in paths and file metadata. The updater also records SHA-256 hashes from the closed source before copying. After copying, it compares both the backup and the source with that record. Any copy error, missing or changed file in scope, hash read error, or observed browser restart prevents installation. The logs report the result and number of hashed files.

The `sha256-v1` scope covers the primary contents of these files when present.

- Every file under Application, including the browser binaries, installer and assets.
- User Data's `Local State`. For each top-level profile directory, `Preferences`, `Secure Preferences`, `Bookmarks`, `Bookmarks.bak`, and the legacy `Current` and `Last` session and tab files.
- Each profile's `History`, `Login Data`, `Login Data For Account`, `Web Data`, `Account Web Data`, and `Cookies` databases, including `Network\Cookies` and present SQLite journals, WAL and shared-memory files for those databases.
- Each profile's `Sessions`, `Extensions`, `Extension State`, `Extension Rules`, `Extension Scripts`, `Local Extension Settings`, `Sync Extension Settings`, and `Managed Extension Settings` trees.

Other profile files, including caches, IndexedDB and website storage, receive the full-tree Robocopy comparison. The scoped hashes keep the cost of multiple reads independent of those potentially large trees. [Robocopy options](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/robocopy) [Chromium preferences](https://chromium.googlesource.com/chromium/src/+/HEAD/chrome/browser/prefs/) [Chromium extension storage names](https://chromium.googlesource.com/chromium/src/+/HEAD/extensions/common/constants.h)

The updater builds one `backups\incomplete` copy and promotes it to a completed snapshot only after verification. Allow disk space for a temporary full copy alongside the completed snapshots. The completion record contains the browser version, timestamp and scoped hashes. A failed copy leaves the previous completed snapshots available. The updater normally retains two completed snapshots and removes abandoned managed copies before a later backup. If pruning fails after promotion, the newly verified snapshot remains usable and the next attempt must clean up safely before allocating another copy. The launcher preserves backups while `installation.json` is present. If cleanup needs attention, open the private backup folder in File Explorer while the updater is idle and check for files held open or a redirected path. Preserve completed copies and recovery records.

## Notifications and logs

The first daily updater check shows the Windows release decision, compatibility and extension results, and the comparison with broadly served Chrome Stable. A remaining patch gap and an unavailable Chrome Version History comparison are advisories. Both appear in the console and log on any check that evaluates them. A later daily check reports the current comparison. Advisories alone use the completed daily schedule and allow an otherwise eligible Windows update.

Genuine review items retry after two hours, deferrals after 15 minutes, and failures after 30 minutes. Recovery and unresolved compatibility problems remain visible. Pending extension handoffs can resume on the next regular launch after their Chromium setting is fixed. Self-update outcomes are recorded separately. Additions, changes and removals of browser-managed component registrations are informational inventory changes. [Extension handoff](extensions.md#install-a-verified-update)

## Manifest V2 compatibility

Installed Manifest V2 extensions, including disabled entries, trigger the gate. An unreadable extension inventory blocks installation. Entries with unknown Manifest versions also trigger the gate. Same-version packaging updates also verify the installer payload even if the installed extensions are all MV3.

Keep a current, trusted installation of [official 7-Zip](https://www.7-zip.org/download.html) under `Program Files\7-Zip` and allow 2 GiB of free space on the updater drive. The updater reports the local 7-Zip version each time it extracts a payload. The operator maintains 7-Zip separately.

`Update.ps1 -Stage -TestCompatibility` runs the full test on demand. The isolated browser uses unpacked contents from the latest verified stable signed full uBlock Origin package. The test checks background initialization and actual request blocking with an allowed control. The result names the tested version and warns when an installed full uBlock Origin version differs. Other installed MV2 extensions are outside the test. For a production update, when the payload has been extracted, installed files must also match it before the recovery marker is cleared, even if the installer reports success.

After a successful gated browser installation, the launcher records the full uBlock Origin version and CRX hash that passed against the installed browser record. It rereads the profiles and stages the verified extension update where needed. It reports a matching installed combination only when the observed extension ID, version and signed manifest evidence match that result. A disabled copy stays disabled. A legacy ID, older version or unverifiable copy remains explicitly unverified. A pending extension action does not block an otherwise eligible security update after the gate passes. If the channel advances after a gate run, the launcher checks its current release without retrieving historical packages. [Extension installation procedure](extensions.md#install-a-verified-update)

- **Pass** allows an otherwise eligible release. The result applies to the exact installer and signed uBlock Origin artifacts and the current test version.
- **Incompatible** means the MV2 background or filtering did not work during the test.
- **Inconclusive** means a supported payload could not be established or the test could not establish an MV2 result.
- **Operational failure** covers verification errors, timeout, missing resources, or cleanup failure.

For a result other than Pass, follow the launcher message and rerun staging after correcting the problem. If `mv2-work` remains, close any isolated Chromium instance running from that directory manually, verify the test processes have exited, and remove that workspace while the updater is idle. The test uses a disposable profile under that directory. A Pass covers this unpacked fixture. Independently verify native signed installation and the extensions and permissions you rely on in an isolated Windows environment if needed.

For an exceptional release decision, use Manual mode to pause unattended installation. Review the Windows packaging release, the Chromium patch gap, and the tested extensions. If needed, validate the exact staged installer and native signed extensions in a disposable Windows environment. If you decide to proceed outside the updater, verify the artifact and signature again, close Chromium manually, back up the application and full profile, and run the official installer yourself. Verify the installed version and profile behavior afterward. The launcher has no override for an unsuccessful gate and treats an externally installed packaging revision as unknown if its fingerprint has changed. Full uBlock Origin and other installed extensions stay under Chromium's control.

## Local storage

All paths below are under `%LOCALAPPDATA%\UngoogledChromiumUpdater`.

| Path | Contents |
| --- | --- |
| `app` | Stable shortcut path with the active launcher and maintenance entry points |
| `app/updater-slot.json` | Slot and version installed with the replacement app |
| `updater-a`, `updater-b` | Alternating updater worker directories |
| `updater-work` | Temporary package, replacement app and handoff plan |
| `updater-previous-app` | Previous launcher and entry scripts retained after a swap |
| `config.json` | Private browser and extension source configuration |
| `config.legacy.json` | Original private configuration retained during migration |
| `state.json` | Daily check status, separate updater and upstream comparison outcomes, per-profile extension observations and permission baselines, CRX handoff state, and pending startup reconciliation |
| `browser-release.json` | Last verified Windows release tag, installer digest, architecture, installed application fingerprint and applicable full uBlock Origin test evidence |
| `mv2-pass.json` | Latest successful compatibility result and associated artifact identities and file hashes |
| `mv2-work` | Single temporary extraction and profile directory, retained if cleanup needs attention |
| `logs` | Daily local logs, rotated at 512 KiB and retained for up to 30 days after a later check |
| `downloads` | Most recent staged Windows installer, reverified before use |
| `extension-packages` | Private cache of verified signed CRX candidates awaiting native installation |
| `backups` | Two completed Application and User Data snapshots under normal retention, plus a reusable incomplete workspace during backup |
| `installation.json` | Recovery marker written immediately before starting the installer |
| `shortcut-backups` | Original Desktop and Start Menu shortcuts |
| `updater-shortcut.json` | Dedicated shortcut path, icon source and ownership hashes |

## Recover an interrupted installation

1. Keep Chromium closed. Check that the official installer and its setup process have exited. The launcher blocks its own browser starts while `installation.json` exists.
2. Read the recovery marker and locate its matching backup. Check `complete.json` for the pre-install browser version and verification scope. Preserve the matching backup before any repair. For a backup with `HashScope` set to `sha256-v1`, use the read-only verification command below. If verification fails, preserve the copy for diagnosis and inspect another completed backup before relying on it. Older backups carry the earlier Robocopy evidence and remain available for manual recovery.
3. Inspect `chrome.exe` and the registered Chromium version. If installation was incomplete, repair with the same verified or a newer verified official installer while Chromium is closed. Compare the staged installer's tag and SHA-256 with the recovery marker, when available. Check for `new_chrome.exe`, installer errors, and consistent executable and registered versions. Chromium setup may create `chromium_installer.log` in the Windows temporary directory.
4. After verification, move `installation.json` aside within the private directory. Start through the launcher and verify profiles, extension status and filtering. Keep the recovery marker and backup until validation succeeds.

Use this advanced maintenance command to recheck the backup referenced by the recovery marker. It reports the scoped SHA-256 result and leaves the marker in place.

```powershell
$updater = Join-Path $env:LOCALAPPDATA 'UngoogledChromiumUpdater'
$marker = Get-Content -LiteralPath (Join-Path $updater 'installation.json') -Raw | ConvertFrom-Json
& (Join-Path $updater 'app\Update.ps1') -VerifyBackup $marker.Backup
```

The command returns 0 when the saved scope matches, 1 when verification fails, and 2 for a legacy backup that has no saved hashes. It verifies the backup on disk without launching Chromium or restoring files.

Restoring an older executable can reintroduce security vulnerabilities and may be incompatible with a migrated profile. If a restore becomes necessary, keep copies of the current state and recover the matching Application and User Data snapshot together, using the same Windows user and the original paths. Check the installer registration and Windows associations before resuming use. The launcher never rolls back automatically.

If a first check repeatedly fails, check the documented source availability, system time, disk space, and access to the private runtime directory. A corrupt `state.json` triggers a fresh check. If an extension reports a new source or permission, check its publisher's release and review the change in Chromium. If you approve an already-installed permission change, remove that extension's baseline entry in `state.json` while the launcher is idle and run `-CheckOnly -VerifyCurrent`.
