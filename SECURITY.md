# Security Policy

SafeMac AV handles untrusted filenames, launches local security tools, moves files into quarantine, and can create per-user scheduled jobs. Security reports are taken seriously.

## Supported versions

Security fixes target the latest release and the current `main` branch. Older source snapshots may not receive backports while the project is preparing its first stable public release.

## Report a vulnerability privately

Do not open a public issue for a suspected vulnerability.

Use GitHub's [private vulnerability reporting](https://github.com/newtonlorenz/safemac-av/security/advisories/new) to send the maintainers:

- the affected commit or version;
- impact and realistic attack scenario;
- minimal reproduction steps or a proof of concept;
- relevant macOS, Xcode, and ClamAV versions; and
- any suggested mitigation.

Redact usernames, home-directory paths, file contents, signing credentials, and real malware. A harmless synthetic fixture is preferred. The maintainers will acknowledge the report in the advisory thread, assess severity, coordinate a fix, and arrange disclosure there.

If private vulnerability reporting is unavailable, open a public issue containing only a request for private maintainer contact. Do not include vulnerability details in that issue.

## Scope

Reports are especially useful for:

- command or argument injection into `clamscan`, `clamdscan`, `freshclam`, or `launchctl`;
- unsafe path handling, symlink traversal, or writes outside the selected directories;
- quarantine data loss, metadata tampering, hash-verification bypasses, or unsafe restore behavior;
- untrusted Finder request or scheduled-job handling;
- privilege escalation, sandbox assumptions, or code-signing weaknesses; and
- accidental disclosure of local paths, logs, scan results, or credentials.

ClamAV engine or signature vulnerabilities should also be reported to the [ClamAV project](https://www.clamav.net/reports/bugs). Homebrew packaging issues belong to [Homebrew](https://github.com/Homebrew/homebrew-core/issues). You may still notify this project privately when an upstream issue affects its integration.

## Security boundaries

- The app is not sandboxed; see the rationale in the [README](README.md#security-and-privacy-model).
- Configured executable paths are trusted local configuration. Pointing them at an untrusted program grants that program the app's user-level access.
- The app does not request root access and scheduled scans run as the current user through `launchd`.
- `freshclam` performs network access. The GUI itself contains no telemetry or analytics client.
- Quarantine is local file isolation, not an encrypted vault or privilege boundary.
- Unsigned local builds and signed/notarized releases have different trust properties. Never treat an archive or DMG as notarized without verifying it.

## Verifying a distribution

For a signed release, inspect the app and notarization ticket before use:

```bash
codesign --verify --deep --strict --verbose=2 "/Applications/SafeMac AV.app"
spctl --assess --type execute --verbose=2 "/Applications/SafeMac AV.app"
```

Checksums, tags, and release notes should be obtained from the upstream GitHub repository. Source builds should be reviewed and built locally with a trusted Xcode installation.
