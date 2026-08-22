import XCTest
@testable import ClamAV_GUI

final class ScanSchedulerTests: XCTestCase {
    private enum TestError: Error {
        case intentionalWriteFailure
    }

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        try super.tearDownWithError()
    }

    func testLaunchArgumentsUseDurableJobIDOnly() {
        let scheduler = ScanScheduler()
        let job = ScanJob(
            name: "Test Job",
            paths: ["/tmp/one path", "/tmp/two,comma"],
            schedule: .daily9am
        )

        let args = scheduler.launchArguments(for: job, scannerPath: "/Applications/ClamAV-GUI.app/Contents/MacOS/ClamAV-GUI")

        XCTAssertEqual(args, [
            "/Applications/ClamAV-GUI.app/Contents/MacOS/ClamAV-GUI",
            "--scheduled-scan",
            "--job-id",
            job.id.uuidString
        ])
    }

    func testLaunchArgumentsRoundTripWithLaunchModeParser() {
        let scheduler = ScanScheduler()
        let job = ScanJob(
            name: "Round Trip",
            paths: ["/tmp/alpha path", "/tmp/beta,comma"],
            schedule: .daily9am
        )

        let arguments = scheduler.launchArguments(
            for: job,
            scannerPath: "/Applications/ClamAV-GUI.app/Contents/MacOS/ClamAV-GUI"
        )

        let mode = LaunchModeParser.parse(arguments: arguments)

        switch mode {
        case .scheduledScan(let parsedJobID, let paths):
            XCTAssertEqual(parsedJobID, job.id)
            XCTAssertTrue(paths.isEmpty)
        case .interactive:
            XCTFail("Expected launch arguments to parse as scheduled mode")
        case .scheduledSignatureUpdate:
            XCTFail("Expected scheduled scan mode, not signature update mode")
        }
    }

    func testMutationRejectsCorruptMetadataBeforeChangingLaunchAgent() throws {
        let fixture = try makeFixture()
        let originalPlist = Data("original launch agent".utf8)
        let job = makeJob(name: "Existing")
        var updatedJob = job
        updatedJob.name = "Updated"
        try Data("not valid JSON".utf8).write(to: fixture.storageURL)
        try originalPlist.write(to: fixture.plistURL(for: job))
        var launchctlCommands: [String] = []
        let scheduler = ScanScheduler(
            launchAgentsDirectory: fixture.launchAgentsDirectory,
            jobsStorageURL: fixture.storageURL,
            launchctlRunner: { command, _ in launchctlCommands.append(command) }
        )

        XCTAssertThrowsError(try scheduler.updateScheduledScan(updatedJob))
        XCTAssertEqual(try Data(contentsOf: fixture.plistURL(for: job)), originalPlist)
        XCTAssertEqual(launchctlCommands, [])
    }

    func testFailedMetadataWriteRollsBackUpdatedLaunchAgent() throws {
        let fixture = try makeFixture()
        let job = makeJob(name: "Existing")
        var updatedJob = job
        updatedJob.name = "Updated"
        let originalMetadata = try JSONEncoder().encode([job])
        let originalPlist = Data("original launch agent".utf8)
        try originalMetadata.write(to: fixture.storageURL)
        try originalPlist.write(to: fixture.plistURL(for: job))
        var launchctlCommands: [String] = []
        let scheduler = ScanScheduler(
            launchAgentsDirectory: fixture.launchAgentsDirectory,
            jobsStorageURL: fixture.storageURL,
            dataWriter: { data, url, options in
                if url.standardizedFileURL == fixture.storageURL.standardizedFileURL {
                    throw TestError.intentionalWriteFailure
                }
                try data.write(to: url, options: options)
            },
            launchctlRunner: { command, _ in launchctlCommands.append(command) }
        )

        XCTAssertThrowsError(try scheduler.updateScheduledScan(updatedJob)) { error in
            guard case TestError.intentionalWriteFailure = error else {
                return XCTFail("Expected primary metadata write failure, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.storageURL), originalMetadata)
        XCTAssertEqual(try Data(contentsOf: fixture.plistURL(for: job)), originalPlist)
        XCTAssertEqual(launchctlCommands, ["unload", "load", "unload", "load"])
    }

    func testFailedReplacementLoadRestoresExistingJobAndLaunchAgent() throws {
        let fixture = try makeFixture()
        let job = makeJob(name: "Existing")
        var updatedJob = job
        updatedJob.name = "Updated"
        let originalMetadata = try JSONEncoder().encode([job])
        let originalPlist = Data("original launch agent".utf8)
        try originalMetadata.write(to: fixture.storageURL)
        try originalPlist.write(to: fixture.plistURL(for: job))
        var launchctlCommands: [String] = []
        var loadCount = 0
        let scheduler = ScanScheduler(
            launchAgentsDirectory: fixture.launchAgentsDirectory,
            jobsStorageURL: fixture.storageURL,
            launchctlRunner: { command, _ in
                launchctlCommands.append(command)
                if command == "load" {
                    loadCount += 1
                    if loadCount == 1 {
                        throw ScanSchedulerError.launchctlFailed(command: command, status: 5)
                    }
                }
            }
        )

        XCTAssertThrowsError(try scheduler.updateScheduledScan(updatedJob)) { error in
            guard case ScanSchedulerError.launchctlFailed(let command, let status) = error else {
                return XCTFail("Expected primary launchctl failure, got \(error)")
            }
            XCTAssertEqual(command, "load")
            XCTAssertEqual(status, 5)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.storageURL), originalMetadata)
        XCTAssertEqual(try Data(contentsOf: fixture.plistURL(for: job)), originalPlist)
        XCTAssertEqual(launchctlCommands, ["unload", "load", "unload", "load"])
    }

    func testFailedMetadataWriteRollsBackRemovedLaunchAgent() throws {
        let fixture = try makeFixture()
        let job = makeJob(name: "Existing")
        let originalMetadata = try JSONEncoder().encode([job])
        let originalPlist = Data("original launch agent".utf8)
        try originalMetadata.write(to: fixture.storageURL)
        try originalPlist.write(to: fixture.plistURL(for: job))
        var launchctlCommands: [String] = []
        let scheduler = ScanScheduler(
            launchAgentsDirectory: fixture.launchAgentsDirectory,
            jobsStorageURL: fixture.storageURL,
            dataWriter: { data, url, options in
                if url.standardizedFileURL == fixture.storageURL.standardizedFileURL {
                    throw TestError.intentionalWriteFailure
                }
                try data.write(to: url, options: options)
            },
            launchctlRunner: { command, _ in launchctlCommands.append(command) }
        )

        XCTAssertThrowsError(try scheduler.removeScheduledScan(job)) { error in
            guard case TestError.intentionalWriteFailure = error else {
                return XCTFail("Expected primary metadata write failure, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.storageURL), originalMetadata)
        XCTAssertEqual(try Data(contentsOf: fixture.plistURL(for: job)), originalPlist)
        XCTAssertEqual(launchctlCommands, ["unload", "load"])
    }

    func testNonZeroLaunchctlExitFailsCreateAndRemovesNewPlist() throws {
        let fixture = try makeFixture()
        let job = makeJob(name: "New")
        let scheduler = ScanScheduler(
            launchAgentsDirectory: fixture.launchAgentsDirectory,
            jobsStorageURL: fixture.storageURL,
            launchctlExecutableURL: URL(fileURLWithPath: "/usr/bin/false")
        )

        XCTAssertThrowsError(try scheduler.createScheduledScan(job)) { error in
            guard case ScanSchedulerError.launchctlFailed(let command, let status) = error else {
                return XCTFail("Expected launchctl failure, got \(error)")
            }
            XCTAssertEqual(command, "load")
            XCTAssertNotEqual(status, 0)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.plistURL(for: job).path))
        XCTAssertEqual(scheduler.listScheduledScans().count, 0)
    }

    func testSchedulerUsesAtomicWritesForPlistAndMetadata() throws {
        let fixture = try makeFixture()
        let job = makeJob(name: "Atomic")
        var writeOptions: [Data.WritingOptions] = []
        let scheduler = ScanScheduler(
            launchAgentsDirectory: fixture.launchAgentsDirectory,
            jobsStorageURL: fixture.storageURL,
            dataWriter: { data, url, options in
                writeOptions.append(options)
                try data.write(to: url, options: options)
            },
            launchctlRunner: { _, _ in }
        )

        try scheduler.createScheduledScan(job)

        XCTAssertEqual(writeOptions.count, 2)
        XCTAssertTrue(writeOptions.allSatisfy { $0.contains(.atomic) })
    }

    func testScheduledJobsMigrateWithoutDeletingLegacyMetadata() throws {
        let fixture = try makeFixture()
        let job = makeJob(name: "Legacy")
        let legacyData = try JSONEncoder().encode([job])
        try legacyData.write(to: fixture.legacyStorageURL)
        try Data("legacy plist".utf8).write(to: fixture.legacyPlistURL(for: job))
        var operations: [(String, URL)] = []
        let scheduler = ScanScheduler(
            launchAgentsDirectory: fixture.launchAgentsDirectory,
            jobsStorageURL: fixture.storageURL,
            legacyJobsStorageURL: fixture.legacyStorageURL,
            launchctlRunner: { operations.append(($0, $1)) }
        )

        let migratedJobs = scheduler.listScheduledScans()
        XCTAssertEqual(migratedJobs.count, 1)
        XCTAssertEqual(migratedJobs.first?.id, job.id)
        XCTAssertEqual(migratedJobs.first?.name, job.name)
        XCTAssertEqual(try Data(contentsOf: fixture.storageURL), legacyData)
        XCTAssertEqual(try Data(contentsOf: fixture.legacyStorageURL), legacyData)
        XCTAssertEqual(operations.map(\.0), ["unload", "load"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.legacyPlistURL(for: job).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.plistURL(for: job).path))
    }

    func testStartupMigrationFailureRestoresLegacyAgentWithoutDuplicate() throws {
        let fixture = try makeFixture()
        let job = makeJob(name: "Legacy")
        try JSONEncoder().encode([job]).write(to: fixture.legacyStorageURL)
        let legacyData = Data("legacy plist".utf8)
        try legacyData.write(to: fixture.legacyPlistURL(for: job))
        let scheduler = ScanScheduler(
            launchAgentsDirectory: fixture.launchAgentsDirectory,
            jobsStorageURL: fixture.storageURL,
            legacyJobsStorageURL: fixture.legacyStorageURL,
            launchctlRunner: { command, url in
                if command == "load", url == fixture.plistURL(for: job) {
                    throw ScanSchedulerError.launchctlFailed(command: command, status: 5)
                }
            }
        )

        XCTAssertTrue(scheduler.listScheduledScans().isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.legacyPlistURL(for: job)), legacyData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.plistURL(for: job).path))
    }

    func testExistingUnloadedSafeMacAgentIsLoadedBeforeLegacyAgentIsDeleted() throws {
        let fixture = try makeFixture()
        let job = makeJob(name: "Legacy")
        try JSONEncoder().encode([job]).write(to: fixture.legacyStorageURL)
        try Data("legacy plist".utf8).write(to: fixture.legacyPlistURL(for: job))
        let replacementData = Data("existing SafeMac plist".utf8)
        try replacementData.write(to: fixture.plistURL(for: job))
        var operations: [(String, URL)] = []
        let scheduler = ScanScheduler(
            launchAgentsDirectory: fixture.launchAgentsDirectory,
            jobsStorageURL: fixture.storageURL,
            legacyJobsStorageURL: fixture.legacyStorageURL,
            launchAgentLoadedStatusProvider: { _ in false },
            launchctlRunner: { operations.append(($0, $1)) }
        )

        _ = try scheduler.loadScheduledScans()

        XCTAssertEqual(operations.map(\.0), ["unload", "load"])
        XCTAssertEqual(operations.last?.1, fixture.plistURL(for: job))
        XCTAssertEqual(try Data(contentsOf: fixture.plistURL(for: job)), replacementData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.legacyPlistURL(for: job).path))
    }

    func testFailedLoadOfExistingSafeMacAgentRestoresLegacyWithoutDeletingEitherPlist() throws {
        let fixture = try makeFixture()
        let job = makeJob(name: "Legacy")
        try JSONEncoder().encode([job]).write(to: fixture.legacyStorageURL)
        let legacyData = Data("legacy plist".utf8)
        let replacementData = Data("existing SafeMac plist".utf8)
        try legacyData.write(to: fixture.legacyPlistURL(for: job))
        try replacementData.write(to: fixture.plistURL(for: job))
        var operations: [(String, URL)] = []
        let scheduler = ScanScheduler(
            launchAgentsDirectory: fixture.launchAgentsDirectory,
            jobsStorageURL: fixture.storageURL,
            legacyJobsStorageURL: fixture.legacyStorageURL,
            launchAgentLoadedStatusProvider: { _ in false },
            launchctlRunner: { command, url in
                operations.append((command, url))
                if command == "load", url == fixture.plistURL(for: job) {
                    throw ScanSchedulerError.launchctlFailed(command: command, status: 5)
                }
            }
        )

        XCTAssertThrowsError(try scheduler.loadScheduledScans())

        XCTAssertEqual(try Data(contentsOf: fixture.legacyPlistURL(for: job)), legacyData)
        XCTAssertEqual(try Data(contentsOf: fixture.plistURL(for: job)), replacementData)
        XCTAssertEqual(operations.last?.0, "load")
        XCTAssertEqual(operations.last?.1, fixture.legacyPlistURL(for: job))
    }

    func testCreatingJobUnloadsAndRemovesLegacyAgentBeforeLoadingSafeMacAgent() throws {
        let fixture = try makeFixture()
        let job = makeJob(name: "Migrated")
        let legacyData = Data("legacy plist".utf8)
        try legacyData.write(to: fixture.legacyPlistURL(for: job))
        var operations: [(String, URL)] = []
        let scheduler = ScanScheduler(
            launchAgentsDirectory: fixture.launchAgentsDirectory,
            jobsStorageURL: fixture.storageURL,
            launchctlRunner: { operations.append(($0, $1)) }
        )

        try scheduler.createScheduledScan(job)

        XCTAssertEqual(operations.map(\.0), ["unload", "load"])
        XCTAssertEqual(operations.first?.1, fixture.legacyPlistURL(for: job))
        XCTAssertEqual(operations.last?.1, fixture.plistURL(for: job))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.legacyPlistURL(for: job).path))
        let plist = try String(contentsOf: fixture.plistURL(for: job), encoding: .utf8)
        XCTAssertTrue(plist.contains("com.newtonlorenz.SafeMacAV.scan.\(job.id.uuidString)"))
    }

    func testFailedSafeMacAgentLoadRestoresLegacyAgentAndRemovesReplacement() throws {
        let fixture = try makeFixture()
        let job = makeJob(name: "Migrated")
        let legacyData = Data("legacy plist".utf8)
        try legacyData.write(to: fixture.legacyPlistURL(for: job))
        var operations: [(String, URL)] = []
        let scheduler = ScanScheduler(
            launchAgentsDirectory: fixture.launchAgentsDirectory,
            jobsStorageURL: fixture.storageURL,
            launchctlRunner: { command, url in
                operations.append((command, url))
                if command == "load", url == fixture.plistURL(for: job) {
                    throw ScanSchedulerError.launchctlFailed(command: command, status: 5)
                }
            }
        )

        XCTAssertThrowsError(try scheduler.createScheduledScan(job))

        XCTAssertEqual(try Data(contentsOf: fixture.legacyPlistURL(for: job)), legacyData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.plistURL(for: job).path))
        XCTAssertEqual(operations.last?.0, "load")
        XCTAssertEqual(operations.last?.1, fixture.legacyPlistURL(for: job))
    }

    func testListScheduledScansToleratesCorruptMetadata() throws {
        let fixture = try makeFixture()
        try Data("not valid JSON".utf8).write(to: fixture.storageURL)
        let scheduler = ScanScheduler(
            launchAgentsDirectory: fixture.launchAgentsDirectory,
            jobsStorageURL: fixture.storageURL,
            launchctlRunner: { _, _ in }
        )

        XCTAssertEqual(scheduler.listScheduledScans().count, 0)
        XCTAssertThrowsError(try scheduler.loadScheduledScans())
    }

    func testLaunchctlPrintOnlyTreatsKnownMissingStatusesAsUnloaded() throws {
        XCTAssertTrue(try ScanScheduler.loadedState(forPrintStatus: 0))
        XCTAssertFalse(try ScanScheduler.loadedState(forPrintStatus: 3))
        XCTAssertFalse(try ScanScheduler.loadedState(forPrintStatus: 113))
        XCTAssertThrowsError(try ScanScheduler.loadedState(forPrintStatus: 64))
    }

    private func makeJob(name: String) -> ScanJob {
        ScanJob(name: name, paths: ["/tmp/example"], schedule: .daily9am)
    }

    private func makeFixture() throws -> SchedulerFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanSchedulerTests-\(UUID().uuidString)", isDirectory: true)
        let launchAgentsDirectory = root.appendingPathComponent("LaunchAgents", isDirectory: true)
        let storageDirectory = root.appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: storageDirectory.appendingPathComponent("SafeMac AV", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: storageDirectory.appendingPathComponent("ClamAV-GUI", isDirectory: true),
            withIntermediateDirectories: true
        )
        temporaryDirectories.append(root)
        return SchedulerFixture(
            launchAgentsDirectory: launchAgentsDirectory,
            storageURL: storageDirectory.appendingPathComponent("SafeMac AV/scheduled_jobs.json"),
            legacyStorageURL: storageDirectory.appendingPathComponent("ClamAV-GUI/scheduled_jobs.json")
        )
    }
}

private struct SchedulerFixture {
    let launchAgentsDirectory: URL
    let storageURL: URL
    let legacyStorageURL: URL

    func plistURL(for job: ScanJob) -> URL {
        launchAgentsDirectory.appendingPathComponent(
            "com.newtonlorenz.SafeMacAV.scan.\(job.id.uuidString).plist"
        )
    }

    func legacyPlistURL(for job: ScanJob) -> URL {
        launchAgentsDirectory.appendingPathComponent(
            "com.newtonlorenz.ClamAV-GUI.scan.\(job.id.uuidString).plist"
        )
    }
}
