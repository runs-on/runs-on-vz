import Foundation
import Virtualization

// One host-owned directory per execution. Never export the VM root or a
// reusable slot directory, which could expose a later job's credentials.
func bootstrapShare(_ path: String) throws -> VZVirtioFileSystemDeviceConfiguration {
    let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard path.hasPrefix("/"), url.path != "/",
          FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw CocoaError(.fileReadInvalidFileName)
    }
    let device = VZVirtioFileSystemDeviceConfiguration(tag: "runs-on-bootstrap")
    device.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: url, readOnly: true))
    return device
}
