import XCTest
@testable import ScrcpyHelperCore

final class AdbClientTests: XCTestCase {
    func testCachedDevicesSkipPropertiesAndDisconnectedDevicesAreRemoved() async throws {
        let runner = AdbFixtureRunner(output: "A device model:ModelA\nB offline")
        let client = AdbClient(configuredPath: "/usr/bin/true", processRunner: runner)
        let known = AdbDevice(sn: "A", brand: "BrandA", model: "ModelA")
        let result = try await client.listReadyDevices(knownDevices: [
            "A": known, "REMOVED": AdbDevice(sn: "REMOVED", brand: "Old", model: "Old")
        ])
        XCTAssertEqual(result.devices, [known])
        XCTAssertEqual(result.unavailableCount, 1)
        let commands = await runner.commands
        XCTAssertEqual(commands, [["devices", "-l"]])
    }

    func testNewDeviceLoadsPropertiesAndFallsBackAfterFailedCommand() async throws {
        let runner = AdbFixtureRunner(output: "A device product:FallbackProduct model:ModelA", brandFails: true)
        let result = try await AdbClient(configuredPath: "/usr/bin/true", processRunner: runner).listReadyDevices()
        XCTAssertEqual(result.devices, [AdbDevice(sn: "A", brand: "Manufacturer", model: "ModelA")])
        let commands = await runner.commands
        XCTAssertEqual(commands.count, 3)
    }

    func testChangedModelInvalidatesCachedProperties() async throws {
        let runner = AdbFixtureRunner(output: "A device model:NewModel")
        let result = try await AdbClient(configuredPath: "/usr/bin/true", processRunner: runner).listReadyDevices(
            knownDevices: ["A": AdbDevice(sn: "A", brand: "OldBrand", model: "OldModel")]
        )
        XCTAssertEqual(result.devices, [AdbDevice(sn: "A", brand: "Brand", model: "NewModel")])
        let commands = await runner.commands
        XCTAssertEqual(commands.count, 2)
    }
}

private actor AdbFixtureRunner: ProcessRunning {
    let output: String
    let brandFails: Bool
    private(set) var commands: [[String]] = []

    init(output: String, brandFails: Bool = false) {
        self.output = output
        self.brandFails = brandFails
    }

    func run(executable: URL, arguments: [String], environment: [String: String]) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        commands.append(arguments)
        if arguments == ["devices", "-l"] { return (0, output, "") }
        if arguments.last == "ro.product.brand" {
            return brandFails ? (1, "invalid partial stdout", "failed") : (0, "Brand", "")
        }
        return (0, "Manufacturer", "")
    }
}
