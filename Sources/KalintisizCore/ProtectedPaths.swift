import Foundation

/// Asla listelenmeyen / dokunulmayan yollar.
public enum ProtectedPaths {
    private static let protectedPrefixes = [
        "/System", "/usr", "/bin", "/sbin", "/private/var/db", "/Library/Apple",
    ]
    private static let allowedExceptions = ["/usr/local"]

    public static func isProtected(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        var relative = path
        if rootPath != "/" {
            if path == rootPath { relative = "/" }
            else if path.hasPrefix(rootPath + "/") { relative = String(path.dropFirst(rootPath.count)) }
        }
        if !relative.hasPrefix("/") { relative = "/" + relative }

        if let last = relative.split(separator: "/").last, last.hasPrefix("com.apple.") { return true }
        if allowedExceptions.contains(where: { isWithin(relative, $0) }) { return false }
        return protectedPrefixes.contains { isWithin(relative, $0) }
    }

    public static func isAppleBundleID(_ id: String) -> Bool {
        id.hasPrefix("com.apple.")
    }

    private static func isWithin(_ path: String, _ prefix: String) -> Bool {
        path == prefix || path.hasPrefix(prefix + "/")
    }
}
