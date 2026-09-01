import Darwin
import Foundation
@preconcurrency import Virtualization

// The listener belongs to one VZVirtualMachine, not the host network. The
// guest cannot choose a path, execution, role, or operation: each connection
// receives the current snapshot from the one file fixed at VM launch.
@MainActor
final class BootstrapChannel: NSObject, @preconcurrency VZVirtioSocketListenerDelegate {
    private let path: String
    private var active = 0
    let listener = VZVirtioSocketListener()

    init(path: String) throws {
        _ = try bootstrapPayload(path)
        self.path = path
        super.init()
        listener.delegate = self
    }

    func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection, from socketDevice: VZVirtioSocketDevice) -> Bool {
        guard active < 8 else { return false }
        active += 1
        let reply = BootstrapReply(connection: connection, path: path)
        DispatchQueue.global(qos: .utility).async {
            reply.send()
            Task { @MainActor in self.active -= 1 }
        }
        return true
    }
}

// One background task owns the connection until the bounded write completes.
private final class BootstrapReply: @unchecked Sendable {
    let connection: VZVirtioSocketConnection
    let path: String
    init(connection: VZVirtioSocketConnection, path: String) {
        self.connection = connection
        self.path = path
    }

    func send() {
        defer { connection.close() }
        let fd = connection.fileDescriptor
        var noSignal: Int32 = 1
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal))) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0,
              let data = try? bootstrapPayload(path) else { return }
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return }
                offset += count
            }
        }
    }
}
