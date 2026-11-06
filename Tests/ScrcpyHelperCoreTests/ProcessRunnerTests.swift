import Darwin
import XCTest
@testable import ScrcpyHelperCore

final class ProcessRunnerTests: XCTestCase {
    func testDrainsLargeStdoutAndStderrWithoutDeadlock() async throws {
        let result = try await FoundationProcessRunner(timeout: 5).run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/usr/bin/head -c 1048576 /dev/zero; /usr/bin/head -c 1048576 /dev/zero >&2; exit 7"]
        )
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(result.stdout.utf8.count, 1_048_576)
        XCTAssertEqual(result.stderr.utf8.count, 1_048_576)
    }

    func testCapturesConcurrentStreamsAndEnvironment() async throws {
        let result = try await FoundationProcessRunner(timeout: 5).run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/usr/bin/head -c 262144 /dev/zero & /usr/bin/head -c 262144 /dev/zero >&2 & wait; printf '%s' \"$SCRCPY_TEST_VALUE\""],
            environment: ["SCRCPY_TEST_VALUE": "测试完成"]
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr.utf8.count, 262_144)
        XCTAssertTrue(result.stdout.hasSuffix("测试完成"))
        XCTAssertEqual(result.stdout.utf8.count, 262_144 + "测试完成".utf8.count)
    }

    func testTimeoutKillsProcessEvenWhenItIgnoresTermination() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let start = ContinuousClock.now
        do {
            _ = try await FoundationProcessRunner(timeout: 0.3).run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo $$ > \"$1\"; trap '' TERM; while :; do :; done", "test", pidFile.path]
            )
            XCTFail("Expected timeout")
        } catch let error as ProcessExecutionError {
            XCTAssertEqual(error, .timedOut(command: "sh", seconds: 0.3))
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
        try assertProcessExited(pidFile)
    }

    func testCancellationTerminatesRunningCommand() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let task = Task {
            try await FoundationProcessRunner(timeout: 10).run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo $$ > \"$1\"; exec /bin/sleep 10", "test", pidFile.path]
            )
        }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: pidFile.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let start = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        try assertProcessExited(pidFile)
    }

    func testAlreadyCancelledTaskDoesNotLaunchCommand() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("launched")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await FoundationProcessRunner().run(
                executable: URL(fileURLWithPath: "/usr/bin/touch"), arguments: [marker.path]
            )
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testClosedOutputStreamsDoNotPreventTimeout() async throws {
        do {
            _ = try await FoundationProcessRunner(timeout: 0.2).run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exec 1>&- 2>&-; exec /bin/sleep 10"]
            )
            XCTFail("Expected timeout")
        } catch is ProcessExecutionError { }
    }

    @MainActor
    func testWaitingForCommandAllowsMainActorToProgress() async throws {
        let task = Task {
            try await FoundationProcessRunner().run(
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["0.3"]
            )
        }
        let start = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(250))
        _ = try await task.value
    }

    func testLaunchFailureIsReported() async {
        do {
            _ = try await FoundationProcessRunner().run(executable: URL(fileURLWithPath: "/missing/scrcpy-helper-test"), arguments: [])
            XCTFail("Expected launch failure")
        } catch { XCTAssertFalse(error is ProcessExecutionError) }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("runner-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func assertProcessExited(_ pidFile: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)), file: file, line: line)
        XCTAssertEqual(kill(pid, 0), -1, file: file, line: line)
        XCTAssertEqual(errno, ESRCH, file: file, line: line)
    }
}
