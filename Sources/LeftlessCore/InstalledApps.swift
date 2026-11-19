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

/// Bu Mac'teki uygulamaların kimlikleri ve adları (yetim taraması için sahiplik bilgisi).
public struct KnownApps: Sendable {
    public var bundleIDs: Set<String>
    /// Normalize adlar: küçük harf, yalnızca harf/rakam; genel adlar ve 4 karakterden kısalar atılır.
    public var names: Set<String>

    public init(bundleIDs: Set<String>, names: some Sequence<String> = []) {
        self.bundleIDs = bundleIDs
        self.names = Set(names.map(Self.normalize).filter {
            $0.count >= 4 && !MatchKeys.genericNames.contains($0)
        })
    }

    /// Küçük harf; harf ve rakam dışındaki her şey atılır ("Riot Client" → "riotclient").
    static func normalize(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
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
        let apps = infos().map { InstalledApp(info: $0, bundleSize: directorySize($0.url)) }
        return apps.sorted {
            let c = $0.info.name.localizedCaseInsensitiveCompare($1.info.name)
            return c == .orderedSame ? $0.id < $1.id : c == .orderedAscending
        }
    }

    /// Yüklü uygulamaların kimlik bilgileri; boyut hesaplanmaz (tarama sırasında hızlı koruma listesi için).
    public func infos() -> [AppInfo] {
        let dirs = [environment.path("/Applications"), environment.homePath("Applications")]
        var result: [AppInfo] = []
        for dir in dirs {
            for appURL in appBundles(in: dir, depth: 1) {
                guard let info = try? inspector.inspect(appURL, includeTeamID: false),
                      !ProtectedPaths.isAppleBundleID(info.bundleID) else { continue }
                result.append(info)
            }
        }
        return result
    }

    /// Bu Mac'teki tüm uygulamaların bundle ID'leri (Apple uygulamaları dahil): /Applications ve
    /// ~/Applications (2 alt klasör seviyesi), /System/Applications ve Spotlight'ın bildiği her uygulama.
    /// mdfind başarısız olursa yalnızca klasör tabanlı liste kullanılır.
    public func allKnownBundleIDs(commands: CommandRunning) -> Set<String> {
        knownApps(commands: commands).bundleIDs
    }

    /// `allKnownBundleIDs` ile aynı uygulamalar; bundle ID'lerle birlikte normalize edilmiş adlar
    /// (paket dosya adı, CFBundleName, CFBundleExecutable).
    public func knownApps(commands: CommandRunning) -> KnownApps {
        var bundles: [URL] = []
        for dir in [environment.path("/Applications"), environment.homePath("Applications")] {
            bundles += appBundles(in: dir, depth: 2)
        }
        bundles += appBundles(in: environment.path("/System/Applications"), depth: 2)
        if let out = try? commands.run("/usr/bin/mdfind", ["kMDItemContentType == 'com.apple.application-bundle'"]),
           out.status == 0 {
            for line in out.stdout.split(whereSeparator: \.isNewline) {
                let path = line.trimmingCharacters(in: .whitespaces)
                if path.hasPrefix("/") { bundles.append(URL(fileURLWithPath: path, isDirectory: true)) }
            }
        }
        var ids = Set<String>()
        var names: [String] = []
        for bundle in bundles {
            let plistURL = bundle.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: plistURL),
                  let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  let id = plist["CFBundleIdentifier"] as? String, !id.isEmpty else { continue }
            ids.insert(id)
            names.append(bundle.deletingPathExtension().lastPathComponent)
            names += [plist["CFBundleName"], plist["CFBundleExecutable"]].compactMap { $0 as? String }
        }
        return KnownApps(bundleIDs: ids, names: names)
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
