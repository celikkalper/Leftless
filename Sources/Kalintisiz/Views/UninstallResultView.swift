import KalintisizCore
import SwiftUI

/// Kaldırma sonrası özet: taşınanlar, [Geri Al] ve taşınamayanlar.
struct UninstallResultView: View {
    @Bindable var model: AppModel
    let outcome: UninstallOutcome

    private var trashed: [HistoryItem] { outcome.record.items.filter { $0.state == .trashed } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: outcome.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(outcome.failures.isEmpty ? .green : .orange)
                    .accessibilityHidden(true)
                Text("\(outcome.record.appName) kaldırıldı — \(trashed.count) öğe, \(AppModel.formatSize(trashed.reduce(0) { $0 + $1.size }))")
                    .font(.title2.bold())
            }
            HStack {
                Button("Geri Al") {
                    Task { await model.restore(outcome.record) }
                }
                .disabled(trashed.isEmpty || model.isWorking)
                .accessibilityLabel("Kaldırmayı geri al")
                if model.isWorking {
                    ProgressView().controlSize(.small).accessibilityLabel("İşlem sürüyor")
                }
            }
            if !outcome.failures.isEmpty {
                Text("Taşınamayanlar (\(outcome.failures.count))").font(.headline)
                List(outcome.failures) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(URL(fileURLWithPath: item.originalPath).lastPathComponent)
                        Text(item.friendlyFailureReason).font(.caption).foregroundStyle(.secondary)
                    }
                    .help([item.originalPath, item.error].compactMap { $0 }.joined(separator: "\n"))
                    .contextMenu {
                        Button("Finder'da Göster") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.originalPath)])
                        }
                    }
                }
            } else {
                Spacer()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
