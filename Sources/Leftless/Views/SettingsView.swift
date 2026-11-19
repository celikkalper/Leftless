import LeftlessCore
import SwiftUI

/// Settings window (⌘,): "Watch the Trash for deleted apps", off by default.
struct SettingsView: View {
    @Bindable var model: AppModel
    let watcher: TrashWatcher
    @AppStorage(TrashWatcher.settingKey) private var watchTrash = false
    @State private var isChanging = false
    @State private var problem: Problem?

    private enum Problem {
        case notificationsDenied, loginItemNeedsApproval, loginItemFailed, cannotReadTrash
    }

    var body: some View {
        Form {
            Section {
                Toggle("Watch the Trash for deleted apps", isOn: Binding(get: { watchTrash }, set: { change(to: $0) }))
                    .disabled(isChanging || (!watchTrash && !model.hasFullDiskAccess))
                Text("When you move an app to the Trash, Leftless lets you know if it left files behind, so you can review and remove them. Leftless opens at login, without a window, to keep watching.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.hasFullDiskAccess {
                    notice("Leftless needs Full Disk Access to see what's in the Trash.",
                           button: "Open Full Disk Access in System Settings") { FullDiskAccess.openSettings() }
                }
                if let problem { problemNotice(problem) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refreshFullDiskAccess() }
    }

    @ViewBuilder private func problemNotice(_ problem: Problem) -> some View {
        switch problem {
        case .notificationsDenied:
            notice("Notifications are turned off for Leftless. Turn them on in System Settings, then try again.",
                   button: "Open System Settings") { TrashNotifications.openSettings() }
        case .loginItemNeedsApproval:
            notice("Allow Leftless in Login Items so it can keep watching after you log in. Until then, it watches while it's open.",
                   button: "Open Login Items Settings") { LoginItem.openSettings() }
        case .loginItemFailed:
            notice("Leftless couldn't be added to Login Items, so it watches only while it's open.",
                   button: "Open Login Items Settings") { LoginItem.openSettings() }
        case .cannotReadTrash:
            notice("Leftless can't read the Trash. Check Full Disk Access, then try again.",
                   button: "Open Full Disk Access in System Settings") { FullDiskAccess.openSettings() }
        }
    }

    private func notice(_ text: LocalizedStringKey, button: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .fixedSize(horizontal: false, vertical: true)
            Button(button, action: action)
        }
    }

    private func change(to on: Bool) {
        guard !isChanging, on != watchTrash else { return }
        problem = nil
        guard on else {
            watcher.disable()
            watchTrash = false
            return
        }
        isChanging = true
        Task {
            defer { isChanging = false }
            switch await watcher.enable() {
            case .watching: watchTrash = true
            case .loginItemNeedsApproval: watchTrash = true; problem = .loginItemNeedsApproval
            case .loginItemFailed: watchTrash = true; problem = .loginItemFailed
            case .notificationsDenied: watchTrash = false; problem = .notificationsDenied
            case .cannotReadTrash: watchTrash = false; problem = .cannotReadTrash
            }
        }
    }
}
