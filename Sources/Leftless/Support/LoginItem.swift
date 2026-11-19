import AppKit
import ServiceManagement

/// Leftless as a login item (`SMAppService.mainApp`), used while "Watch the Trash" is on.
enum LoginItem {
    enum RegisterResult {
        case enabled
        /// Registered, but the user has to allow it in System Settings > General > Login Items.
        case requiresApproval
        case failed
    }

    static func register() -> RegisterResult {
        guard TrashNotifications.isAvailable else { return .failed }
        let service = SMAppService.mainApp
        if service.status != .enabled {
            do { try service.register() } catch {
                return service.status == .requiresApproval ? .requiresApproval : .failed
            }
        }
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        default: return .failed
        }
    }

    static func unregister() {
        guard TrashNotifications.isAvailable, SMAppService.mainApp.status != .notRegistered else { return }
        try? SMAppService.mainApp.unregister()
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Whether the current Apple event is the launch event of a login item. Read while the app is launching.
    static func isLaunchEventFromLogin() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == kCoreEventClass, event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
