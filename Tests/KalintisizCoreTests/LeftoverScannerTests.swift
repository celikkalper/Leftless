import Testing
import Foundation
@testable import KalintisizCore

private func makeEnv(_ fs: FakeSystem, cache: URL? = nil) -> ScanEnvironment {
    ScanEnvironment(root: fs.root, home: fs.home, userCacheDir: cache, uid: 501)
}

private let spotify = AppInfo(url: URL(fileURLWithPath: "/nonexistent/Applications/Spotify.app"),
                              bundleID: "com.spotify.client", name: "Spotify", teamID: "ABCDE12345")

private func scan(_ fs: FakeSystem, app: AppInfo, installed: [AppInfo]? = nil, cache: URL? = nil) -> ScanResult {
    LeftoverScanner(environment: makeEnv(fs, cache: cache), installedApps: installed ?? [app]).scan(app)
}

private func find(_ r: ScanResult, _ suffix: String) -> Leftover? {
    r.leftovers.first { $0.url.path.hasSuffix(suffix) }
}

@Test func findsCertainLibraryItems() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    try fs.touch("Users/tester/Library/Caches/com.spotify.client/data", bytes: 100)
    try fs.touch("Users/tester/Library/Preferences/com.spotify.client.plist")
    try fs.touch("Users/tester/Library/Application Support/Spotify/x")
    let r = scan(fs, app: spotify)
    let caches = try #require(find(r, "Caches/com.spotify.client"))
    let prefs = try #require(find(r, "Preferences/com.spotify.client.plist"))
    let support = try #require(find(r, "Application Support/Spotify"))
    #expect([caches, prefs, support].allSatisfy { $0.confidence == .certain && !$0.requiresAdmin })
    #expect(caches.kind == .caches)
    #expect(prefs.kind == .preferences)
    #expect(support.kind == .applicationSupport)
    #expect(caches.size > 0)
}

@Test func skipsOtherAppsItems() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    let other = AppInfo(url: URL(fileURLWithPath: "/Applications/Other.app"), bundleID: "com.spotify.other", name: "Other")
    try fs.touch("Users/tester/Library/Caches/com.spotify.other/x")
    try fs.touch("Users/tester/Library/Caches/com.spotify.client/x")
    let r = scan(fs, app: spotify, installed: [spotify, other])
    #expect(find(r, "com.spotify.other") == nil)
    #expect(find(r, "com.spotify.client") != nil)
}

@Test func vendorSharedFolderIsProbableWhenSiblingInstalled() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    let excel = AppInfo(url: URL(fileURLWithPath: "/Applications/Microsoft Excel.app"),
                        bundleID: "com.microsoft.Excel", name: "Microsoft Excel")
    let word = AppInfo(url: URL(fileURLWithPath: "/Applications/Microsoft Word.app"),
                       bundleID: "com.microsoft.Word", name: "Microsoft Word")
    try fs.touch("Users/tester/Library/Application Support/Microsoft/x")
    try fs.touch("Users/tester/Library/Preferences/com.microsoft.Excel.plist")
    try fs.touch("Users/tester/Library/Preferences/com.microsoft.Word.plist")
    try fs.touch("Users/tester/Library/Caches/com.microsoft.shared")
    let r = scan(fs, app: excel, installed: [excel, word])
    let vendor = try #require(find(r, "Application Support/Microsoft"))
    #expect(vendor.confidence == .probable)
    #expect(vendor.note == "Microsoft Word da kullanıyor olabilir")
    let shared = try #require(find(r, "Caches/com.microsoft.shared"))
    #expect(shared.confidence == .probable)
    #expect(shared.note == "Microsoft Word da kullanıyor olabilir")
    #expect(find(r, "com.microsoft.Excel.plist")?.confidence == .certain)
    #expect(find(r, "com.microsoft.Word.plist") == nil)
}

@Test func vendorFolderWithoutSiblingIsNotListed() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    let excel = AppInfo(url: URL(fileURLWithPath: "/Applications/Microsoft Excel.app"),
                        bundleID: "com.microsoft.Excel", name: "Microsoft Excel")
    try fs.touch("Users/tester/Library/Application Support/Microsoft/x")
    #expect(find(scan(fs, app: excel), "Application Support/Microsoft") == nil)
}

@Test func shortNamesNeverNameMatch() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    let go = AppInfo(url: URL(fileURLWithPath: "/Applications/Go.app"), bundleID: "com.example.go", name: "Go")
    try fs.touch("Users/tester/Library/Caches/Google/x")
    try fs.touch("Users/tester/Library/Caches/Go/x")
    let r = scan(fs, app: go)
    #expect(find(r, "Caches/Google") == nil)
    #expect(find(r, "Caches/Go") == nil)
}

@Test func personalFoldersTopLevelOnly() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    try fs.touch("Users/tester/Music/Spotify/a.mp3")
    try fs.touch("Users/tester/Music/x/Spotify/b.mp3")
    try fs.touch("Users/tester/Documents/Notes/c")
    let r = scan(fs, app: spotify)
    let m = try #require(find(r, "Music/Spotify"))
    #expect(m.confidence == .probable)
    #expect(m.kind == .personalFolder)
    #expect(r.leftovers.filter { $0.url.path.contains("/Music/") }.count == 1)
    #expect(find(r, "Documents/Notes") == nil)
}

@Test func systemLibraryRequiresAdmin() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    try fs.touch("Library/Application Support/Spotify/x")
    try fs.touch("Library/PrivilegedHelperTools/com.spotify.client.helper")
    try fs.touch("Users/tester/Library/Application Support/Spotify/x")
    let r = scan(fs, app: spotify)
    let support = r.leftovers.filter { $0.url.path.hasSuffix("Library/Application Support/Spotify") }
    #expect(support.count == 2)
    let user = try #require(support.first { $0.url.path.contains("/Users/tester/") })
    let sys = try #require(support.first { !$0.url.path.contains("/Users/tester/") })
    #expect(sys.requiresAdmin)
    #expect(!user.requiresAdmin)
    let helper = try #require(find(r, "PrivilegedHelperTools/com.spotify.client.helper"))
    #expect(helper.kind == .privilegedHelper)
    #expect(helper.requiresAdmin)
}

@Test func appleItemsNeverListed() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    try fs.touch("Users/tester/Library/Preferences/com.apple.spotify.plist")
    try fs.touch("Users/tester/Library/Caches/com.apple.Spotify/x")
    #expect(scan(fs, app: spotify).leftovers.isEmpty)
}

@Test func includesAppBundleAndUserCacheDir() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    let appURL = try fs.makeApp(name: "Spotify", bundleID: "com.spotify.client")
    let app = AppInfo(url: appURL, bundleID: "com.spotify.client", name: "Spotify")
    let cache = fs.root.appendingPathComponent("var/folders/ab/C", isDirectory: true)
    try fs.touch("var/folders/ab/C/com.spotify.client/x")
    try fs.touch("var/folders/ab/C/com.other.app/x")
    let r = scan(fs, app: app, cache: cache)
    let bundle = try #require(r.leftovers.first { $0.kind == .appBundle })
    #expect(bundle.url == appURL)
    #expect(bundle.confidence == .certain)
    #expect(!bundle.requiresAdmin)
    #expect(bundle.size > 0)
    #expect(find(r, "C/com.spotify.client")?.kind == .caches)
    #expect(find(r, "com.other.app") == nil)
    #expect(r.systemExtensions.isEmpty)
}

@Test func duplicateURLKeepsHigherConfidence() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    // userCacheDir aynı klasöre işaret ederse tek kayıt kalmalı.
    try fs.touch("Users/tester/Library/Caches/com.spotify.client/x")
    let cache = fs.home.appendingPathComponent("Library/Caches", isDirectory: true)
    let r = scan(fs, app: spotify, cache: cache)
    #expect(r.leftovers.filter { $0.url.path.hasSuffix("Caches/com.spotify.client") }.count == 1)
}

@Test func groupContainersMatchByTeamID() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    try fs.touch("Users/tester/Library/Group Containers/ABCDE12345.com.spotify.client/x")
    try fs.touch("Users/tester/Library/Group Containers/ABCDE12345.shared/x")
    try fs.touch("Users/tester/Library/Group Containers/ZZZZZ00000.com.spotify.client/x")
    let r = scan(fs, app: spotify)
    #expect(find(r, "ABCDE12345.com.spotify.client")?.confidence == .certain)
    #expect(find(r, "ABCDE12345.com.spotify.client")?.kind == .groupContainer)
    #expect(find(r, "ABCDE12345.shared")?.confidence == .probable)
    #expect(find(r, "ZZZZZ00000.com.spotify.client")?.confidence == .probable)  // yalnızca ad kelimesi
}

@Test func classifyRules() {
    let keys = MatchKeys(app: spotify)
    #expect(keys.vendorPrefix == "com.spotify.")
    #expect(keys.names == ["Spotify"])
    #expect(LeftoverScanner.classify("com.spotify.client", keys: keys) == .certain)
    #expect(LeftoverScanner.classify("com.spotify.client.plist", keys: keys) == .certain)
    #expect(LeftoverScanner.classify("com.spotify.client.helper", keys: keys) == .certain)
    #expect(LeftoverScanner.classify("COM.Spotify.Client-x", keys: keys) == .certain)
    #expect(LeftoverScanner.classify("com.spotify.clientx", keys: keys) == .probable)
    #expect(LeftoverScanner.classify("com.spotify.other", keys: keys) == .probable)
    #expect(LeftoverScanner.classify("spotify", keys: keys) == .certain)
    #expect(LeftoverScanner.classify("Spotify Data", keys: keys) == .probable)
    #expect(LeftoverScanner.classify("Spotifyish", keys: keys) == nil)
    #expect(LeftoverScanner.classify("ABCDE12345.com.spotify.client", keys: keys) == .certain)
    #expect(LeftoverScanner.classify("ABCDE12345.other", keys: keys) == .probable)
    #expect(LeftoverScanner.classify("Dropbox", keys: keys) == nil)
}

@Test func matchKeysRules() {
    let two = AppInfo(url: URL(fileURLWithPath: "/A/Ab.app"), bundleID: "org.ab", name: "Ab", executableName: "abcd")
    let k = MatchKeys(app: two)
    #expect(k.vendorPrefix == nil)
    #expect(k.names == ["abcd"])
    let dup = AppInfo(url: URL(fileURLWithPath: "/A/Zed.app"), bundleID: "dev.zed.Zed", name: "Zedit", executableName: "zedit")
    #expect(MatchKeys(app: dup).names == ["Zedit"])
}

@Test func vendorFolderMatchingAppNameIsProbableWithSibling() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    let podcasts = AppInfo(url: URL(fileURLWithPath: "/nonexistent/Podcasts.app"),
                           bundleID: "com.spotify.podcasts", name: "Spotify Podcasts")
    try fs.touch("Users/tester/Library/Application Support/Spotify/x")
    let r = scan(fs, app: spotify, installed: [spotify, podcasts])
    let item = try #require(find(r, "Application Support/Spotify"))
    #expect(item.confidence == .probable)
    #expect(item.note == "Spotify Podcasts da kullanıyor olabilir")
}

@Test func siblingTeamPrefixedGroupContainerIsNotListed() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    let other = AppInfo(url: URL(fileURLWithPath: "/nonexistent/Other.app"), bundleID: "com.spotify.other", name: "Other")
    try fs.touch("Users/tester/Library/Group Containers/ABCDE12345.com.spotify.other/x")
    try fs.touch("Users/tester/Library/Group Containers/ABCDE12345.com.spotify.client/x")
    let r = scan(fs, app: spotify, installed: [spotify, other])
    #expect(find(r, "ABCDE12345.com.spotify.other") == nil)
    #expect(find(r, "ABCDE12345.com.spotify.client")?.confidence == .certain)
}

@Test func nestedBundleIDsKeepOwnLeftovers() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    let chrome = AppInfo(url: URL(fileURLWithPath: "/nonexistent/Chrome.app"), bundleID: "com.google.Chrome", name: "Google Chrome")
    let canary = AppInfo(url: URL(fileURLWithPath: "/nonexistent/Canary.app"), bundleID: "com.google.Chrome.canary", name: "Chrome Canary")
    try fs.touch("Users/tester/Library/Caches/com.google.Chrome.canary/x")
    try fs.touch("Users/tester/Library/Caches/com.google.Chrome/x")
    let c = scan(fs, app: canary, installed: [chrome, canary])
    #expect(find(c, "Caches/com.google.Chrome.canary")?.confidence == .certain)
    #expect(find(c, "Caches/com.google.Chrome") == nil)
    let g = scan(fs, app: chrome, installed: [chrome, canary])
    #expect(find(g, "Caches/com.google.Chrome.canary") == nil)
    #expect(find(g, "Caches/com.google.Chrome")?.confidence == .certain)
}

@Test func audioPluginSubfoldersAreScanned() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    let zoom = AppInfo(url: URL(fileURLWithPath: "/nonexistent/zoom.us.app"), bundleID: "us.zoom.xos", name: "zoom.us")
    try fs.touch("Library/Audio/Plug-Ins/HAL/ZoomAudioDevice.driver/x")
    let r = scan(fs, app: AppInfo(url: zoom.url, bundleID: zoom.bundleID, name: "Zoom"))
    let item = try #require(find(r, "Plug-Ins/HAL/ZoomAudioDevice.driver"))
    #expect(item.kind == .plugin)
    #expect(item.requiresAdmin)
}
