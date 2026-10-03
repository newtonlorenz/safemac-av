import Foundation

struct ScanHistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let scanType: ScanType
    let filesScanned: Int
    let threatsFound: Int
    let completedWithoutErrors: Bool
    let report: ScanReport

    init(from report: ScanReport, scanType: ScanType, id: UUID = UUID()) {
        self.report = report
        self.id = id
        date = report.endTime
        self.scanType = scanType
        filesScanned = report.filesScanned
        threatsFound = report.threatsFound
        completedWithoutErrors = report.completedWithoutErrors
    }
}

final class ScanHistoryManager: ObservableObject {
    @Published private(set) var entries: [ScanHistoryEntry] = []

    func updateReport(_ report: ScanReport, matching original: ScanReport) {
        guard let index = entries.firstIndex(where: {
            $0.report.startTime == original.startTime && $0.report.endTime == original.endTime
                && $0.report.scanPaths == original.scanPaths
                && $0.report.infectedFiles.map(\.id) == original.infectedFiles.map(\.id)
        }) else { return }
        let existing = entries[index]
        entries[index] = ScanHistoryEntry(from: report, scanType: existing.scanType, id: existing.id)
    }

    func addEntry(_ entry: ScanHistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > 200 { entries.removeLast(entries.count - 200) }
    }
}
