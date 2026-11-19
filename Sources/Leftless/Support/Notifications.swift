import AppKit
import UserNotifications

/// Notifications about apps moved to the Trash that left files behind.
enum TrashNotifications {
    static let categoryID = "trashedApp"
    static let cleanUpActionID = "cleanUp"
    /// userInfo key holding the trashed app's path.
    static let pathKey = "path"

    /// Notifications (and login items) only work in a real app bundle; `swift run` has none.
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Registers the "Clean Up" action. Call before the app finishes launching, after setting the delegate.
    static func registerCategory() {
        guard isAvailable else { return }
        let cleanUp = UNNotificationAction(identifier: cleanUpActionID, title: String(localized: "Clean Up"),
                                           options: [.foreground])
        let category = UNNotificationCategory(identifier: categoryID, actions: [cleanUp], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Asks for permission to show alerts with sound. False if the user declined (now or earlier).
    static func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        let center = UNUserNotificationCenter.current()
        if (try? await center.requestAuthorization(options: [.alert, .sound])) == true { return true }
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    /// "SoundWave left 14 items" with the total size; one notification per trashed app (same id replaces).
    static func post(appName: String, count: Int, size: Int64, trashedPath: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(appName) left \(count) items")
        let formattedSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        content.body = String(localized: "They take up \(formattedSize). Click Clean Up to review them.")
        content.sound = .default
        content.categoryIdentifier = categoryID
        content.userInfo = [pathKey: trashedPath]
        let request = UNNotificationRequest(identifier: "trashedApp:" + trashedPath, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// System Settings > Notifications, on Leftless's page when possible.
    static func openSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.leftless.app"
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
