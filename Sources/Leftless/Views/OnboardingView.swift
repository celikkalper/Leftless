import SwiftUI

/// Tam Disk Erişimi verilmemişse gösterilen 3 adımlı ekran; izin her 2 sn'de bir kontrol edilir.
struct OnboardingView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Full Disk Access Required")
                .font(.largeTitle.bold())

            VStack(alignment: .leading, spacing: 18) {
                step(1, "Why is it needed?",
                     "Some files that apps leave behind are in protected folders. Leftless can see them only with Full Disk Access. Nothing is moved without your permission.")
                step(2, "Go to System Settings", nil) {
                    Button("Open System Settings") { FullDiskAccess.openSettings() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Open Full Disk Access in System Settings")
                }
                step(3, "Add Leftless with + and turn it on",
                     "Turn Leftless on in the list. This screen closes by itself once access is granted.")
            }
            .frame(maxWidth: 480)

            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                    .accessibilityHidden(true)
                Text("Waiting for permission…").foregroundStyle(.secondary)
            }

            Button("Skip for Now") { model.onboardingSkipped = true }
                .buttonStyle(.link)
                .accessibilityLabel("Continue without Full Disk Access")
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            while !Task.isCancelled && !model.hasFullDiskAccess {
                try? await Task.sleep(for: .seconds(2))
                model.refreshFullDiskAccess()
            }
        }
    }

    private func step(_ number: Int, _ title: LocalizedStringResource, _ detail: LocalizedStringResource?) -> some View {
        step(number, title, detail) { EmptyView() }
    }

    private func step<Accessory: View>(_ number: Int, _ title: LocalizedStringResource, _ detail: LocalizedStringResource?,
                                       @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number, format: .number)
                .font(.headline)
                .frame(width: 28, height: 28)
                .background(Circle().fill(.tint.opacity(0.15)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                if let detail {
                    Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                accessory()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number.formatted()): \(String(localized: title))")
    }
}
