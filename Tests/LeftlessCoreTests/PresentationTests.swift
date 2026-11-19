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
        #expect(groups.map(\.title) == ["App", "Caches", "Preferences"])
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

    // MARK: - Geçmiş rozeti

    @Test func historyBadgeCountsRestorableAndPartial() {
        func record(_ name: String) -> HistoryRecord { HistoryRecord(appName: name, bundleID: "com.\(name)", items: []) }
        let records = [record("a"), record("b"), record("c"), record("d")]
        let statuses: [UUID: RestoreStatus] = [
            records[0].id: .restorable, records[1].id: .partial(missing: 1),
            records[2].id: .unrecoverable, records[3].id: .restored,
        ]
        #expect(Presentation.historyBadgeCount(records) { statuses[$0.id] ?? .unrecoverable } == 2)
        #expect(Presentation.historyBadgeCount([]) { _ in .restorable } == 0)
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
        let found = AppListArrangement.arrange(apps, query: "cizim", sort: .name, locale: Locale(identifier: "en_US"))
        #expect(found.map(\.info.name) == ["Çizim Aracı"])
        let spaced = AppListArrangement.arrange(apps, query: "  SPOT ", sort: .name, locale: Locale(identifier: "en_US"))
        #expect(spaced.map(\.info.name) == ["Spotify"])
    }

    @Test func arrangeSearchUsesInjectedLocale() {
        let en = Locale(identifier: "en_US")
        let tr = Locale(identifier: "tr_TR")
        let apps = [app("Instagram", size: 1), app("IntelliJ IDEA", size: 2), app("iTerm", size: 3), app("ISTANBUL Rehberi", size: 4)]
        #expect(AppListArrangement.arrange(apps, query: "instagram", sort: .name, locale: en).map(\.info.name) == ["Instagram"])
        #expect(AppListArrangement.arrange(apps, query: "idea", sort: .name, locale: en).map(\.info.name) == ["IntelliJ IDEA"])
        #expect(AppListArrangement.arrange(apps, query: "ITERM", sort: .name, locale: en).map(\.info.name) == ["iTerm"])
        #expect(AppListArrangement.arrange(apps, query: "ıstanbul", sort: .name, locale: tr).map(\.info.name) == ["ISTANBUL Rehberi"])
        // Turkish dotless-ı folds with I only under Turkish rules.
        #expect(AppListArrangement.arrange(apps, query: "ıstanbul", sort: .name, locale: en).isEmpty)
    }

    // MARK: - Onay metni

    @Test func confirmationTextCases() {
        let bundle = leftover("/Applications/Spotify.app", .appBundle, size: 100)
        let cache = leftover("/u/Library/Caches/s", .caches, size: 20)
        let cache2 = leftover("/u/Library/Caches/t", .caches, size: 20)
        let all = [bundle, cache, cache2]
        #expect(UninstallSummary(leftovers: all, checked: [bundle.id, cache.id, cache2.id])
            .confirmationText(appName: "Spotify", formattedSize: "412 MB")
            == "Spotify and 2 items will be moved to the Trash (412 MB). You can undo this from History.")
        #expect(UninstallSummary(leftovers: all, checked: [bundle.id])
            .confirmationText(appName: "Spotify", formattedSize: "1 KB")
            == "Spotify will be moved to the Trash (1 KB). You can undo this from History.")
        #expect(UninstallSummary(leftovers: all, checked: [cache.id, cache2.id])
            .confirmationText(appName: "Spotify", formattedSize: "2 KB")
            == "2 items will be moved to the Trash (2 KB). You can undo this from History.")
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

    // MARK: - Toplu kaldırma planı

    func appScan(_ name: String, _ leftovers: [Leftover]) -> ScanResult {
        ScanResult(app: AppInfo(url: URL(fileURLWithPath: "/Applications/\(name).app"),
                                bundleID: "com.test.\(name.lowercased())", name: name), leftovers: leftovers)
    }

    @Test func batchPlanFreezesSelectionPerApp() throws {
        let aApp = leftover("/Applications/A.app", .appBundle, size: 100)
        let aCache = leftover("/u/Library/Caches/a", .caches, size: 10)
        let aLog = leftover("/u/Library/Logs/a", .logs, size: 1)
        let bApp = leftover("/Applications/B.app", .appBundle, size: 50)
        let bPrefs = leftover("/u/Library/Preferences/b.plist", .preferences, size: 2)
        let a = appScan("A", [aApp, aCache, aLog]), b = appScan("B", [bApp, bPrefs])
        var checked: Set<UUID> = [aLog.id, aApp.id, bApp.id, bPrefs.id]
        let plan = try #require(BatchUninstallPlan(scans: [a, b], checked: checked))
        #expect(plan.plans.map(\.scan.app.name) == ["A", "B"])
        #expect(plan.plans[0].selected.map(\.id) == [aApp.id, aLog.id])
        #expect(plan.plans[1].selected.map(\.id) == [bApp.id, bPrefs.id])
        #expect(plan.summary.appCount == 2)
        #expect(plan.summary.otherCount == 2)
        #expect(plan.summary.totalCount == 4)
        #expect(plan.summary.totalSize == 153)
        // Sonradan değişen işaretler dondurulmuş planı etkilemez.
        checked.insert(aCache.id)
        #expect(plan.plans[0].selected.map(\.id) == [aApp.id, aLog.id])
        #expect(plan.isValid(for: [a, b]))
    }

    @Test func batchPlanInvalidWhenAScanChanged() throws {
        let aApp = leftover("/Applications/A.app", .appBundle, size: 100)
        let bApp = leftover("/Applications/B.app", .appBundle, size: 50)
        let a = appScan("A", [aApp]), b = appScan("B", [bApp])
        let plan = try #require(BatchUninstallPlan(scans: [a, b], checked: [aApp.id, bApp.id]))
        #expect(plan.isValid(for: [b, a]))
        // Yeniden taranan uygulama yeni kimlikler üretir.
        let rescanned = appScan("B", [leftover("/Applications/B.app", .appBundle, size: 50)])
        #expect(!plan.isValid(for: [a, rescanned]))
        // Seçimden çıkan, eklenen ya da henüz taranmamış uygulama da planı geçersiz kılar.
        #expect(!plan.isValid(for: [a]))
        let c = appScan("C", [leftover("/Applications/C.app", .appBundle, size: 1)])
        #expect(!plan.isValid(for: [a, b, c]))
        #expect(!plan.isValid(for: []))
    }

    @Test func batchPlanSkipsAppsWithNothingChecked() throws {
        let aApp = leftover("/Applications/A.app", .appBundle, size: 100)
        let bCache = leftover("/u/Library/Caches/b", .caches, size: 7)
        let a = appScan("A", [aApp]), b = appScan("B", [bCache])
        let plan = try #require(BatchUninstallPlan(scans: [a, b], checked: [bCache.id]))
        #expect(plan.plans.map(\.scan.app.name) == ["B"])
        #expect(plan.summary.appCount == 0)
        #expect(plan.summary.otherCount == 1)
        // Hiçbir şey seçilmeyen uygulama yine de seçimin parçasıdır: plan ona göre doğrulanır.
        #expect(plan.isValid(for: [a, b]))
        #expect(!plan.isValid(for: [b]))
        #expect(BatchUninstallPlan(scans: [a, b], checked: []) == nil)
        #expect(BatchUninstallPlan(scans: [], checked: [aApp.id]) == nil)
    }

    @Test func batchSummaryCountsSharedPathsOnce() throws {
        // Aynı satıcı klasörü iki uygulamanın taramasında: Uninstaller onu yalnızca ilk işe verir.
        let aApp = leftover("/Applications/A.app", .appBundle, size: 100)
        let aShared = leftover("/u/Library/Application Support/Vendor", .applicationSupport, size: 10)
        let bApp = leftover("/Applications/B.app", .appBundle, size: 50)
        let bShared = leftover("/u/Library/Application Support/Vendor", .applicationSupport, size: 10)
        let bInside = leftover("/u/Library/Application Support/Vendor/B", .applicationSupport, size: 3)
        let bOwn = leftover("/u/Library/Caches/b", .caches, size: 1)
        let a = appScan("A", [aApp, aShared]), b = appScan("B", [bApp, bShared, bInside, bOwn])
        let checked: Set<UUID> = [aApp.id, aShared.id, bApp.id, bShared.id, bInside.id, bOwn.id]
        let plan = try #require(BatchUninstallPlan(scans: [a, b], checked: checked))
        #expect(plan.summary.appCount == 2)
        #expect(plan.summary.otherCount == 2)
        #expect(plan.summary.totalSize == 161)
        #expect(BatchUninstallSummary(scans: [a, b], checked: checked) == plan.summary)
        // Uninstaller ile aynı kural.
        let kept = Uninstaller.effectiveSelections([[aApp, aShared], [bApp, bShared, bInside, bOwn]])
        #expect(kept.map { $0.map(\.id) } == [[aApp.id, aShared.id], [bApp.id, bOwn.id]])
    }

    @Test func discardingScansDropsUninstalledAppsAndTheirChecks() {
        let aApp = leftover("/Applications/A.app", .appBundle, size: 100)
        let aCache = leftover("/u/Library/Caches/a", .caches, size: 1)
        let bCache = leftover("/u/Library/Caches/b", .caches, size: 1)
        let a = appScan("A", [aApp, aCache]), b = appScan("B", [bCache])
        let scans = ["/Applications/A.app": a, "/Applications/B.app": b]
        let result = Presentation.discardingScans(of: [a.app], from: scans,
                                                  checked: [aApp.id, aCache.id, bCache.id])
        #expect(Array(result.scans.keys) == ["/Applications/B.app"])
        #expect(result.checked == [bCache.id])
    }

    @Test func batchConfirmationText() {
        func summary(apps: Int, others: Int) -> BatchUninstallSummary {
            BatchUninstallSummary(appCount: apps, otherCount: others, totalSize: 0)
        }
        #expect(summary(apps: 3, others: 41).confirmationText(formattedSize: "1.2 GB")
            == "3 apps and 41 items will be moved to the Trash (1.2 GB). You can undo this from History.")
        #expect(summary(apps: 2, others: 0).confirmationText(formattedSize: "5 MB")
            == "2 apps will be moved to the Trash (5 MB). You can undo this from History.")
        #expect(summary(apps: 0, others: 4).confirmationText(formattedSize: "2 KB")
            == "4 items will be moved to the Trash (2 KB). You can undo this from History.")
    }

    // MARK: - Geçmiş öğesi metinleri

    @Test func historyItemLabelHidesPath() {
        let item = HistoryItem(originalPath: "/Users/u/Library/Preferences/com.foo.plist", kind: .preferences, size: 1)
        #expect(item.displayLabel == "com.foo.plist (Preferences)")
    }

    @Test func friendlyFailureReason() {
        var item = HistoryItem(originalPath: "/a", kind: .caches, size: 1, state: .failed, failure: .adminDenied)
        #expect(Presentation.friendlyFailureReason(item) == "Administrator permission was not granted")
        item.failure = .other("The file “a” couldn’t be moved because you don’t have permission.")
        #expect(Presentation.friendlyFailureReason(item) == "Couldn't be moved")
        #expect(Presentation.failureDetail(item) == "The file “a” couldn’t be moved because you don’t have permission.")
        item.failure = nil
        #expect(Presentation.friendlyFailureReason(item) == "Couldn't be moved")
    }

    @Test func legacyRecordWithTurkishErrorDecodesAndDisplaysUnchanged() throws {
        let json = """
        {"id":"\(UUID().uuidString)","originalPath":"/a","kind":"caches","size":1,"requiresAdmin":false,
         "state":"failed","error":"Yönetici izni verilmedi"}
        """
        let item = try JSONDecoder().decode(HistoryItem.self, from: Data(json.utf8))
        #expect(item.failure == nil)
        #expect(Presentation.friendlyFailureReason(item) == "Yönetici izni verilmedi")
    }

    @Test func failureReasonEncodingIsStable() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func json(_ r: FailureReason) throws -> String { String(decoding: try encoder.encode(r), as: UTF8.self) }
        #expect(try json(.adminDenied) == #"{"code":"adminDenied"}"#)
        #expect(try json(.manifestUpdateFailed) == #"{"code":"manifestUpdateFailed"}"#)
        #expect(try json(.notFoundInTrash) == #"{"code":"notFoundInTrash"}"#)
        #expect(try json(.moveNotVerified) == #"{"code":"moveNotVerified"}"#)
        #expect(try json(.other("mv: boom")) == #"{"code":"other","detail":"mv: boom"}"#)
        for r in [FailureReason.adminDenied, .other("x")] {
            #expect(try JSONDecoder().decode(FailureReason.self, from: encoder.encode(r)) == r)
        }
    }

    @Test func kindDisplayNamesAreEnglishSource() {
        #expect(LeftoverKind.caches.displayName == "Caches")
        #expect(LeftoverKind.launchDaemon.displayName == "Launch Daemon")
        #expect(LeftoverKind.allCases.allSatisfy { !$0.displayName.isEmpty })
    }
}

// MARK: - Orphaned leftovers

@Suite struct OrphanPresentationTests {
    func item(_ path: String, size: Int64, kind: LeftoverKind = .caches) -> Leftover {
        Leftover(url: URL(fileURLWithPath: path), kind: kind, confidence: .probable, size: size)
    }

    func scan() -> OrphanScanResult {
        OrphanScanResult(groups: [
            OrphanGroup(id: "com.old.big", displayName: "Big", items: [
                item("/u/Library/Caches/com.old.big", size: 300),
                item("/u/Library/Preferences/com.old.big.plist", size: 2, kind: .preferences),
            ]),
            OrphanGroup(id: "net.gone.small", displayName: "Small", items: [
                item("/u/Library/Logs/net.gone.small", size: 10, kind: .logs),
            ]),
        ])
    }

    @Test func eachScanHasItsOwnIdentity() {
        #expect(scan().id != scan().id)
    }

    @Test func selectAllAndDeselectAllCoverEveryItem() {
        let s = scan()
        let all = Set(s.groups.flatMap(\.items).map(\.id))
        let other = UUID()
        #expect(OrphanSelection.allIDs(s.groups) == all)
        #expect(!OrphanSelection.isAllSelected(s.groups, checked: [other]))
        let selected = OrphanSelection.selectingAll(s.groups, checked: [other])
        #expect(selected == all.union([other]))
        #expect(OrphanSelection.isAllSelected(s.groups, checked: selected))
        #expect(OrphanSelection.deselectingAll(s.groups, checked: selected) == [other])
        #expect(!OrphanSelection.isAllSelected([], checked: []))
    }

    @Test func planFreezesCheckedItemsInScanOrder() throws {
        let s = scan()
        let items = s.groups.flatMap(\.items)
        let plan = try #require(OrphanPlan(scan: s, checked: [items[2].id, items[0].id]))
        #expect(plan.scanID == s.id)
        #expect(plan.selected.map(\.id) == [items[0].id, items[2].id])
        #expect(plan.summary.totalCount == 2)
        #expect(plan.summary.totalSize == 310)
        #expect(plan.confirmationText(formattedSize: "310 bytes")
                == "2 items will be moved to the Trash (310 bytes). You can undo this from History.")
    }

    @Test func planIsNilWhenNothingChecked() {
        #expect(OrphanPlan(scan: scan(), checked: [UUID()]) == nil)
    }

    @Test func planIsValidOnlyForTheSameScan() throws {
        let s = scan()
        let plan = try #require(OrphanPlan(scan: s, checked: [s.groups[0].items[0].id]))
        #expect(plan.isValid(for: s))
        #expect(!plan.isValid(for: nil))
        #expect(!plan.isValid(for: scan()))   // rescanned
        var changed = s
        changed.groups.removeFirst()
        #expect(!plan.isValid(for: changed))
    }

    @Test func planBuildsOneOrphansJob() throws {
        let s = scan()
        let items = s.groups.flatMap(\.items)
        let plan = try #require(OrphanPlan(scan: s, checked: [items[1].id]))
        let job = plan.job(home: URL(fileURLWithPath: "/Users/me"))
        #expect(job.operation == .orphans)
        #expect(job.icon == nil)
        #expect(job.selected.map(\.id) == [items[1].id])
        #expect(job.scan.leftovers.map(\.id) == items.map(\.id))
        #expect(job.scan.app.url.path == "/Users/me/Library")
        #expect(job.scan.app.bundleID == "leftless.orphans")
        #expect(job.scan.app.name == "Orphaned leftovers")
    }

    @Test func historyTitleFollowsOperation() {
        func record(_ op: HistoryOperation) -> HistoryRecord {
            HistoryRecord(appName: "SoundWave", bundleID: "com.example.soundwave", items: [], operation: op)
        }
        #expect(Presentation.historyTitle(record(.uninstall)) == "SoundWave")
        #expect(Presentation.historyTitle(record(.reset)) == "SoundWave — Reset")
        #expect(Presentation.historyTitle(record(.orphans)) == "Orphaned leftovers")
    }
}
