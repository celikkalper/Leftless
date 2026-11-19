import Foundation

// Arayüzün kullandığı saf yardımcılar (test edilebilsin diye çekirdekte).

public struct LeftoverGroup: Identifiable, Sendable {
    public var kind: LeftoverKind
    public var items: [Leftover]
    public var id: LeftoverKind { kind }
    public var title: String { kind.displayName }
    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
}

public enum LeftoverGrouping {
    /// `LeftoverKind.allCases` sırasıyla gruplar; grup içinde önce kesin öğeler, sonra boyuta göre azalan.
    public static func groups(_ leftovers: [Leftover]) -> [LeftoverGroup] {
        let byKind = Dictionary(grouping: leftovers, by: \.kind)
        return LeftoverKind.allCases.compactMap { kind in
            guard let items = byKind[kind], !items.isEmpty else { return nil }
            let sorted = items.sorted { a, b in
                if a.confidence != b.confidence { return a.confidence == .certain }
                if a.size != b.size { return a.size > b.size }
                return a.url.path < b.url.path
            }
            return LeftoverGroup(kind: kind, items: sorted)
        }
    }
}

public struct UninstallSummary: Equatable, Sendable {
    public var includesApp: Bool
    /// Uygulama paketi dışındaki seçili öğe sayısı.
    public var otherCount: Int
    public var totalSize: Int64

    public init(leftovers: [Leftover], checked: Set<UUID>) {
        let selected = leftovers.filter { checked.contains($0.id) }
        includesApp = selected.contains { $0.kind == .appBundle }
        otherCount = selected.filter { $0.kind != .appBundle }.count
        totalSize = selected.reduce(0) { $0 + $1.size }
    }

    public var totalCount: Int { otherCount + (includesApp ? 1 : 0) }
    public var isEmpty: Bool { totalCount == 0 }
}

public enum RestoreConflicts {
    /// Restorer'ın `onConflict` soracağı öğeler: Çöp'te duran ve orijinal yolu yeniden dolu olanlar.
    public static func detect(in record: HistoryRecord, exists: (String) -> Bool) -> [HistoryItem] {
        record.items.filter { item in
            guard item.state == .trashed, let trash = item.trashPath else { return false }
            return exists(trash) && exists(item.originalPath)
        }
    }
}

public enum AppListSort: String, CaseIterable, Sendable {
    case name, size
}

public enum AppListArrangement {
    public static func arrange(_ apps: [InstalledApp], query: String, sort: AppListSort,
                               excludingBundleID: String?) -> [InstalledApp] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = apps.filter { app in
            if let excluded = excludingBundleID, app.info.bundleID == excluded { return false }
            guard !q.isEmpty else { return true }
            return app.info.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive],
                                       locale: Locale(identifier: "tr_TR")) != nil
        }
        return filtered.sorted { a, b in
            if sort == .size, a.bundleSize != b.bundleSize { return a.bundleSize > b.bundleSize }
            let c = a.info.name.localizedCaseInsensitiveCompare(b.info.name)
            return c == .orderedSame ? a.id < b.id : c == .orderedAscending
        }
    }
}

extension UninstallSummary {
    /// Onay diyaloğu metni: "Spotify ve 13 öğe Çöp Sepeti'ne taşınacak (412 MB). Geçmiş'ten geri alabilirsiniz."
    public func confirmationText(appName: String, formattedSize: String) -> String {
        let what: String
        switch (includesApp, otherCount) {
        case (true, 0): what = appName
        case (true, let n): what = "\(appName) ve \(n) öğe"
        case (false, let n): what = "\(n) öğe"
        }
        return "\(what) Çöp Sepeti'ne taşınacak (\(formattedSize)). Geçmiş'ten geri alabilirsiniz."
    }
}

/// Onay anında dondurulan kaldırma planı: sonradan değişen seçim/tarama ona dokunamaz.
public struct UninstallPlan: Identifiable, Sendable {
    public let id = UUID()
    public let scan: ScanResult
    public let selected: [Leftover]
    public let summary: UninstallSummary

    /// Seçili öğe yoksa `nil`. `selected` taramadaki sırayı korur.
    public init?(scan: ScanResult, checked: Set<UUID>) {
        let selected = scan.leftovers.filter { checked.contains($0.id) }
        guard !selected.isEmpty else { return nil }
        self.scan = scan
        self.selected = selected
        self.summary = UninstallSummary(leftovers: scan.leftovers, checked: checked)
    }

    /// Plan hâlâ ekrandaki taramaya mı ait? (Aynı uygulama ve aynı tarama — öğe kimlikleri her taramada yenidir.)
    public func isValid(for current: ScanResult?) -> Bool {
        guard let current, current.app.url == scan.app.url else { return false }
        let ids = Set(current.leftovers.map(\.id))
        return selected.allSatisfy { ids.contains($0.id) }
    }
}

extension HistoryItem {
    /// Kullanıcıya gösterilen ad: dosya adı ve türü, tam yol olmadan. Ör. "foo.plist (Tercihler)".
    public var displayLabel: String {
        "\(URL(fileURLWithPath: originalPath).lastPathComponent) (\(kind.displayName))"
    }

    /// Ham hata yerine sade bir neden.
    public var friendlyFailureReason: String {
        error == "Yönetici izni verilmedi" ? "Yönetici izni verilmedi" : "Taşınamadı"
    }
}
