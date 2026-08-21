# Changelog

All notable project changes will be documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases will use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- A native macOS login-item control with enabled, disabled, approval-required, and unavailable status feedback in Settings.

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

[Unreleased]: https://github.com/newtonlorenz/safemac-av/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/newtonlorenz/safemac-av/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/newtonlorenz/safemac-av/releases/tag/v1.0.0
