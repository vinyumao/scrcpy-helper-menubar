import ScrcpyHelperCore
import XCTest

@MainActor
final class AppModelTests: XCTestCase {
    func testRefreshReturnsWhileCommandIsStillPending() async throws {
        let (model, runner, directory) = try makeModel()
        defer { model.stopTracking(); try? FileManager.default.removeItem(at: directory) }
        await waitForRequests(1, runner: runner)
        XCTAssertTrue(model.isRefreshing)
        XCTAssertTrue(model.devices.isEmpty)
        await runner.complete(0, serial: "A")
        await waitForDevice("A", model: model)
        XCTAssertFalse(model.isRefreshing)
    }

    func testCancelledOlderRefreshCannotOverwriteNewerDevices() async throws {
        let (model, runner, directory) = try makeModel()
        defer { model.stopTracking(); try? FileManager.default.removeItem(at: directory) }
        await waitForRequests(1, runner: runner)
        model.refresh()
        await waitForRequests(2, runner: runner)
        await runner.complete(1, serial: "NEW")
        await waitForDevice("NEW", model: model)
        // The fake command deliberately ignores cancellation and completes late.
        await runner.complete(0, serial: "OLD")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.devices.map(\.sn), ["NEW"])
        XCTAssertFalse(model.isRefreshing)
        XCTAssertNil(model.lastError)
    }

    func testStoppingRefreshPreventsLateStateUpdates() async throws {
        let (model, runner, directory) = try makeModel()
        defer { model.stopTracking(); try? FileManager.default.removeItem(at: directory) }
        await waitForRequests(1, runner: runner)
        model.stopTracking()
        await runner.complete(0, serial: "LATE")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(model.devices.isEmpty)
        XCTAssertFalse(model.isRefreshing)
        XCTAssertNil(model.lastError)
    }

    func testRefreshFailureClearsLoadingAndReportsError() async throws {
        let (model, runner, directory) = try makeModel()
        defer { model.stopTracking(); try? FileManager.default.removeItem(at: directory) }
        await waitForRequests(1, runner: runner)
        await runner.fail(0)
        for _ in 0..<100 {
            if !model.isRefreshing { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isRefreshing)
        XCTAssertTrue(model.lastError?.contains("超时") == true)
    }

    func testSavingGlobalDraftPreservesNewerDeviceConfiguration() async throws {
        let (model, runner, directory) = try makeModel()
        defer { model.stopTracking(); try? FileManager.default.removeItem(at: directory) }
        await waitForRequests(1, runner: runner)
        await runner.complete(0, serial: "A")
        await waitForDevice("A", model: model)
        var oldDraft = model.settings
        let profile = DeviceSettings(alias: "  主机  ", launchOptions: ScrcpyLaunchOptions(noAudio: false), preferredDisplayId: 2)
        XCTAssertTrue(model.saveDeviceSettings(profile, serial: "A"))
        oldDraft.launchOptions.maxSize1024 = true
        XCTAssertTrue(model.saveSettings(oldDraft))
        await waitForRequests(2, runner: runner)
        await runner.complete(1, serial: "A")
        await waitForDevice("A", model: model)
        XCTAssertEqual(model.settings.alias(for: "A"), "主机")
        XCTAssertEqual(model.settings.devices["A"]?.preferredDisplayId, 2)
        XCTAssertEqual(model.settings.options(for: "A").noAudio, false)
        XCTAssertEqual(model.settings.options(for: "A").maxSize1024, false)
        XCTAssertEqual(model.settings.options(for: "OTHER").maxSize1024, true)
        XCTAssertEqual(model.deviceTitle(model.devices[0]), "主机 (A)")
    }

    private func makeModel() throws -> (AppModel, ControlledRunner, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("app-model-tests-\(UUID().uuidString)")
        try SettingsStore(appSupportDirectory: directory).save(AppSettings(adbPath: "/usr/bin/true", scrcpyPath: "/usr/bin/true"))
        let runner = ControlledRunner()
        return (AppModel(appSupportURL: directory, processRunner: runner, tracksDevices: false), runner, directory)
    }

    private func waitForRequests(_ count: Int, runner: ControlledRunner) async {
        for _ in 0..<100 {
            if await runner.requestCount >= count { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Command was not started")
    }

    private func waitForDevice(_ serial: String, model: AppModel) async {
        for _ in 0..<100 {
            if model.devices.first?.sn == serial && !model.isRefreshing { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Device state was not updated")
    }
}

private actor ControlledRunner: ProcessRunning {
    typealias Result = (exitCode: Int32, stdout: String, stderr: String)
    private var pending: [Int: CheckedContinuation<Result, Error>] = [:]
    private(set) var requestCount = 0

    func run(executable: URL, arguments: [String], environment: [String: String]) async throws -> Result {
        if arguments == ["devices", "-l"] {
            let id = requestCount
            requestCount += 1
            return try await withCheckedThrowingContinuation { pending[id] = $0 }
        }
        if arguments.contains("--list-displays") {
            return (0, "--display-id=0 (1080x1920)\n--display-id=2 (800x600)", "")
        }
        return (0, "TestBrand", "")
    }

    func complete(_ id: Int, serial: String) {
        pending.removeValue(forKey: id)?.resume(returning: (0, "\(serial) device model:TestModel", ""))
    }

    func fail(_ id: Int) {
        pending.removeValue(forKey: id)?.resume(throwing: ProcessExecutionError.timedOut(command: "adb", seconds: 15))
    }
}
