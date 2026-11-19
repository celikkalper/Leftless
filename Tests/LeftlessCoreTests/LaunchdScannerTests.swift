import Testing
import Foundation
@testable import LeftlessCore

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

private let chrome = AppInfo(url: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
                             bundleID: "com.google.Chrome", name: "Google Chrome")
private let canary = AppInfo(url: URL(fileURLWithPath: "/Applications/Google Chrome Canary.app"),
                             bundleID: "com.google.Chrome.canary", name: "Google Chrome Canary")
private let spotifyApp = AppInfo(url: URL(fileURLWithPath: "/Applications/Spotify.app"),
                                 bundleID: "com.spotify.client", name: "Spotify")

@Test func otherInstalledAppsAgentIsNotListed() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    try writePlist(fs, "Users/tester/Library/LaunchAgents/updater.plist",
                   ["Label": "x", "ProgramArguments": ["/opt/com.google.Chrome.canary/updater"]])
    let found = LaunchdScanner(environment: env(fs))
        .scan(chrome, keys: MatchKeys(app: chrome), installedApps: [chrome, canary])
    #expect(found.isEmpty)
}

@Test func fileNameWithBundleIDIsCertain() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    try writePlist(fs, "Users/tester/Library/LaunchAgents/com.spotify.client.helper.plist",
                   ["Label": "x", "ProgramArguments": ["/opt/unrelated/tool"]])
    let found = LaunchdScanner(environment: env(fs))
        .scan(spotifyApp, keys: MatchKeys(app: spotifyApp), installedApps: [spotifyApp])
    #expect(found.first?.confidence == .certain)
}

@Test func fileNameWithOnlyAppNameIsProbable() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    try writePlist(fs, "Users/tester/Library/LaunchAgents/Spotify Updater.plist",
                   ["Label": "x", "ProgramArguments": ["/opt/unrelated/tool"]])
    let found = LaunchdScanner(environment: env(fs))
        .scan(spotifyApp, keys: MatchKeys(app: spotifyApp), installedApps: [spotifyApp])
    #expect(found.first?.confidence == .probable)
}
