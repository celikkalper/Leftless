# Kalıntısız — macOS Uygulama Kaldırıcı: Tasarım

Tarih: 2026-11-19
Durum: Taslak (onay bekliyor)

## 1. Amaç ve neden

macOS'ta bir uygulamayı Çöp Sepeti'ne sürüklemek yalnızca `.app` paketini siler; ayar dosyaları,
önbellekler, `~/Library` altındaki destek klasörleri, launch agent/daemon'lar, yardımcı araçlar ve
`.pkg` ile sisteme dağılmış dosyalar geride kalır. **Kalıntısız**, bir uygulamayı bunların hepsiyle
birlikte kaldıran, teknik bilgisi olmayan bir kullanıcının da rahatça kullanabileceği bir Mac
uygulamasıdır. Yanlış bir şey silinirse tek tıkla geri alınabilmelidir.

## 2. Hedefler

- Seçilen uygulamaya ait kalıntıları olabildiğince eksiksiz bulmak (bkz. §6 Tarama).
- Bulunanları anlaşılır bir listede, boyutları ve güven seviyeleriyle göstermek.
- Silmeyi **Çöp Sepeti'ne taşıma** olarak yapmak ve her işlemi kayıt altına almak.
- "Geçmiş / Geri Yükle" ekranından bir kaldırma işlemini **tek tıkla** eski haline getirmek.
- macOS 15 (Sequoia) ve üzeri; Intel (x86_64) ve Apple Silicon (arm64) — Universal binary.

## 3. Hedef olmayanlar

- App Store dağıtımı (sandbox bu tür uygulamaya izin vermez).
- Arka planda sürekli çalışan izleme servisi (yaklaşım C reddedildi).
- Sistem temizliği, büyük dosya bulma, önbellek temizleme gibi genel "temizleyici" özellikleri.
- Homebrew/CLI araçlarını kaldırma (ilk sürümde yok).
- Kalıcı silme (Çöp Sepeti'ni boşaltmak kullanıcının işi).

## 4. Anti-hedefler (çalışsa bile başarısızlık sayılacak durumlar)

- Başka bir uygulamaya ya da sisteme ait bir dosyayı **varsayılan olarak işaretli** silmek.
- Apple sistem uygulamalarına (`/System/Applications`, `com.apple.*`) veya SIP korumalı yollara dokunmak.
- Kullanıcının belgelerini (`~/Documents`, `~/Desktop`, `~/Downloads`, `~/Music` vb.) kesin eşleşme
  gibi göstermek. Buradaki eşleşmeler en fazla "muhtemel" olur ve işaretsiz gelir.
- Geri yükleme kaydı yazılamadan dosya taşımak (kayıtsız silme olmaz).
- Kullanıcıyı terminal, yol adı veya teknik jargonla karşı karşıya bırakmak.

## 5. Kısıtlar

- Hedef: macOS 15.0+; Universal (arm64 + x86_64).
- Dil: Swift 6, arayüz SwiftUI. Üçüncü parti bağımlılık yok.
- Kullanıcı Xcode kuracak; proje Xcode'da açılıp ⌘R ile çalıştırılabilir olmalı. Xcode kurulana kadar
  komut satırından da (`swift build` + `lipo` + elle `.app` paketi) derlenebilmeli.
- Sandbox kapalı. Tam Disk Erişimi (FDA) gerekiyor; uygulama ilk açılışta bunu adım adım ister
  ve izin verilmeden tarama "kısıtlı mod"da çalışır (bulamadığı yerleri belirtir).
- Arayüz dili Türkçe; metinler `Localizable.xcstrings` içinde (ileride İngilizce eklenebilsin).

## 6. Yaklaşımlar

| | Yaklaşım | Artı | Eksi |
|---|---|---|---|
| A | İsim + bundle ID ile bilinen `~/Library` klasörlerini taramak | Basit, hızlı, güvenli | `.pkg` dosyalarını, farklı isimli launch agent'ları, helper'ları kaçırır |
| **B** | **A + pkg kayıtları + launchd plist içeriği + giriş öğeleri + group container + helper'lar + yönetici şifresiyle sistem dosyaları** | Neredeyse eksiksiz, yine de sade | Daha fazla kod; sistem dosyaları için şifre gerekir |
| C | B + arka planda sürekli dosya izleme | Teoride en eksiksiz | Sürekli servis, pil/kaynak, ek izin; önceden kurulmuş uygulamalara faydası yok |

**Seçilen: B** (kullanıcı onayladı). C "kullanıcı dostu" hedefine ters düştüğü için, A ise "kalıntı
bırakmasın" hedefini karşılamadığı için elendi.

### Tarama ayrıntıları (B)

Girdi: bir `.app` paketi → `CFBundleIdentifier`, `CFBundleName`, `CFBundleExecutable`,
team ID (kod imzasından), sürüm.

Eşleşme anahtarları: bundle ID, bundle ID'nin ön eki (ör. `com.spotify.`), uygulama adı,
yürütülebilir dosya adı, team ID.

Taranacak yerler (`~` = kullanıcı, ayrıca `/Library` karşılıkları):
- `Application Support`, `Caches`, `Preferences` (+ `ByHost`), `Logs`, `Saved Application State`,
  `HTTPStorages`, `WebKit`, `Cookies`, `Containers`, `Group Containers`, `Application Scripts`
- `LaunchAgents`, `LaunchDaemons` — plist **içeriği** okunur; `Program`/`ProgramArguments` uygulama
  paketine veya eşleşen bir yola işaret ediyorsa kesin eşleşme.
- `/Library/PrivilegedHelperTools`, `/Library/Extensions`, `~/Library/Internet Plug-Ins`,
  `Audio/Plug-Ins`, `PreferencePanes`, `QuickLook`, `Services`, `Screen Savers`
- `/private/var/db/receipts` — `pkgutil --pkgs` / `--files` ile paketin kurduğu dosyalar
  (yalnızca hâlâ var olanlar; paylaşılan dizinler hariç, sadece dosyalar ve pakete özel klasörler).
  Ayrıca `pkgutil --forget` ile kayıt kaldırılır (bu adım geri yüklemede `--forget` geri alınamadığı
  için kayıt manifestte not edilir).
- Giriş öğeleri / arka plan öğeleri: `SMAppService` ile kayıtlı olanlar uygulama paketiyle birlikte
  gider; `sfltool dumpbtm` çıktısı bilgi amaçlı okunur.
- `/private/var/folders/...` altındaki kullanıcı önbelleği (`getconf DARWIN_USER_CACHE_DIR`).

Kişisel klasörler (`~/Documents`, `~/Desktop`, `~/Downloads`, `~/Music`, `~/Movies`, `~/Pictures`):
yalnızca **en üst seviyede** isim eşleşmesi aranır (özyinelemeli tarama yok); bulunanlar hep "muhtemel".

Aynı üreticinin paylaşılan öğeleri: bir öğe yalnızca üretici düzeyinde eşleşiyorsa (team ID ya da
`com.microsoft.` gibi ön ek; ör. `Application Support/Microsoft`) ve aynı üreticinin **başka bir uygulaması
hâlâ yüklüyse**, öğe "muhtemel"e düşer, işaretsiz gelir ve "Word da kullanıyor olabilir" notu taşır.
Aynı kural paylaşılan pkg kayıtları ve helper'lar için de geçerlidir. `~/Library` / `/Library` dışındaki pkg
dosyaları (ör. `/usr/local/bin`) her zaman "muhtemel"dir.

Sistem uzantıları (DriverKit, ağ, endpoint security — `systemextensionsctl list`): ilk sürümde
**kaldırılmaz**. Tespit edilir ve sonuç ekranında "Bu uygulamanın bir sistem uzantısı var; macOS bunu
Sistem Ayarları > Genel > Giriş Öğeleri ve Uzantılar üzerinden kaldırır" bilgisiyle gösterilir.

Güven seviyeleri:
- **Kesin**: bundle ID/team ID tam eşleşmesi, pkg kaydı, launchd plist'in uygulamayı göstermesi.
  Varsayılan işaretli.
- **Muhtemel**: yalnızca isim benzerliği, ya da kullanıcı belge klasörlerindeki eşleşmeler.
  Varsayılan işaretsiz, "muhtemel" etiketiyle.
- Hiçbir zaman listelenmez: `com.apple.*`, SIP korumalı yollar, başka bir yüklü uygulamanın
  bundle ID'sine ait olduğu tespit edilen öğeler.

## 7. Kaldırma akışı

1. Kullanıcı listeden uygulamayı seçer ya da `.app`'i pencereye sürükler.
2. Tarama sonuçları gösterilir (toplam boyut, kategoriye göre gruplanmış liste, onay kutuları).
3. "Çöp Sepeti'ne Taşı" → uygulama çalışıyorsa kapatmayı önerir (önce nazikçe, gerekirse zorla).
4. İşaretli launch agent/daemon'lar `launchctl bootout` ile durdurulur.
5. Önce **manifest** yazılır (§8), ardından öğeler `FileManager.trashItem` ile Çöp Sepeti'ne taşınır;
   dönen Çöp Sepeti yolu manifeste işlenir. Yönetici gerektiren öğeler tek bir şifre penceresiyle,
   root olarak `mv` ile **kullanıcının kendi `~/.Trash` klasörüne** benzersiz bir adla taşınır (sahiplik
   korunur; Finder Çöp Sepeti'ni boşaltırken gerekirse şifre sorar). Hedef yol uygulama tarafından önceden
   belirlenip manifeste yazılır, sonra komut çalıştırılır. Bu öğelerin geri yüklenmesi de bir şifre
   penceresi açar (geri yüklemede tek seferde, toplu).
6. Sonuç ekranı: "Spotify kaldırıldı — 14 öğe, 412 MB. [Geri Al]".

Kısmi başarısızlık: taşınamayan öğeler sonuç ekranında listelenir, manifestte "taşınamadı" olarak
kalır; işlem iptal edilmez.

## 8. Geçmiş ve geri yükleme

- Kayıt yeri: `~/Library/Application Support/Kalintisiz/History/<uuid>.json` (her işlem bir dosya).
- Her kayıt: uygulama adı, bundle ID, sürüm, simge (PNG, küçük), tarih, toplam boyut ve her öğe için
  `orijinalYol`, `copYolu`, `tür`, `boyut`, `yöneticiGerekti`, `launchdEtiketi?`, `pkgId?`, `durum`.
- Geçmiş ekranı: "Spotify — 14 öğe — 19 Kasım" satırları. Durumlar:
  - **Geri yüklenebilir**: tüm `copYolu`'lar hâlâ mevcut.
  - **Kısmen geri yüklenebilir**: bazıları eksik.
  - **Artık geri alınamaz**: hiçbiri yok (Çöp Sepeti boşaltılmış).
- "Geri Yükle": öğeler orijinal yollarına taşınır (ara klasörler gerekirse oluşturulur), launch
  agent/daemon'lar `launchctl bootstrap` ile yeniden yüklenir. Orijinal yolda artık bir dosya varsa
  üzerine yazılmaz; kullanıcıya sorulur (Atla / Değiştir).
- Kayıt silme: Geçmişten satır silmek yalnızca kaydı siler, dosyalara dokunmaz.

## 9. Arayüz

Ana pencere, kenar çubuklu (NavigationSplitView):

```
┌ Uygulamalar ─────────┬──────────────────────────────┐
│ 🔍 Ara               │  Spotify  1.2.4   ·  412 MB   │
│ ▸ Spotify    412 MB  │  ☑ Uygulama          380 MB   │
│ ▸ Zoom       210 MB  │  ☑ Caches             28 MB   │
│ ▸ Slack      190 MB  │  ☑ Preferences (2)     4 KB   │
│ ──────────           │  ☑ LaunchAgent         1 KB   │
│ 🕘 Geçmiş            │  ☐ ~/Music/Spotify? (muhtemel)│
│                      │        [ Çöp Sepeti'ne Taşı ] │
└──────────────────────┴──────────────────────────────┘
```

- Uygulama listesi: `/Applications`, `~/Applications`; Apple uygulamaları gizli. Boyuta/ada göre sıralama.
  Listedeki boyut **yalnızca `.app` paketinin** boyutudur (hızlı açılış); kalıntılar dahil toplam boyut
  uygulama seçilip tarandığında sağ panelde gösterilir.
- Sürükle-bırak: pencereye ya da Dock simgesine `.app` bırakılabilir.
- Her öğede "Finder'da Göster"; teknik yol yalnızca üzerine gelince/ayrıntıda görünür.
- İlk açılış: Tam Disk Erişimi için adım adım ekran (Sistem Ayarları'nı doğru panelde açan düğme,
  izin verildiğini otomatik algılama).
- Açık/koyu mod, VoiceOver etiketleri.

## 10. Mimari (öneri, builder'a açık)

- `Kalintisiz` (SwiftUI app hedefi): arayüz.
- `KalintisizCore` (Swift paketi/kütüphane): `AppInspector`, `LeftoverScanner`, `Uninstaller`,
  `HistoryStore`, `Restorer`, `ProtectedPaths`. Arayüzden bağımsız ve birim testli; dosya sistemi
  erişimi test için sahte bir kök dizinle çalıştırılabilir olmalı.
- Yönetici işlemleri: ilk sürümde `AuthorizationExecuteWithPrivileges` yerine
  `osascript ... with administrator privileges` ile tek seferlik toplu komut (basit, güvenilir).
  İleride `SMAppService` daemon'a geçilebilir.
- Proje: XcodeGen `project.yml` + üretilmiş `.xcodeproj` (Xcode'da açılır); ayrıca Xcode'suz
  derleme için `scripts/build-universal.sh`.

## 11. Benim verdiğim kararlar (kullanıcı kontrol etsin)

- Uygulama adı: **Kalıntısız** (bundle ID `com.kalintisiz.app`) — değiştirilebilir.
- Arayüz Türkçe.
- Dağıtım: ilk aşamada yerel kullanım, ad-hoc imzalı. Başkalarına dağıtmak için Apple Developer
  hesabı ($99/yıl) ile Developer ID imzası + notarization gerekir; sonraki adım.
- Homebrew/CLI kaldırma yok.
- Yönetici gerektiren öğeler de kullanıcının Çöp Sepeti'ne gider; geri yüklemeleri şifre ister.
- Aynı üreticinin başka uygulaması yüklüyse paylaşılan klasörler işaretsiz/"muhtemel" gelir.
- Kenar çubuğundaki boyut yalnızca uygulamanın kendisi; tam boyut seçince hesaplanır.
- Kişisel klasörlerde yalnızca en üst seviyeye bakılır.
- Sistem uzantıları ilk sürümde kaldırılmaz, yalnızca bildirilir.

## 12. Builder'a bırakılanlar

- Kod düzeni, test yapısı, tarama paralelliği, boyut hesaplama yöntemi.
- Simge ve görsel detaylar (sade, sistem stiline uygun).
