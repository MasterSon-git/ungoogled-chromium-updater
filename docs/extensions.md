# Extension maintenance

The launcher reads extension registration metadata from each profile and checks approved release channels. It compares version, identity, update URL and requested permissions. Packages offered by an approved channel are verified before a manual update is proposed. It reports new or unrecognized extensions for review. It leaves enabled states, grants, and profile preferences under Chromium's control.

## Chrome Web Store

For an approved ID, the coordinator queries Google's Chrome Web Store update endpoint with the extension ID and browser version. This endpoint can return version, package location, SHA-256 and length. The updater validates the extension's developer proof and Chromium's pinned production Web Store publisher proof before presenting a new package for review. Availability may vary with browser version and staged rollout.

Use Chromium Web Store by NeverDecaf for Store extension installation and update prompts when the identity and channel match. Keep the helper in manual installation mode so that each offered version can be reviewed. Check its badge and release details after the launcher flags an update. Chromium authorizes the install and prompts for permission changes. After any update, run a check with `-VerifyCurrent` to compare the installed version and manifest with the signed package. A userscript manager's own script updates are separate.

Ungoogled Chromium's upstream [FAQ](https://github.com/ungoogled-software/ungoogled-chromium-wiki/blob/master/faq.md) documents the extension backend. The patched Chromium downloader can differ from Google Chrome's updater, even when an extension has a normal Store update URL. Review [NeverDecaf's published source and releases](https://github.com/NeverDecaf/chromium-web-store) before changing this backend. The helper uses extension management, downloads, storage, alarms, context menus, and host access on supported stores. This access lets it discover installed extensions and fetch distributions. Its update checks may also query channels for extensions beyond the launcher's approved list. Keep it installed while it remains the supported Store workflow, and review its permissions and maintenance before enabling any additional sources.

## Full uBlock Origin

The original Chrome Web Store ID is `cjpalhdlnbpafiamejdnhcphjbkeiagm`. Raymond Hill publishes the current full Chromium extension as a [signed CRX on GitHub](https://github.com/gorhill/uBlock/releases/latest), with ID `fkgkibajhfbepljeaefdnfnegdcjomkh`. Its [official update manifest](https://github.com/gorhill/uBlock/blob/master/dist/chromium/update.xml) maps the new ID to the release artifact. The launcher's check retrieves releases and binaries directly from GitHub. The CRX package currently declares the publisher's CDN URL for the update manifest. If the helper offers that channel independently, use the GitHub release and Chromium confirmation for uBlock Origin maintenance.

For an ID migration:

1. Open the legacy extension's dashboard, go to Settings, then choose **Back up to file**. Save it in the private updater directory. Save My filters, My rules, and Trusted sites separately if you use those features. Note the extension's enabled state, custom browser site access, and any file or incognito access you intentionally granted. Review the [publisher's backup instructions](https://github.com/gorhill/uBlock/wiki/Dashboard%3A-Settings).
2. Back up the closed profile and validate the intended Windows browser build before migration. Choose the signed Chromium `.crx` from the official stable GitHub release. Use the supported Chromium prompt. The signed replacement has a new identity and Chromium requires explicit confirmation. If no prompt appears, check the upstream-supported CRX installation flow. Keep the old extension and use the backup if the signed installation cannot be completed.
3. Restore the JSON in the new extension's dashboard. Verify filters, dynamic rules, trusted sites, imported lists, and selected settings. Restore browser-side grants deliberately if needed. Temporarily disable the legacy extension during the comparison, keep its backup, and reproduce the old enabled state after testing.
4. Test the new extension with the [uBlock Origin logger](https://github.com/gorhill/uBlock/wiki/The-logger) and a safe request you expect to be blocked. Verify the same request succeeds with filtering paused for that test site, then restore filtering. Confirm the new ID and exact installed version in `chrome://extensions`, and run the launcher's signed channel check. The next signed update can be verified the same way.
5. Remove the legacy extension only after the replacement works and the user approves removing the old copy.

uBlock Origin filter-list refreshes are managed in the extension's dashboard. They are independent of the CRX version and its update workflow.
