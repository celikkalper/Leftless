import Testing
import Foundation
@testable import KalintisizCore

private final class FakeFiles: FileMoving, @unchecked Sendable {
    private let lock = NSLock()
    var existing = Set<String>()
    var trashCalls: [String] = []
    var failing = Set<String>()
    var permissionDenied = Set<String>()
    var onFirstTrash: (() -> Void)?
    private var didFire = false
    let trashRoot = "/trash"

    func trash(_ url: URL) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        if !didFire { didFire = true; onFirstTrash?() }
        trashCalls.append(url.path)
        if failing.contains(url.path) { throw CocoaError(.fileWriteUnknown) }
        if permissionDenied.contains(url.path) {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(.EACCES)])
        }
        existing.remove(url.path)
        let dest = uniqueTrashURL(for: url, trashDirectory: URL(fileURLWithPath: trashRoot)) { existing.contains($0.path) }
        existing.insert(dest.path)
        return dest
    }
    func move(_ from: URL, to: URL) throws {}
    func exists(_ url: URL) -> Bool { lock.lock(); defer { lock.unlock() }; return existing.contains(url.path) }
    func createDirectory(_ url: URL) throws {}
}

private final class FakePrivileged: PrivilegedExecuting, @unchecked Sendable {
    var calls: [[String]] = []
    var action: ([String]) throws -> Void = { _ in }
    func run(_ commands: [String]) throws { calls.append(commands); try action(commands) }
}

private final class FakeCommands: CommandRunning, @unchecked Sendable {
    var calls: [[String]] = []
    func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput {
        calls.append([executable] + arguments)
        return CommandOutput(status: 3, stdout: "", stderr: "not loaded")
    }
}

private struct Rig {
    let tmp: URL
    let store: HistoryStore
    let files = FakeFiles()
    let priv = FakePrivileged()
    let cmds = FakeCommands()
    let trashDir = URL(fileURLWithPath: "/trash", isDirectory: true)

    init(storeDirectory: URL? = nil) {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("uninst-\(UUID().uuidString)")
        store = HistoryStore(directory: storeDirectory ?? tmp.appendingPathComponent("h"))
    }

    func uninstaller() -> Uninstaller {
        Uninstaller(history: store, files: files, privileged: priv, commands: cmds,
                    environment: ScanEnvironment(root: URL(fileURLWithPath: "/"), home: URL(fileURLWithPath: "/Users/t"), uid: 501),
                    trashDirectory: trashDir)
    }

    func leftover(_ path: String, kind: LeftoverKind = .caches, admin: Bool = false,
                  label: String? = nil, pkg: String? = nil) -> Leftover {
        files.existing.insert(path)
        return Leftover(url: URL(fileURLWithPath: path), kind: kind, confidence: .certain, size: 5,
                        requiresAdmin: admin, launchdLabel: label, packageID: pkg)
    }

    func scan(_ l: [Leftover]) -> ScanResult {
        ScanResult(app: AppInfo(url: URL(fileURLWithPath: "/Applications/X.app"), bundleID: "com.x", name: "X", version: "2"),
                   leftovers: l)
    }
}

@Suite struct UninstallerTests {
    @Test func writesManifestBeforeMovingAnything() throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.tmp) }
        let a = rig.leftover("/u/a"), b = rig.leftover("/u/b")
        nonisolated(unsafe) var seen: [HistoryRecord] = []
        rig.files.onFirstTrash = { seen = (try? rig.store.all()) ?? [] }
        _ = try rig.uninstaller().uninstall(rig.scan([a, b]), selected: [a, b], icon: nil)
        #expect(seen.count == 1)
        #expect(seen[0].items.count == 2)
        #expect(seen[0].items.allSatisfy { $0.state == .pending })
    }

    @Test func doesNotMoveWhenManifestCannotBeSaved() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("uninst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let blocker = tmp.appendingPathComponent("file")
        try Data().write(to: blocker)
        let rig = Rig(storeDirectory: blocker.appendingPathComponent("sub"))
        let a = rig.leftover("/u/a")
        #expect(throws: (any Error).self) {
            try rig.uninstaller().uninstall(rig.scan([a]), selected: [a], icon: nil)
        }
        #expect(rig.files.trashCalls.isEmpty)
        #expect(rig.priv.calls.isEmpty)
        #expect(rig.cmds.calls.isEmpty)
    }

    @Test func adminItemsBatchedIntoSinglePrivilegedRun() throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.tmp) }
        let a = rig.leftover("/Library/App Support/it's", admin: true)
        let b = rig.leftover("/Library/Other/it's", admin: true)
        rig.priv.action = { _ in
            rig.files.existing.remove(a.url.path); rig.files.existing.remove(b.url.path)
            rig.files.existing.insert("/trash/it's"); rig.files.existing.insert("/trash/it's 2")
        }
        let out = try rig.uninstaller().uninstall(rig.scan([a, b]), selected: [a, b], icon: nil)
        #expect(rig.priv.calls.count == 1)
        let cmds = rig.priv.calls[0]
        #expect(cmds.contains("[ ! -e '/trash/it'\\''s' ] && /bin/mv -n '/Library/App Support/it'\\''s' '/trash/it'\\''s'"))
        #expect(cmds.contains("[ ! -e '/trash/it'\\''s 2' ] && /bin/mv -n '/Library/Other/it'\\''s' '/trash/it'\\''s 2'"))
        #expect(rig.files.trashCalls.isEmpty)
        #expect(out.record.items.allSatisfy { $0.state == .trashed })
        #expect(out.failures.isEmpty)
    }

    @Test func launchAgentBootedOutBeforeTrash() throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.tmp) }
        let agent = rig.leftover("/Users/t/Library/LaunchAgents/com.x.plist", kind: .launchAgent, label: "com.x")
        let out = try rig.uninstaller().uninstall(rig.scan([agent]), selected: [agent], icon: nil)
        #expect(rig.cmds.calls == [["/bin/launchctl", "bootout", "gui/501", agent.url.path]])
        #expect(out.record.items[0].launchdDomain == "gui/501")
        #expect(out.record.items[0].launchdLabel == "com.x")
        #expect(out.record.items[0].state == .trashed)
    }

    @Test func adminLaunchDaemonBootoutPrecedesMoves() throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.tmp) }
        let d = rig.leftover("/Library/LaunchDaemons/com.x.plist", kind: .launchDaemon, admin: true, label: "com.x")
        _ = try rig.uninstaller().uninstall(rig.scan([d]), selected: [d], icon: nil)
        let cmds = rig.priv.calls[0]
        #expect(cmds[0].hasPrefix("/bin/launchctl bootout system '/Library/LaunchDaemons/com.x.plist'"))
        #expect(cmds[1].contains("/bin/mv -n"))
        #expect(rig.cmds.calls.isEmpty)
    }

    @Test func partialFailureIsRecorded() throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.tmp) }
        let a = rig.leftover("/u/a"), b = rig.leftover("/u/b")
        rig.files.failing.insert(a.url.path)
        let out = try rig.uninstaller().uninstall(rig.scan([a, b]), selected: [a, b], icon: Data([1, 2]))
        #expect(out.record.items[0].state == .failed)
        #expect(out.record.items[0].error != nil)
        #expect(out.record.items[1].state == .trashed)
        #expect(out.record.items[1].trashPath == "/trash/b")
        #expect(out.failures.count == 1)
        #expect(out.record.icon == Data([1, 2]))
        let saved = try rig.store.all()
        #expect(saved[0].items.map(\.state) == [.failed, .trashed])
    }

    @Test func cancelledAdminMarksItemsFailed() throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.tmp) }
        let a = rig.leftover("/Library/a", admin: true)
        rig.priv.action = { _ in throw PrivilegedError.cancelled }
        let out = try rig.uninstaller().uninstall(rig.scan([a]), selected: [a], icon: nil)
        #expect(out.record.items[0].state == .failed)
        #expect(out.record.items[0].error == "Yönetici izni verilmedi")
        #expect(out.failures.count == 1)
    }

    @Test func partiallyAppliedAdminBatchIsDeterminedFromFilesystem() throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.tmp) }
        let a = rig.leftover("/Library/a", admin: true)
        let b = rig.leftover("/Library/b", admin: true)
        rig.priv.action = { _ in
            rig.files.existing.remove("/Library/a")
            rig.files.existing.insert("/trash/a")
            throw PrivilegedError.failed("mv: boom")
        }
        let out = try rig.uninstaller().uninstall(rig.scan([a, b]), selected: [a, b], icon: nil)
        #expect(out.record.items[0].state == .trashed)
        #expect(out.record.items[1].state == .failed)
        #expect(out.record.items[1].error == "mv: boom")
        #expect(out.failures.count == 1)
    }

    @Test func forgetsReceiptOnlyWhenAllItsLeftoversSelected() throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.tmp) }
        let a = rig.leftover("/Library/a", kind: .packageFile, admin: true, pkg: "com.full")
        let b = rig.leftover("/Library/b", kind: .packageFile, admin: true, pkg: "com.part")
        let c = rig.leftover("/Library/c", kind: .packageFile, admin: true, pkg: "com.part")
        _ = try rig.uninstaller().uninstall(rig.scan([a, b, c]), selected: [a, b], icon: nil)
        let cmds = rig.priv.calls[0]
        #expect(cmds.contains("/usr/sbin/pkgutil --forget 'com.full'"))
        #expect(!cmds.contains { $0.contains("com.part") && $0.contains("pkgutil") })
    }

    @Test func adminLaunchAgentUsesGuiDomain() throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.tmp) }
        let a = rig.leftover("/Library/LaunchAgents/com.x.plist", kind: .launchAgent, admin: true, label: "com.x")
        let out = try rig.uninstaller().uninstall(rig.scan([a]), selected: [a], icon: nil)
        #expect(rig.priv.calls[0][0].hasPrefix("/bin/launchctl bootout gui/501 '/Library/LaunchAgents/com.x.plist'"))
        #expect(out.record.items[0].launchdDomain == "gui/501")
    }

    @Test func sharedBasenameBetweenAdminAndNonAdminDoesNotCollide() throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.tmp) }
        let user = rig.leftover("/Users/t/Library/Preferences/com.x.plist", kind: .preferences)
        let admin = rig.leftover("/Library/Preferences/com.x.plist", kind: .preferences, admin: true)
        nonisolated(unsafe) var manifestAdminTarget: String?
        rig.priv.action = { cmds in
            manifestAdminTarget = (try? rig.store.all())?.first?.items.first { $0.requiresAdmin }?.trashPath
            rig.files.existing.remove(admin.url.path)
            for c in cmds where c.contains("/bin/mv") {
                let dst = c.components(separatedBy: "' '").last!.dropLast()
                rig.files.existing.insert(String(dst))
            }
        }
        let out = try rig.uninstaller().uninstall(rig.scan([user, admin]), selected: [user, admin], icon: nil)
        let items = out.record.items
        #expect(items.allSatisfy { $0.state == .trashed })
        #expect(items[0].trashPath != items[1].trashPath)
        #expect(items[1].trashPath == "/trash/com.x 2.plist")
        #expect(manifestAdminTarget == items[1].trashPath)
        #expect(rig.priv.calls[0].contains { $0.contains("'/trash/com.x 2.plist'") })
    }

    @Test func doesNotForgetReceiptWhenNonAdminItemOfPackageFailed() throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.tmp) }
        let user = rig.leftover("/Users/t/a", kind: .packageFile, pkg: "com.pkg")
        let admin = rig.leftover("/Library/b", kind: .packageFile, admin: true, pkg: "com.pkg")
        rig.files.failing.insert(user.url.path)
        _ = try rig.uninstaller().uninstall(rig.scan([user, admin]), selected: [user, admin], icon: nil)
        #expect(!rig.priv.calls[0].contains { $0.contains("pkgutil") })
    }

    @Test func permissionDeniedTrashFallsBackToPrivilegedMove() throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.tmp) }
        let bundle = rig.leftover("/Applications/X.app", kind: .appBundle)
        let prefs = rig.leftover("/Users/t/Library/Preferences/com.x.plist", kind: .preferences)
        rig.files.permissionDenied.insert(bundle.url.path)
        nonisolated(unsafe) var manifestTarget: String?
        rig.priv.action = { cmds in
            manifestTarget = (try? rig.store.all())?.first?.items.first?.trashPath
            #expect(cmds.contains("[ ! -e '/trash/X.app' ] && /bin/mv -n '/Applications/X.app' '/trash/X.app'"))
            rig.files.existing.remove(bundle.url.path)
            rig.files.existing.insert("/trash/X.app")
        }
        let out = try rig.uninstaller().uninstall(rig.scan([bundle, prefs]), selected: [bundle, prefs], icon: nil)
        #expect(rig.priv.calls.count == 1)
        #expect(out.record.items[0].state == .trashed)
        #expect(out.record.items[0].requiresAdmin)
        #expect(out.record.items[0].trashPath == "/trash/X.app")
        #expect(manifestTarget == "/trash/X.app")
        #expect(out.record.items[1].state == .trashed)
        #expect(out.failures.isEmpty)
    }

    @Test func nonPermissionTrashErrorDoesNotEscalate() throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.tmp) }
        let a = rig.leftover("/u/a")
        rig.files.failing.insert(a.url.path)
        let out = try rig.uninstaller().uninstall(rig.scan([a]), selected: [a], icon: nil)
        #expect(rig.priv.calls.isEmpty)
        #expect(out.record.items[0].state == .failed)
        #expect(!out.record.items[0].requiresAdmin)
    }

    @Test func skipsPrivilegedBatchWhenRetargetedManifestCannotBeSaved() throws {
        let rig = Rig()
        let dir = rig.tmp.appendingPathComponent("h")
        let fm = FileManager.default
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? fm.removeItem(at: rig.tmp)
        }
        let user = rig.leftover("/u/a")
        let admin = rig.leftover("/Library/b", admin: true)
        // İlk manifest yazıldıktan sonra kayıt klasörü salt okunur olur: ikinci kayıt başarısız.
        rig.files.onFirstTrash = { try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path) }
        let out = try rig.uninstaller().uninstall(rig.scan([user, admin]), selected: [user, admin], icon: nil)
        #expect(rig.priv.calls.isEmpty)
        #expect(out.record.items[0].state == .trashed)
        #expect(out.record.items[1].state == .failed)
        #expect(out.record.items[1].error == "Kayıt güncellenemedi")
        #expect(out.failures.count == 1)
    }
}
