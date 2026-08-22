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
- [ ] Confirm repository variables and appcast secret for signed Sparkle updates:
  - `SPARKLE_FEED_URL`: credential-free HTTPS URL without a query or fragment
  - `SPARKLE_PUBLIC_ED_KEY`: canonical base64 for exactly 32 bytes
  - `SPARKLE_DOWNLOAD_URL_PREFIX`: credential-free HTTPS URL ending in `/`, without a query or fragment
  - `SPARKLE_PRIVATE_ED_KEY_BASE64`: base64 encoding of a modern Sparkle exported key file whose decoded seed is exactly 32 bytes
- [ ] Confirm the Sparkle public key belongs to that private key. The workflow independently derives and compares it before importing the Developer ID certificate.

## Verify source

Run locally before tagging:

```bash
xcodebuild test \
  -project ClamAV-GUI.xcodeproj \
  -scheme ClamAV-GUI \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData-Test

xcodebuild build \
  -project ClamAV-GUI.xcodeproj \
  -scheme ClamAV-GUI \
  -configuration Release \
  -destination 'platform=macOS'
```

## Tag and package

Do not package final release assets from a moving branch ref. After release publication is approved:

- [ ] Create tag `vX.Y.Z` on the verified commit.
- [ ] Dispatch the manual **Release package** workflow from `main` with `release_ref` set to the full annotated tag ref `refs/tags/vX.Y.Z`. The workflow rejects tags whose resolved commit is not on `origin/main` before any release secret is exposed.
- [ ] Download the workflow artifact.

- [ ] Verify checksums from the artifact directory:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

- [ ] Verify notarization, stapling, nested embedded-code signatures, and Gatekeeper on a Mac:

```bash
./scripts/verify-release-package.sh build
```

- [ ] Before replacing the currently installed app, verify the signed appcast advertises exactly one newer update to that installed build. The verifier requires a deep, strict Developer ID Application signature from Team `CQPH8YR62A`, hardened runtime, secure timestamp, and Gatekeeper trust:

```bash
./scripts/verify-installed-sparkle-canary.sh "/Applications/SafeMac AV.app" build/appcast/appcast.xml build/SafeMac-AV.dmg
```

- [ ] Copy `SafeMac AV.app` to `/Applications`, launch it, and confirm the main window and menu-bar item open.
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
