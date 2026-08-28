import XCTest
@testable import runs_on_vz

final class MACAddressTests: XCTestCase {
    func testNormalizesDHCPLeaseMACAddress() {
        XCTAssertEqual(normalizedMACAddress("ea:77:8:12:d6:75"), "ea:77:08:12:d6:75")
        XCTAssertEqual(normalizedMACAddress("D2:EA:7B:96:7D:31"), "d2:ea:7b:96:7d:31")
    }

    func testRejectsInvalidMACAddress() {
        XCTAssertNil(normalizedMACAddress("ea:77:8:12:d6"))
        XCTAssertNil(normalizedMACAddress("ea:77:800:12:d6:75"))
        XCTAssertNil(normalizedMACAddress("not:a:mac:address:at:all"))
    }
}
