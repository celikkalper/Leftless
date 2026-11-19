import Foundation

public struct UninstallOutcome: Sendable {
    public var record: HistoryRecord
    public var failures: [HistoryItem]

    public init(record: HistoryRecord, failures: [HistoryItem]) {
        self.record = record
        self.failures = failures
    }
}

/// One app (or one orphan/reset set) to process in a batch; produces one history record.
public struct UninstallJob: Sendable {
    public var scan: ScanResult
    public var selected: [Leftover]
    public var icon: Data?
    public var operation: HistoryOperation

    public init(scan: ScanResult, selected: [Leftover], icon: Data?, operation: HistoryOperation = .uninstall) {
        self.scan = scan
        self.selected = selected
        self.icon = icon
        self.operation = operation
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
        try uninstall(batch: [UninstallJob(scan: result, selected: selected, icon: icon)])[0]
    }

    /// Bir işin yürütme durumu (iş başına bir kayıt).
    private struct Work {
        var job: UninstallJob
        /// Önceki işlerin aldığı yollar çıkarılmış seçim.
        var selected: [Leftover]
        var items: [HistoryItem]
        var record: HistoryRecord
        var adminBootouts: [String] = []
        var adminIndices: [Int] = []
        var manifestSaved = true
    }

    /// Birden çok işi tek yönetici çalıştırmasıyla kaldırır; iş başına bir kayıt döner (sırası korunur).
    /// Tüm manifestler (pending) herhangi bir taşımadan önce yazılır; biri yazılamazsa önceden yazılanlar
    /// silinir ve hiçbir şey taşınmadan fırlatır. Öğe bazlı hatalar fırlatılmaz, kayıtta `failed` olarak tutulur.
    public func uninstall(batch jobs: [UninstallJob]) throws -> [UninstallOutcome] {
        var chosenTargets = Set<String>()
        var claimedPaths = Set<String>()
        var works: [Work] = []
        for job in jobs {
            // Bir yol yalnızca bir kez taşınabilir: önceki bir işin aldığı öğe sonraki işlerden çıkarılır.
            let selected = job.selected.filter { claimedPaths.insert($0.url.path).inserted }
            let items: [HistoryItem] = selected.map { leftover in
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
            let record = HistoryRecord(appName: job.scan.app.name, bundleID: job.scan.app.bundleID,
                                       version: job.scan.app.version, icon: job.icon, items: items,
                                       operation: job.operation)
            works.append(Work(job: job, selected: selected, items: items, record: record))
        }

        var savedIDs: [UUID] = []
        do {
            for work in works {
                try history.save(work.record)
                savedIDs.append(work.record.id)
            }
        } catch {
            // Hiçbir şey taşınmadı: yarım kalan toplu işlemin bekleyen kayıtları geri alınır.
            for id in savedIDs { try? history.delete(id: id) }
            throw error
        }

        for w in works.indices {
            for item in works[w].items where item.launchdDomain != nil {
                if item.requiresAdmin {
                    works[w].adminBootouts.append(
                        "/bin/launchctl bootout \(item.launchdDomain ?? "system") \(ShellQuoting.quote(item.originalPath)) || true")
                } else if let domain = item.launchdDomain {
                    // Zaten yüklü olmayabilir: hata ve sıfırdan farklı çıkış yok sayılır.
                    _ = try? commands.run("/bin/launchctl", ["bootout", domain, item.originalPath])
                }
            }

            for index in works[w].items.indices where !works[w].items[index].requiresAdmin {
                do {
                    let trashed = try files.trash(URL(fileURLWithPath: works[w].items[index].originalPath))
                    works[w].items[index].state = .trashed
                    works[w].items[index].trashPath = trashed.path
                } catch where Self.isPermissionError(error) {
                    // Ör. root:wheel 755 paket: yönetici taşımasına aktarılır (hedef aşağıda seçilip kaydedilir).
                    works[w].items[index].requiresAdmin = true
                } catch {
                    works[w].items[index].state = .failed
                    works[w].items[index].failure = .other(error.localizedDescription)
                }
            }
        }

        // trashItem kendi boş adını seçer; bir yönetici hedefiyle çakışmış olabilir. Tüm işlerin hedefleri
        // birlikte yeniden seçilir (işler arasında da benzersiz).
        var retargeted = Set<String>()
        for w in works.indices {
            let adminIndices = works[w].items.indices.filter { works[w].items[$0].requiresAdmin }
            works[w].adminIndices = adminIndices
            for index in adminIndices {
                let original = URL(fileURLWithPath: works[w].items[index].originalPath)
                let target = uniqueTrashURL(for: original, trashDirectory: trashDirectory) {
                    files.exists($0) || retargeted.contains($0.path)
                }
                retargeted.insert(target.path)
                works[w].items[index].trashPath = target.path
            }
            guard !adminIndices.isEmpty else { continue }
            works[w].record.items = works[w].items
            do {
                try history.save(works[w].record)
            } catch {
                // Root, diskteki manifestte olmayan hedeflere taşıma yapmamalı: bu işin yönetici adımı atlanır.
                works[w].manifestSaved = false
                for index in adminIndices {
                    works[w].items[index].state = .failed
                    works[w].items[index].failure = .manifestUpdateFailed
                }
            }
        }

        // Sıra: tüm bootout'lar, tüm taşımalar, en sonda makbuzlar (aynı paket bir kez unutulur).
        var bootouts: [String] = [], moves: [String] = [], forgets: [String] = []
        var forgotten = Set<String>()
        for work in works where work.manifestSaved {
            bootouts += work.adminBootouts
            for index in work.adminIndices {
                guard let target = work.items[index].trashPath else { continue }
                let src = ShellQuoting.quote(work.items[index].originalPath), dst = ShellQuoting.quote(target)
                moves.append("[ ! -e \(dst) ] && /bin/mv -n \(src) \(dst)")
            }
            for pkg in receiptsToForget(result: work.job.scan, selected: work.selected, items: work.items)
            where forgotten.insert(pkg).inserted {
                forgets.append("/usr/sbin/pkgutil --forget \(ShellQuoting.quote(pkg))")
            }
        }
        let adminCommands = bootouts + moves + forgets

        if !adminCommands.isEmpty {
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
            for w in works.indices where works[w].manifestSaved {
                for index in works[w].adminIndices {
                    let original = URL(fileURLWithPath: works[w].items[index].originalPath)
                    if let target = works[w].items[index].trashPath,
                       files.exists(URL(fileURLWithPath: target)), !files.exists(original) {
                        works[w].items[index].state = .trashed
                    } else {
                        works[w].items[index].state = .failed
                        works[w].items[index].failure = privilegedError ?? .moveNotVerified
                    }
                }
            }
        }

        return works.map { work in
            var record = work.record
            record.items = work.items
            // Dosyalar zaten taşındı; kayıt güncellenemese de sonuç döndürülür (ilk manifest diskte).
            try? history.save(record)
            return UninstallOutcome(record: record, failures: work.items.filter { $0.state == .failed })
        }
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
