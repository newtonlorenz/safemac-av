import Foundation

struct ExternalScanRequest: Codable, Equatable, Identifiable {
    let id: UUID
    let createdAt: Date
    let paths: [String]
    let source: String
}

final class ExternalScanRequestStore {
    static let appGroupIdentifier = "group.com.newtonlorenz.ClamAV-GUI"

    private static let maxQueuedRequests = 25
    private static let maxPathsPerRequest = 64
    private static let maxRequestBytes = 64 * 1024
    private static let maxRequestAge: TimeInterval = 5 * 60
    private static let maxClockSkew: TimeInterval = 60

    private let queueURL: URL?
    private let fileManager: FileManager
    private let now: () -> Date

    init(baseURL: URL? = nil, fileManager: FileManager = .default, now: @escaping () -> Date = Date.init) {
        self.fileManager = fileManager
        self.now = now

        if let baseURL {
            self.queueURL = baseURL.appendingPathComponent("external-scan-requests", isDirectory: true)
        } else if let appGroupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier) {
            self.queueURL = appGroupURL.appendingPathComponent("external-scan-requests", isDirectory: true)
        } else {
            self.queueURL = nil
        }
    }

    @discardableResult
    func enqueue(paths: [String], source: String) throws -> ExternalScanRequest {
        let queueURL = try resolvedQueueURL()
        try prepareQueueDirectory(at: queueURL)
        guard try queuedRequestFiles(at: queueURL).count < Self.maxQueuedRequests else {
            throw ExternalScanRequestStoreError.queueFull
        }

        let normalizedPaths = try Self.normalizedPaths(paths)
        let request = ExternalScanRequest(
            id: UUID(),
            createdAt: now(),
            paths: normalizedPaths,
            source: Self.normalizedSource(source)
        )
        let data = try JSONEncoder().encode(request)
        guard data.count <= Self.maxRequestBytes else {
            throw ExternalScanRequestStoreError.requestTooLarge
        }

        let requestURL = queueURL.appendingPathComponent("\(request.id.uuidString).json")
        try data.write(to: requestURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestURL.path)
        return request
    }

    func drainRequests() throws -> [ExternalScanRequest] {
        let queueURL = try resolvedQueueURL()
        guard fileManager.fileExists(atPath: queueURL.path) else { return [] }
        try validateQueueDirectory(at: queueURL)

        let files = try queuedRequestFiles(at: queueURL)

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
                guard isFresh(decodedRequest.createdAt) else {
                    throw ExternalScanRequestStoreError.staleRequest
                }
                let normalizedPaths = try Self.normalizedPaths(decodedRequest.paths)
                requests.append(
                    ExternalScanRequest(
                        id: decodedRequest.id,
                        createdAt: decodedRequest.createdAt,
                        paths: normalizedPaths,
                        source: Self.normalizedSource(decodedRequest.source)
                    )
                )
                try fileManager.removeItem(at: file)
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
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try validateQueueDirectory(at: url)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func validateQueueDirectory(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ExternalScanRequestStoreError.invalidQueueDirectory
        }
    }

    private func queuedRequestFiles(at url: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .map { $0 }
    }

    private func isSafeRequestFile(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        guard (values.fileSize ?? 0) <= Self.maxRequestBytes else { return false }
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
            guard path.first == "/", !path.contains("\0") else {
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

    private static func normalizedSource(_ source: String) -> String {
        source == "finder" ? "finder" : "unknown"
    }
}

enum ExternalScanRequestStoreError: LocalizedError, Equatable {
    case appGroupUnavailable
    case invalidQueueDirectory
    case invalidPaths
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
