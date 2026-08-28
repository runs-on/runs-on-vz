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

    init(_ raw: ArraySlice<String>) throws {
        var iterator = raw.makeIterator()
        while let argument = iterator.next() {
            guard argument.hasPrefix("--") else {
                throw CLIError(code: .usage, kind: "invalid_argument", message: "unexpected argument \(argument)")
            }
            switch argument {
            case "--json", "--detach":
                flags.insert(argument)
            default:
                guard let value = iterator.next(), !value.hasPrefix("--") else {
                    throw CLIError(code: .usage, kind: "missing_value", message: "\(argument) requires a value")
                }
                values[argument] = value
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
}

private enum JSONOutput {
    static func success(_ fields: [String: Any] = [:]) {
        var payload = fields
        payload["ok"] = true
        write(payload, to: FileHandle.standardOutput)
    }

    static func failure(_ error: CLIError) {
        write(["error": ["code": error.kind, "message": error.message]], to: FileHandle.standardError)
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
    do {
        try FileManager.default.createDirectory(at: destination.url, withIntermediateDirectories: false)
    } catch {
        throw CLIError(code: .io, kind: "create_destination", message: "create \(destination.url.path): \(error.localizedDescription)")
    }
    do {
        try cloneFile(source.disk, destination.disk)
        try cloneFile(source.nvram, destination.nvram)
        try cloneConfig(source.config, destination.config)
    } catch {
        try? FileManager.default.removeItem(at: destination.url)
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
    private var stopped = false

    init(directory: VMDirectory, cpus: Int, memoryMiB: Int) throws {
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
    }

    func run() async throws {
        try await machine.start(options: VZMacOSVirtualMachineStartOptions())
        while !stopped && machine.state != .stopped && machine.state != .error {
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    func requestStop() {
        guard machine.state == .running else { return }
        do {
            try machine.requestStop()
        } catch {
            Task { try? await machine.stop() }
        }
    }
}

extension VirtualMachineSession: @MainActor VZVirtualMachineDelegate {
    func guestDidStop(_ virtualMachine: VZVirtualMachine) { stopped = true }
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) { stopped = true }
}

private func startDetached(directory: VMDirectory, cpus: Int, memoryMiB: Int) throws {
    try directory.validate()
    if let pid = readPID(directory.pid), processExists(pid) {
        throw CLIError(code: .unavailable, kind: "already_running", message: "VM is already running with pid \(pid)")
    }
    try? FileManager.default.removeItem(at: directory.pid)
    FileManager.default.createFile(atPath: directory.log.path, contents: nil)
    let log = try FileHandle(forWritingTo: directory.log)
    try log.seekToEnd()

    let process = Process()
    process.executableURL = executableURL()
    process.arguments = ["internal-run", "--vm", directory.url.path, "--cpus", String(cpus), "--memory-mib", String(memoryMiB)]
    process.standardOutput = log
    process.standardError = log
    do {
        try process.run()
    } catch {
        try? log.close()
        throw CLIError(code: .software, kind: "start_process", message: "start VM process: \(error.localizedDescription)")
    }
    try Data("\(process.processIdentifier)\n".utf8).write(to: directory.pid, options: .atomic)
    try? log.close()

    for _ in 0..<100 {
        if !processExists(process.processIdentifier) {
            throw CLIError(code: .software, kind: "vm_start_failed", message: "VM process exited; see \(directory.log.path)")
        }
        if let contents = try? String(contentsOf: directory.log, encoding: .utf8), contents.contains("runs-on-vz: started") {
            return
        }
        usleep(50_000)
    }
}

@MainActor
private func runForeground(directory: VMDirectory, cpus: Int, memoryMiB: Int) async throws {
    let session = try VirtualMachineSession(directory: directory, cpus: cpus, memoryMiB: memoryMiB)
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
        if readPID(directory.pid) == getpid() { try? FileManager.default.removeItem(at: directory.pid) }
    }
    FileHandle.standardError.write(Data("runs-on-vz: started\n".utf8))
    try await session.run()
}

private func stopVM(directory: VMDirectory, graceSeconds: Int) throws {
    guard let pid = readPID(directory.pid) else {
        return
    }
    guard processExists(pid) else {
        try? FileManager.default.removeItem(at: directory.pid)
        return
    }
    if kill(pid, SIGTERM) != 0 {
        throw CLIError(code: .software, kind: "signal", message: "signal VM process \(pid): \(String(cString: strerror(errno)))")
    }
    let deadline = Date().addingTimeInterval(TimeInterval(graceSeconds))
    while Date() < deadline {
        if !processExists(pid) {
            try? FileManager.default.removeItem(at: directory.pid)
            return
        }
        usleep(100_000)
    }
    if kill(pid, SIGKILL) != 0 && errno != ESRCH {
        throw CLIError(code: .software, kind: "force_stop", message: "force-stop VM process \(pid): \(String(cString: strerror(errno)))")
    }
    try? FileManager.default.removeItem(at: directory.pid)
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
    for block in contents.components(separatedBy: "}") {
        var fields: [String: String] = [:]
        for line in block.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        let leaseMAC = fields["hw_address"]?.split(separator: ",", maxSplits: 1).last.map(String.init)?.lowercased()
        if leaseMAC == macAddress, let address = fields["ip_address"], !address.isEmpty { return address }
    }
    return nil
}

private func readPID(_ url: URL) -> pid_t? {
    guard let text = try? String(contentsOf: url, encoding: .utf8), let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), value > 1 else { return nil }
    return value
}

private func processExists(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
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
                throw CLIError(code: .usage, kind: "missing_command", message: "usage: runs-on-vz <clone|run|ip|stop|delete> [options]")
            }
            let command = CommandLine.arguments[1]
            let arguments = try Arguments(CommandLine.arguments.dropFirst(2))
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
                if arguments.has("--detach") {
                    try startDetached(directory: directory, cpus: cpus, memoryMiB: memoryMiB)
                    JSONOutput.success()
                } else {
                    try await runForeground(directory: directory, cpus: cpus, memoryMiB: memoryMiB)
                    JSONOutput.success()
                }
            case "internal-run":
                let directory = VMDirectory(url: URL(fileURLWithPath: try arguments.require("--vm")))
                try await runForeground(directory: directory, cpus: try arguments.integer("--cpus"), memoryMiB: try arguments.integer("--memory-mib"))
            case "ip":
                let directory = VMDirectory(url: URL(fileURLWithPath: try arguments.require("--vm")))
                JSONOutput.success(["ip": try findIPAddress(directory: directory)])
            case "stop":
                let directory = VMDirectory(url: URL(fileURLWithPath: try arguments.require("--vm")))
                try stopVM(directory: directory, graceSeconds: try arguments.integer("--grace-seconds", default: 30))
                JSONOutput.success()
            case "delete":
                let directory = VMDirectory(url: URL(fileURLWithPath: try arguments.require("--vm")))
                try stopVM(directory: directory, graceSeconds: 5)
                if FileManager.default.fileExists(atPath: directory.url.path) { try FileManager.default.removeItem(at: directory.url) }
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
