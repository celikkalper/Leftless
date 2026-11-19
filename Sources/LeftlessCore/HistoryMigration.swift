import Foundation

/// Eski "Kalintisiz" geçmiş klasörünü yeni "Leftless" konumuna taşır.
public enum HistoryMigration {
    /// `<AS>/Kalintisiz/History` varsa ve `<AS>/Leftless/History` yoksa taşır; taşıdıysa `true` döner.
    @discardableResult
    public static func migrateIfNeeded(applicationSupport: URL, fileManager: FileManager = .default) throws -> Bool {
        let old = applicationSupport.appendingPathComponent("Kalintisiz/History", isDirectory: true)
        let newRoot = applicationSupport.appendingPathComponent("Leftless", isDirectory: true)
        let new = newRoot.appendingPathComponent("History", isDirectory: true)
        guard fileManager.fileExists(atPath: old.path), !fileManager.fileExists(atPath: new.path) else {
            return false
        }
        try fileManager.createDirectory(at: newRoot, withIntermediateDirectories: true)
        try fileManager.moveItem(at: old, to: new)
        return true
    }
}
