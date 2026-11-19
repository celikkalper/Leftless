import Testing
import Foundation
@testable import KalintisizCore

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
