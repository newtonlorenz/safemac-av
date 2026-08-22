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
            ScoreComponent(title: "Real-time Monitoring", isComplete: monitoringEnabled, points: 15, action: monitoringEnabled ? nil : .enableMonitoring),
            ScoreComponent(title: "Finder Extension", isComplete: finderExtensionEnabled, points: 10, action: finderExtensionEnabled ? nil : .openFinderSettings)
        ]
        return ProtectionScore(score: components.filter(\.isComplete).map(\.points).reduce(0, +), components: components)
    }
}
