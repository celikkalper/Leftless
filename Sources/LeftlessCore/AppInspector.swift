import Foundation

public enum AppInspectorError: Error, Equatable {
    case notAnAppBundle, missingInfoPlist, missingBundleIdentifier
}

public struct AppInspector: Sendable {
    private let commands: CommandRunning

    public init(commands: CommandRunning) {
        self.commands = commands
    }

    /// `includeTeamID: false` codesign çağrısını atlar (liste görünümü için hızlı yol).
    public func inspect(_ appURL: URL, includeTeamID: Bool = true) throws -> AppInfo {
        guard appURL.pathExtension == "app" else { throw AppInspectorError.notAnAppBundle }
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw AppInspectorError.missingInfoPlist }
        guard let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
            throw AppInspectorError.missingBundleIdentifier
        }
        let name = (plist["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (plist["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? appURL.deletingPathExtension().lastPathComponent
        return AppInfo(url: appURL, bundleID: bundleID, name: name,
                       executableName: plist["CFBundleExecutable"] as? String,
                       version: plist["CFBundleShortVersionString"] as? String,
                       teamID: includeTeamID ? teamID(of: appURL) : nil)
    }

    private func teamID(of appURL: URL) -> String? {
        guard let out = try? commands.run("/usr/bin/codesign", ["-dv", "--verbose=2", appURL.path]) else { return nil }
        for line in out.stderr.split(whereSeparator: \.isNewline) where line.hasPrefix("TeamIdentifier=") {
            let value = line.dropFirst("TeamIdentifier=".count).trimmingCharacters(in: .whitespaces)
            return (value.isEmpty || value == "not set") ? nil : value
        }
        return nil
    }
}
