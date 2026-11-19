import AppKit
import LeftlessCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel

    override init() {
        // Eski "Kalintisiz" geçmiş klasörü, model geçmişi okumadan önce taşınır; hata olursa geçmiş boş başlar.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        _ = try? HistoryMigration.migrateIfNeeded(applicationSupport: support)
        model = AppModel()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` ile paketsiz çalışırken pencerenin öne gelmesi için.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct LeftlessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Leftless", id: "main") {
            ContentView(model: delegate.model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .commands { TabCommands(model: delegate.model) }
    }
}

struct ContentView: View {
    @Bindable var model: AppModel

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

/// Segmented Apps / History switch in the toolbar; disabled while an uninstall or restore is running.
private struct TabPicker: View {
    @Bindable var model: AppModel

    private var historyTitle: String {
        let count = model.historyBadge
        return count > 0 ? String(localized: "History (\(count))") : String(localized: "History")
    }

    var body: some View {
        Picker("View", selection: Binding(get: { model.tab }, set: { model.switchTab($0) })) {
            Text("Apps").tag(MainTab.apps)
            Text(historyTitle).tag(MainTab.history)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(minWidth: 200)
        .disabled(model.isWorking)
    }
}

/// View menu items with ⌘1 / ⌘2.
struct TabCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Apps") { model.switchTab(.apps) }
                .keyboardShortcut("1")
                .disabled(model.isWorking || model.showsOnboarding)
            Button("History") { model.switchTab(.history) }
                .keyboardShortcut("2")
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
