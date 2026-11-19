import Foundation

/// Aynı kimlik köküne (ilk üç bileşen, ör. `com.vendor.app`) ait yetim öğeler.
public struct OrphanGroup: Identifiable, Sendable {
    /// Kimlik kökü (küçük harf).
    public var id: String
    public var displayName: String
    public var items: [Leftover]
    public var totalSize: Int64

    public init(id: String, displayName: String, items: [Leftover]) {
        self.id = id
        self.displayName = displayName
        self.items = items
        self.totalSize = items.reduce(0) { $0 + $1.size }
    }
}

public struct OrphanScanResult: Sendable {
    /// Toplam boyuta göre büyükten küçüğe.
    public var groups: [OrphanGroup]
    /// Kısıtlı taramada (Tam Disk Erişimi yok) aranmayan yerlerin görünen adları.
    public var skippedLocations: [String]

    public init(groups: [OrphanGroup], skippedLocations: [String] = []) {
        self.groups = groups
        self.skippedLocations = skippedLocations
    }
}

/// Bu Mac'teki hiçbir uygulamaya ait olmayan ~/Library öğelerini bulur.
/// Yalnızca reverse-DNS adlı girdiler (ve programı artık olmayan LaunchAgents) değerlendirilir;
/// emin olunamayan her şey sahipli sayılır (yanlış pozitif yerine yanlış negatif).
public struct OrphanScanner: Sendable {
    private let environment: ScanEnvironment
    /// Küçük harfli bilinen bundle ID'ler.
    private let known: Set<String>
    /// Normalize bilinen uygulama adları (bkz. `KnownApps.names`).
    private let knownNames: Set<String>
    private let restricted: Bool

    public init(environment: ScanEnvironment, knownApps: KnownApps, restricted: Bool = false) {
        self.environment = environment
        // Leftless'in kendisi her zaman sahiplidir (ör. kurulu kopya dışında çalışırken).
        self.known = Set(knownApps.bundleIDs.map { $0.lowercased() }).union(["com.leftless.app"])
        self.knownNames = knownApps.names
        self.restricted = restricted
    }

    /// Tek bir uygulamanın değil, birçok uygulamanın paylaştığı araç zinciri / SDK / çatı kimlikleri:
    /// her zaman sahipli sayılır (küçük harf önek eşleşmesi).
    static let sharedPrefixes = [
        "org.swift.", "org.llvm.", "io.branch.", "com.crashlytics", "io.fabric.", "com.plausiblelabs.",
        "com.electron.", "com.github.squirrel", "org.sparkle-project.", "com.google.keystone",
        "com.microsoft.autoupdate", "com.adobe.acc", "org.chromium.",
    ]

    private static let locations: [(name: String, kind: LeftoverKind)] = [
        ("Application Support", .applicationSupport), ("Caches", .caches),
        ("Preferences", .preferences), ("Preferences/ByHost", .preferences),
        ("Logs", .logs), ("Saved Application State", .savedState),
        ("HTTPStorages", .httpStorages), ("WebKit", .webKit), ("Cookies", .cookies),
        ("Containers", .container), ("Group Containers", .groupContainer),
    ]

    static let topLevelDomains: Set<String> = [
        "com", "org", "net", "io", "co", "app", "dev", "de", "us", "uk", "fr", "jp", "me", "tv", "ai", "info",
        "ch", "nl", "se",
    ]
    private static let strippedExtensions = ["plist", "savedstate", "binarycookies"]

    public func scan() -> OrphanScanResult {
        var found: [(root: String, item: Leftover)] = []
        for loc in Self.locations {
            if restricted, Self.restrictedKinds.contains(loc.kind) { continue }
            for entry in entries(of: environment.homePath("Library/\(loc.name)")) {
                guard !ProtectedPaths.isProtected(entry, root: environment.root),
                      let id = Self.identifier(entry.lastPathComponent, groupContainer: loc.kind == .groupContainer),
                      !isOwned(id) else { continue }
                found.append((Self.identifierRoot(id), leftover(entry, kind: loc.kind)))
            }
        }
        found += launchAgents()

        var byRoot: [String: (display: String, items: [Leftover])] = [:]
        for (root, item) in found {
            let key = root.lowercased()
            if byRoot[key] == nil { byRoot[key] = (Self.displayName(root), []) }
            byRoot[key]!.items.append(item)
        }
        let groups = byRoot.map { key, value in
            OrphanGroup(id: key, displayName: value.display, items: value.items.sorted {
                $0.size != $1.size ? $0.size > $1.size : $0.url.path < $1.url.path
            })
        }.sorted { $0.totalSize != $1.totalSize ? $0.totalSize > $1.totalSize : $0.id < $1.id }
        return OrphanScanResult(groups: groups,
                                skippedLocations: restricted ? Self.restrictedDisplayNames : [])
    }

    /// Tam Disk Erişimi olmadan okunamayan (izin penceresi tetikleyen) yerler.
    private static let restrictedKinds: Set<LeftoverKind> = [.container, .groupContainer, .cookies]
    private static var restrictedDisplayNames: [String] {
        [LeftoverScanner.containersDisplayName, LeftoverKind.cookies.displayName]
    }

    // MARK: - LaunchAgents

    /// ~/Library/LaunchAgents: mutlak program yolu varsa yalnızca o yol artık yoksa yetimdir;
    /// çözülebilir program yoksa ad reverse-DNS ve sahipsizse yetimdir.
    private func launchAgents() -> [(root: String, item: Leftover)] {
        var result: [(root: String, item: Leftover)] = []
        for file in entries(of: environment.homePath("Library/LaunchAgents")) where file.pathExtension == "plist" {
            guard !ProtectedPaths.isProtected(file, root: environment.root) else { continue }
            let plist = (try? Data(contentsOf: file))
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any]
            let label = plist?["Label"] as? String
            if let label, ProtectedPaths.isAppleBundleID(label) { continue }

            let id = Self.identifier(file.lastPathComponent, groupContainer: false)
            let orphan: Bool
            switch plist.map(programState) ?? .unresolvable {
            case .missing: orphan = true
            case .present: orphan = false
            case .unresolvable: orphan = id.map { !isOwned($0) } ?? false
            }
            guard orphan else { continue }

            let root = id.map(Self.identifierRoot)
                ?? label.flatMap { $0.isEmpty ? nil : Self.identifierRoot($0) }
                ?? file.deletingPathExtension().lastPathComponent
            var item = leftover(file, kind: .launchAgent)
            item.launchdLabel = label
            result.append((root, item))
        }
        return result
    }

    private enum ProgramState { case present, missing, unresolvable }

    /// Program / ProgramArguments[0]: mutlak değilse (ya da yoksa) çözülemez; orada hiçbir şey yoksa eksik.
    /// Sistem yolları (/System, /usr — /usr/local hariç —, /bin, /sbin, /Library/Apple) ve
    /// erişilemeyen yollar var sayılır.
    private func programState(_ plist: [String: Any]) -> ProgramState {
        let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
        guard let program, program.hasPrefix("/") else { return .unresolvable }
        let url = environment.path(program)
        guard !ProtectedPaths.isProtected(url, root: environment.root) else { return .present }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) || (try? fm.attributesOfItem(atPath: url.path)) != nil { return .present }
        // Var olan en yakın üst klasörde arama izni yoksa yokluğundan emin olunamaz.
        var ancestor = url.deletingLastPathComponent()
        while !fm.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            ancestor = ancestor.deletingLastPathComponent()
        }
        let searchable = fm.isExecutableFile(atPath: ancestor.path) && fm.isReadableFile(atPath: ancestor.path)
        return searchable ? .missing : .present
    }

    // MARK: - Kimlik

    /// Bilinen bir uygulamaya ait mi: Apple; paylaşılan araç/SDK önekleri; tam eşitlik; bilinen bir
    /// kimliğin noktalı uzantısı (`com.v.app.helper`); bilinen bir kimlikle aynı üretici öneki (`com.v.`);
    /// ya da TLD sonrası bir bileşenin bilinen bir uygulama adıyla eşleşmesi (`com.capcut.CapCut` ↔ CapCut.app).
    private func isOwned(_ identifier: String) -> Bool {
        let id = identifier.lowercased()
        if ProtectedPaths.isAppleBundleID(id) || known.contains(id) { return true }
        if Self.sharedPrefixes.contains(where: { id.hasPrefix($0) }) { return true }
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        let vendor = parts[0] + "." + parts[1] + "."
        if known.contains(where: { id.hasPrefix($0 + ".") || $0.hasPrefix(vendor) }) { return true }
        for part in parts.dropFirst() {
            let component = KnownApps.normalize(String(part))
            guard !component.isEmpty else { continue }
            for name in knownNames {
                if component.contains(name) { return true }   // eşitlik dahil; adlar ≥ 4 karakter
                if component.count >= 4, name.contains(component) { return true }
            }
        }
        return false
    }

    /// Girdi adından reverse-DNS kimliği; değilse nil. Bilinen uzantılar ve (Group Containers'ta)
    /// baştaki 10 karakterlik team ID atılır.
    static func identifier(_ entryName: String, groupContainer: Bool) -> String? {
        var name = entryName
        let ext = (name as NSString).pathExtension.lowercased()
        if strippedExtensions.contains(ext) { name = (name as NSString).deletingPathExtension }
        var parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if groupContainer, let first = parts.first, isTeamID(first) { parts.removeFirst() }
        guard parts.count >= 3, !parts.contains(where: \.isEmpty),
              topLevelDomains.contains(parts[0].lowercased()) else { return nil }
        return parts.joined(separator: ".")
    }

    private static func isTeamID(_ s: String) -> Bool {
        s.count == 10 && s.allSatisfy { ($0.isUppercase || $0.isNumber) && $0.isASCII }
    }

    /// İlk üç bileşen (özgün harf durumu).
    static func identifierRoot(_ identifier: String) -> String {
        identifier.split(separator: ".").prefix(3).joined(separator: ".")
    }

    /// Kökün son bileşeni, ilk harfi büyük: `com.vendor.soundwave` → "Soundwave".
    static func displayName(_ root: String) -> String {
        let last = root.split(separator: ".").last.map(String.init) ?? root
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    // MARK: - Yardımcılar

    private func leftover(_ url: URL, kind: LeftoverKind) -> Leftover {
        Leftover(url: url, kind: kind, confidence: .probable, size: directorySize(url),
                 requiresAdmin: LeftoverScanner.needsAdmin(url))
    }

    private func entries(of dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [])) ?? []
    }
}
