import Foundation

public struct CommandOutput: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Boru dolup kilitlenmesin diye süreç bitmeden okunur.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        process.waitUntilExit()
        group.wait()
        return CommandOutput(status: process.terminationStatus,
                             stdout: String(decoding: outData, as: UTF8.self),
                             stderr: String(decoding: errData, as: UTF8.self))
    }
}

/// Kök/home soyutlaması: testler sahte kök kullanır, canlı ortamda kök "/" olur.
public struct ScanEnvironment: Sendable {
    public var root: URL
    public var home: URL
    public var userCacheDir: URL?
    public var uid: uid_t

    public init(root: URL, home: URL, userCacheDir: URL? = nil, uid: uid_t) {
        self.root = root
        self.home = home
        self.userCacheDir = userCacheDir
        self.uid = uid
    }

    public static func live() -> ScanEnvironment {
        var cacheDir: URL?
        if let out = try? ProcessCommandRunner().run("/usr/bin/getconf", ["DARWIN_USER_CACHE_DIR"]),
           out.status == 0 {
            let p = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty { cacheDir = URL(fileURLWithPath: p, isDirectory: true) }
        }
        return ScanEnvironment(root: URL(fileURLWithPath: "/", isDirectory: true),
                               home: FileManager.default.homeDirectoryForCurrentUser,
                               userCacheDir: cacheDir, uid: getuid())
    }

    /// root + mutlak yol.
    public func path(_ absolute: String) -> URL {
        let rel = absolute.hasPrefix("/") ? String(absolute.dropFirst()) : absolute
        return rel.isEmpty ? root : root.appendingPathComponent(rel)
    }

    public func homePath(_ relative: String) -> URL {
        home.appendingPathComponent(relative)
    }
}
