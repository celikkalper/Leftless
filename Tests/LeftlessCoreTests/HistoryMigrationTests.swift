import Foundation
import Testing
@testable import LeftlessCore

@Suite struct HistoryMigrationTests {
    private func makeSupport() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leftless-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func movesOldHistoryWhenNewMissing() throws {
        let support = try makeSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let fm = FileManager.default
        let oldHistory = support.appendingPathComponent("Kalintisiz/History", isDirectory: true)
        try fm.createDirectory(at: oldHistory, withIntermediateDirectories: true)
        try "{}".write(to: oldHistory.appendingPathComponent("a.json"), atomically: true, encoding: .utf8)

        let moved = try HistoryMigration.migrateIfNeeded(applicationSupport: support)

        #expect(moved)
        #expect(fm.fileExists(atPath: support.appendingPathComponent("Leftless/History/a.json").path))
        #expect(!fm.fileExists(atPath: oldHistory.path))
    }

    @Test func doesNothingWhenNewExists() throws {
        let support = try makeSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let fm = FileManager.default
        let oldHistory = support.appendingPathComponent("Kalintisiz/History", isDirectory: true)
        let newHistory = support.appendingPathComponent("Leftless/History", isDirectory: true)
        try fm.createDirectory(at: oldHistory, withIntermediateDirectories: true)
        try fm.createDirectory(at: newHistory, withIntermediateDirectories: true)
        try "{}".write(to: oldHistory.appendingPathComponent("old.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: newHistory.appendingPathComponent("new.json"), atomically: true, encoding: .utf8)

        let moved = try HistoryMigration.migrateIfNeeded(applicationSupport: support)

        #expect(!moved)
        #expect(fm.fileExists(atPath: oldHistory.appendingPathComponent("old.json").path))
        #expect(fm.fileExists(atPath: newHistory.appendingPathComponent("new.json").path))
        #expect(!fm.fileExists(atPath: newHistory.appendingPathComponent("old.json").path))
    }

    @Test func doesNothingWhenOldMissing() throws {
        let support = try makeSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let moved = try HistoryMigration.migrateIfNeeded(applicationSupport: support)
        #expect(!moved)
        #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("Leftless").path))
    }
}
