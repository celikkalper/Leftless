import LeftlessCore
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
                Text("\(outcome.record.appName) uninstalled — \(trashed.count) items, \(AppModel.formatSize(trashed.reduce(0) { $0 + $1.size }))")
                    .font(.title2.bold())
            }
            HStack {
                Button("Undo") {
                    Task { await model.restore(outcome.record) }
                }
                .disabled(trashed.isEmpty || model.isWorking)
                .accessibilityLabel("Undo uninstall")
                if model.isWorking {
                    ProgressView().controlSize(.small).accessibilityLabel("In progress")
                }
            }
            if !outcome.failures.isEmpty {
                Text("Couldn't Be Moved (\(outcome.failures.count))").font(.headline)
                List(outcome.failures) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(URL(fileURLWithPath: item.originalPath).lastPathComponent)
                        Text(Presentation.friendlyFailureReason(item)).font(.caption).foregroundStyle(.secondary)
                    }
                    .help([item.originalPath, Presentation.failureDetail(item)].compactMap { $0 }.joined(separator: "\n"))
                    .contextMenu {
                        Button("Show in Finder") {
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
