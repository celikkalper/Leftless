import AppKit
import LeftlessCore
import SwiftUI

struct HistoryView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.history.isEmpty {
                ContentUnavailableView("No History", systemImage: "clock",
                                       description: Text("Apps you uninstall are listed here."))
            } else {
                List(model.history) { record in
                    HistoryRow(record: record, status: model.historyStatus[record.id] ?? .unrecoverable,
                               isWorking: model.isWorking) {
                        Task { await model.restore(record) }
                    }
                    .contextMenu {
                        Button("Delete Record", role: .destructive) { model.deleteRecord(record) }
                    }
                }
            }
        }
        .navigationTitle("History")
        .onAppear { model.reloadHistory() }
    }
}

private struct HistoryRow: View {
    let record: HistoryRecord
    let status: RestoreStatus
    let isWorking: Bool
    let onRestore: () -> Void

    /// Day and month in the user's locale (e.g. "20 November", "20. November", "11月20日").
    private static let dayMonth = Date.FormatStyle().day().month(.wide)

    private var canRestore: Bool {
        switch status {
        case .restorable, .partial: true
        case .unrecoverable, .restored: false
        }
    }

    private var badge: (String, Color) {
        switch status {
        case .restorable: (String(localized: "Restorable"), .green)
        case .partial: (String(localized: "Partly restorable"), .orange)
        case .unrecoverable: (String(localized: "No longer restorable"), .secondary)
        case .restored: (String(localized: "Restored"), .blue)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            icon
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title) — \(record.items.count) items — \(record.date.formatted(Self.dayMonth))")
                Text(AppModel.formatSize(record.totalSize))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(badge.0)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(badge.1.opacity(0.15), in: Capsule())
                .foregroundStyle(badge.1)
                .accessibilityLabel("Status: \(badge.0)")
            Button("Restore", action: onRestore)
                .disabled(!canRestore || isWorking)
                .accessibilityLabel("Restore \(title)")
        }
        .padding(.vertical, 2)
    }

    private var title: String { Presentation.historyTitle(record) }

    private var icon: Image {
        if record.operation == .orphans { return Image(systemName: "questionmark.folder") }
        if let data = record.icon, let image = NSImage(data: data) {
            return Image(nsImage: image)
        }
        return Image(systemName: "app.dashed")
    }
}

extension View {
    /// Geri yüklemede çakışan yollar için tek bir soru: tümü için [Atla] ya da [Değiştir].
    func restoreConflictAlert(model: AppModel) -> some View {
        modifier(RestoreConflictAlert(model: model))
    }
}

private struct RestoreConflictAlert: ViewModifier {
    @Bindable var model: AppModel

    private func title(_ pending: PendingRestore?) -> String {
        guard let conflicts = pending?.conflicts, !conflicts.isEmpty else { return "" }
        return conflicts.count == 1 ? String(localized: "\(conflicts[0].displayLabel) already exists")
                                    : String(localized: "\(conflicts.count) items already exist")
    }

    private func message(_ pending: PendingRestore) -> String {
        guard pending.conflicts.count > 1 else {
            return String(localized: "Restore the copy from the Trash? If you choose Replace, the existing item will be moved to the Trash.")
        }
        let lines = pending.conflicts.map { String(localized: "\($0.displayLabel) already exists") }
        let note = String(localized: "Your choice applies to all of these items. If you choose Replace, the existing items will be moved to the Trash.")
        return (lines + ["", note]).joined(separator: "\n")
    }

    func body(content: Content) -> some View {
        content.alert(title(model.pendingRestore), isPresented: $model.showsRestoreConflicts, presenting: model.pendingRestore) { pending in
            Button("Skip") { Task { await model.resolveRestore(pending, choice: .skip) } }
            Button("Replace") { Task { await model.resolveRestore(pending, choice: .replace) } }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(message(pending))
        }
    }
}
