import Foundation

struct ScanHistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let scanType: ScanType
    let filesScanned: Int
    let threatsFound: Int

    init(from report: ScanReport, scanType: ScanType) {
        id = UUID()
        date = report.endTime
        self.scanType = scanType
        filesScanned = report.filesScanned
        threatsFound = report.infectedFiles.count
    }
}

final class ScanHistoryManager: ObservableObject {
    @Published private(set) var entries: [ScanHistoryEntry] = []

    func addEntry(_ entry: ScanHistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > 200 { entries.removeLast(entries.count - 200) }
    }
}
