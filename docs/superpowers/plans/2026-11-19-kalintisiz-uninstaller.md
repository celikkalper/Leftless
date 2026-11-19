# Kalıntısız Uygulama Planı

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** macOS 15+ için, uygulamaları kalıntılarıyla birlikte Çöp Sepeti'ne taşıyan ve tek tıkla geri yükleyebilen Universal bir SwiftUI uygulaması.

**Architecture:** İş mantığının tamamı arayüzden bağımsız `KalintisizCore` kütüphanesinde; dosya sistemi kökü, komut çalıştırma, Çöp Sepeti'ne taşıma ve yönetici işlemleri protokollerin arkasında, böylece testler sahte bir kök dizinde çalışır. `Kalintisiz` SwiftUI uygulaması yalnızca bu çekirdeği çağırır. SwiftPM ile derlenir; Xcode için XcodeGen projesi, Xcode'suz Universal `.app` için betik.

**Tech Stack:** Swift 6.1, SwiftUI, Foundation, Swift Testing (`import Testing`), SwiftPM, XcodeGen, `lipo`, `codesign`.

**Spec:** `docs/superpowers/specs/2026-11-19-kalintisiz-uninstaller-design.md`

## Global Constraints

- Platform: `.macOS(.v15)`; çıktı Universal (arm64 + x86_64). Geliştirme makinesi Intel, macOS 15.8.3.
- Swift 6 dil modu; üçüncü parti bağımlılık yok (XcodeGen yalnızca geliştirme aracı).
- Sandbox kapalı. Bundle ID `com.kalintisiz.app`, görünen ad **Kalıntısız**, ürün/klasör adı `Kalintisiz`.
- Arayüz Türkçe; metinler `String(localized:)` / SwiftUI `Text("...")` ile Türkçe anahtarlarla yazılır (İngilizce sonradan `Localizable.xcstrings` ile eklenir — spec'ten bilinçli sapma: CLT ile xcstrings derlemesi garanti değil).
- Hiçbir şey kalıcı silinmez; her taşıma öncesinde manifest diske yazılmış olmalı.
- Asla listelenmez/dokunulmaz: `com.apple.*`, `/System`, `/usr` (`/usr/local` hariç), `/bin`, `/sbin`, `/private/var/db` (receipt okuma hariç), `/Library/Apple`.
- Commit mesajları şu satırla biter: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`

## Review Focus

1. **Yol adlarında boşluk, Türkçe karakter, tırnak** (`Müzik Çalar's.app`) — yönetici komutları kabuk kaçışıyla üretilmeli; `ShellQuoting` testleri (Task 6).
2. **Çöp Sepeti'nde aynı isim zaten varken** taşıma — yönetici taşımasında hedef adı benzersiz olmalı; `uniqueTrashURL` testi (Task 6).
3. **Geri yüklerken orijinal klasör artık yok** (ör. `~/Library/Application Support` altı silinmiş) — ara klasörler oluşturulur; Restorer testi (Task 8).
4. **Uygulama `/Applications` dışından sürüklenmiş, imzasız ya da Info.plist'siz** — `AppInspector` hata yerine anlamlı `AppInspectorError` döner; test (Task 2).
5. **Aynı bundle ID önekine sahip ama ilgisiz kısa ad** (ör. ad "Go" → `~/Library/Caches/Google`) — kısa ad (< 4 karakter) isim eşleşmesi asla yapılmaz, yalnızca tam bileşen eşleşmesi; test (Task 3).

---

## Dosya Yapısı

```
Package.swift
project.yml                          # XcodeGen
scripts/build-universal.sh
App/Info.plist
App/Kalintisiz.entitlements          # sandbox kapalı
Sources/KalintisizCore/
  Models.swift                       # AppInfo, Leftover, LeftoverKind, Confidence, ScanResult
  ProtectedPaths.swift
  ScanEnvironment.swift              # kök/home soyutlaması, CommandRunning
  AppInspector.swift
  InstalledApps.swift
  LeftoverScanner.swift              # kütüphane klasörleri + eşleşme + güven
  LaunchdScanner.swift
  ReceiptScanner.swift
  History.swift                      # HistoryRecord, HistoryItem, HistoryStore
  FileOps.swift                      # FileMoving, PrivilegedExecuting, ShellQuoting
  Uninstaller.swift
  Restorer.swift
Sources/Kalintisiz/                  # SwiftUI
  KalintisizApp.swift
  AppModel.swift
  Views/AppListView.swift
  Views/ScanDetailView.swift
  Views/HistoryView.swift
  Views/OnboardingView.swift
  Support/FullDiskAccess.swift
  Support/AppTerminator.swift
Tests/KalintisizCoreTests/
  Fixtures.swift                     # sahte kök dizin + sahte .app üretici
  ...Tests.swift (görev başına bir dosya)
```

---

### Task 1: İskelet, modeller ve korunan yollar

**Files:**
- Create: `Package.swift`, `.gitignore`, `Sources/KalintisizCore/Models.swift`, `Sources/KalintisizCore/ProtectedPaths.swift`, `Sources/Kalintisiz/KalintisizApp.swift` (boş pencere), `Tests/KalintisizCoreTests/Fixtures.swift`, `Tests/KalintisizCoreTests/ProtectedPathsTests.swift`

**Interfaces:**
- Produces:
  - `public struct AppInfo: Codable, Hashable, Sendable { url: URL; bundleID: String; name: String; executableName: String?; version: String?; teamID: String? }`
  - `public enum Confidence: String, Codable, Sendable { case certain, probable }`
  - `public enum LeftoverKind: String, Codable, Sendable, CaseIterable { case appBundle, applicationSupport, caches, preferences, logs, savedState, httpStorages, webKit, cookies, container, groupContainer, applicationScripts, launchAgent, launchDaemon, privilegedHelper, kernelExtension, plugin, packageFile, personalFolder, other }` + `var displayName: String` (Türkçe: "Uygulama", "Önbellek", "Tercihler", ...)
  - `public struct Leftover: Identifiable, Codable, Hashable, Sendable { id: UUID; url: URL; kind: LeftoverKind; confidence: Confidence; size: Int64; requiresAdmin: Bool; launchdLabel: String?; packageID: String?; note: String? }` + `var selectedByDefault: Bool { confidence == .certain }`
  - `public struct ScanResult: Sendable { app: AppInfo; leftovers: [Leftover]; systemExtensions: [String]; var totalSize: Int64 }`
  - `public enum ProtectedPaths { static func isProtected(_ url: URL, root: URL) -> Bool; static func isAppleBundleID(_ id: String) -> Bool }`
  - Test yardımcısı: `struct FakeSystem { let root: URL; var home: URL; func makeApp(name:bundleID:executable:version:in:) throws -> URL; func touch(_ relative: String, bytes: Int = 10) throws -> URL }` — her test için `FileManager.default.temporaryDirectory` altında benzersiz kök.

- [ ] **Step 1:** `git init`; `.gitignore` (`.build/`, `build/`, `*.xcodeproj/xcuserdata`, `.DS_Store`). `Package.swift`: `platforms: [.macOS(.v15)]`, ürünler: `library KalintisizCore`, `executableTarget Kalintisiz` (bağımlılık: core), `testTarget KalintisizCoreTests`.
- [ ] **Step 2: Failing test** `ProtectedPathsTests`:
```swift
@Test func appleAndSystemPathsAreProtected() {
  let r = URL(fileURLWithPath: "/")
  #expect(ProtectedPaths.isProtected(URL(fileURLWithPath: "/System/Library/Foo"), root: r))
  #expect(ProtectedPaths.isProtected(URL(fileURLWithPath: "/usr/lib/x"), root: r))
  #expect(!ProtectedPaths.isProtected(URL(fileURLWithPath: "/usr/local/bin/x"), root: r))
  #expect(ProtectedPaths.isProtected(URL(fileURLWithPath: "/Users/a/Library/Preferences/com.apple.finder.plist"), root: r))
  #expect(!ProtectedPaths.isProtected(URL(fileURLWithPath: "/Users/a/Library/Caches/com.spotify.client"), root: r))
  #expect(ProtectedPaths.isAppleBundleID("com.apple.Safari"))
}
```
- [ ] **Step 3:** `swift test` → derleme hatası (tip yok).
- [ ] **Step 4:** Modelleri ve `ProtectedPaths`'i yaz. `isProtected`: `root`'a göre göreli yol üzerinden Global Constraints listesi + son yol bileşeni `com.apple.` ile başlıyorsa true.
- [ ] **Step 5:** `swift test` → PASS; `swift build` → `Kalintisiz` derlenir.
- [ ] **Step 6:** Commit `chore: scaffold package, models and protected paths`.

---

### Task 2: AppInspector ve yüklü uygulama listesi

**Files:**
- Create: `Sources/KalintisizCore/ScanEnvironment.swift`, `AppInspector.swift`, `InstalledApps.swift`; Test: `AppInspectorTests.swift`

**Interfaces:**
- Produces:
  - `public protocol CommandRunning: Sendable { func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput }`, `public struct CommandOutput { status: Int32; stdout: String; stderr: String }`, `public struct ProcessCommandRunner: CommandRunning`
  - `public struct ScanEnvironment: Sendable { root: URL; home: URL; userCacheDir: URL?; uid: uid_t; static func live() -> ScanEnvironment; func path(_ absolute: String) -> URL /* root + absolute */; func homePath(_ relative: String) -> URL }`
  - `public enum AppInspectorError: Error, Equatable { case notAnAppBundle, missingInfoPlist, missingBundleIdentifier }`
  - `public struct AppInspector { init(commands: CommandRunning); func inspect(_ appURL: URL) throws -> AppInfo }` — team ID `codesign -dv --verbose=2 <app>` stderr'deki `TeamIdentifier=` satırından; imzasız/“not set” ise `nil`.
  - `public struct InstalledApps { init(environment: ScanEnvironment, inspector: AppInspector); func list() -> [InstalledApp] }`, `public struct InstalledApp: Identifiable, Hashable { info: AppInfo; bundleSize: Int64; var id: String { info.url.path } }` — `/Applications` ve `~/Applications` (1 seviye + bir alt klasör, ör. `/Applications/Utilities` hariç Apple), Apple bundle ID'leri hariç, ada göre sıralı.
  - `public func directorySize(_ url: URL) -> Int64` (`totalFileAllocatedSize`, sembolik link takip etmez).

- [ ] **Step 1: Failing tests:** `inspectReadsBundleInfo` (FakeSystem.makeApp → bundleID/name/executable/version eşleşir, teamID nil çünkü sahte runner boş döner), `inspectRejectsNonApp` (`.txt` → `.notAnAppBundle`), `inspectRejectsMissingPlist` (`.app` klasörü Info.plist'siz → `.missingInfoPlist`), `inspectParsesTeamID` (sahte runner stderr `TeamIdentifier=ABCDE12345` → `"ABCDE12345"`), `installedAppsSkipsApple` (`com.apple.Safari` ve `com.spotify.client` → yalnız Spotify).
- [ ] **Step 2:** `swift test --filter AppInspector` → FAIL.
- [ ] **Step 3:** Uygula. Ad: `CFBundleDisplayName` ?? `CFBundleName` ?? dosya adı.
- [ ] **Step 4:** `swift test` → PASS.
- [ ] **Step 5:** Commit `feat(core): inspect app bundles and list installed apps`.

---

### Task 3: Kütüphane klasörleri taraması ve eşleşme kuralları

**Files:**
- Create: `Sources/KalintisizCore/LeftoverScanner.swift`; Test: `LeftoverScannerTests.swift`

**Interfaces:**
- Consumes: Task 1–2 tipleri.
- Produces:
  - `public struct MatchKeys: Sendable { bundleID: String; vendorPrefix: String?; names: [String]; teamID: String?; init(app: AppInfo) }` — `vendorPrefix`: bundle ID'nin ilk iki bileşeni + "." (`com.spotify.`), yalnızca ≥3 bileşen varsa. `names`: ad, yürütülebilir ad; < 4 karakter olanlar atılır.
  - `public struct LeftoverScanner { init(environment: ScanEnvironment, installedApps: [AppInfo], launchd: LaunchdScanner?, receipts: ReceiptScanner?); func scan(_ app: AppInfo) -> ScanResult }` (Task 5–6 `nil` geçerek bu görevde test edilir)
  - `func classify(_ entryName: String, keys: MatchKeys) -> Confidence?` (internal, testli)

Taranacak klasör → tür eşlemesi (hem `~/Library/X` hem `/Library/X`; `/Library` altı `requiresAdmin = true`):
`Application Support→applicationSupport, Caches→caches, Preferences & Preferences/ByHost→preferences, Logs→logs, Saved Application State→savedState, HTTPStorages→httpStorages, WebKit→webKit, Cookies→cookies, Containers→container, Group Containers→groupContainer, Application Scripts→applicationScripts, Internet Plug-Ins|Audio/Plug-Ins|PreferencePanes|QuickLook|Services|Screen Savers→plugin, /Library/PrivilegedHelperTools→privilegedHelper, /Library/Extensions→kernelExtension`, ayrıca `userCacheDir` → caches. Uygulama paketinin kendisi `appBundle`/certain (yolu `/Applications` ise requiresAdmin = yazılabilir değilse).

Eşleşme (`classify`), giriş adı uzantısız ve küçük harfle:
- **certain:** ad == bundleID, ad bundleID ile başlar ve sonraki karakter `.`/`-`/`_` (ör. `com.spotify.client.helper`, `com.spotify.client.plist`), Group Container adı `<teamID>.` ile başlar ve bundleID/ad içerir.
- **certain:** ad (büyük/küçük duyarsız) uygulama adlarından birine tam eşit (`Spotify`).
- **probable:** ad `vendorPrefix` ile başlar ama bundleID değil; ya da ad bir uygulama adını ayrı bir kelime olarak içerir (`Spotify Data`).
- Aksi halde `nil`.

Sonrası kurallar (sıra önemli):
1. `ProtectedPaths.isProtected` → atla.
2. Öğe `installedApps` içindeki **başka** bir uygulamanın bundleID'sine certain eşleşiyorsa → atla.
3. Öğe yalnızca üretici düzeyinde (vendorPrefix ya da team ID) eşleşiyor **veya** üretici klasörü (ad == vendor adı, ör. `Microsoft`) ise ve aynı vendorPrefix/teamID'li başka uygulama yüklüyse → `probable`, `note = "<DiğerAd> da kullanıyor olabilir"`.
4. Kişisel klasörler (`Documents, Desktop, Downloads, Music, Movies, Pictures`) yalnızca en üst seviye, yalnızca isim eşleşmesi, her zaman `probable`, `kind = .personalFolder`.

- [ ] **Step 1: Failing tests** (FakeSystem'de dosyalar oluştur, `scan` sonucu üzerinden):
  - `findsCertainLibraryItems`: `Library/Caches/com.spotify.client`, `Library/Preferences/com.spotify.client.plist`, `Library/Application Support/Spotify` → üçü de certain, türleri doğru.
  - `skipsOtherAppsItems`: başka yüklü `com.spotify.other` için `Caches/com.spotify.other` → sonuçta yok.
  - `vendorSharedFolderIsProbableWhenSiblingInstalled`: `com.microsoft.Excel` taranırken `com.microsoft.Word` yüklü, `Application Support/Microsoft` → probable, `note` "Microsoft Word da kullanıyor olabilir" içerir.
  - `shortNamesNeverNameMatch`: ad `Go`, bundle `com.example.go` → `Caches/Google` sonuçta yok.
  - `personalFoldersTopLevelOnly`: `Music/Spotify` → probable/personalFolder; `Music/x/Spotify` → yok.
  - `systemLibraryRequiresAdmin`: `/Library/Application Support/Spotify` → requiresAdmin true.
  - `appleItemsNeverListed`: `Preferences/com.apple.spotify.plist` gibi bir dosya → yok.
- [ ] **Step 2:** `swift test --filter LeftoverScanner` → FAIL.
- [ ] **Step 3:** Uygula; boyutlar `directorySize` ile. Her klasör yalnızca 1 seviye listelenir (Containers vb. içine inilmez).
- [ ] **Step 4:** `swift test` → PASS.
- [ ] **Step 5:** Commit `feat(core): scan library folders with confidence rules`.

---

### Task 4: launchd ve pkg kayıtları, sistem uzantıları

**Files:**
- Create: `Sources/KalintisizCore/LaunchdScanner.swift`, `ReceiptScanner.swift`; Modify: `LeftoverScanner.swift`; Test: `LaunchdScannerTests.swift`, `ReceiptScannerTests.swift`

**Interfaces:**
- Produces:
  - `public struct LaunchdScanner { init(environment: ScanEnvironment); func scan(_ app: AppInfo, keys: MatchKeys) -> [Leftover] }` — `~/Library/LaunchAgents` (kind `.launchAgent`, admin false), `/Library/LaunchAgents` ve `/Library/LaunchDaemons` (admin true; daemons `.launchDaemon`). Plist'i `PropertyListSerialization` ile okur; `Program` veya `ProgramArguments[0]` uygulama paketinin içini ya da eşleşen bir helper yolunu gösteriyorsa **certain**; değilse dosya adına `classify` uygulanır. `launchdLabel = plist["Label"]`.
  - `public protocol ReceiptProviding: Sendable { func packageIDs() -> [String]; func installedPaths(forPackage id: String) -> [String] /* mutlak yollar */ }`, `public struct PkgutilReceiptProvider: ReceiptProviding` (`pkgutil --pkgs`, `pkgutil --pkg-info <id>` → `location:` ve `volume:`, `pkgutil --only-files --files <id>`; mutlak yol = volume + location + dosya).
  - `public struct ReceiptScanner { init(environment:, provider: ReceiptProviding); func scan(_ app: AppInfo, keys: MatchKeys, installedApps: [AppInfo]) -> [Leftover] }` — eşleşen paket: id `classify` ile certain/probable. Yalnızca var olan, korunmayan, `Library` altındakiler `packageFile` + paketin güveni; `Library` dışındakiler (ör. `/usr/local/bin`) her zaman probable. Sonuçta zaten listelenmiş bir öğenin altındaki yollar tekrar eklenmez. `packageID` doldurulur. `.app` paketinin içindekiler atlanır.
  - `LeftoverScanner.scan` sistem uzantılarını `systemextensionsctl list` çıktısında bundleID/teamID geçen satırlardan doldurur (`systemExtensions: [String]`).
- [ ] **Step 1: Failing tests:** `launchAgentPointingIntoAppIsCertain` (plist `ProgramArguments = ["/Applications/Zoom.us.app/Contents/MacOS/x"]`, dosya adı `us.zoom.updater.plist` → certain, label okunur), `unrelatedAgentIgnored`, `daemonRequiresAdmin`, `receiptFilesBecomeLeftovers` (sahte provider: `com.spotify.pkg` → `/Library/Application Support/SpotifyHelper/a.dylib` → packageFile, packageID dolu), `receiptFilesOutsideLibraryAreProbable` (`/usr/local/bin/spotify-cli` → probable), `receiptNestedPathsDeduplicated`.
- [ ] **Step 2:** `swift test --filter "Launchd|Receipt"` → FAIL.
- [ ] **Step 3:** Uygula ve `LeftoverScanner`'a bağla; tekrar eden URL'ler birleştirilir (yüksek güven kazanır).
- [ ] **Step 4:** `swift test` → PASS.
- [ ] **Step 5:** Commit `feat(core): detect launchd items, pkg receipts and system extensions`.

---

### Task 5: Geçmiş (manifest) deposu

**Files:**
- Create: `Sources/KalintisizCore/History.swift`; Test: `HistoryStoreTests.swift`

**Interfaces:**
- Produces:
  - `public enum ItemState: String, Codable { case pending, trashed, failed, restored }`
  - `public struct HistoryItem: Codable, Hashable, Identifiable { id: UUID; originalPath: String; trashPath: String?; kind: LeftoverKind; size: Int64; requiresAdmin: Bool; launchdLabel: String?; launchdDomain: String?; packageID: String?; state: ItemState; error: String? }`
  - `public struct HistoryRecord: Codable, Identifiable { id: UUID; appName: String; bundleID: String; version: String?; date: Date; icon: Data?; items: [HistoryItem] ; var totalSize: Int64 }`
  - `public enum RestoreStatus: Equatable { case restorable, partial(missing: Int), unrecoverable, restored }`
  - `public final class HistoryStore: Sendable { init(directory: URL); func save(_ r: HistoryRecord) throws /* atomik yazım, <id>.json */; func all() throws -> [HistoryRecord] /* tarihe göre yeni→eski, bozuk dosyaları atlar */; func delete(id: UUID) throws; func status(of r: HistoryRecord) -> RestoreStatus }` — status: `trashed` öğelerin `trashPath`'lerinden var olanları say; hepsi `restored` → `.restored`; hiç `trashed` yok/hiçbiri yok → `.unrecoverable`.
  - `static func liveDirectory() -> URL` = `~/Library/Application Support/Kalintisiz/History`.
- [ ] **Step 1: Failing tests:** `saveAndLoadRoundTrip`, `allSortedNewestFirstAndSkipsCorruptFiles`, `statusRestorableWhenAllTrashPathsExist`, `statusPartialWhenSomeMissing` (`.partial(missing: 1)`), `statusUnrecoverableWhenTrashEmptied`, `deleteRemovesOnlyRecordFile` (trash dosyası yerinde kalır).
- [ ] **Step 2:** FAIL → **Step 3:** uygula (JSON `.iso8601`, `.prettyPrinted`) → **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(core): history store with restore status`.

---

### Task 6: Dosya işlemleri, yönetici yürütücü, kabuk kaçışı

**Files:**
- Create: `Sources/KalintisizCore/FileOps.swift`; Test: `FileOpsTests.swift`

**Interfaces:**
- Produces:
  - `public protocol FileMoving: Sendable { func trash(_ url: URL) throws -> URL; func move(_ from: URL, to: URL) throws; func exists(_ url: URL) -> Bool; func createDirectory(_ url: URL) throws }`, `public struct SystemFileMover: FileMoving` (`FileManager.trashItem(at:resultingItemURL:)`).
  - `public protocol PrivilegedExecuting: Sendable { func run(_ commands: [String]) throws }` — tek bir şifre penceresi; `public struct OsascriptPrivilegedExecutor` komutları `set -e` ile `; ` yerine `&&` zinciriyle birleştirip `do shell script "<escaped>" with administrator privileges` olarak `osascript -e` ile çalıştırır. Kullanıcı iptal ederse (`-128`) `PrivilegedError.cancelled`.
  - `public enum ShellQuoting { static func quote(_ s: String) -> String /* tek tırnak, ' → '\'' */; static func appleScriptString(_ s: String) -> String /* \ ve " kaçışı */ }`
  - `public func uniqueTrashURL(for original: URL, trashDirectory: URL, fileExists: (URL) -> Bool) -> URL` — `Ad.uzantı` varsa `Ad 2.uzantı`, `Ad 3.uzantı`...
- [ ] **Step 1: Failing tests:** `quotesSpacesTurkishAndApostrophes` (`/Applications/Müzik Çalar's.app` → `'/Applications/Müzik Çalar'\''s.app'`), `appleScriptEscapesQuotesAndBackslashes`, `uniqueTrashURLAppendsCounter` (`a.plist` ve `a 2.plist` mevcut → `a 3.plist`; klasör `Spotify` → `Spotify 2`), `systemMoverTrashesFileInTempDir` (gerçek `trashItem` — geçici dosya çöpe gider ve dönen URL var; test sonunda dönen URL'yi siler).
- [ ] **Step 2:** FAIL → **Step 3:** uygula → **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(core): file mover, privileged executor and shell quoting`.

---

### Task 7: Uninstaller

**Files:**
- Create: `Sources/KalintisizCore/Uninstaller.swift`; Test: `UninstallerTests.swift` (sahte `FileMoving`, `PrivilegedExecuting`, `CommandRunning` kayıt tutan çiftlerle)

**Interfaces:**
- Consumes: Task 5 `HistoryStore`, Task 6 protokolleri, `ScanResult`, `Leftover`.
- Produces:
  - `public struct UninstallOutcome { record: HistoryRecord; failures: [HistoryItem] }`
  - `public struct Uninstaller { init(history: HistoryStore, files: FileMoving, privileged: PrivilegedExecuting, commands: CommandRunning, environment: ScanEnvironment, trashDirectory: URL /* live: home/.Trash */); func uninstall(_ result: ScanResult, selected: [Leftover], icon: Data?) throws -> UninstallOutcome }`

Sıra (spec §7):
1. Tüm seçili öğeler `pending` olarak `HistoryRecord`'a; admin öğeler için `trashPath` şimdiden `uniqueTrashURL` ile belirlenir (aynı çağrı içinde seçilen hedefler de "var" sayılır). **`history.save` başarısızsa hiçbir şey taşınmadan hata fırlatılır.**
2. launchd öğeleri: admin değilse `launchctl bootout gui/<uid> <plist>` (`commands`), admin ise komut listesine `launchctl bootout system <plist>`; `launchdDomain` kaydedilir. bootout hatası yok sayılır (zaten yüklü olmayabilir).
3. Admin olmayanlar tek tek `files.trash` → `trashed` + gerçek `trashPath`; hata → `failed` + `error`.
4. Admin olanlar: `mv -n <orijinal> <trashPath>` komutları + varsa `pkgutil --forget <id>` (benzersiz) → tek `privileged.run`. İptal → bu öğeler `failed` ("Yönetici izni verilmedi"); başarı → `trashed`.
5. Kayıt tekrar kaydedilir; `failures` = `failed` öğeler.
- [ ] **Step 1: Failing tests:** `writesManifestBeforeMovingAnything` (sahte history kaydında, ilk `trash` çağrısı anında diskte `pending` kayıt var), `doesNotMoveWhenManifestCannotBeSaved` (salt-okunur history dizini → hata, `trash` hiç çağrılmadı), `adminItemsBatchedIntoSinglePrivilegedRun` (2 admin öğe → `run` 1 kez, komutlar `mv -n` ve kaçışlı yollar içerir), `launchAgentBootedOutBeforeTrash`, `partialFailureIsRecorded` (bir öğe `trash` hatası → `failed`, diğerleri `trashed`, fonksiyon fırlatmaz), `cancelledAdminMarksItemsFailed`.
- [ ] **Step 2:** FAIL → **Step 3:** uygula → **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(core): uninstaller with manifest-first trashing`.

---

### Task 8: Restorer

**Files:**
- Create: `Sources/KalintisizCore/Restorer.swift`; Test: `RestorerTests.swift`

**Interfaces:**
- Produces:
  - `public enum ConflictChoice: Sendable { case skip, replace }`
  - `public struct RestoreOutcome { record: HistoryRecord; restored: Int; skipped: Int; failures: [HistoryItem] }`
  - `public struct Restorer { init(history:, files:, privileged:, commands:, environment:); func restore(_ record: HistoryRecord, onConflict: (HistoryItem) -> ConflictChoice) throws -> RestoreOutcome }`

Davranış: yalnızca `trashed` ve `trashPath`'i var olan öğeler. Orijinal yolda bir şey varsa `onConflict`: `skip` → atlanır; `replace` → mevcut olan önce Çöp Sepeti'ne. Ara klasörler oluşturulur. Admin öğeler tek `privileged.run` (`mkdir -p`, `mv -n`). Sonra launchd öğeleri `launchctl bootstrap <launchdDomain> <orijinalYol>` (admin olanlar aynı yönetici çalıştırmasının sonunda). Başarılılar `restored`; kayıt kaydedilir.
- [ ] **Step 1: Failing tests:** `restoresToOriginalPathsCreatingParents` (orijinal üst klasör yok → oluşturulur), `skipsConflictWhenAsked`, `replacesConflictByTrashingExisting`, `bootstrapsLaunchAgentsAfterRestore`, `adminRestoreUsesSinglePrivilegedRun`, `missingTrashItemsAreReportedNotThrown`.
- [ ] **Step 2:** FAIL → **Step 3:** uygula → **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(core): restore uninstalled apps from history`.

---

### Task 9: SwiftUI arayüzü

**Files:**
- Create: `Sources/Kalintisiz/` altındaki tüm dosyalar (Dosya Yapısı'na bakın); Modify: `KalintisizApp.swift`

**Interfaces:**
- Consumes: Task 2 `InstalledApps`, Task 3–4 `LeftoverScanner`, Task 7 `Uninstaller`, Task 8 `Restorer`, Task 5 `HistoryStore`.
- Produces:
  - `@MainActor @Observable final class AppModel { apps: [InstalledApp]; selection: Selection? /* .app(InstalledApp) | .history */; scan: ScanResult?; checked: Set<UUID>; isScanning: Bool; history: [HistoryRecord]; lastOutcome: UninstallOutcome?; func reloadApps(); func select(_:) async /* tarama Task.detached */; func handleDrop(_ urls: [URL]); func uninstall() async; func restore(_ r: HistoryRecord) async }`
  - `enum FullDiskAccess { static func isGranted() -> Bool /* ~/Library/Containers/com.apple.stocks veya /Library/Application Support/com.apple.TCC/TCC.db okunabilir mi */; static func openSettings() /* x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles */ }`
  - `enum AppTerminator { static func runningInstances(bundleID:) -> [NSRunningApplication]; static func quit(bundleID:, timeout: 5) async -> Bool /* terminate, süre dolarsa forceTerminate */ }`

Ekranlar (spec §9 maketine göre):
- **Kenar çubuğu:** arama alanı, uygulama listesi (simge `NSWorkspace.icon(forFile:)`, ad, `.app` boyutu `ByteCountFormatter`), ayırıcı, "Geçmiş". Pencere `onDrop(of: [.fileURL])` ve `NSApplicationDelegate.application(_:open:)` (Dock'a bırakma) → `handleDrop`.
- **Detay:** başlık (simge, ad, sürüm, toplam seçili boyut), `LeftoverKind.displayName`'e göre gruplanmış `List` + onay kutuları; probable öğelerde "muhtemel" rozeti ve `note`; satır bağlam menüsü "Finder'da Göster"; yol yalnızca `help()` ipucunda. Sistem uzantısı varsa bilgilendirme kutusu (spec metni). Alt kısımda **"Çöp Sepeti'ne Taşı"** (`.borderedProminent`, hiçbir öğe seçili değilse pasif) → onay diyaloğu "Spotify ve 13 öğe Çöp Sepeti'ne taşınacak (412 MB). Geçmiş'ten geri alabilirsiniz." → uygulama çalışıyorsa "Spotify açık. Kapatılsın mı?" → sonuç ekranı "Spotify kaldırıldı — 14 öğe, 412 MB" + [Geri Al] + taşınamayanlar listesi.
- **Geçmiş:** satır "Spotify — 14 öğe — 19 Kasım" + durum rozeti (Geri yüklenebilir / Kısmen / Artık geri alınamaz / Geri yüklendi) + [Geri Yükle] + bağlam menüsü "Kaydı Sil". Çakışmada `Alert`: "<yol> zaten var" [Atla] [Değiştir] (Restorer'ın senkron `onConflict`'i için çakışmalar önce tespit edilip kullanıcıya toplu sorulur, cevaplar sözlükle geçilir).
- **İlk açılış / FDA yoksa:** `OnboardingView` 3 adım (neden gerekli, "Sistem Ayarları'nı Aç", "+ ile Kalıntısız'ı ekle ve aç"), her 2 sn `isGranted()` kontrolü; "Şimdilik atla" → kısıtlı mod, detayda sarı şerit "Tam Disk Erişimi yok; bazı kalıntılar görünmeyebilir".
- Açık/koyu mod sistemden; tüm düğme ve simgelerde `accessibilityLabel`.

- [ ] **Step 1:** Görünümleri ve `AppModel`'i yaz.
- [ ] **Step 2:** `swift build` → başarılı; `swift test` → hâlâ PASS.
- [ ] **Step 3:** Commit `feat(app): SwiftUI interface for scan, uninstall and history`.

---

### Task 10: Universal `.app`, Xcode projesi ve uçtan uca doğrulama

**Files:**
- Create: `App/Info.plist`, `App/Kalintisiz.entitlements`, `scripts/build-universal.sh`, `project.yml`, `README.md` (Türkçe: derleme, Xcode'da açma, FDA verme)

**Interfaces:**
- Consumes: tüm hedefler.

- `Info.plist`: `CFBundleIdentifier com.kalintisiz.app`, `CFBundleDisplayName Kalıntısız`, `CFBundleExecutable Kalintisiz`, `LSMinimumSystemVersion 15.0`, `CFBundleDocumentTypes` (`com.apple.application-bundle`, rol Viewer — Dock'a bırakma için), `NSAppleEventsUsageDescription` ("Yönetici izni gerektiren dosyaları taşımak için").
- `build-universal.sh`: `swift build -c release --triple arm64-apple-macosx15.0` ve `--triple x86_64-apple-macosx15.0`; `lipo -create` → `build/Kalıntısız.app/Contents/MacOS/Kalintisiz`; Info.plist kopyala; `codesign --force --deep -s - --entitlements App/Kalintisiz.entitlements`.
- `project.yml`: tek `application` hedefi, kaynaklar `Sources/Kalintisiz`, yerel paket bağımlılığı `KalintisizCore`, `INFOPLIST_FILE: App/Info.plist`, `ARCHS: $(ARCHS_STANDARD)`, `MACOSX_DEPLOYMENT_TARGET: 15.0`, `ENABLE_APP_SANDBOX: NO`, imza "Sign to Run Locally"; test hedefi `KalintisizCoreTests`.

- [ ] **Step 1:** Dosyaları yaz; `brew install xcodegen`; `xcodegen generate` → `Kalintisiz.xcodeproj` oluşur.
- [ ] **Step 2:** `scripts/build-universal.sh` çalıştır. Beklenen: `lipo -info "build/Kalıntısız.app/Contents/MacOS/Kalintisiz"` → `x86_64 arm64`; `codesign -v` hatasız.
- [ ] **Step 3: Uçtan uca duman testi** (geçici sahte uygulama ile, gerçek kullanıcı uygulamalarına dokunmadan): `~/Applications/KalintisizTest.app` (bundle `com.kalintisiz.e2etest`) + `~/Library/Caches/com.kalintisiz.e2etest`, `~/Library/Preferences/com.kalintisiz.e2etest.plist`, `~/Library/LaunchAgents/com.kalintisiz.e2etest.plist` (`ProgramArguments` app içini gösterir, yüklenmemiş) oluştur. Uygulamayı aç, KalintisizTest'i seç → 4 öğe certain görünür → Çöp Sepeti'ne taşı → dosyalar `~/.Trash`'te, orijinaller yok → Geçmiş'te "KalintisizTest — 4 öğe" → Geri Yükle → dört yol da yerinde. Sonunda sahte dosyaları kaldır (Çöp Sepeti'ne).
- [ ] **Step 4:** Commit `build: universal app bundle, Xcode project and README`.

---

## Self-review notları

- Spec §6 kişisel klasör, üretici paylaşımı, sistem uzantısı kuralları → Task 3–4. §7 manifest-önce, kısmi hata, admin toplu → Task 7. §8 durumlar, çakışma, launchd yeniden yükleme → Task 5, 8. §9 FDA, sürükle-bırak, Finder'da Göster → Task 9. §5 Universal + Xcode → Task 10.
- Bilinçli sapma: xcstrings yerine Türkçe anahtarlı `String(localized:)` (Global Constraints).
