import AppKit
import LeftlessCore

/// "Watch the Trash for deleted apps": while on, every app that lands in `~/.Trash` is scanned for leftovers
/// (the bundle itself excluded) and, if any are found, a notification offers to clean them up.
@MainActor
final class TrashWatcher {
    /// `@AppStorage` key of the setting (off by default).
    static let settingKey = "watchTrash"

    enum EnableResult {
        case watching
        /// Watching, but the login item needs the user's approval in System Settings.
        case loginItemNeedsApproval
        /// Watching while Leftless runs, but it couldn't be added as a login item.
        case loginItemFailed
        case notificationsDenied
        case cannotReadTrash
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: settingKey) }

    private let environment = ScanEnvironment.live()
    private var monitor: TrashMonitor?
    /// Trashed paths already notified that are still in the Trash (forgotten once they leave it, so an app
    /// trashed again after emptying the Trash notifies again).
    private var notified: Set<String> = []
    /// Trash paths Leftless itself moved apps to in this run (registered by `AppModel`); never notified.
    private var ignoredPaths: Set<String> = []
    /// Bundle IDs of apps an uninstall is moving right now (count per running operation).
    private var movingBundleIDs: [String: Int] = [:]

    var isWatching: Bool { monitor != nil }

    /// Turns the setting on: notification permission first (declined → stays off), then watching, then the
    /// login item (watching continues even if that fails or needs approval).
    func enable() async -> EnableResult {
        guard await TrashNotifications.requestAuthorization() else { return .notificationsDenied }
        guard start() else { return .cannotReadTrash }
        UserDefaults.standard.set(true, forKey: Self.settingKey)
        switch LoginItem.register() {
        case .enabled: return .watching
        case .requiresApproval: return .loginItemNeedsApproval
        case .failed: return .loginItemFailed
        }
    }

    /// Turns the setting off: stops watching and removes the login item.
    func disable() {
        UserDefaults.standard.set(false, forKey: Self.settingKey)
        stop()
        LoginItem.unregister()
    }

    /// Starts watching if the setting is on and the Trash can be read. Apps already in the Trash never notify.
    @discardableResult
    func startIfEnabled() -> Bool {
        guard Self.isEnabled, FullDiskAccess.isGranted() else { return false }
        return start()
    }

    private func start() -> Bool {
        guard monitor == nil else { return true }
        let trash = environment.home.appendingPathComponent(".Trash", isDirectory: true)
        let ownBundle = trash.appendingPathComponent(Bundle.main.bundleURL.lastPathComponent).path
        let monitor = TrashMonitor(directory: trash, debounce: 1, ignoring: [ownBundle], onSnapshot: { [weak self] present in
            Task { @MainActor in self?.trimNotified(to: present) }
        }) { [weak self] paths in
            Task { @MainActor in self?.handle(paths) }
        }
        guard monitor.start() else { return false }
        self.monitor = monitor
        return true
    }

    func stop() {
        monitor?.stop()
        monitor = nil
    }

    // MARK: - Moves made by Leftless

    /// Called before an uninstall moves these apps' bundles: a trashed app with one of these bundle IDs is not
    /// reported until `didMove` (the history record on disk covers it afterwards).
    func willMove(bundleIDs: [String]) {
        for id in bundleIDs { movingBundleIDs[id, default: 0] += 1 }
    }

    /// Called after the move with the record's trash paths (belt and braces next to the history check).
    func didMove(bundleIDs: [String], trashPaths: [String]) {
        ignoredPaths.formUnion(trashPaths)
        for id in bundleIDs {
            let count = (movingBundleIDs[id] ?? 1) - 1
            movingBundleIDs[id] = count > 0 ? count : nil
        }
    }

    private func isMovedByLeftless(_ path: String, bundleID: String?, recorded: Set<String>) -> Bool {
        TrashWatch.isMovedByLeftless(path: path, bundleID: bundleID, recordedTrashPaths: recorded,
                                     ignoredPaths: ignoredPaths, movingBundleIDs: Set(movingBundleIDs.keys))
    }

    // MARK: - Checking trashed apps

    private func trimNotified(to present: Set<String>) {
        notified.formIntersection(present)
        ignoredPaths.formIntersection(present)
    }

    private func handle(_ paths: [String]) {
        for path in paths where !notified.contains(path) && !isMovedByLeftless(path, bundleID: nil, recorded: []) {
            Task { await check(path) }
        }
    }

    /// Scans one trashed app off the main actor (installed list read as in `AppModel.select`) and notifies
    /// if it left certain leftovers besides its bundle.
    private func check(_ path: String) async {
        let env = environment
        let restricted = !FullDiskAccess.isGranted()
        let ownIDs = AppModel.ownBundleIDs
        let moving = Set(movingBundleIDs.keys), ignored = ignoredPaths
        let (scan, recordedAfterScan) = await Task.detached { () -> (ScanResult?, Set<String>) in
            // Apps Leftless itself uninstalled: their trash paths are in a history record, saved before the
            // admin step (so also while the password prompt is open or when items were unticked on purpose).
            let recorded = Self.recordedTrashPaths()
            guard !TrashWatch.isMovedByLeftless(path: path, bundleID: nil, recordedTrashPaths: recorded,
                                                ignoredPaths: ignored, movingBundleIDs: moving) else { return (nil, recorded) }
            let commands = ProcessCommandRunner()
            let inspector = AppInspector(commands: commands)
            guard let info = try? inspector.inspect(URL(fileURLWithPath: path), includeTeamID: true),
                  !TrashWatch.isMovedByLeftless(path: path, bundleID: info.bundleID, recordedTrashPaths: recorded,
                                                ignoredPaths: ignored, movingBundleIDs: moving)
            else { return (nil, recorded) }
            var installed = InstalledApps(environment: env, inspector: inspector).infos()
            guard TrashWatch.shouldScan(info, installed: installed, ownBundleIDs: ownIDs) else { return (nil, recorded) }
            installed.append(info)
            let scanner = LeftoverScanner(
                environment: env, installedApps: installed,
                launchd: LaunchdScanner(environment: env),
                receipts: ReceiptScanner(environment: env, provider: PkgutilReceiptProvider()),
                commands: commands, restricted: restricted)
            let scan = TrashWatch.removingAppBundle(from: scanner.scan(info))
            return (scan, Self.recordedTrashPaths())   // read again: an uninstall may have saved a record meanwhile
        }.value
        // Only certain (pre-ticked) leftovers count; possible matches alone never notify.
        // Checked again: an uninstall may have started or finished while the scan ran.
        guard isWatching, let scan, let summary = TrashWatch.notificationSummary(scan),
              !isMovedByLeftless(path, bundleID: scan.app.bundleID, recorded: recordedAfterScan),
              notified.insert(path).inserted else { return }
        TrashNotifications.post(appName: scan.app.name, count: summary.count, size: summary.size, trashedPath: path)
    }

    /// Trash paths in the history records on disk (read off the main actor).
    nonisolated private static func recordedTrashPaths() -> Set<String> {
        TrashWatch.recordedTrashPaths(in: (try? HistoryStore(directory: HistoryStore.liveDirectory()).all()) ?? [])
    }
}
