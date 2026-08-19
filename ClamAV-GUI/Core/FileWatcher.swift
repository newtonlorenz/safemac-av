import Foundation

protocol FileWatcherProtocol: AnyObject {
    func startWatching(directories: [URL], handler: @escaping ([URL]) -> Void)
    func stopWatching()
    func updateConfiguration(batchIntervalMinutes: Int, batchThreshold: Int)
    func configureImmediateScanDirectories(_ directories: [URL])
    var isWatching: Bool { get }
    var onNewFileDetected: ((URL) -> Void)? { get set }
}

final class FileWatcher: FileWatcherProtocol {
    private var eventStream: FSEventStreamRef?
    private var watchedDirectories: [URL] = []
    private var changeHandler: (([URL]) -> Void)?
    private var pendingFiles: Set<URL> = []
    private var immediateScanDirectories: [URL] = []
    private var batchTimer: DispatchSourceTimer?
    private var batchInterval: TimeInterval
    private var batchThreshold: Int
    private let queue = DispatchQueue(label: "com.clamav.filewatcher")
    private let queueKey = DispatchSpecificKey<Void>()

    private(set) var isWatching: Bool = false
    var onNewFileDetected: ((URL) -> Void)?

    init(batchIntervalMinutes: Int = 5, batchThreshold: Int = 10) {
        self.batchInterval = TimeInterval(batchIntervalMinutes * 60)
        self.batchThreshold = batchThreshold
        queue.setSpecific(key: queueKey, value: ())
    }

    func startWatching(directories: [URL], handler: @escaping ([URL]) -> Void) {
        stopWatching()

        let validDirectories = directories.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }

        guard !validDirectories.isEmpty else { return }

        watchedDirectories = validDirectories
        changeHandler = handler

        let pathsToWatch = watchedDirectories.map { $0.path } as CFArray

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)

        guard let stream = FSEventStreamCreate(
            nil,
            { (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
                guard let info = clientCallBackInfo else { return }
                let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.handleEvents(numEvents: numEvents, eventPaths: eventPaths, eventFlags: eventFlags)
            },
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            flags
        ) else {
            return
        }

        eventStream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        isWatching = true

        startBatchTimer()
    }

    func stopWatching() {
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventStream = nil
        }

        performOnQueue {
            batchTimer?.cancel()
            batchTimer = nil
            pendingFiles.removeAll()
        }
        isWatching = false
    }

    func updateConfiguration(batchIntervalMinutes: Int, batchThreshold: Int) {
        performOnQueue {
            self.batchInterval = TimeInterval(max(1, batchIntervalMinutes) * 60)
            self.batchThreshold = max(1, batchThreshold)
        }

        guard isWatching else { return }
        startBatchTimer()
    }

    func configureImmediateScanDirectories(_ directories: [URL]) {
        performOnQueue {
            immediateScanDirectories = Self.uniqueStandardizedDirectories(directories)
        }
    }

    private func handleEvents(numEvents: Int, eventPaths: UnsafeMutableRawPointer, eventFlags: UnsafePointer<FSEventStreamEventFlags>) {
        guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }

        for i in 0..<numEvents {
            let path = paths[i]
            let flags = eventFlags[i]

            let isFile = (flags & UInt32(kFSEventStreamEventFlagItemIsFile)) != 0
            let isCreated = (flags & UInt32(kFSEventStreamEventFlagItemCreated)) != 0
            let isModified = (flags & UInt32(kFSEventStreamEventFlagItemModified)) != 0
            let isRenamed = (flags & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0

            if isFile && (isCreated || isModified || isRenamed) {
                let url = URL(fileURLWithPath: path)

                if shouldScanFile(url) {
                    if immediateScanDirectories.contains(where: { Self.contains(url, in: $0) }) {
                        DispatchQueue.main.async { [weak self] in
                            self?.onNewFileDetected?(url)
                        }
                    } else {
                        pendingFiles.insert(url)

                        if pendingFiles.count >= batchThreshold {
                            flushPendingFiles()
                        }
                    }
                }
            }
        }
    }

    private func shouldScanFile(_ url: URL) -> Bool {
        let filename = url.lastPathComponent

        let ignoredPrefixes = [".", "~"]
        for prefix in ignoredPrefixes {
            if filename.hasPrefix(prefix) { return false }
        }

        let ignoredExtensions = ["tmp", "temp", "part", "crdownload", "download"]
        if ignoredExtensions.contains(url.pathExtension.lowercased()) {
            return false
        }

        let ignoredPatterns = ["node_modules", ".git", "DerivedData", "__pycache__"]
        for pattern in ignoredPatterns {
            if url.path.contains(pattern) { return false }
        }

        return true
    }

    private func startBatchTimer() {
        performOnQueue {
            batchTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + batchInterval, repeating: batchInterval)
            timer.setEventHandler { [weak self] in
                self?.flushPendingFiles()
            }
            batchTimer = timer
            timer.resume()
        }
    }

    private func performOnQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    private static func uniqueStandardizedDirectories(_ directories: [URL]) -> [URL] {
        directories.reduce(into: [URL]()) { result, directory in
            let standardizedDirectory = directory.standardizedFileURL
            if !result.contains(standardizedDirectory) {
                result.append(standardizedDirectory)
            }
        }
    }

    private static func contains(_ file: URL, in directory: URL) -> Bool {
        let filePath = file.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        let directoryPrefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        return filePath == directoryPath || filePath.hasPrefix(directoryPrefix)
    }

    private func flushPendingFiles() {
        guard !pendingFiles.isEmpty else { return }

        let files = Array(pendingFiles)
        pendingFiles.removeAll()

        DispatchQueue.main.async { [weak self] in
            self?.changeHandler?(files)
        }
    }
}
