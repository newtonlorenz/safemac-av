import Foundation

struct ScanSizeEstimate: Equatable, Sendable {
    let totalFiles: Int
    let totalBytes: Int64
    private let fileSizes: [String: Int64]

    init(fileSizes: [String: Int64]) {
        self.fileSizes = fileSizes
        totalFiles = fileSizes.count
        totalBytes = fileSizes.values.reduce(0, +)
    }

    func fileSize(atPath path: String) -> Int64? {
        fileSizes[URL(fileURLWithPath: path).standardizedFileURL.path]
    }
}

enum ScanSizeEstimator {
    static func estimate(paths: [URL], options: ScanOptions) async -> ScanSizeEstimate {
        await Task.detached(priority: .utility) {
            estimateSynchronously(paths: paths, options: options)
        }.value
    }

    static func estimateSynchronously(paths: [URL], options: ScanOptions) -> ScanSizeEstimate {
        guard !options.reportOnlyInfected, !options.followSymlinks else {
            return ScanSizeEstimate(fileSizes: [:])
        }

        let fileManager = FileManager.default
        var sizes: [String: Int64] = [:]

        for path in paths {
            guard !Task.isCancelled else { break }
            collect(
                path.standardizedFileURL,
                options: options,
                fileManager: fileManager,
                sizes: &sizes
            )
        }

        return ScanSizeEstimate(fileSizes: sizes)
    }

    private static func collect(
        _ root: URL,
        options: ScanOptions,
        fileManager: FileManager,
        sizes: inout [String: Int64]
    ) {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .volumeIdentifierKey
        ]

        guard let rootValues = try? root.resourceValues(forKeys: keys),
              rootValues.isSymbolicLink != true || options.followSymlinks else {
            return
        }

        if rootValues.isRegularFile == true {
            addFile(root, values: rootValues, options: options, sizes: &sizes)
            return
        }

        guard rootValues.isDirectory == true, options.recursive else { return }
        let rootVolume = rootValues.volumeIdentifier.map { String(describing: $0) }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return
        }

        for case let candidate as URL in enumerator {
            guard !Task.isCancelled else { break }
            let standardized = candidate.standardizedFileURL
            guard let values = try? standardized.resourceValues(forKeys: keys) else { continue }

            if isExcluded(standardized.path, patterns: options.excludedPaths) {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isSymbolicLink == true && !options.followSymlinks {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if enumerator.level > options.maxRecursionDepth {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if !options.crossFileSystem,
               let rootVolume,
               values.volumeIdentifier.map({ String(describing: $0) }) != rootVolume {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isRegularFile == true {
                addFile(standardized, values: values, options: options, sizes: &sizes)
            }
        }
    }

    private static func addFile(
        _ file: URL,
        values: URLResourceValues,
        options: ScanOptions,
        sizes: inout [String: Int64]
    ) {
        guard !isExcluded(file.path, patterns: options.excludedPaths),
              let size = values.fileSize.map(Int64.init),
              size <= Int64(options.maxFileSize) * 1_048_576 else {
            return
        }
        sizes[file.standardizedFileURL.path] = max(0, size)
    }

    private static func isExcluded(_ path: String, patterns: [String]) -> Bool {
        patterns.contains { pattern in
            guard !pattern.isEmpty else { return false }
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                return path.localizedStandardContains(pattern)
            }
            let range = NSRange(path.startIndex..<path.endIndex, in: path)
            return expression.firstMatch(in: path, range: range) != nil
        }
    }
}

enum ScanProgressEstimate {
    static func estimatedTimeRemaining(
        bytesScanned: Int64,
        totalBytes: Int64,
        elapsedTime: TimeInterval
    ) -> TimeInterval? {
        guard bytesScanned > 0,
              totalBytes > bytesScanned,
              elapsedTime > 0 else {
            return nil
        }

        let bytesPerSecond = Double(bytesScanned) / elapsedTime
        guard bytesPerSecond > 0 else { return nil }
        return Double(totalBytes - bytesScanned) / bytesPerSecond
    }
}
