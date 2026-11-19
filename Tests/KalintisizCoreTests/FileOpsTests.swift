import Testing
import Foundation
@testable import KalintisizCore

private final class RecordingRunner: CommandRunning, @unchecked Sendable {
    var calls: [(String, [String])] = []
    var result: CommandOutput
    init(_ result: CommandOutput = CommandOutput(status: 0, stdout: "", stderr: "")) { self.result = result }
    func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput {
        calls.append((executable, arguments))
        return result
    }
}

@Test func quotesSpacesTurkishAndApostrophes() {
    #expect(ShellQuoting.quote("/Applications/Müzik Çalar's.app") == "'/Applications/Müzik Çalar'\\''s.app'")
}

@Test func appleScriptEscapesQuotesAndBackslashes() {
    #expect(ShellQuoting.appleScriptString(#"a"b\c"#) == #"a\"b\\c"#)
}

@Test func uniqueTrashURLAppendsCounter() {
    let trash = URL(fileURLWithPath: "/T", isDirectory: true)
    let existing: Set<String> = ["/T/a.plist", "/T/a 2.plist", "/T/Spotify"]
    let exists: (URL) -> Bool = { existing.contains($0.path) }
    #expect(uniqueTrashURL(for: URL(fileURLWithPath: "/x/a.plist"), trashDirectory: trash, fileExists: exists).path == "/T/a 3.plist")
    #expect(uniqueTrashURL(for: URL(fileURLWithPath: "/x/Spotify"), trashDirectory: trash, fileExists: exists).path == "/T/Spotify 2")
    #expect(uniqueTrashURL(for: URL(fileURLWithPath: "/x/Foo.app"), trashDirectory: trash, fileExists: exists).path == "/T/Foo.app")
    let foo: (URL) -> Bool = { $0.path == "/T/Foo.app" }
    #expect(uniqueTrashURL(for: URL(fileURLWithPath: "/x/Foo.app"), trashDirectory: trash, fileExists: foo).path == "/T/Foo 2.app")
}

@Test func systemMoverTrashesFileInTempDir() throws {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("kalintisiz-test-\(UUID().uuidString).txt")
    try "x".write(to: file, atomically: true, encoding: .utf8)
    let mover = SystemFileMover()
    let trashed = try mover.trash(file)
    defer { try? FileManager.default.removeItem(at: trashed) }
    #expect(mover.exists(trashed))
    #expect(!mover.exists(file))
}

@Test func systemMoverMoveRefusesToOverwrite() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kalintisiz-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let mover = SystemFileMover()
    try mover.createDirectory(dir)
    let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
    try "a".write(to: a, atomically: true, encoding: .utf8)
    try "b".write(to: b, atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) { try mover.move(a, to: b) }
    #expect(try String(contentsOf: b, encoding: .utf8) == "b")
}

@Test func privilegedExecutorBuildsSingleOsascriptCall() throws {
    let runner = RecordingRunner()
    try OsascriptPrivilegedExecutor(commands: runner).run(["rm -rf '/a b'", "launchctl bootout \"x\""])
    #expect(runner.calls.count == 1)
    #expect(runner.calls[0].0 == "/usr/bin/osascript")
    #expect(runner.calls[0].1 == ["-e",
        #"do shell script "rm -rf '/a b' && launchctl bootout \"x\"" with administrator privileges"#])
}

@Test func privilegedExecutorEmptyIsNoOp() throws {
    let runner = RecordingRunner()
    try OsascriptPrivilegedExecutor(commands: runner).run([])
    #expect(runner.calls.isEmpty)
}

@Test func privilegedExecutorMapsCancelAndFailure() {
    let cancel = RecordingRunner(CommandOutput(status: 1, stdout: "", stderr: "execution error: User canceled. (-128)"))
    #expect(throws: PrivilegedError.cancelled) { try OsascriptPrivilegedExecutor(commands: cancel).run(["true"]) }
    let fail = RecordingRunner(CommandOutput(status: 1, stdout: "", stderr: "boom"))
    #expect(throws: PrivilegedError.failed("boom")) { try OsascriptPrivilegedExecutor(commands: fail).run(["true"]) }
}
