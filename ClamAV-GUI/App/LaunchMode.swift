import Foundation

enum LaunchMode: Equatable {
    case interactive
    case scheduledScan(jobID: UUID?, paths: [URL])
    case scheduledSignatureUpdate

    var isInteractive: Bool {
        if case .interactive = self { return true }
        return false
    }

    var presentsUserInterface: Bool {
        self != .scheduledSignatureUpdate
    }

    func hidesDock(settings: AppSettings, isUITesting: Bool) -> Bool {
        switch self {
        case .interactive, .scheduledScan:
            settings.hideFromDock && !isUITesting
        case .scheduledSignatureUpdate:
            true
        }
    }
}

enum LaunchModeParser {
    static func parse(arguments: [String]) -> LaunchMode {
        if arguments.contains("--scheduled-signature-update") {
            return .scheduledSignatureUpdate
        }
        guard arguments.contains("--scheduled-scan") else { return .interactive }

        var jobID: UUID?
        var paths: [URL] = []
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--job-id" where index + 1 < arguments.count:
                jobID = UUID(uuidString: arguments[index + 1])
                index += 2
            case "--path" where index + 1 < arguments.count:
                paths.append(URL(fileURLWithPath: arguments[index + 1]))
                index += 2
            case "--paths" where index + 1 < arguments.count:
                let splitPaths = arguments[index + 1]
                    .split(separator: ",")
                    .map { URL(fileURLWithPath: String($0)) }
                paths.append(contentsOf: splitPaths)
                index += 2
            default:
                index += 1
            }
        }

        guard jobID != nil || !paths.isEmpty else { return .interactive }
        return .scheduledScan(jobID: jobID, paths: paths)
    }
}
