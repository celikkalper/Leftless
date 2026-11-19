import Foundation

/// LaunchAgents / LaunchDaemons plist'lerini uygulamayla eşleştirir.
public struct LaunchdScanner: Sendable {
    private let environment: ScanEnvironment

    public init(environment: ScanEnvironment) {
        self.environment = environment
    }

    public func scan(_ app: AppInfo, keys: MatchKeys, installedApps: [AppInfo] = []) -> [Leftover] {
        let dirs: [(URL, LeftoverKind, Bool)] = [
            (environment.homePath("Library/LaunchAgents"), .launchAgent, false),
            (environment.path("/Library/LaunchAgents"), .launchAgent, true),
            (environment.path("/Library/LaunchDaemons"), .launchDaemon, true),
        ]
        var result: [Leftover] = []
        for (dir, kind, admin) in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "plist" {
                guard !ProtectedPaths.isProtected(file, root: environment.root),
                      let data = try? Data(contentsOf: file),
                      let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
                else { continue }

                var confidence: Confidence?
                var note: String?
                if pointsIntoApp(plist, app: app, keys: keys, installedApps: installedApps) {
                    confidence = .certain
                } else if let r = LeftoverScanner.evaluate(file.lastPathComponent, app: app, keys: keys,
                                                           installedApps: installedApps) {
                    (confidence, note) = r
                }
                guard let confidence else { continue }
                result.append(Leftover(url: file, kind: kind, confidence: confidence, size: directorySize(file),
                                       requiresAdmin: admin, launchdLabel: plist["Label"] as? String, note: note))
            }
        }
        return result
    }

    private func pointsIntoApp(_ plist: [String: Any], app: AppInfo, keys: MatchKeys, installedApps: [AppInfo]) -> Bool {
        let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
        guard let program, !program.isEmpty else { return false }
        if program.hasPrefix(app.url.path + "/") { return true }
        let bundleID = keys.bundleID.lowercased()
        let lowered = program.lowercased()
        guard !bundleID.isEmpty, lowered.contains(bundleID) else { return false }
        // Daha spesifik bir kimliğe sahip başka bir yüklü uygulama da eşleşiyorsa (Chrome / Chrome.canary) o ona aittir.
        let moreSpecific = installedApps.contains {
            let other = $0.bundleID.lowercased()
            return other != bundleID && other.count > bundleID.count && lowered.contains(other)
        }
        return !moreSpecific
    }
}
