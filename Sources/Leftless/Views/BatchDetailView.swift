import AppKit
import LeftlessCore
import SwiftUI

/// Detail for two or more selected apps: one section per app with its grouped leftovers, one Move to Trash.
struct BatchDetailView: View {
    @Bindable var model: AppModel
    /// Onay anında dondurulan plan; diyaloglar ve kaldırma yalnızca bunu kullanır.
    @State private var confirmPlan: BatchUninstallPlan?
    @State private var quitPlan: BatchUninstallPlan?
    /// Names of the open apps, frozen together with `quitPlan`.
    @State private var quitNames = ""
    /// Groups whose open/closed state the user changed, per app.
    @State private var toggled: Set<GroupKey> = []

    private struct GroupKey: Hashable {
        let app: InstalledApp.ID
        let kind: LeftoverKind
    }

    private var summary: BatchUninstallSummary {
        BatchUninstallSummary(model.selectedScans.map { UninstallSummary(leftovers: $0.leftovers, checked: model.checked) })
    }

    private var allScanned: Bool {
        !model.isScanning && model.selectedScans.count == model.selectedApps.count
    }

    var body: some View {
        VStack(spacing: 0) {
            if !model.hasFullDiskAccess {
                FullDiskAccessBanner(model: model, skipped: skippedLocations)
            }
            if let outcomes = model.batchOutcomes {
                BatchUninstallResultView(model: model, outcomes: outcomes)
            } else {
                header
                Divider()
                List {
                    ForEach(model.selectedApps) { app in
                        Section {
                            content(for: app)
                        } header: {
                            sectionHeader(app)
                        }
                    }
                }
                .disabled(model.isWorking)
                Divider()
                footer
            }
        }
        .alert("Move to Trash", isPresented: presence($confirmPlan), presenting: confirmPlan) { plan in
            Button("Move") { proceed(with: plan) }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            Text(plan.summary.confirmationText(formattedSize: AppModel.formatSize(plan.summary.totalSize)))
        }
        .alert(String(localized: "Quit \(quitNames)?"), isPresented: presence($quitPlan), presenting: quitPlan) { plan in
            Button("Quit") { Task { await model.uninstall(plan, quitFirst: true) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Places not searched without Full Disk Access (the same for every app; listed once).
    private var skippedLocations: [String] {
        var result: [String] = []
        for place in model.selectedScans.flatMap(\.skippedLocations) where !result.contains(place) { result.append(place) }
        return result
    }

    private func proceed(with plan: BatchUninstallPlan) {
        let running = model.runningApps(in: plan)
        if running.isEmpty {
            Task { await model.uninstall(plan, quitFirst: false) }
        } else {
            // Onay penceresi kapanırken yeni pencere açılmaz: bir sonraki çalışma döngüsünde gösterilir.
            let names = ListFormatter.localizedString(byJoining: running.map(\.name))
            Task { @MainActor in
                quitNames = names
                quitPlan = plan
            }
        }
    }

    private func presence(_ plan: Binding<BatchUninstallPlan?>) -> Binding<Bool> {
        Binding(get: { plan.wrappedValue != nil }, set: { if !$0 { plan.wrappedValue = nil } })
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
            Text("\(model.selectedApps.count) apps selected").font(.title2.bold())
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(AppModel.formatSize(summary.totalSize))
                    .font(.title2.monospacedDigit())
                Text("selected").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Selected total size: \(AppModel.formatSize(summary.totalSize))")
        }
        .padding()
    }

    private func sectionHeader(_ app: InstalledApp) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.info.url.path))
                .resizable()
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            Text(app.info.name).font(.headline)
            Spacer()
            if let scan = model.scans[app.id] {
                let size = UninstallSummary(leftovers: scan.leftovers, checked: model.checked).totalSize
                Text(AppModel.formatSize(size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Selected total size: \(AppModel.formatSize(size))")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func content(for app: InstalledApp) -> some View {
        if let scan = model.scans[app.id] {
            if !scan.systemExtensions.isEmpty {
                Label("A system extension from this app or its developer was found. macOS removes it in System Settings > General > Login Items & Extensions.",
                      systemImage: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(scan.systemExtensions.joined(separator: "\n"))
            }
            LeftoverGroupRows(model: model, groups: LeftoverGrouping.groups(scan.leftovers)) { kind in
                let key = GroupKey(app: app.id, kind: kind)
                return Binding(get: { toggled.contains(key) },
                               set: { if $0 { toggled.insert(key) } else { toggled.remove(key) } })
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for leftovers…").foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var footer: some View {
        HStack {
            Text("\(summary.totalCount) of \(model.selectedScans.reduce(0) { $0 + $1.leftovers.count }) items selected")
                .foregroundStyle(.secondary)
            Spacer()
            if model.isWorking {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("In progress")
            }
            Button("Move to Trash") {
                confirmPlan = BatchUninstallPlan(scans: model.selectedScans, checked: model.checked)
            }
            .buttonStyle(.borderedProminent)
            .disabled(summary.totalCount == 0 || !allScanned || model.isWorking)
            .keyboardShortcut(.delete, modifiers: .command)
            .accessibilityLabel("Move selected items to the Trash")
        }
        .padding()
    }
}
