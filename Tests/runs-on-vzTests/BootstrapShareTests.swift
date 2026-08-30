import Foundation
import Virtualization
import XCTest
@testable import runs_on_vz

final class BootstrapShareTests: XCTestCase {
    func testOnlyExportsTheBootstrapDirectoryReadOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let device = try bootstrapShare(directory.path)
        XCTAssertEqual(device.tag, "runs-on-bootstrap")
        let share = try XCTUnwrap(device.share as? VZSingleDirectoryShare)
        XCTAssertEqual(share.directory.url.path, directory.resolvingSymlinksInPath().path)
        XCTAssertTrue(share.directory.isReadOnly)
    }
}
