import AppKit
import KalintisizCore
import SwiftUI

struct ScanDetailView: View {
    @Bindable var model: AppModel
    /// Onay anında dondurulan plan; diyaloglar ve kaldırma yalnızca bunu kullanır.
    @State private var confirmPlan: UninstallPlan?
    @State private var quitPlan: UninstallPlan?

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
                    .disabled(model.isWorking)
                Divider()
                footer(scan)
            } else {
                ProgressView("Kalıntılar aranıyor…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert("Çöp Sepeti'ne Taşı", isPresented: presence($confirmPlan), presenting: confirmPlan) { plan in
            Button("Taşı") { proceed(with: plan) }
            Button("Vazgeç", role: .cancel) {}
        } message: { plan in
            Text(plan.summary.confirmationText(appName: plan.scan.app.name,
                                               formattedSize: AppModel.formatSize(plan.summary.totalSize)))
        }
        .alert(quitTitle, isPresented: presence($quitPlan), presenting: quitPlan) { plan in
            Button("Kapat") { Task { await model.uninstall(plan, quitFirst: true) } }
            Button("Vazgeç", role: .cancel) {}
        }
    }

    private var quitTitle: String {
        "\(quitPlan?.scan.app.name ?? "") açık. Kapatılsın mı?"
    }

    private func proceed(with plan: UninstallPlan) {
        if model.isRunning(plan) {
            // Onay penceresi kapanırken yeni pencere açılmaz: bir sonraki çalışma döngüsünde gösterilir.
            Task { @MainActor in quitPlan = plan }
        } else {
            Task { await model.uninstall(plan, quitFirst: false) }
        }
    }

    private func presence(_ plan: Binding<UninstallPlan?>) -> Binding<Bool> {
        Binding(get: { plan.wrappedValue != nil }, set: { if !$0 { plan.wrappedValue = nil } })
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
                Text("\(extensions.count) uzantı")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .padding([.horizontal, .top])
        .help(extensions.joined(separator: "\n"))
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
            Button("Çöp Sepeti'ne Taşı") { confirmPlan = UninstallPlan(scan: scan, checked: model.checked) }
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
            VStack(alignment: .leading, spacing: 2) {
                Text("Tam Disk Erişimi yok; bazı kalıntılar görünmeyebilir")
                if let skipped = model.scan?.skippedLocations, !skipped.isEmpty {
                    Text("Aranmayan yerler: \(skipped.joined(separator: "; "))")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button("İzin Ver") { model.onboardingSkipped = false }
                .accessibilityLabel("Tam Disk Erişimi izni ver")
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.yellow.opacity(0.35))
    }
}
