import Testing
import Foundation
@testable import LeftlessCore

@Suite struct TrashWatchTests {
    let trash = "/Users/tester/.Trash"
    /// Fake paths: every `.app` entry counts as an app bundle unless a test says otherwise.
    let anyApp: (String) -> Bool = { _ in true }

    @Test func onlyNewAppsReported() {
        let new = TrashWatch.newApps(previous: ["\(trash)/Old.app"],
                                     current: ["\(trash)/Old.app", "\(trash)/SoundWave.app", "\(trash)/Clip.app"],
                                     ignoring: [], isApp: anyApp)
        #expect(new == ["\(trash)/SoundWave.app", "\(trash)/Clip.app"])
    }

    @Test func nonAppsIgnored() {
        let new = TrashWatch.newApps(previous: [],
                                     current: ["\(trash)/notes.txt", "\(trash)/Folder", "\(trash)/Archive.app.zip",
                                               "\(trash)/Tool.APP"],
                                     ignoring: [], isApp: anyApp)
        #expect(new == ["\(trash)/Tool.APP"])
    }

    @Test func sameAppNotReportedTwice() {
        let first = TrashWatch.newApps(previous: [], current: ["\(trash)/SoundWave.app"], ignoring: [], isApp: anyApp)
        #expect(first == ["\(trash)/SoundWave.app"])
        let again = TrashWatch.newApps(previous: Set(first), current: ["\(trash)/SoundWave.app"], ignoring: [], isApp: anyApp)
        #expect(again.isEmpty)
        let duplicated = TrashWatch.newApps(previous: [], current: ["\(trash)/A.app", "\(trash)/A.app"], ignoring: [], isApp: anyApp)
        #expect(duplicated == ["\(trash)/A.app"])
    }

    @Test func ownBundleIgnored() {
        let new = TrashWatch.newApps(previous: [], current: ["\(trash)/Leftless.app", "\(trash)/SoundWave.app"],
                                     ignoring: ["\(trash)/Leftless.app"], isApp: anyApp)
        #expect(new == ["\(trash)/SoundWave.app"])
    }

    @Test func onlyEntriesWithInfoPlistAreApps() throws {
        let fs = try FakeSystem(); defer { fs.cleanup() }
        let dir = fs.home.appendingPathComponent(".Trash", isDirectory: true)
        let fm = FileManager.default
        let real = dir.appendingPathComponent("Real.app"), hollow = dir.appendingPathComponent("Hollow.app")
        try fm.createDirectory(at: real.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data().write(to: real.appendingPathComponent("Contents/Info.plist"))
        try fm.createDirectory(at: hollow, withIntermediateDirectories: true)
        let new = TrashWatch.newApps(previous: [], current: [hollow.path, real.path], ignoring: [])
        #expect(new == [real.path])
        var asked: [String] = []
        _ = TrashWatch.newApps(previous: [], current: ["\(trash)/A.app", "\(trash)/notes.txt"], ignoring: []) {
            asked.append($0); return false
        }
        #expect(asked == ["\(trash)/A.app"])
    }

    @Test func appsMovedByLeftlessAreRecognised() {
        let moved = HistoryItem(originalPath: "/Applications/SoundWave.app", trashPath: "\(trash)/SoundWave 2.app",
                                kind: .appBundle, size: 1, state: .trashed)
        let pending = HistoryItem(originalPath: "/Applications/Clip.app", trashPath: "\(trash)/Clip.app",
                                  kind: .appBundle, size: 1, requiresAdmin: true)
        let noTarget = HistoryItem(originalPath: "/u/Library/Caches/x", kind: .caches, size: 1, state: .failed)
        let records = [HistoryRecord(appName: "SoundWave", bundleID: "s", items: [moved, noTarget]),
                       HistoryRecord(appName: "Clip", bundleID: "c", items: [pending])]
        let recorded = TrashWatch.recordedTrashPaths(in: records)
        #expect(recorded == ["\(trash)/SoundWave 2.app", "\(trash)/Clip.app"])

        func byLeftless(_ path: String, _ id: String?, ignored: Set<String> = [], moving: Set<String> = []) -> Bool {
            TrashWatch.isMovedByLeftless(path: path, bundleID: id, recordedTrashPaths: recorded,
                                         ignoredPaths: ignored, movingBundleIDs: moving)
        }
        #expect(byLeftless("\(trash)/SoundWave 2.app", nil))                       // recorded in history
        #expect(byLeftless("\(trash)/./Clip.app", "c"))                            // same path, not standardized
        #expect(!byLeftless("\(trash)/SoundWave.app", "s"))                        // the user trashed another copy
        #expect(byLeftless("\(trash)/Tool.app", nil, ignored: ["\(trash)/Tool.app"]))   // registered by the app
        #expect(byLeftless("\(trash)/Tool 3.app", "t", moving: ["t"]))             // being moved right now
        #expect(!byLeftless("\(trash)/Tool 3.app", nil, moving: ["t"]))            // bundle ID not known yet
        #expect(!byLeftless("\(trash)/Other.app", "o", moving: ["t"]))
    }

    @Test func trashLocationDetected() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        #expect(TrashWatch.isInTrash(URL(fileURLWithPath: "/Users/tester/.Trash/SoundWave.app"), home: home))
        #expect(TrashWatch.isInTrash(URL(fileURLWithPath: "/Volumes/Disk/.Trashes/501/SoundWave.app"), home: home))
        #expect(!TrashWatch.isInTrash(URL(fileURLWithPath: "/Applications/SoundWave.app"), home: home))
        #expect(!TrashWatch.isInTrash(URL(fileURLWithPath: "/Users/tester/.TrashOld/SoundWave.app"), home: home))
    }

    @Test func appBundleRemovedFromScan() {
        let app = AppInfo(url: URL(fileURLWithPath: "\(trash)/SoundWave.app"), bundleID: "com.example.soundwave",
                          name: "SoundWave")
        let bundle = Leftover(url: app.url, kind: .appBundle, confidence: .certain, size: 100)
        let cache = Leftover(url: URL(fileURLWithPath: "/Users/tester/Library/Caches/com.example.soundwave"),
                             kind: .caches, confidence: .certain, size: 5)
        let scan = ScanResult(app: app, leftovers: [bundle, cache], skippedLocations: ["x"])
        let result = TrashWatch.removingAppBundle(from: scan)
        #expect(result.leftovers == [cache])
        #expect(result.app == app)
        #expect(result.skippedLocations == ["x"])
    }

    @Test func scanSkippedForOwnAppleAndStillInstalledApps() {
        let trashed = AppInfo(url: URL(fileURLWithPath: "\(trash)/SoundWave.app"), bundleID: "com.example.soundwave",
                              name: "SoundWave")
        let other = AppInfo(url: URL(fileURLWithPath: "/Applications/Clip.app"), bundleID: "com.example.clip", name: "Clip")
        #expect(TrashWatch.shouldScan(trashed, installed: [other], ownBundleIDs: ["com.leftless.app"]))
        var copy = trashed
        copy.url = URL(fileURLWithPath: "/Applications/SoundWave.app")
        #expect(!TrashWatch.shouldScan(trashed, installed: [other, copy], ownBundleIDs: []))
        #expect(!TrashWatch.shouldScan(AppInfo(url: trashed.url, bundleID: "com.leftless.app", name: "Leftless"),
                                       installed: [], ownBundleIDs: ["com.leftless.app"]))
        #expect(!TrashWatch.shouldScan(AppInfo(url: trashed.url, bundleID: "com.apple.Safari", name: "Safari"),
                                       installed: [], ownBundleIDs: []))
    }
}

/// Runs the real file-system monitor against a temp directory (never the real Trash).
@Suite struct TrashMonitorTests {
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var _batches: [[String]] = []
        func add(_ paths: [String]) { lock.lock(); _batches.append(paths); lock.unlock() }
        var batches: [[String]] { lock.lock(); defer { lock.unlock() }; return _batches }
    }

    /// Polls `condition` until it holds or `timeout` passes (no fixed sleeps: a slow machine only waits longer).
    @discardableResult
    static func waitUntil(timeout: Double = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// Snapshots (entries present in the directory) passed to `onSnapshot`.
    final class SnapshotLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _last: Set<String>?
        func add(_ present: Set<String>) { lock.lock(); _last = present; lock.unlock() }
        var last: Set<String>? { lock.lock(); defer { lock.unlock() }; return _last }
    }

    /// Creates `<dir>/<name>` as a minimal app bundle (with `Contents/Info.plist`), or as a bare folder.
    static func addBundle(_ name: String, in dir: URL, infoPlist: Bool = true) throws {
        let bundle = dir.appendingPathComponent(name)
        // Built next to the directory and moved in, as Finder does, so it appears complete.
        let staging = dir.deletingLastPathComponent().appendingPathComponent("staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        if infoPlist { try Data().write(to: staging.appendingPathComponent("Contents/Info.plist")) }
        try FileManager.default.moveItem(at: staging, to: bundle)
    }

    @Test func reportsAppsAddedAfterStartOnce() async throws {
        let fs = try FakeSystem(); defer { fs.cleanup() }
        let dir = fs.home.appendingPathComponent(".Trash", isDirectory: true)
        let fm = FileManager.default
        func path(_ name: String) -> String { dir.appendingPathComponent(name).path }
        func add(_ name: String, infoPlist: Bool = true) throws { try Self.addBundle(name, in: dir, infoPlist: infoPlist) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try add("Old.app")
        let collector = Collector()
        let snapshots = SnapshotLog()
        let monitor = TrashMonitor(directory: dir, debounce: 0.1, ignoring: [path("Mine.app")],
                                   onSnapshot: { snapshots.add($0) }) { collector.add($0) }
        #expect(monitor.start())
        defer { monitor.stop() }
        // Batches may be split differently on a busy machine; only the reported paths and their order matter.
        var reported: [String] { collector.batches.flatMap { $0 } }

        // Non-apps, folders without Info.plist, the ignored bundle and apps present at start are never reported.
        try Data().write(to: dir.appendingPathComponent("notes.txt"))
        try add("Hollow.app", infoPlist: false)
        try add("Mine.app")
        try add("SoundWave.app")
        #expect(await Self.waitUntil { reported.contains(path("SoundWave.app")) })
        #expect(reported == [path("SoundWave.app")])

        // Removing it and adding it back within one burst doesn't report it again; a different app is reported.
        try fm.removeItem(atPath: path("SoundWave.app"))
        try add("SoundWave.app")
        try add("Clip.app")
        #expect(await Self.waitUntil { reported.contains(path("Clip.app")) })

        // Once a snapshot shows it gone (Trash emptied), the same app trashed again is reported again.
        try fm.removeItem(atPath: path("Clip.app"))
        #expect(await Self.waitUntil { snapshots.last.map { !$0.contains(path("Clip.app")) } ?? false })
        try add("Clip.app")
        #expect(await Self.waitUntil { reported.filter { $0 == path("Clip.app") }.count == 2 })

        // A later app is reported after everything before it, so nothing else can still be on its way.
        try add("Sentinel.app")
        #expect(await Self.waitUntil { reported.contains(path("Sentinel.app")) })
        #expect(reported == [path("SoundWave.app"), path("Clip.app"), path("Clip.app"), path("Sentinel.app")])
    }

    @Test func stoppedMonitorReportsNothing() async throws {
        let fs = try FakeSystem(); defer { fs.cleanup() }
        let dir = fs.home.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let collector = Collector()
        let monitor = TrashMonitor(directory: dir, debounce: 0.1, ignoring: []) { collector.add($0) }
        #expect(monitor.start())
        monitor.stop()
        // A second, running monitor shows when the change has been seen (instead of sleeping a fixed time).
        let control = Collector()
        let running = TrashMonitor(directory: dir, debounce: 0.1, ignoring: []) { control.add($0) }
        #expect(running.start())
        defer { running.stop() }
        try Self.addBundle("SoundWave.app", in: dir)
        #expect(await Self.waitUntil { !control.batches.isEmpty })
        #expect(collector.batches.isEmpty)
    }

    @Test func missingDirectoryFailsToStart() throws {
        let fs = try FakeSystem(); defer { fs.cleanup() }
        let monitor = TrashMonitor(directory: fs.root.appendingPathComponent("nope"), debounce: 0.1, ignoring: []) { _ in }
        #expect(!monitor.start())
    }
}

@Suite struct TrashNotificationSummaryTests {
    @Test func countsOnlyCertainLeftovers() throws {
        let app = AppInfo(url: URL(fileURLWithPath: "/Users/tester/.Trash/SoundWave.app"),
                          bundleID: "com.example.soundwave", name: "SoundWave")
        let sure = Leftover(url: URL(fileURLWithPath: "/u/Library/Caches/a"), kind: .caches, confidence: .certain, size: 7)
        let sure2 = Leftover(url: URL(fileURLWithPath: "/u/Library/Preferences/a"), kind: .preferences,
                             confidence: .certain, size: 3)
        let maybe = Leftover(url: URL(fileURLWithPath: "/u/Library/Application Support/a"), kind: .applicationSupport,
                             confidence: .probable, size: 1000)
        let summary = try #require(TrashWatch.notificationSummary(ScanResult(app: app, leftovers: [sure, maybe, sure2])))
        #expect(summary.count == 2)
        #expect(summary.size == 10)
        #expect(TrashWatch.notificationSummary(ScanResult(app: app, leftovers: [maybe])) == nil)
        #expect(TrashWatch.notificationSummary(ScanResult(app: app, leftovers: [])) == nil)
    }
}
