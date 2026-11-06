import XCTest
@testable import ScrcpyHelperCore

final class SettingsStoreTests: XCTestCase {
    func testOldSettingsKeepPathsAndOptionsWhenProfilesAreMissing() throws {
        let data = Data(#"{"adbPath":"/custom/adb","scrcpyPath":"/custom/scrcpy","launchOptions":{"noAudio":false,"stayAwake":false,"maxSize1024":true}}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(settings.adbPath, "/custom/adb")
        XCTAssertEqual(settings.scrcpyPath, "/custom/scrcpy")
        XCTAssertEqual(settings.launchOptions, ScrcpyLaunchOptions(noAudio: false, stayAwake: false, maxSize1024: true))
        XCTAssertTrue(settings.devices.isEmpty)
    }

    func testPartialSettingsUseDefaultsForMissingFields() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"launchOptions":{"noAudio":false},"devices":{"A":{"alias":"主机"}}}"#.utf8))
        XCTAssertEqual(settings.launchOptions, ScrcpyLaunchOptions(noAudio: false))
        XCTAssertEqual(settings.devices["A"], DeviceSettings(alias: "主机"))
    }

    func testIndependentOptionsAndInheritanceStayIsolated() {
        let independent = ScrcpyLaunchOptions(noAudio: false, stayAwake: false, maxSize1024: true)
        var settings = AppSettings(devices: ["A": DeviceSettings(launchOptions: independent), "B": DeviceSettings(alias: "副机")])
        settings.launchOptions.stayAwake = false
        XCTAssertEqual(settings.options(for: "A"), independent)
        XCTAssertEqual(settings.options(for: "B"), settings.launchOptions)
        XCTAssertEqual(settings.options(for: "NEW"), settings.launchOptions)
        settings.launchOptions.maxSize1024 = true
        XCTAssertEqual(settings.options(for: "B").maxSize1024, true)
        XCTAssertEqual(settings.options(for: "A"), independent)
    }

    func testProfilesAndSelectedDisplaysSurviveRestart() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(appSupportDirectory: directory)
        let settings = AppSettings(devices: [
            "A": DeviceSettings(alias: "收银主机", launchOptions: ScrcpyLaunchOptions(noAudio: false), preferredDisplayId: 2),
            "B": DeviceSettings(alias: "手机")
        ])
        try store.save(settings)
        XCTAssertEqual(SettingsStore(appSupportDirectory: directory).load(), settings)
        try store.update { $0.devices["A"]?.preferredDisplayId = 7 }
        let reloaded = SettingsStore(appSupportDirectory: directory).load()
        XCTAssertEqual(reloaded.devices["A"]?.preferredDisplayId, 7)
        XCTAssertEqual(reloaded.devices["B"], settings.devices["B"])
    }

    func testMissingPreferredDisplayFallsBackWithoutErasingPreference() {
        let settings = AppSettings(devices: ["A": DeviceSettings(preferredDisplayId: 7)])
        XCTAssertEqual(settings.preferredDisplay(for: "A", available: [0, 7]), 7)
        XCTAssertNil(settings.preferredDisplay(for: "A", available: [0]))
        XCTAssertEqual(settings.preferredDisplay(for: "A", available: nil), 7)
        XCTAssertEqual(settings.devices["A"]?.preferredDisplayId, 7)
    }

    func testAliasWhitespaceFallsBackAndSpecialCharactersStayOneArgument() {
        let settings = AppSettings(devices: ["A": DeviceSettings(alias: " \n"), "B": DeviceSettings(alias: "  测试 '主机' $(echo example)  ")])
        XCTAssertNil(settings.alias(for: "A"))
        let title = settings.alias(for: "B")!
        XCTAssertEqual(title, "测试 '主机' $(echo example)")
        let arguments = settings.options(for: "B").arguments(serial: "B", displayId: 2, windowTitle: title)
        XCTAssertEqual(arguments.last, "--window-title=\(title)")
        XCTAssertTrue(arguments.contains("--display-id=2"))
    }

    func testCorruptFileIsNotOverwrittenAndIsBackedUpBeforeSave() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let original = Data("{broken configuration".utf8)
        try original.write(to: file)
        let store = SettingsStore(appSupportDirectory: directory)
        XCTAssertNotNil(store.loadWarning)
        XCTAssertEqual(try Data(contentsOf: file), original)
        try store.update { $0.devices["A"] = DeviceSettings(alias: "主机") }
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("settings-backup-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
        XCTAssertEqual(SettingsStore(appSupportDirectory: directory).load().alias(for: "A"), "主机")
    }

    func testFailedSaveDoesNotUpdateInMemorySettings() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocked = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: blocked)
        let store = SettingsStore(appSupportDirectory: blocked)
        let before = store.load()
        XCTAssertThrowsError(try store.update { $0.adbPath = "/different/adb" })
        XCTAssertEqual(store.load(), before)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("settings-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
