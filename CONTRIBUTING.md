# Development

Read [AGENTS.md](AGENTS.md) and [SECURITY.md](SECURITY.md) before making changes. Verify current upstream sources, keep code and documentation in sync, and keep private data outside the repository. Use English and ASCII where practical. Keep dependency and security changes explicit in commits.

Run the automated logic tests in PowerShell 7.5 or newer.

```powershell
.\tests\Test-Updater.ps1
git diff --check
```

The suite uses controlled data and temporary directories. Use `Update.ps1 -CheckOnly -VerifyCurrent` for an end-to-end read-only check against the installed browser and live sources. Document which network and runtime paths you exercised.

For a release-specific MV2 test, download the architecture-matched official Windows portable ZIP and the official signed uBlock Origin CRX. Verify their expected SHA-256 values through the release API. Supply the paths and expected hashes to `tests\Runtime.ps1` using `-BrowserZip`, `-BrowserSha256`, `-UboCrx`, and `-UboSha256`. The test verifies both files, safely extracts into a disposable directory, launches the tested binary with the documented Chromium mute option, and uses a loopback fixture to verify actual blocking and an allowed request. The unpacked fixture is only for testing. Exercise native signed installation, permission prompts, and update behavior in a separate isolated UI session when needed.

Before committing, check the exact staged files and scan for local paths, credentials, profile information, log output and extension inventories. Keep any environment-specific assessment in private local storage.
