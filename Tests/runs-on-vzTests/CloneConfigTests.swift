import Foundation
import XCTest
import Virtualization
@testable import runs_on_vz

final class CloneConfigTests: XCTestCase {
    func testClonePreservesMachineIdentifierAndRegeneratesMACAddress() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source.json")
        let destination = directory.appendingPathComponent("destination.json")
        let machineIdentifier = "paired-with-nvram"
        let originalMACAddress = "02:00:00:00:00:01"
        let payload: [String: Any] = [
            "ecid": machineIdentifier,
            "macAddress": originalMACAddress,
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: source)

        try cloneConfig(source, destination)

        let cloned = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any]
        )
        XCTAssertEqual(cloned["ecid"] as? String, machineIdentifier)
        XCTAssertNotEqual(cloned["macAddress"] as? String, originalMACAddress)
        XCTAssertNotNil(VZMACAddress(string: try XCTUnwrap(cloned["macAddress"] as? String)))
    }

    func testCloneOwnershipResolvesSymlinkedParent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = root.appendingPathComponent("storage", isDirectory: true)
        let link = root.appendingPathComponent("vms", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: storage)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            resolvedCloneOwnershipParent(link).standardizedFileURL,
            storage.standardizedFileURL
        )
    }
}
