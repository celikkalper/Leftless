import Foundation

public protocol ReceiptProviding: Sendable {
    func packageIDs() -> [String]
    /// Paketin kurduğu dosyaların mutlak yolları.
    func installedPaths(forPackage id: String) -> [String]
}

public struct PkgutilReceiptProvider: ReceiptProviding {
    private let commands: CommandRunning
    private let pkgutil = "/usr/sbin/pkgutil"

    public init(commands: CommandRunning = ProcessCommandRunner()) {
        self.commands = commands
    }

    public func packageIDs() -> [String] {
        guard let out = try? commands.run(pkgutil, ["--pkgs"]), out.status == 0 else { return [] }
        return lines(out.stdout)
    }

    public func installedPaths(forPackage id: String) -> [String] {
        guard let info = try? commands.run(pkgutil, ["--pkg-info", id]), info.status == 0,
              let files = try? commands.run(pkgutil, ["--only-files", "--files", id]), files.status == 0
        else { return [] }
        var volume = "/", location = ""
        for line in lines(info.stdout) {
            if line.hasPrefix("volume:") { volume = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("location:") { location = String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces) }
        }
        return lines(files.stdout).map { "/" + [volume, location, $0].map(Self.trimSlashes).filter { !$0.isEmpty }.joined(separator: "/") }
    }

    private static func trimSlashes(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }

    private func lines(_ s: String) -> [String] {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Uygulamayla eşleşen pkg kayıtlarının kurduğu dosyaları bulur.
public struct ReceiptScanner: Sendable {
    private let environment: ScanEnvironment
    private let provider: ReceiptProviding

    public init(environment: ScanEnvironment, provider: ReceiptProviding) {
        self.environment = environment
        self.provider = provider
    }

    /// `excluding`: zaten listelenmiş URL'ler; bunların altındaki yollar eklenmez.
    public func scan(_ app: AppInfo, keys: MatchKeys, installedApps: [AppInfo],
                     excluding: [URL] = []) -> [Leftover] {
        var taken = excluding.map { $0.standardizedFileURL.path }
        let libraries = [environment.path("/Library"), environment.homePath("Library")].map { $0.standardizedFileURL.path }
        var result: [Leftover] = []
        for id in provider.packageIDs() {
            guard let (pkgConfidence, note) = LeftoverScanner.evaluate(id, app: app, keys: keys,
                                                                       installedApps: installedApps) else { continue }
            for absolute in provider.installedPaths(forPackage: id) {
                let url = environment.path(absolute)
                let path = url.standardizedFileURL.path
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
                      !ProtectedPaths.isProtected(url, root: environment.root),
                      !url.pathComponents.contains(where: { $0.hasSuffix(".app") }),
                      !taken.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
                let inLibrary = libraries.contains { path.hasPrefix($0 + "/") }
                let home = environment.home.standardizedFileURL.path
                result.append(Leftover(url: url, kind: .packageFile, confidence: inLibrary ? pkgConfidence : .probable,
                                       size: directorySize(url), requiresAdmin: !(path.hasPrefix(home + "/")),
                                       packageID: id, note: note))
                taken.append(path)
            }
        }
        return result
    }
}
