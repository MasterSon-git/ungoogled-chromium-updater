# Updater release procedure

Use [Semantic Versioning 2.0.0](https://semver.org/) for the updater. Bump the patch version for compatible fixes, the minor version for compatible features, and the major version for breaking changes to configuration, installation, or documented command interfaces. Put the exact version in `src/Updater.version`. Tag the independently reviewed commit `vMAJOR.MINOR.PATCH` or use a prerelease tag such as `v0.2.0-rc.1`. Increment the prerelease identifier for each candidate. Build metadata is reserved. Publish the final version under its own stable tag.

Stable accepts stable tags. Staging also accepts prerelease tags. The client selects the highest eligible version strictly above the installed version from the latest 100 releases. Chromium and extensions use their existing stable channels.

## Repository settings

Set these before the first authorized release.

1. Protect `main` with required pull requests and the **Windows validation** check from CI. Independently review the exact commit, including the release workflow, signing tools and full action SHA changes, before selecting it for release.
2. Add active tag rulesets for `v*`. Restrict tag creation to the authorized release maintainer using the narrowest available bypass role. Use a separate ruleset to restrict updates and deletions without a routine release bypass. A release tag selects a permanent source commit. Keep the default Actions token read-only in repository settings. The publication job explicitly requests its write permission.
3. Create the `release-signing` environment under **Settings > Environments**. Add the release maintainer as a required reviewer. Leave **Prevent self-review** off for this single-maintainer repository, disable administrator bypass of protection rules, and choose **Selected branches and tags**. Add a tag rule for `v*` and remove branch deployment rules. Keep `UPDATER_SIGNING_KEY` exclusively in that environment as an Environment Secret. Verify the approval gate with the reviewed workflow before relying on it. Required reviewer controls are plan and visibility dependent. Public GitHub repositories support this configuration on current plans. Obtain the necessary plan or separately approved visibility before configuring a secret if the current repository lacks the controls. [GitHub environment settings](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments)
4. Enable immutable releases under repository settings and confirm the setting before approving signing. The publish job checks the published release's immutable status using its contents-scoped token. The updater requires that status as well. A published immutable prerelease has locked assets and a fixed tag even though its GitHub prerelease flag remains editable. The client requires that flag to agree with the signed SemVer tag. [GitHub immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)

GitHub Releases is the only client distribution source. Anonymous delivery requires a public repository and a published release. Repository visibility, production bootstrap and publication each require maintainer authorization.

## Bootstrap signing

The reviewed `0.1.0` bootstrap at `65285a9` contains the production public pin. Use the following provisioning steps for a new key only after separate maintainer approval.

1. On a trusted Windows workstation, generate an RSA key with 3072 or 4096 bits. Use PowerShell and .NET's `RSA.Create(3072)` or `RSA.Create(4096)`. Obtain the SubjectPublicKeyInfo PEM with `ExportSubjectPublicKeyInfoPem()` and record the SHA-256 of the DER bytes from `ExportSubjectPublicKeyInfo()` through a trusted administrative channel.
2. Add only the public PEM to `src/ReleaseTrust.ps1` in a reviewed PR. Compare its DER SHA-256 against the recorded fingerprint independently of the GitHub upload. A second human review is welcome when available. The maintainer can compare a fresh export from the same key and verify a local signing challenge before discarding the private bytes.
3. After verifying the environment settings, import the base64 of the private key's unencrypted PKCS#8 DER into the Environment Secret. Use the GitHub CLI's standard input from a trusted shell with transcription and diagnostic tracing off, or the protected web UI. In PowerShell, the export and import can share a process without writing the key to disk or putting it in command arguments.

   ```powershell
   $privateBytes = $rsa.ExportPkcs8PrivateKey()
   try {
       [Convert]::ToBase64String($privateBytes) |
           gh secret set UPDATER_SIGNING_KEY --env release-signing --repo MasterSon-git/ungoogled-chromium-updater
       if ($LASTEXITCODE) { throw 'Could not import the environment signing key.' }
   } finally {
       [Array]::Clear($privateBytes)
       $rsa.Dispose()
   }
   ```

4. If recovery of the same key is needed, retain an encrypted backup in the maintainer's approved private storage with separately protected recovery credentials. Test decryption and fingerprint comparison before relying on it. GitHub Secrets cannot serve as a retrievable backup. With or without a backup, provision new installations using a reviewed checkout and independently verified public pin.

For planned rotation, publish a higher bridge version with the new public pin in `UpdaterReleasePublicKey` and the old public pin in `UpdaterBridgeSigningPublicKey`. Keep the old environment secret for that release. The client trusts its installed key when verifying the bridge. The CI bridge pin controls signature verification in the release jobs only. Publish stable and prerelease bridges as needed for eligible clients. Then replace the environment secret with the new key and clear the bridge pin in the next reviewed release. Clients that miss the bridge can install a verified bridge using the old trusted pin or install a reviewed new bootstrap. For key loss without a backup or key compromise, suspend signing and publication, notify affected installations through a trusted channel, and distribute a reviewed manual bootstrap with a replacement pin. [Threat model](../SECURITY.md#updater-self-update)

## Build, approve, and publish

1. Select the exact independently reviewed commit reachable from `origin/main` with passing Windows CI. Confirm the version and intended channel. For an unsigned local check, fetch `main` and run:

   ```powershell
   git fetch origin main
   .\tools\Release.ps1 -Commit $reviewedCommit -OutputDirectory $outputDirectory
   ```

2. After authorization, create an annotated tag matching that commit's version file. Write English release notes in the annotation and push only the selected tag.

   ```powershell
   git tag -a $releaseTag $reviewedCommit
   git push origin "refs/tags/$releaseTag"
   ```

3. Open the tag workflow run. Confirm that the tag points at the selected reviewed commit, both Windows suites passed, and the two unsigned builds matched. Review the ZIP SHA-256 and artifact contents before approving **Sign approved release** in the `release-signing` environment. Cancel the run if any verification or settings differ from the reviewed configuration.
4. The signing job downloads the tested artifact by ID and matches the build's SHA-256 before signing. It produces only the detached signature artifact. The publication job downloads both artifacts from the same run, verifies the expected ZIP hash and signature and derives prerelease status from the version. It publishes the two assets on the existing tag after signing succeeds. The GitHub CLI stages both assets in a draft before publication. If publication fails, inspect the draft and tag before any retry. [GitHub CLI release behavior](https://cli.github.com/manual/gh_release_create)
5. Verify the anonymous API and download path from a separate Windows test install using the approved bootstrap pin. Use `Setup.ps1 -Install -TestInstall ([guid]::NewGuid())`, provision only an isolated browser fixture and profile, and set `"updaterChannel": "Staging"` and `"selfUpdateEnabled": true`. Its launcher starts at `app\ChromiumUpdater.exe` in the test root. Exercise two approved test versions, inspect the active version and launch results, and record the exact artifact identities and recovery result before approving Stable. Keep issue #8 open until live signed prerelease delivery is verified.

The ZIP contains reviewed updater scripts and C# source, sample configuration, applicable notices and a generated manifest. Setup and self-update compile the launcher locally using the Windows .NET Framework compiler. Reproducibility covers the distributed ZIP. The builder uses Git objects and fixed ZIP ordering and timestamps. Signatures use RSA PKCS#1 v1.5 with SHA-256 over five ASCII lines with LF terminators, including the format identifier `Ungoogled Chromium Updater package v1`, repository `MasterSon-git/ungoogled-chromium-updater`, tag, decimal ZIP byte count, and lowercase ZIP SHA-256.

The v1 manifest declares the complete flat payload. New versions may add bounded, individually named script, C# source, JSON, Markdown or text files. Keep the v1 core files and entry-point contracts while older clients depend on them. For a new archive or signature format, first release a v1 bridge that can consume both formats. Verify the bridge on an older installation and provide the trusted manual upgrade path for clients that skip it.

## First signed staging validation

Use the reviewed `0.1.0` checkout at `65285a9` for the isolated baseline and verify its installed public pin against the reviewed DER fingerprint. Keep browser installation in Manual mode with a local argument recorder and a disposable profile. Once the reviewed `0.1.1-rc.1` commit is on `main` and the maintainer authorizes the tag and publication, use the release workflow above.

After publication, verify that the anonymous release API reports an immutable prerelease with the expected tag and both signed package assets. Run an eligible launch from the isolated baseline in Staging mode. Record that `app\Updater.version` and the selected slot both report `0.1.1-rc.1`, the updater outcome is `Applied`, and the recorder received the original arguments. The isolated installation provides the evidence for issue #8 before production activation.

## Verify and reinstall

Use a trusted review checkout with the expected public pin. Put the downloaded ZIP and matching `.sig` side by side.

```powershell
.\tools\Release.ps1 -VerifyPackage $packagePath -Version 0.2.0
Expand-Archive -LiteralPath $packagePath -DestinationPath $newLocalDirectory
& (Join-Path $newLocalDirectory 'Setup.ps1') -Install
```

Use the exact intended version and a new local extraction directory. Proceed only after verification succeeds. The verifier checks the signature and manifest and runs the verified worker probe. Let updater checks finish before running Setup. The installed launcher path stays the same. [Updater and browser recovery](maintenance.md)
