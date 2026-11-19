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

/// Several apps' selections together (batch uninstall). `appCount` counts selected app bundles.
public struct BatchUninstallSummary: Equatable, Sendable {
    public var appCount: Int
    /// Selected items other than app bundles.
    public var otherCount: Int
    public var totalSize: Int64

    public init(appCount: Int, otherCount: Int, totalSize: Int64) {
        self.appCount = appCount
        self.otherCount = otherCount
        self.totalSize = totalSize
    }

    /// Totals of what will really be moved: a path shared by several apps (or inside another app's selected
    /// folder) is counted once, for the first app, exactly as `Uninstaller.uninstall(batch:)` moves it.
    public init(selections: [[Leftover]]) {
        let kept = Uninstaller.effectiveSelections(selections)
        self.init(appCount: kept.filter { $0.contains { $0.kind == .appBundle } }.count,
                  otherCount: kept.reduce(0) { $0 + $1.filter { $0.kind != .appBundle }.count },
                  totalSize: kept.reduce(0) { $0 + $1.reduce(0) { $0 + $1.size } })
    }

    /// Live totals for the shown scans and checkboxes (same rule as the frozen plan).
    public init(scans: [ScanResult], checked: Set<UUID>) {
        self.init(selections: scans.map { $0.leftovers.filter { checked.contains($0.id) } })
    }

    public var totalCount: Int { appCount + otherCount }

    /// E.g. "3 apps and 41 items will be moved to the Trash (1.2 GB). You can undo this from History."
    public func confirmationText(formattedSize: String) -> String {
        let what: String
        switch (appCount, otherCount) {
        case (0, let n): what = L("\(n) items")
        case (let a, 0): what = L("\(a) apps")
        case (let a, let n):
            let apps = L("\(a) apps"), items = L("\(n) items")
            what = L("\(apps) and \(items)")
        }
        return L("\(what) will be moved to the Trash (\(formattedSize)). You can undo this from History.")
    }
}

/// Batch uninstall plan frozen at confirmation: one `UninstallPlan` per app that has something checked,
/// in the order the scans were given. Later changes to the selection or the scans can't touch it.
public struct BatchUninstallPlan: Identifiable, Sendable {
    public let id = UUID()
    public let plans: [UninstallPlan]
    public let summary: BatchUninstallSummary
    /// Every app shown at confirmation (also those with nothing checked); the plan is valid only for exactly these.
    public let appPaths: Set<String>

    /// `nil` when nothing is checked in any of the scans.
    public init?(scans: [ScanResult], checked: Set<UUID>) {
        let plans = scans.compactMap { UninstallPlan(scan: $0, checked: checked) }
        guard !plans.isEmpty else { return nil }
        self.plans = plans
        self.summary = BatchUninstallSummary(selections: plans.map(\.selected))
        self.appPaths = Set(scans.map(\.app.url.path))
    }

    /// Is the plan still about the scans on screen? Same set of apps, and each app's scan unchanged.
    public func isValid(for current: [ScanResult]) -> Bool {
        guard Set(current.map(\.app.url.path)) == appPaths, current.count == appPaths.count else { return false }
        return plans.allSatisfy { plan in
            plan.isValid(for: current.first { $0.app.url == plan.scan.app.url })
        }
    }
}

extension HistoryItem {
    /// User-facing name: file name and kind, without the full path. E.g. "foo.plist (Preferences)".
    public var displayLabel: String {
        "\(URL(fileURLWithPath: originalPath).lastPathComponent) (\(kind.displayName))"
    }
}

public enum Presentation {
    /// After an uninstall, the scans of the affected apps are out of date: they are dropped (with their checked
    /// items) so the apps are scanned again the next time they are shown.
    public static func discardingScans(of apps: [AppInfo], from scans: [String: ScanResult], checked: Set<UUID>)
        -> (scans: [String: ScanResult], checked: Set<UUID>) {
        let urls = Set(apps.map(\.url))
        let stale = scans.filter { urls.contains($0.value.app.url) }
        let staleIDs = Set(stale.values.flatMap { $0.leftovers.map(\.id) })
        return (scans.filter { !urls.contains($0.value.app.url) }, checked.subtracting(staleIDs))
    }

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

// MARK: - Orphaned leftovers

/// Select All / Deselect All over the shown orphan groups (other checked ids are left alone).
public enum OrphanSelection {
    public static func allIDs(_ groups: [OrphanGroup]) -> Set<UUID> {
        Set(groups.flatMap(\.items).map(\.id))
    }

    /// `false` when there is nothing to select.
    public static func isAllSelected(_ groups: [OrphanGroup], checked: Set<UUID>) -> Bool {
        let all = allIDs(groups)
        return !all.isEmpty && all.isSubset(of: checked)
    }

    public static func selectingAll(_ groups: [OrphanGroup], checked: Set<UUID>) -> Set<UUID> {
        checked.union(allIDs(groups))
    }

    public static func deselectingAll(_ groups: [OrphanGroup], checked: Set<UUID>) -> Set<UUID> {
        checked.subtracting(allIDs(groups))
    }
}

/// Orphan move plan frozen at confirmation: the checked items of one particular scan.
/// After a rescan (new scan identity) it is no longer valid and nothing may be moved with it.
public struct OrphanPlan: Identifiable, Sendable {
    /// Bundle ID of the pseudo app the orphans job is recorded under.
    public static let bundleID = "leftless.orphans"

    public let id = UUID()
    public let scanID: UUID
    /// Every item of the frozen scan, in scan order.
    public let items: [Leftover]
    /// Checked items, in scan order.
    public let selected: [Leftover]
    public let summary: UninstallSummary

    /// `nil` when none of the scan's items is checked.
    public init?(scan: OrphanScanResult, checked: Set<UUID>) {
        let items = scan.groups.flatMap(\.items)
        let selected = items.filter { checked.contains($0.id) }
        guard !selected.isEmpty else { return nil }
        self.scanID = scan.id
        self.items = items
        self.selected = selected
        self.summary = UninstallSummary(leftovers: items, checked: checked)
    }

    /// Is the plan still about the scan on screen? Same scan, and every planned item still listed.
    public func isValid(for current: OrphanScanResult?) -> Bool {
        guard let current, current.id == scanID else { return false }
        let ids = OrphanSelection.allIDs(current.groups)
        return selected.allSatisfy { ids.contains($0.id) }
    }

    /// E.g. "12 items will be moved to the Trash (85 MB). You can undo this from History."
    public func confirmationText(formattedSize: String) -> String {
        summary.confirmationText(appName: "", formattedSize: formattedSize)
    }

    /// The single uninstall job (one "Orphaned leftovers" history record) for this plan; `selected`
    /// narrows the planned items (e.g. to those still orphaned right before moving).
    public func job(home: URL, selected: [Leftover]? = nil) -> UninstallJob {
        let app = AppInfo(url: home.appendingPathComponent("Library", isDirectory: true),
                          bundleID: Self.bundleID, name: L("Orphaned leftovers"))
        return UninstallJob(scan: ScanResult(app: app, leftovers: items), selected: selected ?? self.selected, icon: nil,
                            operation: .orphans)
    }
}

extension Presentation {
    /// Title of a history row: the app name, "SoundWave — Reset", or "Orphaned leftovers".
    public static func historyTitle(_ record: HistoryRecord) -> String {
        switch record.operation {
        case .uninstall: record.appName
        case .reset: L("\(record.appName) — Reset")
        case .orphans: L("Orphaned leftovers")
        }
    }
}
