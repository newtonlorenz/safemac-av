import Foundation
import Darwin

protocol ClamAVRunnerProtocol {
    func scan(paths: [URL], options: ScanOptions, progressHandler: @escaping (ScanProgress) -> Void) async throws -> ScanReport
    func cancelCurrentScan()
    func pauseScan()
    func resumeScan()
    var currentProcessPID: Int32? { get }
    var scanIsPaused: Bool { get }
}

final class ClamAVRunner: ClamAVRunnerProtocol {
    private let configManager: ConfigManagerProtocol
    private let processLock = NSLock()
    private var currentProcess: Process?
    private var isCancelled = false
    private var processPID: Int32?
    private var isPaused = false

    var currentProcessPID: Int32? { withProcessLock { processPID } }
    var scanIsPaused: Bool { withProcessLock { isPaused } }

    private func withProcessLock<T>(_ operation: () throws -> T) rethrows -> T {
        processLock.lock()
        defer { processLock.unlock() }
        return try operation()
    }

    init(configManager: ConfigManagerProtocol) {
        self.configManager = configManager
    }

    func scan(paths: [URL], options: ScanOptions, progressHandler: @escaping (ScanProgress) -> Void) async throws -> ScanReport {
        withProcessLock { isCancelled = false }
        let settings = configManager.loadSettings()
        let startTime = Date()
        let backend = scannerBackend(for: settings, paths: paths, options: options)

        guard FileManager.default.isExecutableFile(atPath: backend.executablePath) else {
            throw ClamAVError.executableNotFound(backend.executablePath)
        }

        let process = Process()
        withProcessLock { currentProcess = process }
        if settings.lowImpactMode {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
            process.arguments = ["-n", "10", backend.executablePath] + backend.arguments
        } else {
            process.executableURL = URL(fileURLWithPath: backend.executablePath)
            process.arguments = backend.arguments
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let outputState = ClamAVScanOutputState()

        let stdoutReader = ProcessOutputReader(handle: stdoutPipe.fileHandleForReading) { data in
            outputState.appendStdout(data, startTime: startTime, progressHandler: progressHandler)
        }
        let stderrReader = ProcessOutputReader(handle: stderrPipe.fileHandleForReading) { data in
            outputState.appendStderr(data)
        }
        stdoutReader.start()
        stderrReader.start()

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { [weak self] proc in
                stdoutReader.finish()
                stderrReader.finish()
                let cancelled = self?.withProcessLock {
                    self?.currentProcess = nil
                    self?.processPID = nil
                    self?.isPaused = false
                    return self?.isCancelled == true
                } ?? false

                if cancelled {
                    continuation.resume(throwing: ClamAVError.cancelled)
                    return
                }

                outputState.flushStdout(startTime: startTime, progressHandler: progressHandler)
                let snapshot = outputState.snapshot()

                guard proc.terminationReason == .exit else {
                    continuation.resume(throwing: ClamAVError.scanFailed(
                        exitCode: proc.terminationStatus,
                        message: "Scanner terminated by signal \(proc.terminationStatus)."
                    ))
                    return
                }

                let completionState = Self.completionState(
                    forExitCode: proc.terminationStatus,
                    infectedCount: snapshot.1.count
                )
                guard completionState != .scanError else {
                    let message = (snapshot.2.first ?? "clamscan exited with status \(proc.terminationStatus)")
                    continuation.resume(throwing: ClamAVError.scanFailed(exitCode: proc.terminationStatus, message: message))
                    return
                }

                let report = ScanReport(
                    startTime: startTime,
                    endTime: Date(),
                    filesScanned: snapshot.0,
                    infectedFiles: snapshot.1,
                    errors: snapshot.2,
                    scanPaths: paths,
                    exitCode: proc.terminationStatus,
                    completionState: completionState
                )
                continuation.resume(returning: report)
            }

            do {
                try withProcessLock {
                    guard !isCancelled else { throw ClamAVError.cancelled }
                    try process.run()
                    processPID = process.processIdentifier
                }
                // Send initial scanning status so UI updates from "Preparing"
                DispatchQueue.main.async {
                    progressHandler(ScanProgress(
                        status: .scanning,
                        currentFile: nil,
                        filesScanned: 0,
                        infectedCount: 0,
                        startTime: startTime
                    ))
                }
            } catch {
                stdoutReader.stop()
                stderrReader.stop()
                withProcessLock {
                    currentProcess = nil
                    processPID = nil
                    isPaused = false
                }
                if case ClamAVError.cancelled = error {
                    continuation.resume(throwing: ClamAVError.cancelled)
                } else {
                    continuation.resume(throwing: ClamAVError.processStartFailed(error.localizedDescription))
                }
            }
        }
    }

    func cancelCurrentScan() {
        withProcessLock {
            isCancelled = true
            guard let process = currentProcess, process.isRunning else { return }
            process.terminate()
            // A stopped process cannot act on SIGTERM until it continues.
            if isPaused {
                kill(process.processIdentifier, SIGCONT)
            }
            isPaused = false
            // Retain the process and PID until termination actually completes.
        }
    }

    func pauseScan() {
        withProcessLock {
            guard !isCancelled, let pid = processPID else { return }
            if kill(pid, SIGSTOP) == 0 { isPaused = true }
        }
    }

    func resumeScan() {
        withProcessLock {
            guard let pid = processPID else { return }
            if kill(pid, SIGCONT) == 0 { isPaused = false }
        }
    }

    private func scannerBackend(for settings: AppSettings, paths: [URL], options: ScanOptions) -> (executablePath: String, arguments: [String]) {
        if settings.scannerBackend == .clamdscan && settings.clamdSettings.isEnabled {
            return (
                settings.clamdSettings.clamdScanPath,
                buildClamdscanArguments(paths: paths, options: options, settings: settings)
            )
        }

        var effectiveOptions = options
        if effectiveOptions.databasePath?.isEmpty != false {
            effectiveOptions.databasePath = settings.signatureDirectory
        }
        var seenExclusions = Set<String>()
        effectiveOptions.excludedPaths = (options.excludedPaths + settings.allExclusions).filter {
            seenExclusions.insert($0).inserted
        }

        return (
            settings.clamScanPath,
            Self.buildClamscanArguments(paths: paths, options: effectiveOptions)
        )
    }

    private func buildClamdscanArguments(paths: [URL], options: ScanOptions, settings: AppSettings) -> [String] {
        var args = ["--stdout", "--no-summary", "--multiscan", "--wait"]

        let clamdConfig = URL(fileURLWithPath: settings.configDirectory).appendingPathComponent("clamd.conf")
        if FileManager.default.fileExists(atPath: clamdConfig.path) {
            args.append("--config-file=\(clamdConfig.path)")
        }

        if options.reportOnlyInfected {
            args.append("--infected")
        }

        for path in paths {
            args.append(path.path)
        }

        return args
    }

    static func buildClamscanArguments(paths: [URL], options: ScanOptions) -> [String] {
        var args: [String] = []

        if options.recursive {
            args.append("-r")
        }

        if options.followSymlinks {
            args.append("--follow-dir-symlinks=1")
            args.append("--follow-file-symlinks=1")
        } else {
            args.append("--follow-dir-symlinks=0")
            args.append("--follow-file-symlinks=0")
        }

        args.append("--scan-archive=\(options.scanArchives ? "yes" : "no")")

        args.append("--max-filesize=\(options.maxFileSize)M")
        args.append("--max-scansize=\(options.maxScanSize)M")
        args.append("--max-dir-recursion=\(options.maxRecursionDepth)")

        if options.maxScanTime > 0 {
            args.append("--max-scantime=\(options.maxScanTime * 1000)")
        }

        args.append("--heuristic-alerts=\(options.heuristicAlerts ? "yes" : "no")")
        args.append("--alert-encrypted=\(options.alertEncryptedArchives ? "yes" : "no")")
        args.append("--cross-fs=\(options.crossFileSystem ? "yes" : "no")")

        if options.detectPUA {
            args.append("--detect-pua=yes")
        }

        if options.reportOnlyInfected {
            args.append("--infected")
        }

        if let databasePath = options.databasePath, !databasePath.isEmpty {
            args.append("--database=\(databasePath)")
        }

        for exclusion in options.excludedPaths {
            args.append("--exclude=\(exclusion)")
            args.append("--exclude-dir=\(exclusion)")
        }

        // Don't use --infected flag - we need output for progress updates
        // clamscan will output "file: OK" for clean files

        for path in paths {
            args.append(path.path)
        }

        return args
    }

    static func completionState(forExitCode exitCode: Int32, infectedCount: Int) -> ScanCompletionState {
        switch exitCode {
        case 0:
            return infectedCount > 0 ? .infectedFound : .success
        case 1:
            return .infectedFound
        default:
            return .scanError
        }
    }

    static func parseInfectedLine(_ line: String) -> ScanResult? {
        guard line.hasSuffix(" FOUND"),
              let delimiterRange = line.range(of: ": ", options: .backwards) else {
            return nil
        }

        let path = String(line[..<delimiterRange.lowerBound])
        let threatWithSuffix = line[delimiterRange.upperBound...]
        let threat = String(threatWithSuffix.dropLast(" FOUND".count))
        guard !path.isEmpty, !threat.isEmpty else { return nil }

        return ScanResult(
            path: path,
            threatName: threat,
            severity: classifyThreat(threat),
            actionTaken: .reported
        )
    }

    static func classifyThreat(_ threatName: String) -> ThreatSeverity {
        let lowerName = threatName.lowercased()

        if lowerName.contains("trojan") || lowerName.contains("backdoor") || lowerName.contains("rootkit") {
            return .critical
        }
        if lowerName.contains("virus") || lowerName.contains("worm") || lowerName.contains("ransom") {
            return .high
        }
        if lowerName.contains("adware") || lowerName.contains("spyware") {
            return .medium
        }
        if lowerName.contains("pua") || lowerName.contains("potentially") {
            return .low
        }

        return .medium
    }

    static func currentFilePath(from line: String) -> String? {
        guard let delimiterRange = line.range(of: ": ", options: .backwards) else {
            return nil
        }

        return String(line[..<delimiterRange.lowerBound])
    }
}

private final class ClamAVScanOutputState: @unchecked Sendable {
    private let lock = NSLock()
    private var infectedFiles: [ScanResult] = []
    private var errors: [String] = []
    private var filesScanned = 0
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()

    func appendStdout(_ data: Data, startTime: Date, progressHandler: @escaping (ScanProgress) -> Void) {
        let updates = lockedProgressUpdates {
            stdoutBuffer.append(data)
            return consumeLines(from: &stdoutBuffer).compactMap {
                processOutputLine($0, startTime: startTime)
            }
        }
        publish(updates: updates, progressHandler: progressHandler)
    }

    func flushStdout(startTime: Date, progressHandler: @escaping (ScanProgress) -> Void) {
        let updates = lockedProgressUpdates {
            let trailingLine = String(decoding: stdoutBuffer, as: UTF8.self)
            stdoutBuffer.removeAll()
            recordError(String(decoding: stderrBuffer, as: UTF8.self))
            stderrBuffer.removeAll()
            return [processOutputLine(trailingLine, startTime: startTime)].compactMap { $0 }
        }
        publish(updates: updates, progressHandler: progressHandler)
    }

    func appendStderr(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        stderrBuffer.append(data)
        for line in consumeLines(from: &stderrBuffer) { recordError(line) }
    }

    private func consumeLines(from buffer: inout Data) -> [String] {
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[..<newline], as: UTF8.self))
            buffer.removeSubrange(...newline)
        }
        return lines
    }

    private func recordError(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && !trimmed.hasPrefix("LibClamAV") { errors.append(trimmed) }
    }

    func snapshot() -> (Int, [ScanResult], [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (filesScanned, infectedFiles, errors)
    }

    private func lockedProgressUpdates(_ work: () -> [ScanProgress]) -> [ScanProgress] {
        lock.lock()
        defer { lock.unlock() }
        return work()
    }

    private func processOutputLine(_ line: String, startTime: Date) -> ScanProgress? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("Scanned files:"),
           let summaryCount = Int(trimmed.dropFirst("Scanned files:".count).trimmingCharacters(in: .whitespaces)),
           summaryCount >= 0 {
            // --infected suppresses clean-file lines, but clamscan still reports
            // the complete total in its final summary.
            filesScanned = max(filesScanned, summaryCount)
        } else if let result = ClamAVRunner.parseInfectedLine(trimmed) {
            infectedFiles.append(result)
            filesScanned += 1
        } else if trimmed.hasSuffix(": OK") || trimmed.hasSuffix(": Empty file") {
            filesScanned += 1
        } else if trimmed.hasSuffix(" ERROR") || trimmed.hasPrefix("ERROR:") {
            recordError(trimmed)
        }

        return ScanProgress(
            status: .scanning,
            currentFile: extractCurrentFile(from: trimmed),
            filesScanned: filesScanned,
            infectedCount: infectedFiles.count,
            startTime: startTime
        )
    }

    private func publish(updates: [ScanProgress], progressHandler: @escaping (ScanProgress) -> Void) {
        for progress in updates {
            DispatchQueue.main.async {
                progressHandler(progress)
            }
        }
    }

    private func extractCurrentFile(from line: String) -> String? {
        ClamAVRunner.currentFilePath(from: line)
    }

}

enum ClamAVError: LocalizedError {
    case executableNotFound(String)
    case processStartFailed(String)
    case cancelled
    case parseError(String)
    case scanFailed(exitCode: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let path):
            return "ClamAV executable not found at: \(path)"
        case .processStartFailed(let reason):
            return "Failed to start scan: \(reason)"
        case .cancelled:
            return "Scan was cancelled"
        case .parseError(let reason):
            return "Failed to parse output: \(reason)"
        case .scanFailed(let exitCode, let message):
            return "Scan failed (exit \(exitCode)): \(message)"
        }
    }
}
