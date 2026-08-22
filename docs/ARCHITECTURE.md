# Architecture

SafeMac AV is a native macOS SwiftUI application that coordinates local ClamAV command-line tools. It does not embed or reimplement the antivirus engine.

## System overview

```text
SwiftUI views
     |
     v
  AppState  <------ Finder request queue / distributed notification
     |
     +------ ScanCoordinator ------ ClamAVRunner ------ clamscan or local clamdscan
     +------ FreshclamRunner ------------------------- freshclam
     +------ QuarantineManager ----------------------- quarantine payload + metadata
     +------ ScanScheduler --------------------------- per-user launchd jobs
     +------ SignatureUpdateScheduler ---------------- one per-user LaunchAgent
     +------ FileWatcher ----------------------------- macOS FSEvents
     +------ ConfigManager --------------------------- local JSON settings
     +------ LaunchAtLoginManager -------------------- SMAppService.loginItem
     +------ NotificationManager --------------------- macOS local notifications

delegate-owned NSWindowController + MenuBarExtra
     |
     +------ shared AppState
     +------ MenuBarManager -------------------------- AppKit activation policy

per-user launchd
     |
     +------ --scheduled-signature-update
                    |
                    +------ SafeMacAVBackground ---- freshclam
```

`AppState` is the `@MainActor` composition root for user-visible state. It owns service instances, coordinates scan lifecycle, and maps service outcomes into SwiftUI-observable values. Core classes isolate process launching, filesystem persistence, scheduling, and event streams from the view layer.

## Main flows

### Interactive scan

1. A view creates a `ScanRequest` with selected URLs and immutable `ScanOptions`.
2. `AppState` validates the configured ClamAV installation.
3. `ScanCoordinator` prevents overlapping scans and owns cancellation state.
4. `ClamAVRunner` launches `clamscan`, or a configured local `clamdscan`, with an argument array rather than a shell command.
5. Stdout and stderr are parsed into progress, detections, and a `ScanReport`. ClamAV exit code `1` means detections were found; higher codes are failures.
6. When requested, detections are passed to `QuarantineManager` after the scan completes.

### Signature update

`FreshclamRunner` launches the configured `freshclam` executable with the local config and signature-data paths. Its output is parsed into success, already-current, or failure status. Network access belongs to `freshclam`; the Swift application does not implement an update client.

`SignatureUpdateScheduler` owns the single per-user LaunchAgent `com.newtonlorenz.SafeMacAV.signature-update`. Its property list contains only the embedded `SafeMacAVBackground` executable and `--scheduled-signature-update`; configured ClamAV paths remain in app settings rather than launchd arguments. It validates that helper before changing the previous job. Daily and weekly calendar changes atomically replace the property list using modern per-user `launchctl bootstrap` and `bootout` operations. Reconciliation observes both the property list and launchd's loaded state, boots out the exact legacy `com.newtonlorenz.ClamAV-GUI.signature-update` service before loading the replacement, and removes its property list only after the replacement succeeds. A failed change restores the previous property list and runtime state; if restoration also fails, the app reports an indeterminate schedule instead of displaying a false enabled or disabled state.

Only the canonical `/Applications/SafeMac AV.app` install automatically reconciles the captured executable path; development, translocated, downloaded, and backup copies cannot take over the installed schedule. A scheduled invocation uses accessory mode, suppresses normal scenes, and runs from an application-delegate-owned task rather than a window lifecycle. It calls the same single-flight `AppState.updateSignatures()` path as manual updates, emits the same privacy-safe local result notification, and exits only after the update completes. If automatic updates were disabled after launchd queued an invocation, it exits without running `freshclam`. Malware-signature updates are distinct from SafeMac AV application updates and from Homebrew-managed ClamAV engine upgrades.

### Quarantine

The default quarantine location is `~/.clamav-quarantine/`. Each payload gets an opaque `.quarantine` filename, while `metadata.json` stores its original path, threat name, file size, timestamp, and SHA-256 hash.

Mutation ordering is transactional:

- quarantine moves the payload, commits metadata atomically, and rolls the move back on metadata failure;
- restore verifies SHA-256, preserves an existing destination as a backup, and rolls all moves back on metadata failure; and
- delete commits metadata first, deletes the payload, and restores the previous metadata if deletion fails.

The quarantine directory is not an encryption or privilege boundary. The current user can inspect or modify it.

### Scheduled scan

`ScanScheduler` persists job definitions in `~/Library/Application Support/SafeMac AV/` and writes one `com.newtonlorenz.SafeMacAV.scan.<UUID>` property list per enabled job under `~/Library/LaunchAgents/`. Only canonical interactive startup from `/Applications/SafeMac AV.app` may mutate legacy LaunchAgents: it validates and atomically copies legacy metadata without deleting it, then unloads each exact loaded legacy job before ensuring its replacement is loaded. Development, translocated, downloaded, and backup copies can strictly read metadata but cannot inspect or migrate those agents; schedule updates and deletion fail without mutation when the exact legacy agent still exists. A failed replacement restores the legacy file and its exact prior loaded or unloaded state. The Schedules screen uses the scheduler's strict nonmutating load path and displays startup migration or metadata failures instead of converting them into an empty schedule list; the tolerant lookup remains available only for non-interactive best-effort callers. The LaunchAgent starts the app with a job UUID; the app loads the current stored definition rather than placing user-selected scan paths directly in the property list.

Schedules run in the logged-in user's context. Moving or deleting the built app can invalidate the executable path captured in an existing LaunchAgent.

### Folder monitoring

`FileWatcher` creates an FSEvent stream for configured folders. New or changed files are filtered, deduplicated, and either scanned immediately for configured Downloads behavior or batched. Monitoring exists only for the lifetime of the app process; it is not a privileged on-access scanner.

### Background helper and launch at login

`SafeMacAVBackground.app` is an embedded macOS 13+ `LSUIElement` login-item app. It owns the persistent menu-bar session, background lease, one-shot scheduled-signature mode, and a fixed one-shot notification-authorization mode. It has no Finder queue consumer and no app-update framework or configuration. Its fixed Open, Settings, and Check for Updates routes first verify the canonical `/Applications/SafeMac AV.app` bundle; its distributed notifications are payload-free wake hints only. The foreground app owns Finder handoff, scheduled scans, all windows, and app updates.

The helper captures at most 64 KiB of combined freshclam output, maps it through the same outcome parser as foreground updates, and never logs raw process output. Any nonzero freshclam exit fails closed even if preceding output resembles success. It checks only the helper bundle's existing notification authorization after a scheduled update. Authorized notifications use the same summary-only update outcomes; denied and not-determined status suppresses delivery. The foreground Settings action verifies the embedded helper then starts a dedicated new helper instance with only the fixed authorization flag, so an already-running login helper cannot consume the request with stale arguments. That explicit user action is the sole authorization prompt path; it does not depend on launch-at-login being enabled and never runs from login or scheduling.

`LaunchAtLoginManager` maps `SMAppService.loginItem(identifier:)` into app-level disabled, enabled, approval-required, and unavailable states. On the canonical install only, it transactionally migrates an enabled legacy main-app login item: register the helper, retain the legacy item while approval is pending, remove the legacy item only after helper enablement, and roll back the helper if legacy removal fails. The service is injected behind a protocol so registration, approval, failure, and rollback behavior can be tested without changing the current user's Login Items.

This migration intentionally supports one release of forward compatibility, not an automatic downgrade. A pre-helper binary cannot recreate the removed helper registration safely. Before installing an older binary, disable launch at login in the current release; after installing the older binary, enable it again there. Failed registration, approval-pending migration, and disabled-state rollback retain or restore the legacy registration where possible, and the UI never reports launch-at-login disabled while either service remains active.

`AppState` treats the macOS service status as authoritative. It reconciles the saved `launchAtLogin` preference at startup and whenever the app becomes active. A toggle first updates the system login item and then atomically saves the matching preference. If persistence fails, the login-item change is rolled back; service and persistence errors remain visible in Settings.

### Finder request

The Finder Sync extension receives the current Finder selection, writes a bounded JSON request into the signed app group's shared container, posts a distributed notification containing at most the request UUID as a best-effort wake signal, and opens the main app. macOS can suppress distributed notifications sent by a sandboxed Finder extension, so notification delivery is never authoritative: initial launch, application activation, and reopen maintenance all drain the shared queue. The notification never carries file paths or raw errors. The main app uses one `AppState`-owned consumer to coalesce wakeups, atomically claim validated records before waiting for the scan coordinator to become idle, and acknowledge each claim only after the coordinator admits its scan. Claims are recovered as pending work after an app restart. This prevents overlapping in-process wakeups or queue pruning from deleting work held behind a running scan and admits each validated request once during a healthy app process. A crash before admission leaves the claim available for a later retry; a crash after admission may interrupt the scan after its claim has been acknowledged. The queue therefore does not claim crash-safe exactly-once or at-least-once execution after admission.

The store requires the fixed Finder source, fresh request timestamps before a queued request is claimed, absolute normalized paths, UUID-matched filenames, bounded record and queue sizes, and current-user `0700` directory and `0600` file permissions. A recovered claim keeps its original timestamp and remains pending after the queue freshness window because it already passed validation before the app accepted responsibility for it; its source, paths, filename, size, ownership, and permissions are revalidated on every restart. Invalid records are isolated so they do not block valid requests. If the shared container is unavailable or a newly queued request is stale, oversized, symlinked, malformed, over-permissive, or cannot be acknowledged, the handoff fails closed and no scan is admitted. The main app presents one fixed generic error after opening; Finder uses the same generic alert only if the app cannot open. Neither surface exposes selected paths, notification payloads, or filesystem errors.

A distributable build signs the app and extension consistently with the unprovisioned macOS app group `CQPH8YR62A.com.newtonlorenz.SafeMacAV`, whose prefix matches the Developer ID team. The main app intentionally retains `com.newtonlorenz.ClamAV-GUI` to preserve its installed Sparkle update lineage, while the Finder extension uses the host-prefixed child identity `com.newtonlorenz.ClamAV-GUI.SafeMacAV.FinderSync`. The notification, team-prefixed app group, and bundle identifiers are namespaced to the upstream project and must change together in a fork.

### Foreground and menu-bar operation

The embedded helper owns the persistent status item. The foreground app retains an uninserted SwiftUI menu-bar scene only as a composition host; its application delegate lazily owns one AppKit `NSWindowController`, whose `NSHostingController` embeds `ContentView`. The retained controller gives startup, helper Open/Settings routes, close/reopen, and Dock reopen one authoritative window identity instead of relying on SwiftUI scene materialization timing.

`MenuBarManager` isolates AppKit activation-policy changes behind a testable protocol. The bundle is a foreground application so ordinary interactive launches can reliably become active, own the menu bar, and focus their first window. During launch, the persisted `hideFromDock` preference selects the runtime `.accessory` policy to remain hidden, scheduled signature updates always select `.accessory`, and visible interactive launches and scheduled scans select `.regular` before launch finishes. Because bundle classification precedes the delegate's runtime policy, hidden and scheduled background launches can show a transient Dock item during startup; installed verification records that measured limitation instead of promising zero Dock presence. An app-lifetime settings observation keeps the runtime policy reversible even when no main window exists. App composition publishes its immutable manager, settings/argument providers, and `AppState` work closures through a shared launch-configuration registry instead of configuring a particular SwiftUI adaptor wrapper. Every delegate instance subscribes weakly, so the instance that actually receives AppKit lifecycle callbacks prepares and continues launch exactly once whether configuration arrives before or after those callbacks. Visible interactive launches and scheduled scans additionally retain their presentation request until composition installs the main-controller factory, then create and order the controller window before requesting public `NSRunningApplication` activation on the next main run-loop turn. The controller reorders the same window as key after activation and permits at most one bounded retry when macOS still reports the application inactive or the window non-key. Maintenance or scan work begins only after a further main-run-loop yield so the window can paint. Sparkle's controller is constructed stopped; a visible interactive launch starts it only after signature-schedule reconciliation and the initial Finder/background route drain complete. Hidden-Dock interactive launches, scheduled scans, and scheduled signature updates do not auto-start Sparkle, so they cannot surface first-run app-update consent unexpectedly; an explicit Check for Updates command starts the controller on demand. Scheduled signature updates never create a controller, remain in accessory mode, and run in a separate delegate-owned task that is not cancelled with a view lifecycle. Main-window title, identifier, size, style, and close/reopen behavior are AppKit-owned; repeated routes cannot create a second window.

### Local notifications

`NotificationManager` wraps `UNUserNotificationCenter` behind an injectable protocol and installs a retained delegate during initialization so authorized alerts remain visible while the app is active. `AppState` maps completed scans, detections, signature-update results, clean automatic download scans, and scheduled-scan starts into local notification requests. The master notification preference gates every request; detection sounds and clean-download notices have separate preferences.

Notification content is intentionally summary-only. It includes counts and generic outcomes but excludes file names, filesystem paths, threat signatures, schedule names, and raw process errors. Permission state and safe delivery errors are surfaced in Settings. macOS remains the final authority on whether an authorized request is displayed.

## Local state

| Data | Default location | Lifetime |
| --- | --- | --- |
| Settings | `~/Library/Application Support/SafeMac AV/settings.json` | Persistent; validated legacy data is copied once and retained at its original path |
| Scheduled-job definitions | `~/Library/Application Support/SafeMac AV/scheduled_jobs.json` | Persistent; validated legacy data is copied once and retained at its original path |
| Finder request queue | App-group container `CQPH8YR62A.com.newtonlorenz.SafeMacAV` | Atomically claimed before waiting, recovered after restart, and acknowledged after scan admission; invalid records are removed during validation |
| LaunchAgent definitions | `~/Library/LaunchAgents/com.newtonlorenz.SafeMacAV.scan.*.plist` | Until job removal |
| Signature-update LaunchAgent | `~/Library/LaunchAgents/com.newtonlorenz.SafeMacAV.signature-update.plist` | Until automatic updates are disabled |
| Embedded helper login item | macOS System Settings › General › Login Items | Until disabled by the user or app |
| Background work leases | `~/Library/Application Support/SafeMac AV/*.lock` | Held only while work runs |
| Quarantine payload and metadata | `~/.clamav-quarantine/` | Until restore or deletion |
| Scan history and application logs | Process memory | Current app run |
| ClamAV signatures | Homebrew's ClamAV data directory by default | Managed by `freshclam` |

Paths can expose user information and should be redacted from bug reports.

## Trust boundaries

- User-selected files and Finder requests are untrusted inputs.
- Configured scanner executable paths are trusted configuration.
- ClamAV output is external process output and must be parsed defensively.
- Scan paths, threat details, schedule names, and update errors must not cross into local notification content.
- Filesystem mutations can fail between steps and must preserve recoverable state.
- Login-item registration is mediated by macOS `SMAppService`; approval can only be granted by the current user in System Settings. The helper uses a separate bundle identity and does not request notification permission at login.
- The app is not sandboxed, does not request root, and runs processes with the current user's privileges.
- A local source build has not been authenticated by Apple. Signing, hardened runtime, notarization, and stapling are separate release responsibilities.

## Testing strategy

The `ClamAV-GUI` scheme runs unit and integration coverage for configuration migration and validation, argument construction and output parsing, scan coordination, external request persistence, scheduling, login-item state reconciliation and rollback, and quarantine rollback behavior. Services accept test-specific storage URLs or protocols where isolation is necessary.

The `ClamAV-GUI-UI` scheme is a small interactive smoke suite for window creation, sidebar navigation, and the standalone menu-bar controls. It runs locally rather than in hosted CI because macOS UI automation depends on a locally signable test host and a stable logged-in window session. Disabling code signing causes the UI runner to be terminated before test execution.

New behavior should be introduced with a failing test, implemented minimally, then refactored with the full suite green. Security-sensitive filesystem and process behavior needs both success and failure-path coverage.
