import AppKit
import KalintisizCore
import SwiftUI

struct HistoryView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.history.isEmpty {
                ContentUnavailableView("Geçmiş boş", systemImage: "clock",
                                       description: Text("Kaldırdığınız uygulamalar burada listelenir."))
            } else {
                List(model.history) { record in
                    HistoryRow(record: record, status: model.historyStatus[record.id] ?? .unrecoverable,
                               isWorking: model.isWorking) {
                        Task { await model.restore(record) }
                    }
                    .contextMenu {
                        Button("Kaydı Sil", role: .destructive) { model.deleteRecord(record) }
                    }
                }
            }
        }
        .navigationTitle("Geçmiş")
        .onAppear { model.reloadHistory() }
    }
}

private struct HistoryRow: View {
    let record: HistoryRecord
    let status: RestoreStatus
    let isWorking: Bool
    let onRestore: () -> Void

    private static let dayMonth = Date.FormatStyle().day().month(.wide).locale(Locale(identifier: "tr_TR"))

    private var canRestore: Bool {
        switch status {
        case .restorable, .partial: true
        case .unrecoverable, .restored: false
        }
    }

    private var badge: (String, Color) {
        switch status {
        case .restorable: ("Geri yüklenebilir", .green)
        case .partial: ("Kısmen", .orange)
        case .unrecoverable: ("Artık geri alınamaz", .secondary)
        case .restored: ("Geri yüklendi", .blue)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            icon
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(record.appName) — \(record.items.count) öğe — \(record.date.formatted(Self.dayMonth))")
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
                .accessibilityLabel("Durum: \(badge.0)")
            Button("Geri Yükle", action: onRestore)
                .disabled(!canRestore || isWorking)
                .accessibilityLabel("\(record.appName) uygulamasını geri yükle")
        }
        .padding(.vertical, 2)
    }

    private var icon: Image {
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
        return conflicts.count == 1 ? "\(conflicts[0].displayLabel) zaten var"
                                    : "\(conflicts.count) öğe zaten var"
    }

    private func message(_ pending: PendingRestore) -> String {
        guard pending.conflicts.count > 1 else {
            return "Çöp Sepeti'ndeki kopya geri yüklensin mi? Değiştir derseniz mevcut öğe Çöp Sepeti'ne taşınır."
        }
        return pending.conflicts.map { "\($0.displayLabel) zaten var" }.joined(separator: "\n")
            + "\n\nSeçiminiz bu öğelerin tümüne uygulanır. Değiştir derseniz mevcut öğeler Çöp Sepeti'ne taşınır."
    }

    func body(content: Content) -> some View {
        content.alert(title(model.pendingRestore), isPresented: $model.showsRestoreConflicts, presenting: model.pendingRestore) { pending in
            Button("Atla") { Task { await model.resolveRestore(pending, choice: .skip) } }
            Button("Değiştir") { Task { await model.resolveRestore(pending, choice: .replace) } }
            Button("Vazgeç", role: .cancel) {}
        } message: { pending in
            Text(message(pending))
        }
    }
}
