import Foundation
import Testing
@testable import KalintisizCore

/// Canlı ortamda uçtan uca duman testi. Yalnızca `KALINTISIZ_E2E=1` ile çalışır.
/// Kendi oluşturduğu sahte uygulamayı kullanır; gerçek kullanıcı uygulamalarına dokunmaz.
@Suite struct EndToEndTests {
    private struct FailingPrivileged: PrivilegedExecuting {
        func run(_ commands: [String]) throws {
            Issue.record("Yetkili yürütücü çağrılmamalıydı: \(commands)")
            throw PrivilegedError.failed("beklenmeyen çağrı")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["KALINTISIZ_E2E"] == "1"))
    func fakeAppLifecycle() throws {
        let fm = FileManager.default
        let env = ScanEnvironment.live()
        let home = env.home
        let bundleID = "com.kalintisiz.e2etest"

        let appURL = home.appendingPathComponent("Applications/KalintisizTest.app", isDirectory: true)
        let cacheURL = home.appendingPathComponent("Library/Caches/\(bundleID)", isDirectory: true)
        let prefsURL = home.appendingPathComponent("Library/Preferences/\(bundleID).plist")
        let agentURL = home.appendingPathComponent("Library/LaunchAgents/\(bundleID).plist")
        let fixtures = [appURL, cacheURL, prefsURL, agentURL]

        // Var olan bir şeyin üzerine yazmamak için çalışmayı reddet.
        for url in fixtures {
            #expect(!fm.fileExists(atPath: url.path), "Zaten var, test çalışmayı reddediyor: \(url.path)")
            if fm.fileExists(atPath: url.path) { return }
        }

        let tempDir = fm.temporaryDirectory.appendingPathComponent("kalintisiz-e2e-\(UUID().uuidString)", isDirectory: true)
        let uid = getuid()
        defer {
            _ = try? ProcessCommandRunner().run("/bin/launchctl", ["bootout", "gui/\(uid)/\(bundleID)"])
            for url in fixtures { try? fm.removeItem(at: url) }
            try? fm.removeItem(at: tempDir)
        }

        // Sahte uygulama ve artıkları oluştur.
        let exeURL = appURL.appendingPathComponent("Contents/MacOS/KalintisizTest")
        try fm.createDirectory(at: exeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let infoPlist: [String: Any] = [
            "CFBundleIdentifier": bundleID, "CFBundleName": "KalintisizTest",
            "CFBundleExecutable": "KalintisizTest", "CFBundleShortVersionString": "1.0",
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
            .write(to: appURL.appendingPathComponent("Contents/Info.plist"))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: exeURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exeURL.path)

        try fm.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: cacheURL.appendingPathComponent("data.bin"))
        try fm.createDirectory(at: prefsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["k": "v"], format: .xml, options: 0).write(to: prefsURL)
        try fm.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let agent: [String: Any] = ["Label": bundleID, "ProgramArguments": [exeURL.path]]
        try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0).write(to: agentURL)

        // 1) İncele + tara
        let commands = ProcessCommandRunner()
        let info = try AppInspector(commands: commands).inspect(appURL, includeTeamID: false)
        #expect(info.bundleID == bundleID)
        let scanner = LeftoverScanner(environment: env, installedApps: [info],
                                      launchd: LaunchdScanner(environment: env), commands: commands)
        let scan = scanner.scan(info)

        func key(_ u: URL) -> String { u.standardizedFileURL.resolvingSymlinksInPath().path }
        let wanted = Set(fixtures.map(key))
        let found = scan.leftovers.filter { wanted.contains(key($0.url)) }
        #expect(found.count == 4, "Bulunan: \(scan.leftovers.map(\.url.path))")
        #expect(Set(found.map { key($0.url) }) == wanted)
        #expect(found.allSatisfy { $0.confidence == .certain })
        guard found.count == 4 else { return }

        // 2) Kaldır
        let store = HistoryStore(directory: tempDir)
        let trashDir = home.appendingPathComponent(".Trash", isDirectory: true)
        let uninstaller = Uninstaller(history: store, files: SystemFileMover(), privileged: FailingPrivileged(),
                                      commands: commands, environment: env, trashDirectory: trashDir)
        let outcome = try uninstaller.uninstall(scan, selected: found, icon: nil)
        #expect(outcome.failures.isEmpty)
        #expect(outcome.record.items.count == 4)
        for item in outcome.record.items {
            #expect(item.state == .trashed)
            #expect(!fm.fileExists(atPath: item.originalPath), "Orijinal hâlâ var: \(item.originalPath)")
            if let t = item.trashPath { #expect(fm.fileExists(atPath: t), "Çöpte yok: \(t)") }
            else { Issue.record("trashPath yok: \(item.originalPath)") }
        }
        #expect(try store.all().contains { $0.id == outcome.record.id })

        // 3) Geri yükle
        let restorer = Restorer(history: store, files: SystemFileMover(), privileged: FailingPrivileged(),
                                commands: commands, environment: env)
        let restored = restorer.restore(outcome.record) { _ in .skip }
        #expect(restored.restored == 4)
        #expect(restored.failures.isEmpty)
        for url in fixtures { #expect(fm.fileExists(atPath: url.path), "Geri gelmedi: \(url.path)") }
    }
}
