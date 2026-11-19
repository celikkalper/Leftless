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
    var selection: InstalledApp?
    var scan: ScanResult?
    var checked: Set<UUID> = []
    var isScanning = false
    var isLoadingApps = false
    var isWorking = false
    var history: [HistoryRecord] = []
    var historyStatus: [UUID: RestoreStatus] = [:]
    var lastOutcome: UninstallOutcome?
    var pendingRestore: PendingRestore?
    var alertMessage: String?
    var restoreSummary: String?
    var hasFullDiskAccess = FullDiskAccess.isGranted()
    var onboardingSkipped = false
    var searchText = ""
    var sort: AppListSort = .name

    private let environment = ScanEnvironment.live()
    private let store = HistoryStore(directory: HistoryStore.liveDirectory())
    private var scanToken = UUID()

    var visibleApps: [InstalledApp] {
        AppListArrangement.arrange(apps, query: searchText, sort: sort, excludingBundleIDs: Self.ownBundleIDs)
    }

    var summary: UninstallSummary {
        UninstallSummary(leftovers: scan?.leftovers ?? [], checked: checked)
    }

    init() {
        reloadApps()
        reloadHistory()
    }

    // MARK: - Liste

    func reloadApps() {
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

    func refreshFullDiskAccess() {
        hasFullDiskAccess = FullDiskAccess.isGranted()
    }

    // MARK: - Tarama

    func select(_ newSelection: InstalledApp?) async {
        // Kaldırma/geri yükleme sürerken seçim değişmez: sonuç ve plan hep aynı uygulamaya ait kalır.
        guard !isWorking else { return }
        guard newSelection != selection || (scan == nil && !isScanning) else { return }
        selection = newSelection
        lastOutcome = nil
        scan = nil
        checked = []
        guard let app = newSelection else {
            scanToken = UUID()   // sürmekte olan tarama sonucu yok sayılır
            isScanning = false
            return
        }
        tab = .apps
        let token = UUID()
        scanToken = token
        isScanning = true
        let env = environment
        let restricted = !hasFullDiskAccess
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
        guard scanToken == token else { return }
        scan = result
        checked = Set(result.leftovers.filter(\.selectedByDefault).map(\.id))
        isScanning = false
    }

    /// Bırakılan ilk `.app` paketini seçer; listede yoksa listeye eklenir.
    func handleDrop(_ urls: [URL]) {
        guard !isWorking, let url = urls.first(where: { $0.pathExtension == "app" }) else { return }
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
        return selection?.info.url == app.url
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
        if let app = selection, FileManager.default.fileExists(atPath: app.info.url.path) {
            scan = nil
            await select(app)
        }
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
