import Testing
import Foundation
@testable import KalintisizCore

private func env(_ fs: FakeSystem) -> ScanEnvironment {
    ScanEnvironment(root: fs.root, home: fs.home, userCacheDir: nil, uid: 501)
}

private let zoom = AppInfo(url: URL(fileURLWithPath: "/Applications/Zoom.us.app"),
                           bundleID: "us.zoom.xos", name: "zoom.us", executableName: "zoom.us")

private func writePlist(_ fs: FakeSystem, _ relative: String, _ dict: [String: Any]) throws {
    let url = try fs.touch(relative)
    try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: url)
}

@Test func launchAgentPointingIntoAppIsCertain() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    try writePlist(fs, "Users/tester/Library/LaunchAgents/helper.plist",
                   ["Label": "us.zoom.updater", "ProgramArguments": ["/Applications/Zoom.us.app/Contents/MacOS/x"]])
    let found = LaunchdScanner(environment: env(fs)).scan(zoom, keys: MatchKeys(app: zoom))
    let item = try #require(found.first)
    #expect(found.count == 1)
    #expect(item.confidence == .certain)
    #expect(item.kind == .launchAgent)
    #expect(item.launchdLabel == "us.zoom.updater")
    #expect(!item.requiresAdmin)
}

@Test func unrelatedAgentIgnored() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    try writePlist(fs, "Users/tester/Library/LaunchAgents/com.other.tool.plist",
                   ["Label": "com.other.tool", "ProgramArguments": ["/Applications/Other.app/Contents/MacOS/x"]])
    try fs.touch("Users/tester/Library/LaunchAgents/broken.plist")   // geçersiz plist sessizce atlanır
    #expect(LaunchdScanner(environment: env(fs)).scan(zoom, keys: MatchKeys(app: zoom)).isEmpty)
}

@Test func daemonRequiresAdmin() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    try writePlist(fs, "Library/LaunchDaemons/us.zoom.ZoomDaemon.plist",
                   ["Label": "us.zoom.ZoomDaemon", "Program": "/Applications/Zoom.us.app/Contents/Library/LaunchServices/us.zoom.ZoomDaemon"])
    try writePlist(fs, "Library/LaunchAgents/us.zoom.agent.plist", ["Label": "us.zoom.agent"])
    let found = LaunchdScanner(environment: env(fs)).scan(zoom, keys: MatchKeys(app: zoom))
    let daemon = try #require(found.first { $0.kind == .launchDaemon })
    #expect(daemon.requiresAdmin)
    #expect(daemon.confidence == .certain)
    let agent = try #require(found.first { $0.kind == .launchAgent })
    #expect(agent.requiresAdmin)
}

@Test func leftoverScannerIncludesLaunchdOnce() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    try writePlist(fs, "Users/tester/Library/LaunchAgents/us.zoom.updater.plist", ["Label": "us.zoom.updater"])
    let e = env(fs)
    let r = LeftoverScanner(environment: e, installedApps: [zoom], launchd: LaunchdScanner(environment: e)).scan(zoom)
    #expect(r.leftovers.filter { $0.kind == .launchAgent }.count == 1)
}
