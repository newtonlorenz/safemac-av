import Foundation

final class LogManager {
    private(set) var entries: [LogEntry] = []
    private let maxEntries: Int

    init(maxEntries: Int = 1000) {
        self.maxEntries = maxEntries
    }

    func add(_ level: LogLevel, _ message: String) {
        entries.append(LogEntry(timestamp: Date(), level: level, message: message))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }
}
