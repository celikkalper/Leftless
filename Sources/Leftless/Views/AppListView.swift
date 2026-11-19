import AppKit
import LeftlessCore
import SwiftUI

struct AppListView: View {
    @Bindable var model: AppModel

    /// ⌘/⇧-click selects several apps; the detail then shows all of them for one batch uninstall.
    private var selection: Binding<Set<InstalledApp.ID>> {
        Binding(get: { model.selection }, set: { newValue in model.tab = .apps; Task { await model.select(newValue) } })
    }

    var body: some View {
        List(selection: selection) {
            Section("Apps") {
                if model.isLoadingApps && model.apps.isEmpty {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Loading apps")
                }
                ForEach(model.visibleApps) { app in
                    AppRow(app: app).tag(app.id)
                }
            }
        }
        .listStyle(.sidebar)
        .disabled(model.isWorking)
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search")
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Sort By", selection: $model.sort) {
                        Text("Name").tag(AppListSort.name)
                        Text("Size").tag(AppListSort.size)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Sort order")
            }
            ToolbarItem {
                Button {
                    model.reloadApps()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh app list")
            }
        }
    }
}

private struct AppRow: View {
    let app: InstalledApp

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.info.url.path))
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            Text(app.info.name).lineLimit(1)
            Spacer()
            Text(AppModel.formatSize(app.bundleSize))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .help(app.info.url.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(app.info.name), \(AppModel.formatSize(app.bundleSize))")
    }
}
