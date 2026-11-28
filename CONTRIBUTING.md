# Development

Read [AGENTS.md](AGENTS.md) and [SECURITY.md](SECURITY.md) before making changes. Verify current upstream sources, keep code and documentation in sync, and keep private data outside the repository. Use English and ASCII where practical. Keep dependency and security changes explicit in commits.

Run the same static checks and Windows suites used by CI in PowerShell 7.5 or newer.

```powershell
.\tools\Test-Project.ps1
git diff --check
```

With [GitHub CLI](https://cli.github.com/) on `PATH`, use `Test-Project.ps1 -ReleaseCli` to include the publication regression. Windows CI and the unsigned release build run it by default. The test checks multiline notes from an isolated annotated tag and runs the real CLI with a missing notes file so it stops after argument validation and before HTTP.

The suite uses controlled data and a private temporary directory. Backup tests use real Robocopy and inject same-size changes with matching timestamps, read failures, and unsafe cleanup paths. They check scoped recovery hashes, rotation of completed copies, installer blocking, and verification while a recovery marker is present. The suite also checks the distinction between advisory-only daily checks and retryable work, as well as component inventory changes after browser startup.

The installer fixture that exits successfully with a payload mismatch must retain recovery, keep the previous release record, and block browser launch. Use `Update.ps1 -CheckOnly -VerifyCurrent` for a read-only check against the installed browser and live sources. Document which network and runtime paths you exercised.

Extension cases cover approved source mismatches, staged CRX integrity, script scope reassignment and removed restrictions, disabled entries, post-install and startup inventory changes, and per-profile uBlock Origin reconciliation. To exercise a genuine signed update, use a separately verified official Windows portable build and a disposable profile. With approval for the visible native prompt, install an older verified signed fixture through Chromium, record its ID and version, set a harmless storage value, and disable the extension. Stage the newer signed package and open that CRX through Chromium in the same disposable profile. Confirm the new version under the same ID and verify the disabled state and stored value. Keep browser output captured and the isolated browser muted. The full uBlock Origin 1.77.2 to 1.77.4 upgrade on Windows x64 158.0.8127.88-1.1 exercised this path. The permission-increase prompt and signed in-place Store and Chromium Web Store helper updates are separate runtime scenarios.

For the launcher handoff, use two disposable profiles with an older signed extension and **Always prompt for install** enabled. Confirm that each profile gets its own Chromium prompt. Accept one prompt, decline the other, and check the installed versions independently. A repeated launcher check should leave the declined package pending without a second prompt. Hold **Shift** while opening **Chromium Updater** and choose **R** to retry it. An explicit `-RetryExtensionUpdates` is available for diagnostics. The Windows suite uses fixtures to exercise batching, profile scope, early retry after a settings change, process creation failure, and staged-file changes. A compiled recorder verifies the original browser arguments and working directory at process startup.

The self-update suite uses a temporary signing key, actual release ZIPs, an isolated Setup installation, and the compiled Windows launcher. It supplies fixture responses at the network boundary and launches a small argument recorder. It tests a changed launcher and bootstrap, an added manifest file used by the installed maintenance command, and verified manual recovery after a hard interruption between the app directory renames. Record the actual GitHub CI result separately from local validation. See [release procedures](docs/releases.md) for the signing approval gate and live staging validation.

For the integrated Windows gate, maintain a current, trusted installation of [official 7-Zip](https://www.7-zip.org/download.html) in Program Files and run `Update.ps1 -Stage -TestCompatibility` with a configured updater. The command reports the 7-Zip version, stages the verified installer, and exercises its embedded browser payload and the latest verified stable full uBlock Origin CRX. It leaves the installed browser and production profile untouched. Check the tested-version scope, workspace cleanup, and the cached-pass message on a second run. A staged or unknown Windows revision can still yield exit code 2 after a compatibility Pass. For a fresh run, remove `mv2-pass.json` while the updater is idle. Increment the test version in `src/Mv2.ps1` when changes affect the evidence a cached result represents.

For an independent portable diagnostic, download the architecture-matched official Windows portable ZIP and signed full uBlock Origin CRX. Obtain their expected hashes from the official release API and pass them with `-BrowserZip`, `-BrowserSha256`, `-UboCrx`, and `-UboSha256` to `tests\Runtime.ps1`. The shared fixture uses Chromium's documented mute option and a loopback service to test background initialization, blocking, and an allowed request. This diagnostic does not establish installer equivalence. Exercise native signed installation, permission prompts, and update behavior in a separate isolated UI session when needed.

By submitting original code, scripts, tooling, or documentation, you agree to license that material under [Zero-Clause BSD (0BSD)](LICENSE). Attribution for original contributions is optional. Dedicate any original creative assets under [CC0 1.0 Universal (CC0-1.0)](https://creativecommons.org/publicdomain/zero/1.0/) and include its legal text with the first such asset.

Before adding third-party code or assets, verify their source and applicable terms. Preserve the applicable copyright and license text, and record the source, affected files, and applicable terms in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Before committing, check the exact staged files and scan for local paths, credentials, profile information, log output and extension inventories. Keep any environment-specific assessment in private local storage. Select and review distribution package contents explicitly.
