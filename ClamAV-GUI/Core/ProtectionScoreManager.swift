import Foundation

struct ProtectionScore: Equatable {
    let score: Int
    let components: [ScoreComponent]
}

struct ScoreComponent: Identifiable, Equatable {
    enum Action: Equatable {
        case configureClamAV
        case updateSignatures
        case reviewScan
        case enableMonitoring
        case openFinderSettings
    }

    let id = UUID()
    let title: String
    let isComplete: Bool
    let points: Int
    let action: Action?

    static func == (lhs: ScoreComponent, rhs: ScoreComponent) -> Bool {
        lhs.title == rhs.title && lhs.isComplete == rhs.isComplete && lhs.points == rhs.points && lhs.action == rhs.action
    }
}

final class ProtectionScoreManager {
    private let configManager: ConfigManagerProtocol

    init(configManager: ConfigManagerProtocol) {
        self.configManager = configManager
    }

    func calculateScore(lastScanDate: Date?, monitoringEnabled: Bool, finderExtensionEnabled: Bool) -> ProtectionScore {
        let isInstalled = configManager.validateClamAVInstallation().isInstalled
        let signaturesFresh = {
            guard let updated = configManager.getSignatureInfo().lastUpdated else { return false }
            return Calendar.current.dateComponents([.day], from: updated, to: Date()).day ?? Int.max <= 7
        }()
        let recentScan = {
            guard let lastScanDate else { return false }
            return Calendar.current.dateComponents([.day], from: lastScanDate, to: Date()).day ?? Int.max <= 7
        }()

        let components = [
            ScoreComponent(title: "ClamAV Installed", isComplete: isInstalled, points: 25, action: isInstalled ? nil : .configureClamAV),
            ScoreComponent(title: "Signatures Up to Date", isComplete: signaturesFresh, points: 25, action: signaturesFresh ? nil : .updateSignatures),
            ScoreComponent(title: "Recent Scan", isComplete: recentScan, points: 25, action: recentScan ? nil : .reviewScan),
            ScoreComponent(title: "Folder Monitoring", isComplete: monitoringEnabled, points: 15, action: monitoringEnabled ? nil : .enableMonitoring),
            ScoreComponent(title: "Finder Extension", isComplete: finderExtensionEnabled, points: 10, action: finderExtensionEnabled ? nil : .openFinderSettings)
        ]
        return ProtectionScore(score: components.filter(\.isComplete).map(\.points).reduce(0, +), components: components)
    }
}

/// A capability and outcome summary, never a measure of how safe the Mac is.
struct ScanOverviewStatus: Equatable {
    enum Kind: Equatable { case scanning, updating, setupNeeded, definitionsNeeded, detections, incomplete, ready }
    enum Action: Equatable { case configureEngine, updateDefinitions, reviewScan }

    let kind: Kind
    let title: String
    let detail: String
    let action: Action?

    var symbol: String {
        switch kind {
        case .scanning: return "magnifyingglass"
        case .updating: return "arrow.triangle.2.circlepath"
        case .setupNeeded: return "wrench.and.screwdriver"
        case .definitionsNeeded, .incomplete: return "exclamationmark.triangle"
        case .detections: return "exclamationmark.shield"
        case .ready: return "checkmark.circle"
        }
    }

    var actionTitle: String? {
        switch action {
        case .configureEngine: return "Open engine settings"
        case .updateDefinitions: return "Update definitions"
        case .reviewScan: return "View scan"
        case nil: return nil
        }
    }

    static func resolve(
        installation: ClamAVInstallationStatus,
        isScanning: Bool,
        isPaused: Bool,
        isUpdating: Bool,
        report: ScanReport?,
        scanError: String? = nil
    ) -> ScanOverviewStatus {
        if isScanning {
            return Self(kind: .scanning, title: isPaused ? "Scan paused" : "Scan in progress", detail: isPaused ? "Resume the scan when you are ready." : "You can continue using your Mac while selected files are checked.", action: .reviewScan)
        }
        if let report, report.infectedFiles.contains(where: { $0.actionTaken == .reported || $0.actionTaken == .ignored })
            || report.threatsFound > report.infectedFiles.count {
            return detectionStatus(for: report)
        }
        if isUpdating {
            return Self(kind: .updating, title: "Updating malware definitions", detail: "Downloading the latest detection data for ClamAV.", action: nil)
        }
        switch installation {
        case .notInstalled:
            return Self(kind: .setupNeeded, title: "Set up the scanning engine", detail: "SafeMac AV needs ClamAV installed on this Mac. Install it with Homebrew, then check the engine paths in Settings.", action: .configureEngine)
        case .partialInstall, .clamdUnavailable:
            return Self(kind: .setupNeeded, title: "Check the scanning engine", detail: installation.message, action: .configureEngine)
        case .missingSignatures:
            return Self(kind: .definitionsNeeded, title: "Download malware definitions", detail: "ClamAV is installed. Download its detection data before your first scan.", action: .updateDefinitions)
        case .outdatedSignatures:
            return Self(kind: .definitionsNeeded, title: "Update malware definitions", detail: installation.message, action: .updateDefinitions)
        case .ready:
            break
        }
        if let scanError {
            return Self(kind: .incomplete, title: "Scan needs attention", detail: scanError, action: .reviewScan)
        }
        if let report, report.threatsFound > 0 {
            return detectionStatus(for: report)
        }
        if let report, !report.isClean {
            return Self(kind: .incomplete, title: report.completionState == .cancelled ? "Scan cancelled" : "Scan needs attention", detail: "The last scan did not finish checking all selected files. Review its results before trying again.", action: .reviewScan)
        }
        return Self(kind: .ready, title: "Ready to scan", detail: "Choose files or folders to check locally with ClamAV. Files are not uploaded.", action: nil)
    }

    private static func detectionStatus(for report: ScanReport) -> ScanOverviewStatus {
        let quarantined = report.infectedFiles.filter { $0.actionTaken == .quarantined }.count
        let unresolved = report.infectedFiles.filter { $0.actionTaken == .reported || $0.actionTaken == .ignored }.count
        let unavailable = report.threatsFound - report.infectedFiles.count
        var details = ["\(quarantined) quarantined."]
        if unresolved > 0 {
            details.append("\(unresolved) still reported at their original location. Review the scan results.")
        }
        if unavailable > 0 {
            details.append("File details for \(unavailable) detection\(unavailable == 1 ? "" : "s") are unavailable. Scan these locations again to review them.")
        }
        if unresolved == 0 && unavailable == 0 {
            details.append("Review the scan results for details.")
        }
        let count = report.threatsFound
        return Self(kind: .detections, title: "\(count) detection\(count == 1 ? "" : "s") in the last scan", detail: details.joined(separator: " "), action: .reviewScan)
    }

}
