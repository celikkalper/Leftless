import AppKit
import KalintisizCore
import Observation

enum Selection: Hashable {
    case app(InstalledApp)
    case history
}

struct PendingRestore: Identifiable {
    let id = UUID()
    let record: HistoryRecord
    let conflicts: [HistoryItem]
}

@MainActor @Observable
final class AppModel {
    static let ownBundleID = "com.kalintisiz.app"

    var apps: [InstalledApp] = []
    var selection: Selection?
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
        AppListArrangement.arrange(apps, query: searchText, sort: sort, excludingBundleID: Self.ownBundleID)
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

    func refreshFullDiskAccess() {
        hasFullDiskAccess = FullDiskAccess.isGranted()
    }

    // MARK: - Tarama

    func select(_ newSelection: Selection?) async {
        // Kaldırma/geri yükleme sürerken seçim değişmez: sonuç ve plan hep aynı uygulamaya ait kalır.
        guard !isWorking else { return }
        guard newSelection != selection || (scan == nil && !isScanning) else { return }
        selection = newSelection
        lastOutcome = nil
        scan = nil
        checked = []
        guard case .app(let app) = newSelection else {
            scanToken = UUID()   // sürmekte olan tarama sonucu yok sayılır
            isScanning = false
            if newSelection == .history { reloadHistory() }
            return
        }
        let token = UUID()
        scanToken = token
        isScanning = true
        let env = environment
        let installed = apps.map(\.info)
        let result = await Task.detached {
            let commands = ProcessCommandRunner()
            let info = (try? AppInspector(commands: commands).inspect(app.info.url, includeTeamID: true)) ?? app.info
            let scanner = LeftoverScanner(
                environment: env, installedApps: installed,
                launchd: LaunchdScanner(environment: env),
                receipts: ReceiptScanner(environment: env, provider: PkgutilReceiptProvider()),
                commands: commands)
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
            Task { await select(.app(existing)) }
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
                alertMessage = "Bu bir uygulama paketi gibi görünmüyor."
                return
            }
            guard app.info.bundleID != Self.ownBundleID, !ProtectedPaths.isAppleBundleID(app.info.bundleID) else {
                alertMessage = "Bu uygulama Kalıntısız ile kaldırılamaz."
                return
            }
            if !apps.contains(where: { $0.id == app.id }) { apps.append(app) }
            await select(.app(app))
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
                alertMessage = "\(plan.scan.app.name) kapatılamadı. Lütfen uygulamayı kapatıp yeniden deneyin."
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
            alertMessage = "Geçmiş kaydı yazılamadı; hiçbir dosya taşınmadı."
        }
    }

    private func isShowing(_ app: AppInfo) -> Bool {
        if case .app(let selected) = selection { return selected.info.url == app.url }
        return false
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
        var parts = ["\(outcome.restored) öğe geri yüklendi"]
        if outcome.skipped > 0 { parts.append("\(outcome.skipped) öğe atlandı") }
        if !outcome.failures.isEmpty { parts.append("\(outcome.failures.count) öğe geri yüklenemedi") }
        restoreSummary = parts.joined(separator: ", ") + "."
        isWorking = false   // yeniden tarama `select` ile yapılacağı için burada kapatılır
        if lastOutcome?.record.id == r.id { lastOutcome = nil }
        reloadHistory()
        reloadApps()
        if case .app(let app) = selection, FileManager.default.fileExists(atPath: app.info.url.path) {
            scan = nil
            await select(.app(app))
        }
    }

    func deleteRecord(_ r: HistoryRecord) {
        do { try store.delete(id: r.id) } catch { alertMessage = "Kayıt silinemedi." }
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
