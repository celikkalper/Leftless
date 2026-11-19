import AppKit

@MainActor
enum AppTerminator {
    static func runningInstances(bundleID: String) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }
    }

    /// Nazikçe kapatır; `timeout` saniye içinde kapanmazsa zorla kapatır. Hepsi kapandıysa `true`.
    static func quit(bundleID: String, timeout: TimeInterval = 5) async -> Bool {
        let instances = runningInstances(bundleID: bundleID)
        guard !instances.isEmpty else { return true }
        instances.forEach { $0.terminate() }
        if await waitUntilTerminated(instances, seconds: timeout) { return true }
        instances.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        return await waitUntilTerminated(instances, seconds: 2)
    }

    private static func waitUntilTerminated(_ apps: [NSRunningApplication], seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if apps.allSatisfy(\.isTerminated) { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return apps.allSatisfy(\.isTerminated)
    }
}
