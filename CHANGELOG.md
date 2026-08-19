# Changelog

All notable project changes will be documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases will use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

The project is preparing its first public source release.

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
