# Browser maintenance and recovery

## Release approval

1. Check the current Windows installer candidate with `Update.ps1 -Stage`. The API must identify the expected official repository, stable tag and architecture-specific asset with its approved URL, size and SHA-256. Review the exact package and its Authenticode status.
2. Compare the candidate with Chrome Releases and the core ungoogled-chromium source release. When the installed profile has Manifest V2 extensions, examine the Windows release's pinned source submodule and patch series. Run the isolated test in [CONTRIBUTING.md](../CONTRIBUTING.md) against the same release and review any other needed MV2 behavior.
3. Approve that specific release in the private `config.json`. Fill `tag` and `sha256` in `browserApproval`. Set `mv2RuntimeVerified` only after actually testing the candidate. For a valid Authenticode signature set `signerSha256` to the approved signing certificate's SHA-256. For an unsigned build, explicit acceptance of the GitHub distribution trust model is required before setting `allowUnsigned` to true.
4. If that Windows build trails broadly served Chrome stable and you choose to install it, set `acceptedStableVersion` to the specific broadly served version whose gap you reviewed. A later upstream stable version requires another review. An approval applies to one tag and installer digest. Leave `acceptedStableVersion` null when it is current.
5. Export uBlock Origin settings through its dashboard as described in [extensions.md](extensions.md). Close all Chromium windows and background instances. Run `Update.ps1 -Apply -NoLaunch` while Chromium is closed. Keep the browser closed during backup and installation. For future validated releases, set `installOnLaunch` to true if you prefer to apply approved builds on a covered launch while Chromium is closed.
6. Read the summary and verify the installed version. Start Chromium, check the existing profiles and extensions, and verify filtering again in the production browser. Browser flags and policies are left to Chromium and the operator.

The updater holds an exclusive per-user file lock across checks, backups, installation and the handoff to Chromium. It stages the official installer, backs up both Application and User Data with Robocopy, verifies the copy, then delegates file and registration changes to the per-user installer. It checks the resulting executable version, architecture, registration and deferred executable. Direct browser launches remain possible during this process. Avoid them while the installer is active.

## Local storage

All paths below are under `%LOCALAPPDATA%\UngoogledChromiumUpdater`.

| Path | Contents |
| --- | --- |
| `app` | Installed launcher and scripts |
| `config.json` | Private browser and extension source configuration |
| `state.json` | Daily status and installed extension version and manifest permission baselines |
| `logs` | Daily local logs, rotated at 512 KiB and retained for up to 30 days after a later check |
| `downloads` | Most recent staged Windows installer, reverified before use |
| `backups` | Two verified browser and profile copies after successful installation |
| `installation.json` | Recovery marker written immediately before starting the installer |
| `shortcut-backups` | Original Desktop and Start Menu shortcuts |

## Recover an interrupted installation

1. Keep Chromium closed. Check that the official installer and its setup process have exited. The launcher blocks its own browser starts while `installation.json` exists.
2. Read the recovery marker and locate its matching backup. Check for `complete.json` in the backup. It records the pre-install browser version. Preserve this copy before any further repair. The backup includes uBlock Origin and extension data even if a separate dashboard export is unavailable.
3. Inspect `chrome.exe` and the registered Chromium version. If installation was incomplete, repair with the same verified or a newer verified official installer while Chromium is closed. Check for `new_chrome.exe`, installer errors, and consistent executable and registered versions. Chromium setup may create `chromium_installer.log` in the Windows temporary directory.
4. After verification, move `installation.json` aside within the private directory. Start through the launcher and verify profiles, extension status and filtering. Keep the recovery marker and backup until validation succeeds.

Restoring an older executable can reintroduce security vulnerabilities and may be incompatible with a migrated profile. If a restore becomes necessary, keep copies of the current state and recover the matching Application and User Data snapshot together, using the same Windows user and the original paths. Check the installer registration and Windows associations before resuming use. The launcher never rolls back automatically.

If a first check repeatedly fails, check the documented source availability, system time, disk space, and access to the private runtime directory. A corrupt `state.json` triggers a fresh check. If an extension reports a new source or permission, check its publisher's release and review the change in Chromium. If you approve an already-installed permission change, remove that extension's baseline entry in `state.json` while the launcher is idle and run `-CheckOnly -VerifyCurrent`.
