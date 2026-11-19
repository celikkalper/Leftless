import AppKit
import KalintisizCore
import SwiftUI

/// Türüne göre gruplanmış kalıntı listesi; her grup başlığında üç durumlu onay kutusu.
struct LeftoverListView: View {
    @Bindable var model: AppModel
    let groups: [LeftoverGroup]
    @State private var collapsed: Set<LeftoverKind> = []

    /// Çok öğeli gruplar (ör. paket dosyaları) başlangıçta kapalı.
    private static let autoCollapseThreshold = 8

    var body: some View {
        List {
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
        .onAppear {
            collapsed = Set(groups.filter { $0.items.count > Self.autoCollapseThreshold }.map(\.kind))
        }
    }

    private func groupHeader(_ group: LeftoverGroup) -> some View {
        HStack {
            Toggle(sources: group.items.map { binding(for: $0.id) }, isOn: \.self) {
                Text("\(group.title) (\(group.items.count))").bold()
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel("\(group.title), \(group.items.count) öğe")
            Spacer()
            Text(AppModel.formatSize(group.totalSize))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func expansion(for group: LeftoverGroup) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(group.kind) },
                set: { if $0 { collapsed.remove(group.kind) } else { collapsed.insert(group.kind) } })
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(get: { model.checked.contains(id) },
                set: { if $0 { model.checked.insert(id) } else { model.checked.remove(id) } })
    }
}

private struct LeftoverRow: View {
    let item: Leftover
    @Binding var isOn: Bool

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
                    if item.confidence == .probable {
                        Text("muhtemel")
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
                            .accessibilityLabel("Yönetici izni gerekir")
                    }
                }
                if let note = item.note {
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
            Button("Finder'da Göster") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
        }
    }
}
