import Foundation

protocol FreshclamRunnerProtocol {
    func update() async throws -> UpdateResult
    func update(using settings: AppSettings) async throws -> UpdateResult
    func checkForUpdates() async throws -> Bool
}

final class FreshclamRunner: FreshclamRunnerProtocol {
    private let configManager: ConfigManagerProtocol

    init(configManager: ConfigManagerProtocol) {
        self.configManager = configManager
    }

    func update() async throws -> UpdateResult {
        let settings = configManager.loadSettings()
        return try await update(using: settings)
    }

    func update(using settings: AppSettings) async throws -> UpdateResult {
        let invocation: FreshclamInvocation
        do {
            invocation = try FreshclamInvocation.make(
                executablePath: settings.freshclamPath,
                configDirectory: settings.configDirectory,
                signatureDirectory: settings.signatureDirectory
            )
        } catch {
            throw FreshclamError.executableNotFound(settings.freshclamPath)
        }
        let completed = try await runFreshclam(executablePath: invocation.executablePath, arguments: invocation.arguments)
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
        switch FreshclamUpdateOutcome.parse(output: output, exitCode: exitCode) {
        case .updated(let main, let daily, let bytecode):
            return .success(main: main, daily: daily, bytecode: bytecode)
        case .upToDate:
            return .alreadyUpToDate()
        case .failed(let message):
            return .failed(error: message)
        }
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
