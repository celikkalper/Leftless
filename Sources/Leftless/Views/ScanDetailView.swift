import AppKit
import LeftlessCore
import SwiftUI

struct ScanDetailView: View {
    @Bindable var model: AppModel
    /// Onay anında dondurulan plan; diyaloglar ve kaldırma yalnızca bunu kullanır.
    @State private var confirmPlan: UninstallPlan?
    @State private var quitPlan: UninstallPlan?
    /// Frozen reset plan (the app's data only, independent of the checkboxes) and its quit prompt.
    @State private var confirmReset: ResetPlan?
    @State private var quitReset: ResetPlan?

    var body: some View {
        VStack(spacing: 0) {
            if !model.hasFullDiskAccess {
                FullDiskAccessBanner(model: model, skipped: model.scan?.skippedLocations ?? [])
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
                ProgressView("Looking for leftovers…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert("Move to Trash", isPresented: presence($confirmPlan), presenting: confirmPlan) { plan in
            Button("Move") { proceed(with: plan) }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            Text(plan.summary.confirmationText(appName: plan.scan.app.name,
                                               formattedSize: AppModel.formatSize(plan.summary.totalSize)))
        }
        .alert(quitTitle, isPresented: presence($quitPlan), presenting: quitPlan) { plan in
            Button("Quit") { Task { await model.uninstall(plan, quitFirst: true) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert(resetTitle, isPresented: presence($confirmReset), presenting: confirmReset) { plan in
            Button("Reset") { proceed(with: plan) }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            Text(plan.confirmationText(formattedSize: AppModel.formatSize(plan.totalSize)))
        }
        .alert(quitResetTitle, isPresented: presence($quitReset), presenting: quitReset) { plan in
            Button("Quit") { Task { await model.reset(plan, quitFirst: true) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var quitTitle: String {
        String(localized: "\(quitPlan?.scan.app.name ?? "") is open. Quit it?")
    }

    private var quitResetTitle: String {
        String(localized: "\(quitReset?.scan.app.name ?? "") is open. Quit it?")
    }

    private var resetTitle: String {
        String(localized: "Reset \(confirmReset?.scan.app.name ?? "")?")
    }

    private func proceed(with plan: ResetPlan) {
        if model.isRunning(plan.scan.app) {
            Task { @MainActor in quitReset = plan }
        } else {
            Task { await model.reset(plan, quitFirst: false) }
        }
    }

    private func proceed(with plan: UninstallPlan) {
        if model.isRunning(plan) {
            // Onay penceresi kapanırken yeni pencere açılmaz: bir sonraki çalışma döngüsünde gösterilir.
            Task { @MainActor in quitPlan = plan }
        } else {
            Task { await model.uninstall(plan, quitFirst: false) }
        }
    }

    private func presence<Plan>(_ plan: Binding<Plan?>) -> Binding<Bool> {
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
                    Text("Version \(version)").foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(AppModel.formatSize(model.summary.totalSize))
                    .font(.title2.monospacedDigit())
                Text("selected").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Selected total size: \(AppModel.formatSize(model.summary.totalSize))")
        }
        .padding()
    }

    private func systemExtensionBox(_ extensions: [String]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("A system extension from this app or its developer was found. macOS removes it in System Settings > General > Login Items & Extensions.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(extensions.count) extensions")
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
            Text("\(model.summary.totalCount) of \(scan.leftovers.count) items selected")
                .foregroundStyle(.secondary)
            Spacer()
            if model.isWorking {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("In progress")
            }
            Button("Reset…") { confirmReset = ResetPlan(scan: scan) }
                .disabled(!model.canReset(scan) || model.isWorking)
                .help("Moves the app's data to the Trash. The app stays installed.")
                .accessibilityLabel("Reset the app's data")
            Button("Move to Trash") { confirmPlan = UninstallPlan(scan: scan, checked: model.checked) }
                .buttonStyle(.borderedProminent)
                .disabled(model.summary.isEmpty || model.isWorking)
                .keyboardShortcut(.delete, modifiers: .command)
                .accessibilityLabel("Move selected items to the Trash")
        }
        .padding()
    }
}

/// Yellow strip shown without Full Disk Access, with the places that weren't searched.
struct FullDiskAccessBanner: View {
    @Bindable var model: AppModel
    let skipped: [String]

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("No Full Disk Access; some leftovers may not be shown")
                if !skipped.isEmpty {
                    Text("Not searched: \(skipped.joined(separator: "; "))")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button("Grant Access") { model.onboardingSkipped = false }
                .accessibilityLabel("Grant Full Disk Access")
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.yellow.opacity(0.35))
    }
}
