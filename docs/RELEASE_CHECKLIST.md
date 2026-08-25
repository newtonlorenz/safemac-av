# SafeMac AV release checklist

Use this checklist for a signed and notarized release. Publication is a separate approval step after artifacts are verified.

## Prepare

- [ ] Confirm `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `ClamAV-GUI.xcodeproj/project.pbxproj`.
- [ ] Confirm `CHANGELOG.md` has a dated release section and compare links.
- [ ] Confirm GitHub repository secrets for signing and notarization are configured:
  - `DEVELOPER_ID_CERTIFICATE_BASE64`
  - `DEVELOPER_ID_CERTIFICATE_PASSWORD`
  - `RELEASE_KEYCHAIN_PASSWORD`
  - `NOTARY_KEY_BASE64`
  - `NOTARY_KEY_ID`
  - `NOTARY_ISSUER_ID`
- [ ] Confirm the protected GitHub environment `release` exists, contains the release secrets, and requires designated maintainer reviewers.
- [ ] Confirm a GitHub tag ruleset protects `refs/tags/v*`: block tag updates/deletions and restrict creation to designated release maintainers.
- [ ] Confirm repository variables and appcast secret for signed Sparkle updates:
  - `SPARKLE_FEED_URL`: credential-free HTTPS URL without a query or fragment
  - `SPARKLE_PUBLIC_ED_KEY`: canonical base64 for exactly 32 bytes
  - `SPARKLE_DOWNLOAD_URL_PREFIX`: credential-free HTTPS URL ending in `/`, without a query or fragment
  - `SPARKLE_PRIVATE_ED_KEY_BASE64`: base64 encoding of a modern Sparkle exported key file whose decoded seed is exactly 32 bytes
- [ ] Confirm the Sparkle public key belongs to that private key. The workflow independently derives and compares it before importing the Developer ID certificate.

The release workflow stores the decoded private key in the runner's temporary directory with mode `0600`, rejects public/private key mismatches, and removes the temporary key even if a later step fails. A non-release local build without a feed URL or public key disables the app-update UI instead of checking a placeholder feed.

## Verify source

Run locally before tagging:

```bash
./scripts/run-tests.sh unit
./scripts/run-tests.sh release
```

## Create a local package

Create an unsigned DMG for local testing:

```bash
./scripts/create-dmg.sh
```

Create a signed local DMG without notarizing it:

```bash
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  ./scripts/create-dmg.sh
```

Create a signed, notarized, and stapled package with a `notarytool` Keychain profile:

```bash
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_PROFILE='safemac-av-notary' \
  ./scripts/create-dmg.sh
```

Alternatively, use an App Store Connect API key stored outside the repository:

```bash
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_KEY_PATH='/path/to/AuthKey_ABC123DEFG.p8' \
NOTARY_KEY_ID='ABC123DEFG' \
NOTARY_ISSUER_ID='00000000-0000-0000-0000-000000000000' \
  ./scripts/create-dmg.sh
```

Create the Keychain profile separately with `xcrun notarytool store-credentials`. Keep credentials in Keychain or in an external `.p8` file. Never commit credentials or pass them as plain-text script arguments. The script writes the DMG and `SHA256SUMS.txt` under the ignored `build/` directory. Notarization modes submit to Apple, staple the app and DMG, and verify nested code.

If Keychain contains duplicate certificate names, set `SIGNING_IDENTITY` to the SHA-1 hash reported by `security find-identity -v -p codesigning`.

## Tag and package

Do not package final release assets from a moving branch ref. After release publication is approved:

- [ ] Create an annotated tag `vX.Y.Z` on the verified commit: `git tag -a vX.Y.Z -m "SafeMac AV vX.Y.Z"`.
- [ ] Dispatch the manual **Release package** workflow from `main` with `release_ref` set to the full annotated tag ref `refs/tags/vX.Y.Z`. The workflow rejects tags whose resolved commit is not exactly the freshly fetched current `origin/main` HEAD before any release secret is exposed.
- [ ] Download the workflow artifact.

- [ ] Verify checksums from the artifact directory:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

- [ ] Verify notarization, stapling, nested embedded-code signatures, and Gatekeeper on a Mac:

```bash
./scripts/verify-release-package.sh build
```

- [ ] Confirm the verifier reports the embedded `SafeMacAVBackground.app` helper. It must be Developer-ID signed by Team `CQPH8YR62A`, hardened, timestamped, universal, `LSUIElement=true`, and free of Sparkle.
- [ ] Exercise launch-at-login migration on an installed build: legacy main-app item enabled, helper registration/approval, helper enablement, legacy removal, and disable rollback. If a downgrade is needed during this one-release bridge, disable launch at login before installing the pre-helper build and re-enable it from that build; do not assume an old build can recreate the helper migration automatically.

- [ ] Generate a local appcast from a directory containing release archives:

```bash
SPARKLE_PRIVATE_ED_KEY='/path/to/sparkle_private_ed_key' \
SPARKLE_DOWNLOAD_URL_PREFIX='https://example.com/downloads/' \
  ./scripts/generate-appcast.sh build/appcast
```

- [ ] Before replacing the currently installed app, verify the signed appcast advertises exactly one newer update to that installed build. The verifier requires a deep, strict Developer ID Application signature from Team `CQPH8YR62A`, hardened runtime, secure timestamp, and Gatekeeper trust:

```bash
./scripts/verify-installed-sparkle-canary.sh "/Applications/SafeMac AV.app" build/appcast/appcast.xml build/SafeMac-AV.dmg
```

- [ ] Copy `SafeMac AV.app` to `/Applications`, launch it, and confirm the main window opens. Enable launch at login, approve it if macOS asks, then confirm the embedded helper owns one menu-bar item without prompting for notification permission.
- [ ] From Settings › Notifications, choose **Allow Background Update Notifications** and confirm the dedicated helper authorization request is shown only after that explicit click (including while the regular login helper is already running). Confirm a denied or not-determined helper authorization suppresses scheduled-update notifications without another prompt.
- [ ] Confirm `appcast.xml` is present, has valid feed and archive EdDSA signatures, and references the published DMG URL prefix.

## Publish boundary

Stop before creating a GitHub Release or uploading public assets until release publication is explicitly approved.

After final publication approval:

- [ ] Create a GitHub Release for `vX.Y.Z`.
- [ ] Upload `SafeMac-AV.dmg`, `SHA256SUMS.txt`, and `appcast.xml` if generated.
- [ ] Re-download release assets and repeat checksum, stapler, and Gatekeeper verification.
- [ ] Update any public download/appcast hosting that is not served from GitHub Releases.
- [ ] Run the installed-app Sparkle canary against the published feed. It rechecks the same signature, Team ID, runtime, timestamp, and Gatekeeper policy before and after updating its temporary copy:

```bash
SAFEMAC_CANARY_EXPECT_UPDATE=1 \
SAFEMAC_CANARY_INSTALL=1 \
SPARKLE_CLI='/path/to/sparkle.app/Contents/MacOS/sparkle' \
  ./scripts/run-installed-sparkle-canary.sh
```
