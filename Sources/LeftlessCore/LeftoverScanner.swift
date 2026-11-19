import Foundation

/// Bir uygulamayı Library klasörlerindeki girdilerle eşleştirmek için anahtarlar.
public struct MatchKeys: Sendable {
    public var bundleID: String
    /// Bundle ID'nin ilk iki bileşeni + "." (yalnızca ≥3 bileşen varsa), ör. `com.spotify.`.
    public var vendorPrefix: String?
    /// Uygulama adı ve yürütülebilir ad; 4 karakterden kısalar ve genel adlar (`genericNames`) atılır.
    public var names: [String]
    /// `names` içinde yalnızca yürütülebilir addan gelenler (küçük harf); bunlarla eşleşme en çok probable olur.
    public var executableOnlyNames: Set<String>
    public var teamID: String?

    /// Birçok uygulamanın paylaştığı yürütülebilir/uygulama adları: eşleşmede hiç kullanılmaz.
    static let genericNames: Set<String> = ["electron", "helper", "launcher", "main", "app", "run", "updater"]

    public init(app: AppInfo) {
        bundleID = app.bundleID
        teamID = app.teamID
        let parts = app.bundleID.split(separator: ".", omittingEmptySubsequences: false)
        vendorPrefix = parts.count >= 3 ? parts[0] + "." + parts[1] + "." : nil
        var seen = Set<String>()
        names = [app.name, app.executableName ?? ""].filter { name in
            name.count >= 4 && !Self.genericNames.contains(name.lowercased()) && seen.insert(name.lowercased()).inserted
        }
        let appName = app.name.lowercased()
        executableOnlyNames = Set(names.map { $0.lowercased() }.filter { $0 != appName })
    }
}

public struct LeftoverScanner: Sendable {
    private let environment: ScanEnvironment
    private let installedApps: [AppInfo]
    private let launchd: LaunchdScanner?
    private let receipts: ReceiptScanner?
    private let commands: CommandRunning?
    private let restricted: Bool

    /// `restricted`: Tam Disk Erişimi yokken sistem izin pencerelerini tetikleyen yerler
    /// (kişisel klasörler, konteynerler) aranmaz; `ScanResult.skippedLocations` bunları listeler.
    public init(environment: ScanEnvironment, installedApps: [AppInfo], launchd: LaunchdScanner? = nil,
                receipts: ReceiptScanner? = nil, commands: CommandRunning? = nil, restricted: Bool = false) {
        self.environment = environment
        self.restricted = restricted
        self.installedApps = installedApps
        self.launchd = launchd
        self.receipts = receipts
        self.commands = commands
    }

    // MARK: - Tarama

    private struct Location {
        var name: String
        var kind: LeftoverKind
        var system: Bool   // /Library altı mı (requiresAdmin)
        var user: Bool     // ~/Library altında da aranır mı
    }

    private static let locations: [Location] = {
        var l: [Location] = []
        let both: [(String, LeftoverKind)] = [
            ("Application Support", .applicationSupport), ("Caches", .caches),
            ("Preferences", .preferences), ("Preferences/ByHost", .preferences),
            ("Logs", .logs), ("Saved Application State", .savedState),
            ("HTTPStorages", .httpStorages), ("WebKit", .webKit), ("Cookies", .cookies),
            ("Containers", .container), ("Group Containers", .groupContainer),
            ("Application Scripts", .applicationScripts),
            ("Internet Plug-Ins", .plugin), ("PreferencePanes", .plugin),
            ("Audio/Plug-Ins/Components", .plugin), ("Audio/Plug-Ins/HAL", .plugin),
            ("Audio/Plug-Ins/VST", .plugin), ("Audio/Plug-Ins/VST3", .plugin), ("Audio/Plug-Ins/MAS", .plugin),
            ("QuickLook", .plugin), ("Services", .plugin), ("Screen Savers", .plugin),
        ]
        for (name, kind) in both {
            l.append(Location(name: name, kind: kind, system: false, user: true))
            l.append(Location(name: name, kind: kind, system: true, user: false))
        }
        l.append(Location(name: "PrivilegedHelperTools", kind: .privilegedHelper, system: true, user: false))
        l.append(Location(name: "Extensions", kind: .kernelExtension, system: true, user: false))
        return l
    }()

    private static let personalFolders = ["Documents", "Desktop", "Downloads", "Music", "Movies", "Pictures"]

    public func scan(_ app: AppInfo) -> ScanResult {
        let keys = MatchKeys(app: app)
        let root = environment.root
        var found: [Leftover] = []

        // Uygulamanın kendisi
        if FileManager.default.fileExists(atPath: app.url.path) {
            found.append(Leftover(url: app.url, kind: .appBundle, confidence: .certain,
                                  size: directorySize(app.url), requiresAdmin: Self.needsAdmin(app.url)))
        }

        func consider(_ entry: URL, kind: LeftoverKind, admin: Bool) {
            guard !ProtectedPaths.isProtected(entry, root: root),
                  let (confidence, note) = Self.evaluate(entry.lastPathComponent, app: app, keys: keys,
                                                         installedApps: installedApps) else { return }
            found.append(Leftover(url: entry, kind: kind, confidence: confidence,
                                  size: directorySize(entry), requiresAdmin: admin || Self.needsAdmin(entry), note: note))
        }

        var skipped: [String] = []
        if restricted { skipped = [Self.personalFoldersDisplayName, Self.containersDisplayName] }

        for loc in Self.locations {
            if restricted, !loc.system, loc.kind == .container || loc.kind == .groupContainer { continue }
            let dir = loc.system ? environment.path("/Library/\(loc.name)")
                                 : environment.homePath("Library/\(loc.name)")
            for entry in entries(of: dir) { consider(entry, kind: loc.kind, admin: loc.system) }
        }
        if let cache = environment.userCacheDir {
            for entry in entries(of: cache) { consider(entry, kind: .caches, admin: false) }
        }

        for folder in Self.personalFolders where !restricted {
            for entry in entries(of: environment.homePath(folder)) {
                guard !ProtectedPaths.isProtected(entry, root: root),
                      Self.nameMatch(entry.lastPathComponent, keys: keys) != nil else { continue }
                found.append(Leftover(url: entry, kind: .personalFolder, confidence: .probable,
                                      size: directorySize(entry), requiresAdmin: Self.needsAdmin(entry)))
            }
        }

        if let launchd { found += launchd.scan(app, keys: keys, installedApps: installedApps) }
        var leftovers = Self.deduplicated(found)
        if let receipts {
            leftovers = Self.deduplicated(leftovers + receipts.scan(app, keys: keys, installedApps: installedApps,
                                                                    excluding: leftovers.map(\.url)))
        }
        return ScanResult(app: app, leftovers: leftovers, systemExtensions: systemExtensions(for: keys),
                          skippedLocations: skipped)
    }

    static var personalFoldersDisplayName: String { L("Documents, Desktop, Downloads, Music, Movies, Pictures") }
    static var containersDisplayName: String { L("App containers (Containers, Group Containers)") }

    /// Taşımak için üst klasöre yazma izni gerekir; bir klasörü başka bir üst klasöre taşımak ise
    /// klasörün kendisine de yazma izni ister (ör. root:wheel 755 App Store paketleri).
    static func needsAdmin(_ url: URL) -> Bool {
        let fm = FileManager.default
        if !fm.isWritableFile(atPath: url.deletingLastPathComponent().path) { return true }
        var isDir: ObjCBool = false
        let isRealDir = fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            && (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        return isRealDir && !fm.isWritableFile(atPath: url.path)
    }

    /// `systemextensionsctl list` çıktısında bundle ID / team ID geçen satırlar.
    private func systemExtensions(for keys: MatchKeys) -> [String] {
        guard let commands,
              let out = try? commands.run("/usr/bin/systemextensionsctl", ["list"]), out.status == 0 else { return [] }
        let needles = [keys.bundleID, keys.teamID].compactMap { $0 }.filter { !$0.isEmpty }.map { $0.lowercased() }
        return out.stdout.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in !line.isEmpty && needles.contains { line.lowercased().contains($0) } }
    }

    /// Bir girdinin güvenini ve (varsa) notunu hesaplar; listelenmemeli ise nil.
    static func evaluate(_ entryName: String, app: AppInfo, keys: MatchKeys,
                         installedApps: [AppInfo]) -> (Confidence, String?)? {
        let others = installedApps.filter { $0.bundleID.lowercased() != app.bundleID.lowercased() }
        let level = Self.matchLevel(entryName, keys: keys)

        // Başka bir yüklü uygulamanın girdisi mi? Yalnızca o kimlik, taranan uygulamanınkinden
        // daha spesifikse (iç içe kimlikler: Chrome / Chrome.canary) atlanır.
        let ownMatch = Self.matchesBundleID(entryName, other: app)
        for other in others where Self.matchesBundleID(entryName, other: other) {
            if ownMatch && app.bundleID.count >= other.bundleID.count { continue }
            return nil
        }

        let sibling = others
            .filter { Self.sharesVendor($0, with: app, keys: keys) }
            .min { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let note = sibling.map { L("\($0.name) may also use this") }

        // Üretici klasörü (ör. "Microsoft", "Spotify"): kardeş uygulama varsa ortaktır.
        if let note, let vendor = Self.vendorName(keys), Self.stripped(entryName) == vendor {
            return (.probable, note)
        }
        switch level {
        case .certain: return (.certain, nil)
        case .vendor: return (.probable, note)
        case .name: return (.probable, nil)
        case nil: return nil
        }
    }

    private func entries(of dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [])) ?? []
    }

    /// Aynı URL iki kez çıkarsa yüksek güven kalır; sıra: certain önce, büyük boyut önce.
    private static func deduplicated(_ items: [Leftover]) -> [Leftover] {
        var byPath: [String: Leftover] = [:]
        for item in items {
            let key = item.url.standardizedFileURL.path
            if let existing = byPath[key], !(item.confidence == .certain && existing.confidence == .probable) { continue }
            byPath[key] = item
        }
        return byPath.values.sorted {
            if $0.confidence != $1.confidence { return $0.confidence == .certain }
            if $0.size != $1.size { return $0.size > $1.size }
            return $0.url.path < $1.url.path
        }
    }

    // MARK: - Eşleşme

    enum MatchLevel { case certain, vendor, name }

    /// `classify`: certain / probable / nil.
    static func classify(_ entryName: String, keys: MatchKeys) -> Confidence? {
        switch matchLevel(entryName, keys: keys) {
        case .certain: .certain
        case .vendor, .name: .probable
        case nil: nil
        }
    }

    static func matchLevel(_ entryName: String, keys: MatchKeys) -> MatchLevel? {
        let raw = entryName.lowercased()
        let candidates = raw == stripped(entryName) ? [raw] : [raw, stripped(entryName)]
        let bundleID = keys.bundleID.lowercased()
        let team = keys.teamID?.lowercased()
        let appNames = keys.names.map { $0.lowercased() }
        let strongNames = appNames.filter { !keys.executableOnlyNames.contains($0) }

        var best: MatchLevel?
        func raise(_ level: MatchLevel) {
            switch (best, level) {
            case (.certain, _): break
            case (_, .certain): best = .certain
            case (.vendor, _): break
            default: best = level
            }
        }
        for name in candidates {
            if hasBundlePrefix(name, bundleID) { raise(.certain) }
            if let team, name.hasPrefix(team + ".") {
                let rest = String(name.dropFirst(team.count + 1))
                if hasBundlePrefix(rest, bundleID) || strongNames.contains(where: { containsAsWords(rest, $0) }) { raise(.certain) }
                else { raise(.vendor) }
            }
            // Yalnızca yürütülebilir adla (uygulama adından farklıysa) tam eşleşme en çok probable olur.
            if strongNames.contains(name) { raise(.certain) } else if appNames.contains(name) { raise(.name) }
            if let vp = keys.vendorPrefix?.lowercased(), name.hasPrefix(vp) { raise(.vendor) }
        }
        // Kelime eşleşmesi özgün harf durumuyla yapılır (ZoomAudioDevice -> zoom, audio, device).
        for original in [entryName, (entryName as NSString).deletingPathExtension]
        where appNames.contains(where: { containsAsWords(original, $0) }) { raise(.name) }
        return best
    }

    /// Yalnızca isim eşleşmesi (kişisel klasörler için): tam eşitlik ya da ayrı kelime.
    static func nameMatch(_ entryName: String, keys: MatchKeys) -> MatchLevel? {
        let name = stripped(entryName)
        let appNames = keys.names.map { $0.lowercased() }
        if appNames.contains(name) || appNames.contains(entryName.lowercased()) { return .certain }
        let original = (entryName as NSString).deletingPathExtension
        if appNames.contains(where: { containsAsWords(entryName, $0) || containsAsWords(original, $0) }) { return .name }
        return nil
    }

    /// Küçük harf, uzantısız ad.
    private static func stripped(_ entryName: String) -> String {
        (entryName as NSString).deletingPathExtension.lowercased()
    }

    private static func hasBundlePrefix(_ name: String, _ bundleID: String) -> Bool {
        if name == bundleID { return true }
        guard name.hasPrefix(bundleID) else { return false }
        let next = name[name.index(name.startIndex, offsetBy: bundleID.count)]
        return next == "." || next == "-" || next == "_"
    }

    /// Girdi, başka bir uygulamanın bundle ID'sine certain düzeyinde mi ait?
    private static func matchesBundleID(_ entryName: String, other: AppInfo) -> Bool {
        let bundleID = other.bundleID.lowercased()
        let raw = entryName.lowercased()
        for name in [raw, stripped(entryName)] {
            if hasBundlePrefix(name, bundleID) { return true }
            // <herhangi önek>.<bundleID>: Group Container (team ID) ve group./groups. türevleri.
            for (i, ch) in name.enumerated() where ch == "." {
                if hasBundlePrefix(String(name.dropFirst(i + 1)), bundleID) { return true }
            }
        }
        return false
    }

    private static func sharesVendor(_ other: AppInfo, with app: AppInfo, keys: MatchKeys) -> Bool {
        if let vp = keys.vendorPrefix?.lowercased(), other.bundleID.lowercased().hasPrefix(vp) { return true }
        if let team = keys.teamID, let otherTeam = other.teamID, team.lowercased() == otherTeam.lowercased() { return true }
        return false
    }

    /// `com.microsoft.` → `microsoft`.
    private static func vendorName(_ keys: MatchKeys) -> String? {
        guard let vp = keys.vendorPrefix else { return nil }
        return vp.lowercased().split(separator: ".").dropFirst().first.map(String.init)
    }

    /// `name` içindeki kelimeler (harf/rakam dışı ayraçlarla), `phrase` kelimelerini ardışık olarak içeriyor mu.
    private static func containsAsWords(_ name: String, _ phrase: String) -> Bool {
        let words = tokens(name), target = tokens(phrase)
        guard !target.isEmpty, words.count >= target.count else { return false }
        for start in 0...(words.count - target.count) where Array(words[start..<start + target.count]) == target {
            return true
        }
        return false
    }

    /// Harf/rakam dışı ayraçlarda ve küçük→büyük harf geçişlerinde böler; küçük harfe çevirir.
    private static func tokens(_ s: String) -> [String] {
        var words: [String] = [], current = ""
        var prevLower = false
        for ch in s {
            guard ch.isLetter || ch.isNumber else {
                if !current.isEmpty { words.append(current.lowercased()); current = "" }
                prevLower = false
                continue
            }
            if ch.isUppercase && prevLower, !current.isEmpty { words.append(current.lowercased()); current = "" }
            current.append(ch)
            prevLower = ch.isLowercase
        }
        if !current.isEmpty { words.append(current.lowercased()) }
        return words
    }
}
