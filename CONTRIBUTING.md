# Development

Read [AGENTS.md](AGENTS.md) and [SECURITY.md](SECURITY.md) before making changes. Verify current upstream sources, keep code and documentation in sync, and keep private data outside the repository. Use English and ASCII where practical. Keep dependency and security changes explicit in commits.

Run the automated logic tests in PowerShell 7.5 or newer.

```powershell
.\tests\Test-Updater.ps1
git diff --check
```

The suite uses controlled data and a private temporary directory. Use `Update.ps1 -CheckOnly -VerifyCurrent` for a read-only check against the installed browser and live sources. Document which network and runtime paths you exercised.

For the integrated Windows gate, install current official [7-Zip](https://www.7-zip.org/download.html) in Program Files and run `Update.ps1 -Stage -TestCompatibility` with a configured updater. The command stages the verified installer and exercises its embedded browser payload and the current signed full uBlock Origin CRX. It leaves the installed browser and production profile untouched. Check the explicit compatibility result, workspace cleanup, and the cached-pass message on a second run. A pending patch gap or revision can still yield exit code 2 after a compatibility Pass. For a fresh run, remove `mv2-pass.json` while the updater is idle. Increment the test version in `src/Mv2.ps1` when changes affect the evidence a cached result represents.

For an independent portable diagnostic, download the architecture-matched official Windows portable ZIP and signed full uBlock Origin CRX. Obtain their expected hashes from the official release API and pass them with `-BrowserZip`, `-BrowserSha256`, `-UboCrx`, and `-UboSha256` to `tests\Runtime.ps1`. The shared fixture uses Chromium's documented mute option and a loopback service to test background initialization, blocking, and an allowed request. This diagnostic does not establish installer equivalence. Exercise native signed installation, permission prompts, and update behavior in a separate isolated UI session when needed.

Before committing, check the exact staged files and scan for local paths, credentials, profile information, log output and extension inventories. Keep any environment-specific assessment in private local storage.
