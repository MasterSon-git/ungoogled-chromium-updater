# Working instructions

- Read the existing implementation and documentation before changing either.
- Verify current upstream behavior against authoritative sources and, where necessary, the released Windows binaries.
- Preserve user data, browser and extension identity, disabled states, and native integrity and permission checks. Never weaken security requirements for convenience.
- Keep changes focused. Prefer supported mechanisms and avoid unnecessary dependencies.
- Run the automated checks and static validation relevant to the change. Perform focused isolated runtime validation when needed.
- Run local tests with hidden windows, captured output, and no interactive prompts. Ask before launching a test that requires a visible window.
- Before every game-engine test launch, verify silence through a supported option or an isolated profile with master volume and every audio category set to zero. Skip the test and report the gap if silence cannot be established.
- Never terminate Chromium. Ask the user to close it manually before operations that require exclusive access, then verify that relevant processes have exited.
- Document security decisions and update affected documentation in the same change.
- Never commit machine configuration, private extension inventories, credentials, logs, backups, browser data, or downloads.
- Submit original code, scripts, tooling, and documentation under 0BSD. Use CC0-1.0 for original creative assets and include its legal text if assets are added.
- Check the source and terms of third-party material before including it. Preserve required notices and record provenance in THIRD_PARTY_NOTICES.md.
- Review the exact staged files for private material. Keep publication assessments in private storage.
- Follow the reviewed-tag and protected environment procedures in [docs/releases.md](docs/releases.md). Release tags, signing secrets, publication, public visibility changes, and production self-update activation require maintainer approval.
- Validate launcher self-updates in a separate installation with test data. Use test-only keys for fixture releases and the approved public pin for authorized live staging validation. Keep production shortcuts, configuration, and profile untouched.
- Write project materials in English and use ASCII where practical. Report failures, unverified behavior and unresolved security concerns.
