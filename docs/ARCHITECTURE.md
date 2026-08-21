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
     +------ LaunchAtLoginManager -------------------- SMAppService.mainApp
     +------ NotificationManager --------------------- macOS local notifications

delegate-owned NSWindowController + MenuBarExtra
     |
     +------ shared AppState
     +------ MenuBarManager -------------------------- AppKit activation policy

per-user launchd
     |
     +------ --scheduled-signature-update
                    |
                    +------ application delegate ---- AppState ---- FreshclamRunner
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

`SignatureUpdateScheduler` owns the single per-user LaunchAgent `com.newtonlorenz.ClamAV-GUI.signature-update`. Its property list contains only the current app executable and `--scheduled-signature-update`; configured ClamAV paths remain in app settings rather than launchd arguments. Daily and weekly calendar changes atomically replace the property list using modern per-user `launchctl bootstrap` and `bootout` operations. Reconciliation observes both the property list and launchd's loaded state so it repairs either kind of drift. A failed change restores the previous property list and runtime state; if restoration also fails, the app reports an indeterminate schedule instead of displaying a false enabled or disabled state.

Only the canonical `/Applications/SafeMac AV.app` install automatically reconciles the captured executable path; development, translocated, downloaded, and backup copies cannot take over the installed schedule. A scheduled invocation uses accessory mode, suppresses normal scenes, and runs from an application-delegate-owned task rather than a window lifecycle. It calls the same single-flight `AppState.updateSignatures()` path as manual updates, emits the same privacy-safe local result notification, and exits only after the update completes. If automatic updates were disabled after launchd queued an invocation, it exits without running `freshclam`. Malware-signature updates are distinct from SafeMac AV application updates and from Homebrew-managed ClamAV engine upgrades.

### Quarantine

The default quarantine location is `~/.clamav-quarantine/`. Each payload gets an opaque `.quarantine` filename, while `metadata.json` stores its original path, threat name, file size, timestamp, and SHA-256 hash.

Mutation ordering is transactional:

- quarantine moves the payload, commits metadata atomically, and rolls the move back on metadata failure;
- restore verifies SHA-256, preserves an existing destination as a backup, and rolls all moves back on metadata failure; and
- delete commits metadata first, deletes the payload, and restores the previous metadata if deletion fails.

The quarantine directory is not an encryption or privilege boundary. The current user can inspect or modify it.

### Scheduled scan

`ScanScheduler` persists job definitions in Application Support and writes one property list per enabled job under `~/Library/LaunchAgents/`. The LaunchAgent starts the app with a job UUID; the app loads the current stored definition rather than placing user-selected scan paths directly in the property list.

Schedules run in the logged-in user's context. Moving or deleting the built app can invalidate the executable path captured in an existing LaunchAgent.

### Folder monitoring

`FileWatcher` creates an FSEvent stream for configured folders. New or changed files are filtered, deduplicated, and either scanned immediately for configured Downloads behavior or batched. Monitoring exists only for the lifetime of the app process; it is not a privileged on-access scanner.

### Launch at login

`LaunchAtLoginManager` maps `SMAppService.mainApp` into app-level disabled, enabled, approval-required, and unavailable states. The service is injected behind a protocol so registration, failure, and rollback behavior can be tested without changing the current user's Login Items.

`AppState` treats the macOS service status as authoritative. It reconciles the saved `launchAtLogin` preference at startup and whenever the app becomes active. A toggle first updates the system login item and then atomically saves the matching preference. If persistence fails, the login-item change is rolled back; service and persistence errors remain visible in Settings.

### Finder request

The Finder Sync extension receives the current Finder selection, writes a JSON request when a shared container is available, posts a distributed notification as a wake signal, and opens the main app when necessary. The main app drains requests serially and submits them through the same scan coordinator as interactive scans.

A distributable build must sign the app and extension consistently and configure the matching app group. The notification and bundle identifiers are namespaced to the upstream project and must change together in a fork.

### Standalone menu-bar operation

The app uses a persistent SwiftUI `MenuBarExtra` as its only scene. The application delegate lazily owns one AppKit `NSWindowController`, whose `NSHostingController` embeds `ContentView` with the exact same `AppState` used by the menu-bar surface. The retained controller gives startup, menu-bar Open, Settings, close/reopen, and Dock reopen one authoritative window identity instead of relying on SwiftUI scene materialization timing. The menu-bar surface can also start a quick scan, update signatures, and quit the app.

`MenuBarManager` isolates AppKit activation-policy changes behind a testable protocol. The app declares `LSUIElement` so background and scheduled launches never acquire a transient Dock item before the delegate runs. During launch, the persisted `hideFromDock` preference still selects `.accessory` to remain hidden or promotes an interactive app to `.regular` before launch finishes. An app-lifetime settings observation keeps that policy reversible even when no main window exists. Visible interactive launches and scheduled scans synchronously create and present the retained main controller, then yield one main-run-loop turn before maintenance or scan work begins so the window can paint. Hidden-Dock interactive launches create no initial window but can open the same controller from the menu bar. Scheduled signature updates never create a controller, remain in accessory mode, and run in a separate delegate-owned task that is not cancelled with a view lifecycle. Main-window title, identifier, size, style, and close/reopen behavior are AppKit-owned; repeated routes cannot create a second window.

### Local notifications

`NotificationManager` wraps `UNUserNotificationCenter` behind an injectable protocol and installs a retained delegate during initialization so authorized alerts remain visible while the app is active. `AppState` maps completed scans, detections, signature-update results, clean automatic download scans, and scheduled-scan starts into local notification requests. The master notification preference gates every request; detection sounds and clean-download notices have separate preferences.

Notification content is intentionally summary-only. It includes counts and generic outcomes but excludes file names, filesystem paths, threat signatures, schedule names, and raw process errors. Permission state and safe delivery errors are surfaced in Settings. macOS remains the final authority on whether an authorized request is displayed.

## Local state

| Data | Default location | Lifetime |
| --- | --- | --- |
| Settings | `~/Library/Application Support/ClamAV-GUI/settings.json` | Persistent |
| Scheduled-job definitions | `~/Library/Application Support/ClamAV-GUI/scheduled_jobs.json` | Persistent |
| Finder request queue | App-group container when configured, otherwise Application Support | Drained after processing |
| LaunchAgent definitions | `~/Library/LaunchAgents/com.newtonlorenz.ClamAV-GUI.scan.*.plist` | Until job removal |
| Signature-update LaunchAgent | `~/Library/LaunchAgents/com.newtonlorenz.ClamAV-GUI.signature-update.plist` | Until automatic updates are disabled |
| Main-app login item | macOS System Settings › General › Login Items | Until disabled by the user or app |
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
- Login-item registration is mediated by macOS `SMAppService`; approval can only be granted by the current user in System Settings.
- The app is not sandboxed, does not request root, and runs processes with the current user's privileges.
- A local source build has not been authenticated by Apple. Signing, hardened runtime, notarization, and stapling are separate release responsibilities.

## Testing strategy

The `ClamAV-GUI` scheme runs unit and integration coverage for configuration migration and validation, argument construction and output parsing, scan coordination, external request persistence, scheduling, login-item state reconciliation and rollback, and quarantine rollback behavior. Services accept test-specific storage URLs or protocols where isolation is necessary.

The `ClamAV-GUI-UI` scheme is a small interactive smoke suite for window creation, sidebar navigation, and the standalone menu-bar controls. It runs locally rather than in hosted CI because macOS UI automation depends on a locally signable test host and a stable logged-in window session. Disabling code signing causes the UI runner to be terminated before test execution.

New behavior should be introduced with a failing test, implemented minimally, then refactored with the full suite green. Security-sensitive filesystem and process behavior needs both success and failure-path coverage.
