import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` ile paketsiz çalışırken pencerenin öne gelmesi için.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// Dock simgesine bırakılan uygulamalar.
    func application(_ application: NSApplication, open urls: [URL]) {
        model.handleDrop(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct KalintisizApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Kalıntısız", id: "main") {
            ContentView(model: delegate.model)
                .frame(minWidth: 760, minHeight: 480)
        }
    }
}

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if !model.hasFullDiskAccess && !model.onboardingSkipped {
                OnboardingView(model: model)
            } else {
                NavigationSplitView {
                    AppListView(model: model)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
                } detail: {
                    detail
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDrop(urls)
            return urls.contains { $0.pathExtension == "app" }
        }
        .restoreConflictAlert(model: model)
        .alert("Bir sorun oluştu", isPresented: $model.showsAlert) {
            Button("Tamam", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
        .alert("Geri yükleme tamamlandı", isPresented: $model.showsRestoreSummary) {
            Button("Tamam", role: .cancel) {}
        } message: {
            Text(model.restoreSummary ?? "")
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.selection {
        case .app:
            ScanDetailView(model: model)
        case .history:
            HistoryView(model: model)
        case nil:
            ContentUnavailableView {
                Label("Bir uygulama seçin", systemImage: "trash.square")
            } description: {
                Text("Kaldırmak istediğiniz uygulamayı listeden seçin ya da bu pencereye sürükleyin.")
            }
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
