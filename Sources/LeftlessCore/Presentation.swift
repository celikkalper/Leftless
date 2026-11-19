import Foundation

// Pure helpers used by the UI (kept in the core so they can be tested).

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
                               excludingBundleIDs: Set<String> = [], locale: Locale = .current) -> [InstalledApp] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = apps.filter { app in
            if excludingBundleIDs.contains(app.info.bundleID) { return false }
            guard !q.isEmpty else { return true }
            return app.info.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive],
                                       locale: locale) != nil
        }
        return filtered.sorted { a, b in
            if sort == .size, a.bundleSize != b.bundleSize { return a.bundleSize > b.bundleSize }
            let c = a.info.name.localizedCaseInsensitiveCompare(b.info.name)
            return c == .orderedSame ? a.id < b.id : c == .orderedAscending
        }
    }
}

extension UninstallSummary {
    /// Confirmation dialog text, e.g. "Spotify and 13 items will be moved to the Trash (412 MB). You can undo this from History."
    public func confirmationText(appName: String, formattedSize: String) -> String {
        let what: String
        switch (includesApp, otherCount) {
        case (true, 0): what = appName
        case (true, let n):
            let items = L("\(n) items")
            what = L("\(appName) and \(items)")
        case (false, let n): what = L("\(n) items")
        }
        return L("\(what) will be moved to the Trash (\(formattedSize)). You can undo this from History.")
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
    /// User-facing name: file name and kind, without the full path. E.g. "foo.plist (Preferences)".
    public var displayLabel: String {
        "\(URL(fileURLWithPath: originalPath).lastPathComponent) (\(kind.displayName))"
    }
}

public enum Presentation {
    /// Number of history records that can still be (partly) restored; shown on the History tab.
    public static func historyBadgeCount(_ records: [HistoryRecord], status: (HistoryRecord) -> RestoreStatus) -> Int {
        records.filter {
            switch status($0) {
            case .restorable, .partial: true
            case .unrecoverable, .restored: false
            }
        }.count
    }

    /// Plain-language reason for a failed item: from the failure code, else legacy text unchanged, else a generic message.
    public static func friendlyFailureReason(_ item: HistoryItem) -> String {
        switch item.failure {
        case .adminDenied: return L("Administrator permission was not granted")
        case .manifestUpdateFailed: return L("Couldn't update the history record")
        case .notFoundInTrash: return L("Not found in the Trash")
        case .moveNotVerified: return L("The move couldn't be verified")
        case .other: return L("Couldn't be moved")
        case nil: return item.error ?? L("Couldn't be moved")
        }
    }

    /// Raw technical text for tooltips: system text from `.other`, or the legacy error string.
    public static func failureDetail(_ item: HistoryItem) -> String? {
        if case .other(let text) = item.failure { return text }
        return item.failure == nil ? item.error : nil
    }
}
