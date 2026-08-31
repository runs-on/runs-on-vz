import Darwin
import Foundation
import XCTest
@testable import runs_on_vz

final class BootstrapPayloadTests: XCTestCase {
    func testReadsLatestAtomicSnapshotAndRejectsUnsafeFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("bootstrap.json")
        for value in ["first", "renewed"] {
            try Data(value.utf8).write(to: file, options: .atomic)
            XCTAssertEqual(try bootstrapPayload(file.path), Data(value.utf8))
        }
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try bootstrapPayload(link.path))
        XCTAssertThrowsError(try bootstrapPayload(directory.path))
        XCTAssertThrowsError(try bootstrapPayload("relative.json"))
        try Data().write(to: file, options: .atomic)
        XCTAssertThrowsError(try bootstrapPayload(file.path))
        try Data(repeating: 0, count: 65537).write(to: file, options: .atomic)
        XCTAssertThrowsError(try bootstrapPayload(file.path))
        let fifo = directory.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try bootstrapPayload(fifo.path))
    }
}
