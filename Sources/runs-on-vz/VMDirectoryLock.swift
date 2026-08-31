import Darwin
import Foundation

// Lock the directory inode itself. Start, stop and delete share this lock;
// there is no lock-file name that deletion could recreate under a waiter.
final class VMDirectoryLock {
    private var descriptor: Int32

    init(_ directory: URL) throws {
        descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        do {
            guard flock(descriptor, LOCK_EX) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            var locked = stat()
            var current = stat()
            guard fstat(descriptor, &locked) == 0, lstat(directory.path, &current) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            guard locked.st_dev == current.st_dev, locked.st_ino == current.st_ino,
                  current.st_mode & S_IFMT == S_IFDIR else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ESTALE))
            }
        } catch {
            release()
            throw error
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
