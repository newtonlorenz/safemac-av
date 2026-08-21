import ServiceManagement

enum LaunchAtLoginStatus: Equatable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable

    var isRequested: Bool {
        switch self {
        case .enabled, .requiresApproval:
            return true
        case .disabled, .unavailable:
            return false
        }
    }

    var title: String {
        switch self {
        case .disabled:
            return "Off"
        case .enabled:
            return "On"
        case .requiresApproval:
            return "Approval required"
        case .unavailable:
            return "Unavailable"
        }
    }

    var detail: String? {
        switch self {
        case .requiresApproval:
            return "Allow SafeMac AV in System Settings › General › Login Items to finish enabling it."
        case .unavailable:
            return "This build cannot register SafeMac AV as a login item."
        case .disabled, .enabled:
            return nil
        }
    }

    var symbolName: String {
        switch self {
        case .enabled:
            return "checkmark.circle.fill"
        case .requiresApproval:
            return "exclamationmark.triangle.fill"
        case .disabled:
            return "circle"
        case .unavailable:
            return "xmark.circle"
        }
    }
}

enum LaunchAtLoginServiceStatus {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

protocol LaunchAtLoginService: AnyObject {
    var serviceStatus: LaunchAtLoginServiceStatus { get }
    func register() throws
    func unregister() throws
}

protocol LaunchAtLoginManaging {
    var status: LaunchAtLoginStatus { get }
    func setEnabled(_ enabled: Bool) throws
}

final class MainAppLaunchAtLoginService: LaunchAtLoginService {
    var serviceStatus: LaunchAtLoginServiceStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered:
            return .notRegistered
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .notFound
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

final class LaunchAtLoginManager: LaunchAtLoginManaging {
    private let service: any LaunchAtLoginService

    init(service: any LaunchAtLoginService = MainAppLaunchAtLoginService()) {
        self.service = service
    }

    var status: LaunchAtLoginStatus {
        switch service.serviceStatus {
        case .notRegistered:
            return .disabled
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard !status.isRequested else { return }
            try service.register()
        } else {
            guard status.isRequested else { return }
            try service.unregister()
        }
    }
}
