import Darwin
import Foundation
import XCTest
@testable import runs_on_vz

final class ProcessIdentityTests: XCTestCase {
    func testPersistsExactProcessIdentityAndRejectsReusedPID() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = directory.appendingPathComponent("run.pid")
        XCTAssertNil(try ProcessIdentity.read(record))
        let current = try XCTUnwrap(ProcessIdentity.current(getpid()))
        XCTAssertTrue(try current.isRunning())
        try current.write(record)
        XCTAssertEqual(try ProcessIdentity.read(record), current)
        let stale = ProcessIdentity(pid: current.pid, startSeconds: current.startSeconds + 1, startMicroseconds: current.startMicroseconds)
        XCTAssertFalse(try stale.isRunning())
        try Data("not a process record".utf8).write(to: record)
        XCTAssertThrowsError(try ProcessIdentity.read(record))
    }

    func testRejectsSpecialPIDsAndMissingRecordDirectory() throws {
        for pid: pid_t in [-1, 0, 1] { XCTAssertThrowsError(try ProcessIdentity.current(pid)) }
        let identity = try XCTUnwrap(ProcessIdentity.current(getpid()))
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("run.pid")
        XCTAssertThrowsError(try identity.write(missing))
    }
}
