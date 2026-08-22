# Changelog

All notable project changes will be documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases will use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- An embedded, hardened macOS 13+ background login-item helper for launch at login, the persistent menu bar, and automatic signature-update launches.
- Transactional migration from the legacy main-app login item, shared symlink-resistant background-work leases, and release verification for the embedded helper.
- Documented one-release launch-at-login downgrade recovery: disable the helper login item before installing a pre-helper build, then re-enable the legacy login item from that build.
- A user-initiated Settings flow for the background helper’s separate notification permission, using a dedicated one-shot helper instance so it remains reliable while the login helper is already running.

### Changed

- New automatic signature schedules invoke only the embedded helper with a fixed flag; the foreground app keeps the legacy scheduled-update handler for one compatibility release.
- Freshclam success parsing now fails closed for every nonzero exit, and helper/main handoff code requirements require the Apple generic anchor, exact bundle identifier, and Team ID.
- Sparkle now defers its first-run consent until visible interactive launch maintenance completes; hidden and scheduled modes start it only through an explicit Check for Updates action.

## [1.2.0] - 2026-08-22

### Added

- A native macOS login-item control with enabled, disabled, approval-required, and unavailable status feedback in Settings.
- Real daily or weekly per-user scheduling for automatic ClamAV malware-signature updates, with transactional rollback and privacy-safe result notifications.
- Sparkle-based app-update checking, guarded by release-provided feed URL and public EdDSA key configuration.

### Changed

- The local DMG helper can notarize with either a notarytool Keychain profile or App Store Connect API key credentials and always writes `SHA256SUMS.txt`.
- The release-package workflow can embed Sparkle app-update settings and generate a signed appcast artifact when the Sparkle private key secret is configured.

### Security

- Hardened Finder scan handoff so file paths move only through the signed app-group queue with freshness, size, symlink, permission, and absolute-path validation.

## [1.1.0] - 2026-08-21

### Added

- Native macOS 26 Liquid Glass surfaces with accessible material and opaque fallbacks for earlier macOS versions and increased-contrast settings.
- Expanded macOS UI smoke coverage for the application shell, appearance modes, and sidebar navigation.

### Changed

- The product and public repository are now branded SafeMac AV, with a new app icon, README presentation, Finder action, and release package name.
- The interface now uses a responsive split-view shell and clearer dashboard, scan, update, scheduling, quarantine, history, log, and settings surfaces.

### Fixed

- Signature updates started from the Updates screen now show shared in-progress feedback on the Dashboard.

## [1.0.0] - 2026-08-19

### Added

- Native SwiftUI dashboard, scan configuration, quarantine, history, updates, schedules, logs, and settings screens.
- Local `clamscan` and optional local `clamdscan` execution with progress, pause, resume, cancellation, and exit-code handling.
- `freshclam` signature updates and Homebrew path detection for Apple silicon and Intel Macs.
- FSEvents folder monitoring, per-user `launchd` schedules, and a Finder Sync extension request path.
- Unit, integration, and interactive macOS UI tests.
- Public license, security policy, contribution guide, architecture notes, issue forms, pull-request template, and CI workflow.

### Changed

- Quarantine, restore, and delete operations now keep payload and metadata changes transactional when storage operations fail.
- Settings and scheduled-job metadata now use atomic writes, report failures, and preserve existing state during failed updates.
- User-facing quarantine, scheduling, and export failures now appear as actionable alerts instead of being silently ignored.
- The protection score now distinguishes an installed ClamAV engine from stale or missing signatures.

### Security

- Public distribution guidance distinguishes unsigned source builds from signed and notarized artifacts.

[Unreleased]: https://github.com/newtonlorenz/safemac-av/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/newtonlorenz/safemac-av/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/newtonlorenz/safemac-av/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/newtonlorenz/safemac-av/releases/tag/v1.0.0
