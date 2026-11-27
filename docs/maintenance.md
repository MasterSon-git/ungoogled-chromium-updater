# Updater and browser maintenance

## Updater maintenance and recovery

An existing configuration without updater settings uses Stable and enabled self-updates. Setup and self-updates preserve existing browser and extension settings. Existing installations that predate the self-update launcher need one manual `Setup.ps1 -Install` from a reviewed checkout or a verified package.

The updater checks for a release before browser and extension checks on an eligible launch. A download, signature, or probe failure keeps the current worker active and allows the browser check to continue. Activation uses `updater-active.json` to select a verified worker in `updater-a` or `updater-b`. The previous worker stays on disk. An interrupted attempt before activation leaves the current worker selected. A later attempt replaces abandoned staging data.

If the launcher reports a damaged installation, let any updater checks finish and run `Setup.ps1 -Install` again from a trusted checkout or verified release of the intended version. A manual install resets the activation record and replaces the fixed launcher and its base worker. Review the version before deliberately reverting because an older version can restore an older signing pin. To reinstall from a downloaded updater release, verify the ZIP and its `.sig` using the release tool from a checkout with the independently trusted key, extract it into a new local directory and run its `Setup.ps1 -Install`. [Release verification](releases.md#verify-and-reinstall)

A pending `installation.json` still requires the browser recovery procedure below after an updater reinstall. Leave private configuration, backups and recovery records in place. To pause updater downloads while investigating a release, set `"selfUpdateEnabled": false` in `config.json` while the updater is idle.

## Browser update policy

In `config.json`, `browserUpdateMode` is `Automatic` for new installations. A due launcher check can apply an eligible stable release while Chromium is closed. For Manual mode, set the value to `Manual`, run `Update.ps1 -Stage`, and review the release and Authenticode status. Put the exact `tag` and `sha256` printed by staging in `browserApproval`, then use `Update.ps1 -Apply -NoLaunch` while Chromium is closed. Both modes enforce the same artifact and compatibility checks.

`browserTrust` is the standing distribution policy in both modes. The example accepts unsigned installers from the pinned official Windows release channel with `allowUnsigned: true` and `signerSha256: null`. Review [the distribution trust and signature policy](../SECURITY.md) before accepting that setting. For signed builds, set `signerSha256` to the independently approved certificate's SHA-256. A configured pin requires a matching, valid signature.

Rerun `Setup.ps1 -Install` from the checkout to migrate a configuration with `installOnLaunch`. Setup preserves the original as `config.legacy.json`, moves both legacy launch settings to Manual mode, and carries over the exact tag and hash. Review the new standing trust policy before applying releases. To enable unattended updates on a migrated installation, validate the staged gate with `-Stage -TestCompatibility` and then choose `Automatic`. Previous per-release unsigned acceptance, signer pins, upstream gap acceptance, and manual MV2 attestations expire at migration.

The updater records the complete Windows tag and installer SHA-256 and links the record to a fingerprint of the installed application files. During legacy migration, Setup can initialize a missing record if the legacy log records a successful verified install of the currently published tag, the legacy approval matches its official installer digest and signing policy, and Windows registration and the installed files match the verified payload, including the embedded `setup.exe`. This comparison does not run the installer. Preserve the original logs and legacy configuration until migration is complete.

Chromium version and numeric packaging revision are compared in that order. If installation evidence is missing or inconclusive, or an external repair or state loss leaves the revision unknown, the updater waits for a higher Chromium version. A lower release or a changed artifact for the recorded tag requires review. Chrome Version History is a separate comparison. A remaining patch gap or an unavailable API is reported even when a verified Windows update can be installed.

The updater holds an exclusive per-user file lock across checks, backups, installation and the handoff to Chromium. It stages the official installer, backs up both Application and User Data with Robocopy, verifies the copy, then delegates file and registration changes to the per-user installer. It passes Chromium's documented installer preferences to preserve existing shortcuts during updates. It checks the resulting executable version, architecture, registration and deferred executable. Direct browser launches remain possible during this process. Avoid them while the installer is active.

## Manifest V2 compatibility

Installed Manifest V2 extensions, including disabled entries, trigger the gate. An unreadable extension inventory blocks installation. Entries with unknown Manifest versions also trigger the gate. Same-version packaging updates also verify the installer payload even if the installed extensions are all MV3.

Keep a current, trusted installation of [official 7-Zip](https://www.7-zip.org/download.html) under `Program Files\7-Zip` and allow 2 GiB of free space on the updater drive. The updater reports the local 7-Zip version each time it extracts a payload. The operator maintains 7-Zip separately.

`Update.ps1 -Stage -TestCompatibility` runs the full test on demand. The isolated browser uses unpacked contents from the latest verified stable signed full uBlock Origin package. The test checks background initialization and actual request blocking with an allowed control. The result names the tested version and warns when an installed full uBlock Origin version differs. Other installed MV2 extensions are outside the test. For a production update, when the payload has been extracted, installed files must also match it before the recovery marker is cleared, even if the installer reports success.

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
| `app` | Fixed shortcut launcher, entry scripts and manually installed base worker |
| `updater-active.json` | Atomically selected updater slot and version |
| `updater-a`, `updater-b` | Alternating updater worker directories |
| `updater-work` | Temporary updater package and extraction workspace |
| `config.json` | Private browser and extension source configuration |
| `config.legacy.json` | Original private configuration retained during migration |
| `state.json` | Daily status and installed extension version and manifest permission baselines |
| `browser-release.json` | Last verified Windows release tag, installer digest, architecture and installed application fingerprint |
| `mv2-pass.json` | Latest successful compatibility result and associated artifact identities and file hashes |
| `mv2-work` | Single temporary extraction and profile directory, retained if cleanup needs attention |
| `logs` | Daily local logs, rotated at 512 KiB and retained for up to 30 days after a later check |
| `downloads` | Most recent staged Windows installer, reverified before use |
| `backups` | Two verified browser and profile copies after successful installation |
| `installation.json` | Recovery marker written immediately before starting the installer |
| `shortcut-backups` | Original Desktop and Start Menu shortcuts |

## Recover an interrupted installation

1. Keep Chromium closed. Check that the official installer and its setup process have exited. The launcher blocks its own browser starts while `installation.json` exists.
2. Read the recovery marker and locate its matching backup. Check for `complete.json` in the backup. It records the pre-install browser version. Preserve this copy before any further repair. The backup includes uBlock Origin and extension data even if a separate dashboard export is unavailable.
3. Inspect `chrome.exe` and the registered Chromium version. If installation was incomplete, repair with the same verified or a newer verified official installer while Chromium is closed. Compare the staged installer's tag and SHA-256 with the recovery marker, when available. Check for `new_chrome.exe`, installer errors, and consistent executable and registered versions. Chromium setup may create `chromium_installer.log` in the Windows temporary directory.
4. After verification, move `installation.json` aside within the private directory. Start through the launcher and verify profiles, extension status and filtering. Keep the recovery marker and backup until validation succeeds.

Restoring an older executable can reintroduce security vulnerabilities and may be incompatible with a migrated profile. If a restore becomes necessary, keep copies of the current state and recover the matching Application and User Data snapshot together, using the same Windows user and the original paths. Check the installer registration and Windows associations before resuming use. The launcher never rolls back automatically.

If a first check repeatedly fails, check the documented source availability, system time, disk space, and access to the private runtime directory. A corrupt `state.json` triggers a fresh check. If an extension reports a new source or permission, check its publisher's release and review the change in Chromium. If you approve an already-installed permission change, remove that extension's baseline entry in `state.json` while the launcher is idle and run `-CheckOnly -VerifyCurrent`.
