import Foundation

public enum ItemState: String, Codable, Sendable {
    case pending, trashed, failed, restored
}

/// Why an item could not be moved or restored. Stored as a stable code, never as display text.
public enum FailureReason: Codable, Hashable, Sendable {
    case adminDenied, manifestUpdateFailed, notFoundInTrash, moveNotVerified
    /// Raw system text (stderr / `localizedDescription`); shown only in help tooltips.
    case other(String)

    private enum CodingKeys: String, CodingKey { case code, detail }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .code) {
        case "adminDenied": self = .adminDenied
        case "manifestUpdateFailed": self = .manifestUpdateFailed
        case "notFoundInTrash": self = .notFoundInTrash
        case "moveNotVerified": self = .moveNotVerified
        default: self = .other(try c.decodeIfPresent(String.self, forKey: .detail) ?? "")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .adminDenied: try c.encode("adminDenied", forKey: .code)
        case .manifestUpdateFailed: try c.encode("manifestUpdateFailed", forKey: .code)
        case .notFoundInTrash: try c.encode("notFoundInTrash", forKey: .code)
        case .moveNotVerified: try c.encode("moveNotVerified", forKey: .code)
        case .other(let text):
            try c.encode("other", forKey: .code)
            try c.encode(text, forKey: .detail)
        }
    }
}

public struct HistoryItem: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var originalPath: String
    public var trashPath: String?
    public var kind: LeftoverKind
    public var size: Int64
    public var requiresAdmin: Bool
    public var launchdLabel: String?
    public var launchdDomain: String?
    public var packageID: String?
    public var state: ItemState
    public var failure: FailureReason?
    /// Legacy free-text reason from records written before failure codes; decoded, displayed, never written.
    public var error: String?

    public init(id: UUID = UUID(), originalPath: String, trashPath: String? = nil, kind: LeftoverKind,
                size: Int64, requiresAdmin: Bool = false, launchdLabel: String? = nil,
                launchdDomain: String? = nil, packageID: String? = nil,
                state: ItemState = .pending, failure: FailureReason? = nil, error: String? = nil) {
        self.id = id
        self.originalPath = originalPath
        self.trashPath = trashPath
        self.kind = kind
        self.size = size
        self.requiresAdmin = requiresAdmin
        self.launchdLabel = launchdLabel
        self.launchdDomain = launchdDomain
        self.packageID = packageID
        self.state = state
        self.failure = failure
        self.error = error
    }
}

public struct HistoryRecord: Codable, Identifiable, Sendable {
    public var id: UUID
    public var appName: String
    public var bundleID: String
    public var version: String?
    public var date: Date
    public var icon: Data?
    public var items: [HistoryItem]

    public init(id: UUID = UUID(), appName: String, bundleID: String, version: String? = nil,
                date: Date = Date(), icon: Data? = nil, items: [HistoryItem]) {
        self.id = id
        self.appName = appName
        self.bundleID = bundleID
        self.version = version
        self.date = date
        self.icon = icon
        self.items = items
    }

    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
}

public enum RestoreStatus: Equatable, Sendable {
    case restorable, partial(missing: Int), unrecoverable, restored
}

public final class HistoryStore: Sendable {
    let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func liveDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Leftless/History", isDirectory: true)
    }

    private func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Dizini gerekirse oluşturur ve kaydı atomik yazar; başarısızsa fırlatır.
    public func save(_ r: HistoryRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(r).write(to: fileURL(r.id), options: .atomic)
    }

    /// Yeniden eskiye sıralı; okunamayan/bozuk dosyalar atlanır.
    public func all() throws -> [HistoryRecord] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(HistoryRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }

    /// Yalnızca kayıt dosyasını siler; Çöp'teki dosyalara dokunmaz.
    public func delete(id: UUID) throws {
        try FileManager.default.removeItem(at: fileURL(id))
    }

    public func status(of r: HistoryRecord) -> RestoreStatus {
        if !r.items.isEmpty, r.items.allSatisfy({ $0.state == .restored }) { return .restored }
        let trashed = r.items.filter { $0.state == .trashed }
        let missing = trashed.filter { item in
            guard let path = item.trashPath else { return true }
            return !FileManager.default.fileExists(atPath: path)
        }.count
        if trashed.isEmpty || missing == trashed.count { return .unrecoverable }
        return missing == 0 ? .restorable : .partial(missing: missing)
    }
}
