import Foundation

struct PerformanceStats: Equatable {
    let cpuUsage: Double
    let memoryUsageMB: Double
    let filesPerSecond: Double
    let estimatedSecondsRemaining: Double?
}

final class PerformanceMonitor {
    private var lastFileCount = 0
    private var lastCheckTime = Date()
    private var recentSpeeds: [Double] = []

    func getStats(for pid: Int32, currentFileCount: Int, totalEstimate: Int?) -> PerformanceStats {
        let cpu = shellDouble(arguments: ["-p", "\(pid)", "-o", "%cpu="])
        let rssKB = shellDouble(arguments: ["-p", "\(pid)", "-o", "rss="])
        let speed = calculateSpeed(currentFileCount: currentFileCount)
        let eta = totalEstimate.flatMap { total -> Double? in
            guard speed > 0, total > currentFileCount else { return nil }
            return Double(total - currentFileCount) / speed
        }
        return PerformanceStats(cpuUsage: cpu, memoryUsageMB: rssKB / 1024, filesPerSecond: speed, estimatedSecondsRemaining: eta)
    }

    func reset() {
        lastFileCount = 0
        lastCheckTime = Date()
        recentSpeeds = []
    }

    private func calculateSpeed(currentFileCount: Int) -> Double {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastCheckTime)
        guard elapsed > 0.5 else { return recentSpeeds.last ?? 0 }

        let speed = Double(max(0, currentFileCount - lastFileCount)) / elapsed
        lastFileCount = currentFileCount
        lastCheckTime = now
        recentSpeeds.append(speed)
        if recentSpeeds.count > 5 { recentSpeeds.removeFirst() }
        return recentSpeeds.reduce(0, +) / Double(recentSpeeds.count)
    }

    private func shellDouble(arguments: [String]) -> Double {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return Double(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        } catch {
            return 0
        }
    }
}
