import Testing
import Foundation
@testable import LeftlessCore

private final class RFiles: FileMoving, @unchecked Sendable {
    private let lock = NSLock()
    var existing = Set<String>()
    var created: [String] = []
    var moves: [(String, String)] = []
    var trashCalls: [String] = []
    var failingMoves = Set<String>()

    func trash(_ url: URL) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        trashCalls.append(url.path)
        existing.remove(url.path)
        let dest = uniqueTrashURL(for: url, trashDirectory: URL(fileURLWithPath: "/Users/t/.Trash")) { existing.contains($0.path) }
        existing.insert(dest.path)
        return dest
    }
    func move(_ from: URL, to: URL) throws {
        lock.lock(); defer { lock.unlock() }
        if failingMoves.contains(from.path) { throw CocoaError(.fileWriteNoPermission) }
        moves.append((from.path, to.path))
        existing.remove(from.path)
        existing.insert(to.path)
    }
    func exists(_ url: URL) -> Bool { lock.lock(); defer { lock.unlock() }; return existing.contains(url.path) }
    func createDirectory(_ url: URL) throws { lock.lock(); defer { lock.unlock() }; created.append(url.path) }
}

private final class RPrivileged: PrivilegedExecuting, @unchecked Sendable {
    var calls: [[String]] = []
    var action: ([String]) throws -> Void = { _ in }
    func run(_ commands: [String]) throws { calls.append(commands); try action(commands) }
}

private final class RCommands: CommandRunning, @unchecked Sendable {
    var calls: [[String]] = []
    func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput {
        calls.append([executable] + arguments)
        return CommandOutput(status: 5, stdout: "", stderr: "")
    }
}

private struct RRig {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString)")
    let store: HistoryStore
    let files = RFiles()
    let priv = RPrivileged()
    let cmds = RCommands()

    init() { store = HistoryStore(directory: tmp.appendingPathComponent("h")) }

    func restorer() -> Restorer {
        Restorer(history: store, files: files, privileged: priv, commands: cmds,
                 environment: ScanEnvironment(root: URL(fileURLWithPath: "/"), home: URL(fileURLWithPath: "/Users/t"), uid: 501))
    }

    /// Çöpte duran bir öğe (trashed) üretir; çöp dosyası var kabul edilir.
    func item(_ original: String, trash: String, kind: LeftoverKind = .caches, admin: Bool = false,
              domain: String? = nil, state: ItemState = .trashed, trashExists: Bool = true) -> HistoryItem {
        if trashExists { files.existing.insert(trash) }
        return HistoryItem(originalPath: original, trashPath: trash, kind: kind, size: 5, requiresAdmin: admin,
                           launchdDomain: domain, state: state)
    }

    func record(_ items: [HistoryItem]) -> HistoryRecord {
        HistoryRecord(appName: "X", bundleID: "com.x", items: items)
    }
}

@Suite struct RestorerTests {
    @Test func restoresToOriginalPathsCreatingParents() throws {
        let rig = RRig()
        defer { try? FileManager.default.removeItem(at: rig.tmp) }
        let rec = rig.record([rig.item("/Users/t/Library/Caches/com.x/data", trash: "/Users/t/.Trash/data")])
        let out = rig.restorer().restore(rec) { _ in .skip }
        #expect(rig.files.created == ["/Users/t/Library/Caches/com.x"])
        #expect(rig.files.moves.count == 1)
        #expect(rig.files.moves[0].0 == "/Users/t/.Trash/data")
        #expect(rig.files.moves[0].1 == "/Users/t/Library/Caches/com.x/data")
        #expect(out.restored == 1)
        #expect(out.skipped == 0)
        #expect(out.failures.isEmpty)
        #expect(out.record.items[0].state == .restored)
        #expect(try rig.store.all().first?.items[0].state == .restored)
    }

    @Test func skipsConflictWhenAsked() {
        let rig = RRig()
        defer { try? FileManager.default.removeItem(at: rig.tmp) }
        let it = rig.item("/Users/t/a", trash: "/Users/t/.Trash/a")
        rig.files.existing.insert("/Users/t/a")
        nonisolated(unsafe) var asked: [String] = []
        let out = rig.restorer().restore(rig.record([it])) { asked.append($0.originalPath); return .skip }
        #expect(asked == ["/Users/t/a"])
        #expect(out.skipped == 1)
        #expect(out.restored == 0)
        #expect(out.record.items[0].state == .trashed)
        #expect(rig.files.moves.isEmpty)
        #expect(rig.files.trashCalls.isEmpty)
    }

    @Test func replacesConflictByTrashingExisting() {
        let rig = RRig()
        defer { try? FileManager.default.removeItem(at: rig.tmp) }
        let it = rig.item("/Users/t/a", trash: "/Users/t/.Trash/a")
        rig.files.existing.insert("/Users/t/a")
        let out = rig.restorer().restore(rig.record([it])) { _ in .replace }
        #expect(rig.files.trashCalls == ["/Users/t/a"])
        #expect(rig.files.moves.count == 1)
        #expect(rig.files.moves[0].1 == "/Users/t/a")
        #expect(out.restored == 1)
        #expect(out.record.items[0].state == .restored)
    }

    @Test func bootstrapsLaunchAgentsAfterRestore() {
        let rig = RRig()
        defer { try? FileManager.default.removeItem(at: rig.tmp) }
        let a = rig.item("/Users/t/Library/LaunchAgents/com.x.plist", trash: "/Users/t/.Trash/com.x.plist",
                         kind: .launchAgent, domain: "gui/501")
        let out = rig.restorer().restore(rig.record([a])) { _ in .skip }
        #expect(rig.cmds.calls == [["/bin/launchctl", "bootstrap", "gui/501", "/Users/t/Library/LaunchAgents/com.x.plist"]])
        #expect(out.restored == 1)
    }

    @Test func doesNotBootstrapWhenMoveFails() {
        let rig = RRig()
        defer { try? FileManager.default.removeItem(at: rig.tmp) }
        let a = rig.item("/Users/t/Library/LaunchAgents/com.x.plist", trash: "/Users/t/.Trash/com.x.plist",
                         kind: .launchAgent, domain: "gui/501")
        rig.files.failingMoves.insert("/Users/t/.Trash/com.x.plist")
        let out = rig.restorer().restore(rig.record([a])) { _ in .skip }
        #expect(rig.cmds.calls.isEmpty)
        #expect(out.failures.count == 1)
        #expect(out.failures[0].error != nil)
        #expect(out.record.items[0].state == .trashed)
    }

    @Test func adminRestoreUsesSinglePrivilegedRun() {
        let rig = RRig()
        defer { try? FileManager.default.removeItem(at: rig.tmp) }
        let a = rig.item("/Library/App Support/it's", trash: "/Users/t/.Trash/it's", admin: true)
        let d = rig.item("/Library/LaunchDaemons/com.x.plist", trash: "/Users/t/.Trash/com.x.plist",
                         kind: .launchDaemon, admin: true, domain: "system")
        rig.priv.action = { _ in
            for (from, to) in [("/Users/t/.Trash/it's", "/Library/App Support/it's"),
                               ("/Users/t/.Trash/com.x.plist", "/Library/LaunchDaemons/com.x.plist")] {
                rig.files.existing.remove(from); rig.files.existing.insert(to)
            }
        }
        let out = rig.restorer().restore(rig.record([a, d])) { _ in .skip }
        #expect(rig.priv.calls.count == 1)
        let c = rig.priv.calls[0]
        #expect(c[0] == "/bin/mkdir -p '/Library/App Support' && [ ! -e '/Library/App Support/it'\\''s' ] && /bin/mv -n '/Users/t/.Trash/it'\\''s' '/Library/App Support/it'\\''s'")
        #expect(c[1] == "/bin/mkdir -p '/Library/LaunchDaemons' && [ ! -e '/Library/LaunchDaemons/com.x.plist' ] && /bin/mv -n '/Users/t/.Trash/com.x.plist' '/Library/LaunchDaemons/com.x.plist'")
        #expect(c[2] == "( /bin/launchctl bootstrap system '/Library/LaunchDaemons/com.x.plist' || true )")
        #expect(c.count == 3)
        #expect(rig.files.moves.isEmpty)
        #expect(rig.cmds.calls.isEmpty)
        #expect(out.restored == 2)
        #expect(out.record.items.allSatisfy { $0.state == .restored })
    }

    @Test func adminReplaceTrashesExistingFirstInSameRun() {
        let rig = RRig()
        defer { try? FileManager.default.removeItem(at: rig.tmp) }
        let a = rig.item("/Library/a", trash: "/Users/t/.Trash/a", admin: true)
        rig.files.existing.insert("/Library/a")
        rig.files.existing.insert("/Users/t/.Trash/a") // hedef adı çakışır
        rig.priv.action = { _ in
            rig.files.existing.insert("/Users/t/.Trash/a 2")
            rig.files.existing.remove("/Library/a")
            rig.files.existing.remove("/Users/t/.Trash/a")
            rig.files.existing.insert("/Library/a")
        }
        let out = rig.restorer().restore(rig.record([a])) { _ in .replace }
        #expect(rig.priv.calls.count == 1)
        let c = rig.priv.calls[0]
        #expect(c[0] == "[ -e '/Library/a' ] && /bin/mv -n '/Library/a' '/Users/t/.Trash/a 2'")
        #expect(c[1].contains("/bin/mv -n '/Users/t/.Trash/a' '/Library/a'"))
        #expect(rig.files.trashCalls.isEmpty)
        #expect(out.failures.isEmpty)
        #expect(out.record.items[0].state == .restored)
    }

    @Test func adminCancelledAndPartialDerivedFromFilesystem() {
        let rig = RRig()
        defer { try? FileManager.default.removeItem(at: rig.tmp) }
        let a = rig.item("/Library/a", trash: "/Users/t/.Trash/a", admin: true)
        let b = rig.item("/Library/b", trash: "/Users/t/.Trash/b", admin: true)
        rig.priv.action = { _ in
            rig.files.existing.remove("/Users/t/.Trash/a"); rig.files.existing.insert("/Library/a")
            throw PrivilegedError.cancelled
        }
        let out = rig.restorer().restore(rig.record([a, b])) { _ in .skip }
        #expect(out.record.items[0].state == .restored)
        #expect(out.record.items[1].state == .trashed)
        #expect(out.failures.count == 1)
        #expect(out.failures[0].error == "Yönetici izni verilmedi")
        #expect(out.restored == 1)
    }

    @Test func adminFailureReportsStderr() {
        let rig = RRig()
        defer { try? FileManager.default.removeItem(at: rig.tmp) }
        let a = rig.item("/Library/a", trash: "/Users/t/.Trash/a", admin: true)
        rig.priv.action = { _ in throw PrivilegedError.failed("mv: boom") }
        let out = rig.restorer().restore(rig.record([a])) { _ in .skip }
        #expect(out.failures[0].error == "mv: boom")
    }

    @Test func missingTrashItemsAreReportedNotThrown() {
        let rig = RRig()
        defer { try? FileManager.default.removeItem(at: rig.tmp) }
        let missing = rig.item("/Users/t/a", trash: "/Users/t/.Trash/a", trashExists: false)
        let adminMissing = rig.item("/Library/b", trash: "/Users/t/.Trash/b", admin: true, trashExists: false)
        let failed = rig.item("/Users/t/c", trash: "/Users/t/.Trash/c", admin: true, state: .failed)
        let pending = rig.item("/Users/t/d", trash: "/Users/t/.Trash/d", state: .pending)
        let done = rig.item("/Users/t/e", trash: "/Users/t/.Trash/e", state: .restored)
        let out = rig.restorer().restore(rig.record([missing, adminMissing, failed, pending, done])) { _ in .replace }
        #expect(out.restored == 0)
        #expect(out.skipped == 0)
        #expect(rig.files.moves.isEmpty)
        #expect(rig.priv.calls.isEmpty)
        #expect(rig.cmds.calls.isEmpty)
        #expect(out.record.items.map(\.state) == [.trashed, .trashed, .failed, .pending, .restored])
        #expect(out.failures.count == 2)
        #expect(out.failures.allSatisfy { $0.error != nil })
    }

    @Test func joinedAdminBatchStopsAtFailureAndSkipsBootstrap() throws {
        let rig = RRig()
        let dir = rig.tmp.appendingPathComponent("sh")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rig.tmp) }
        let bad = rig.item(dir.appendingPathComponent("out/a").path, trash: dir.appendingPathComponent("missing-src").path, admin: true)
        let agent = rig.item(dir.appendingPathComponent("out/b.plist").path, trash: dir.appendingPathComponent("missing-src2").path,
                             kind: .launchDaemon, admin: true, domain: "system")
        rig.priv.action = { _ in throw PrivilegedError.failed("x") }
        _ = rig.restorer().restore(rig.record([bad, agent])) { _ in .skip }
        let shell = rig.priv.calls[0].joined(separator: " && ")
            .replacingOccurrences(of: "/bin/launchctl", with: "/bin/echo")
        #expect(shell.contains("( /bin/echo bootstrap"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", shell]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(p.terminationStatus != 0)
        #expect(!text.contains("bootstrap"))
    }
}
