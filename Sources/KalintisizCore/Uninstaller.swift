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
                item.launchdDomain = leftover.requiresAdmin ? "system" : "gui/\(environment.uid)"
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
                adminCommands.append("/bin/launchctl bootout system \(ShellQuoting.quote(item.originalPath)) || true")
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
            } catch {
                items[index].state = .failed
                items[index].error = error.localizedDescription
            }
        }

        let adminIndices = items.indices.filter { items[$0].requiresAdmin }
        for index in adminIndices {
            guard let target = items[index].trashPath else { continue }
            adminCommands.append("/bin/mv -n \(ShellQuoting.quote(items[index].originalPath)) \(ShellQuoting.quote(target))")
        }
        adminCommands += receiptsToForget(result: result, selected: selected)
            .map { "/usr/sbin/pkgutil --forget \(ShellQuoting.quote($0))" }

        if !adminCommands.isEmpty {
            var privilegedError: String?
            do {
                try privileged.run(adminCommands)
            } catch PrivilegedError.cancelled {
                privilegedError = "Yönetici izni verilmedi"
            } catch PrivilegedError.failed(let message) {
                privilegedError = message
            } catch {
                privilegedError = error.localizedDescription
            }
            // Zincir (&&) yarıda kesilmiş olabilir: durum dosya sisteminden belirlenir.
            for index in adminIndices {
                let original = URL(fileURLWithPath: items[index].originalPath)
                if let target = items[index].trashPath,
                   files.exists(URL(fileURLWithPath: target)), !files.exists(original) {
                    items[index].state = .trashed
                } else {
                    items[index].state = .failed
                    items[index].error = privilegedError ?? "Taşıma doğrulanamadı"
                }
            }
        }

        record.items = items
        // Dosyalar zaten taşındı; kayıt güncellenemese de sonuç döndürülür (ilk manifest diskte).
        try? history.save(record)
        return UninstallOutcome(record: record, failures: items.filter { $0.state == .failed })
    }

    private static func isLaunchd(_ kind: LeftoverKind) -> Bool {
        kind == .launchAgent || kind == .launchDaemon
    }

    /// Yalnızca o paket kimliğine ait TÜM kalıntılar seçiliyse makbuz unutulur.
    private func receiptsToForget(result: ScanResult, selected: [Leftover]) -> [String] {
        let selectedIDs = Set(selected.map(\.id))
        var seen = Set<String>()
        var ids: [String] = []
        for leftover in selected {
            guard let pkg = leftover.packageID, seen.insert(pkg).inserted else { continue }
            let all = result.leftovers.filter { $0.packageID == pkg }
            if all.allSatisfy({ selectedIDs.contains($0.id) }) { ids.append(pkg) }
        }
        return ids
    }
}
