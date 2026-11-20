import AppKit
import LeftlessCore
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    let trashWatcher = TrashWatcher()
    /// Launched at login with Trash watching on: no window and no Dock icon until the user opens Leftless
    /// (or clicks a notification). Whenever Trash watching is on (started at launch or turned on later),
    /// closing the main window goes back to the background instead of quitting; ⌘Q still quits.
    private var runsInBackground = false
    private var launchedAtLogin = false
    private weak var mainWindow: NSWindow?
    private var openMainWindow: OpenWindowAction?
    private var mainWindowCloseObserver: (any NSObjectProtocol)?

    override init() {
        // Eski "Kalintisiz" geçmiş klasörü, model geçmişi okumadan önce taşınır; hata olursa geçmiş boş başlar.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        _ = try? HistoryMigration.migrateIfNeeded(applicationSupport: support)
        model = AppModel()
        super.init()
        model.trashWatcher = trashWatcher
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The delegate must be set before launching finishes to receive a click that launched the app.
        if TrashNotifications.isAvailable {
            UNUserNotificationCenter.current().delegate = self
            TrashNotifications.registerCategory()
        }
        launchedAtLogin = LoginItem.isLaunchEventFromLogin()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchedAtLogin = launchedAtLogin || LoginItem.isLaunchEventFromLogin()
        let watching = trashWatcher.startIfEnabled()
        if launchedAtLogin && watching {
            runsInBackground = true
            NSApp.setActivationPolicy(.accessory)
            hideMainWindow()
        } else {
            // `swift run` ile paketsiz çalışırken pencerenin öne gelmesi için.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        #if DEBUG
        _ = Screenshots.runIfRequested()
        #endif
    }

    /// Dock simgesine bırakılan uygulamalar.
    func application(_ application: NSApplication, open urls: [URL]) {
        model.handleDrop(urls)
    }

    /// Atlanan izin sonradan verilirse sarı şerit kalksın diye her öne gelişte yeniden kontrol edilir.
    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshFullDiskAccess()
        // Full Disk Access granted later: start watching if the setting is on.
        if !trashWatcher.isWatching { trashWatcher.startIfEnabled() }
    }

    /// Opening Leftless again (Finder, Launchpad, Dock) shows the window, also after a login launch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !trashWatcher.isWatching
    }

    // MARK: - Main window

    /// Called by the main window's content whenever it is put in a window.
    func mainWindowAppeared(_ window: NSWindow, openWindow: OpenWindowAction) {
        openMainWindow = openWindow
        guard window !== mainWindow else { return }
        mainWindow = window
        if let mainWindowCloseObserver { NotificationCenter.default.removeObserver(mainWindowCloseObserver) }
        mainWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.mainWindowWillClose() }
        }
        if runsInBackground && NSApp.activationPolicy() == .accessory { hideMainWindow() }
    }

    /// While watching the Trash, closing the main window keeps Leftless running without a Dock icon (unless
    /// another window, e.g. Settings, is still open; then it stays a regular app until quit).
    private func mainWindowWillClose() {
        guard trashWatcher.isWatching else { return }
        let window = mainWindow
        let othersVisible = NSApp.windows.contains { $0 !== window && $0.isVisible && $0.canBecomeMain }
        guard !othersVisible else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Closes the window at a login launch (on the next run-loop pass: it may still be setting up).
    private func hideMainWindow() {
        guard let window = mainWindow else { return }
        DispatchQueue.main.async {
            guard NSApp.activationPolicy() == .accessory else { return }
            window.close()
        }
    }

    /// Brings the main window forward (opening it again if it was closed) as a regular app with a Dock icon.
    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if let window = mainWindow, window.isVisible || window.isMiniaturized {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if let openMainWindow {
            openMainWindow(id: "main")
        } else {
            mainWindow?.makeKeyAndOrderFront(nil)
        }
    }

    /// A Trash-watch notification (or its Clean Up button): show that app's leftovers for review.
    private func reviewTrashedApp(at path: String) {
        showMainWindow()
        Task { await model.reviewTrashedApp(at: URL(fileURLWithPath: path)) }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier,
              let path = response.notification.request.content.userInfo[TrashNotifications.pathKey] as? String
        else { return }
        await reviewTrashedApp(at: path)
    }
}

@main
struct LeftlessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Leftless", id: "main") {
            ContentView(model: delegate.model) { [delegate] window, openWindow in
                delegate.mainWindowAppeared(window, openWindow: openWindow)
            }
                .frame(minWidth: 760, minHeight: 480)
        }
        .commands { TabCommands(model: delegate.model) }

        Settings {
            SettingsView(model: delegate.model, watcher: delegate.trashWatcher)
        }
    }
}

struct ContentView: View {
    @Bindable var model: AppModel
    /// Reports the window the view is shown in (main window only; not used for screenshots).
    var onWindow: ((NSWindow, OpenWindowAction) -> Void)?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if model.showsOnboarding {
                OnboardingView(model: model)
            } else {
                mainContent
                    .toolbar {
                        ToolbarItem(placement: .principal) { TabPicker(model: model) }
                    }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDrop(urls)
            return urls.contains { $0.pathExtension == "app" }
        }
        .background {
            if let onWindow {
                WindowReader { onWindow($0, openWindow) }
            }
        }
        .restoreConflictAlert(model: model)
        .alert("Something Went Wrong", isPresented: $model.showsAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
        .alert("Restore Complete", isPresented: $model.showsRestoreSummary) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.restoreSummary ?? "")
        }
    }

    @ViewBuilder private var mainContent: some View {
        switch model.tab {
        case .apps:
            NavigationSplitView {
                AppListView(model: model)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            } detail: {
                detail
            }
        case .leftovers:
            OrphansView(model: model)
        case .history:
            HistoryView(model: model)
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.selectedApps.count {
        case 1:
            ScanDetailView(model: model)
        case 2...:
            BatchDetailView(model: model)
        default:
            ContentUnavailableView {
                Label("Select an App", systemImage: "trash.square")
            } description: {
                Text("Choose the app you want to uninstall from the list, or drag it into this window.")
            }
        }
    }
}

/// Calls `onWindow` with the window its view is placed in.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onWindow = onWindow
    }

    final class ReaderView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

/// Segmented Apps / Leftovers / History switch in the toolbar; disabled while an uninstall or restore is running.
private struct TabPicker: View {
    @Bindable var model: AppModel

    private var historyTitle: String {
        let count = model.historyBadge
        return count > 0 ? String(localized: "History (\(count))") : String(localized: "History")
    }

    var body: some View {
        Picker("View", selection: Binding(get: { model.tab }, set: { model.switchTab($0) })) {
            Text("Apps").tag(MainTab.apps)
            Text("Leftovers").tag(MainTab.leftovers)
            Text(historyTitle).tag(MainTab.history)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(minWidth: 300)
        .disabled(model.isWorking)
    }
}

/// View menu items with ⌘1 / ⌘2 / ⌘3.
struct TabCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Apps") { model.switchTab(.apps) }
                .keyboardShortcut("1")
                .disabled(model.isWorking || model.showsOnboarding)
            Button("Leftovers") { model.switchTab(.leftovers) }
                .keyboardShortcut("2")
                .disabled(model.isWorking || model.showsOnboarding)
            Button("History") { model.switchTab(.history) }
                .keyboardShortcut("3")
                .disabled(model.isWorking || model.showsOnboarding)
        }
    }
}

extension AppModel {
    // Alert'lerin `isPresented` bağlamaları: kapatılınca ilgili değer temizlenir.
    var showsAlert: Bool {
        get { alertMessage != nil }
        set { if !newValue { alertMessage = nil } }
    }
    var showsRestoreSummary: Bool {
        get { restoreSummary != nil }
        set { if !newValue { restoreSummary = nil } }
    }
    var showsRestoreConflicts: Bool {
        get { pendingRestore != nil }
        set { if !newValue { pendingRestore = nil } }
    }
}
