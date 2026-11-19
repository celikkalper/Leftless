import Testing
import Foundation
@testable import KalintisizCore

final class FakeRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    let output: CommandOutput
    init(output: CommandOutput = CommandOutput(status: 0, stdout: "", stderr: "")) { self.output = output }
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }
    func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput {
        lock.lock(); _calls.append([executable] + arguments); lock.unlock()
        return output
    }
}

@Test func inspectReadsBundleInfo() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    let app = try fs.makeApp(name: "Spotify", bundleID: "com.spotify.client", executable: "SpotifyExe", version: "1.2.3")
    let info = try AppInspector(commands: FakeRunner()).inspect(app)
    #expect(info.bundleID == "com.spotify.client")
    #expect(info.name == "Spotify")
    #expect(info.executableName == "SpotifyExe")
    #expect(info.version == "1.2.3")
    #expect(info.teamID == nil)
    #expect(info.url == app)
}

@Test func inspectRejectsNonApp() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    let f = try fs.touch("Applications/readme.txt")
    #expect(throws: AppInspectorError.notAnAppBundle) { try AppInspector(commands: FakeRunner()).inspect(f) }
}

@Test func inspectRejectsMissingPlist() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    let app = fs.root.appendingPathComponent("Applications/Broken.app", isDirectory: true)
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    #expect(throws: AppInspectorError.missingInfoPlist) { try AppInspector(commands: FakeRunner()).inspect(app) }
}

@Test func inspectParsesTeamID() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    let app = try fs.makeApp(name: "Signed", bundleID: "com.example.signed")
    let runner = FakeRunner(output: CommandOutput(status: 0, stdout: "",
        stderr: "Identifier=com.example.signed\nTeamIdentifier=ABCDE12345\n"))
    let info = try AppInspector(commands: runner).inspect(app)
    #expect(info.teamID == "ABCDE12345")
    #expect(runner.calls.first?.first == "/usr/bin/codesign")
}

@Test func inspectTreatsNotSetTeamIDAsNil() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    let app = try fs.makeApp(name: "Adhoc", bundleID: "com.example.adhoc")
    let runner = FakeRunner(output: CommandOutput(status: 0, stdout: "", stderr: "TeamIdentifier=not set\n"))
    #expect(try AppInspector(commands: runner).inspect(app).teamID == nil)
}

@Test func installedAppsSkipsApple() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    try fs.makeApp(name: "Safari", bundleID: "com.apple.Safari")
    try fs.makeApp(name: "Spotify", bundleID: "com.spotify.client")
    try fs.makeApp(name: "Zed", bundleID: "dev.zed.Zed", in: fs.home.appendingPathComponent("Applications"))
    try fs.makeApp(name: "Nested", bundleID: "com.example.nested",
                   in: fs.root.appendingPathComponent("Applications/Vendor"))
    let env = ScanEnvironment(root: fs.root, home: fs.home, userCacheDir: nil, uid: 501)
    let list = InstalledApps(environment: env, inspector: AppInspector(commands: FakeRunner())).list()
    #expect(list.map(\.info.bundleID) == ["com.example.nested", "com.spotify.client", "dev.zed.Zed"])
    #expect(list.allSatisfy { $0.bundleSize > 0 })
}

@Test func environmentPathsAreRootRelative() throws {
    let env = ScanEnvironment(root: URL(fileURLWithPath: "/tmp/r"), home: URL(fileURLWithPath: "/tmp/r/Users/t"),
                              userCacheDir: nil, uid: 501)
    #expect(env.path("/Library/X").path == "/tmp/r/Library/X")
    #expect(env.homePath("Library/Caches").path == "/tmp/r/Users/t/Library/Caches")
}
