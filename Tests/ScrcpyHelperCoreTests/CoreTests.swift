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
