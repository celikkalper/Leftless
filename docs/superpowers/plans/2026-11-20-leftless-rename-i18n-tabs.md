# Leftless Rename, Localization and History Tab — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename Kalıntısız to Leftless, localize the whole app into 7 languages, and move History into a toolbar tab.

**Architecture:** Mechanical rename first (one commit, green suite). Core stops persisting human text (failure codes) and gets its own String Catalog; the app's literals become English keys in an app String Catalog; a coverage test guards every catalog. The sidebar loses the History row; a toolbar segmented picker switches between Apps (split view) and History (full width). Universal builds move to `xcodebuild`, because SwiftPM copies `.xcstrings` raw (verified) while Xcode compiles them into `.lproj`.

**Tech Stack:** Swift 6.1, SwiftUI, SwiftPM, Swift Testing, Xcode 26.3 (`xcodebuild`, String Catalogs), XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-20-leftless-rename-i18n-tabs-design.md` (and the original `2026-11-19-kalintisiz-uninstaller-design.md`, whose anti-goals still bind).

## Global Constraints

- Display name **Leftless**; bundle ID `com.leftless.app`; product/target `Leftless`; core module `LeftlessCore`; tests `LeftlessCoreTests`; history dir `~/Library/Application Support/Leftless/History`.
- Languages: `en` (source, `defaultLocalization: "en"`), `tr`, `de`, `fr`, `es`, `ja`, `pt-BR`.
- Every user-visible string goes through a String Catalog with an English key; no Turkish literals left in `Sources/` (except the legacy-text passthrough described in Task 2).
- Core never writes human text into history records; failure reasons are `FailureReason` codes.
- All prior safety behaviour (manifest-first, nothing permanently deleted, probable items unticked, protected paths) is unchanged; the existing 105 tests keep passing (renamed).
- macOS 15.0+, Universal (arm64 + x86_64), sandbox off.
- Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Existing users' history after rename** — records in `Kalintisiz/History` must still show and restore; `HistoryMigration` test (Task 1).
2. **Old records with Turkish error text** — displayed unchanged, never crash decoding; `HistoryItem` decoding test with legacy `error` string (Task 2).
3. **A key missing in one language** — falls back to English silently at runtime, but the catalog coverage test must fail (Task 3).
4. **Long translations (German/French) in the toolbar picker and buttons** — no truncation of `History (N)` at the default window width; checked in the launch-per-language step (Task 5).
5. **Japanese/Portuguese plural and number formatting** — counts like "14 items" use catalog plural variants and `ByteCountFormatter`/locale-aware formatting, never string concatenation; catalog test checks plural variants exist for count keys (Task 3).

---

### Task 1: Rename to Leftless (+ history migration)

**Files:** Move `Sources/Kalintisiz` → `Sources/Leftless`, `Sources/KalintisizCore` → `Sources/LeftlessCore`, `Tests/KalintisizCoreTests` → `Tests/LeftlessCoreTests`, `App/Kalintisiz.entitlements` → `App/Leftless.entitlements`, `KalintisizApp.swift` → `LeftlessApp.swift`; modify `Package.swift`, `project.yml`, `App/Info.plist`, `scripts/build-universal.sh`, `README.md`, all `import KalintisizCore`; delete `Kalintisiz.xcodeproj` and regenerate `Leftless.xcodeproj`; Create `Sources/LeftlessCore/HistoryMigration.swift`, `Tests/LeftlessCoreTests/HistoryMigrationTests.swift`.

**Interfaces:**
- Produces: `public enum HistoryMigration { static func migrateIfNeeded(applicationSupport: URL, fileManager: FileManager = .default) throws -> Bool }` — moves `<AS>/Kalintisiz/History` to `<AS>/Leftless/History` only when the old exists and the new does not (creates `<AS>/Leftless`); returns whether it moved. Called once at app launch before history loads; errors are ignored by the caller (history simply starts empty).
- `HistoryStore.liveDirectory()` → `.../Leftless/History`.
- Self-exclusion in the app list covers both `com.leftless.app` and `com.kalintisiz.app`.
- E2E fixture IDs become `com.leftless.e2etest` / `LeftlessTest.app`; env var `KALINTISIZ_E2E` → `LEFTLESS_E2E`. `.gitignore` gains `.swiftpm/` and `*.xcodeproj/project.xcworkspace/xcuserdata/`.

- [ ] **Step 1:** `git mv` the folders/files; update Package.swift product/target names; fix imports; `swift build` + `swift test` → 105 pass.
- [ ] **Step 2: Failing tests** `HistoryMigrationTests`: `movesOldHistoryWhenNewMissing` (old dir with one json → after: new dir has it, old `History` gone, returns true), `doesNothingWhenNewExists` (both exist → untouched, false), `doesNothingWhenOldMissing` (false).
- [ ] **Step 3:** Implement `HistoryMigration`; call it in the app delegate's launch path before the model loads history. Update `liveDirectory()`, self-exclusion, Info.plist (`CFBundleIdentifier com.leftless.app`, `CFBundleDisplayName Leftless`, `CFBundleName Leftless`, `CFBundleExecutable Leftless`), entitlements path, `project.yml`, script output `build/Leftless.app`, README (English title; keep Turkish body for now — Task 3 rewrites it), E2E IDs.
- [ ] **Step 4:** `xcodegen generate`; `git rm -r Kalintisiz.xcodeproj`; `swift test` (108 pass) and `xcodebuild -project Leftless.xcodeproj -scheme Leftless -destination 'platform=macOS' build` succeed; `grep -rni kalintisiz Sources Tests App scripts project.yml Package.swift` shows only the migration's old folder name and the legacy bundle ID.
- [ ] **Step 5:** Commit `refactor: rename app to Leftless and migrate history folder`.

---

### Task 2: Core — failure codes and core String Catalog

**Files:** Modify `Sources/LeftlessCore/{History,Uninstaller,Restorer,Models,LeftoverScanner,Presentation}.swift`, `Package.swift` (`defaultLocalization: "en"`, core `resources: [.process("Localizable.xcstrings")]`); Create `Sources/LeftlessCore/Localizable.xcstrings`, `Sources/LeftlessCore/L10n.swift`; Tests: update `UninstallerTests`, `RestorerTests`, `PresentationTests`, `HistoryStoreTests`.

**Interfaces:**
- Produces:
  - `public enum FailureReason: Codable, Hashable, Sendable { case adminDenied, manifestUpdateFailed, notFoundInTrash, moveNotVerified, other(String) }` — `other` carries raw system text (stderr / `localizedDescription`), shown only in `.help()`.
  - `HistoryItem` gains `failure: FailureReason?`; the old `error: String?` stays decodable (legacy) but is no longer written. Uninstaller/Restorer set `failure` everywhere they previously wrote Turkish text ("Yönetici izni verilmedi" → `.adminDenied`, "Kayıt güncellenemedi" → `.manifestUpdateFailed`, "Çöp Sepeti'nde bulunamadı" → `.notFoundInTrash`, "…doğrulanamadı" → `.moveNotVerified`, stderr/NSError text → `.other(text)`).
  - `func L(_ key: String.LocalizationValue) -> String` in `L10n.swift` = `String(localized: key, bundle: .module)`, used by every core display string: `LeftoverKind.displayName`, vendor note (`"%@ may also use this"` with app name argument), `skippedLocations` names.
  - `Presentation.friendlyFailureReason(_ item: HistoryItem) -> String` — from `failure` when present; else legacy `error` text returned unchanged; else "Couldn't be moved".
- [ ] **Step 1: Failing tests:** `uninstallCancelledAdminRecordsAdminDeniedCode` (`failure == .adminDenied`, `error == nil`), `retargetSaveFailureRecordsManifestUpdateFailed`, `restorerMissingTrashRecordsNotFoundInTrash`, `legacyRecordWithTurkishErrorDecodesAndDisplaysUnchanged` (JSON fixture with `"error":"Yönetici izni verilmedi"` and no `failure` → decodes; friendly text equals that string), `kindDisplayNamesAreEnglishSource` (`LeftoverKind.caches.displayName == "Caches"` under `swift test`, where catalogs are not compiled and the source string is returned).
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement; write all core keys into `Sources/LeftlessCore/Localizable.xcstrings` (English only for now — Task 3 fills translations). **Step 4:** `swift test` → all pass; `grep -rn '[çğıöşüÇĞİÖŞÜ]' Sources/LeftlessCore --include=*.swift` → only `HistoryMigration`-free legacy comment or nothing.
- [ ] **Step 5:** Commit `refactor(core): failure codes and localizable core strings`.

---

### Task 3: App strings in English, 7-language catalogs, coverage test

**Files:** Modify every view and `AppModel`/`Support` file in `Sources/Leftless`; Create `Sources/Leftless/Localizable.xcstrings`, `App/InfoPlist.xcstrings`; fill `Sources/LeftlessCore/Localizable.xcstrings`; Create `Tests/LeftlessCoreTests/LocalizationCatalogTests.swift`; rewrite `README.md` in English with a short Turkish section.

**Interfaces:**
- Consumes: Task 2 `L(_:)`, `FailureReason`, `friendlyFailureReason`.
- Catalog rules: source language `en`; languages `tr, de, fr, es, ja, pt-BR`; every entry `state: "translated"` in all 6; count-bearing strings ("%lld items", "History (%lld)", "%lld extensions" …) use `variations.plural` with at least `one` and `other` for every language that needs them (ja may use `other` only); sizes via `ByteCountFormatter`, dates via `Date.FormatStyle` — never concatenated.
- `InfoPlist.xcstrings`: `CFBundleDisplayName` = "Leftless" in all languages; `NSAppleEventsUsageDescription` translated.
- `project.yml`: add the catalogs to the app/core targets as resources; `LOCALIZATION_PREFERS_STRING_CATALOGS = YES`, `SWIFT_EMIT_LOC_STRINGS = YES`; `knownRegions` include the 7.

- [ ] **Step 1: Failing test** `LocalizationCatalogTests` (reads the three `.xcstrings` JSON files from the repo via `#filePath`): `everyKeyTranslatedInAllLanguages` (for each key: each of the 6 languages has a `stringUnit` with `state == "translated"` and non-empty value, or a `variations.plural` whose every variant is translated), `countKeysHavePluralVariants` (keys containing `%lld` have `variations.plural` in `tr, de, fr, es, pt-BR`), `noTurkishLiteralsInAppSources` (scan `Sources/Leftless/**/*.swift` string literals for `[çğıöşüÇĞİÖŞÜ]` → none).
- [ ] **Step 2:** Run → FAIL. **Step 3:** Convert all app literals to English source strings (natural, concise UI English; keep Turkish meaning: e.g. "Çöp Sepeti'ne Taşı" → "Move to Trash", "muhtemel" → "possible", "Geçmiş" → "History", "Tam Disk Erişimi" → "Full Disk Access"). Build with `xcodebuild … build` so Xcode extracts keys into the catalogs; then fill all 6 translations (Turkish = the current shipped wording). Write README in English (+ "Türkçe" section).
- [ ] **Step 4:** `swift test` → all pass; `xcodebuild … build` → success and `git diff --exit-code -- '*.xcstrings'` after a second build shows no new extracted keys.
- [ ] **Step 5:** Commit `feat: localize Leftless into 7 languages`.

---

### Task 4: History as a toolbar tab

**Files:** Modify `Sources/Leftless/LeftlessApp.swift` (root view), `AppModel.swift`, `Views/AppListView.swift`, `Views/HistoryView.swift`; `Sources/LeftlessCore/Presentation.swift`; Test: `PresentationTests.swift`.

**Interfaces:**
- Produces: `enum MainTab: Hashable { case apps, history }` in the app; `AppModel.tab: MainTab` (default `.apps`); `AppModel.selection` keeps only app selections (the `.history` case is removed). `Presentation.historyBadgeCount(_ records: [HistoryRecord], status: (HistoryRecord) -> RestoreStatus) -> Int` — counts `.restorable` and `.partial`.
- Layout: toolbar item `.principal` → `Picker` with `.segmented` style: "Apps" and "History" (with " (N)" via plural key when N > 0); `.keyboardShortcut("1")` / `("2")` via hidden buttons or `Commands` menu items "Apps"/"History" under View. `.apps` → existing `NavigationSplitView`; `.history` → `HistoryView` full width. Switching tabs while `isWorking` is disabled. After a successful uninstall the result view's existing "Geri Al" stays; no automatic tab switch.
- [ ] **Step 1: Failing test** `historyBadgeCountsRestorableAndPartial` (restorable, partial, unrecoverable, restored → 2).
- [ ] **Step 2:** FAIL → **Step 3:** implement helper + UI; new strings go through the catalogs with all 7 languages (coverage test from Task 3 enforces). **Step 4:** `swift test`, `xcodebuild … build` pass.
- [ ] **Step 5:** Commit `feat(app): History as a toolbar tab`.

---

### Task 5: Universal build via xcodebuild and per-language launch check

**Files:** Modify `scripts/build-universal.sh`, `README.md` (build section).

- `build-universal.sh`: `xcodegen generate` if `project.yml` is newer than the project; `xcodebuild -project Leftless.xcodeproj -scheme Leftless -configuration Release -derivedDataPath build/DerivedData ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- build`; copy the product to `build/Leftless.app`; `xattr -cr`; ad-hoc `codesign --force --deep -s - --entitlements App/Leftless.entitlements`; print `lipo -info` and `codesign -v`.
- [ ] **Step 1:** Rewrite script; run it. Expected: `lipo -info build/Leftless.app/Contents/MacOS/Leftless` → `x86_64 arm64`; `ls build/Leftless.app/Contents/Resources` contains `tr.lproj de.lproj fr.lproj es.lproj ja.lproj pt-BR.lproj` (or equivalents) and the core resource bundle with the same `.lproj` folders.
- [ ] **Step 2:** For each of `en tr de fr es ja pt-BR`: `open -n build/Leftless.app --args -AppleLanguages "(<lang>)"`, wait 3 s, capture the window with `screencapture -l<windowID>` if screen-recording permission is available (otherwise skip screenshots and only assert the process is alive), then quit. Do not click anything. Save screenshots under the session scratchpad, not the repo.
- [ ] **Step 3:** `LEFTLESS_E2E=1 swift test --filter EndToEnd` passes.
- [ ] **Step 4:** Commit `build: universal xcodebuild pipeline with compiled string catalogs`.
