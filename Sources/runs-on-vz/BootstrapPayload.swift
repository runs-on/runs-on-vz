import Darwin
import Foundation
import Security

// Read one bounded, regular, host-owned snapshot. A new open observes atomic
// replacements on the host; no host filesystem is exposed to the guest.
func bootstrapPayload(_ path: String) throws -> Data {
    guard path.hasPrefix("/") else { throw CocoaError(.fileReadInvalidFileName) }
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? file.close() }
    var status = stat()
    guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
          status.st_size > 0, status.st_size <= 65536 else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let data = try file.read(upToCount: 65537) ?? Data()
    guard !data.isEmpty, data.count <= 65536 else { throw CocoaError(.fileReadCorruptFile) }
    return data
}

// stamped adds the host's clock and 32 fresh random bytes to an object
// payload (under "runs-on-vz": time_ms, seed): a guest resumed from a saved
// state wakes with the clock and random pool it was saved with.
func stamped(_ data: Data) -> Data {
    guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return data }
    var seed = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, seed.count, &seed) == errSecSuccess else { return data }
    object["runs-on-vz"] = ["time_ms": Int64(Date().timeIntervalSince1970 * 1000), "seed": Data(seed).base64EncodedString()]
    return (try? JSONSerialization.data(withJSONObject: object)) ?? data
}
