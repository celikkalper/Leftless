import Foundation

public struct UninstallOutcome: Sendable {
    public var record: HistoryRecord
    public var failures: [HistoryItem]

    public init(record: HistoryRecord, failures: [HistoryItem]) {
        self.record = record
        self.failures = failures
    }
}

public struct Uninstaller: Sendable {
    private let history: HistoryStore
    private let files: FileMoving
    private let privileged: PrivilegedExecuting
    private let commands: CommandRunning
    private let environment: ScanEnvironment
    private let trashDirectory: URL

    /// `trashDirectory` canlıda `home/.Trash`.
    public init(history: HistoryStore, files: FileMoving, privileged: PrivilegedExecuting,
                commands: CommandRunning, environment: ScanEnvironment, trashDirectory: URL) {
        self.history = history
        self.files = files
        self.privileged = privileged
        self.commands = commands
        self.environment = environment
        self.trashDirectory = trashDirectory
    }

    /// Önce manifest (pending) yazılır; yazılamazsa hiçbir şey taşınmadan fırlatır.
    /// Öğe bazlı hatalar fırlatılmaz, kayıtta `failed` olarak tutulur.
    public func uninstall(_ result: ScanResult, selected: [Leftover], icon: Data?) throws -> UninstallOutcome {
        var chosenTargets = Set<String>()
        var items: [HistoryItem] = selected.map { leftover in
            var item = HistoryItem(originalPath: leftover.url.path, kind: leftover.kind, size: leftover.size,
                                   requiresAdmin: leftover.requiresAdmin, launchdLabel: leftover.launchdLabel,
                                   packageID: leftover.packageID)
            if Self.isLaunchd(leftover.kind) {
                item.launchdDomain = leftover.kind == .launchDaemon ? "system" : "gui/\(environment.uid)"
            }
            if leftover.requiresAdmin {
                let target = uniqueTrashURL(for: leftover.url, trashDirectory: trashDirectory) {
                    files.exists($0) || chosenTargets.contains($0.path)
                }
                chosenTargets.insert(target.path)
                item.trashPath = target.path
            }
            return item
        }
        var record = HistoryRecord(appName: result.app.name, bundleID: result.app.bundleID,
                                   version: result.app.version, icon: icon, items: items)
        try history.save(record)

        var adminCommands: [String] = []
        for index in items.indices where items[index].launchdDomain != nil {
            let item = items[index]
            if item.requiresAdmin {
                adminCommands.append("/bin/launchctl bootout \(item.launchdDomain ?? "system") \(ShellQuoting.quote(item.originalPath)) || true")
            } else if let domain = item.launchdDomain {
                // Zaten yüklü olmayabilir: hata ve sıfırdan farklı çıkış yok sayılır.
                _ = try? commands.run("/bin/launchctl", ["bootout", domain, item.originalPath])
            }
        }

        for index in items.indices where !items[index].requiresAdmin {
            do {
                let trashed = try files.trash(URL(fileURLWithPath: items[index].originalPath))
                items[index].state = .trashed
                items[index].trashPath = trashed.path
            } catch where Self.isPermissionError(error) {
                // Ör. root:wheel 755 paket: yönetici taşımasına aktarılır (hedef aşağıda seçilip kaydedilir).
                items[index].requiresAdmin = true
            } catch {
                items[index].state = .failed
                items[index].failure = .other(error.localizedDescription)
            }
        }

        let adminIndices = items.indices.filter { items[$0].requiresAdmin }
        // trashItem kendi boş adını seçer; bir yönetici hedefiyle çakışmış olabilir. Hedefler yeniden seçilir.
        var retargeted = Set<String>()
        for index in adminIndices {
            let original = URL(fileURLWithPath: items[index].originalPath)
            let target = uniqueTrashURL(for: original, trashDirectory: trashDirectory) {
                files.exists($0) || retargeted.contains($0.path)
            }
            retargeted.insert(target.path)
            items[index].trashPath = target.path
        }
        var manifestSaved = true
        if !adminIndices.isEmpty {
            record.items = items
            do {
                try history.save(record)
            } catch {
                // Root, diskteki manifestte olmayan hedeflere taşıma yapmamalı: yönetici adımı atlanır.
                manifestSaved = false
                for index in adminIndices {
                    items[index].state = .failed
                    items[index].failure = .manifestUpdateFailed
                }
            }
        }
        for index in adminIndices where manifestSaved {
            guard let target = items[index].trashPath else { continue }
            let src = ShellQuoting.quote(items[index].originalPath), dst = ShellQuoting.quote(target)
            adminCommands.append("[ ! -e \(dst) ] && /bin/mv -n \(src) \(dst)")
        }
        adminCommands += receiptsToForget(result: result, selected: selected, items: items)
            .map { "/usr/sbin/pkgutil --forget \(ShellQuoting.quote($0))" }

        if manifestSaved, !adminCommands.isEmpty {
            var privilegedError: FailureReason?
            do {
                try privileged.run(adminCommands)
            } catch PrivilegedError.cancelled {
                privilegedError = .adminDenied
            } catch PrivilegedError.failed(let message) {
                privilegedError = .other(message)
            } catch {
                privilegedError = .other(error.localizedDescription)
            }
            // Zincir (&&) yarıda kesilmiş olabilir: durum dosya sisteminden belirlenir.
            for index in adminIndices {
                let original = URL(fileURLWithPath: items[index].originalPath)
                if let target = items[index].trashPath,
                   files.exists(URL(fileURLWithPath: target)), !files.exists(original) {
                    items[index].state = .trashed
                } else {
                    items[index].state = .failed
                    items[index].failure = privilegedError ?? .moveNotVerified
                }
            }
        }

        record.items = items
        // Dosyalar zaten taşındı; kayıt güncellenemese de sonuç döndürülür (ilk manifest diskte).
        try? history.save(record)
        return UninstallOutcome(record: record, failures: items.filter { $0.state == .failed })
    }

    /// Yazma izni hatası mı (Cocoa NSFileWriteNoPermission ya da altta yatan POSIX EACCES/EPERM)?
    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EACCES) || ns.code == Int(EPERM) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionError(underlying) }
        return false
    }

    private static func isLaunchd(_ kind: LeftoverKind) -> Bool {
        kind == .launchAgent || kind == .launchDaemon
    }

    /// Yalnızca o paket kimliğine ait TÜM kalıntılar seçiliyse makbuz unutulur.
    /// Ayrıca o paketin yönetici olmayan öğelerinden biri Çöp'e taşınamadıysa unutulmaz.
    private func receiptsToForget(result: ScanResult, selected: [Leftover], items: [HistoryItem]) -> [String] {
        let selectedIDs = Set(selected.map(\.id))
        var seen = Set<String>()
        var ids: [String] = []
        for leftover in selected {
            guard let pkg = leftover.packageID, seen.insert(pkg).inserted else { continue }
            let all = result.leftovers.filter { $0.packageID == pkg }
            let nonAdminFailed = items.contains { $0.packageID == pkg && !$0.requiresAdmin && $0.state == .failed }
            if all.allSatisfy({ selectedIDs.contains($0.id) }), !nonAdminFailed { ids.append(pkg) }
        }
        return ids
    }
}
