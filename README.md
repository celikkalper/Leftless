# Leftless

An app uninstaller for macOS 15 and later. When you remove an app, Leftless finds what it leaves behind (caches, preferences, logs, launch agents and more) and moves all of it to the Trash together. Nothing is ever deleted permanently: every uninstall is recorded in History and can be undone.

Available in English, Turkish, German, French, Spanish, Japanese and Portuguese (Brazil). Leftless follows the macOS system language; to choose a different language for Leftless only, use **System Settings → General → Language & Region → Applications**.

## What it does

- Lists installed apps. Pick one from the list, or drag an `.app` onto the window or the Dock icon.
- Scans for the app's leftovers and shows how sure it is about each one: **certain** items are selected by default, **possible** items stay unselected until you tick them.
- Moves the selected items to the Trash. Items that need administrator permission ask for your password once.
- Never touches `com.apple.*` items or system folders.

## Opening in Xcode

1. Double-click `Leftless.xcodeproj`.
2. Make sure the **Leftless** scheme is selected and press **⌘R**.

The project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen); you only need it if you change project settings (`brew install xcodegen && xcodegen generate`). Swift Package Manager works too: `swift run Leftless`, and `swift test` for the tests. Under SwiftPM the String Catalogs are not compiled, so the app shows its English source text; build with Xcode to get the translations.

## Translations

Strings live in String Catalogs with English keys: `Sources/Leftless/Localizable.xcstrings` (app), `Sources/LeftlessCore/Localizable.xcstrings` (core) and `App/InfoPlist.xcstrings` (Info.plist). `LocalizationCatalogTests` fails if any key is missing a language or a count string lacks plural forms. Translations were written by Claude; a review by native speakers is recommended before release.

After adding or changing strings in the app, build once and merge the new keys into the catalog (Xcode does this itself when you build in the IDE):

```sh
xcodebuild -project Leftless.xcodeproj -scheme Leftless -destination 'platform=macOS' build
xcrun xcstringstool sync Sources/Leftless/Localizable.xcstrings \
  --stringsdata ~/Library/Developer/Xcode/DerivedData/Leftless-*/Build/Intermediates.noindex/Leftless.build/Debug/Leftless.build/Objects-normal/*/*.stringsdata
```

## Building a universal .app

```sh
./scripts/build-universal.sh
```

The script runs `xcodebuild` (Release, `ARCHS="arm64 x86_64"`) so the String Catalogs are compiled into `.lproj` folders in the app and in the `Leftless_LeftlessCore.bundle` resource bundle, then ad-hoc signs the result and fails if an architecture, the core bundle or a language is missing. (A plain `swift build` does not compile the catalogs and does not ship the core bundle, so it is not used for the .app.)

Output: `build/Leftless.app` (arm64 + x86_64, ad-hoc signed). To check it:

```sh
lipo -info "build/Leftless.app/Contents/MacOS/Leftless"
codesign -v "build/Leftless.app"
```

> To distribute Leftless to other Macs it must be signed with a **Developer ID** and **notarized** by Apple. An ad-hoc signed app only opens without warnings on the Mac that built it.

## Full Disk Access

Leftless runs outside the sandbox. Some folders (Mail, Safari data, Containers and so on) can only be scanned with **Full Disk Access**:

1. Open **System Settings → Privacy & Security → Full Disk Access**.
2. Click **+**, add Leftless and turn it on.
3. Restart Leftless.

Without it the app still works, but some leftovers may not be shown; a warning bar appears in the window.

> **Upgrading from Kalıntısız:** the bundle ID changed to `com.leftless.app`, so Full Disk Access granted to the old app does not carry over. Grant it again to Leftless (you can remove the old Kalıntısız entry). Your existing History is moved over automatically on first launch.

## Undo and History

Before each uninstall, Leftless writes to disk which file is going where. In **History**, each record is listed as "App name — N items". **Restore** moves the files from the Trash back to their original locations. If something else now exists at the same path, you are asked whether to skip or replace it; launch agents are loaded again after they are restored. If you have emptied the Trash, those items can no longer be restored and the record says so.

## End-to-end smoke test (optional)

Runs the whole flow (scan → uninstall → restore) for real against a fake app (`~/Applications/LeftlessTest.app`) and its leftovers, then deletes the fake files:

```sh
LEFTLESS_E2E=1 swift test --filter EndToEnd
```

Without the environment variable this test is skipped.

## Türkçe

Leftless (eski adıyla Kalıntısız), macOS 15 ve sonrası için bir uygulama kaldırıcıdır. Kaldırdığınız uygulamanın geride bıraktığı önbellek, tercih, günlük ve başlatma aracısı gibi kalıntıları bulur ve hepsini birlikte Çöp Sepeti'ne taşır. Hiçbir şey kalıcı olarak silinmez. Uygulama macOS'un sistem dilini kullanır; Türkçe arayüz için ayrıca bir şey yapmanız gerekmez.

- **Xcode'da açma:** `Leftless.xcodeproj` dosyasına çift tıklayın, **Leftless** şemasını seçin ve **⌘R** ile çalıştırın. Proje `project.yml` dosyasından XcodeGen ile üretilir (`xcodegen generate`). `swift run Leftless` ile de çalışır, ancak çeviriler yalnızca Xcode ile derlenince görünür; SwiftPM ile arayüz İngilizce açılır.
- **Universal .app:** `./scripts/build-universal.sh` komutu `xcodebuild` ile derleyip `build/Leftless.app` dosyasını üretir (arm64 + x86_64, ad-hoc imzalı); çeviri kataloglarını derler ve mimari, çekirdek kaynak paketi ya da dil eksikse hata verir.
- **Tam Disk Erişimi:** **Sistem Ayarları → Gizlilik ve Güvenlik → Tam Disk Erişimi** bölümünde **+** ile Leftless'ı ekleyip açın, sonra uygulamayı yeniden başlatın. Paket kimliği `com.leftless.app` olarak değiştiği için **Kalıntısız'a verdiğiniz izin Leftless'a geçmez; izni yeniden vermeniz gerekir.** Eski geçmişiniz ilk açılışta otomatik olarak taşınır.
- **Geçmiş ve geri alma:** Her kaldırmadan önce hangi dosyanın nereye taşınacağı diske kaydedilir. **Geçmiş** bölümünde **Geri Yükle** dediğinizde dosyalar Çöp Sepeti'nden özgün yerlerine döner. Çöp Sepeti'ni boşalttıysanız ilgili öğeler geri yüklenemez.
- **Dağıtım:** Başka Mac'lara dağıtmak için uygulamanın **Developer ID** ile imzalanması ve Apple'ın **noter onayından (notarization)** geçmesi gerekir. Ad-hoc imzalı uygulama yalnızca derlendiği Mac'te sorunsuz açılır.
