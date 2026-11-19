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
    /// Trashed paths already notified in this run (also across turning the setting off and on).
    private var notified: Set<String> = []

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
        let monitor = TrashMonitor(directory: trash, debounce: 1, ignoring: [ownBundle]) { [weak self] paths in
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

    private func handle(_ paths: [String]) {
        for path in paths where !notified.contains(path) {
            Task { await check(path) }
        }
    }

    /// Scans one trashed app off the main actor (installed list read as in `AppModel.select`) and notifies
    /// if it left anything besides its bundle.
    private func check(_ path: String) async {
        let env = environment
        let restricted = !FullDiskAccess.isGranted()
        let ownIDs = AppModel.ownBundleIDs
        let scan = await Task.detached { () -> ScanResult? in
            let commands = ProcessCommandRunner()
            let inspector = AppInspector(commands: commands)
            guard let info = try? inspector.inspect(URL(fileURLWithPath: path), includeTeamID: true) else { return nil }
            var installed = InstalledApps(environment: env, inspector: inspector).infos()
            guard TrashWatch.shouldScan(info, installed: installed, ownBundleIDs: ownIDs) else { return nil }
            installed.append(info)
            let scanner = LeftoverScanner(
                environment: env, installedApps: installed,
                launchd: LaunchdScanner(environment: env),
                receipts: ReceiptScanner(environment: env, provider: PkgutilReceiptProvider()),
                commands: commands, restricted: restricted)
            return TrashWatch.removingAppBundle(from: scanner.scan(info))
        }.value
        guard isWatching, let scan, !scan.leftovers.isEmpty, notified.insert(path).inserted else { return }
        TrashNotifications.post(appName: scan.app.name, count: scan.leftovers.count, size: scan.totalSize,
                                trashedPath: path)
    }
}
