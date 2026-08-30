import Darwin
import Foundation

// A PID alone is not an identity: recovery may happen after the kernel has
// reused it. Keep the process start time and refuse ambiguous process records.
struct ProcessIdentity: Codable, Equatable {
    let pid: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    static func current(_ pid: pid_t) throws -> ProcessIdentity? {
        guard pid > 1 else { throw CocoaError(.fileReadCorruptFile) }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
        if count == 0 && errno == ESRCH { return nil }
        guard count == size else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        if info.pbi_status == UInt32(SZOMB) { return nil }
        return ProcessIdentity(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }

    func isRunning() throws -> Bool { try Self.current(pid) == self }

    static func read(_ path: URL) throws -> ProcessIdentity? {
        do { return try JSONDecoder().decode(Self.self, from: Data(contentsOf: path)) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }

    func write(_ path: URL) throws {
        try JSONEncoder().encode(self).write(to: path, options: .atomic)
        let file = try FileHandle(forWritingTo: path)
        defer { try? file.close() }
        try file.synchronize()
        let directory = open(path.deletingLastPathComponent().path, O_RDONLY)
        guard directory >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}
