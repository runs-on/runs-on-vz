import Foundation
import XCTest
@testable import runs_on_vz

final class VMDirectoryLockTests: XCTestCase {
    func testCreationCannotAdoptReplacementBeforeOpeningDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("vm")
        let replacement = ReplacementAttempt()

        XCTAssertThrowsError(try VMDirectoryLock.create(directory, afterCreation: {
            DispatchQueue.global().async {
                do {
                    let original = try VMDirectoryLock(directory)
                    defer { original.release() }
                    replacement.ownsOriginal.signal()
                    // This removal must wait for creation to capture its FD.
                    try original.removeDirectory()
                    let next = try VMDirectoryLock.create(directory)
                    defer { next.release() }
                    try Data("replacement survives".utf8).write(to: directory.appendingPathComponent("winner"))
                    // Keep the original inode locked until replacement is done.
                } catch { replacement.error = error }
                replacement.done.signal()
            }
            XCTAssertEqual(replacement.ownsOriginal.wait(timeout: .now() + 5), .success)
            XCTAssertEqual(replacement.done.wait(timeout: .now() + 0.1), .timedOut)
        }))
        XCTAssertEqual(replacement.done.wait(timeout: .now() + 5), .success)
        XCTAssertNil(replacement.error)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("winner")), Data("replacement survives".utf8))
    }
}

// The semaphore publishes the error after the worker exits; the test reads it
// only after waiting. No VM or runtime process is involved in this interleaving.
private final class ReplacementAttempt: @unchecked Sendable {
    let ownsOriginal = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    var error: Error?
}
