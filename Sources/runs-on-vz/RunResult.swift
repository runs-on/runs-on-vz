import Foundation

struct RunFailure: Codable, Equatable {
    let kind: String
    let message: String
}

struct RunResult: Codable, Equatable {
    let identity: ProcessIdentity
    let failure: RunFailure?

    static func read(_ path: URL) throws -> RunResult? {
        do { return try JSONDecoder().decode(Self.self, from: Data(contentsOf: path)) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }

    func write(_ path: URL) throws {
        try writeDurably(JSONEncoder().encode(self), to: path)
    }
}
