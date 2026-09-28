import XCTest
@testable import ScrcpyHelperCore

final class AdbDevicesParserTests: XCTestCase {
    func testParsesDevicesLOutput() {
        let output = """
        List of devices attached
        emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1
        XYZ123                 offline transport_id:2
        REALSN                 device product:cross product:ignore model:Pixel_7 transport_id:3
        """
        let parsed = AdbDevicesParser.parse(output)
        XCTAssertEqual(parsed.unavailableCount, 1)
        XCTAssertEqual(parsed.ready.count, 2)
        XCTAssertEqual(parsed.ready[0].sn, "emulator-5554")
        XCTAssertEqual(parsed.ready[0].model, "sdk_gphone64_arm64")
        XCTAssertEqual(parsed.ready[1].sn, "REALSN")
        XCTAssertEqual(parsed.ready[1].model, "Pixel_7")
        XCTAssertEqual(parsed.ready[1].product, "cross")
    }

    func testSanitizeProp() {
        XCTAssertNil(AdbDevicesParser.sanitizeProp(" error: closed\n"))
        XCTAssertNil(AdbDevicesParser.sanitizeProp("not found"))
        XCTAssertEqual(AdbDevicesParser.sanitizeProp("  samsung\r\n"), "samsung")
    }
}

final class AdbTrackDevicesFrameParserTests: XCTestCase {
    func testParsesSplitAndConsecutiveSnapshots() throws {
        let first = "ABC123\tdevice\n"
        let second = "ABC123\toffline\n"
        let stream = frame(first) + frame(second) + frame("")
        var parser = AdbTrackDevicesFrameParser()

        XCTAssertEqual(try parser.append(Data(stream.prefix(2))), [])
        XCTAssertEqual(try parser.append(Data(stream.dropFirst(2).prefix(7))), [])
        XCTAssertEqual(try parser.append(Data(stream.dropFirst(9))), [first, second, ""])
    }

    func testRejectsInvalidFrameLength() {
        var parser = AdbTrackDevicesFrameParser()
        XCTAssertThrowsError(try parser.append(Data("ZZZZ".utf8)))
        var negativeLengthParser = AdbTrackDevicesFrameParser()
        XCTAssertThrowsError(try negativeLengthParser.append(Data("-001".utf8)))
    }

    private func frame(_ snapshot: String) -> Data {
        Data(String(format: "%04X", snapshot.utf8.count).utf8) + Data(snapshot.utf8)
    }
}

final class AdbDeviceTrackerTests: XCTestCase {
    func testDeliversSnapshotWhileTrackingProcessIsRunning() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("adb-tracker-live-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let scriptURL = directory.appendingPathComponent("adb")
        let snapshot = "DEMO123\tdevice\n"
        let frame = String(format: "%04X", snapshot.utf8.count) + snapshot
        try "#!/bin/sh\nprintf '%s' '\(frame)'\nexec /bin/sleep 15\n"
            .write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let received = expectation(description: "receives snapshot before process exit")
        let tracker = AdbDeviceTracker(adbURL: scriptURL) { output in
            if output == snapshot { received.fulfill() }
        }
        tracker.start()
        wait(for: [received], timeout: 3)
        tracker.stop()
    }

    func testRestartsTrackingProcessAfterExit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("adb-tracker-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let scriptURL = directory.appendingPathComponent("adb")
        let snapshot = "DEMO123\tdevice\n"
        let frame = String(format: "%04X", snapshot.utf8.count) + snapshot
        try "#!/bin/sh\nprintf '%s' '\(frame)'\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let received = expectation(description: "receives ADB snapshots after restart")
        received.expectedFulfillmentCount = 2
        let tracker = AdbDeviceTracker(adbURL: scriptURL) { output in
            if output == snapshot { received.fulfill() }
        }
        tracker.start()
        wait(for: [received], timeout: 5)
        tracker.stop()
    }
}

final class ScrcpyLaunchOptionsTests: XCTestCase {
    func testArgumentsIncludeFlags() {
        let options = ScrcpyLaunchOptions(noAudio: true, stayAwake: true, maxSize1024: true)
        XCTAssertEqual(
            options.arguments(serial: "ABC"),
            ["-s", "ABC", "--no-audio", "--stay-awake", "--max-size=1024"]
        )
    }

    func testArgumentsMinimal() {
        let options = ScrcpyLaunchOptions(noAudio: false, stayAwake: false, maxSize1024: false)
        XCTAssertEqual(options.arguments(serial: "SN1"), ["-s", "SN1"])
    }

    func testArgumentsSelectSecondaryDisplay() {
        let options = ScrcpyLaunchOptions(noAudio: false, stayAwake: false, maxSize1024: false)
        XCTAssertEqual(options.arguments(serial: "SN1", displayId: 7), ["-s", "SN1", "--display-id=7"])
    }
}

final class ScrcpyDisplaysParserTests: XCTestCase {
    func testParsesDistinctDisplayIds() {
        let output = """
        [server] INFO: List of displays:
            --display-id=27    (1920x1080)
            --display-id=0     (1080x2400)
            --display-id=27    (1920x1080)
        """
        XCTAssertEqual(ScrcpyDisplaysParser.parse(output), [0, 27])
    }

    func testIgnoresUnrelatedOutput() {
        XCTAssertEqual(ScrcpyDisplaysParser.parse("[server] WARN: no displays available"), [])
    }
}

final class ScrcpyClientTests: XCTestCase {
    func testLaunchPassesResolvedAdbPathToScrcpyEnvironment() throws {
        let launcher = RecordingScrcpyLauncher()
        let client = ScrcpyClient(
            configuredPath: "/tmp/scrcpy",
            configuredAdbPath: "/tmp/adb",
            launcher: launcher,
            fileManager: ExecutableFileManager(paths: ["/tmp/scrcpy", "/tmp/adb"]),
            pathEnvironment: "/usr/bin"
        )

        _ = try client.launch(serial: "DEVICE", options: ScrcpyLaunchOptions())

        XCTAssertEqual(launcher.executable?.path, "/tmp/scrcpy")
        XCTAssertEqual(launcher.arguments, ["-s", "DEVICE", "--no-audio", "--stay-awake"])
        XCTAssertEqual(launcher.environment["ADB"], "/tmp/adb")
    }

    func testLaunchForwardsFailureCallback() throws {
        let launcher = RecordingScrcpyLauncher()
        let client = ScrcpyClient(
            configuredPath: "/tmp/scrcpy",
            configuredAdbPath: "/tmp/adb",
            launcher: launcher,
            fileManager: ExecutableFileManager(paths: ["/tmp/scrcpy", "/tmp/adb"])
        )
        let failure = LockedString()

        _ = try client.launch(serial: "DEVICE", options: ScrcpyLaunchOptions()) { message in
            failure.set(message)
        }
        launcher.reportFailure("adb 未授权")

        XCTAssertEqual(failure.value, "adb 未授权")
    }

    func testListDisplaysUsesSelectedAdbAndParsesStandardError() throws {
        let runner = RecordingProcessRunner(
            result: (0, "", "[server] INFO: List of displays:\n    --display-id=0 (1080x2400)\n    --display-id=2 (1920x1080)\n")
        )
        let client = ScrcpyClient(
            configuredPath: "/tmp/scrcpy",
            configuredAdbPath: "/tmp/adb",
            processRunner: runner,
            fileManager: ExecutableFileManager(paths: ["/tmp/scrcpy", "/tmp/adb"])
        )

        XCTAssertEqual(try client.listDisplays(serial: "DEVICE"), [0, 2])
        XCTAssertEqual(runner.arguments, ["-s", "DEVICE", "--list-displays"])
        XCTAssertEqual(runner.environment["ADB"], "/tmp/adb")
    }

    func testLaunchCanSelectDisplay() throws {
        let launcher = RecordingScrcpyLauncher()
        let client = ScrcpyClient(
            configuredPath: "/tmp/scrcpy",
            configuredAdbPath: "/tmp/adb",
            launcher: launcher,
            fileManager: ExecutableFileManager(paths: ["/tmp/scrcpy", "/tmp/adb"])
        )

        _ = try client.launch(serial: "DEVICE", displayId: 2, options: ScrcpyLaunchOptions())

        XCTAssertEqual(launcher.arguments, ["-s", "DEVICE", "--display-id=2", "--no-audio", "--stay-awake"])
    }

    func testFoundationLauncherForwardsStandardErrorAfterNonZeroExit() throws {
        let expectation = expectation(description: "reports process failure")
        let failure = LockedString()

        _ = try FoundationScrcpyLauncher().launch(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo '无法连接设备' >&2; exit 2"],
            environment: [:]
        ) { message in
            failure.set(message)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(failure.value, "无法连接设备")
    }
}

private final class RecordingProcessRunner: ProcessRunning, @unchecked Sendable {
    let result: (exitCode: Int32, stdout: String, stderr: String)
    var arguments: [String] = []
    var environment: [String: String] = [:]

    init(result: (exitCode: Int32, stdout: String, stderr: String)) {
        self.result = result
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        self.arguments = arguments
        self.environment = environment
        return result
    }
}

private final class RecordingScrcpyLauncher: ScrcpyLaunching, @unchecked Sendable {
    var executable: URL?
    var arguments: [String] = []
    var environment: [String: String] = [:]
    var onFailure: (@Sendable (String) -> Void)?

    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        onFailure: @escaping @Sendable (String) -> Void
    ) throws -> Int32 {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.onFailure = onFailure
        return 123
    }

    func reportFailure(_ message: String) {
        onFailure?(message)
    }
}

private final class ExecutableFileManager: FileManager, @unchecked Sendable {
    private let paths: Set<String>

    init(paths: Set<String>) {
        self.paths = paths
        super.init()
    }

    override func isExecutableFile(atPath path: String) -> Bool {
        paths.contains(path)
    }
}

private final class LockedString: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        storage = value
    }
}

final class ToolDetectorHintTests: XCTestCase {
    func testHints() {
        XCTAssertTrue(ToolDetector.installHint(for: ToolStatus(adbFound: false, scrcpyFound: true)).contains("adb"))
        XCTAssertTrue(ToolDetector.installHint(for: ToolStatus(adbFound: true, scrcpyFound: false)).contains("scrcpy"))
        XCTAssertTrue(ToolDetector.installHint(for: ToolStatus(adbFound: false, scrcpyFound: false)).contains("adb 与 scrcpy"))
    }
}
