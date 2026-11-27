# Publication review

Ungoogled Chromium Updater is an independent, unofficial project. Refer to upstream projects by name to identify their software and distribution channels. A Windows shortcut can reference the icon in the user's local Chromium installation. Keep upstream logos and artwork out of project branding and distribution archives.

## Review before publication

- Inspect the candidate tree and the history of all local and advertised remote refs, including branches, tags, and available pull-request refs. Review commit and tag messages, author and committer metadata, and tracked file contents.
- Review the hosted repository description and settings, issues, pull requests, conversation and review comments, releases and assets, and Actions workflows, runs, logs, artifacts, and caches where available. Include other populated surfaces, such as a wiki or Discussions, when applicable.
- Look for credentials, personal email addresses and paths, production configuration, private profile and extension inventories, downloads, logs, backups, and browser data. Confirm that copied or adapted material has documented provenance and retains its notices.
- Record the refs, surfaces, checks, findings, and access limits in a private assessment. Share a sanitized summary for independent review. Resolve confirmed rights and privacy issues before publication. Obtain maintainer approval before contacting upstream authors or rewriting history.
- Keep the repository private during review. Changing visibility and publishing a GitHub Release require a separate maintainer decision.

## Verify a source archive

Use a reviewed commit and a new local archive path outside the repository, preferably in private storage. Pass the reviewed commit ID and archive path to Git.

```powershell
git ls-tree -r --name-only $reviewedCommit
git archive --format=zip --output=$archivePath $reviewedCommit
if ($LASTEXITCODE) { throw 'Source archive creation failed.' }
tar -tf $archivePath
if ($LASTEXITCODE) { throw 'Source archive listing failed.' }
```

Compare archive file entries with the exact reviewed tree and the path allowlist in `.gitignore`. Include `LICENSE`, `THIRD_PARTY_NOTICES.md`, and the example configuration. Inspect the archived contents for private data and generated files, including launcher binaries, Chromium and extension downloads, and user configuration. Git's ignore rules apply to untracked files. A private file committed earlier still appears in its tree and history, so review both before publication.
