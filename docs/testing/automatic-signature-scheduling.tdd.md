# Automatic signature scheduling TDD evidence

## User journeys

- A user can enable daily or weekly malware-signature updates and trust that both the saved setting and per-user LaunchAgent agree.
- A failed file, launchd, or settings operation preserves the previous working schedule and shows a safe error.
- A scheduled launch updates through the existing single-flight `freshclam` path, posts the existing privacy-safe result notification, and exits without normal UI.
- A queued scheduled launch becomes a no-op if automatic updates have since been disabled.

## RED

Commits `2735b03` and `f2f5020` introduced focused scheduler, launch-mode, lifecycle, and AppState integration tests before production code. The focused build failed because `SignatureUpdateScheduler`, `SignatureUpdateScheduling`, and the scheduled-signature launch mode did not exist.

## GREEN

The focused suite covers:

- fixed label and executable-only launch arguments;
- daily and weekly calendar intervals;
- atomic installation and replacement;
- write/load rollback and disable cleanup;
- dedicated launch-mode parsing, accessory/no-window policy, one-shot completion;
- transactional AppState persistence and rollback;
- corrupt-settings startup safety; and
- enabled and disabled scheduled execution.

Final focused, full-suite, universal Release, UI, coverage, and review evidence is recorded in pull request #10.
