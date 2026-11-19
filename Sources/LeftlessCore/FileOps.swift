import Foundation

public protocol FileMoving: Sendable {
    /// Öğeyi Çöp Sepeti'ne taşır; Çöp'teki yeni konumu döndürür.
    func trash(_ url: URL) throws -> URL
    /// Hedef zaten varsa üzerine yazmaz, hata fırlatır.
    func move(_ from: URL, to: URL) throws
    func exists(_ url: URL) -> Bool
    func createDirectory(_ url: URL) throws
}

public struct SystemFileMover: FileMoving {
    public init() {}

    public func trash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let trashed = result as URL? else {
            throw CocoaError(.fileWriteUnknown)
        }
        return trashed
    }

    public func move(_ from: URL, to: URL) throws {
        // moveItem zaten mevcut hedefte hata verir; üzerine yazma yok.
        try FileManager.default.moveItem(at: from, to: to)
    }

    public func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

public enum PrivilegedError: Error, Equatable, Sendable {
    case cancelled
    case failed(String)
}

public protocol PrivilegedExecuting: Sendable {
    /// Tüm komutları tek bir yönetici şifre penceresiyle çalıştırır.
    func run(_ commands: [String]) throws
}

public struct OsascriptPrivilegedExecutor: PrivilegedExecuting {
    private let commands: CommandRunning

    public init(commands: CommandRunning = ProcessCommandRunner()) {
        self.commands = commands
    }

    public func run(_ commandList: [String]) throws {
        guard !commandList.isEmpty else { return }
        let shell = commandList.joined(separator: " && ")
        let script = "do shell script \"\(ShellQuoting.appleScriptString(shell))\" with administrator privileges"
        let out = try commands.run("/usr/bin/osascript", ["-e", script])
        guard out.status != 0 else { return }
        if out.stderr.contains("-128") { throw PrivilegedError.cancelled }
        throw PrivilegedError.failed(out.stderr)
    }
}

public enum ShellQuoting {
    /// Tek tırnak içine alır; içerideki ' → '\'' .
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript çift tırnaklı dize için \ ve " kaçışı.
    public static func appleScriptString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Çöp'te çakışmayan ad üretir: "Ad.uzantı" → "Ad 2.uzantı", "Ad 3.uzantı"...
public func uniqueTrashURL(for original: URL, trashDirectory: URL, fileExists: (URL) -> Bool) -> URL {
    let name = original.lastPathComponent
    let first = trashDirectory.appendingPathComponent(name)
    guard fileExists(first) else { return first }
    let ext = original.pathExtension
    let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
    var n = 2
    while true {
        let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
        let url = trashDirectory.appendingPathComponent(candidate)
        if !fileExists(url) { return url }
        n += 1
    }
}
