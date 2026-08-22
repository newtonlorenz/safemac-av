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
- [ ] If app updates are enabled, confirm repository variables and appcast secret:
  - `SPARKLE_FEED_URL`
  - `SPARKLE_PUBLIC_ED_KEY`
  - optional `SPARKLE_DOWNLOAD_URL_PREFIX`
  - optional `SPARKLE_PRIVATE_ED_KEY_BASE64`

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
- [ ] Run the manual **Release package** workflow with `release_ref` set to `vX.Y.Z`.
- [ ] Download the workflow artifact.

- [ ] Verify checksums from the artifact directory:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

- [ ] Verify notarization on a Mac:

```bash
codesign --verify --strict --verbose=2 SafeMac-AV.dmg
xcrun stapler validate SafeMac-AV.dmg
spctl --assess --type open --verbose SafeMac-AV.dmg
```

- [ ] Mount the DMG and verify the app executable contains both `arm64` and `x86_64` slices:

```bash
lipo -archs "/Volumes/SafeMac AV/SafeMac AV.app/Contents/MacOS/SafeMac AV"
```

- [ ] Copy `SafeMac AV.app` to `/Applications`, launch it, and confirm the main window and menu-bar item open.
- [ ] If Sparkle is configured, confirm `appcast.xml` is present and references the published DMG URL prefix.

## Publish boundary

Stop before creating a GitHub Release or uploading public assets until release publication is explicitly approved.

After final publication approval:

- [ ] Create a GitHub Release for `vX.Y.Z`.
- [ ] Upload `SafeMac-AV.dmg`, `SHA256SUMS.txt`, and `appcast.xml` if generated.
- [ ] Re-download release assets and repeat checksum, stapler, and Gatekeeper verification.
- [ ] Update any public download/appcast hosting that is not served from GitHub Releases.
