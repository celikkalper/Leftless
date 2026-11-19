import Testing
import Foundation
@testable import LeftlessCore

private func env(_ fs: FakeSystem) -> ScanEnvironment {
    ScanEnvironment(root: fs.root, home: fs.home, userCacheDir: nil, uid: 501)
}

private func lib(_ relative: String) -> String { "Users/tester/Library/" + relative }

private func writePlist(_ fs: FakeSystem, _ relative: String, _ dict: [String: Any]) throws {
    let url = try fs.touch(relative)
    try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: url)
}

private func scan(_ fs: FakeSystem, known: Set<String>, names: [String] = [],
                  restricted: Bool = false) -> OrphanScanResult {
    OrphanScanner(environment: env(fs), knownApps: KnownApps(bundleIDs: known, names: names),
                  restricted: restricted).scan()
}

private func names(_ r: OrphanScanResult) -> Set<String> {
    Set(r.groups.flatMap(\.items).map(\.url.lastPathComponent))
}

@Test func listsReverseDNSItemsOfUnknownApps() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    try fs.touch(lib("Application Support/com.vendor.soundwave/data"), bytes: 100)
    try fs.touch(lib("Preferences/com.vendor.soundwave.plist"))
    try fs.touch(lib("Caches/com.vendor.soundwave/cache.db"))
    try fs.touch(lib("Saved Application State/com.vendor.soundwave.savedState/x"))
    try fs.touch(lib("Cookies/com.vendor.soundwave.binarycookies"))
    let r = scan(fs, known: ["com.other.app"])
    let group = try #require(r.groups.first)
    #expect(r.groups.count == 1)
    #expect(group.id == "com.vendor.soundwave")
    #expect(group.displayName == "Soundwave")
    #expect(group.items.count == 5)
    #expect(Set(group.items.map(\.kind)) == [.applicationSupport, .preferences, .caches, .savedState, .cookies])
    #expect(group.items.allSatisfy { $0.confidence == .probable })
    #expect(group.totalSize == group.items.reduce(0) { $0 + $1.size })
    #expect(group.totalSize > 0)
    #expect(r.skippedLocations.isEmpty)
}

@Test func skipsInstalledAppAndItsHelpers() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    try fs.touch(lib("Application Support/com.acme.editor/x"))
    try fs.touch(lib("Caches/com.acme.editor.helper/x"))
    try fs.touch(lib("Preferences/com.acme.editor.plist"))
    try fs.touch(lib("Preferences/ByHost/com.acme.editor.0A1B2C3D.plist"))
    try fs.touch(lib("Caches/com.gone.tool/x"))
    let r = scan(fs, known: ["com.acme.editor"])
    #expect(names(r) == ["com.gone.tool"])
}

@Test func skipsVendorSiblings() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    try fs.touch(lib("Application Support/com.acme.oldapp/x"))
    try fs.touch(lib("Caches/com.acme.updater/x"))
    let r = scan(fs, known: ["com.acme.editor"])
    #expect(r.groups.isEmpty)
}

@Test func teamPrefixedGroupContainerMatchedByID() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    try fs.touch(lib("Group Containers/ABCDE12345.com.acme.editor/x"))
    try fs.touch(lib("Group Containers/ABCDE12345.com.gone.app/x"))
    try fs.touch(lib("Group Containers/ABCDE12345.group.com.gone.app/x"))   // "group." öneki: reverse-DNS değil
    try fs.touch(lib("Containers/com.gone.app/Data/x"))
    let r = scan(fs, known: ["com.acme.editor"])
    #expect(names(r) == ["ABCDE12345.com.gone.app", "com.gone.app"])
    let group = try #require(r.groups.first)
    #expect(r.groups.count == 1)
    #expect(group.id == "com.gone.app")
    #expect(Set(group.items.map(\.kind)) == [.groupContainer, .container])
}

@Test func skipsAppleAndProtected() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    try fs.touch(lib("Preferences/com.apple.finder.plist"))
    try fs.touch(lib("Caches/com.apple.Safari/x"))
    try fs.touch(lib("Group Containers/group.com.apple.notes/x"))
    try fs.touch(lib("Group Containers/2BUA8C4S2C.com.apple.something/x"))
    try writePlist(fs, lib("LaunchAgents/com.apple.foo.plist"),
                   ["Label": "com.apple.foo", "Program": "/Applications/Missing.app/Contents/MacOS/x"])
    try writePlist(fs, lib("LaunchAgents/odd.plist"),
                   ["Label": "com.apple.bar", "Program": "/Applications/Missing.app/Contents/MacOS/x"])
    #expect(scan(fs, known: []).groups.isEmpty)
}

@Test func skipsNonReverseDNSNames() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    try fs.touch(lib("Application Support/SoundWave/x"))
    try fs.touch(lib("Application Support/vendor.app/x"))          // 2 bileşen
    try fs.touch(lib("Caches/xyz.vendor.app/x"))                   // bilinmeyen ilk bileşen
    try fs.touch(lib("Preferences/.GlobalPreferences.plist"))
    try fs.touch(lib("Logs/DiagnosticReports/x"))
    try fs.touch(lib("Containers/3F1A2B3C-0000-1111-2222-333344445555/x"))
    #expect(scan(fs, known: []).groups.isEmpty)
}

@Test func launchAgentWithMissingProgramIsOrphan() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    let existing = try fs.touch("Applications/Here.app/Contents/MacOS/here")
    // Adı sahipli (bilinen kimlik) ama programı yok → yetim.
    try writePlist(fs, lib("LaunchAgents/com.acme.editor.agent.plist"),
                   ["Label": "com.acme.editor.agent", "ProgramArguments": ["/Applications/Gone.app/Contents/MacOS/x", "-d"]])
    // Reverse-DNS olmayan ad, eksik program → yetim.
    try writePlist(fs, lib("LaunchAgents/updater.plist"),
                   ["Label": "updater", "Program": "/usr/local/bin/gone-updater"])
    // Program var → adı ne olursa olsun listelenmez.
    let existingPath = "/" + existing.path.dropFirst(fs.root.path.count + 1)
    try writePlist(fs, lib("LaunchAgents/com.acme.editor.helper.plist"),
                   ["Label": "com.acme.editor.helper", "Program": existingPath])
    try writePlist(fs, lib("LaunchAgents/com.unknown.vendor.agent.plist"),
                   ["Label": "com.unknown.vendor.agent", "ProgramArguments": [existingPath]])
    // Reverse-DNS olmayan dosya adı, reverse-DNS etiket: etiketin köküyle gruplanır.
    try writePlist(fs, lib("LaunchAgents/oddname.plist"),
                   ["Label": "com.gone.thing.agent", "Program": "/Applications/Gone.app/Contents/MacOS/y"])
    // Sistem yolundaki program (sahte kökte yok) → var sayılır.
    try writePlist(fs, lib("LaunchAgents/local.system.plist"),
                   ["Label": "local.system", "ProgramArguments": ["/usr/bin/true"]])
    try writePlist(fs, lib("LaunchAgents/local.lib.plist"),
                   ["Label": "local.lib", "Program": "/Library/Apple/usr/bin/x"])
    // Göreli program yolu çözülemez → sahipli sayılır.
    try writePlist(fs, lib("LaunchAgents/local.rel.plist"), ["Label": "local.rel", "Program": "bin/x"])
    // Reverse-DNS ve bilinmeyen → yetim (program olmasa da).
    try writePlist(fs, lib("LaunchAgents/com.gone.sync.plist"), ["Label": "com.gone.sync"])

    let r = scan(fs, known: ["com.acme.editor"])
    #expect(names(r) == ["com.acme.editor.agent.plist", "updater.plist", "com.gone.sync.plist", "oddname.plist"])
    #expect(r.groups.contains { $0.id == "com.gone.thing" && $0.items.map(\.url.lastPathComponent) == ["oddname.plist"] })
    let items = r.groups.flatMap(\.items)
    #expect(items.allSatisfy { $0.kind == .launchAgent })
    let agent = try #require(items.first { $0.url.lastPathComponent == "com.acme.editor.agent.plist" })
    #expect(agent.launchdLabel == "com.acme.editor.agent")
    let updaterGroup = try #require(r.groups.first { $0.items.contains { $0.url.lastPathComponent == "updater.plist" } })
    #expect(updaterGroup.id == "updater")
    #expect(updaterGroup.displayName == "Updater")
}

@Test func restrictedSkipsContainers() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    try fs.touch(lib("Containers/com.gone.app/Data/x"))
    try fs.touch(lib("Group Containers/ABCDE12345.com.gone.app/x"))
    try fs.touch(lib("Cookies/com.gone.app.binarycookies"))
    try fs.touch(lib("Caches/com.gone.app/x"))
    let r = scan(fs, known: [], restricted: true)
    #expect(names(r) == ["com.gone.app"])
    #expect(r.groups.flatMap(\.items).allSatisfy { $0.kind == .caches })
    #expect(r.skippedLocations == [LeftoverScanner.containersDisplayName, LeftoverKind.cookies.displayName])
}

@Test func groupsSortedBySize() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    try fs.touch(lib("Caches/com.small.app/x"), bytes: 10)
    try fs.touch(lib("Caches/com.big.app/x"), bytes: 500_000)
    try fs.touch(lib("Application Support/com.mid.app/x"), bytes: 50_000)
    try fs.touch(lib("Preferences/com.big.app.extra.plist"), bytes: 10)
    let r = scan(fs, known: [])
    #expect(r.groups.map(\.id) == ["com.big.app", "com.mid.app", "com.small.app"])
    #expect(r.groups[0].items.count == 2)
    let sizes = r.groups.map(\.totalSize)
    #expect(sizes == sizes.sorted(by: >))
}

@Test func allItemsUnticked() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    try fs.touch(lib("Caches/com.gone.app/x"))
    try fs.touch(lib("Preferences/com.gone.app.plist"))
    try writePlist(fs, lib("LaunchAgents/com.gone.app.agent.plist"), ["Label": "com.gone.app.agent"])
    let items = scan(fs, known: []).groups.flatMap(\.items)
    #expect(items.count == 3)
    #expect(items.allSatisfy { !$0.selectedByDefault && $0.confidence == .probable })
}

@Test func knownBundleIDsIncludeNestedAppleAndSpotlightApps() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    let apps = fs.root.appendingPathComponent("Applications")
    try fs.makeApp(name: "Top", bundleID: "com.top.app")
    try fs.makeApp(name: "Util", bundleID: "com.util.app", in: apps.appendingPathComponent("Utilities"))
    try fs.makeApp(name: "Deep", bundleID: "com.deep.app", in: apps.appendingPathComponent("A/B"))
    try fs.makeApp(name: "Mine", bundleID: "com.mine.app", in: fs.home.appendingPathComponent("Applications"))
    try fs.makeApp(name: "Notes", bundleID: "com.apple.Notes", in: fs.root.appendingPathComponent("System/Applications"))
    let elsewhere = try fs.makeApp(name: "Far", bundleID: "com.far.app", in: fs.root.appendingPathComponent("Opt"))
    let output = CommandOutput(status: 0, stdout: "\(elsewhere.path)\n\(fs.root.path)/Nope.app\n\n", stderr: "")
    let runner = FakeRunner(output: output)
    let ids = InstalledApps(environment: env(fs), inspector: AppInspector(commands: runner))
        .allKnownBundleIDs(commands: runner)
    #expect(ids == ["com.top.app", "com.util.app", "com.deep.app", "com.mine.app", "com.apple.Notes", "com.far.app"])
    #expect(runner.calls.first?.first == "/usr/bin/mdfind")
}

@Test func knownBundleIDsSurviveMdfindFailure() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    try fs.makeApp(name: "Top", bundleID: "com.top.app")
    let runner = FakeRunner(output: CommandOutput(status: 1, stdout: "garbage", stderr: "error"))
    let ids = InstalledApps(environment: env(fs), inspector: AppInspector(commands: runner))
        .allKnownBundleIDs(commands: runner)
    #expect(ids == ["com.top.app"])
}

// MARK: - Gerçek yanlış pozitifler (inceleme turu 1)

@Test func ownedByKnownAppName() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    try fs.makeApp(name: "CapCut", bundleID: "com.lemon.lvoverseas")
    try fs.makeApp(name: "Docker", bundleID: "com.docker.docker", executable: "com.docker.docker")
    try fs.makeApp(name: "Riot Client", bundleID: "com.riotgames.RiotGames.RiotClient", executable: "RiotClientServices")
    try fs.touch(lib("Preferences/com.capcut.CapCut.plist"))
    try fs.touch(lib("Preferences/com.electron.dockerdesktop.plist"))
    try fs.touch(lib("Caches/com.riot.riotclient/x"))
    try fs.touch(lib("Application Support/com.oldvendor.goneapp/x"))   // gerçek yetim: hâlâ listelenir
    let runner = FakeRunner(output: CommandOutput(status: 1, stdout: "", stderr: ""))
    let known = InstalledApps(environment: env(fs), inspector: AppInspector(commands: runner)).knownApps(commands: runner)
    #expect(known.names.isSuperset(of: ["capcut", "docker", "riotclient", "riotclientservices", "comdockerdocker"]))
    let r = OrphanScanner(environment: env(fs), knownApps: known).scan()
    #expect(names(r) == ["com.oldvendor.goneapp"])
    #expect(r.groups.map(\.id) == ["com.oldvendor.goneapp"])
}

@Test func dockerElectronPrefOwnedByDenylistAlone() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    try fs.touch(lib("Preferences/com.electron.dockerdesktop.plist"))
    #expect(scan(fs, known: []).groups.isEmpty)
}

@Test func launchAgentWithExistingProgramIsOwned() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    let program = try fs.touch("Users/Shared/Riot Games/Riot Client.app/Contents/MacOS/RiotClientServices")
    try writePlist(fs, lib("LaunchAgents/com.riot.riotclient.checkinstalls.plist"),
                   ["Label": "com.riot.riotclient.checkinstalls",
                    "ProgramArguments": ["/" + program.path.dropFirst(fs.root.path.count + 1), "--check"]])
    #expect(scan(fs, known: []).groups.isEmpty)
}

@Test func sharedToolchainAndSDKCachesOwned() throws {
    let fs = try FakeSystem(); defer { fs.cleanup() }
    for name in ["org.swift.swiftpm", "io.branch.network.cache", "org.llvm.clang", "com.crashlytics.data",
                 "io.fabric.sdk.mac.data", "com.plausiblelabs.crashreporter.data", "com.github.Squirrel.x",
                 "org.sparkle-project.Sparkle", "com.google.Keystone.Agent", "com.microsoft.autoupdate2",
                 "com.adobe.accmac", "org.chromium.chromoting"] {
        try fs.touch(lib("Caches/\(name)/x"))
    }
    try fs.touch(lib("Caches/com.oldvendor.goneapp/x"))
    #expect(names(scan(fs, known: [])) == ["com.oldvendor.goneapp"])
}

@Test func knownAppNamesIgnoreGenericAndShort() {
    let k = KnownApps(bundleIDs: [], names: ["Electron", "Helper", "App", "Foo", "Riot Client", "Sound-Wave 2"])
    #expect(k.names == ["riotclient", "soundwave2"])
}
