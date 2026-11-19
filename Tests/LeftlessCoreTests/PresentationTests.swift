import Testing
import Foundation
@testable import LeftlessCore

@Suite struct PresentationTests {
    func leftover(_ path: String, _ kind: LeftoverKind, size: Int64, _ confidence: Confidence = .certain) -> Leftover {
        Leftover(url: URL(fileURLWithPath: path), kind: kind, confidence: confidence, size: size)
    }

    func app(_ name: String, size: Int64, id: String? = nil) -> InstalledApp {
        InstalledApp(info: AppInfo(url: URL(fileURLWithPath: "/Applications/\(name).app"),
                                   bundleID: id ?? "com.test.\(name.lowercased())", name: name),
                     bundleSize: size)
    }

    // MARK: - Gruplama

    @Test func groupsFollowKindOrderWithCountsAndSizes() {
        let items = [
            leftover("/u/Library/Caches/b", .caches, size: 5),
            leftover("/Applications/Foo.app", .appBundle, size: 100),
            leftover("/u/Library/Caches/a", .caches, size: 20),
            leftover("/u/Library/Preferences/foo.plist", .preferences, size: 1),
        ]
        let groups = LeftoverGrouping.groups(items)
        #expect(groups.map(\.kind) == [.appBundle, .caches, .preferences])
        #expect(groups.map(\.title) == ["Uygulama", "Önbellek", "Tercihler"])
        #expect(groups[1].items.map(\.url.lastPathComponent) == ["a", "b"])
        #expect(groups[1].totalSize == 25)
        #expect(groups.map(\.items.count) == [1, 2, 1])
    }

    @Test func groupPutsCertainBeforeProbable() {
        let items = [
            leftover("/u/Library/Application Support/big", .applicationSupport, size: 900, .probable),
            leftover("/u/Library/Application Support/small", .applicationSupport, size: 1),
        ]
        let group = LeftoverGrouping.groups(items)[0]
        #expect(group.items.map(\.url.lastPathComponent) == ["small", "big"])
    }

    @Test func emptyInputGivesNoGroups() {
        #expect(LeftoverGrouping.groups([]).isEmpty)
    }

    // MARK: - Seçim özeti

    @Test func summaryCountsCheckedItemsAndSeparatesAppBundle() {
        let bundle = leftover("/Applications/Foo.app", .appBundle, size: 100)
        let cache = leftover("/u/Library/Caches/foo", .caches, size: 20)
        let prefs = leftover("/u/Library/Preferences/foo.plist", .preferences, size: 3)
        let summary = UninstallSummary(leftovers: [bundle, cache, prefs], checked: [bundle.id, cache.id])
        #expect(summary.includesApp)
        #expect(summary.otherCount == 1)
        #expect(summary.totalCount == 2)
        #expect(summary.totalSize == 120)
        #expect(!summary.isEmpty)
    }

    @Test func summaryWithoutAppBundle() {
        let bundle = leftover("/Applications/Foo.app", .appBundle, size: 100)
        let cache = leftover("/u/Library/Caches/foo", .caches, size: 20)
        let summary = UninstallSummary(leftovers: [bundle, cache], checked: [cache.id, UUID()])
        #expect(!summary.includesApp)
        #expect(summary.otherCount == 1)
        #expect(summary.totalSize == 20)
    }

    @Test func emptySummary() {
        let cache = leftover("/u/Library/Caches/foo", .caches, size: 20)
        let summary = UninstallSummary(leftovers: [cache], checked: [])
        #expect(summary.isEmpty)
        #expect(summary.totalSize == 0)
    }

    // MARK: - Geri yükleme çakışmaları

    @Test func conflictsAreTrashedItemsWhoseTrashCopyAndOriginalBothExist() {
        let conflict = HistoryItem(originalPath: "/a", trashPath: "/t/a", kind: .caches, size: 1, state: .trashed)
        let noConflict = HistoryItem(originalPath: "/b", trashPath: "/t/b", kind: .caches, size: 1, state: .trashed)
        let missingTrash = HistoryItem(originalPath: "/c", trashPath: "/t/c", kind: .caches, size: 1, state: .trashed)
        let restored = HistoryItem(originalPath: "/d", trashPath: "/t/d", kind: .caches, size: 1, state: .restored)
        let failed = HistoryItem(originalPath: "/e", trashPath: nil, kind: .caches, size: 1, state: .failed)
        let record = HistoryRecord(appName: "Foo", bundleID: "com.foo",
                                   items: [conflict, noConflict, missingTrash, restored, failed])
        let existing: Set<String> = ["/a", "/t/a", "/t/b", "/c", "/d", "/t/d", "/e"]
        let found = RestoreConflicts.detect(in: record) { existing.contains($0) }
        #expect(found.map(\.id) == [conflict.id])
    }

    // MARK: - Uygulama listesi

    @Test func arrangeExcludesSelfFiltersAndSortsByName() {
        let apps = [app("Zoom", size: 40), app("slack", size: 30),
                    app("Leftless", size: 50, id: "com.leftless.app"),
                    app("Kalıntısız", size: 50, id: "com.kalintisiz.app"), app("Spotify", size: 20)]
        let byName = AppListArrangement.arrange(apps, query: "", sort: .name, excludingBundleIDs: ["com.leftless.app", "com.kalintisiz.app"])
        #expect(byName.map(\.info.name) == ["slack", "Spotify", "Zoom"])
        let bySize = AppListArrangement.arrange(apps, query: "", sort: .size, excludingBundleIDs: ["com.leftless.app", "com.kalintisiz.app"])
        #expect(bySize.map(\.info.name) == ["Zoom", "slack", "Spotify"])
    }

    @Test func arrangeQueryIsCaseAndDiacriticInsensitive() {
        let apps = [app("Çizim Aracı", size: 1), app("Spotify", size: 2)]
        let found = AppListArrangement.arrange(apps, query: "cizim", sort: .name)
        #expect(found.map(\.info.name) == ["Çizim Aracı"])
        let spaced = AppListArrangement.arrange(apps, query: "  SPOT ", sort: .name)
        #expect(spaced.map(\.info.name) == ["Spotify"])
    }

    // MARK: - Onay metni

    @Test func confirmationTextCases() {
        let bundle = leftover("/Applications/Spotify.app", .appBundle, size: 100)
        let cache = leftover("/u/Library/Caches/s", .caches, size: 20)
        let all = [bundle, cache]
        #expect(UninstallSummary(leftovers: all, checked: [bundle.id, cache.id])
            .confirmationText(appName: "Spotify", formattedSize: "412 MB")
            == "Spotify ve 1 öğe Çöp Sepeti'ne taşınacak (412 MB). Geçmiş'ten geri alabilirsiniz.")
        #expect(UninstallSummary(leftovers: all, checked: [bundle.id])
            .confirmationText(appName: "Spotify", formattedSize: "1 KB")
            == "Spotify Çöp Sepeti'ne taşınacak (1 KB). Geçmiş'ten geri alabilirsiniz.")
        #expect(UninstallSummary(leftovers: all, checked: [cache.id])
            .confirmationText(appName: "Spotify", formattedSize: "2 KB")
            == "1 öğe Çöp Sepeti'ne taşınacak (2 KB). Geçmiş'ten geri alabilirsiniz.")
    }

    // MARK: - Kaldırma planı

    func scanResult(_ appPath: String, _ leftovers: [Leftover]) -> ScanResult {
        ScanResult(app: AppInfo(url: URL(fileURLWithPath: appPath), bundleID: "com.test", name: "T"), leftovers: leftovers)
    }

    @Test func planFreezesCheckedItemsInScanOrder() throws {
        let a = leftover("/Applications/T.app", .appBundle, size: 100)
        let b = leftover("/u/Library/Caches/t", .caches, size: 5)
        let c = leftover("/u/Library/Logs/t", .logs, size: 1)
        let scan = scanResult("/Applications/T.app", [a, b, c])
        let plan = try #require(UninstallPlan(scan: scan, checked: [c.id, a.id]))
        #expect(plan.selected.map(\.id) == [a.id, c.id])
        #expect(plan.summary.totalSize == 101)
        #expect(UninstallPlan(scan: scan, checked: []) == nil)
        #expect(UninstallPlan(scan: scan, checked: [UUID()]) == nil)
    }

    @Test func planIsInvalidForOtherAppOrNewScan() throws {
        let a = leftover("/Applications/T.app", .appBundle, size: 100)
        let scan = scanResult("/Applications/T.app", [a])
        let plan = try #require(UninstallPlan(scan: scan, checked: [a.id]))
        #expect(plan.isValid(for: scan))
        #expect(!plan.isValid(for: nil))
        let other = leftover("/Applications/B.app", .appBundle, size: 1)
        #expect(!plan.isValid(for: scanResult("/Applications/B.app", [other])))
        // Aynı uygulamanın yeniden taranması yeni kimlikler üretir: eski plan geçersiz.
        let rescanned = leftover("/Applications/T.app", .appBundle, size: 100)
        #expect(!plan.isValid(for: scanResult("/Applications/T.app", [rescanned])))
    }

    // MARK: - Geçmiş öğesi metinleri

    @Test func historyItemLabelHidesPath() {
        let item = HistoryItem(originalPath: "/Users/u/Library/Preferences/com.foo.plist", kind: .preferences, size: 1)
        #expect(item.displayLabel == "com.foo.plist (Tercihler)")
    }

    @Test func friendlyFailureReason() {
        var item = HistoryItem(originalPath: "/a", kind: .caches, size: 1, state: .failed,
                               error: "Yönetici izni verilmedi")
        #expect(item.friendlyFailureReason == "Yönetici izni verilmedi")
        item.error = "The file “a” couldn’t be moved because you don’t have permission."
        #expect(item.friendlyFailureReason == "Taşınamadı")
        item.error = nil
        #expect(item.friendlyFailureReason == "Taşınamadı")
    }
}
