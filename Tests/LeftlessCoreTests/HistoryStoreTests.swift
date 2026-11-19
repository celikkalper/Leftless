import Testing
import Foundation
@testable import LeftlessCore

@Suite struct HistoryStoreTests {
    func makeItem(path: String, trash: String?, state: ItemState = .trashed) -> HistoryItem {
        HistoryItem(id: UUID(), originalPath: path, trashPath: trash, kind: .caches, size: 10,
                    requiresAdmin: false, launchdLabel: nil, launchdDomain: nil, packageID: nil,
                    state: state, error: nil)
    }

    func makeRecord(date: Date = Date(), items: [HistoryItem] = []) -> HistoryRecord {
        HistoryRecord(id: UUID(), appName: "Foo", bundleID: "com.foo", version: "1.0",
                      date: date, icon: Data([1, 2, 3]), items: items)
    }

    @Test func saveAndLoadRoundTrip() throws {
        let fake = try FakeSystem(); defer { fake.cleanup() }
        let store = HistoryStore(directory: fake.root.appendingPathComponent("History"))
        let record = makeRecord(date: Date(timeIntervalSince1970: 1_700_000_000),
                                items: [makeItem(path: "/a", trash: "/t/a")])
        try store.save(record)
        let loaded = try store.all()
        #expect(loaded.count == 1)
        #expect(loaded[0].id == record.id)
        #expect(loaded[0].items == record.items)
        #expect(loaded[0].icon == record.icon)
        #expect(loaded[0].date == record.date)
        #expect(loaded[0].totalSize == 10)
    }

    @Test func allSortedNewestFirstAndSkipsCorruptFiles() throws {
        let fake = try FakeSystem(); defer { fake.cleanup() }
        let dir = fake.root.appendingPathComponent("History")
        let store = HistoryStore(directory: dir)
        let old = makeRecord(date: Date(timeIntervalSince1970: 1_000))
        let new = makeRecord(date: Date(timeIntervalSince1970: 2_000))
        try store.save(old); try store.save(new)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("broken.json"))
        let all = try store.all()
        #expect(all.map(\.id) == [new.id, old.id])
    }

    @Test func allReturnsEmptyWhenDirectoryMissing() throws {
        let fake = try FakeSystem(); defer { fake.cleanup() }
        let store = HistoryStore(directory: fake.root.appendingPathComponent("Nope"))
        #expect(try store.all().isEmpty)
    }

    @Test func saveThrowsWhenDirectoryUncreatable() throws {
        let fake = try FakeSystem(); defer { fake.cleanup() }
        let file = try fake.touch("blocker")
        let store = HistoryStore(directory: file.appendingPathComponent("History"))
        #expect(throws: (any Error).self) { try store.save(makeRecord()) }
    }

    @Test func statusRestorableWhenAllTrashPathsExist() throws {
        let fake = try FakeSystem(); defer { fake.cleanup() }
        let t1 = try fake.touch("trash/a"), t2 = try fake.touch("trash/b")
        let store = HistoryStore(directory: fake.root.appendingPathComponent("History"))
        let r = makeRecord(items: [makeItem(path: "/a", trash: t1.path), makeItem(path: "/b", trash: t2.path)])
        #expect(store.status(of: r) == .restorable)
    }

    @Test func statusPartialWhenSomeMissing() throws {
        let fake = try FakeSystem(); defer { fake.cleanup() }
        let t1 = try fake.touch("trash/a")
        let store = HistoryStore(directory: fake.root.appendingPathComponent("History"))
        let r = makeRecord(items: [makeItem(path: "/a", trash: t1.path),
                                   makeItem(path: "/b", trash: fake.root.appendingPathComponent("trash/gone").path)])
        #expect(store.status(of: r) == .partial(missing: 1))
    }

    @Test func statusUnrecoverableWhenTrashEmptied() throws {
        let fake = try FakeSystem(); defer { fake.cleanup() }
        let store = HistoryStore(directory: fake.root.appendingPathComponent("History"))
        let r = makeRecord(items: [makeItem(path: "/a", trash: fake.root.appendingPathComponent("trash/x").path),
                                   makeItem(path: "/b", trash: nil, state: .failed)])
        #expect(store.status(of: r) == .unrecoverable)
        #expect(store.status(of: makeRecord()) == .unrecoverable)
    }

    @Test func statusRestoredWhenAllItemsRestored() throws {
        let fake = try FakeSystem(); defer { fake.cleanup() }
        let store = HistoryStore(directory: fake.root.appendingPathComponent("History"))
        let r = makeRecord(items: [makeItem(path: "/a", trash: nil, state: .restored)])
        #expect(store.status(of: r) == .restored)
    }

    @Test func deleteRemovesOnlyRecordFile() throws {
        let fake = try FakeSystem(); defer { fake.cleanup() }
        let trash = try fake.touch("trash/a")
        let store = HistoryStore(directory: fake.root.appendingPathComponent("History"))
        let r = makeRecord(items: [makeItem(path: "/a", trash: trash.path)])
        try store.save(r)
        try store.delete(id: r.id)
        #expect(try store.all().isEmpty)
        #expect(FileManager.default.fileExists(atPath: trash.path))
    }

    @Test func oldRecordWithoutOperationDecodesAsUninstall() throws {
        let fake = try FakeSystem(); defer { fake.cleanup() }
        let dir = fake.root.appendingPathComponent("History")
        let store = HistoryStore(directory: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        {"id":"8E0C5A52-2B1C-4E4C-9C61-6C3B7B6C9A11","appName":"Old","bundleID":"com.old",
         "date":"2026-01-01T00:00:00Z","items":[]}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("8E0C5A52-2B1C-4E4C-9C61-6C3B7B6C9A11.json"))
        let all = try store.all()
        #expect(all.count == 1)
        #expect(all[0].operation == .uninstall)
        #expect(all[0].appName == "Old")
    }

    @Test func operationRoundTrips() throws {
        let fake = try FakeSystem(); defer { fake.cleanup() }
        let store = HistoryStore(directory: fake.root.appendingPathComponent("History"))
        var r = makeRecord()
        #expect(r.operation == .uninstall)
        r.operation = .reset
        try store.save(r)
        #expect(try store.all()[0].operation == .reset)
    }
}
