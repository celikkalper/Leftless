import AppKit
import LeftlessCore
import SwiftUI

/// Türüne göre gruplanmış kalıntı listesi; her grup başlığında üç durumlu onay kutusu.
struct LeftoverListView: View {
    @Bindable var model: AppModel
    let groups: [LeftoverGroup]
    /// Groups whose open/closed state the user changed from the default.
    @State private var toggled: Set<LeftoverKind> = []

    var body: some View {
        List {
            LeftoverGroupRows(model: model, groups: groups) { kind in
                Binding(get: { toggled.contains(kind) },
                        set: { if $0 { toggled.insert(kind) } else { toggled.remove(kind) } })
            }
        }
    }
}

/// The grouped rows (disclosure per kind) for use inside a `List`; the batch view shows one set per app.
struct LeftoverGroupRows: View {
    @Bindable var model: AppModel
    let groups: [LeftoverGroup]
    /// Whether the user flipped a group from its default open/closed state.
    let toggled: (LeftoverKind) -> Binding<Bool>

    /// Çok öğeli gruplar (ör. paket dosyaları) başlangıçta kapalı.
    private static let autoCollapseThreshold = 8

    var body: some View {
        ForEach(groups) { group in
            DisclosureGroup(isExpanded: expansion(for: group)) {
                ForEach(group.items) { item in
                    LeftoverRow(item: item, isOn: binding(for: item.id))
                }
            } label: {
                groupHeader(group)
            }
        }
    }

    private func groupHeader(_ group: LeftoverGroup) -> some View {
        HStack {
            Toggle(sources: group.items.map { binding(for: $0.id) }, isOn: \.self) {
                Text("\(group.title) (\(group.items.count.formatted()))").bold()
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel("\(group.title), \(group.items.count) items")
            Spacer()
            Text(AppModel.formatSize(group.totalSize))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func expansion(for group: LeftoverGroup) -> Binding<Bool> {
        let collapsedByDefault = group.items.count > Self.autoCollapseThreshold
        let flipped = toggled(group.kind)
        return Binding(get: { collapsedByDefault == flipped.wrappedValue },
                       set: { flipped.wrappedValue = ($0 == collapsedByDefault) })
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(get: { model.checked.contains(id) },
                set: { if $0 { model.checked.insert(id) } else { model.checked.remove(id) } })
    }
}

struct LeftoverRow: View {
    let item: Leftover
    @Binding var isOn: Bool
    /// Orphan lists show the item's place (kind) instead of a "possible" badge on every row.
    var showsKind = false

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $isOn) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(item.url.lastPathComponent)
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    if item.confidence == .probable, !showsKind {
                        Text("possible")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                    if item.requiresAdmin {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Requires administrator permission")
                    }
                }
                if showsKind {
                    Text(item.kind.displayName).font(.caption).foregroundStyle(.secondary)
                } else if let note = item.note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(AppModel.formatSize(item.size))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .help(item.url.path)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
        }
    }
}
