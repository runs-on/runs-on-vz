import Darwin
import Foundation
@preconcurrency import Virtualization

private enum ExitCode: Int32 {
    case usage = 64
    case unavailable = 69
    case software = 70
    case io = 74
    case configuration = 78
}

private struct CLIError: Error, CustomStringConvertible {
    let code: ExitCode
    let kind: String
    let message: String

    var description: String { message }
}

private struct Arguments {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ raw: ArraySlice<String>, valueNames: Set<String>, flagNames: Set<String>) throws {
        var iterator = raw.makeIterator()
        while let argument = iterator.next() {
            guard argument.hasPrefix("--") else {
                throw CLIError(code: .usage, kind: "invalid_argument", message: "unexpected argument \(argument)")
            }
            if flagNames.contains(argument) {
                guard !flags.contains(argument) else {
                    throw CLIError(code: .usage, kind: "duplicate_argument", message: "\(argument) was provided more than once")
                }
                flags.insert(argument)
            } else if valueNames.contains(argument) {
                guard values[argument] == nil else {
                    throw CLIError(code: .usage, kind: "duplicate_argument", message: "\(argument) was provided more than once")
                }
                guard let value = iterator.next(), !value.hasPrefix("--") else {
                    throw CLIError(code: .usage, kind: "missing_value", message: "\(argument) requires a value")
                }
                values[argument] = value
            } else {
                throw CLIError(code: .usage, kind: "unknown_option", message: "unknown option \(argument)")
            }
        }
    }

    func require(_ name: String) throws -> String {
        guard let value = values[name], !value.isEmpty else {
            throw CLIError(code: .usage, kind: "missing_argument", message: "\(name) is required")
        }
        return value
    }

    func integer(_ name: String, default defaultValue: Int? = nil) throws -> Int {
        guard let raw = values[name] else {
            if let defaultValue { return defaultValue }
            throw CLIError(code: .usage, kind: "missing_argument", message: "\(name) is required")
        }
        guard let value = Int(raw), value > 0 else {
            throw CLIError(code: .usage, kind: "invalid_argument", message: "\(name) must be a positive integer")
        }
        return value
    }

    func has(_ name: String) -> Bool { flags.contains(name) }
    func optional(_ name: String) -> String? { values[name] }
}

private enum JSONOutput {
    static func success(_ fields: [String: Any] = [:]) {
        var payload = fields
        payload["ok"] = true
        write(payload, to: FileHandle.standardOutput)
    }

    static func failure(_ error: CLIError) {
        write(["ok": false, "error": ["kind": error.kind, "message": error.message]], to: FileHandle.standardError)
    }

    private static func write(_ payload: [String: Any], to handle: FileHandle) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        handle.write(data)
        handle.write(Data([0x0a]))
    }
}

private struct VMDirectory {
    let url: URL
    var config: URL { url.appendingPathComponent("config.json") }
    var disk: URL { url.appendingPathComponent("disk.img") }
    var nvram: URL { url.appendingPathComponent("nvram.bin") }
    var pid: URL { url.appendingPathComponent("run.pid") }
    var result: URL { url.appendingPathComponent("run.result") }
    var log: URL { url.appendingPathComponent("run.log") }

    func validate() throws {
        for file in [config, disk, nvram] where !FileManager.default.fileExists(atPath: file.path) {
            throw CLIError(code: .configuration, kind: "invalid_vm", message: "missing \(file.lastPathComponent) in \(url.path)")
        }
    }
}

private struct VMConfig {
    let cpuCountMin: Int
    let memorySizeMin: UInt64
    let macAddress: VZMACAddress
    let hardwareModel: VZMacHardwareModel
    let machineIdentifier: VZMacMachineIdentifier
    let width: Int
    let height: Int

    init(url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CLIError(code: .io, kind: "read_config", message: "read \(url.path): \(error.localizedDescription)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError(code: .configuration, kind: "invalid_config", message: "config.json is not a JSON object")
        }
        guard let cpuCountMin = json["cpuCountMin"] as? Int,
              let memorySizeMin = Self.uint64(json["memorySizeMin"]),
              let macString = json["macAddress"] as? String,
              let macAddress = VZMACAddress(string: macString),
              let hardwareString = json["hardwareModel"] as? String,
              let hardwareData = Data(base64Encoded: hardwareString),
              let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareData),
              let machineString = json["ecid"] as? String,
              let machineData = Data(base64Encoded: machineString),
              let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: machineData) else {
            throw CLIError(code: .configuration, kind: "invalid_config", message: "config.json lacks valid macOS VM identity or resource fields")
        }
        let display = json["display"] as? [String: Any]
        self.cpuCountMin = cpuCountMin
        self.memorySizeMin = memorySizeMin
        self.macAddress = macAddress
        self.hardwareModel = hardwareModel
        self.machineIdentifier = machineIdentifier
        width = display?["width"] as? Int ?? 1024
        height = display?["height"] as? Int ?? 768
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber { return number.uint64Value }
        if let text = value as? String { return UInt64(text) }
        return nil
    }
}

private func cloneVM(source: VMDirectory, destination: VMDirectory) throws {
    try source.validate()
    guard !FileManager.default.fileExists(atPath: destination.url.path) else {
        throw CLIError(code: .configuration, kind: "destination_exists", message: "destination already exists: \(destination.url.path)")
    }
    let lock = try VMDirectoryLock.create(destination.url)
    defer { lock.release() }
    do {
        try cloneFile(source.disk, destination.disk)
        try cloneFile(source.nvram, destination.nvram)
        try cloneConfig(source.config, destination.config)
    } catch {
        try? lock.removeDirectory()
        throw error
    }
}

private func cloneFile(_ source: URL, _ destination: URL) throws {
    if clonefile(source.path, destination.path, 0) != 0 {
        throw CLIError(code: .io, kind: "clonefile", message: "clone \(source.lastPathComponent): \(String(cString: strerror(errno)))")
    }
}

private func cloneConfig(_ source: URL, _ destination: URL) throws {
    let data = try Data(contentsOf: source)
    guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CLIError(code: .configuration, kind: "invalid_config", message: "config.json is not a JSON object")
    }
    json["macAddress"] = VZMACAddress.randomLocallyAdministered().string
    json["ecid"] = VZMacMachineIdentifier().dataRepresentation.base64EncodedString()
    let encoded = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    try encoded.write(to: destination, options: .atomic)
}

@MainActor
private final class VirtualMachineSession: NSObject {
    let machine: VZVirtualMachine
    private var bootstrapChannel: BootstrapChannel?
    private var stopped = false
    private var stopFailure: String?
    private var stopRequested = false

    init(directory: VMDirectory, cpus: Int, memoryMiB: Int, bootstrapFile: String?) throws {
        let imageConfig = try VMConfig(url: directory.config)
        guard cpus >= imageConfig.cpuCountMin else {
            throw CLIError(code: .configuration, kind: "insufficient_cpu", message: "VM requires at least \(imageConfig.cpuCountMin) CPUs")
        }
        let memoryBytes = UInt64(memoryMiB) * 1024 * 1024
        guard memoryBytes >= imageConfig.memorySizeMin else {
            throw CLIError(code: .configuration, kind: "insufficient_memory", message: "VM requires at least \(imageConfig.memorySizeMin) bytes of memory")
        }

        let configuration = VZVirtualMachineConfiguration()
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.cpuCount = cpus
        configuration.memorySize = memoryBytes

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = imageConfig.hardwareModel
        platform.machineIdentifier = imageConfig.machineIdentifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: directory.nvram)
        configuration.platform = platform

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: imageConfig.width, heightInPixels: imageConfig.height, pixelsPerInch: 80)]
        configuration.graphicsDevices = [graphics]

        configuration.keyboards = [VZMacKeyboardConfiguration()]
        configuration.pointingDevices = [VZMacTrackpadConfiguration()]

        let sound = VZVirtioSoundDeviceConfiguration()
        sound.streams = [VZVirtioSoundDeviceOutputStreamConfiguration()]
        configuration.audioDevices = [sound]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        network.macAddress = imageConfig.macAddress
        configuration.networkDevices = [network]

        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: directory.disk, readOnly: false, cachingMode: .automatic, synchronizationMode: .full)
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        let consolePort = VZVirtioConsolePortConfiguration()
        consolePort.name = "runs-on-vz"
        let console = VZVirtioConsoleDeviceConfiguration()
        console.ports[0] = consolePort
        configuration.consoleDevices = [console]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        try configuration.validate()

        machine = VZVirtualMachine(configuration: configuration)
        super.init()
        machine.delegate = self
        if let bootstrapFile {
            let channel = try BootstrapChannel(path: bootstrapFile)
            guard let socket = machine.socketDevices.first as? VZVirtioSocketDevice else {
                throw CLIError(code: .configuration, kind: "missing_socket", message: "VM socket device is unavailable")
            }
            socket.setSocketListener(channel.listener, forPort: 1024)
            bootstrapChannel = channel
        }
    }

    func run() async throws {
        try await machine.start(options: VZMacOSVirtualMachineStartOptions())
        if stopRequested { stopRunningMachine() }
        FileHandle.standardError.write(Data("runs-on-vz: started\n".utf8))
        while !stopped && machine.state != .stopped && machine.state != .error {
            try await Task.sleep(for: .milliseconds(250))
        }
        if let stopFailure {
            throw CLIError(code: .software, kind: "vm_crashed", message: "VM stopped with an error: \(stopFailure)")
        }
        if machine.state == .error {
            throw CLIError(code: .software, kind: "vm_crashed", message: "VM entered the error state")
        }
    }

    func requestStop() {
        stopRequested = true
        if machine.state == .running { stopRunningMachine() }
    }

    private func stopRunningMachine() {
        do {
            try machine.requestStop()
        } catch {
            Task { try? await machine.stop() }
        }
    }
}

extension VirtualMachineSession: VZVirtualMachineDelegate {
    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in stopped = true }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            stopFailure = message
            stopped = true
        }
    }
}

private func argumentSchema(for command: String) throws -> (values: Set<String>, flags: Set<String>) {
    let json = Set(["--json"])
    switch command {
    case "clone":
        return (["--source", "--destination"], json)
    case "run":
        return (["--vm", "--cpus", "--memory-mib", "--bootstrap-file"], json.union(["--detach"]))
    case "internal-run":
        return (["--vm", "--cpus", "--memory-mib", "--bootstrap-file"], [])
    case "wait", "ip", "delete":
        return (["--vm"], json)
    case "stop":
        return (["--vm", "--grace-seconds"], json)
    default:
        throw CLIError(code: .usage, kind: "unknown_command", message: "unknown command \(command)")
    }
}

private func startDetached(directory: VMDirectory, cpus: Int, memoryMiB: Int, bootstrapFile: String?) throws {
    let lock = try VMDirectoryLock(directory.url)
    defer { lock.release() }
    try directory.validate()
    if let identity = try ProcessIdentity.read(directory.pid), try identity.isRunning() {
        throw CLIError(code: .unavailable, kind: "already_running", message: "VM is already running")
    }
    try? FileManager.default.removeItem(at: directory.pid)
    try? FileManager.default.removeItem(at: directory.result)
    FileManager.default.createFile(atPath: directory.log.path, contents: nil)
    let log = try FileHandle(forWritingTo: directory.log)
    try log.truncate(atOffset: 0)

    let process = Process()
    process.executableURL = executableURL()
    process.arguments = ["internal-run", "--vm", directory.url.path, "--cpus", String(cpus), "--memory-mib", String(memoryMiB)]
    if let bootstrapFile {
        process.arguments?.append(contentsOf: ["--bootstrap-file", bootstrapFile])
    }
    process.standardOutput = log
    process.standardError = log
    let gate = Pipe()
    process.standardInput = gate
    defer { try? gate.fileHandleForWriting.close() }
    do {
        try process.run()
    } catch {
        try? log.close()
        throw CLIError(code: .software, kind: "start_process", message: "start VM process: \(error.localizedDescription)")
    }
    guard let identity = try ProcessIdentity.current(process.processIdentifier) else {
        throw CLIError(code: .software, kind: "process_identity", message: "VM child exited before startup")
    }
    try identity.write(directory.pid)
    // EOF without this gate means the launcher died before recording the
    // child. Such a child must exit without touching Virtualization.framework.
    try gate.fileHandleForWriting.write(contentsOf: Data("start\n".utf8))
    try gate.fileHandleForWriting.close()
    try? log.close()

    for _ in 0..<100 {
        if try !identity.isRunning() {
            if let recorded = try? ProcessIdentity.read(directory.pid), recorded == identity {
                try? FileManager.default.removeItem(at: directory.pid)
            }
            throw CLIError(code: .software, kind: "vm_start_failed", message: "VM process exited; see \(directory.log.path)")
        }
        if let contents = try? String(contentsOf: directory.log, encoding: .utf8), contents.contains("runs-on-vz: started") {
            return
        }
        usleep(50_000)
    }
    do {
        try stopVM(directory: directory, graceSeconds: 1)
    } catch {
        throw CLIError(code: .software, kind: "start_timeout_cleanup", message: "VM did not report startup and could not be stopped: \(error.localizedDescription)")
    }
    throw CLIError(code: .software, kind: "start_timeout", message: "VM did not report startup; see \(directory.log.path)")
}

@MainActor
private func runRecordedForeground(directory: VMDirectory, identity: ProcessIdentity, cpus: Int, memoryMiB: Int, bootstrapFile: String?) async throws {
    guard try ProcessIdentity.read(directory.pid) == identity else {
        throw CLIError(code: .software, kind: "process_identity", message: "VM process no longer owns its startup record")
    }
    // The launcher records the child before opening its gate. Never recreate
    // a missing or replaced record after another owner has started cleanup.
    let session = try VirtualMachineSession(directory: directory, cpus: cpus, memoryMiB: memoryMiB, bootstrapFile: bootstrapFile)
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    term.setEventHandler { session.requestStop() }
    interrupt.setEventHandler { session.requestStop() }
    term.resume()
    interrupt.resume()
    defer {
        term.cancel()
        interrupt.cancel()
    }
    do {
        try await session.run()
        try RunResult(identity: identity, failure: nil).write(directory.result)
    } catch {
        let failure = wrap(error)
        try? RunResult(identity: identity, failure: RunFailure(kind: failure.kind, message: failure.message)).write(directory.result)
        throw error
    }
}

private func stopVM(directory: VMDirectory, graceSeconds: Int) throws {
    guard let identity = try ProcessIdentity.read(directory.pid) else {
        return
    }
    let pid = identity.pid
    guard try identity.isRunning() else {
        try? FileManager.default.removeItem(at: directory.pid)
        return
    }
    if kill(pid, SIGTERM) != 0 {
        throw CLIError(code: .software, kind: "signal", message: "signal VM process \(pid): \(String(cString: strerror(errno)))")
    }
    let deadline = Date().addingTimeInterval(TimeInterval(graceSeconds))
    while Date() < deadline {
        if try !identity.isRunning() {
            try? FileManager.default.removeItem(at: directory.pid)
            return
        }
        usleep(100_000)
    }
    if try identity.isRunning(), kill(pid, SIGKILL) != 0 && errno != ESRCH {
        throw CLIError(code: .software, kind: "force_stop", message: "force-stop VM process \(pid): \(String(cString: strerror(errno)))")
    }
    let killDeadline = Date().addingTimeInterval(5)
    while try identity.isRunning() && Date() < killDeadline { usleep(100_000) }
    guard try !identity.isRunning() else {
        throw CLIError(code: .software, kind: "stop_timeout", message: "VM process did not exit after force-stop")
    }
    try? FileManager.default.removeItem(at: directory.pid)
}

private func recordForegroundProcess(directory: VMDirectory) throws -> ProcessIdentity {
    let lock = try VMDirectoryLock(directory.url)
    defer { lock.release() }
    if let previous = try ProcessIdentity.read(directory.pid), try previous.isRunning() {
        throw CLIError(code: .unavailable, kind: "already_running", message: "VM is already running")
    }
    guard let identity = try ProcessIdentity.current(getpid()) else {
        throw CLIError(code: .software, kind: "process_identity", message: "cannot identify VM process")
    }
    try? FileManager.default.removeItem(at: directory.result)
    try identity.write(directory.pid)
    return identity
}

private func cleanupVM(directory: VMDirectory, graceSeconds: Int, delete: Bool) throws {
    let lock: VMDirectoryLock
    do {
        lock = try VMDirectoryLock(directory.url)
    } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
        return // Cleanup is idempotent when the VM directory is already gone.
    }
    defer { lock.release() }
    try stopVM(directory: directory, graceSeconds: graceSeconds)
    if delete { try lock.removeDirectory() }
}

private func waitVM(directory: VMDirectory) throws {
    guard let identity = try ProcessIdentity.read(directory.pid) else {
        throw CLIError(code: .software, kind: "process_identity", message: "VM process identity is missing")
    }
    while try identity.isRunning() { usleep(100_000) }
    let result: RunResult?
    do {
        result = try RunResult.read(directory.result)
    } catch {
        throw CLIError(code: .software, kind: "invalid_result", message: "read VM result: \(error.localizedDescription)")
    }
    guard let result else {
        throw CLIError(code: .software, kind: "unexpected_exit", message: "VM process exited without recording a result")
    }
    guard result.identity == identity else {
        throw CLIError(code: .software, kind: "stale_result", message: "VM result does not match the observed process")
    }
    if let failure = result.failure {
        throw CLIError(code: .software, kind: failure.kind, message: failure.message)
    }
}

private func findIPAddress(directory: VMDirectory, timeoutSeconds: Int = 120) throws -> String {
    let config = try VMConfig(url: directory.config)
    let wantedMAC = config.macAddress.string.lowercased()
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
    while Date() < deadline {
        if let leases = try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8),
           let address = addressFromLeases(leases, macAddress: wantedMAC) {
            return address
        }
        usleep(500_000)
    }
    throw CLIError(code: .unavailable, kind: "ip_timeout", message: "no DHCP lease for \(wantedMAC) after \(timeoutSeconds) seconds")
}

private func addressFromLeases(_ contents: String, macAddress: String) -> String? {
    guard let wantedMAC = normalizedMACAddress(macAddress) else { return nil }
    for block in contents.components(separatedBy: "}") {
        var fields: [String: String] = [:]
        for line in block.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        let leaseMAC = fields["hw_address"]?.split(separator: ",", maxSplits: 1).last.flatMap {
            normalizedMACAddress(String($0))
        }
        if leaseMAC == wantedMAC, let address = fields["ip_address"], !address.isEmpty { return address }
    }
    return nil
}

func normalizedMACAddress(_ address: String) -> String? {
    let octets = address.split(separator: ":", omittingEmptySubsequences: false)
    guard octets.count == 6 else { return nil }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(6)
    for octet in octets {
        guard !octet.isEmpty, octet.count <= 2, let byte = UInt8(octet, radix: 16) else { return nil }
        bytes.append(byte)
    }
    return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
}

private func executableURL() -> URL {
    if let url = Bundle.main.executableURL { return url }
    let argument = CommandLine.arguments[0]
    if argument.hasPrefix("/") { return URL(fileURLWithPath: argument) }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(argument)
}

private func wrap(_ error: any Error) -> CLIError {
    if let error = error as? CLIError { return error }
    return CLIError(code: .software, kind: "internal", message: error.localizedDescription)
}

@main
private enum RunsOnVZ {
    static func main() async {
        do {
            guard CommandLine.arguments.count >= 2 else {
                throw CLIError(code: .usage, kind: "missing_command", message: "usage: runs-on-vz <clone|run|wait|ip|stop|delete> [options]")
            }
            let command = CommandLine.arguments[1]
            let schema = try argumentSchema(for: command)
            let arguments = try Arguments(CommandLine.arguments.dropFirst(2), valueNames: schema.values, flagNames: schema.flags)
            switch command {
            case "clone":
                let source = VMDirectory(url: URL(fileURLWithPath: try arguments.require("--source")))
                let destination = VMDirectory(url: URL(fileURLWithPath: try arguments.require("--destination")))
                try cloneVM(source: source, destination: destination)
                JSONOutput.success()
            case "run":
                let directory = VMDirectory(url: URL(fileURLWithPath: try arguments.require("--vm")))
                let cpus = try arguments.integer("--cpus")
                let memoryMiB = try arguments.integer("--memory-mib")
                let bootstrapFile = arguments.optional("--bootstrap-file")
                if arguments.has("--detach") {
                    try startDetached(directory: directory, cpus: cpus, memoryMiB: memoryMiB, bootstrapFile: bootstrapFile)
                    JSONOutput.success()
                } else {
                    let identity = try recordForegroundProcess(directory: directory)
                    try await runRecordedForeground(directory: directory, identity: identity, cpus: cpus, memoryMiB: memoryMiB, bootstrapFile: bootstrapFile)
                    JSONOutput.success()
                }
            case "internal-run":
                guard readLine() == "start" else {
                    throw CLIError(code: .software, kind: "start_cancelled", message: "VM launcher did not authorize startup")
                }
                let directory = VMDirectory(url: URL(fileURLWithPath: try arguments.require("--vm")))
                guard let identity = try ProcessIdentity.current(getpid()) else {
                    throw CLIError(code: .software, kind: "process_identity", message: "cannot identify VM process")
                }
                try await runRecordedForeground(directory: directory, identity: identity, cpus: try arguments.integer("--cpus"), memoryMiB: try arguments.integer("--memory-mib"), bootstrapFile: arguments.optional("--bootstrap-file"))
            case "wait":
                try waitVM(directory: VMDirectory(url: URL(fileURLWithPath: try arguments.require("--vm"))))
                JSONOutput.success()
            case "ip":
                let directory = VMDirectory(url: URL(fileURLWithPath: try arguments.require("--vm")))
                JSONOutput.success(["ip": try findIPAddress(directory: directory)])
            case "stop":
                let directory = VMDirectory(url: URL(fileURLWithPath: try arguments.require("--vm")))
                try cleanupVM(directory: directory, graceSeconds: try arguments.integer("--grace-seconds", default: 30), delete: false)
                JSONOutput.success()
            case "delete":
                let directory = VMDirectory(url: URL(fileURLWithPath: try arguments.require("--vm")))
                try cleanupVM(directory: directory, graceSeconds: 5, delete: true)
                JSONOutput.success()
            default:
                throw CLIError(code: .usage, kind: "unknown_command", message: "unknown command \(command)")
            }
        } catch {
            let cliError = wrap(error)
            JSONOutput.failure(cliError)
            Darwin.exit(cliError.code.rawValue)
        }
    }
}
