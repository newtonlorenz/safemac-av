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
        case .interactive, .signatureUpdate:
            XCTFail("Expected launch arguments to parse as scheduled mode")
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

    func testListScheduledScansToleratesCorruptMetadata() throws {
        let fixture = try makeFixture()
        try Data("not valid JSON".utf8).write(to: fixture.storageURL)
        let scheduler = ScanScheduler(
            launchAgentsDirectory: fixture.launchAgentsDirectory,
            jobsStorageURL: fixture.storageURL,
            launchctlRunner: { _, _ in }
        )

        XCTAssertEqual(scheduler.listScheduledScans().count, 0)
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
        temporaryDirectories.append(root)
        return SchedulerFixture(
            launchAgentsDirectory: launchAgentsDirectory,
            storageURL: storageDirectory.appendingPathComponent("scheduled_jobs.json")
        )
    }
}

private struct SchedulerFixture {
    let launchAgentsDirectory: URL
    let storageURL: URL

    func plistURL(for job: ScanJob) -> URL {
        launchAgentsDirectory.appendingPathComponent(
            "com.newtonlorenz.ClamAV-GUI.scan.\(job.id.uuidString).plist"
        )
    }
}
