import AppKit
import LeftlessCore
import SwiftUI

/// Leftovers tab: files in the Library that belong to no app on this Mac. Nothing is checked after a scan;
/// the confirmed selection is frozen and moved as one "Orphaned leftovers" history record.
struct OrphansView: View {
    @Bindable var model: AppModel
    /// Onay anında dondurulan plan; diyalog ve taşıma yalnızca bunu kullanır.
    @State private var confirmPlan: OrphanPlan?
    /// Groups whose open/closed state the user changed from the default.
    @State private var toggled: Set<String> = []

    /// Çok öğeli gruplar başlangıçta kapalı.
    private static let autoCollapseThreshold = 8

    var body: some View {
        VStack(spacing: 0) {
            if !model.hasFullDiskAccess {
                FullDiskAccessBanner(model: model, skipped: model.orphanScan?.skippedLocations ?? [])
            }
            if let outcome = model.orphanOutcome {
                UninstallResultView(model: model, outcome: outcome)
                Divider()
                HStack {
                    Spacer()
                    Button("Scan Again") { Task { await model.scanOrphans() } }
                        .disabled(model.isWorking)
                }
                .padding()
            } else if model.isScanningOrphans {
                ProgressView("Looking for orphaned leftovers…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let scan = model.orphanScan {
                if scan.groups.isEmpty {
                    ContentUnavailableView {
                        Label("No Orphaned Leftovers Found", systemImage: "checkmark.circle")
                    } description: {
                        Text("Everything Leftless checked in your Library belongs to an app on this Mac.")
                    } actions: {
                        Button("Scan Again") { Task { await model.scanOrphans() } }
                    }
                } else {
                    results(scan)
                }
            } else {
                ContentUnavailableView {
                    Label("Find Orphaned Leftovers", systemImage: "questionmark.folder")
                } description: {
                    Text("Leftless looks in your Library for files left behind by apps that are no longer on this Mac. Nothing is selected or moved until you choose.")
                } actions: {
                    Button("Scan") { Task { await model.scanOrphans() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isWorking)
                }
            }
        }
        .alert("Move to Trash", isPresented: presence($confirmPlan), presenting: confirmPlan) { plan in
            Button("Move") { Task { await model.moveOrphans(plan) } }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            Text(plan.confirmationText(formattedSize: AppModel.formatSize(plan.summary.totalSize)))
        }
    }

    private func presence(_ plan: Binding<OrphanPlan?>) -> Binding<Bool> {
        Binding(get: { plan.wrappedValue != nil }, set: { if !$0 { plan.wrappedValue = nil } })
    }

    private func summary(_ scan: OrphanScanResult) -> UninstallSummary {
        UninstallSummary(leftovers: scan.groups.flatMap(\.items), checked: model.orphanChecked)
    }

    @ViewBuilder private func results(_ scan: OrphanScanResult) -> some View {
        header(scan)
        Divider()
        List {
            ForEach(scan.groups) { group in
                DisclosureGroup(isExpanded: expansion(for: group)) {
                    ForEach(group.items) { item in
                        LeftoverRow(item: item, isOn: binding(for: item.id), showsKind: true)
                    }
                } label: {
                    groupHeader(group)
                }
            }
        }
        .disabled(model.isWorking)
        Label("Files of apps on external drives or in folders Spotlight doesn't index may also be listed here. Check before removing them.",
              systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 6)
        Divider()
        footer(scan)
    }

    private func header(_ scan: OrphanScanResult) -> some View {
        let size = summary(scan).totalSize
        return HStack(spacing: 12) {
            Image(systemName: "questionmark.folder.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Orphaned Leftovers").font(.title2.bold())
                Text("Files of apps that are no longer on this Mac")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Scan Again") { Task { await model.scanOrphans() } }
                .disabled(model.isWorking)
            VStack(alignment: .trailing, spacing: 2) {
                Text(AppModel.formatSize(size))
                    .font(.title2.monospacedDigit())
                Text("selected").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Selected total size: \(AppModel.formatSize(size))")
        }
        .padding()
    }

    private func groupHeader(_ group: OrphanGroup) -> some View {
        HStack {
            Toggle(sources: group.items.map { binding(for: $0.id) }, isOn: \.self) {
                Text("\(group.displayName) (\(group.items.count.formatted()))").bold()
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel("\(group.displayName), \(group.items.count) items")
            Text(group.id)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(AppModel.formatSize(group.totalSize))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func footer(_ scan: OrphanScanResult) -> some View {
        let summary = summary(scan)
        let allSelected = OrphanSelection.isAllSelected(scan.groups, checked: model.orphanChecked)
        return HStack {
            Button {
                model.orphanChecked = allSelected
                    ? OrphanSelection.deselectingAll(scan.groups, checked: model.orphanChecked)
                    : OrphanSelection.selectingAll(scan.groups, checked: model.orphanChecked)
            } label: {
                if allSelected { Text("Deselect All") } else { Text("Select All") }
            }
            .disabled(model.isWorking)
            Text("\(summary.totalCount) of \(scan.groups.reduce(0) { $0 + $1.items.count }) items selected")
                .foregroundStyle(.secondary)
            Spacer()
            if model.isWorking {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("In progress")
            }
            Button("Move to Trash") { confirmPlan = OrphanPlan(scan: scan, checked: model.orphanChecked) }
                .buttonStyle(.borderedProminent)
                .disabled(summary.isEmpty || model.isWorking)
                .keyboardShortcut(.delete, modifiers: .command)
                .accessibilityLabel("Move selected items to the Trash")
        }
        .padding()
    }

    private func expansion(for group: OrphanGroup) -> Binding<Bool> {
        let collapsedByDefault = group.items.count > Self.autoCollapseThreshold
        return Binding(get: { collapsedByDefault == toggled.contains(group.id) },
                       set: { open in
                           if open == collapsedByDefault { toggled.insert(group.id) } else { toggled.remove(group.id) }
                       })
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(get: { model.orphanChecked.contains(id) },
                set: { if $0 { model.orphanChecked.insert(id) } else { model.orphanChecked.remove(id) } })
    }
}
