import Foundation

/// Asla listelenmeyen / dokunulmayan yollar.
public enum ProtectedPaths {
    // Karşılaştırma küçük harfle yapılır (APFS varsayılan olarak büyük/küçük harf duyarsız).
    private static let protectedPrefixes = [
        "/system", "/usr", "/bin", "/sbin", "/private/var/db", "/library/apple",
    ]
    private static let allowedExceptions = ["/usr/local"]
    private static let privateAliases = ["/var", "/etc", "/tmp"]

    public static func isProtected(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        var relative = path
        if rootPath != "/" {
            if path == rootPath { relative = "/" }
            else if path.hasPrefix(rootPath + "/") { relative = String(path.dropFirst(rootPath.count)) }
        }
        if !relative.hasPrefix("/") { relative = "/" + relative }
        relative = relative.lowercased()
        // /var, /etc, /tmp aslında /private altındadır.
        if privateAliases.contains(where: { isWithin(relative, $0) }) { relative = "/private" + relative }

        if let last = relative.split(separator: "/").last, last.hasPrefix("com.apple.") { return true }
        if allowedExceptions.contains(where: { isWithin(relative, $0) }) { return false }
        return protectedPrefixes.contains { isWithin(relative, $0) }
    }

    public static func isAppleBundleID(_ id: String) -> Bool {
        id.lowercased().hasPrefix("com.apple.")
    }

    private static func isWithin(_ path: String, _ prefix: String) -> Bool {
        path == prefix || path.hasPrefix(prefix + "/")
    }
}
