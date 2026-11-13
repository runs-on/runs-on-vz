import Darwin
import Foundation

@main
struct ProcessIdentitySmoke {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vz-identity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = directory.appendingPathComponent("run.pid")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        guard let identity = try ProcessIdentity.current(child.processIdentifier) else { fatalError("missing live identity") }
        guard try identity.isRunning() else { fatalError("live process not found") }
        let reused = ProcessIdentity(pid: identity.pid, startSeconds: identity.startSeconds + 1, startMicroseconds: identity.startMicroseconds)
        guard try !reused.isRunning() else { fatalError("accepted reused PID") }
        try reused.write(record)
        try command("stop", directory)
        guard child.isRunning else { fatalError("stopped unrelated process") }
        try identity.write(record)
        try RunResult(identity: identity, failure: nil).write(directory.appendingPathComponent("run.result"))
        guard try ProcessIdentity.read(record) == identity else { fatalError("identity did not round trip") }
        let waiter = try launch("wait", directory)
        usleep(100_000)
        guard waiter.isRunning else { fatalError("wait returned before process exited") }
        try command("stop", directory)
        waiter.waitUntilExit()
        child.waitUntilExit()
        guard waiter.terminationStatus == 0 else { fatalError("wait failed") }
        guard try !identity.isRunning() else { fatalError("stop returned with process alive") }
        guard try ProcessIdentity.read(record) == nil else { fatalError("stop retained process record") }

        let crashed = Process()
        crashed.executableURL = URL(fileURLWithPath: "/bin/sleep")
        crashed.arguments = ["30"]
        try crashed.run()
        guard let crashedIdentity = try ProcessIdentity.current(crashed.processIdentifier) else { fatalError("missing crash identity") }
        try crashedIdentity.write(record)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("run.result"))
        let crashWaiter = try launch("wait", directory)
        usleep(100_000)
        crashed.terminate()
        crashed.waitUntilExit()
        crashWaiter.waitUntilExit()
        guard crashWaiter.terminationStatus != 0 else { fatalError("wait accepted an exit without a result") }

        try Data("malformed".utf8).write(to: record)
        do { _ = try ProcessIdentity.read(record); fatalError("accepted malformed record") } catch {}
        print("Process identity, reused-PID protection, wait and stop checks passed")
    }

    static func launch(_ verb: String, _ directory: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        process.arguments = [verb, "--vm", directory.path]
        if verb == "stop" { process.arguments?.append(contentsOf: ["--grace-seconds", "1"]) }
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        return process
    }

    static func command(_ verb: String, _ directory: URL) throws {
        let process = try launch(verb, directory)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { fatalError("\(verb) failed") }
    }
}
