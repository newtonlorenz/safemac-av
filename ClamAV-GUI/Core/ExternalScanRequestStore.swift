import Foundation

struct ExternalScanRequest: Codable, Equatable, Identifiable {
    let id: UUID
    let createdAt: Date
    let paths: [String]
    let source: String
}

final class ExternalScanRequestStore {
    static let appGroupIdentifier = "CQPH8YR62A.com.newtonlorenz.SafeMacAV"
    static let finderSource = "finder"
    static let scanRequestNotificationName = NSNotification.Name("com.newtonlorenz.SafeMacAV.scanRequest")
    static let scanRequestFailedNotificationName = NSNotification.Name("com.newtonlorenz.SafeMacAV.scanRequestFailed")

    private static let maxQueuedRequests = 25
    private static let maxPathsPerRequest = 64
    private static let maxPathLength = 4_096
    private static let maxRequestBytes = 64 * 1024
    private static let maxRequestAge: TimeInterval = 5 * 60
    private static let maxClockSkew: TimeInterval = 60

    private let queueURL: URL?
    private let fileManager: FileManager
    private let now: () -> Date
    private let beforePublishingRequest: ((URL) throws -> Void)?

    init(
        baseURL: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        appGroupContainerResolver: ((String) -> URL?)? = nil,
        beforePublishingRequest: ((URL) throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.now = now
        self.beforePublishingRequest = beforePublishingRequest

        if let baseURL {
            self.queueURL = baseURL.appendingPathComponent("external-scan-requests", isDirectory: true)
        } else {
            let appGroupURL = if let appGroupContainerResolver {
                appGroupContainerResolver(Self.appGroupIdentifier)
            } else {
                fileManager.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier)
            }
            self.queueURL = appGroupURL?.appendingPathComponent("external-scan-requests", isDirectory: true)
        }
    }

    @discardableResult
    func enqueue(paths: [String], source: String) throws -> ExternalScanRequest {
        let queueURL = try resolvedQueueURL()
        try prepareQueueDirectory(at: queueURL)
        _ = try load(files: queuedRequestFiles(at: queueURL))
        guard try queuedRequestFiles(at: queueURL).count < Self.maxQueuedRequests else {
            throw ExternalScanRequestStoreError.queueFull
        }

        let normalizedPaths = try Self.normalizedPaths(paths)
        let normalizedSource = try Self.normalizedSource(source)
        let request = ExternalScanRequest(
            id: UUID(),
            createdAt: now(),
            paths: normalizedPaths,
            source: normalizedSource
        )
        let data = try JSONEncoder().encode(request)
        guard data.count <= Self.maxRequestBytes else {
            throw ExternalScanRequestStoreError.requestTooLarge
        }

        let stagingURL = queueURL.appendingPathComponent(".\(request.id.uuidString).tmp")
        let requestURL = queueURL.appendingPathComponent("\(request.id.uuidString).json")
        do {
            try data.write(to: stagingURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagingURL.path)
            try beforePublishingRequest?(stagingURL)
            try fileManager.moveItem(at: stagingURL, to: requestURL)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
        return request
    }

    func loadRequest(id: UUID) throws -> [ExternalScanRequest] {
        let queueURL = try resolvedQueueURL()
        guard fileManager.fileExists(atPath: queueURL.path) else { return [] }
        try validateQueueDirectory(at: queueURL)

        let file = queueURL.appendingPathComponent("\(id.uuidString).json")
        guard fileManager.fileExists(atPath: file.path) else { return [] }
        return try load(files: [file])
    }

    func loadRequests() throws -> [ExternalScanRequest] {
        let queueURL = try resolvedQueueURL()
        guard fileManager.fileExists(atPath: queueURL.path) else { return [] }
        try validateQueueDirectory(at: queueURL)

        let files = try queuedRequestFiles(at: queueURL)
        return try load(files: files)
    }

    func claimRequest(id: UUID) throws -> [ExternalScanRequest] {
        let queueURL = try resolvedQueueURL()
        guard fileManager.fileExists(atPath: queueURL.path) else { return [] }
        try validateQueueDirectory(at: queueURL)

        let requestURL = queueURL.appendingPathComponent("\(id.uuidString).json")
        let claimURL = queueURL.appendingPathComponent("\(id.uuidString).claim")
        let isNewClaim = fileManager.fileExists(atPath: requestURL.path)
        if isNewClaim {
            try fileManager.moveItem(at: requestURL, to: claimURL)
        }
        guard fileManager.fileExists(atPath: claimURL.path) else { return [] }
        return try load(files: [claimURL], requiresFreshness: isNewClaim)
    }

    func claimRequests() throws -> [ExternalScanRequest] {
        let queueURL = try resolvedQueueURL()
        guard fileManager.fileExists(atPath: queueURL.path) else { return [] }
        try validateQueueDirectory(at: queueURL)

        let recoveredClaims = try claimedRequestFiles(at: queueURL)
        var newClaims: [URL] = []
        for requestURL in try queuedRequestFiles(at: queueURL) {
            let claimURL = requestURL.deletingPathExtension().appendingPathExtension("claim")
            try fileManager.moveItem(at: requestURL, to: claimURL)
            newClaims.append(claimURL)
        }
        return try (
            load(files: recoveredClaims, requiresFreshness: false)
                + load(files: newClaims, requiresFreshness: true)
        ).sorted { $0.createdAt < $1.createdAt }
    }

    func acknowledgeRequest(id: UUID) throws {
        try removeRequestFile(id: id, pathExtension: "json")
    }

    func acknowledgeClaim(id: UUID) throws {
        try removeRequestFile(id: id, pathExtension: "claim")
    }

    private func removeRequestFile(id: UUID, pathExtension: String) throws {
        let queueURL = try resolvedQueueURL()
        guard fileManager.fileExists(atPath: queueURL.path) else {
            throw ExternalScanRequestStoreError.invalidRequestFile
        }
        try validateQueueDirectory(at: queueURL)

        let requestURL = queueURL.appendingPathComponent("\(id.uuidString).\(pathExtension)")
        guard fileManager.fileExists(atPath: requestURL.path) else {
            throw ExternalScanRequestStoreError.invalidRequestFile
        }
        guard try isSafeRequestFile(requestURL) else {
            throw ExternalScanRequestStoreError.invalidRequestFile
        }
        try fileManager.removeItem(at: requestURL)
    }

    private func load(
        files: [URL],
        requiresFreshness: Bool = true
    ) throws -> [ExternalScanRequest] {
        var requests: [ExternalScanRequest] = []
        for file in files {
            do {
                guard try isSafeRequestFile(file) else {
                    try? fileManager.removeItem(at: file)
                    continue
                }
                let data = try Data(contentsOf: file)
                guard data.count <= Self.maxRequestBytes else {
                    throw ExternalScanRequestStoreError.requestTooLarge
                }
                let decodedRequest = try JSONDecoder().decode(ExternalScanRequest.self, from: data)
                guard !requiresFreshness || isFresh(decodedRequest.createdAt) else {
                    throw ExternalScanRequestStoreError.staleRequest
                }
                guard file.deletingPathExtension().lastPathComponent == decodedRequest.id.uuidString else {
                    throw ExternalScanRequestStoreError.invalidRequestFile
                }
                let normalizedPaths = try Self.normalizedPaths(decodedRequest.paths)
                requests.append(
                    ExternalScanRequest(
                        id: decodedRequest.id,
                        createdAt: decodedRequest.createdAt,
                        paths: normalizedPaths,
                        source: try Self.normalizedSource(decodedRequest.source)
                    )
                )
            } catch {
                try? fileManager.removeItem(at: file)
            }
        }
        return requests.sorted { $0.createdAt < $1.createdAt }
    }

    private func resolvedQueueURL() throws -> URL {
        guard let queueURL else {
            throw ExternalScanRequestStoreError.appGroupUnavailable
        }
        return queueURL
    }

    private func prepareQueueDirectory(at url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  Self.hasExpectedOwner(attributes) else {
                throw ExternalScanRequestStoreError.invalidQueueDirectory
            }
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        try validateQueueDirectory(at: url)
    }

    private func validateQueueDirectory(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ExternalScanRequestStoreError.invalidQueueDirectory
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard Self.hasExpectedOwner(attributes), Self.permissions(in: attributes) == 0o700 else {
            throw ExternalScanRequestStoreError.invalidQueueDirectory
        }
    }

    private func queuedRequestFiles(at url: URL) throws -> [URL] {
        try requestFiles(at: url, pathExtension: "json")
    }

    private func claimedRequestFiles(at url: URL) throws -> [URL] {
        try requestFiles(at: url, pathExtension: "claim")
    }

    private func requestFiles(at url: URL, pathExtension: String) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == pathExtension }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .map { $0 }
    }

    private func isSafeRequestFile(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        guard (values.fileSize ?? 0) <= Self.maxRequestBytes else { return false }
        guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { return false }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard Self.hasExpectedOwner(attributes), Self.permissions(in: attributes) == 0o600 else { return false }
        return true
    }

    private func isFresh(_ createdAt: Date) -> Bool {
        let currentDate = now()
        guard createdAt.timeIntervalSince(currentDate) <= Self.maxClockSkew else { return false }
        return currentDate.timeIntervalSince(createdAt) <= Self.maxRequestAge
    }

    private static func normalizedPaths(_ paths: [String]) throws -> [String] {
        let trimmedPaths = paths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !trimmedPaths.isEmpty else {
            throw ExternalScanRequestStoreError.invalidPaths
        }
        guard trimmedPaths.count <= maxPathsPerRequest else {
            throw ExternalScanRequestStoreError.tooManyPaths
        }

        let normalizedPaths = try trimmedPaths.map { path in
            guard path.first == "/", path.count <= maxPathLength, !path.contains("\0") else {
                throw ExternalScanRequestStoreError.invalidPaths
            }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.isFileURL, url.path.first == "/" else {
                throw ExternalScanRequestStoreError.invalidPaths
            }
            return url.path
        }

        return Array(Set(normalizedPaths)).sorted()
    }

    private static func normalizedSource(_ source: String) throws -> String {
        guard source == finderSource else {
            throw ExternalScanRequestStoreError.invalidSource
        }
        return finderSource
    }

    private static func permissions(in attributes: [FileAttributeKey: Any]) -> Int? {
        guard let permissions = attributes[.posixPermissions] as? NSNumber else { return nil }
        return permissions.intValue & 0o777
    }

    private static func hasExpectedOwner(_ attributes: [FileAttributeKey: Any]) -> Bool {
        guard let ownerID = attributes[.ownerAccountID] as? NSNumber else { return false }
        return ownerID.uint32Value == geteuid()
    }
}

struct FinderScanRequestHandoff {
    static let genericFailureMessage = "SafeMac AV couldn’t receive this scan request. Open SafeMac AV and try again."

    let enqueue: ([String], String) throws -> ExternalScanRequest
    let postWake: (UUID) -> Void
    let presentFailure: (String) -> Void

    @discardableResult
    func submit(paths: [String]) -> Bool {
        do {
            let request = try enqueue(paths, ExternalScanRequestStore.finderSource)
            postWake(request.id)
            return true
        } catch {
            presentFailure(Self.genericFailureMessage)
            return false
        }
    }
}

enum ExternalScanRequestStoreError: LocalizedError, Equatable {
    case appGroupUnavailable
    case invalidQueueDirectory
    case invalidPaths
    case invalidSource
    case invalidRequestFile
    case tooManyPaths
    case queueFull
    case requestTooLarge
    case staleRequest

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "Finder scan handoff is unavailable."
        case .invalidQueueDirectory:
            return "Finder scan handoff storage is invalid."
        case .invalidPaths:
            return "Finder scan request paths are invalid."
        case .invalidSource:
            return "Finder scan request source is invalid."
        case .invalidRequestFile:
            return "Finder scan request storage is invalid."
        case .tooManyPaths:
            return "Finder scan request contains too many paths."
        case .queueFull:
            return "Finder scan request queue is full."
        case .requestTooLarge:
            return "Finder scan request is too large."
        case .staleRequest:
            return "Finder scan request is stale."
        }
    }
}
