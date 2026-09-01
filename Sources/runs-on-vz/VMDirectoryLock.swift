import Darwin
import Foundation

// Lock the directory inode itself. Start, stop and delete share this lock;
// there is no lock-file name that deletion could recreate under a waiter.
final class VMDirectoryLock {
    private let directory: URL
    private var descriptor: Int32

    convenience init(_ directory: URL) throws {
        try self.init(directory, descriptor: Self.openDirectory(directory))
    }

    private init(_ directory: URL, descriptor: Int32) throws {
        self.directory = directory
        self.descriptor = descriptor
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        do {
            guard flock(descriptor, LOCK_EX) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            try validateIdentity()
        } catch {
            release()
            throw error
        }
    }

    // The short parent lock closes mkdir -> open against runtime deletion.
    // Release it before waiting on the child lock, so another VM's lifecycle
    // never waits behind this VM's startup or graceful shutdown.
    static func create(_ directory: URL, afterCreation: () -> Void = {}) throws -> VMDirectoryLock {
        let parent = try VMDirectoryLock(directory.deletingLastPathComponent())
        defer { parent.release() }
        guard mkdir(directory.path, 0o700) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        afterCreation() // Deterministic test barrier at the creation boundary.
        let descriptor = openDirectory(directory)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        parent.release()
        return try VMDirectoryLock(directory, descriptor: descriptor)
    }

    func removeDirectory() throws {
        let parent = try VMDirectoryLock(directory.deletingLastPathComponent())
        defer { parent.release() }
        try validateIdentity()
        try FileManager.default.removeItem(at: directory)
    }

    private static func openDirectory(_ directory: URL) -> Int32 {
        open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }

    private func validateIdentity() throws {
        var locked = stat()
        var current = stat()
        guard fstat(descriptor, &locked) == 0, lstat(directory.path, &current) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard locked.st_dev == current.st_dev, locked.st_ino == current.st_ino,
              current.st_mode & S_IFMT == S_IFDIR else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ESTALE))
        }
    }

    func release() {
        if descriptor >= 0 {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }

    deinit { release() }
}
