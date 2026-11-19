import Foundation

public struct AppInfo: Codable, Hashable, Sendable {
    public var url: URL
    public var bundleID: String
    public var name: String
    public var executableName: String?
    public var version: String?
    public var teamID: String?

    public init(url: URL, bundleID: String, name: String, executableName: String? = nil,
                version: String? = nil, teamID: String? = nil) {
        self.url = url
        self.bundleID = bundleID
        self.name = name
        self.executableName = executableName
        self.version = version
        self.teamID = teamID
    }
}

public enum Confidence: String, Codable, Sendable {
    case certain, probable
}

public enum LeftoverKind: String, Codable, Sendable, CaseIterable {
    case appBundle, applicationSupport, caches, preferences, logs, savedState, httpStorages
    case webKit, cookies, container, groupContainer, applicationScripts
    case launchAgent, launchDaemon, privilegedHelper, kernelExtension
    case plugin, packageFile, personalFolder, other

    public var displayName: String {
        switch self {
        case .appBundle: "Uygulama"
        case .applicationSupport: "Uygulama Desteği"
        case .caches: "Önbellek"
        case .preferences: "Tercihler"
        case .logs: "Günlükler"
        case .savedState: "Kayıtlı Durum"
        case .httpStorages: "HTTP Depolama"
        case .webKit: "WebKit Verisi"
        case .cookies: "Çerezler"
        case .container: "Konteyner"
        case .groupContainer: "Grup Konteyneri"
        case .applicationScripts: "Uygulama Betikleri"
        case .launchAgent: "Başlatma Aracısı"
        case .launchDaemon: "Başlatma Servisi"
        case .privilegedHelper: "Ayrıcalıklı Yardımcı"
        case .kernelExtension: "Çekirdek Eklentisi"
        case .plugin: "Eklenti"
        case .packageFile: "Paket Dosyası"
        case .personalFolder: "Kişisel Klasör"
        case .other: "Diğer"
        }
    }
}

public struct Leftover: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var url: URL
    public var kind: LeftoverKind
    public var confidence: Confidence
    public var size: Int64
    public var requiresAdmin: Bool
    public var launchdLabel: String?
    public var packageID: String?
    public var note: String?

    public init(id: UUID = UUID(), url: URL, kind: LeftoverKind, confidence: Confidence,
                size: Int64 = 0, requiresAdmin: Bool = false, launchdLabel: String? = nil,
                packageID: String? = nil, note: String? = nil) {
        self.id = id
        self.url = url
        self.kind = kind
        self.confidence = confidence
        self.size = size
        self.requiresAdmin = requiresAdmin
        self.launchdLabel = launchdLabel
        self.packageID = packageID
        self.note = note
    }

    public var selectedByDefault: Bool { confidence == .certain }
}

public struct ScanResult: Sendable {
    public var app: AppInfo
    public var leftovers: [Leftover]
    public var systemExtensions: [String]

    public init(app: AppInfo, leftovers: [Leftover], systemExtensions: [String] = []) {
        self.app = app
        self.leftovers = leftovers
        self.systemExtensions = systemExtensions
    }

    public var totalSize: Int64 { leftovers.reduce(0) { $0 + $1.size } }
}
