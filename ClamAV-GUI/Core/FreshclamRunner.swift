import Foundation

protocol FreshclamRunnerProtocol {
    func update() async throws -> UpdateResult
    func checkForUpdates() async throws -> Bool
}

final class FreshclamRunner: FreshclamRunnerProtocol {
    private let configManager: ConfigManagerProtocol

    init(configManager: ConfigManagerProtocol) {
        self.configManager = configManager
    }

    func update() async throws -> UpdateResult {
        let settings = configManager.loadSettings()

        guard FileManager.default.isExecutableFile(atPath: settings.freshclamPath) else {
            throw FreshclamError.executableNotFound(settings.freshclamPath)
        }

        let signatureDirectory = URL(fileURLWithPath: settings.signatureDirectory)
        if !FileManager.default.fileExists(atPath: signatureDirectory.path) {
            try FileManager.default.createDirectory(at: signatureDirectory, withIntermediateDirectories: true)
        }

        var args: [String] = []
        let configFile = URL(fileURLWithPath: settings.configDirectory).appendingPathComponent("freshclam.conf")
        if FileManager.default.fileExists(atPath: configFile.path) {
            args.append("--config-file=\(configFile.path)")
        }
        args.append("--stdout")
        args.append("--datadir=\(settings.signatureDirectory)")
        args.append("--verbose")

        let completed = try await runFreshclam(executablePath: settings.freshclamPath, arguments: args)
        return Self.parseUpdateOutput(completed.output, exitCode: completed.exitCode)
    }

    func checkForUpdates() async throws -> Bool {
        let settings = configManager.loadSettings()

        guard FileManager.default.isExecutableFile(atPath: settings.freshclamPath) else {
            throw FreshclamError.executableNotFound(settings.freshclamPath)
        }

        let completed = try await runFreshclam(executablePath: settings.freshclamPath, arguments: ["--version"])
        return completed.exitCode == 0
    }

    private func runFreshclam(executablePath: String, arguments: [String]) async throws -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let outputBuffer = FreshclamOutputBuffer()

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            outputBuffer.append(handle.availableData)
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                outputBuffer.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: (outputBuffer.output, proc.terminationStatus))
            }

            do {
                try process.run()
            } catch {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: FreshclamError.processStartFailed(error.localizedDescription))
            }
        }
    }

    static func parseUpdateOutput(_ output: String, exitCode: Int32) -> UpdateResult {
        let lines = output.components(separatedBy: "\n")

        var mainVersion: String?
        var dailyVersion: String?
        var bytecodeVersion: String?
        var isUpToDate = false
        var didUpdate = false
        var errorMessage: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = trimmed.lowercased()

            if trimmed.contains("main.cvd") || trimmed.contains("main.cld") {
                if let version = extractVersion(from: trimmed) {
                    mainVersion = version
                }
            }

            if trimmed.contains("daily.cvd") || trimmed.contains("daily.cld") {
                if let version = extractVersion(from: trimmed) {
                    dailyVersion = version
                }
            }

            if trimmed.contains("bytecode.cvd") || trimmed.contains("bytecode.cld") {
                if let version = extractVersion(from: trimmed) {
                    bytecodeVersion = version
                }
            }

            if trimmed.contains("is up to date") || trimmed.contains("up-to-date") {
                isUpToDate = true
            }

            if lowercased.contains("updated")
                || lowercased.contains("downloaded")
                || lowercased.contains("database updated")
                || lowercased.contains("daily.cld updated")
                || lowercased.contains("main.cld updated")
                || lowercased.contains("bytecode.cld updated") {
                didUpdate = true
            }

            if lowercased.contains("error") || lowercased.contains("failed") {
                if errorMessage == nil {
                    errorMessage = trimmed
                }
            }
        }

        if exitCode != 0 && errorMessage != nil {
            return .failed(error: errorMessage ?? "Update failed with exit code \(exitCode)")
        }

        if exitCode != 0 && !isUpToDate && !didUpdate {
            let message = errorMessage ?? "Update failed with exit code \(exitCode)"
            return .failed(error: message)
        }

        if isUpToDate && !didUpdate {
            return .alreadyUpToDate()
        }

        return .success(main: mainVersion, daily: dailyVersion, bytecode: bytecodeVersion)
    }

    private static func extractVersion(from line: String) -> String? {
        let patterns = [
            #"version (\d+)"#,
            #"updated \(version: (\d+)"#,
            #"is up to date \(version: (\d+)"#,
            #"bytecode\.cvd database is up-to-date \(version: (\d+)"#,
            #"daily\.cld database is up-to-date \(version: (\d+)"#,
            #"main\.cvd database is up-to-date \(version: (\d+)"#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)),
               let range = Range(match.range(at: 1), in: line) {
                return String(line[range])
            }
        }

        return nil
    }
}

private final class FreshclamOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    var output: String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }

    func append(_ data: Data) {
        guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        text += chunk
        lock.unlock()
    }
}

enum FreshclamError: LocalizedError {
    case executableNotFound(String)
    case processStartFailed(String)
    case configNotFound

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let path):
            return "freshclam executable not found at: \(path)"
        case .processStartFailed(let reason):
            return "Failed to start update: \(reason)"
        case .configNotFound:
            return "freshclam.conf not found"
        }
    }
}
