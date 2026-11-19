import Foundation

public struct InstalledApp: Identifiable, Hashable, Sendable {
    public var info: AppInfo
    public var bundleSize: Int64
    public var id: String { info.url.path }

    public init(info: AppInfo, bundleSize: Int64) {
        self.info = info
        self.bundleSize = bundleSize
    }
}

public struct InstalledApps: Sendable {
    private let environment: ScanEnvironment
    private let inspector: AppInspector

    public init(environment: ScanEnvironment, inspector: AppInspector) {
        self.environment = environment
        self.inspector = inspector
    }

    public func list() -> [InstalledApp] {
        let dirs = [environment.path("/Applications"), environment.homePath("Applications")]
        var apps: [InstalledApp] = []
        for dir in dirs {
            for appURL in appBundles(in: dir, depth: 1) {
                guard let info = try? inspector.inspect(appURL, includeTeamID: false),
                      !ProtectedPaths.isAppleBundleID(info.bundleID) else { continue }
                apps.append(InstalledApp(info: info, bundleSize: directorySize(appURL)))
            }
        }
        return apps.sorted {
            let c = $0.info.name.localizedCaseInsensitiveCompare($1.info.name)
            return c == .orderedSame ? $0.id < $1.id : c == .orderedAscending
        }
    }

    /// `dir` içindeki .app paketleri; `depth` kadar alt klasöre iner (.app içine inmez).
    private func appBundles(in dir: URL, depth: Int) -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var result: [URL] = []
        for item in items {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            if item.pathExtension == "app" { result.append(item) }
            else if depth > 0 { result += appBundles(in: item, depth: depth - 1) }
        }
        return result
    }
}

/// Klasörün (veya dosyanın) disk üzerindeki boyutu; sembolik linkleri takip etmez.
public func directorySize(_ url: URL) -> Int64 {
    let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isSymbolicLinkKey]
    func size(of u: URL) -> Int64 {
        guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return 0 }
        return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
    }
    var total = size(of: url)
    guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: []) else { return total }
    for case let u as URL in e { total += size(of: u) }
    return total
}
