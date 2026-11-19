import Testing
import Foundation
@testable import LeftlessCore

@Suite struct TrashWatchTests {
    let trash = "/Users/tester/.Trash"

    @Test func onlyNewAppsReported() {
        let new = TrashWatch.newApps(previous: ["\(trash)/Old.app"],
                                     current: ["\(trash)/Old.app", "\(trash)/SoundWave.app", "\(trash)/Clip.app"],
                                     ignoring: [])
        #expect(new == ["\(trash)/SoundWave.app", "\(trash)/Clip.app"])
    }

    @Test func nonAppsIgnored() {
        let new = TrashWatch.newApps(previous: [],
                                     current: ["\(trash)/notes.txt", "\(trash)/Folder", "\(trash)/Archive.app.zip",
                                               "\(trash)/Tool.APP"],
                                     ignoring: [])
        #expect(new == ["\(trash)/Tool.APP"])
    }

    @Test func sameAppNotReportedTwice() {
        let first = TrashWatch.newApps(previous: [], current: ["\(trash)/SoundWave.app"], ignoring: [])
        #expect(first == ["\(trash)/SoundWave.app"])
        let again = TrashWatch.newApps(previous: Set(first), current: ["\(trash)/SoundWave.app"], ignoring: [])
        #expect(again.isEmpty)
        let duplicated = TrashWatch.newApps(previous: [], current: ["\(trash)/A.app", "\(trash)/A.app"], ignoring: [])
        #expect(duplicated == ["\(trash)/A.app"])
    }

    @Test func ownBundleIgnored() {
        let new = TrashWatch.newApps(previous: [], current: ["\(trash)/Leftless.app", "\(trash)/SoundWave.app"],
                                     ignoring: ["\(trash)/Leftless.app"])
        #expect(new == ["\(trash)/SoundWave.app"])
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

    static func waitUntil(timeout: Double = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func reportsAppsAddedAfterStartOnce() async throws {
        let fs = try FakeSystem(); defer { fs.cleanup() }
        let dir = fs.home.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Old.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Mine.app"), withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("Mine.app"))
        let collector = Collector()
        let monitor = TrashMonitor(directory: dir, debounce: 0.2,
                                   ignoring: [dir.appendingPathComponent("Mine.app").path]) { collector.add($0) }
        #expect(monitor.start())
        defer { monitor.stop() }

        // A burst of changes is reported once, after the debounce.
        try Data().write(to: dir.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("SoundWave.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Mine.app"), withIntermediateDirectories: true)
        await Self.waitUntil { !collector.batches.isEmpty }
        #expect(collector.batches == [[dir.appendingPathComponent("SoundWave.app").path]])

        // Removing and adding it back doesn't report it again; a different app is reported.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("SoundWave.app"))
        try await Task.sleep(for: .milliseconds(400))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("SoundWave.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Clip.app"), withIntermediateDirectories: true)
        await Self.waitUntil { collector.batches.count >= 2 }
        try await Task.sleep(for: .milliseconds(400))
        #expect(collector.batches == [[dir.appendingPathComponent("SoundWave.app").path],
                                      [dir.appendingPathComponent("Clip.app").path]])
    }

    @Test func stoppedMonitorReportsNothing() async throws {
        let fs = try FakeSystem(); defer { fs.cleanup() }
        let dir = fs.home.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let collector = Collector()
        let monitor = TrashMonitor(directory: dir, debounce: 0.1, ignoring: []) { collector.add($0) }
        #expect(monitor.start())
        monitor.stop()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("SoundWave.app"), withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(500))
        #expect(collector.batches.isEmpty)
    }

    @Test func missingDirectoryFailsToStart() throws {
        let fs = try FakeSystem(); defer { fs.cleanup() }
        let monitor = TrashMonitor(directory: fs.root.appendingPathComponent("nope"), debounce: 0.1, ignoring: []) { _ in }
        #expect(!monitor.start())
    }
}
