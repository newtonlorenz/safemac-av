# Contributing

Thanks for helping improve SafeMac AV. This project favors small, reviewable changes backed by tests and a clear user outcome.

## Before opening a change

- Search existing issues and pull requests.
- Use an issue for behavior changes, larger refactors, or anything that changes the security model.
- Keep private data out of reports. Paths, account names, logs, quarantined filenames, and threat results can all be sensitive.
- Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## Development setup

You need macOS 13 or later, Xcode, and a local ClamAV installation. Follow the [README setup](README.md#quick-start) or run the read-only environment check:

```bash
./setup.sh
```

Open `ClamAV-GUI.xcodeproj` and use the shared `ClamAV-GUI` scheme. These internal names remain for compatibility.

## Working on a change

1. Update a clean local `main` with `git pull --ff-only origin main`.
2. Create a focused branch from `main`. Never commit or push directly to `main`.
3. Add or update a test that demonstrates the behavior.
4. Make the smallest implementation that passes the test.
5. Run the unit suite, a Release build, and any affected UI flow.
6. Review the complete diff for secrets, private paths, signing assets, and generated output.
7. Update README, architecture, or changelog entries when behavior changes.

Prefer value semantics and new values over shared mutation. Validate filesystem paths and external data at boundaries. Errors affecting scans, quarantine, schedules, or user data should be visible to the user and retain enough context for diagnosis without exposing unrelated private information.

Do not add real malware, secrets, personal files, signing certificates, provisioning profiles, or notarization credentials to the repository.

## Verification

Unit and integration tests:

```bash
xcodebuild \
  -project ClamAV-GUI.xcodeproj \
  -scheme ClamAV-GUI \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Release build:

```bash
xcodebuild \
  -project ClamAV-GUI.xcodeproj \
  -scheme ClamAV-GUI \
  -configuration Release \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Interactive UI smoke test, from a logged-in macOS session with a locally signable test host. Do not disable code signing for this command:

```bash
xcodebuild \
  -project ClamAV-GUI.xcodeproj \
  -scheme ClamAV-GUI-UI \
  -destination 'platform=macOS' \
  test
```

An ad-hoc or development-signed local test run is sufficient. With `CODE_SIGNING_ALLOWED=NO`, macOS terminates the UI runner before the test executes. For UI changes, also launch the built application and exercise the affected flow directly. Never test destructive quarantine actions against irreplaceable files.

## Pull requests

Every tracked change must arrive through a pull request. This includes documentation, CI, release scripts, and maintenance changes. Direct pushes, local merges into `main`, and public-history rewrites are not accepted.

Push the branch with `git push -u origin <branch>`, then open a focused pull request. Upstream merges use squash merge to keep `main` linear. Delete the merged branch afterward.

Use a conventional commit subject where practical, for example:

```text
fix: preserve quarantine state when metadata writes fail
```

A pull request should explain the problem, the chosen behavior, security or privacy impact, and exact verification performed. Screenshots are useful for visible UI changes. Keep generated build output out of the diff.

Resolve review conversations before merge. Do not merge with failing or unavailable CI unless the maintainer explicitly approves and documents an exception in the pull request.

## Maintainer release workflow

1. Merge version, changelog, packaging, and release-note changes through a pull request.
2. Tag the reviewed commit on `main`. Do not move or replace a published tag.
3. Build from a clean tag and run the documented verification suite.
4. Sign with Developer ID, notarize with Apple, and staple the ticket.
5. Publish a universal `arm64` and `x86_64` DMG with `SHA256SUMS.txt`.
6. Download the published assets and verify their checksum, signature, notarization, Gatekeeper result, and installed UI.

Published tags and assets are immutable. Publish a new semantic version for corrections.

## Fork and distribution checklist

The upstream identifiers intentionally use the Newton Lorenz namespace. You can modify the code under MIT, but a distributable fork should have its own identity:

1. Change the app, Finder extension, and test bundle identifiers in `ClamAV-GUI.xcodeproj/project.pbxproj`.
2. Change `CQPH8YR62A.com.newtonlorenz.ClamAV-GUI` to an unprovisioned macOS app-group identifier prefixed by your signing Team ID, and add the matching entitlement to both participating targets.
3. Change the distributed-notification name, Finder app lookup identifier, LaunchAgent labels, and any other `com.newtonlorenz.*` strings together.
4. Choose your own signing team, Developer ID certificate, and notarization profile.
5. Rename the product if your distribution could be mistaken for the upstream build.
6. Retain the MIT copyright and permission notice in copies or substantial portions, as required by [LICENSE](LICENSE).

Find all identity-bearing strings before release:

```bash
rg -n 'newtonlorenz|ClamAV-GUI' \
  ClamAV-GUI ClamAV-GUI-Finder ClamAV-GUI.xcodeproj
```

## License

By contributing, you agree that your contribution is licensed under the repository's [MIT License](LICENSE).
