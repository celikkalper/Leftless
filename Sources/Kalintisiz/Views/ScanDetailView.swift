import AppKit
import KalintisizCore
import SwiftUI

struct ScanDetailView: View {
    @Bindable var model: AppModel
    @State private var confirming = false
    @State private var askingToQuit = false

    var body: some View {
        VStack(spacing: 0) {
            if !model.hasFullDiskAccess {
                fullDiskAccessBanner
            }
            if let outcome = model.lastOutcome {
                UninstallResultView(model: model, outcome: outcome)
            } else if let scan = model.scan {
                header(scan)
                Divider()
                if !scan.systemExtensions.isEmpty {
                    systemExtensionBox(scan.systemExtensions)
                }
                LeftoverListView(model: model, groups: LeftoverGrouping.groups(scan.leftovers))
                Divider()
                footer(scan)
            } else {
                ProgressView("Kalıntılar aranıyor…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert("Çöp Sepeti'ne Taşı", isPresented: $confirming) {
            Button("Taşı") { startUninstall() }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
        .alert("\(appName) açık. Kapatılsın mı?", isPresented: $askingToQuit) {
            Button("Kapat") {
                Task {
                    if await model.quitSelectedApp() {
                        await model.uninstall()
                    } else {
                        model.alertMessage = "\(appName) kapatılamadı. Lütfen uygulamayı kapatıp yeniden deneyin."
                    }
                }
            }
            Button("Vazgeç", role: .cancel) {}
        }
    }

    private var appName: String { model.scan?.app.name ?? "" }

    private var confirmationMessage: String {
        let s = model.summary
        let size = AppModel.formatSize(s.totalSize)
        let what: String
        switch (s.includesApp, s.otherCount) {
        case (true, 0): what = appName
        case (true, let n): what = "\(appName) ve \(n) öğe"
        case (false, let n): what = "\(n) öğe"
        }
        return "\(what) Çöp Sepeti'ne taşınacak (\(size)). Geçmiş'ten geri alabilirsiniz."
    }

    private func startUninstall() {
        if model.isSelectedAppRunning {
            askingToQuit = true
        } else {
            Task { await model.uninstall() }
        }
    }

    private func header(_ scan: ScanResult) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: scan.app.url.path))
                .resizable()
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(scan.app.name).font(.title2.bold())
                if let version = scan.app.version {
                    Text("Sürüm \(version)").foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(AppModel.formatSize(model.summary.totalSize))
                    .font(.title2.monospacedDigit())
                Text("seçili").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Seçili toplam boyut \(AppModel.formatSize(model.summary.totalSize))")
        }
        .padding()
    }

    private func systemExtensionBox(_ extensions: [String]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Bu uygulamaya veya üreticisine ait bir sistem uzantısı bulundu; macOS bunu Sistem Ayarları > Genel > Giriş Öğeleri ve Uzantılar üzerinden kaldırır.")
                    .fixedSize(horizontal: false, vertical: true)
                Text(extensions.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .padding([.horizontal, .top])
        .accessibilityElement(children: .combine)
    }

    private func footer(_ scan: ScanResult) -> some View {
        HStack {
            Text("\(model.summary.totalCount) / \(scan.leftovers.count) öğe seçili")
                .foregroundStyle(.secondary)
            Spacer()
            if model.isWorking {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("İşlem sürüyor")
            }
            Button("Çöp Sepeti'ne Taşı") { confirming = true }
                .buttonStyle(.borderedProminent)
                .disabled(model.summary.isEmpty || model.isWorking)
                .keyboardShortcut(.delete, modifiers: .command)
                .accessibilityLabel("Seçili öğeleri Çöp Sepeti'ne taşı")
        }
        .padding()
    }

    private var fullDiskAccessBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .accessibilityHidden(true)
            Text("Tam Disk Erişimi yok; bazı kalıntılar görünmeyebilir")
            Spacer()
            Button("İzin Ver") { model.onboardingSkipped = false }
                .accessibilityLabel("Tam Disk Erişimi izni ver")
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.yellow.opacity(0.35))
    }
}
