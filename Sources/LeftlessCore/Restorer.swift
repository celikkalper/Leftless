import Foundation

public enum ConflictChoice: Sendable {
    case skip, replace
}

public struct RestoreOutcome: Sendable {
    public var record: HistoryRecord
    public var restored: Int
    public var skipped: Int
    public var failures: [HistoryItem]

    public init(record: HistoryRecord, restored: Int, skipped: Int, failures: [HistoryItem]) {
        self.record = record
        self.restored = restored
        self.skipped = skipped
        self.failures = failures
    }
}

public struct Restorer: Sendable {
    private let history: HistoryStore
    private let files: FileMoving
    private let privileged: PrivilegedExecuting
    private let commands: CommandRunning
    private let environment: ScanEnvironment

    public init(history: HistoryStore, files: FileMoving, privileged: PrivilegedExecuting,
                commands: CommandRunning, environment: ScanEnvironment) {
        self.history = history
        self.files = files
        self.privileged = privileged
        self.commands = commands
        self.environment = environment
    }

    /// Öğe bazlı sorunlar (eksik Çöp dosyası, taşıma hatası, iptal) fırlatılmaz; `failures` içinde döner.
    /// Başlangıçta doğrulanacak bir ön koşul olmadığından bu işlev hiç fırlatmaz.
    public func restore(_ record: HistoryRecord, onConflict: (HistoryItem) -> ConflictChoice) -> RestoreOutcome {
        var items = record.items
        var restored = 0, skipped = 0
        var failedIndices = Set<Int>()
        var adminIndices: [(Int, String)] = []
        var replaceCommands: [String] = []
        var chosenTargets = Set<String>()
        let trashDirectory = environment.home.appendingPathComponent(".Trash", isDirectory: true)

        for index in items.indices where items[index].state == .trashed {
            let item = items[index]
            // Yalnızca Çöp'te hâlâ duran öğeler geri yüklenir; eksik olan hata olarak bildirilir.
            guard let trashPath = item.trashPath, files.exists(URL(fileURLWithPath: trashPath)) else {
                items[index].failure = .notFoundInTrash
                failedIndices.insert(index)
                continue
            }
            let original = URL(fileURLWithPath: item.originalPath)
            if files.exists(original) {
                if onConflict(item) == .skip { skipped += 1; continue }
                if item.requiresAdmin {
                    let target = uniqueTrashURL(for: original, trashDirectory: trashDirectory) {
                        files.exists($0) || chosenTargets.contains($0.path)
                    }
                    chosenTargets.insert(target.path)
                    replaceCommands.append("[ -e \(ShellQuoting.quote(item.originalPath)) ] && /bin/mv -n \(ShellQuoting.quote(item.originalPath)) \(ShellQuoting.quote(target.path))")
                } else {
                    do { _ = try files.trash(original) } catch {
                        items[index].failure = .other(error.localizedDescription)
                        failedIndices.insert(index)
                        continue
                    }
                }
            }
            if item.requiresAdmin { adminIndices.append((index, trashPath)); continue }

            do {
                try files.createDirectory(original.deletingLastPathComponent())
                try files.move(URL(fileURLWithPath: trashPath), to: original)
                items[index].state = .restored
                items[index].failure = nil
                items[index].error = nil
                restored += 1
                if let domain = launchdDomain(for: item) {
                    // Zaten yüklü olabilir: hata yok sayılır.
                    _ = try? commands.run("/bin/launchctl", ["bootstrap", domain, item.originalPath])
                }
            } catch {
                items[index].failure = .other(error.localizedDescription)
                failedIndices.insert(index)
            }
        }

        if !adminIndices.isEmpty {
            var batch = replaceCommands
            for (index, trashPath) in adminIndices {
                let item = items[index]
                let parent = URL(fileURLWithPath: item.originalPath).deletingLastPathComponent().path
                batch.append("/bin/mkdir -p \(ShellQuoting.quote(parent)) && [ ! -e \(ShellQuoting.quote(item.originalPath)) ] && /bin/mv -n \(ShellQuoting.quote(trashPath)) \(ShellQuoting.quote(item.originalPath))")
            }
            for (index, _) in adminIndices {
                if let domain = launchdDomain(for: items[index]) {
                    // Yürütücü komutları " && " ile birleştirir; `|| true` parantezlenmezse önceki
                    // hataları yutar ve geri yüklenmemiş yollar için bootstrap çalışır.
                    batch.append("( /bin/launchctl bootstrap \(domain) \(ShellQuoting.quote(items[index].originalPath)) || true )")
                }
            }
            var privilegedError: FailureReason?
            do {
                try privileged.run(batch)
            } catch PrivilegedError.cancelled {
                privilegedError = .adminDenied
            } catch PrivilegedError.failed(let message) {
                privilegedError = .other(message)
            } catch {
                privilegedError = .other(error.localizedDescription)
            }
            // Zincir (&&) yarıda kesilmiş olabilir: durum dosya sisteminden belirlenir.
            for (index, _) in adminIndices {
                let original = URL(fileURLWithPath: items[index].originalPath)
                let trashStillThere = items[index].trashPath.map { files.exists(URL(fileURLWithPath: $0)) } ?? false
                if files.exists(original), !trashStillThere {
                    items[index].state = .restored
                    items[index].failure = nil
                    items[index].error = nil
                    restored += 1
                } else {
                    items[index].failure = privilegedError ?? .moveNotVerified
                    failedIndices.insert(index)
                }
            }
        }

        var updated = record
        updated.items = items
        // Dosyalar zaten geri taşındı; kayıt güncellenemese de sonuç döndürülür.
        try? history.save(updated)
        return RestoreOutcome(record: updated, restored: restored, skipped: skipped,
                              failures: failedIndices.sorted().map { items[$0] })
    }

    private func launchdDomain(for item: HistoryItem) -> String? {
        guard item.kind == .launchAgent || item.kind == .launchDaemon else { return nil }
        return item.launchdDomain ?? (item.kind == .launchDaemon ? "system" : "gui/\(environment.uid)")
    }
}
