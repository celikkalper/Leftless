import LeftlessCore
import SwiftUI

/// Kaldırma sonrası özet: taşınanlar, [Geri Al] ve taşınamayanlar.
struct UninstallResultView: View {
    @Bindable var model: AppModel
    let outcome: UninstallOutcome

    private var trashed: [HistoryItem] { outcome.record.items.filter { $0.state == .trashed } }

    private var title: Text {
        let size = AppModel.formatSize(trashed.reduce(0) { $0 + $1.size })
        switch outcome.record.operation {
        case .orphans: return Text("Orphaned leftovers moved to the Trash — \(trashed.count) items, \(size)")
        case .reset: return Text("\(outcome.record.appName) was reset — \(trashed.count) items, \(size)")
        case .uninstall: return Text("\(outcome.record.appName) uninstalled — \(trashed.count) items, \(size)")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: outcome.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(outcome.failures.isEmpty ? .green : .orange)
                    .accessibilityHidden(true)
                title.font(.title2.bold())
            }
            HStack {
                Button("Undo") {
                    Task { await model.restore(outcome.record) }
                }
                .disabled(trashed.isEmpty || model.isWorking)
                .accessibilityLabel(outcome.record.operation == .reset ? Text("Undo reset") : Text("Undo uninstall"))
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

/// Result of a batch uninstall: one section per app with its own Undo and the items that couldn't be moved.
struct BatchUninstallResultView: View {
    @Bindable var model: AppModel
    let outcomes: [UninstallOutcome]

    private static func trashed(_ outcome: UninstallOutcome) -> [HistoryItem] {
        outcome.record.items.filter { $0.state == .trashed }
    }

    private var allTrashed: [HistoryItem] { outcomes.flatMap(Self.trashed) }
    private var hasFailures: Bool { outcomes.contains { !$0.failures.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: hasFailures ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(hasFailures ? .orange : .green)
                    .accessibilityHidden(true)
                Text("\(outcomes.count) apps uninstalled — \(allTrashed.count) items, \(AppModel.formatSize(allTrashed.reduce(0) { $0 + $1.size }))")
                    .font(.title2.bold())
                if model.isWorking {
                    ProgressView().controlSize(.small).accessibilityLabel("In progress")
                }
            }
            List {
                ForEach(outcomes, id: \.record.id) { outcome in
                    Section {
                        appRow(outcome)
                        ForEach(outcome.failures) { item in
                            failureRow(item)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func appRow(_ outcome: UninstallOutcome) -> some View {
        let trashed = Self.trashed(outcome)
        let record = outcome.record
        return HStack(spacing: 10) {
            Group {
                if let data = record.icon, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.appName).font(.headline)
                Text("\(trashed.count) items, \(AppModel.formatSize(trashed.reduce(0) { $0 + $1.size }))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !outcome.failures.isEmpty {
                    Text("Couldn't Be Moved (\(outcome.failures.count))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if case .restored = model.historyStatus[record.id] {
                Text("Restored").foregroundStyle(.secondary)
            } else {
                Button("Undo") {
                    Task { await model.restore(record) }
                }
                .disabled(trashed.isEmpty || model.isWorking)
                .accessibilityLabel("Undo uninstall of \(record.appName)")
            }
        }
    }

    private func failureRow(_ item: HistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(URL(fileURLWithPath: item.originalPath).lastPathComponent)
            Text(Presentation.friendlyFailureReason(item)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.leading, 38)
        .help([item.originalPath, Presentation.failureDetail(item)].compactMap { $0 }.joined(separator: "\n"))
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.originalPath)])
            }
        }
    }
}
