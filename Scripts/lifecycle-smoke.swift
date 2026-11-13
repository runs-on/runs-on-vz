import Darwin
import Foundation

struct SmokeFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

// Exercise the actual CLI against disposable invalid bundles and owned child
// processes. No fixture can pass VMConfig validation, so no VM can start.
@main
struct LifecycleSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw SmokeFailure("expected absolute runtime path") }
        let binary = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vz-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try assertFailure(
            binary,
            ["clone", "--source", root.path, "--destination", root.appendingPathComponent("unused").path, "--slot", "0", "--json"],
            status: 64,
            kind: "unknown_option"
        )
        try assertFailure(binary, ["wait", "--vm", root.path, "--detach", "--json"], status: 64, kind: "unknown_option")
        try assertFailure(binary, ["wait", "--vm", root.path, "--vm", root.path, "--json"], status: 64, kind: "duplicate_argument")
        for command in ["stop", "delete", "run", "foreground"] {
            let vm = root.appendingPathComponent(command)
            try fixture(vm)
            let fd = open(vm.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard fd >= 0, flock(fd, LOCK_EX) == 0 else { throw SmokeFailure("lock fixture") }
            var locked = true
            defer { if locked { _ = flock(fd, LOCK_UN); close(fd) } }
            var args = [command == "foreground" ? "run" : command, "--vm", vm.path]
            if command == "run" || command == "foreground" {
                args += ["--cpus", "4", "--memory-mib", "8192"]
                if command == "run" { args.append("--detach") }
            }
            let process = try launch(binary, args)
            defer { finish(process) }
            usleep(300_000)
            guard process.isRunning else { throw SmokeFailure("\(command) ignored another lifecycle owner's directory lock") }
            guard !FileManager.default.fileExists(atPath: vm.appendingPathComponent("run.pid").path) else {
                throw SmokeFailure("\(command) wrote a process record without the lifecycle lock")
            }
            _ = flock(fd, LOCK_UN)
            close(fd)
            locked = false
            process.waitUntilExit()
            let expectedSuccess = command == "stop" || command == "delete"
            guard (process.terminationStatus == 0) == expectedSuccess else { throw SmokeFailure("unexpected \(command) outcome") }
            if command == "delete" && FileManager.default.fileExists(atPath: vm.path) { throw SmokeFailure("delete retained directory") }
        }

        // A waiter opened the old inode. Replacing that pathname cannot give
        // it authority to operate on the new directory after its lock opens.
        let replaced = root.appendingPathComponent("replaced")
        try fixture(replaced)
        let fd = open(replaced.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0, flock(fd, LOCK_EX) == 0 else { throw SmokeFailure("lock replaced fixture") }
        let deleting = try launch(binary, ["delete", "--vm", replaced.path])
        defer { finish(deleting) }
        usleep(300_000)
        guard deleting.isRunning else { throw SmokeFailure("delete did not wait for prior directory owner") }
        try FileManager.default.moveItem(at: replaced, to: root.appendingPathComponent("old"))
        try fixture(replaced)
        _ = flock(fd, LOCK_UN)
        close(fd)
        deleting.waitUntilExit()
        guard deleting.terminationStatus != 0, FileManager.default.fileExists(atPath: replaced.path) else {
            throw SmokeFailure("stale owner removed replacement directory")
        }

        let gated = root.appendingPathComponent("gated")
        try fixture(gated)
        let child = try launch(binary, ["internal-run", "--vm", gated.path, "--cpus", "4", "--memory-mib", "8192"])
        defer { finish(child) }
        child.waitUntilExit()
        guard child.terminationStatus != 0,
              !FileManager.default.fileExists(atPath: gated.appendingPathComponent("run.pid").path) else {
            throw SmokeFailure("child without launcher authorization wrote its process record")
        }

        for recorded in [false, true] {
            let record = gated.appendingPathComponent("run.pid")
            let previous = Data("not this child's process record".utf8)
            if recorded { try previous.write(to: record) }
            let gate = Pipe()
            let unowned = try launch(binary, ["internal-run", "--vm", gated.path, "--cpus", "4", "--memory-mib", "8192"], input: gate.fileHandleForReading)
            defer { finish(unowned) }
            try gate.fileHandleForReading.close()
            try gate.fileHandleForWriting.write(contentsOf: Data("start\n".utf8))
            try gate.fileHandleForWriting.close()
            unowned.waitUntilExit()
            guard unowned.terminationStatus != 0 else { throw SmokeFailure("unrecorded child accepted its gate") }
            if recorded {
                guard try Data(contentsOf: record) == previous else { throw SmokeFailure("child replaced another startup record") }
            } else if FileManager.default.fileExists(atPath: record.path) {
                throw SmokeFailure("child recreated missing startup record")
            }
        }

        let source = root.appendingPathComponent("source")
        try fixture(source)
        // Cloning invalid VM bytes exercises filesystem and identity work,
        // never Virtualization.framework startup. Exactly one clone may own
        // a destination; losers must not remove its files during cleanup.
        for round in 0..<5 {
            let destination = root.appendingPathComponent("clone-\(round)")
            var clones: [Process] = []
            defer { for process in clones { finish(process) } }
            for _ in 0..<16 {
                clones.append(try launch(binary, ["clone", "--source", source.path, "--destination", destination.path]))
            }
            for process in clones { process.waitUntilExit() }
            guard clones.filter({ $0.terminationStatus == 0 }).count == 1 else {
                throw SmokeFailure("concurrent clone did not have exactly one owner")
            }
            for name in ["config.json", "disk.img", "nvram.bin"] {
                guard FileManager.default.fileExists(atPath: destination.appendingPathComponent(name).path) else {
                    throw SmokeFailure("losing clone removed winner's \(name)")
                }
            }
            let second = root.appendingPathComponent("second-\(round)")
            let cloning = try launch(binary, ["clone", "--source", source.path, "--destination", second.path])
            defer { finish(cloning) }
            cloning.waitUntilExit()
            guard cloning.terminationStatus == 0 else { throw SmokeFailure("second clone failed") }
            let firstConfig = try JSONSerialization.jsonObject(with: Data(contentsOf: destination.appendingPathComponent("config.json"))) as! [String: Any]
            let secondConfig = try JSONSerialization.jsonObject(with: Data(contentsOf: second.appendingPathComponent("config.json"))) as! [String: Any]
            for name in ["ecid", "macAddress"] {
                guard let first = firstConfig[name] as? String, let next = secondConfig[name] as? String, first != next else {
                    throw SmokeFailure("clones reused \(name)")
                }
            }
            try Data("changed clone".utf8).write(to: second.appendingPathComponent("disk.img"))
            guard try Data(contentsOf: source.appendingPathComponent("disk.img")) == Data("invalid test fixture".utf8) else {
                throw SmokeFailure("clone writes changed the source disk")
            }
        }
        print("Strict arguments, typed failures, lifecycle serialization, launcher EOF and concurrent fresh-clone checks passed")
    }

    static func fixture(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
        for name in ["disk.img", "nvram.bin"] {
            try Data("invalid test fixture".utf8).write(to: directory.appendingPathComponent(name))
        }
    }

    static func launch(_ binary: URL, _ arguments: [String], input: FileHandle = .nullDevice) throws -> Process {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    static func assertFailure(_ binary: URL, _ arguments: [String], status: Int32, kind: String) throws {
        let errors = Pipe()
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == status,
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["ok"] as? Bool == false,
              let error = payload["error"] as? [String: Any],
              error["kind"] as? String == kind,
              error["message"] as? String != nil else {
            throw SmokeFailure("expected status \(status) and typed \(kind) failure for \(arguments)")
        }
    }

    static func finish(_ process: Process) {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }
}
