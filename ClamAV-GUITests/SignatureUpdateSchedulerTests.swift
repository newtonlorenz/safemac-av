import XCTest
@testable import ClamAV_GUI

final class SignatureUpdateSchedulerTests: XCTestCase {
    private enum TestError: Error { case intentionalWriteFailure }
    private let userID: uid_t = 501
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories { try? FileManager.default.removeItem(at: directory) }
        temporaryDirectories = []
        try super.tearDownWithError()
    }

    func testDailyScheduleBootstrapsPrivacySafeLaunchAgentAtomically() throws {
        let fixture = try makeFixture()
        var operations: [SignatureUpdateLaunchctlOperation] = []
        var writeOptions: [Data.WritingOptions] = []
        let scheduler = makeScheduler(
            fixture: fixture,
            dataWriter: { data, url, options in
                writeOptions.append(options)
                try data.write(to: url, options: options)
            },
            launchctlRunner: { operations.append($0) }
        )
        let schedule = ScanSchedule(frequency: .daily, time: DateComponents(hour: 6, minute: 45))

        try scheduler.reconcile(enabled: true, schedule: schedule)

        let plist = try readPlist(at: fixture.plistURL)
        XCTAssertEqual(plist["Label"] as? String, SignatureUpdateScheduler.label)
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [
            "/Applications/SafeMac AV.app/Contents/MacOS/ClamAV-GUI",
            "--scheduled-signature-update"
        ])
        XCTAssertEqual(plist["StartCalendarInterval"] as? [String: Int], ["Hour": 6, "Minute": 45])
        XCTAssertNil(plist["StandardOutPath"])
        XCTAssertNil(plist["StandardErrorPath"])
        XCTAssertEqual(operations, [.bootstrap(domain: domain, plistURL: fixture.plistURL)])
        XCTAssertEqual(writeOptions.count, 1)
        XCTAssertTrue(writeOptions.allSatisfy { $0.contains(.atomic) })
    }

    func testNewLaunchAgentPermissionsAreNormalizedBeforeBootstrap() throws {
        let fixture = try makeFixture()
        let scheduler = makeScheduler(
            fixture: fixture,
            dataWriter: { data, url, options in
                try data.write(to: url, options: options)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o666],
                    ofItemAtPath: url.path
                )
            }
        )

        try scheduler.reconcile(enabled: true, schedule: .daily9am)

        XCTAssertEqual(try permissions(at: fixture.plistURL), 0o644)
    }

    func testWeeklyScheduleIncludesSelectedWeekday() throws {
        let fixture = try makeFixture()
        let scheduler = makeScheduler(fixture: fixture)
        let schedule = ScanSchedule(
            frequency: .weekly,
            time: DateComponents(hour: 12, minute: 5),
            dayOfWeek: 4
        )

        try scheduler.reconcile(enabled: true, schedule: schedule)

        let plist = try readPlist(at: fixture.plistURL)
        XCTAssertEqual(plist["StartCalendarInterval"] as? [String: Int], [
            "Weekday": 4,
            "Hour": 12,
            "Minute": 5
        ])
    }

    func testLoadedReplacementBootsOutOldAgentBeforeBootstrappingReplacement() throws {
        let fixture = try makeFixture()
        let oldData = Data("old plist".utf8)
        try oldData.write(to: fixture.plistURL)
        var operations: [SignatureUpdateLaunchctlOperation] = []
        let scheduler = makeScheduler(
            fixture: fixture,
            isLoaded: true,
            launchctlRunner: { operations.append($0) }
        )

        try scheduler.reconcile(enabled: true, schedule: .daily9am)

        XCTAssertEqual(operations, [
            .bootout(serviceTarget: serviceTarget),
            .bootstrap(domain: domain, plistURL: fixture.plistURL)
        ])
        XCTAssertNotEqual(try Data(contentsOf: fixture.plistURL), oldData)
    }

    func testPresentButUnloadedPlistConvergesWithoutSpuriousBootout() throws {
        let fixture = try makeFixture()
        try Data("stale plist".utf8).write(to: fixture.plistURL)
        var operations: [SignatureUpdateLaunchctlOperation] = []
        let scheduler = makeScheduler(
            fixture: fixture,
            isLoaded: false,
            launchctlRunner: { operations.append($0) }
        )

        try scheduler.reconcile(enabled: true, schedule: .daily9am)

        XCTAssertEqual(operations, [.bootstrap(domain: domain, plistURL: fixture.plistURL)])
    }

    func testLoadedJobWithMissingPlistIsBootedOutAndRecreated() throws {
        let fixture = try makeFixture()
        var operations: [SignatureUpdateLaunchctlOperation] = []
        let scheduler = makeScheduler(
            fixture: fixture,
            isLoaded: true,
            launchctlRunner: { operations.append($0) }
        )

        try scheduler.reconcile(enabled: true, schedule: .daily9am)

        XCTAssertEqual(operations, [
            .bootout(serviceTarget: serviceTarget),
            .bootstrap(domain: domain, plistURL: fixture.plistURL)
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.plistURL.path))
    }

    func testFailedReplacementBootstrapRestoresPreviousLoadedAgent() throws {
        let fixture = try makeFixture()
        let oldData = Data("old plist".utf8)
        try oldData.write(to: fixture.plistURL)
        var operations: [SignatureUpdateLaunchctlOperation] = []
        var bootstrapCount = 0
        let scheduler = makeScheduler(
            fixture: fixture,
            isLoaded: true,
            launchctlRunner: { operation in
                operations.append(operation)
                if case .bootstrap = operation {
                    bootstrapCount += 1
                    if bootstrapCount == 1 {
                        throw SignatureUpdateSchedulerError.launchctlFailed(command: "bootstrap", status: 5)
                    }
                }
            }
        )

        XCTAssertThrowsError(try scheduler.reconcile(enabled: true, schedule: .daily9am))

        XCTAssertEqual(try Data(contentsOf: fixture.plistURL), oldData)
        XCTAssertEqual(operations, [
            .bootout(serviceTarget: serviceTarget),
            .bootstrap(domain: domain, plistURL: fixture.plistURL),
            .bootout(serviceTarget: serviceTarget),
            .bootstrap(domain: domain, plistURL: fixture.plistURL)
        ])
    }

    func testRollbackNormalizesRestoredLaunchAgentPermissions() throws {
        let fixture = try makeFixture()
        let oldData = Data("old plist".utf8)
        try oldData.write(to: fixture.plistURL)
        var bootstrapCount = 0
        let scheduler = makeScheduler(
            fixture: fixture,
            isLoaded: true,
            dataWriter: { data, url, options in
                try data.write(to: url, options: options)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o666],
                    ofItemAtPath: url.path
                )
            },
            launchctlRunner: { operation in
                if case .bootstrap = operation {
                    bootstrapCount += 1
                    if bootstrapCount == 1 {
                        throw SignatureUpdateSchedulerError.launchctlFailed(
                            command: "bootstrap",
                            status: 5
                        )
                    }
                }
            }
        )

        XCTAssertThrowsError(try scheduler.reconcile(enabled: true, schedule: .daily9am))

        XCTAssertEqual(try Data(contentsOf: fixture.plistURL), oldData)
        XCTAssertEqual(try permissions(at: fixture.plistURL), 0o644)
    }

    func testRollbackFailureIsReportedInsteadOfSilentlyClaimingRestoration() throws {
        let fixture = try makeFixture()
        try Data("old plist".utf8).write(to: fixture.plistURL)
        let scheduler = makeScheduler(
            fixture: fixture,
            isLoaded: true,
            launchctlRunner: { operation in
                if case .bootstrap = operation {
                    throw SignatureUpdateSchedulerError.launchctlFailed(command: "bootstrap", status: 5)
                }
            }
        )

        XCTAssertThrowsError(try scheduler.reconcile(enabled: true, schedule: .daily9am)) { error in
            guard case SignatureUpdateSchedulerError.reconciliationAndRollbackFailed = error else {
                return XCTFail("Expected reconciliationAndRollbackFailed, got \(error)")
            }
        }
    }

    func testFailedAtomicWriteRestoresPreviousLoadedAgent() throws {
        let fixture = try makeFixture()
        let oldData = Data("old plist".utf8)
        try oldData.write(to: fixture.plistURL)
        var operations: [SignatureUpdateLaunchctlOperation] = []
        var writes = 0
        let scheduler = makeScheduler(
            fixture: fixture,
            isLoaded: true,
            dataWriter: { data, url, options in
                writes += 1
                if writes == 1 { throw TestError.intentionalWriteFailure }
                try data.write(to: url, options: options)
            },
            launchctlRunner: { operations.append($0) }
        )

        XCTAssertThrowsError(try scheduler.reconcile(enabled: true, schedule: .daily9am))

        XCTAssertEqual(try Data(contentsOf: fixture.plistURL), oldData)
        XCTAssertEqual(operations, [
            .bootout(serviceTarget: serviceTarget),
            .bootstrap(domain: domain, plistURL: fixture.plistURL)
        ])
    }

    func testDisablingLoadedAgentBootsOutAndRemovesExistingPlist() throws {
        let fixture = try makeFixture()
        try Data("existing".utf8).write(to: fixture.plistURL)
        var operations: [SignatureUpdateLaunchctlOperation] = []
        let scheduler = makeScheduler(
            fixture: fixture,
            isLoaded: true,
            launchctlRunner: { operations.append($0) }
        )

        try scheduler.reconcile(enabled: false, schedule: .daily9am)

        XCTAssertEqual(operations, [.bootout(serviceTarget: serviceTarget)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.plistURL.path))
    }

    func testDisablingLoadedJobWithMissingPlistStillBootsItOut() throws {
        let fixture = try makeFixture()
        var operations: [SignatureUpdateLaunchctlOperation] = []
        let scheduler = makeScheduler(
            fixture: fixture,
            isLoaded: true,
            launchctlRunner: { operations.append($0) }
        )

        try scheduler.reconcile(enabled: false, schedule: .daily9am)

        XCTAssertEqual(operations, [.bootout(serviceTarget: serviceTarget)])
    }

    func testDisablingPresentButUnloadedPlistRemovesWithoutBootout() throws {
        let fixture = try makeFixture()
        try Data("existing".utf8).write(to: fixture.plistURL)
        var operations: [SignatureUpdateLaunchctlOperation] = []
        let scheduler = makeScheduler(
            fixture: fixture,
            isLoaded: false,
            launchctlRunner: { operations.append($0) }
        )

        try scheduler.reconcile(enabled: false, schedule: .daily9am)

        XCTAssertTrue(operations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.plistURL.path))
    }

    func testDisablingWithoutDiskOrRuntimeAgentIsNoOp() throws {
        let fixture = try makeFixture()
        var operations: [SignatureUpdateLaunchctlOperation] = []
        let scheduler = makeScheduler(
            fixture: fixture,
            launchctlRunner: { operations.append($0) }
        )

        try scheduler.reconcile(enabled: false, schedule: .daily9am)

        XCTAssertTrue(operations.isEmpty)
    }

    func testMonthlyScheduleUsesDayOfMonthForExistingModelCompatibility() throws {
        let fixture = try makeFixture()
        let scheduler = makeScheduler(fixture: fixture)
        let schedule = ScanSchedule(
            frequency: .monthly,
            time: DateComponents(hour: 3, minute: 20),
            dayOfMonth: 14
        )

        try scheduler.reconcile(enabled: true, schedule: schedule)

        let plist = try readPlist(at: fixture.plistURL)
        XCTAssertEqual(plist["StartCalendarInterval"] as? [String: Int], [
            "Day": 14,
            "Hour": 3,
            "Minute": 20
        ])
    }

    func testInvalidWeeklyScheduleFailsBeforeWritingOrBootstrapping() throws {
        let fixture = try makeFixture()
        var operations: [SignatureUpdateLaunchctlOperation] = []
        let scheduler = makeScheduler(
            fixture: fixture,
            launchctlRunner: { operations.append($0) }
        )
        let invalidSchedule = ScanSchedule(
            frequency: .weekly,
            time: DateComponents(hour: 25, minute: 0),
            dayOfWeek: 9
        )

        XCTAssertThrowsError(try scheduler.reconcile(enabled: true, schedule: invalidSchedule)) { error in
            guard case SignatureUpdateSchedulerError.invalidSchedule = error else {
                return XCTFail("Expected invalid schedule, got \(error)")
            }
        }
        XCTAssertTrue(operations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.plistURL.path))
    }

    func testFailedFirstBootstrapRemovesIncompleteNewAgent() throws {
        let fixture = try makeFixture()
        var operations: [SignatureUpdateLaunchctlOperation] = []
        let scheduler = makeScheduler(
            fixture: fixture,
            launchctlRunner: { operation in
                operations.append(operation)
                if case .bootstrap = operation {
                    throw SignatureUpdateSchedulerError.launchctlFailed(command: "bootstrap", status: 5)
                }
            }
        )

        XCTAssertThrowsError(try scheduler.reconcile(enabled: true, schedule: .daily9am))

        XCTAssertEqual(operations, [
            .bootstrap(domain: domain, plistURL: fixture.plistURL),
            .bootout(serviceTarget: serviceTarget)
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.plistURL.path))
    }

    func testFailedDisableBootoutPreservesExistingAgent() throws {
        let fixture = try makeFixture()
        let oldData = Data("existing".utf8)
        try oldData.write(to: fixture.plistURL)
        let scheduler = makeScheduler(
            fixture: fixture,
            isLoaded: true,
            launchctlRunner: { _ in
                throw SignatureUpdateSchedulerError.launchctlFailed(command: "bootout", status: 5)
            }
        )

        XCTAssertThrowsError(try scheduler.reconcile(enabled: false, schedule: .daily9am))

        XCTAssertEqual(try Data(contentsOf: fixture.plistURL), oldData)
    }

    func testLaunchctlPrintFailsClosedUnlessServiceIsKnownMissing() throws {
        XCTAssertTrue(try SignatureUpdateScheduler.loadedState(forPrintStatus: 0))
        XCTAssertFalse(try SignatureUpdateScheduler.loadedState(forPrintStatus: 3))
        XCTAssertFalse(try SignatureUpdateScheduler.loadedState(forPrintStatus: 113))
        XCTAssertThrowsError(try SignatureUpdateScheduler.loadedState(forPrintStatus: 5)) { error in
            guard case SignatureUpdateSchedulerError.launchctlFailed(let command, let status) = error else {
                return XCTFail("Expected launchctlFailed, got \(error)")
            }
            XCTAssertEqual(command, "print")
            XCTAssertEqual(status, 5)
        }
    }

    func testDefaultLaunchctlPrintRecognizesMissingServiceWithoutMutatingDisk() throws {
        let fixture = try makeFixture()
        let scheduler = SignatureUpdateScheduler(
            launchAgentsDirectory: fixture.launchAgentsDirectory,
            applicationBundlePath: "/Applications/SafeMac AV.app",
            userID: getuid()
        )

        try scheduler.reconcile(enabled: false, schedule: .daily9am)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.plistURL.path))
    }

    func testDefaultLaunchctlRunnerBootstrapsAndToleratesMissingBootout() throws {
        let fixture = try makeFixture()
        let successfulLaunchctl = try makeLaunchctlStub(exitStatus: 0, in: fixture)
        let installer = SignatureUpdateScheduler(
            launchAgentsDirectory: fixture.launchAgentsDirectory,
            applicationBundlePath: "/Applications/SafeMac AV.app",
            userID: userID,
            launchctlExecutableURL: successfulLaunchctl,
            loadedStatusProvider: { false }
        )

        try installer.reconcile(enabled: true, schedule: .daily9am)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.plistURL.path))

        let missingServiceLaunchctl = try makeLaunchctlStub(exitStatus: 113, in: fixture)
        let remover = SignatureUpdateScheduler(
            launchAgentsDirectory: fixture.launchAgentsDirectory,
            applicationBundlePath: "/Applications/SafeMac AV.app",
            userID: userID,
            launchctlExecutableURL: missingServiceLaunchctl,
            loadedStatusProvider: { true }
        )

        try remover.reconcile(enabled: false, schedule: .daily9am)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.plistURL.path))
    }

    private var domain: String { "gui/\(userID)" }
    private var serviceTarget: String { "\(domain)/\(SignatureUpdateScheduler.label)" }

    private func makeScheduler(
        fixture: SignatureSchedulerFixture,
        isLoaded: Bool = false,
        dataWriter: @escaping SignatureUpdateScheduler.DataWriter = { data, url, options in
            try data.write(to: url, options: options)
        },
        launchctlRunner: @escaping (SignatureUpdateLaunchctlOperation) throws -> Void = { _ in }
    ) -> SignatureUpdateScheduler {
        SignatureUpdateScheduler(
            launchAgentsDirectory: fixture.launchAgentsDirectory,
            applicationBundlePath: "/Applications/SafeMac AV.app",
            userID: userID,
            dataWriter: dataWriter,
            loadedStatusProvider: { isLoaded },
            launchctlRunner: launchctlRunner
        )
    }

    private func readPlist(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }

    private func makeLaunchctlStub(
        exitStatus: Int,
        in fixture: SignatureSchedulerFixture
    ) throws -> URL {
        let url = fixture.launchAgentsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("launchctl-\(exitStatus)")
        try Data("#!/bin/sh\nexit \(exitStatus)\n".utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makeFixture() throws -> SignatureSchedulerFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SignatureUpdateSchedulerTests-\(UUID().uuidString)", isDirectory: true)
        let launchAgentsDirectory = root.appendingPathComponent("LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        temporaryDirectories.append(root)
        return SignatureSchedulerFixture(launchAgentsDirectory: launchAgentsDirectory)
    }
}

private struct SignatureSchedulerFixture {
    let launchAgentsDirectory: URL

    var plistURL: URL {
        launchAgentsDirectory.appendingPathComponent(
            "com.newtonlorenz.ClamAV-GUI.signature-update.plist"
        )
    }
}
