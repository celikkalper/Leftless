import Testing
import Foundation
@testable import LeftlessCore

private struct FakeProvider: ReceiptProviding {
    var packages: [String: [String]]
    func packageIDs() -> [String] { Array(packages.keys) }
    func installedPaths(forPackage id: String) -> [String] { packages[id] ?? [] }
}

private final class StubRunner: CommandRunning, @unchecked Sendable {
    var outputs: [String: String]
    init(_ outputs: [String: String]) { self.outputs = outputs }
    func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput {
        CommandOutput(status: 0, stdout: outputs[arguments.joined(separator: " ")] ?? "", stderr: "")
    }
}

private func env(_ fs: FakeSystem) -> ScanEnvironment {
    ScanEnvironment(root: fs.root, home: fs.home, userCacheDir: nil, uid: 501)
}

private let spotify = AppInfo(url: URL(fileURLWithPath: "/Applications/Spotify.app"),
                              bundleID: "com.spotify.client", name: "Spotify", teamID: "ABCDE12345")

private func scan(_ fs: FakeSystem, _ packages: [String: [String]], excluding: [URL] = []) -> [Leftover] {
    ReceiptScanner(environment: env(fs), provider: FakeProvider(packages: packages))
        .scan(spotify, keys: MatchKeys(app: spotify), installedApps: [spotify], excluding: excluding)
}

@Test func receiptFilesBecomeLeftovers() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    try fs.touch("Library/Application Support/SpotifyHelper/a.dylib")
    let path = "/Library/Application Support/SpotifyHelper/a.dylib"
    let found = scan(fs, ["com.spotify.pkg": [path, "/Library/Application Support/SpotifyHelper/missing"]])
    let item = try #require(found.first)
    #expect(found.count == 1)
    #expect(item.kind == .packageFile)
    #expect(item.packageID == "com.spotify.pkg")
    #expect(item.requiresAdmin)
}

@Test func receiptFilesOutsideLibraryAreProbable() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    try fs.touch("usr/local/bin/spotify-cli")
    let found = scan(fs, ["com.spotify.client.cli": ["/usr/local/bin/spotify-cli"]])
    #expect(found.first?.confidence == .probable)
    try fs.touch("Library/Spotify/x")
    let certain = scan(fs, ["com.spotify.client.cli": ["/Library/Spotify/x"]])
    #expect(certain.first?.confidence == .certain)
}

@Test func receiptNestedPathsDeduplicated() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    let dir = fs.root.appendingPathComponent("Library/Application Support/Spotify")
    try fs.touch("Library/Application Support/Spotify/a")
    try fs.touch("Library/Spotify/b")
    let found = scan(fs, ["com.spotify.client.pkg": ["/Library/Application Support/Spotify/a", "/Library/Spotify/b"]],
                     excluding: [dir])
    #expect(found.map { $0.url.lastPathComponent } == ["b"])
}

@Test func receiptSkipsAppBundlesAndProtectedPaths() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    try fs.touch("Applications/Spotify.app/Contents/x")
    try fs.touch("usr/bin/spotify")
    #expect(scan(fs, ["com.spotify.client.pkg": ["/Applications/Spotify.app/Contents/x", "/usr/bin/spotify"]]).isEmpty)
}

@Test func pkgutilProviderBuildsAbsolutePaths() {
    let runner = StubRunner([
        "--pkgs": "com.spotify.pkg\n",
        "--pkg-info com.spotify.pkg": "package-id: com.spotify.pkg\nvolume: /\nlocation: Library/Spotify\n",
        "--only-files --files com.spotify.pkg": "a/b.dylib\nc\n",
    ])
    let provider = PkgutilReceiptProvider(commands: runner)
    #expect(provider.packageIDs() == ["com.spotify.pkg"])
    #expect(provider.installedPaths(forPackage: "com.spotify.pkg") == ["/Library/Spotify/a/b.dylib", "/Library/Spotify/c"])
}

@Test func systemExtensionsFilteredByBundleOrTeam() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    let runner = StubRunner(["list": "header\n  *  ABCDE12345  com.spotify.client.ext (1.0)  ext  [activated enabled]  \n   X  com.other.ext\n"])
    let r = LeftoverScanner(environment: env(fs), installedApps: [spotify], commands: runner).scan(spotify)
    #expect(r.systemExtensions == ["*  ABCDE12345  com.spotify.client.ext (1.0)  ext  [activated enabled]"])
    #expect(LeftoverScanner(environment: env(fs), installedApps: [spotify]).scan(spotify).systemExtensions.isEmpty)
}
