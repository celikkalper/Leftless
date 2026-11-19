import AppKit
import LeftlessCore
import Observation

enum MainTab: Hashable {
    case apps, history
}

struct PendingRestore: Identifiable {
    let id = UUID()
    let record: HistoryRecord
    let conflicts: [HistoryItem]
}

@MainActor @Observable
final class AppModel {
    /// Eski paket kimliği de dışlanır (yeniden adlandırma öncesi kurulumlar).
    static let ownBundleIDs: Set<String> = ["com.leftless.app", "com.kalintisiz.app"]

    var apps: [InstalledApp] = []
    var tab: MainTab = .apps
    /// Selected apps in list order. One app shows the single-app detail; two or more show the batch detail.
    private(set) var selectedApps: [InstalledApp] = []
    /// Finished scans of the selected apps (scans of deselected apps are dropped).
    private(set) var scans: [InstalledApp.ID: ScanResult] = [:]
    /// Checked leftovers of all shown scans (leftover ids are unique across scans).
    var checked: Set<UUID> = []
    var isLoadingApps = false
    var isWorking = false
    var history: [HistoryRecord] = []
    var historyStatus: [UUID: RestoreStatus] = [:]
    var lastOutcome: UninstallOutcome?
    /// Result of a batch uninstall, one outcome per app that had items moved.
    var batchOutcomes: [UninstallOutcome]?
    var pendingRestore: PendingRestore?
    var alertMessage: String?
    var restoreSummary: String?
    var hasFullDiskAccess = FullDiskAccess.isGranted()
    var onboardingSkipped = false
    var searchText = ""
    var sort: AppListSort = .name

    private let environment = ScanEnvironment.live()
    private let store = HistoryStore(directory: HistoryStore.liveDirectory())
    /// Scans in progress; a result whose token no longer matches (app deselected or rescanned) is ignored.
    private var scanTokens: [InstalledApp.ID: UUID] = [:]

    var selection: Set<InstalledApp.ID> { Set(selectedApps.map(\.id)) }
    /// The selected app when exactly one is selected.
    var singleSelection: InstalledApp? { selectedApps.count == 1 ? selectedApps[0] : nil }
    /// Scan shown by the single-app detail.
    var scan: ScanResult? { singleSelection.flatMap { scans[$0.id] } }
    var isScanning: Bool { !scanTokens.isEmpty }
    /// Scans of the selected apps in list order (missing while an app is still being scanned).
    var selectedScans: [ScanResult] { selectedApps.compactMap { scans[$0.id] } }

    var visibleApps: [InstalledApp] {
        AppListArrangement.arrange(apps, query: searchText, sort: sort, excludingBundleIDs: Self.ownBundleIDs)
    }

    var summary: UninstallSummary {
        UninstallSummary(leftovers: scan?.leftovers ?? [], checked: checked)
    }

    /// Demo models (README screenshots) never read the real disk or history.
    private(set) var isDemo = false

    init() {
        reloadApps()
        reloadHistory()
    }

    #if DEBUG
    /// A model filled with fictional apps and history, for screenshots. Nothing is read from disk.
    init(demoApps: [InstalledApp], selection: [InstalledApp], scans: [ScanResult],
         history: [HistoryRecord], historyStatus: [UUID: RestoreStatus]) {
        isDemo = true
        hasFullDiskAccess = true
        apps = demoApps
        selectedApps = selection
        for scan in scans {
            self.scans[scan.app.url.path] = scan
            checked.formUnion(scan.leftovers.filter(\.selectedByDefault).map(\.id))
        }
        self.history = history
        self.historyStatus = historyStatus
    }
    #endif

    // MARK: - Liste

    func reloadApps() {
        guard !isDemo else { return }
        isLoadingApps = true
        let env = environment
        Task {
            let list = await Task.detached {
                InstalledApps(environment: env, inspector: AppInspector(commands: ProcessCommandRunner())).list()
            }.value
            apps = list
            isLoadingApps = false
        }
    }

    func reloadHistory() {
        guard !isDemo else { return }
        history = (try? store.all()) ?? []
        historyStatus = Dictionary(uniqueKeysWithValues: history.map { ($0.id, store.status(of: $0)) })
    }

    /// Switches the toolbar tab. The app selection and its scan are kept, so returning to Apps shows them again.
    func switchTab(_ newTab: MainTab) {
        guard !isWorking, newTab != tab else { return }
        tab = newTab
        if newTab == .history { reloadHistory() }
    }

    /// Number shown next to "History" in the toolbar: records that can still be restored.
    var historyBadge: Int {
        Presentation.historyBadgeCount(history) { historyStatus[$0.id] ?? .unrecoverable }
    }

    var showsOnboarding: Bool { !hasFullDiskAccess && !onboardingSkipped }

    func refreshFullDiskAccess() {
        guard !isDemo else { return }
        hasFullDiskAccess = FullDiskAccess.isGranted()
    }

    // MARK: - Tarama

    func select(_ app: InstalledApp?) async {
        await select(app.map { [$0.id] } ?? [], known: app.map { [$0] } ?? [])
    }

    /// Changes the selection. Scans of apps that stay selected are kept; deselected apps' scans are dropped
    /// (and their running scans ignored); newly selected apps are scanned concurrently.
    func select(_ ids: Set<InstalledApp.ID>, known: [InstalledApp] = []) async {
        // Kaldırma/geri yükleme sürerken seçim değişmez: sonuç ve plan hep aynı uygulamalara ait kalır.
        guard !isWorking else { return }
        var byID: [InstalledApp.ID: InstalledApp] = [:]
        for app in apps + selectedApps + known { byID[app.id] = app }
        let ordered = visibleApps.map(\.id) + apps.map(\.id) + selectedApps.map(\.id) + known.map(\.id)
        var seen = Set<InstalledApp.ID>()
        let newApps = ordered.compactMap { id -> InstalledApp? in
            guard ids.contains(id), seen.insert(id).inserted else { return nil }
            return byID[id]
        }
        let needsScan = newApps.filter { scans[$0.id] == nil && scanTokens[$0.id] == nil }
        guard Set(newApps.map(\.id)) != selection || !needsScan.isEmpty else { return }
        selectedApps = newApps
        lastOutcome = nil
        batchOutcomes = nil
        let keep = Set(newApps.map(\.id))
        scans = scans.filter { keep.contains($0.key) }
        scanTokens = scanTokens.filter { keep.contains($0.key) }   // sürmekte olan eski taramalar yok sayılır
        let shownIDs = Set(scans.values.flatMap { $0.leftovers.map(\.id) })
        checked = checked.intersection(shownIDs)
        let tasks = needsScan.map { startScan($0) }
        for task in tasks { await task.value }
    }

    private func startScan(_ app: InstalledApp) -> Task<Void, Never> {
        let token = UUID()
        scanTokens[app.id] = token
        let env = environment
        let restricted = !hasFullDiskAccess
        return Task {
            let result = await Task.detached {
                let commands = ProcessCommandRunner()
                let inspector = AppInspector(commands: commands)
                let info = (try? inspector.inspect(app.info.url, includeTeamID: true)) ?? app.info
                // Koruma listesi taramayla birlikte diskten okunur: arayüz listesinin yüklenmesine bağlı değildir.
                var installed = InstalledApps(environment: env, inspector: inspector).infos()
                let path = app.info.url.standardizedFileURL.path
                if !installed.contains(where: { $0.url.standardizedFileURL.path == path }) { installed.append(app.info) }
                let scanner = LeftoverScanner(
                    environment: env, installedApps: installed,
                    launchd: LaunchdScanner(environment: env),
                    receipts: ReceiptScanner(environment: env, provider: PkgutilReceiptProvider()),
                    commands: commands, restricted: restricted)
                return scanner.scan(info)
            }.value
            guard scanTokens[app.id] == token else { return }
            scanTokens[app.id] = nil
            scans[app.id] = result
            checked.formUnion(result.leftovers.filter(\.selectedByDefault).map(\.id))
        }
    }

    /// Bırakılan ilk `.app` paketini seçer; listede yoksa listeye eklenir.
    func handleDrop(_ urls: [URL]) {
        guard !isWorking, let url = urls.first(where: { $0.pathExtension == "app" }) else { return }
        tab = .apps   // a dropped app is always shown on the Apps tab, even if it is already selected
        let path = url.standardizedFileURL.path
        if let existing = apps.first(where: { $0.info.url.standardizedFileURL.path == path }) {
            Task { await select(existing) }
            return
        }
        Task {
            // İnceleme ve boyut hesabı dosya sistemi işi: ana aktörün dışında.
            let inspected = await Task.detached { () -> InstalledApp? in
                guard let info = try? AppInspector(commands: ProcessCommandRunner()).inspect(url, includeTeamID: false)
                else { return nil }
                return InstalledApp(info: info, bundleSize: directorySize(url))
            }.value
            guard let app = inspected else {
                alertMessage = String(localized: "This doesn't look like an app.")
                return
            }
            guard !Self.ownBundleIDs.contains(app.info.bundleID), !ProtectedPaths.isAppleBundleID(app.info.bundleID) else {
                alertMessage = String(localized: "This app can't be uninstalled with Leftless.")
                return
            }
            if !apps.contains(where: { $0.id == app.id }) { apps.append(app) }
            await select(app)
        }
    }

    // MARK: - Kaldırma

    func isRunning(_ app: AppInfo) -> Bool {
        !AppTerminator.runningInstances(bundleID: app.bundleID).isEmpty
    }

    func isRunning(_ plan: UninstallPlan) -> Bool {
        !AppTerminator.runningInstances(bundleID: plan.scan.app.bundleID).isEmpty
    }

    /// Onaylanan planı uygular. Kapatma dahil tüm süre boyunca `isWorking` açıktır (seçim kilitli);
    /// plan artık ekrandaki taramaya ait değilse hiçbir şey taşınmaz.
    func uninstall(_ plan: UninstallPlan, quitFirst: Bool) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        if quitFirst {
            guard await AppTerminator.quit(bundleID: plan.scan.app.bundleID, timeout: 5) else {
                alertMessage = String(localized: "\(plan.scan.app.name) couldn't be quit. Please quit the app and try again.")
                return
            }
        }
        guard isShowing(plan.scan.app), plan.isValid(for: scan) else { return }
        let icon = Self.iconData(for: plan.scan.app.url)
        let env = environment, store = store
        let result = await Task.detached {
            let commands = ProcessCommandRunner()
            let uninstaller = Uninstaller(
                history: store, files: SystemFileMover(),
                privileged: OsascriptPrivilegedExecutor(commands: commands), commands: commands,
                environment: env, trashDirectory: env.home.appendingPathComponent(".Trash", isDirectory: true))
            return Result { try uninstaller.uninstall(plan.scan, selected: plan.selected, icon: icon) }
        }.value
        switch result {
        case .success(let outcome):
            if isShowing(plan.scan.app) { lastOutcome = outcome }
            reloadHistory()
            reloadApps()
        case .failure:
            alertMessage = String(localized: "Couldn't write the history record; no files were moved.")
        }
    }

    private func isShowing(_ app: AppInfo) -> Bool {
        return singleSelection?.info.url == app.url
    }

    /// Apps of the plan that are open now, in plan order.
    func runningApps(in plan: BatchUninstallPlan) -> [AppInfo] {
        plan.plans.map(\.scan.app).filter(isRunning)
    }

    /// Batch version of `uninstall(_:quitFirst:)`: one quit step for all running apps (if any fails to quit,
    /// nothing is moved), then one `uninstall(batch:)` run (one record per app, one password prompt).
    func uninstall(_ plan: BatchUninstallPlan, quitFirst: Bool) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        if quitFirst {
            var bundleIDs: [String] = []
            for app in plan.plans.map(\.scan.app) where !bundleIDs.contains(app.bundleID) { bundleIDs.append(app.bundleID) }
            let quits = bundleIDs.map { id in Task { await AppTerminator.quit(bundleID: id, timeout: 5) } }
            var failedIDs = Set<String>()
            for (id, quit) in zip(bundleIDs, quits) {
                if await !quit.value { failedIDs.insert(id) }
            }
            let failed = plan.plans.map(\.scan.app).filter { failedIDs.contains($0.bundleID) }.map(\.name)
            guard failed.isEmpty else {
                // Hiçbir şey taşınmaz: kapanmayan uygulama(lar) adıyla bildirilir.
                let names = ListFormatter.localizedString(byJoining: failed)
                alertMessage = failed.count == 1
                    ? String(localized: "Nothing was moved because \(names) couldn't be quit. Please quit the app and try again.")
                    : String(localized: "Nothing was moved because \(names) couldn't be quit. Please quit these apps and try again.")
                return
            }
        }
        guard plan.isValid(for: selectedScans) else { return }
        let jobs = plan.plans.map {
            UninstallJob(scan: $0.scan, selected: $0.selected, icon: Self.iconData(for: $0.scan.app.url))
        }
        let env = environment, store = store
        let result = await Task.detached {
            let commands = ProcessCommandRunner()
            let uninstaller = Uninstaller(
                history: store, files: SystemFileMover(),
                privileged: OsascriptPrivilegedExecutor(commands: commands), commands: commands,
                environment: env, trashDirectory: env.home.appendingPathComponent(".Trash", isDirectory: true))
            return Result { try uninstaller.uninstall(batch: jobs) }
        }.value
        switch result {
        case .success(let outcomes):
            // A job left with no items (all claimed by an earlier app) has no saved record: not shown.
            if plan.isValid(for: selectedScans) { batchOutcomes = outcomes.filter { !$0.record.items.isEmpty } }
            reloadHistory()
            reloadApps()
        case .failure:
            alertMessage = String(localized: "Couldn't write the history record; no files were moved.")
        }
    }

    // MARK: - Geri yükleme

    /// Çakışma varsa önce kullanıcıya sorulur (`pendingRestore`); yoksa hemen geri yükler.
    func restore(_ r: HistoryRecord) async {
        let fm = FileManager.default
        let conflicts = RestoreConflicts.detect(in: r) { fm.fileExists(atPath: $0) }
        if conflicts.isEmpty {
            await performRestore(r, answers: [:])
        } else {
            pendingRestore = PendingRestore(record: r, conflicts: conflicts)
        }
    }

    func resolveRestore(_ pending: PendingRestore, choice: ConflictChoice) async {
        pendingRestore = nil
        let answers = Dictionary(uniqueKeysWithValues: pending.conflicts.map { ($0.id, choice) })
        await performRestore(pending.record, answers: answers)
    }

    private func performRestore(_ r: HistoryRecord, answers: [UUID: ConflictChoice]) async {
        guard !isWorking else { return }
        let env = environment, store = store
        isWorking = true
        let outcome = await Task.detached {
            let commands = ProcessCommandRunner()
            let restorer = Restorer(history: store, files: SystemFileMover(),
                                    privileged: OsascriptPrivilegedExecutor(commands: commands),
                                    commands: commands, environment: env)
            // Önceden sorulmamış bir çakışma çıkarsa güvenli tarafta kalınır: atla.
            return restorer.restore(r) { answers[$0.id] ?? .skip }
        }.value
        // One full sentence per line: counts use the catalog's plural variants.
        var lines = [String(localized: "\(outcome.restored) items were restored.")]
        if outcome.skipped > 0 { lines.append(String(localized: "\(outcome.skipped) items were skipped.")) }
        if !outcome.failures.isEmpty {
            lines.append(String(localized: "\(outcome.failures.count) items couldn't be restored."))
        }
        restoreSummary = lines.joined(separator: "\n")
        isWorking = false   // yeniden tarama `select` ile yapılacağı için burada kapatılır
        if lastOutcome?.record.id == r.id { lastOutcome = nil }
        reloadHistory()
        reloadApps()
        // A batch result stays on screen (each row shows its own restore state); otherwise the shown apps are
        // scanned again, since restored files may be their leftovers.
        guard batchOutcomes == nil else { return }
        let rescan = selectedApps.filter { FileManager.default.fileExists(atPath: $0.info.url.path) }
        guard !rescan.isEmpty else { return }
        for app in rescan { scans[app.id] = nil }
        await select(selection)
    }

    func deleteRecord(_ r: HistoryRecord) {
        do { try store.delete(id: r.id) } catch { alertMessage = String(localized: "Couldn't delete the record.") }
        reloadHistory()
    }

    // MARK: - Yardımcılar

    static func iconData(for url: URL) -> Data? {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    static func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
