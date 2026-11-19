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
            Text("Tam Disk Erişimi gerekiyor")
                .font(.largeTitle.bold())

            VStack(alignment: .leading, spacing: 18) {
                step(1, "Neden gerekli?",
                     "Uygulamaların bıraktığı bazı dosyalar korunan klasörlerde durur. Kalıntısız bunları ancak Tam Disk Erişimi ile görebilir; hiçbir şey izniniz olmadan taşınmaz.")
                step(2, "Sistem Ayarları'nı açın", nil) {
                    Button("Sistem Ayarları'nı Aç") { FullDiskAccess.openSettings() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Sistem Ayarları'nda Tam Disk Erişimi bölümünü aç")
                }
                step(3, "+ ile Kalıntısız'ı ekle ve aç",
                     "Listede Kalıntısız'ı açık konuma getirin. İzin verildiğinde bu ekran kendiliğinden kapanır.")
            }
            .frame(maxWidth: 480)

            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                    .accessibilityHidden(true)
                Text("İzin bekleniyor…").foregroundStyle(.secondary)
            }

            Button("Şimdilik atla") { model.onboardingSkipped = true }
                .buttonStyle(.link)
                .accessibilityLabel("Tam Disk Erişimi olmadan devam et")
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

    private func step(_ number: Int, _ title: String, _ detail: String?) -> some View {
        step(number, title, detail) { EmptyView() }
    }

    private func step<Accessory: View>(_ number: Int, _ title: String, _ detail: String?,
                                       @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
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
        .accessibilityLabel("Adım \(number): \(title)")
    }
}
