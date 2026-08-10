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

final class ToolDetectorHintTests: XCTestCase {
    func testHints() {
        XCTAssertTrue(ToolDetector.installHint(for: ToolStatus(adbFound: false, scrcpyFound: true)).contains("adb"))
        XCTAssertTrue(ToolDetector.installHint(for: ToolStatus(adbFound: true, scrcpyFound: false)).contains("scrcpy"))
        XCTAssertTrue(ToolDetector.installHint(for: ToolStatus(adbFound: false, scrcpyFound: false)).contains("adb 与 scrcpy"))
    }
}
