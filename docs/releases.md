# Updater release procedure

Use [Semantic Versioning 2.0.0](https://semver.org/) for the updater. Bump the patch version for compatible fixes, the minor version for compatible features, and the major version for breaking changes to configuration, installation, or documented command interfaces. Put the exact version in `src/Updater.version` and tag the selected commit `vMAJOR.MINOR.PATCH`. Use tags such as `v0.2.0-rc.1` for staging and increment the prerelease identifier for each new candidate. Build metadata is reserved. Publish the final version under its own stable tag.

Stable accepts only stable tags. Staging accepts both stable tags and prerelease tags. The client selects the highest eligible version strictly above the active version from the latest 100 GitHub releases, with a single bounded metadata request. If an installation cannot discover an eligible version, use the verified manual installation path. The Chromium and extension channels stay on their existing stable policies.

## Build and sign a selected version

1. Select an independently reviewed commit on `origin/main`. Confirm its version and run both Windows test suites and static validation in [CONTRIBUTING.md](../CONTRIBUTING.md). Review the exact release inputs and keep private evidence outside the repository.
2. From a trusted release-tool checkout, fetch `main` and pass the complete selected commit SHA to the builder. Use a new local output directory. The builder archives only the tracked allowlist at that commit. It writes a reproducible ZIP with fixed entry ordering and timestamps, checks the file list and version, and probes the worker.

   ```powershell
   git fetch origin main
   .\tools\Release.ps1 -Commit $reviewedCommit -OutputDirectory $outputDirectory
   ```

3. On a trusted signing workstation, repeat the build into a separate directory with `-CertificateThumbprint $thumbprint`. The tool uses an RSA 3072-bit or 4096-bit signing key available through the certificate in `Cert:\CurrentUser\My`. The tool verifies the signature against the pin in the trusted release-tool checkout before writing the sidecar. Compare ZIP hashes from the reviewed build and the signing build.
4. Verify the signed package against the expected version. The package and signature are the release assets. The ZIP contains the updater scripts and C# sources, the sample configuration, 0BSD and third-party notices. It contains no compiled launcher or third-party executable. Setup compiles the fixed launcher locally with the Windows .NET Framework compiler.

Signing uses SHA-256 with RSA PKCS#1 v1.5. The signed message consists of five ASCII lines with LF terminators, including the format identifier `Ungoogled Chromium Updater package v1`, repository `MasterSon-git/ungoogled-chromium-updater`, tag, decimal ZIP length in bytes, and lowercase hexadecimal ZIP SHA-256. The signature is a raw binary sidecar.

Keep the release private key off GitHub and outside the repository. Use a non-exportable key or a hardware-backed provider where available. Pin only its independently verified public SubjectPublicKeyInfo PEM in `src/ReleaseTrust.ps1`. Have a second maintainer compare the public-key fingerprint with the trusted signer before approving the bootstrap. The initial implementation ships with an empty pin pending that approval.

For planned rotation, select a reviewed higher version containing the new pin. Build and sign it from the trusted tool checkout with the old pin and key. Verify it with that same old pin and test that the installed bridge accepts a later release signed with the new key. Publish a channel-appropriate stable bridge before changing the stable signing key. Keep an authenticated route to the bridge for clients that skip it. For key compromise or loss, distribute a reviewed bootstrap and replacement pin independently and use the manual installation path. [Threat model](../SECURITY.md#updater-self-update)

## Validate staging and publish

1. Run `tests\Test-SelfUpdate.ps1` before proposing a release. It builds signed fixture packages, uses a separate setup root and runs the real Windows launcher across versions with an isolated argument recorder. Its feed replies come from local fixtures.
2. After the maintainer authorizes a public staging release, first validate the intended package in an isolated install. Use a separate test installation with `Setup.ps1 -Install -TestInstall ([guid]::NewGuid())` and the launcher under its `app` directory. Its initial configuration uses an isolated browser path and profile, Manual browser updates, and disabled self-updates. Provision only an isolated browser fixture and test data, set `"updaterChannel": "Staging"` and `"selfUpdateEnabled": true`, and exercise the signed package. Keep production shortcuts and data out of the test. Run both test versions and record the active versions, errors and recovery result.
3. Have a maintainer create a draft release at the approved commit's exact tag. Attach `ungoogled-chromium-updater-v1.zip` and `ungoogled-chromium-updater-v1.zip.sig`, confirm the tag, version, asset hashes and release notes, and select pre-release for a staging tag. Publication is a deliberate GitHub action by a maintainer. The build and verification tools use no GitHub credentials or publication permissions.
4. Verify the anonymous API and download path after publication with the isolated Staging installation. Record the exact assets and result before approving a separate stable version. A draft allows asset review by maintainers. The anonymous path requires a public repository and a published release. Repository visibility is a separate maintainer decision. [GitHub release API](https://docs.github.com/en/rest/releases/releases?apiVersion=2022-11-28#list-releases)

GitHub immutable releases protect the tag and assets of a published release, including a published prerelease. Enable immutability before the first approved distribution where available, and upload files while the release is a draft. GitHub allows changing the prerelease flag even on an immutable release. The client requires that flag to agree with the signed version tag, so publish a new stable tag for promotion. Immutability and GitHub attestations provide hosting-side evidence. Clients verify the independent publisher signature for every package. [GitHub immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)

## Verify and reinstall

Get the release tool and pinned public key from a trusted checkout. Download the ZIP and its matching `.sig` next to it. Replace the example version with the exact version you intend to install.

```powershell
.\tools\Release.ps1 -VerifyPackage $packagePath -Version 0.2.0
Expand-Archive -LiteralPath $packagePath -DestinationPath $newLocalDirectory
& (Join-Path $newLocalDirectory 'Setup.ps1') -Install
```

Proceed with extraction only after successful verification. The verifier checks the signature and file list and runs the verified worker probe. Use a separate local directory for extraction and leave the updater idle for manual installation. Existing shortcuts continue to use the fixed launcher path. Changing the bootstrap command or activation format requires a compatible transition or a documented manual install. [Updater and browser recovery](maintenance.md)
