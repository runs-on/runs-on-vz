import Foundation
import XCTest
@testable import runs_on_vz

final class RunResultTests: XCTestCase {
    func testPersistsSuccessAndFailureForAnExactProcessIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("run.result")
        let identity = try XCTUnwrap(ProcessIdentity.current(getpid()))
        let success = RunResult(identity: identity, failure: nil)
        try success.write(path)
        XCTAssertEqual(try RunResult.read(path), success)

        let failure = RunResult(identity: identity, failure: RunFailure(kind: "vm_crashed", message: "guest stopped"))
        try failure.write(path)
        XCTAssertEqual(try RunResult.read(path), failure)
    }

    func testRejectsMalformedResultAndAllowsMissingResult() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("run.result")
        XCTAssertNil(try RunResult.read(path))
        try Data("malformed".utf8).write(to: path)
        XCTAssertThrowsError(try RunResult.read(path))
    }
}
