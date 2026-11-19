import Foundation

/// Rules for the "Watch the Trash" feature: which Trash entries are newly deleted apps, and how their scans
/// are shown (the bundle itself is already in the Trash, so it is never offered for moving).
public enum TrashWatch {
    /// Paths in `current` that are app bundles (`.app`), not in `previous` and not ignored, in `current` order.
    /// `previous` should hold every path seen so far, so an app is reported at most once.
    public static func newApps(previous: Set<String>, current: [String], ignoring ownBundlePaths: Set<String>) -> [String] {
        var seen = previous.union(ownBundlePaths)
        return current.filter { path in
            path.lowercased().hasSuffix(".app") && seen.insert(path).inserted
        }
    }

    /// Whether the URL is inside the user's Trash (`~/.Trash`) or a volume's `.Trashes` folder.
    public static func isInTrash(_ url: URL, home: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let trash = home.appendingPathComponent(".Trash", isDirectory: true).standardizedFileURL.path
        return path.hasPrefix(trash + "/") || url.standardizedFileURL.pathComponents.contains(".Trashes")
    }

    /// The scan without its `.appBundle` item (the app is already in the Trash).
    public static func removingAppBundle(from scan: ScanResult) -> ScanResult {
        var result = scan
        result.leftovers.removeAll { $0.kind == .appBundle }
        return result
    }

    /// Count and size shown in the "left N items" notification: only certain (pre-ticked) leftovers.
    /// `nil` when there are none, so no notification is posted.
    public static func notificationSummary(_ scan: ScanResult) -> (count: Int, size: Int64)? {
        let certain = scan.leftovers.filter(\.selectedByDefault)
        guard !certain.isEmpty else { return nil }
        return (certain.count, certain.reduce(0) { $0 + $1.size })
    }

    /// A trashed app is scanned unless it is Leftless itself, an Apple app, or another copy with the same
    /// bundle ID is still installed (the leftovers then belong to that copy).
    public static func shouldScan(_ app: AppInfo, installed: [AppInfo], ownBundleIDs: Set<String>) -> Bool {
        guard !ownBundleIDs.contains(app.bundleID), !ProtectedPaths.isAppleBundleID(app.bundleID) else { return false }
        let path = app.url.standardizedFileURL.path
        return !installed.contains { $0.bundleID == app.bundleID && $0.url.standardizedFileURL.path != path }
    }
}

/// Watches one directory (the Trash) for app bundles that appear after `start()`. Changes are debounced:
/// after the last change in a burst, the directory is listed once and new apps are passed to `onNewApps`
/// (on the monitor's own queue). Apps present at start, and any path reported before, are never reported.
public final class TrashMonitor: @unchecked Sendable {
    private let directory: URL
    private let debounce: TimeInterval
    private let ignoring: Set<String>
    private let onNewApps: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "com.leftless.trash-monitor")
    // State below is only touched on `queue`.
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var seen: Set<String> = []

    public init(directory: URL, debounce: TimeInterval = 1, ignoring: Set<String>,
                onNewApps: @escaping @Sendable ([String]) -> Void) {
        self.directory = directory
        self.debounce = debounce
        self.ignoring = ignoring
        self.onNewApps = onNewApps
    }

    deinit { source?.cancel() }

    /// Takes the initial snapshot and starts watching. Returns false if the directory can't be opened or listed.
    public func start() -> Bool {
        queue.sync {
            guard source == nil else { return true }
            guard let initial = snapshot() else { return false }
            let fd = open(directory.path, O_EVTONLY)
            guard fd >= 0 else { return false }
            seen = Set(initial)
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: queue)
            src.setEventHandler { [weak self] in self?.scheduleCheck() }
            src.setCancelHandler { close(fd) }
            source = src
            src.resume()
            return true
        }
    }

    public func stop() {
        queue.sync {
            pending?.cancel()
            pending = nil
            source?.cancel()
            source = nil
        }
    }

    private func scheduleCheck() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.check() }
        pending = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    private func check() {
        pending = nil
        guard source != nil, let current = snapshot() else { return }
        let new = TrashWatch.newApps(previous: seen, current: current, ignoring: ignoring)
        seen.formUnion(current)
        if !new.isEmpty { onNewApps(new) }
    }

    private func snapshot() -> [String]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        return names.sorted().map { directory.appendingPathComponent($0).path }
    }
}
