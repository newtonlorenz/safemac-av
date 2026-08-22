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
            return "macOS did not find the login item registration. Try enabling it again; SafeMac AV will show any registration error."
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
    func migrateLegacyRegistrationIfNeeded() throws
}

extension LaunchAtLoginManaging {
    func migrateLegacyRegistrationIfNeeded() throws {}
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

final class BackgroundLoginItemLaunchAtLoginService: LaunchAtLoginService {
    private let service: SMAppService

    init(identifier: String = BackgroundHelperBundle.bundleIdentifier) {
        service = SMAppService.loginItem(identifier: identifier)
    }

    var serviceStatus: LaunchAtLoginServiceStatus {
        switch service.status {
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
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }
}

enum LaunchAtLoginMigrationError: LocalizedError {
    case helperDidNotRegister
    case legacyRemovalFailed
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case .helperDidNotRegister:
            return "SafeMac AV could not confirm the background login item registration."
        case .legacyRemovalFailed:
            return "SafeMac AV kept the existing login item because the background login item migration could not finish."
        case .rollbackFailed:
            return "SafeMac AV could not safely roll back the login item migration. Review Login Items in System Settings."
        }
    }
}

final class LaunchAtLoginManager: LaunchAtLoginManaging {
    private let service: any LaunchAtLoginService
    private let legacyService: (any LaunchAtLoginService)?
    private let shouldMigrateLegacyRegistration: () -> Bool

    convenience init() {
        self.init(
            service: BackgroundLoginItemLaunchAtLoginService(),
            legacyService: MainAppLaunchAtLoginService(),
            shouldMigrateLegacyRegistration: {
                Self.isCanonicalInstalledBundle(at: Bundle.main.bundleURL)
            }
        )
    }

    init(
        service: any LaunchAtLoginService,
        legacyService: (any LaunchAtLoginService)? = nil,
        shouldMigrateLegacyRegistration: @escaping () -> Bool = { false }
    ) {
        self.service = service
        self.legacyService = legacyService
        self.shouldMigrateLegacyRegistration = shouldMigrateLegacyRegistration
    }

    var status: LaunchAtLoginStatus {
        let helperStatus: LaunchAtLoginStatus
        switch service.serviceStatus {
        case .notRegistered:
            helperStatus = .disabled
        case .enabled:
            helperStatus = .enabled
        case .requiresApproval:
            helperStatus = .requiresApproval
        case .notFound:
            helperStatus = .unavailable
        }
        guard helperStatus == .disabled || helperStatus == .unavailable,
              let legacyService else {
            return helperStatus
        }
        switch legacyService.serviceStatus {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered, .notFound:
            return helperStatus
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try migrateLegacyRegistrationIfNeeded()
            guard service.serviceStatus != .enabled, service.serviceStatus != .requiresApproval else { return }
            try service.register()
        } else {
            try disableAllRegisteredServices()
        }
    }

    private func disableAllRegisteredServices() throws {
        let helperWasRegistered = Self.isRequested(service.serviceStatus)
        let legacyWasRegistered = legacyService.map { Self.isRequested($0.serviceStatus) } ?? false
        guard helperWasRegistered || legacyWasRegistered else { return }

        var helperWasUnregistered = false
        if helperWasRegistered {
            try service.unregister()
            helperWasUnregistered = true
        }

        guard legacyWasRegistered, let legacyService else { return }
        do {
            try legacyService.unregister()
        } catch {
            guard helperWasUnregistered else {
                throw LaunchAtLoginMigrationError.legacyRemovalFailed
            }
            do {
                try service.register()
            } catch {
                throw LaunchAtLoginMigrationError.rollbackFailed
            }
            throw LaunchAtLoginMigrationError.legacyRemovalFailed
        }
    }

    func migrateLegacyRegistrationIfNeeded() throws {
        guard shouldMigrateLegacyRegistration(), let legacyService else { return }
        guard legacyService.serviceStatus == .enabled || legacyService.serviceStatus == .requiresApproval else {
            return
        }

        let didRegisterHelper: Bool
        switch service.serviceStatus {
        case .enabled:
            didRegisterHelper = false
        case .requiresApproval:
            return
        case .notRegistered, .notFound:
            try service.register()
            didRegisterHelper = true
        }

        if service.serviceStatus == .requiresApproval {
            // Retain the legacy registration until the user approves the helper.
            return
        }

        guard service.serviceStatus == .enabled else {
            if didRegisterHelper {
                try? service.unregister()
            }
            throw LaunchAtLoginMigrationError.helperDidNotRegister
        }

        do {
            try legacyService.unregister()
        } catch {
            guard didRegisterHelper else {
                throw LaunchAtLoginMigrationError.legacyRemovalFailed
            }
            do {
                try service.unregister()
            } catch {
                throw LaunchAtLoginMigrationError.rollbackFailed
            }
            throw LaunchAtLoginMigrationError.legacyRemovalFailed
        }
    }

    static func isCanonicalInstalledBundle(at bundleURL: URL) -> Bool {
        let canonicalURL = URL(fileURLWithPath: "/Applications/SafeMac AV.app", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return bundleURL.standardizedFileURL.resolvingSymlinksInPath().path == canonicalURL.path
    }

    private static func isRequested(_ serviceStatus: LaunchAtLoginServiceStatus) -> Bool {
        switch serviceStatus {
        case .enabled, .requiresApproval:
            return true
        case .notRegistered, .notFound:
            return false
        }
    }
}
