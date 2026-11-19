import AppKit
import LeftlessCore
import SwiftUI

struct AppListView: View {
    @Bindable var model: AppModel

    private var selection: Binding<Selection?> {
        Binding(get: { model.selection }, set: { newValue in Task { await model.select(newValue) } })
    }

    var body: some View {
        List(selection: selection) {
            Section("Uygulamalar") {
                if model.isLoadingApps && model.apps.isEmpty {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Uygulamalar yükleniyor")
                }
                ForEach(model.visibleApps) { app in
                    AppRow(app: app).tag(Selection.app(app))
                }
            }
            Section {
                Label("Geçmiş", systemImage: "clock.arrow.circlepath")
                    .tag(Selection.history)
                    .accessibilityLabel("Geçmiş")
            }
        }
        .listStyle(.sidebar)
        .disabled(model.isWorking)
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Ara")
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Sırala", selection: $model.sort) {
                        Text("Ada göre").tag(AppListSort.name)
                        Text("Boyuta göre").tag(AppListSort.size)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sırala", systemImage: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Sıralama")
            }
            ToolbarItem {
                Button {
                    model.reloadApps()
                } label: {
                    Label("Yenile", systemImage: "arrow.clockwise")
                }
                .accessibilityLabel("Uygulama listesini yenile")
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
