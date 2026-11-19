import Testing
import Foundation
@testable import LeftlessCore

@Test func appleAndSystemPathsAreProtected() {
    let r = URL(fileURLWithPath: "/")
    #expect(ProtectedPaths.isProtected(URL(fileURLWithPath: "/System/Library/Foo"), root: r))
    #expect(ProtectedPaths.isProtected(URL(fileURLWithPath: "/usr/lib/x"), root: r))
    #expect(!ProtectedPaths.isProtected(URL(fileURLWithPath: "/usr/local/bin/x"), root: r))
    #expect(ProtectedPaths.isProtected(URL(fileURLWithPath: "/Users/a/Library/Preferences/com.apple.finder.plist"), root: r))
    #expect(!ProtectedPaths.isProtected(URL(fileURLWithPath: "/Users/a/Library/Caches/com.spotify.client"), root: r))
    #expect(ProtectedPaths.isAppleBundleID("com.apple.Safari"))
}

@Test func otherProtectedRootsAndFakeRoot() throws {
    let r = URL(fileURLWithPath: "/")
    for p in ["/bin/ls", "/sbin/x", "/private/var/db/receipts/a.plist", "/Library/Apple/foo", "/usr", "/System"] {
        #expect(ProtectedPaths.isProtected(URL(fileURLWithPath: p), root: r), "\(p)")
    }
    #expect(!ProtectedPaths.isProtected(URL(fileURLWithPath: "/Library/Application Support/Spotify"), root: r))
    #expect(!ProtectedPaths.isProtected(URL(fileURLWithPath: "/usr/local"), root: r))
    #expect(!ProtectedPaths.isAppleBundleID("com.applesauce.app"))

    let fake = try FakeSystem()
    defer { fake.cleanup() }
    let sys = try fake.touch("System/Library/x")
    let ok = try fake.touch("Users/tester/Library/Caches/com.spotify.client/a")
    #expect(ProtectedPaths.isProtected(sys, root: fake.root))
    #expect(!ProtectedPaths.isProtected(ok, root: fake.root))
}

@Test func protectionIsCaseInsensitive() {
    let r = URL(fileURLWithPath: "/")
    for p in ["/system/Library/x", "/SYSTEM/library", "/Library/APPLE/foo", "/USR/lib/x", "/Bin/ls",
              "/Users/a/Library/Preferences/COM.APPLE.finder.plist"] {
        #expect(ProtectedPaths.isProtected(URL(fileURLWithPath: p), root: r), "\(p)")
    }
    #expect(!ProtectedPaths.isProtected(URL(fileURLWithPath: "/USR/LOCAL/bin/x"), root: r))
    #expect(ProtectedPaths.isAppleBundleID("com.apple.Safari"))
}

@Test func varEtcTmpAreTreatedAsPrivate() {
    let r = URL(fileURLWithPath: "/")
    #expect(ProtectedPaths.isProtected(URL(fileURLWithPath: "/var/db/receipts/a.plist"), root: r))
    #expect(ProtectedPaths.isProtected(URL(fileURLWithPath: "/VAR/DB/x"), root: r))
    #expect(ProtectedPaths.isProtected(URL(fileURLWithPath: "/private/var/db"), root: r))
    #expect(!ProtectedPaths.isProtected(URL(fileURLWithPath: "/var/folders/ab/C/com.spotify.client"), root: r))
    #expect(!ProtectedPaths.isProtected(URL(fileURLWithPath: "/var/database/x"), root: r))
    #expect(!ProtectedPaths.isProtected(URL(fileURLWithPath: "/tmp/x"), root: r))
    #expect(!ProtectedPaths.isProtected(URL(fileURLWithPath: "/etc/hosts"), root: r))
}

@Test func appleDerivedContainersAreProtected() {
    let r = URL(fileURLWithPath: "/")
    for n in ["group.com.apple.notes", "ABCDE12345.groups.com.apple.podcasts", "Group.COM.Apple.Notes"] {
        #expect(ProtectedPaths.isProtected(URL(fileURLWithPath: "/Users/a/Library/Group Containers/\(n)"), root: r), "\(n)")
    }
    #expect(!ProtectedPaths.isProtected(URL(fileURLWithPath: "/Users/a/Library/Caches/com.applesauce.app"), root: r))
}
