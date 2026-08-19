import Foundation

struct ExternalScanRequest: Codable, Equatable, Identifiable {
    let id: UUID
    let createdAt: Date
    let paths: [String]
    let source: String
}

final class ExternalScanRequestStore {
    private let queueURL: URL
    private let fileManager: FileManager

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
        let normalizedPaths = Array(Set(paths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        let request = ExternalScanRequest(id: UUID(), createdAt: Date(), paths: normalizedPaths, source: source)
        let data = try JSONEncoder().encode(request)
        try data.write(to: queueURL.appendingPathComponent("\(request.id.uuidString).json"), options: .atomic)
        return request
    }

    func drainRequests() throws -> [ExternalScanRequest] {
        guard fileManager.fileExists(atPath: queueURL.path) else { return [] }

        let files = try fileManager.contentsOfDirectory(
            at: queueURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }

        var requests: [ExternalScanRequest] = []
        for file in files {
            do {
                let data = try Data(contentsOf: file)
                requests.append(try JSONDecoder().decode(ExternalScanRequest.self, from: data))
                try fileManager.removeItem(at: file)
            } catch {
                try? fileManager.removeItem(at: file)
                throw error
            }
        }
        return requests.sorted { $0.createdAt < $1.createdAt }
    }
}
