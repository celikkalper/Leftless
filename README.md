# Kalıntısız

macOS 15+ için bir uygulama kaldırıcı. Bir uygulamayı kaldırırken geride kalan önbellek, tercih, günlük, başlatma aracısı gibi artıkları bulur ve hepsini birlikte Çöp Sepeti'ne taşır. Hiçbir şey kalıcı olarak silinmez; her işlem Geçmiş'e kaydedilir ve geri alınabilir.

## Ne yapar?

- Kurulu uygulamaları listeler; bir uygulamayı listeden seçebilir ya da `.app` dosyasını pencereye / Dock simgesine sürükleyip bırakabilirsiniz.
- Uygulamaya ait artıkları tarar ve her birini güven düzeyiyle gösterir: **kesin** olanlar varsayılan olarak seçilir, **olası** olanlar siz işaretleyene kadar seçilmez.
- Seçilenleri Çöp Sepeti'ne taşır. Yönetici izni gerektiren öğeler için tek seferde parola istenir.
- `com.apple.*` ve sistem klasörlerine asla dokunmaz.

## Xcode'da açma

1. `Kalintisiz.xcodeproj` dosyasına çift tıklayın.
2. Şema olarak **Kalintisiz** seçili olsun ve **⌘R** ile çalıştırın.

Proje `project.yml` dosyasından [XcodeGen](https://github.com/yonaskolb/XcodeGen) ile üretilir; yalnızca proje ayarlarını değiştirirseniz gerekir (`brew install xcodegen && xcodegen generate`). Swift Package Manager ile de çalışır: `swift run Kalintisiz`, testler için `swift test`.

## Universal .app üretme

```sh
./scripts/build-universal.sh
```

Çıktı: `build/Kalıntısız.app` (arm64 + x86_64, ad-hoc imzalı). Denetlemek için:

```sh
lipo -info "build/Kalıntısız.app/Contents/MacOS/Kalintisiz"
codesign -v "build/Kalıntısız.app"
```

> Başka Mac'lara dağıtmak için uygulamanın **Developer ID** ile imzalanması ve Apple tarafından **noter onayından (notarization)** geçirilmesi gerekir. Ad-hoc imzalı uygulama yalnızca derlediğiniz Mac'te sorunsuz açılır.

## Tam Disk Erişimi

Uygulama sandbox dışında çalışır. Bazı klasörlerin (Posta, Safari verileri, Konteynerler vb.) taranabilmesi için **Tam Disk Erişimi** gerekir:

1. **Sistem Ayarları → Gizlilik ve Güvenlik → Tam Disk Erişimi**
2. **+** düğmesiyle Kalıntısız'ı ekleyin ve anahtarı açın.
3. Uygulamayı yeniden başlatın.

İzin vermezseniz uygulama yine çalışır, ancak bazı artıklar görünmeyebilir; pencerede bir uyarı şeridi gösterilir.

## Geri alma ve Geçmiş

Her kaldırma işleminden önce hangi dosyanın nereye taşınacağı diske kaydedilir. **Geçmiş** sekmesinde her kayıt "Uygulama adı — N öğe" olarak listelenir. **Geri Yükle** dediğinizde dosyalar Çöp Sepeti'nden özgün yollarına taşınır. Aynı yolda başka bir dosya varsa atlama ya da değiştirme seçeneği sorulur; başlatma aracıları geri yüklenince yeniden yüklenir. Çöp Sepeti'ni boşalttıysanız ilgili öğeler geri yüklenemez ve kayıtta bu belirtilir.

## Uçtan uca duman testi (isteğe bağlı)

Sahte bir uygulama (`~/Applications/KalintisizTest.app`) ve artıkları ile tüm akışı (tara → kaldır → geri yükle) gerçek ortamda dener, sonunda sahte dosyaları siler:

```sh
KALINTISIZ_E2E=1 swift test --filter EndToEnd
```

Ortam değişkeni olmadan bu test atlanır.
