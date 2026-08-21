import Foundation

struct ExternalScanRequest: Codable, Equatable, Identifiable {
    let id: UUID
    let createdAt: Date
    let paths: [String]
    let source: String
}

final class ExternalScanRequestStore {
    static let finderSource = "finder"

    private let queueURL: URL
    private let fileManager: FileManager
    private let maxPathCount = 128
    private let maxPathLength = 4_096

    init(baseURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager

        if let baseURL {
            self.queueURL = baseURL.appendingPathComponent("external-scan-requests", isDirectory: true)
        } else if let appGroupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: "group.com.newtonlorenz.ClamAV-GUI") {
            self.queueURL = appGroupURL.appendingPathComponent("external-scan-requests", isDirectory: true)
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
            self.queueURL = appSupport
                .appendingPathComponent("ClamAV-GUI", isDirectory: true)
                .appendingPathComponent("external-scan-requests", isDirectory: true)
        }
    }

    @discardableResult
    func enqueue(paths: [String], source: String) throws -> ExternalScanRequest {
        try fileManager.createDirectory(at: queueURL, withIntermediateDirectories: true)
        let normalizedPaths = try validatedPaths(paths)
        let source = try validatedSource(source)
        let request = ExternalScanRequest(id: UUID(), createdAt: Date(), paths: normalizedPaths, source: source)
        let data = try JSONEncoder().encode(request)
        try data.write(to: queueURL.appendingPathComponent("\(request.id.uuidString).json"), options: .atomic)
        return request
    }

    func drainRequest(id: UUID) throws -> [ExternalScanRequest] {
        guard fileManager.fileExists(atPath: queueURL.path) else { return [] }

        let file = queueURL.appendingPathComponent("\(id.uuidString).json")
        guard fileManager.fileExists(atPath: file.path) else { return [] }
        return try drain(files: [file])
    }

    func drainRequests() throws -> [ExternalScanRequest] {
        guard fileManager.fileExists(atPath: queueURL.path) else { return [] }

        let files = try fileManager.contentsOfDirectory(
            at: queueURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }

        return try drain(files: files)
    }

    private func drain(files: [URL]) throws -> [ExternalScanRequest] {
        var requests: [ExternalScanRequest] = []
        for file in files {
            do {
                let data = try Data(contentsOf: file)
                let request = try JSONDecoder().decode(ExternalScanRequest.self, from: data)
                requests.append(try validatedRequest(request))
                try fileManager.removeItem(at: file)
            } catch {
                try? fileManager.removeItem(at: file)
                throw error
            }
        }
        return requests.sorted { $0.createdAt < $1.createdAt }
    }

    private func validatedRequest(_ request: ExternalScanRequest) throws -> ExternalScanRequest {
        ExternalScanRequest(
            id: request.id,
            createdAt: request.createdAt,
            paths: try validatedPaths(request.paths),
            source: try validatedSource(request.source)
        )
    }

    private func validatedPaths(_ paths: [String]) throws -> [String] {
        let normalizedPaths = Array(Set(paths.compactMap { path -> String? in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.hasPrefix("/"),
                  trimmed.count <= maxPathLength else {
                return nil
            }
            return URL(fileURLWithPath: trimmed).standardizedFileURL.path
        })).sorted()

        guard !normalizedPaths.isEmpty else {
            throw ExternalScanRequestStoreError.noValidPaths
        }
        guard normalizedPaths.count <= maxPathCount else {
            throw ExternalScanRequestStoreError.tooManyPaths
        }
        return normalizedPaths
    }

    private func validatedSource(_ source: String) throws -> String {
        guard source == Self.finderSource else {
            throw ExternalScanRequestStoreError.invalidSource
        }
        return source
    }
}

enum ExternalScanRequestStoreError: LocalizedError {
    case noValidPaths
    case tooManyPaths
    case invalidSource

    var errorDescription: String? {
        switch self {
        case .noValidPaths:
            return "External scan request did not contain any valid absolute paths."
        case .tooManyPaths:
            return "External scan request contained too many paths."
        case .invalidSource:
            return "External scan request source is not trusted."
        }
    }
}
