# Development

Read [AGENTS.md](AGENTS.md) and [SECURITY.md](SECURITY.md) before making changes. Verify current upstream sources, keep code and documentation in sync, and keep private data outside the repository. Use English and ASCII where practical. Keep dependency and security changes explicit in commits.

Run the automated logic tests in PowerShell 7.5 or newer.

```powershell
.\tests\Test-Updater.ps1
.\tests\Test-SelfUpdate.ps1
git diff --check
```

The suite uses controlled data and a private temporary directory. It includes legacy release evidence checks and an installer fixture that exits successfully with a payload mismatch. The launcher must retain recovery, keep the previous release record, and block browser launch in that case. Use `Update.ps1 -CheckOnly -VerifyCurrent` for a read-only check against the installed browser and live sources. Document which network and runtime paths you exercised.

The self-update suite uses a temporary signing key, actual release ZIPs, an isolated Setup installation, and the compiled Windows launcher. It supplies fixture responses at the network boundary and launches a small argument recorder. It checks Stable, Staging, disabled updates, activation failures and recovery without using the installed browser or its profile. See [release procedures](docs/releases.md) for building a selected review commit and validating a staging release.

For the integrated Windows gate, maintain a current, trusted installation of [official 7-Zip](https://www.7-zip.org/download.html) in Program Files and run `Update.ps1 -Stage -TestCompatibility` with a configured updater. The command reports the 7-Zip version, stages the verified installer, and exercises its embedded browser payload and the latest verified stable full uBlock Origin CRX. It leaves the installed browser and production profile untouched. Check the tested-version scope, workspace cleanup, and the cached-pass message on a second run. A pending patch gap or revision can still yield exit code 2 after a compatibility Pass. For a fresh run, remove `mv2-pass.json` while the updater is idle. Increment the test version in `src/Mv2.ps1` when changes affect the evidence a cached result represents.

For an independent portable diagnostic, download the architecture-matched official Windows portable ZIP and signed full uBlock Origin CRX. Obtain their expected hashes from the official release API and pass them with `-BrowserZip`, `-BrowserSha256`, `-UboCrx`, and `-UboSha256` to `tests\Runtime.ps1`. The shared fixture uses Chromium's documented mute option and a loopback service to test background initialization, blocking, and an allowed request. This diagnostic does not establish installer equivalence. Exercise native signed installation, permission prompts, and update behavior in a separate isolated UI session when needed.

By submitting original code, scripts, tooling, or documentation, you agree to license that material under [Zero-Clause BSD (0BSD)](LICENSE). Attribution for original contributions is optional. Dedicate any original creative assets under [CC0 1.0 Universal (CC0-1.0)](https://creativecommons.org/publicdomain/zero/1.0/) and include its legal text with the first such asset.

Before adding third-party code or assets, verify their source and applicable terms. Preserve the applicable copyright and license text, and record the source, affected files, and applicable terms in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Before committing, check the exact staged files and scan for local paths, credentials, profile information, log output and extension inventories. Keep any environment-specific assessment in private local storage. Select and review distribution package contents explicitly.
